import 'dart:typed_data';

import 'package:termui/termui.dart';

/// The target mode for terminal rendering.
enum RenderingMode {
  /// Renders to the absolute terminal screen area (typically combined with alternate screen buffer).
  alternateScreen,

  /// Renders relative to the cursor's current inline position without clearing screen history.
  inline,
}

/// A diff-based terminal renderer.
///
/// It maintains a front-buffer representing the last rendered state of the screen.
/// When [render] is called with a new back-buffer, the renderer finds the differences
/// and emits the minimal set of ANSI control sequences to update the display.
class Renderer {
  static final int _traceRenderId = Tracer.registerString('Renderer:render');

  final Buffer _frontBuffer;

  /// The rendering mode used by this renderer.
  /// Determines whether output is rendered inline or to the alternate screen buffer.
  final RenderingMode mode;
  int _lastHeight = 0;
  bool _firstFrame = true;
  final Map<
    int,
    ({
      int cols,
      int rows,
      int pixelWidth,
      int pixelHeight,
      int version,
      Uint8List pixels,
    })
  >
  _uploadedKittyImages = {};

  ShaderCapabilitiesEvent? _shaderCapabilities;
  final Map<String, _GlslContentHash> _uploadedGlslHashes = {};
  final Map<String, ShaderRegion> _emittedShaderRegions = {};
  final Map<int, CellTransform> _emittedCellTransforms = {};

  /// Creates a renderer with an initial screen size and optional host shader capabilities.
  Renderer(
    int width,
    int height, {
    this.mode = RenderingMode.alternateScreen,
    ShaderCapabilitiesEvent? shaderCapabilities,
  }) : _frontBuffer = Buffer(width, height),
       _shaderCapabilities = shaderCapabilities;

  /// Active host shader and per-cell transform capabilities (`null` on plain terminals).
  ShaderCapabilitiesEvent? get shaderCapabilities => _shaderCapabilities;

  set shaderCapabilities(ShaderCapabilitiesEvent? value) {
    if (_shaderCapabilities == value) return;
    _shaderCapabilities = value;
    _uploadedGlslHashes.clear();
    _emittedShaderRegions.clear();
    _emittedCellTransforms.clear();
  }

  /// Emits an `ESC _ S a=reset` sequence when shader capabilities are active
  /// and resets the corresponding renderer diff caches.
  void resetShaders(StringSink out, {String target = 'all'}) {
    final caps = _shaderCapabilities;
    if (caps == null || !caps.isAnySupported) return;
    out.write(ShaderApcEncoder.encodeReset(target: target));
    if (target == 'all' || target == 'regions') {
      _emittedShaderRegions.clear();
    }
    if (target == 'all' || target == 'xforms') {
      _emittedCellTransforms.clear();
    }
    if (target == 'all') {
      _uploadedGlslHashes.clear();
    }
  }

  /// Exposes the current front-buffer representing the screen state.
  Buffer get frontBuffer => _frontBuffer;

  bool _prepareFrame(Buffer backBuffer, StringSink out) {
    bool sizeChanged = _firstFrame;
    _firstFrame = false;

    if (mode == RenderingMode.inline) {
      if (_lastHeight > 0) {
        out.write('\x1b[${_lastHeight}F');
      } else {
        out.write('\n\r');
      }
      if (backBuffer.width != _frontBuffer.width ||
          backBuffer.height != _frontBuffer.height) {
        _frontBuffer.resize(backBuffer.width, backBuffer.height);
        sizeChanged = true;
      }
      return sizeChanged;
    }

    if (backBuffer.width != _frontBuffer.width ||
        backBuffer.height != _frontBuffer.height ||
        sizeChanged) {
      _frontBuffer.resize(backBuffer.width, backBuffer.height);
      sizeChanged = true;
      out.write('\x1b[2J\x1b[H');
    }
    return sizeChanged;
  }

  @pragma('vm:prefer-inline')
  static bool _cellsGlyphDiffer(
    Buffer backBuffer,
    Buffer frontBuffer,
    int idx,
  ) {
    final backCode = backBuffer.glyphCodes[idx];
    final frontCode = frontBuffer.glyphCodes[idx];
    if (((backCode | frontCode) & GlyphCellList.clusterFlag) == 0) {
      return backCode != frontCode;
    }
    if (((backCode ^ frontCode) & GlyphCellList.clusterFlag) != 0) {
      return true;
    }
    return backBuffer.glyphCellList.decodeCode(backCode) !=
        frontBuffer.glyphCellList.decodeCode(frontCode);
  }

  @pragma('vm:prefer-inline')
  bool _isCellChanged(
    Buffer backBuffer,
    int x,
    int y,
    int idx,
    int attrIdx, {
    required bool sizeChanged,
  }) {
    if (sizeChanged) return true;
    final backAttr = backBuffer.attributes;
    final frontAttr = _frontBuffer.attributes;
    if (_cellsGlyphDiffer(backBuffer, _frontBuffer, idx) ||
        backAttr[attrIdx + 0] != frontAttr[attrIdx + 0] ||
        backAttr[attrIdx + 1] != frontAttr[attrIdx + 1] ||
        backAttr[attrIdx + 2] != frontAttr[attrIdx + 2]) {
      return true;
    }
    if ((backBuffer.hasUnderlineColors || _frontBuffer.hasUnderlineColors) &&
        backBuffer.getUnderlineColor(x, y) !=
            _frontBuffer.getUnderlineColor(x, y)) {
      return true;
    }
    if ((backBuffer.hasTextSizing || _frontBuffer.hasTextSizing) &&
        backBuffer.getTextSizing(x, y) != _frontBuffer.getTextSizing(x, y)) {
      return true;
    }
    if (!backBuffer.hasUris && !_frontBuffer.hasUris) return false;
    return backBuffer.getUri(x, y) != _frontBuffer.getUri(x, y);
  }

  void _emitPendingKittyImages(Buffer backBuffer, StringSink out) {
    final attrs = backBuffer.attributes;
    final codes = backBuffer.glyphCodes;
    final cells = backBuffer.glyphCellList;
    final width = backBuffer.width;
    if (width <= 0) return;
    final cellCount = codes.length;
    for (var cellIdx = 0; cellIdx < cellCount; cellIdx++) {
      final attrIdx = cellIdx * 3;
      if ((attrs[attrIdx + 2] & Modifier.kittyPlaceholder) == 0) continue;
      final imageId = _extractKittyImageId(
        cells.decodeCode(codes[cellIdx]),
        attrs[attrIdx],
      );
      final data = backBuffer.lookupKittyImage(
        cellIdx % width,
        cellIdx ~/ width,
        imageId,
      );
      if (data == null || _isKittyImageUploaded(imageId, data)) continue;
      _recordUploadedKittyImage(imageId, data);
      out.write(data.toApcSequence());
    }
  }

  static int _extractKittyImageId(String cellChar, int fgAttr) {
    final low24 = fgAttr & 0xFFFFFF;
    if (cellChar.length < 5) return low24;
    final msb = parseKittyPlaceholderCell(cellChar)?.imageIdMsb ?? 0;
    return ((msb & 0xFF) << 24) | low24;
  }

  bool _isKittyImageUploaded(int imageId, KittyImageData data) {
    final prev = _uploadedKittyImages[imageId];
    return prev != null &&
        prev.cols == data.gridCols &&
        prev.rows == data.gridRows &&
        prev.pixelWidth == data.pixelWidth &&
        prev.pixelHeight == data.pixelHeight &&
        prev.version == data.version &&
        identical(prev.pixels, data.rgbaPixels);
  }

  void _recordUploadedKittyImage(int imageId, KittyImageData data) {
    _uploadedKittyImages[imageId] = (
      cols: data.gridCols,
      rows: data.gridRows,
      pixelWidth: data.pixelWidth,
      pixelHeight: data.pixelHeight,
      version: data.version,
      pixels: data.rgbaPixels,
    );
  }

  int _findChangedRunEnd(
    Buffer backBuffer,
    int y,
    int rowOffset,
    int startX, {
    required bool sizeChanged,
  }) {
    final width = backBuffer.width;
    var runEnd = startX + 1;
    while (runEnd < width) {
      final ridx = rowOffset + runEnd;
      if (!_isCellChanged(
        backBuffer,
        runEnd,
        y,
        ridx,
        ridx * 3,
        sizeChanged: sizeChanged,
      )) {
        break;
      }
      runEnd++;
    }
    return runEnd;
  }

  void _syncFrontCell(
    int rx,
    int y,
    int rxIdx,
    int rxAttrIdx,
    int backCode,
    String char,
    int cellFg,
    int cellBg,
    int cellMod,
    int cellUlColor,
    String? cellUri,
    int cellTextSizing,
  ) {
    final frontCells = _frontBuffer.glyphCellList;
    if ((backCode & GlyphCellList.clusterFlag) == 0) {
      frontCells.setCodeAt(rxIdx, backCode);
    } else {
      frontCells.setCodeAt(rxIdx, frontCells.encodeGrapheme(char));
    }
    final frontAttr = _frontBuffer.attributes;
    frontAttr[rxAttrIdx + 0] = cellFg;
    frontAttr[rxAttrIdx + 1] = cellBg;
    frontAttr[rxAttrIdx + 2] = cellMod;
    if (cellUlColor != 0 || _frontBuffer.hasUnderlineColors) {
      _frontBuffer.setUnderlineColor(rx, y, cellUlColor);
    }
    if (cellUri != null || _frontBuffer.hasUris) {
      _frontBuffer.setUri(rx, y, cellUri);
    }
    if (cellTextSizing != KittyTextSizing.none || _frontBuffer.hasTextSizing) {
      _frontBuffer.setTextSizing(rx, y, cellTextSizing);
    }
  }

  /// Invalidates owning `OSC 66` anchors (and any remaining sibling overlay
  /// cells in their footprints) whenever a continuation cell transitions from
  /// non-continuation back to continuation, so the anchor re-emits over stale
  /// glyphs left by closed overlays.
  void _invalidateUncoveredOsc66Anchors(Buffer backBuffer) {
    final width = backBuffer.width;
    final height = backBuffer.height;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        _invalidateUncoveredAnchorAt(backBuffer, x, y, width, height);
      }
    }
  }

  void _invalidateUncoveredAnchorAt(
    Buffer backBuffer,
    int x,
    int y,
    int width,
    int height,
  ) {
    final ts = KittyTextSizing(backBuffer.getTextSizing(x, y));
    if (!ts.isContinuation) return;
    if (KittyTextSizing(_frontBuffer.getTextSizing(x, y)).isContinuation) {
      return;
    }
    final anchorX = x - ts.originDx;
    final anchorY = y - ts.originDy;
    if (anchorX < 0 || anchorY < 0 || anchorX >= width || anchorY >= height) {
      return;
    }
    final anchorTs = KittyTextSizing(
      backBuffer.getTextSizing(anchorX, anchorY),
    );
    if (!anchorTs.isAnchor) return;
    _invalidateOsc66Footprint(backBuffer, anchorX, anchorY, anchorTs);
  }

  void _invalidateOsc66Footprint(
    Buffer backBuffer,
    int anchorX,
    int anchorY,
    KittyTextSizing anchorTs,
  ) {
    if (_frontBuffer.getTextSizing(anchorX, anchorY) == KittyTextSizing.none) {
      return;
    }
    _frontBuffer.setTextSizing(anchorX, anchorY, KittyTextSizing.none);
    final width = backBuffer.width;
    final height = backBuffer.height;
    final boxCols = _osc66Advance(
      anchorTs,
      backBuffer.glyphCellList.decodeCode(
        backBuffer.glyphCodes[anchorY * width + anchorX],
      ),
      anchorX,
      width,
    );
    final endX = anchorX + boxCols < width ? anchorX + boxCols : width;
    final endY = anchorY + anchorTs.scale < height
        ? anchorY + anchorTs.scale
        : height;
    final frontAttr = _frontBuffer.attributes;
    for (var fy = anchorY; fy < endY; fy++) {
      for (var fx = anchorX; fx < endX; fx++) {
        if (fx == anchorX && fy == anchorY) continue;
        if (KittyTextSizing(backBuffer.getTextSizing(fx, fy)).isContinuation) {
          continue;
        }
        frontAttr[(fy * width + fx) * 3] ^= 1;
      }
    }
  }

  /// Diffs [backBuffer] against [_frontBuffer] and writes minimal ANSI escape sequences to [out].
  void render(Buffer backBuffer, StringSink out) {
    Tracer.record(_traceRenderId, Phase.begin, TraceCategory.paint);
    try {
      final sizeChanged = _prepareFrame(backBuffer, out);
      if (sizeChanged) {
        _uploadedKittyImages.clear();
        _emittedShaderRegions.clear();
        _emittedCellTransforms.clear();
      }
      _emitPendingKittyImages(backBuffer, out);
      if (!sizeChanged && backBuffer.hasTextSizing) {
        _invalidateUncoveredOsc66Anchors(backBuffer);
      }

      var state = _RenderCursorState();
      final width = backBuffer.width;
      final height = backBuffer.height;

      for (var y = 0; y < height; y++) {
        var x = 0;
        final rowOffset = y * width;
        while (x < width) {
          final idx = rowOffset + x;
          if (!_isCellChanged(
            backBuffer,
            x,
            y,
            idx,
            idx * 3,
            sizeChanged: sizeChanged,
          )) {
            x++;
            continue;
          }
          final runEnd = _findChangedRunEnd(
            backBuffer,
            y,
            rowOffset,
            x,
            sizeChanged: sizeChanged,
          );
          _emitRun(backBuffer, out, state, y, rowOffset, x, runEnd);
          x = runEnd;
        }
      }

      if (state.hasActiveStyle) {
        out.write('\x1b[0m');
      }

      _emitShaderMetadataDiff(backBuffer, out);
      _syncFrontShaderMetadata(backBuffer);

      if (mode == RenderingMode.inline) {
        _moveCursorRelative(
          out,
          state.cursorX,
          state.cursorY,
          0,
          backBuffer.height,
        );
        _lastHeight = backBuffer.height;
      }
    } finally {
      Tracer.record(_traceRenderId, Phase.end, TraceCategory.paint);
    }
  }

  void _emitRun(
    Buffer backBuffer,
    StringSink out,
    _RenderCursorState state,
    int y,
    int rowOffset,
    int runStart,
    int runEnd,
  ) {
    final backCodes = backBuffer.glyphCodes;
    final backCells = backBuffer.glyphCellList;
    final backAttr = backBuffer.attributes;
    final hasTextSizing = backBuffer.hasTextSizing;
    var runCursorX = -1;

    for (var rx = runStart; rx < runEnd; rx++) {
      final rxIdx = rowOffset + rx;
      final rxAttrIdx = rxIdx * 3;
      final cellFg = backAttr[rxAttrIdx + 0];
      final cellBg = backAttr[rxAttrIdx + 1];
      final cellMod = backAttr[rxAttrIdx + 2];
      final cellUlColor = backBuffer.getUnderlineColor(rx, y);
      final cellUri = backBuffer.getUri(rx, y);
      final cellTextSizing = hasTextSizing
          ? backBuffer.getTextSizing(rx, y)
          : KittyTextSizing.none;
      final backCode = backCodes[rxIdx];
      final char = backCells.decodeCode(backCode);

      _syncFrontCell(
        rx,
        y,
        rxIdx,
        rxAttrIdx,
        backCode,
        char,
        cellFg,
        cellBg,
        cellMod,
        cellUlColor,
        cellUri,
        cellTextSizing,
      );
      if (KittyTextSizing(cellTextSizing).isContinuation) continue;

      runCursorX = _positionCursorForCell(out, state, runCursorX, rx, y);

      if (cellUri != state.activeUri) {
        out.write('\x1b]8;;${sanitizeOsc8Uri(cellUri ?? '')}\x1b\\');
        state.activeUri = cellUri;
      }

      _writeStyleTransitionPrims(
        out,
        state.activeFg,
        state.activeBg,
        state.activeMod,
        state.activeUlColor,
        cellFg,
        cellBg,
        cellMod,
        cellUlColor,
      );
      state.activeFg = cellFg;
      state.activeBg = cellBg;
      state.activeMod = cellMod;
      state.activeUlColor = cellUlColor;

      runCursorX = _emitCellGlyph(
        out,
        state,
        runCursorX,
        rx,
        backBuffer.width,
        char,
        cellTextSizing,
      );
    }

    if (state.activeUri != null) {
      out.write('\x1b]8;;\x1b\\');
      state.activeUri = null;
    }
  }

  int _positionCursorForCell(
    StringSink out,
    _RenderCursorState state,
    int runCursorX,
    int rx,
    int y,
  ) {
    if (mode == RenderingMode.inline) {
      if (state.cursorY != y || state.cursorX != rx) {
        _moveCursorRelative(out, state.cursorX, state.cursorY, rx, y);
        state.cursorX = rx;
        state.cursorY = y;
      }
      return rx;
    }
    if (runCursorX != rx) {
      out.write('\x1b[${y + 1};${rx + 1}H');
    }
    return rx;
  }

  int _emitCellGlyph(
    StringSink out,
    _RenderCursorState state,
    int runCursorX,
    int rx,
    int bufferWidth,
    String char,
    int cellTextSizing,
  ) {
    final ts = KittyTextSizing(cellTextSizing);
    if (ts.isAnchor) {
      final sanitized = sanitizeOsc8Uri(char);
      final payload = sanitized.isEmpty ? ' ' : sanitized;
      _writeOsc66Sequence(out, ts, payload);
      final advance = _osc66Advance(ts, payload, rx, bufferWidth);
      if (mode == RenderingMode.inline) {
        state.cursorX += advance;
      }
      return runCursorX + advance;
    }
    out.write(char);
    if (mode == RenderingMode.inline) {
      state.cursorX++;
    }
    return runCursorX + 1;
  }

  static void _writeOsc66Sequence(
    StringSink out,
    KittyTextSizing ts,
    String payload,
  ) {
    out
      ..write('\x1b]66;s=')
      ..write(ts.scale);
    if (ts.explicitWidth > 0) {
      out
        ..write(':w=')
        ..write(ts.explicitWidth);
    }
    if (ts.numerator > 0 && ts.denominator > ts.numerator) {
      out
        ..write(':n=')
        ..write(ts.numerator)
        ..write(':d=')
        ..write(ts.denominator);
    }
    if (ts.vAlign != 0) {
      out
        ..write(':v=')
        ..write(ts.vAlign);
    }
    if (ts.hAlign != 0) {
      out
        ..write(':h=')
        ..write(ts.hAlign);
    }
    out
      ..write(';')
      ..write(payload)
      ..write('\x1b\\');
  }

  static int _osc66Advance(
    KittyTextSizing ts,
    String payload,
    int x,
    int bufferWidth,
  ) {
    final baseWidth = ts.explicitWidth > 0
        ? ts.explicitWidth
        : (isWideGrapheme(payload) ? 2 : 1);
    final scaled = ts.scale * baseWidth;
    final remaining = bufferWidth - x;
    return scaled < remaining ? scaled : remaining;
  }

  void _moveCursorRelative(
    StringSink out,
    int fromX,
    int fromY,
    int toX,
    int toY,
  ) {
    if (fromY == toY && fromX == toX) return;

    var currentX = fromX;

    final dy = toY - fromY;
    if (dy > 0) {
      for (var i = 0; i < dy; i++) {
        out.write('\n\r');
      }
      currentX = 0;
    } else if (dy < 0) {
      out.write('\x1b[${-dy}A');
    }

    if (toX == 0 && currentX > 0) {
      out.write('\r');
    } else {
      final dx = toX - currentX;
      if (dx > 0) {
        out.write('\x1b[${dx}C');
      } else if (dx < 0) {
        out.write('\x1b[${-dx}D');
      }
    }
  }

  void _appendRgbSgr(StringBuffer sb, int code, int argb) {
    if (argb.isAnsiIndexed && (code == 38 || code == 48)) {
      sb
        ..write(argb.ansiSgrParams(background: code == 48))
        ..write(';');
      return;
    }
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    sb.write('$code;2;$r;$g;$b;');
  }

  void _appendAddedModifiers(StringBuffer sb, int addedMods, int tgtMod) {
    if ((addedMods & Modifier.bold) != 0) sb.write('1;');
    if ((addedMods & Modifier.dim) != 0) sb.write('2;');
    if ((addedMods & Modifier.italic) != 0) sb.write('3;');
    if ((addedMods & (Modifier.underline | Modifier.underlineStyleMask)) != 0 &&
        Modifier.getUnderlineStyle(tgtMod) == UnderlineStyle.single) {
      sb.write('4;');
    }
    if ((addedMods & Modifier.blink) != 0) sb.write('5;');
    if ((addedMods & Modifier.reverse) != 0) sb.write('7;');
    if ((addedMods & Modifier.hidden) != 0) sb.write('8;');
    if ((addedMods & Modifier.crossedOut) != 0) sb.write('9;');
    if ((addedMods & Modifier.overline) != 0) sb.write('53;');
  }

  void _emitColonUnderlineSequences(
    StringSink out,
    int effectiveUlColor,
    int tgtUlColor,
    int addedMods,
    int tgtMod,
  ) {
    if ((addedMods & (Modifier.underline | Modifier.underlineStyleMask)) != 0) {
      final ulCode = switch (Modifier.getUnderlineStyle(tgtMod)) {
        UnderlineStyle.none || UnderlineStyle.single => null,
        UnderlineStyle.doubleLine => '4:2',
        UnderlineStyle.curly => '4:3',
        UnderlineStyle.dotted => '4:4',
        UnderlineStyle.dashed => '4:5',
      };
      if (ulCode != null) out.write('\x1b[${ulCode}m');
    }
    if (tgtUlColor != effectiveUlColor && tgtUlColor != 0) {
      if (tgtUlColor.isAnsiIndexed) {
        out.write('\x1b[58:5:${tgtUlColor.ansiIndex}m');
        return;
      }
      final r = (tgtUlColor >> 16) & 0xFF;
      final g = (tgtUlColor >> 8) & 0xFF;
      final b = tgtUlColor & 0xFF;
      out.write('\x1b[58:2::$r:$g:${b}m');
    }
  }

  bool _shouldResetStyle(
    int curFg,
    int curBg,
    int curMod,
    int curUlColor,
    int tgtFg,
    int tgtBg,
    int tgtMod,
    int tgtUlColor,
  ) {
    final colorCleared =
        (curFg != 0 && tgtFg == 0) ||
        (curBg != 0 && tgtBg == 0) ||
        (curUlColor != 0 && tgtUlColor == 0);
    return colorCleared || (curMod & ~tgtMod) != 0;
  }

  void _appendColorTransitions(
    StringBuffer sb,
    int effectiveFg,
    int effectiveBg,
    int tgtFg,
    int tgtBg,
  ) {
    if (tgtFg != effectiveFg && tgtFg != 0) _appendRgbSgr(sb, 38, tgtFg);
    if (tgtBg != effectiveBg && tgtBg != 0) _appendRgbSgr(sb, 48, tgtBg);
  }

  /// Writes the ANSI style transitions between the current style state and the target state.
  void _writeStyleTransitionPrims(
    StringSink out,
    int curFg,
    int curBg,
    int curMod,
    int curUlColor,
    int tgtFg,
    int tgtBg,
    int tgtMod,
    int tgtUlColor,
  ) {
    if (curFg == tgtFg &&
        curBg == tgtBg &&
        curMod == tgtMod &&
        curUlColor == tgtUlColor) {
      return;
    }

    if ((tgtFg | tgtBg | tgtMod | tgtUlColor) == 0) {
      out.write('\x1b[0m');
      return;
    }

    var effectiveFg = curFg;
    var effectiveBg = curBg;
    var effectiveMod = curMod;
    var effectiveUlColor = curUlColor;
    if (_shouldResetStyle(
      curFg,
      curBg,
      curMod,
      curUlColor,
      tgtFg,
      tgtBg,
      tgtMod,
      tgtUlColor,
    )) {
      out.write('\x1b[0m');
      effectiveFg = 0;
      effectiveBg = 0;
      effectiveMod = 0;
      effectiveUlColor = 0;
    }

    final sb = StringBuffer();
    _appendColorTransitions(sb, effectiveFg, effectiveBg, tgtFg, tgtBg);

    final addedMods = tgtMod & ~effectiveMod;
    if (addedMods != 0) _appendAddedModifiers(sb, addedMods, tgtMod);

    final s = sb.toString();
    if (s.isNotEmpty) {
      out.write('\x1b[${s.substring(0, s.length - 1)}m');
    }

    _emitColonUnderlineSequences(
      out,
      effectiveUlColor,
      tgtUlColor,
      addedMods,
      tgtMod,
    );
  }

  void _emitShaderMetadataDiff(Buffer backBuffer, StringSink out) {
    final caps = _shaderCapabilities;
    if (caps == null || !caps.isAnySupported) return;
    if (caps.region) {
      _diffShaderRegions(backBuffer, caps, out);
    }
    if (caps.xform) {
      _diffCellTransforms(backBuffer, out);
    }
  }

  void _diffShaderRegions(
    Buffer backBuffer,
    ShaderCapabilitiesEvent caps,
    StringSink out,
  ) {
    final nextRegions = _collectAllowedRegions(backBuffer, caps);
    _emitRemovedRegions(nextRegions, out);
    for (final entry in nextRegions.entries) {
      final region = entry.value;
      if (caps.glsl) {
        _ensureGlslUploaded(region.shaderRef, caps.maxSlots, out);
      }
      if (_emittedShaderRegions[entry.key] != region) {
        out.write(ShaderApcEncoder.encodeRegion(region));
      }
    }
    _emittedShaderRegions
      ..clear()
      ..addAll(nextRegions);
  }

  static Map<String, ShaderRegion> _collectAllowedRegions(
    Buffer backBuffer,
    ShaderCapabilitiesEvent caps,
  ) {
    final next = <String, ShaderRegion>{};
    if (caps.maxRegions <= 0) return next;
    for (final region in backBuffer.shaderRegions) {
      if (!caps.glsl && region.shaderRef is CustomGlslShaderRef) continue;
      if (!next.containsKey(region.id) && next.length >= caps.maxRegions) {
        continue;
      }
      next[region.id] = region;
    }
    return next;
  }

  void _emitRemovedRegions(
    Map<String, ShaderRegion> nextRegions,
    StringSink out,
  ) {
    if (nextRegions.isEmpty && _emittedShaderRegions.length > 1) {
      out.write(ShaderApcEncoder.encodeReset(target: 'regions'));
      return;
    }
    for (final id in _emittedShaderRegions.keys) {
      if (!nextRegions.containsKey(id)) {
        out.write(ShaderApcEncoder.encodeRemoveRegion(id));
      }
    }
  }

  void _ensureGlslUploaded(ShaderRef? ref, int maxSlots, StringSink out) {
    if (ref is! CustomGlslShaderRef) return;
    if (maxSlots <= 0) return;
    if (!_uploadedGlslHashes.containsKey(ref.id) &&
        _uploadedGlslHashes.length >= maxSlots) {
      return;
    }
    final hash = _GlslContentHash.compute(ref.source, persist: ref.persist);
    if (_uploadedGlslHashes[ref.id] == hash) return;
    try {
      final frames = ShaderApcEncoder.encodeDefine(
        id: ref.id,
        glslSource: ref.source,
        persist: ref.persist,
      );
      for (final frame in frames) {
        out.write(frame);
      }
      _uploadedGlslHashes[ref.id] = hash;
    } on ArgumentError {
      // Skip invalid or oversized custom GLSL source without disrupting render.
    }
  }

  void _diffCellTransforms(Buffer backBuffer, StringSink out) {
    final width = backBuffer.width;
    if (width <= 0) return;
    final backTable = backBuffer.cellTransforms;
    if (backTable == null || backTable.isEmpty) {
      _clearEmittedCellTransforms(width, out);
      return;
    }
    final changes = _collectTransformChanges(backTable, width);
    if (changes.isEmpty) return;
    if (changes.length == 1) {
      final c = changes.first;
      out.write(
        ShaderApcEncoder.encodeTransform(
          col: c.col,
          row: c.row,
          transform: c.transform,
        ),
      );
    } else {
      for (final frame in ShaderApcEncoder.encodeTransformsBatch(changes)) {
        out.write(frame);
      }
    }
    _emittedCellTransforms.clear();
    for (final entry in backTable.entries) {
      _emittedCellTransforms[entry.key] = entry.value;
    }
  }

  void _clearEmittedCellTransforms(int width, StringSink out) {
    if (_emittedCellTransforms.isEmpty) return;
    if (_emittedCellTransforms.length == 1) {
      final idx = _emittedCellTransforms.keys.first;
      out.write(
        ShaderApcEncoder.encodeTransform(
          col: idx % width,
          row: idx ~/ width,
          transform: null,
        ),
      );
    } else {
      out.write(ShaderApcEncoder.encodeReset(target: 'xforms'));
    }
    _emittedCellTransforms.clear();
  }

  List<CellTransformEntry> _collectTransformChanges(
    CellTransformTable backTable,
    int width,
  ) => <CellTransformEntry>[
    for (final idx in _emittedCellTransforms.keys)
      if (backTable[idx] == null)
        (col: idx % width, row: idx ~/ width, transform: null),
    for (final entry in backTable.entries)
      if (_emittedCellTransforms[entry.key] != entry.value)
        (
          col: entry.key % width,
          row: entry.key ~/ width,
          transform: entry.value,
        ),
  ];

  void _syncFrontShaderMetadata(Buffer backBuffer) {
    _frontBuffer.shaderRegions
      ..clear()
      ..addAll(backBuffer.shaderRegions);
    _frontBuffer.clearCellTransforms();
    final table = backBuffer.cellTransforms;
    if (table == null || table.isEmpty) return;
    for (final entry in table.entries) {
      _frontBuffer.setCellTransformAt(entry.key, entry.value);
    }
  }
}

final class _GlslContentHash {
  final int fnv1a;
  final int djb2;
  final int length;
  final bool persist;

  const _GlslContentHash(this.fnv1a, this.djb2, this.length, this.persist);

  factory _GlslContentHash.compute(String source, {required bool persist}) {
    var fnv = 0x811C9DC5;
    var djb = 5381;
    for (var i = 0; i < source.length; i++) {
      final cu = source.codeUnitAt(i);
      fnv ^= cu;
      fnv = (fnv * 0x01000193) & 0xFFFFFFFF;
      djb = (((djb << 5) + djb) ^ cu) & 0xFFFFFFFF;
    }
    return _GlslContentHash(fnv, djb, source.length, persist);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _GlslContentHash &&
          other.fnv1a == fnv1a &&
          other.djb2 == djb2 &&
          other.length == length &&
          other.persist == persist;

  @override
  int get hashCode => Object.hash(fnv1a, djb2, length, persist);
}

final class _RenderCursorState {
  int activeFg = 0;
  int activeBg = 0;
  int activeMod = 0;
  int activeUlColor = 0;
  String? activeUri;
  int cursorX = 0;
  int cursorY = 0;

  bool get hasActiveStyle =>
      activeFg != 0 || activeBg != 0 || activeMod != 0 || activeUlColor != 0;
}
