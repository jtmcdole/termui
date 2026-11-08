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

  /// Creates a renderer with an initial screen size.
  Renderer(int width, int height, {this.mode = RenderingMode.alternateScreen})
    : _frontBuffer = Buffer(width, height);

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
    if (backBuffer.characters[idx] != _frontBuffer.characters[idx] ||
        backAttr[attrIdx + 0] != frontAttr[attrIdx + 0] ||
        backAttr[attrIdx + 1] != frontAttr[attrIdx + 1] ||
        backAttr[attrIdx + 2] != frontAttr[attrIdx + 2]) {
      return true;
    }
    if (!backBuffer.hasUnderlineColors && !_frontBuffer.hasUnderlineColors) {
      return false;
    }
    return backBuffer.getUnderlineColor(x, y) !=
        _frontBuffer.getUnderlineColor(x, y);
  }

  void _emitPendingKittyImages(Buffer backBuffer, StringSink out) {
    final attrs = backBuffer.attributes;
    final chars = backBuffer.characters;
    final width = backBuffer.width;
    if (width <= 0) return;
    final cellCount = chars.length;
    for (var cellIdx = 0; cellIdx < cellCount; cellIdx++) {
      final attrIdx = cellIdx * 3;
      if ((attrs[attrIdx + 2] & Modifier.kittyPlaceholder) == 0) continue;
      final imageId = _extractKittyImageId(chars[cellIdx], attrs[attrIdx]);
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
    String char,
    int cellFg,
    int cellBg,
    int cellMod,
    int cellUlColor,
  ) {
    _frontBuffer.characters[rxIdx] = char;
    final frontAttr = _frontBuffer.attributes;
    frontAttr[rxAttrIdx + 0] = cellFg;
    frontAttr[rxAttrIdx + 1] = cellBg;
    frontAttr[rxAttrIdx + 2] = cellMod;
    if (cellUlColor != 0 || _frontBuffer.hasUnderlineColors) {
      _frontBuffer.setUnderlineColor(rx, y, cellUlColor);
    }
  }

  /// Diffs [backBuffer] against [_frontBuffer] and writes minimal ANSI escape sequences to [out].
  void render(Buffer backBuffer, StringSink out) {
    Tracer.record(_traceRenderId, Phase.begin, TraceCategory.paint);
    try {
      final sizeChanged = _prepareFrame(backBuffer, out);
      if (sizeChanged) _uploadedKittyImages.clear();
      _emitPendingKittyImages(backBuffer, out);

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
    if (mode == RenderingMode.inline) {
      _moveCursorRelative(out, state.cursorX, state.cursorY, runStart, y);
      state.cursorX = runStart;
      state.cursorY = y;
    } else {
      out.write('\x1b[${y + 1};${runStart + 1}H');
    }

    final backChars = backBuffer.characters;
    final backAttr = backBuffer.attributes;

    for (var rx = runStart; rx < runEnd; rx++) {
      final rxIdx = rowOffset + rx;
      final rxAttrIdx = rxIdx * 3;
      final cellFg = backAttr[rxAttrIdx + 0];
      final cellBg = backAttr[rxAttrIdx + 1];
      final cellMod = backAttr[rxAttrIdx + 2];
      final cellUlColor = backBuffer.getUnderlineColor(rx, y);

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

      final char = backChars[rxIdx];
      out.write(char);
      _syncFrontCell(
        rx,
        y,
        rxIdx,
        rxAttrIdx,
        char,
        cellFg,
        cellBg,
        cellMod,
        cellUlColor,
      );

      if (mode == RenderingMode.inline) {
        state.cursorX++;
      }
    }
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
        Modifier.has(tgtMod, Modifier.underline)) {
      final ulStyle = Modifier.getUnderlineStyle(tgtMod);
      final ulCode = switch (ulStyle) {
        UnderlineStyle.none || UnderlineStyle.single => '4',
        UnderlineStyle.doubleLine => '4:2',
        UnderlineStyle.curly => '4:3',
        UnderlineStyle.dotted => '4:4',
        UnderlineStyle.dashed => '4:5',
      };
      sb.write('$ulCode;');
    }
    if ((addedMods & Modifier.blink) != 0) sb.write('5;');
    if ((addedMods & Modifier.reverse) != 0) sb.write('7;');
    if ((addedMods & Modifier.hidden) != 0) sb.write('8;');
    if ((addedMods & Modifier.crossedOut) != 0) sb.write('9;');
    if ((addedMods & Modifier.overline) != 0) sb.write('53;');
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
    int effectiveUlColor,
    int tgtFg,
    int tgtBg,
    int tgtUlColor,
  ) {
    if (tgtFg != effectiveFg && tgtFg != 0) _appendRgbSgr(sb, 38, tgtFg);
    if (tgtBg != effectiveBg && tgtBg != 0) _appendRgbSgr(sb, 48, tgtBg);
    if (tgtUlColor != effectiveUlColor && tgtUlColor != 0) {
      _appendRgbSgr(sb, 58, tgtUlColor);
    }
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
    _appendColorTransitions(
      sb,
      effectiveFg,
      effectiveBg,
      effectiveUlColor,
      tgtFg,
      tgtBg,
      tgtUlColor,
    );

    final addedMods = tgtMod & ~effectiveMod;
    if (addedMods != 0) _appendAddedModifiers(sb, addedMods, tgtMod);

    final s = sb.toString();
    if (s.isNotEmpty) {
      out.write('\x1b[${s.substring(0, s.length - 1)}m');
    }
  }
}

final class _RenderCursorState {
  int activeFg = 0;
  int activeBg = 0;
  int activeMod = 0;
  int activeUlColor = 0;
  int cursorX = 0;
  int cursorY = 0;

  bool get hasActiveStyle =>
      activeFg != 0 || activeBg != 0 || activeMod != 0 || activeUlColor != 0;
}
