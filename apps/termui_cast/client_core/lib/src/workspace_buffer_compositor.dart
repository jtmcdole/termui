import 'dart:math';
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:termui/termui.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';

import 'models.dart';
import 'scrollback_page_cache.dart';
import 'session_slot.dart';
import 'terminal_theme_settings.dart';

/// Pure compositing and virtual-line lookup helpers for rendering a [SessionSlot]
/// viewport with scrollback rows, selection/link highlights, cursor, and scrollbar.
abstract final class WorkspaceBufferCompositor {
  static final int _traceCompose = Tracer.registerString(
    'WorkspaceBufferCompositor.compose',
  );
  static final RegExp _controlChars = RegExp(r'[\x00-\x1F\x7F-\x9F]');
  static final TerminalColorResolver _defaultDarkResolver =
      TerminalColorResolver(
        theme: TerminalColorTheme.termuiDark,
        settings: const TerminalThemeSettings(),
      );
  static const int _boxSelectionBg = 0xFF3E2C5E;
  static const int _hoveredLinkBg = 0xFF1B263B;
  static const double _rainbowCycleMs = 1200.0;
  static const double _rainbowCellStepDegrees = 18.0;

  /// Animation cadence matching the Rainbow Road hover wave.
  static const Duration rainbowHoverTickInterval = Duration(milliseconds: 40);
  static const int _scrollThumbFg = 0xFF62D196;
  static const Style _hiddenNoticeStyle = Style(
    foreground: Color(20, 24, 32),
    background: Color(235, 185, 78),
    modifiers: Modifier.bold,
  );

  /// Strips C0/C1 control characters, trims, and truncates [raw] to [maxChars].
  static String sanitizeNotice(String raw, int maxChars, String fallback) {
    final cleaned = raw.replaceAll(_controlChars, '').trim();
    return cleaned.isEmpty
        ? fallback
        : cleaned.characters.take(maxChars).string;
  }

  /// Looks up virtual row [virtualY] across cached scrollback and [liveBuffer].
  static VirtualLineSlice? lookupVirtualLine(
    SessionSlot slot,
    Buffer liveBuffer,
    int virtualY,
  ) {
    final totalLines = slot.scrollbackCache.totalLines;
    if (virtualY < totalLines) {
      final sbRow = slot.scrollbackCache.rowAt(virtualY);
      if (sbRow == null) {
        return (isWrapped: false, characters: const <String>[], uris: null);
      }
      return (
        isWrapped: sbRow.isWrapped,
        characters: sbRow.characters,
        uris: sbRow.expandUris(),
      );
    }
    final liveY = virtualY - totalLines;
    if (liveY < 0 || liveY >= liveBuffer.height) return null;
    final start = liveY * liveBuffer.width;
    final end = start + liveBuffer.width;
    return (
      isWrapped: slot.isLiveRowWrapped(liveY),
      characters: liveBuffer.characters.sublist(start, end),
      uris: liveBuffer.sliceUris(start, end),
    );
  }

  /// Materializes the visible PTY cells for [slot] without cursor/highlight overlays
  /// so split-pane divider detection operates on the exact visible viewport.
  static Buffer? composeViewportCells(SessionSlot? slot) {
    final src = slot?.buffer;
    if (slot == null || src == null) return null;
    if (slot.scrollOffsetLines == 0 && slot.scrollOffsetCols == 0) {
      return src;
    }
    final out = Buffer.blank(src.width, src.height)
      ..registerSelectableRegion(Rect(0, 0, src.width, src.height));
    _populateComposedRows(
      out,
      slot,
      src,
      slot.topVirtualRow,
      _defaultDarkResolver,
    );
    return out;
  }

  /// Matches an `http://` or `https://` URL at 0-based viewport cell `(col, row)`.
  static MatchedTerminalUrl? matchUrlAtCell(
    SessionSlot? slot,
    int col,
    int row,
  ) {
    final buffer = slot?.buffer;
    if (slot == null ||
        buffer == null ||
        col < 0 ||
        row < 0 ||
        col >= buffer.width ||
        row >= buffer.height) {
      return null;
    }
    final virtualX = slot.scrollOffsetCols + col;
    final virtualY = slot.topVirtualRow + row;
    return TerminalSelection.matchUrlAt(
      (y) => lookupVirtualLine(slot, buffer, y),
      virtualX: virtualX,
      virtualY: virtualY,
      cols: buffer.width,
    );
  }

  /// Extracts selected text from [slot] for [selection], or `''` if unhydrated.
  static String extractSelectionText(
    SessionSlot slot,
    TerminalSelection selection,
  ) {
    final buffer = slot.buffer;
    if (buffer == null || selection.isCollapsed) return '';
    return selection.extractVirtualText(
      (virtualY) => lookupVirtualLine(slot, buffer, virtualY),
      cols: buffer.width,
    );
  }

  /// Composites a fresh [Buffer] for the active [slot] viewport.
  static Buffer compose({
    required SessionSlot? slot,
    required int viewportCols,
    required int viewportRows,
    required MatchedTerminalUrl? hoveredLink,
    required TerminalSelection? activeSelection,
    TerminalColorTheme theme = TerminalColorTheme.termuiDark,
    TerminalThemeSettings themeSettings = const TerminalThemeSettings(),
    TerminalColorResolver? colorResolver,
    required int nowMs,
    required String? hiddenClipboardNotice,
  }) {
    Tracer.record(_traceCompose, Phase.begin, TraceCategory.compositor);
    try {
      final src = slot?.buffer;
      if (src == null) {
        final blank = Buffer.blank(viewportCols, viewportRows);
        _paintHiddenNoticeIfNeeded(blank, hiddenClipboardNotice);
        return blank;
      }
      final out = Buffer.blank(src.width, src.height)
        ..registerKittyRegistry(
          Rect(0, 0, src.width, src.height),
          slot!.kittyRegistry,
        )
        ..registerSelectableRegion(Rect(0, 0, src.width, src.height));
      final topVirtualRow = slot.topVirtualRow;
      final resolver =
          colorResolver ??
          (identical(theme, TerminalColorTheme.termuiDark) &&
                  themeSettings == const TerminalThemeSettings()
              ? _defaultDarkResolver
              : TerminalColorResolver(theme: theme, settings: themeSettings));
      final effectiveTheme = resolver.theme;
      _populateComposedRows(out, slot, src, topVirtualRow, resolver);

      if (hoveredLink != null) {
        _paintHoveredLink(
          out,
          hoveredLink.range,
          topVirtualRow: topVirtualRow,
          leftVirtualCol: slot.scrollOffsetCols,
          nowMs: nowMs,
        );
      }

      if (activeSelection != null && !activeSelection.isCollapsed) {
        _paintSelectionHighlight(
          out,
          activeSelection,
          theme: effectiveTheme,
          topVirtualRow: topVirtualRow,
          leftVirtualCol: slot.scrollOffsetCols,
        );
      }

      _paintCursorIfVisible(out, slot, topVirtualRow, resolver);
      if (slot.scrollOffsetLines > 0) {
        _paintScrollbarThumb(out, slot);
      }
      _paintHiddenNoticeIfNeeded(out, hiddenClipboardNotice);
      return out;
    } finally {
      Tracer.record(_traceCompose, Phase.end, TraceCategory.compositor);
    }
  }

  static void _populateComposedRows(
    Buffer out,
    SessionSlot slot,
    Buffer src,
    int topVirtualRow,
    TerminalColorResolver resolver,
  ) {
    final totalLines = slot.scrollbackCache.totalLines;
    final panCols = slot.scrollOffsetCols;
    for (var screenY = 0; screenY < out.height; screenY++) {
      final virtualY = topVirtualRow + screenY;
      if (virtualY < totalLines) {
        final sbRow = slot.scrollbackCache.rowAt(virtualY);
        if (sbRow != null) {
          _copyScrollbackRowSlice(out, screenY, sbRow, panCols, resolver);
        }
      } else {
        final liveY = virtualY - totalLines;
        if (liveY >= 0 && liveY < src.height) {
          _copyLiveRowSlice(out, screenY, src, liveY, panCols, resolver);
        }
      }
    }
  }

  static void _copyLiveRowSlice(
    Buffer out,
    int screenY,
    Buffer src,
    int liveY,
    int panCols,
    TerminalColorResolver resolver,
  ) {
    final copyCols = _copyRowCells(
      out: out,
      screenY: screenY,
      rowChars: src.characters,
      rowAttrs: src.attributes,
      rowStartCell: liveY * src.width,
      rowLength: src.width,
      panCols: panCols,
      resolver: resolver,
    );
    if (copyCols <= 0) return;
    final outOffset = screenY * out.width;
    final srcOffset = liveY * src.width + panCols;
    out.copyCellAuxRangeFrom(src, outOffset, srcOffset, copyCols);
    _healRowEdgesIfNeeded(out, outOffset, panCols, copyCols);
  }

  static void _copyScrollbackRowSlice(
    Buffer out,
    int screenY,
    EncodedScrollbackRow sbRow,
    int panCols,
    TerminalColorResolver resolver,
  ) {
    final copyCols = _copyRowCells(
      out: out,
      screenY: screenY,
      rowChars: sbRow.characters,
      rowAttrs: sbRow.attributes,
      rowStartCell: 0,
      rowLength: sbRow.characters.length,
      panCols: panCols,
      resolver: resolver,
    );
    if (copyCols <= 0) return;
    final outOffset = screenY * out.width;
    _copyScrollbackAuxSlice(out, outOffset, copyCols, sbRow, panCols);
    _healRowEdgesIfNeeded(out, outOffset, panCols, copyCols);
  }

  static void _copyScrollbackAuxSlice(
    Buffer out,
    int outOffset,
    int copyCols,
    EncodedScrollbackRow sbRow,
    int panCols,
  ) {
    out.clearCellAuxRange(outOffset, outOffset + copyCols);
    if (sbRow.underlineColors case final ulMap?) {
      _copyScrollbackUnderlineSlice(out, outOffset, copyCols, ulMap, panCols);
    }
    if (sbRow.uriRuns case final runs?) {
      _copyScrollbackUriSlice(out, outOffset, copyCols, runs, panCols);
    }
  }

  static void _copyScrollbackUnderlineSlice(
    Buffer out,
    int outOffset,
    int copyCols,
    Map<int, int> ulMap,
    int panCols,
  ) {
    for (final entry in ulMap.entries) {
      final rel = entry.key - panCols;
      if (rel >= 0 && rel < copyCols && entry.value != 0) {
        out.setUnderlineColorAt(outOffset + rel, entry.value);
      }
    }
  }

  static void _copyScrollbackUriSlice(
    Buffer out,
    int outOffset,
    int copyCols,
    List<UriRun> runs,
    int panCols,
  ) {
    for (final run in runs) {
      final clean = clampOsc8Uri(run.uri);
      if (clean.isEmpty || run.length <= 0) continue;
      final relStart = max(0, run.start - panCols);
      final relEnd = min(copyCols, run.start + run.length - panCols);
      for (var rel = relStart; rel < relEnd; rel++) {
        out.setUriAt(outOffset + rel, clean);
      }
    }
  }

  static int _copyRowCells({
    required Buffer out,
    required int screenY,
    required List<String> rowChars,
    required Uint32List rowAttrs,
    required int rowStartCell,
    required int rowLength,
    required int panCols,
    required TerminalColorResolver resolver,
  }) {
    final width = out.width;
    if (width <= 0 || panCols >= rowLength) return 0;
    final copyCols = min(width, rowLength - panCols);
    final outOffset = screenY * width;
    final srcOffset = rowStartCell + panCols;
    out.characters.setRange(
      outOffset,
      outOffset + copyCols,
      rowChars,
      srcOffset,
    );
    final outAttrs = out.attributes;
    for (var col = 0; col < copyCols; col++) {
      final srcCell = srcOffset + col;
      final dstCell = outOffset + col;
      final srcAttrBase = srcCell * 3;
      resolver.resolveCellInto(
        rawFg: rowAttrs[srcAttrBase],
        rawBg: rowAttrs[srcAttrBase + 1],
        modifiers: rowAttrs[srcAttrBase + 2],
        grapheme: rowChars[srcCell],
        outAttributes: outAttrs,
        attrOffset: dstCell * 3,
      );
    }
    return copyCols;
  }

  static void _healRowEdgesIfNeeded(
    Buffer out,
    int outOffset,
    int panCols,
    int copyCols,
  ) {
    final width = out.width;
    if (panCols > 0 && out.characters[outOffset].isEmpty) {
      _healCellToBlank(out, outOffset);
    }
    if (copyCols == width &&
        graphemeWidth(out.characters[outOffset + width - 1]) > 1) {
      _healCellToBlank(out, outOffset + width - 1);
    }
  }

  static void _healCellToBlank(Buffer out, int cellIdx) {
    out.characters[cellIdx] = ' ';
    final attrBase = cellIdx * 3;
    out.attributes[attrBase] = 0;
    out.attributes[attrBase + 1] = 0;
    out.attributes[attrBase + 2] = 0;
    out.clearCellAuxRange(cellIdx, cellIdx + 1);
  }

  static void _paintCursorIfVisible(
    Buffer out,
    SessionSlot slot,
    int topVirtualRow,
    TerminalColorResolver resolver,
  ) {
    final cur = slot.cursor;
    if (!cur.visible) return;
    var cursorScreenX = cur.x - slot.scrollOffsetCols;
    final cursorScreenY =
        (slot.scrollbackCache.totalLines + cur.y) - topVirtualRow;
    if (cursorScreenX < 0 ||
        cursorScreenX >= out.width ||
        cursorScreenY < 0 ||
        cursorScreenY >= out.height) {
      return;
    }
    var cellIdx = cursorScreenY * out.width + cursorScreenX;
    if (out.characters[cellIdx].isEmpty &&
        cursorScreenX > 0 &&
        graphemeWidth(out.characters[cellIdx - 1]) > 1) {
      cursorScreenX -= 1;
      cellIdx -= 1;
    }
    final blankGlyph = switch (cur.shape) {
      .blinkingBar || .steadyBar => '▏',
      .blinkingUnderline || .steadyUnderline => '▁',
      .defaultShape || .blinkingBlock || .steadyBlock => null,
    };
    final isDefaultCursor = _usesDefaultInverseCursor(resolver);
    if (blankGlyph != null && out.characters[cellIdx] == ' ') {
      out.characters[cellIdx] = blankGlyph;
      if (!isDefaultCursor) {
        out.attributes[cellIdx * 3] = resolver.theme.cursorColor.argb;
      }
      out.attributes[cellIdx * 3 + 2] &= ~Modifier.transparent;
      return;
    }

    if (isDefaultCursor) {
      _invertCursorCell(out, cursorScreenX, cellIdx);
    } else {
      _paintThemedCursor(out, cursorScreenX, cellIdx, resolver);
    }
  }

  static bool _usesDefaultInverseCursor(TerminalColorResolver resolver) =>
      resolver.theme.id == 'termui_dark' &&
      resolver.settings.customOverrides.cursorColor == null;

  static void _paintThemedCursor(
    Buffer out,
    int cursorScreenX,
    int cellIdx,
    TerminalColorResolver resolver,
  ) {
    final cellBase = cellIdx * 3;
    var curFg = out.attributes[cellBase];
    var curBg = out.attributes[cellBase + 1];
    if (Modifier.has(out.attributes[cellBase + 2], Modifier.reverse)) {
      final visualBg = curFg == 0 ? resolver.theme.foreground.argb : curFg;
      final visualFg = curBg == 0 ? resolver.theme.background.argb : curBg;
      curFg = visualFg;
      curBg = visualBg;
    }
    final (cursorColor, cursorTextColor) = resolver.resolveCursorColors(
      cellFg: curFg,
      cellBg: curBg,
    );
    _writeThemedCursorCell(
      out.attributes,
      cellBase,
      cursorTextColor,
      cursorColor,
    );
    if (graphemeWidth(out.characters[cellIdx]) > 1 &&
        cursorScreenX + 1 < out.width) {
      _writeThemedCursorCell(
        out.attributes,
        (cellIdx + 1) * 3,
        cursorTextColor,
        cursorColor,
      );
    }
  }

  static void _writeThemedCursorCell(
    Uint32List attrs,
    int base,
    int fg,
    int bg,
  ) {
    attrs[base] = fg;
    attrs[base + 1] = bg;
    attrs[base + 2] =
        (attrs[base + 2] & ~Modifier.transparent) & ~Modifier.reverse;
  }

  static void _invertCursorCell(Buffer out, int cursorScreenX, int cellIdx) {
    final modIdx = cellIdx * 3 + 2;
    out.attributes[modIdx] =
        (out.attributes[modIdx] & ~Modifier.transparent) ^ Modifier.reverse;
    if (graphemeWidth(out.characters[cellIdx]) > 1 &&
        cursorScreenX + 1 < out.width) {
      final nextModIdx = (cellIdx + 1) * 3 + 2;
      out.attributes[nextModIdx] =
          (out.attributes[nextModIdx] & ~Modifier.transparent) ^
          Modifier.reverse;
    }
  }

  static void _paintScrollbarThumb(Buffer out, SessionSlot slot) {
    if (out.width < 2 || out.height < 1) return;
    final retained = max(slot.scrollOffsetLines, slot.maxScrollableLines);
    if (retained <= 0) return;
    final h = out.height;
    final thumbH = max(1, (h * h / (retained + h)).round()).clamp(1, h);
    final maxThumbTop = max(0, h - thumbH);
    final thumbTop =
        ((retained - slot.scrollOffsetLines) * maxThumbTop / max(1, retained))
            .round()
            .clamp(0, maxThumbTop);
    final x = out.width - 1;
    for (var y = thumbTop; y < thumbTop + thumbH; y++) {
      final cellIdx = y * out.width + x;
      if (out.characters[cellIdx].isEmpty ||
          graphemeWidth(out.characters[cellIdx - 1]) > 1) {
        _healCellToBlank(out, cellIdx - 1);
      }
      out.characters[cellIdx] = '▐';
      final attrIdx = cellIdx * 3;
      out.attributes[attrIdx] = _scrollThumbFg;
      out.attributes[attrIdx + 2] = Modifier.none;
      out.clearCellAuxRange(cellIdx, cellIdx + 1);
    }
  }

  static void _paintSelectionHighlight(
    Buffer out,
    TerminalSelection selection, {
    TerminalColorTheme theme = TerminalColorTheme.termuiDark,
    int topVirtualRow = 0,
    int leftVirtualCol = 0,
  }) {
    final spans = selection.visibleRowSpans(
      out,
      topVirtualRow: topVirtualRow,
      leftVirtualCol: leftVirtualCol,
    );
    if (spans.isEmpty) return;

    final isBoxMode = selection.mode == .box;
    final bg = isBoxMode ? _boxSelectionBg : theme.selectionBackground.argb;
    final explicitFg = _resolveSelectionFgForBg(
      theme.selectionForeground?.argb,
      bg,
      enforceAa: isBoxMode,
    );

    final outAttrs = out.attributes;
    for (final (y, colStart, colEnd) in spans) {
      final rowOffset = y * out.width;
      for (var x = colStart; x <= colEnd; x++) {
        _applySelectionToCell(
          outAttrs,
          (rowOffset + x) * 3,
          bg: bg,
          explicitFg: explicitFg,
          isBoxMode: isBoxMode,
          theme: theme,
        );
      }
    }
  }

  static int? _resolveSelectionFgForBg(
    int? explicitFg,
    int bg, {
    required bool enforceAa,
  }) {
    if (explicitFg == null) return null;
    final fgColor = Color.argb(explicitFg);
    final bgColor = Color.argb(bg);
    final minRatio = enforceAa ? 4.5 : 3.0;
    if (TerminalContrast.contrastRatio(fgColor, bgColor) >= minRatio) {
      return explicitFg;
    }
    final readable = TerminalContrast.ensureReadableTextOn(fgColor, bgColor);
    if (TerminalContrast.contrastRatio(readable, bgColor) >= minRatio) {
      return readable.argb;
    }
    return TerminalContrast.contrastRatio(Colors.white, bgColor) >=
            TerminalContrast.contrastRatio(Colors.black, bgColor)
        ? Colors.white.argb
        : Colors.black.argb;
  }

  static void _applySelectionToCell(
    Uint32List outAttrs,
    int cellBase, {
    required int bg,
    required int? explicitFg,
    required bool isBoxMode,
    required TerminalColorTheme theme,
  }) {
    final currentFg = outAttrs[cellBase];
    final currentMods = outAttrs[cellBase + 2];
    final hadReverse = Modifier.has(currentMods, Modifier.reverse);
    outAttrs[cellBase + 1] = bg;
    outAttrs[cellBase + 2] =
        (currentMods & ~Modifier.transparent) & ~Modifier.reverse;
    if (explicitFg != null) {
      outAttrs[cellBase] = explicitFg;
      return;
    }
    if (!hadReverse && !isBoxMode) return;
    final fgColor = currentFg == 0 ? theme.foreground : Color.argb(currentFg);
    if (hadReverse ||
        TerminalContrast.contrastRatio(fgColor, Color.argb(bg)) < 4.5) {
      outAttrs[cellBase] =
          _resolveSelectionFgForBg(fgColor.argb, bg, enforceAa: isBoxMode) ??
          fgColor.argb;
    }
  }

  /// Dark pill background color applied under Rainbow Road hovered links.
  static const int rainbowLinkBackgroundArgb = _hoveredLinkBg;

  /// Modifiers (`bold | underline`) applied to Rainbow Road hovered links.
  static const int rainbowLinkModifiers = Modifier.underline | Modifier.bold;

  /// Computes the Rainbow Road wave phase in `[0.0, 360.0)` degrees for epoch
  /// millisecond [nowMs].
  static double rainbowPhaseHueAt(int nowMs) =>
      (nowMs % _rainbowCycleMs) / _rainbowCycleMs * 360.0;

  /// Computes the Rainbow Road foreground ARGB color for cell [cellIndex]
  /// given a precomputed [phaseHue] in degrees.
  static int rainbowLinkForegroundAtPhase(int cellIndex, double phaseHue) =>
      _rainbowArgb(phaseHue - cellIndex * _rainbowCellStepDegrees);

  /// Computes the Rainbow Road foreground ARGB color for cell [cellIndex]
  /// within a hovered link at epoch millisecond [nowMs].
  static int rainbowLinkForegroundAt(int cellIndex, int nowMs) =>
      rainbowLinkForegroundAtPhase(cellIndex, rainbowPhaseHueAt(nowMs));

  static void _paintHoveredLink(
    Buffer out,
    TerminalSelection range, {
    required int topVirtualRow,
    required int leftVirtualCol,
    required int nowMs,
  }) {
    final phaseHue = rainbowPhaseHueAt(nowMs);
    range.paint(
      out,
      topVirtualRow: topVirtualRow,
      leftVirtualCol: leftVirtualCol,
      background: rainbowLinkBackgroundArgb,
      modifiers: rainbowLinkModifiers,
      foregroundAt: (index, _) => rainbowLinkForegroundAtPhase(index, phaseHue),
    );
  }

  static int _rainbowArgb(double hueDegrees) {
    final h = ((hueDegrees % 360.0) + 360.0) % 360.0 / 60.0;
    const c = 0.85;
    const m = 1.0 - c;
    final x = c * (1.0 - (h % 2.0 - 1.0).abs());
    final double r;
    final double g;
    final double b;
    switch (h.floor()) {
      case 0:
        r = c;
        g = x;
        b = 0.0;
      case 1:
        r = x;
        g = c;
        b = 0.0;
      case 2:
        r = 0.0;
        g = c;
        b = x;
      case 3:
        r = 0.0;
        g = x;
        b = c;
      case 4:
        r = x;
        g = 0.0;
        b = c;
      default:
        r = c;
        g = 0.0;
        b = x;
    }
    final ri = ((r + m) * 255.0).round().clamp(0, 255);
    final gi = ((g + m) * 255.0).round().clamp(0, 255);
    final bi = ((b + m) * 255.0).round().clamp(0, 255);
    return 0xFF000000 | (ri << 16) | (gi << 8) | bi;
  }

  static void _paintHiddenNoticeIfNeeded(Buffer out, String? notice) {
    if (notice == null || out.width <= 0 || out.height <= 0) {
      return;
    }
    out.clearCellAuxRange(0, out.width);
    out.writeString(
      0,
      0,
      _clipAndPadWidth(notice.replaceAll(_controlChars, ''), out.width),
      _hiddenNoticeStyle,
    );
  }

  static String _clipAndPadWidth(String value, int targetCols) {
    final sb = StringBuffer();
    var usedCols = 0;
    for (final grapheme in value.characters) {
      final w = graphemeWidth(grapheme);
      if (w <= 0) continue;
      if (usedCols + w > targetCols) break;
      sb.write(grapheme);
      usedCols += w;
    }
    if (usedCols >= targetCols) return '$sb';
    return '$sb${' ' * (targetCols - usedCols)}';
  }
}
