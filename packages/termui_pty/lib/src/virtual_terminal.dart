import 'dart:convert';
import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:termui/termui.dart';

import 'ansi_parser.dart';
import 'scrollback_buffer.dart';

/// Cursor visual style selected by `DECSCUSR` (`CSI Ps SP q`).
enum TerminalCursorShape {
  /// Terminal default cursor style (`Ps = 0`).
  defaultShape,

  /// Blinking block cursor (`Ps = 1`).
  blinkingBlock,

  /// Steady block cursor (`Ps = 2`).
  steadyBlock,

  /// Blinking underline cursor (`Ps = 3`).
  blinkingUnderline,

  /// Steady underline cursor (`Ps = 4`).
  steadyUnderline,

  /// Blinking vertical bar cursor (`Ps = 5`).
  blinkingBar,

  /// Steady vertical bar cursor (`Ps = 6`).
  steadyBar,
}

typedef _SavedCursor = ({
  int x,
  int y,
  Style style,
  bool pendingWrap,
  bool originMode,
  bool g0DecGraphics,
  bool g1DecGraphics,
  bool useG1,
});

/// A virtual terminal that maintains primary and alternate screen buffers,
/// cursor state, scroll margins, and terminal modes in response to ANSI/VT100
/// escape sequences.
final class VirtualTerminal implements TerminalHandler {
  static const List<int> _ansi16Rgb = [
    0x000000,
    0xAA0000,
    0x00AA00,
    0xAAAA00,
    0x0000AA,
    0xAA00AA,
    0x00AAAA,
    0xAAAAAA,
    0x555555,
    0xFF5555,
    0x55FF55,
    0xFFFF55,
    0x5555FF,
    0xFF55FF,
    0x55FFFF,
    0xFFFFFF,
  ];

  static const _SavedCursor _initialSavedCursor = (
    x: 0,
    y: 0,
    style: .empty,
    pendingWrap: false,
    originMode: false,
    g0DecGraphics: false,
    g1DecGraphics: false,
    useG1: false,
  );

  static const List<String> _decSpecialGraphics = [
    ' ',
    '◆',
    '▒',
    '␉',
    '␌',
    '␍',
    '␊',
    '°',
    '±',
    '␤',
    '␋',
    '┘',
    '┐',
    '┌',
    '└',
    '┼',
    '⎺',
    '⎻',
    '─',
    '⎼',
    '⎽',
    '├',
    '┤',
    '┴',
    '┬',
    '│',
    '≤',
    '≥',
    'π',
    '≠',
    '£',
    '·',
  ];

  static final RegExp _whitespaceRegex = RegExp(r'\s+');
  static const int _maxOsc52PayloadLength = 1_400_000;
  static const int _maxOsc52DecodedBytes = 1_048_576;

  /// The width of the virtual terminal in columns.
  int width;

  /// The height of the virtual terminal in rows.
  int height;

  final Buffer _primaryBuffer;
  final ScrollbackBuffer _scrollback;
  List<bool> _primaryWrapped;
  bool _wrappingNextIndexDown = false;
  Buffer? _altBuffer;
  bool _usingAltScreen = false;

  /// Primary-screen scrollback ring buffer (`maxLines == 0` disables retention).
  ScrollbackBuffer get scrollback => _scrollback;

  /// Returns whether visible row [row] (`0 <= row < height`) began via
  /// right-margin auto-wrap from the preceding row (`scrollback[totalLines - 1]`
  /// when `row == 0`).
  ///
  /// Always returns `false` while [isUsingAlternateScreen] is `true` or when
  /// [row] is out of bounds.
  bool isRowWrapped(int row) {
    if (_usingAltScreen || row < 0 || row >= height) return false;
    return _primaryWrapped[row];
  }

  /// The active screen buffer (primary or alternate screen).
  ///
  /// The returned [Buffer] switches between the primary and alternate buffers
  /// across `?47`, `?1047`, and `?1049` transitions, so callers should read
  /// [buffer] on each frame rather than caching it across writes.
  Buffer get buffer =>
      _usingAltScreen ? (_altBuffer ?? _primaryBuffer) : _primaryBuffer;

  /// Whether the alternate screen buffer (`?47`, `?1047`, or `?1049`) is active.
  bool get isUsingAlternateScreen => _usingAltScreen;

  /// The 0-indexed X coordinate of the cursor (`cursorX == width` indicates
  /// right-margin pending wrap when [autoWrapMode] is `true`).
  int cursorX = 0;

  /// The 0-indexed Y coordinate of the cursor.
  int cursorY = 0;

  bool _cursorVisible = true;

  /// Whether the cursor is visible (`DECTCEM` `?25h` / `?25l`).
  bool get cursorVisible => _cursorVisible;

  bool _autoWrap = true;

  /// Whether right-margin auto-wrap (`DECAWM` `?7h` / `?7l`) is enabled.
  bool get autoWrapMode => _autoWrap;

  bool _insertMode = false;

  /// Whether ANSI Insert/Replace Mode (`IRM`, `CSI 4 h` / `CSI 4 l`) is enabled.
  bool get insertMode => _insertMode;

  bool _originMode = false;

  /// Whether Origin Mode (`DECOM`, `?6h` / `?6l`) is enabled.
  bool get originMode => _originMode;

  int _scrollTop = 0;
  int _scrollBottom;
  Style _currentStyle = .empty;
  String? _lastPrintedGrapheme;
  bool _g0DecGraphics = false;
  bool _g1DecGraphics = false;
  bool _useG1 = false;
  final Set<int> _tabStops = {};
  _SavedCursor _savedPrimary = _initialSavedCursor;
  _SavedCursor _savedAlt = _initialSavedCursor;
  late AnsiParser _parser;
  late ByteConversionSink _utf8Sink;

  /// Whether the terminal background should be rendered as transparent.
  final bool transparentBackground;

  /// The default foreground color applied to characters when no explicit color is set.
  final Color? defaultForeground;

  int _mouseTrackingMask = 0;

  /// Whether mouse tracking is enabled (set by DECSET `9`, `1000`, `1002`, or `1003`).
  bool get mouseTrackingEnabled => _mouseTrackingMask != 0;

  set mouseTrackingEnabled(bool value) {
    _mouseTrackingMask = value
        ? (_mouseTrackingMask == 0 ? _mouseModeBit(1000) : _mouseTrackingMask)
        : 0;
  }

  /// Whether SGR mouse reporting mode is enabled (set by DECSET `1006`).
  bool sgrMouseMode = false;

  bool _focusReporting = false;

  /// Whether focus reporting (`DECSET 1004`, `?1004h` / `?1004l`) is enabled.
  bool get focusReportingEnabled => _focusReporting;

  TerminalCursorShape _cursorShape = .defaultShape;

  /// The active cursor visual style set via `DECSCUSR` (`CSI Ps SP q`).
  TerminalCursorShape get cursorShape => _cursorShape;

  /// Whether bracketed paste mode (`DECSET 2004`, `?2004h` / `?2004l`) is enabled.
  bool bracketedPasteMode = false;

  bool _applicationCursorKeys = false;

  /// Whether application cursor keys mode (`DECCKM`, `?1h` / `?1l`) is enabled.
  bool get applicationCursorKeys => _applicationCursorKeys;

  bool _alternateScrollMode = true;

  /// Whether alternate scroll mode (`DECSET 1007`, `?1007h` / `?1007l`) is enabled.
  bool get alternateScrollMode => _alternateScrollMode;

  /// Whether synchronized output mode (`DECSET 2026`, `?2026h` / `?2026l`) is enabled.
  bool synchronizedOutput = false;

  bool _graphemeClusterMode = false;

  /// Whether Unicode grapheme clustering mode (`DECSET 2027`, `?2027h` / `?2027l`) is enabled.
  bool get graphemeClusterMode => _graphemeClusterMode;

  /// Callback invoked when an `OSC 52` clipboard write sequence is decoded.
  ///
  /// The `selection` parameter is the target selection buffer (e.g. `'c'` for
  /// clipboard or `'p'` for primary), and `text` is the decoded UTF-8 string.
  void Function(String selection, String text)? onClipboardWrite;

  /// Callback invoked when a remote application sends an `OSC 52` clipboard
  /// read query (`\x1b]52;<selection>;?\x07`), which is blocked for security.
  void Function(String selection)? onClipboardReadBlocked;

  /// Callback invoked when the terminal generates an escape sequence reply to a
  /// terminal query (`DSR`, `CPR`, `DECXCPR`, `DA1`, `DA2`, `DECRQM`, or `XTWINOPS 18t`).
  void Function(String reply)? onReply;

  final List<void Function()> _listeners = [];

  /// Creates a new virtual terminal with the specified dimensions and settings.
  VirtualTerminal({
    int width = 80,
    int height = 24,
    this.transparentBackground = false,
    this.defaultForeground,
    int maxScrollbackLines = 0,
    this.onReply,
  }) : width = math.max(1, width),
       height = math.max(1, height),
       _scrollBottom = math.max(1, height) - 1,
       _scrollback = ScrollbackBuffer(maxLines: maxScrollbackLines),
       _primaryWrapped = List<bool>.filled(math.max(1, height), false),
       _primaryBuffer = _createBuffer(
         math.max(1, width),
         math.max(1, height),
         transparent: transparentBackground,
       ) {
    _resetDefaultTabStops();
    _initParser();
  }

  void _resetDefaultTabStops() {
    _tabStops
      ..clear()
      ..addAll([for (var col = 8; col < width; col += 8) col]);
  }

  static Buffer _createBuffer(int w, int h, {required bool transparent}) =>
      transparent
      ? Buffer(w, h, defaultBlend: false)
      : Buffer.blank(w, h, defaultBlend: false);

  Buffer _newBuffer(int w, int h) =>
      _createBuffer(w, h, transparent: transparentBackground);

  void _initParser() {
    _parser = AnsiParser(this);
    _utf8Sink = const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(_ParserStringSink(_parser.parse));
  }

  /// Adds a listener to be notified when the terminal buffer changes.
  void addListener(void Function() listener) {
    _listeners.add(listener);
  }

  /// Removes a previously added listener.
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  /// Disposes of resources.
  void dispose() {
    _utf8Sink.close();
    _listeners.clear();
  }

  void _notifyListeners() {
    for (final listener in _listeners) {
      listener();
    }
  }

  /// Resets the terminal to its initial power-on state, exiting alternate
  /// screen, clearing the primary screen, resetting cursor/SGR/mode state, and
  /// discarding partial UTF-8 or escape sequences.
  void reset() {
    _utf8Sink.close();
    _initParser();
    _resetState(fullReset: true);
    _notifyListeners();
  }

  void _resetState({required bool fullReset}) {
    _currentStyle = .empty;
    _lastPrintedGrapheme = null;
    _g0DecGraphics = false;
    _g1DecGraphics = false;
    _useG1 = false;
    _cursorVisible = true;
    _autoWrap = true;
    _insertMode = false;
    _originMode = false;
    _mouseTrackingMask = 0;
    sgrMouseMode = false;
    _focusReporting = false;
    _cursorShape = .defaultShape;
    bracketedPasteMode = false;
    _applicationCursorKeys = false;
    _alternateScrollMode = true;
    synchronizedOutput = false;
    _graphemeClusterMode = false;
    _scrollTop = 0;
    _scrollBottom = height - 1;
    if (fullReset) {
      _resetDefaultTabStops();
      _savedPrimary = _initialSavedCursor;
      _savedAlt = _initialSavedCursor;
      _usingAltScreen = false;
      _altBuffer = null;
      cursorX = 0;
      cursorY = 0;
      _primaryWrapped.fillRange(0, height, false);
      _scrollback.clear();
      final (fg, bg, mod) = _eraseAttributes();
      _primaryBuffer.fillAttributes(char: ' ', fg: fg, bg: bg, modifiers: mod);
    } else {
      if (_usingAltScreen) {
        _savedAlt = _initialSavedCursor;
      } else {
        _savedPrimary = _initialSavedCursor;
      }
      _clampPendingWrap();
    }
  }

  void _clampPendingWrap() {
    if (cursorX >= width) {
      cursorX = math.max(0, width - 1);
    }
  }

  /// Resizes the virtual terminal (both primary and active alternate buffers)
  /// to [newWidth] by [newHeight].
  void resize(int newWidth, int newHeight) {
    final clampedWidth = math.max(1, newWidth);
    final clampedHeight = math.max(1, newHeight);
    if (clampedWidth == width && clampedHeight == height) return;
    _evictOverflowBeforeShrink(clampedHeight);
    final shrunkHorizontally = clampedWidth < width;
    _primaryBuffer.resize(clampedWidth, clampedHeight);
    if (shrunkHorizontally) _healRightEdgeWideGraphemes(_primaryBuffer);
    final alt = _altBuffer;
    if (alt != null) {
      alt.resize(clampedWidth, clampedHeight);
      if (shrunkHorizontally) _healRightEdgeWideGraphemes(alt);
    }
    final nextWrapped = List<bool>.filled(clampedHeight, false);
    final copyWrapped = math.min(_primaryWrapped.length, clampedHeight);
    nextWrapped.setRange(0, copyWrapped, _primaryWrapped);
    _primaryWrapped = nextWrapped;
    _resizeTabStops(clampedWidth);
    width = clampedWidth;
    height = clampedHeight;
    _scrollTop = 0;
    _scrollBottom = height - 1;
    cursorX = cursorX.clamp(0, width - 1);
    cursorY = cursorY.clamp(0, height - 1);
  }

  void _resizeTabStops(int newWidth) {
    if (newWidth < width) {
      _tabStops.removeWhere((col) => col >= newWidth);
      return;
    }
    for (var col = ((width + 7) ~/ 8) * 8; col < newWidth; col += 8) {
      if (col > 0) _tabStops.add(col);
    }
  }

  void _evictOverflowBeforeShrink(int clampedHeight) {
    if (clampedHeight >= height) return;
    final baseCursorY = (_usingAltScreen ? _savedPrimary.y : cursorY).clamp(
      0,
      height - 1,
    );
    final targetY = _lastNonBlankPrimaryRow(baseCursorY);
    final evictCount = math.min(targetY - clampedHeight + 1, baseCursorY);
    if (evictCount <= 0) return;

    _pushPrimaryRowsToScrollback(evictCount);
    _copyCellSpan(_primaryBuffer, 0, evictCount * width, clampedHeight * width);
    _primaryWrapped.setRange(0, clampedHeight, _primaryWrapped, evictCount);
    _savedPrimary = (
      x: _savedPrimary.x,
      y: math.max(0, _savedPrimary.y.clamp(0, height - 1) - evictCount),
      style: _savedPrimary.style,
      pendingWrap: _savedPrimary.pendingWrap,
      originMode: _savedPrimary.originMode,
      g0DecGraphics: _savedPrimary.g0DecGraphics,
      g1DecGraphics: _savedPrimary.g1DecGraphics,
      useG1: _savedPrimary.useG1,
    );
    if (!_usingAltScreen) {
      cursorY = baseCursorY - evictCount;
    }
  }

  int _lastNonBlankPrimaryRow(int minRow) {
    for (var r = height - 1; r > minRow; r--) {
      if (_primaryWrapped[r] || _rowHasVisibleContent(_primaryBuffer, r)) {
        return r;
      }
    }
    return minRow;
  }

  static bool _rowHasVisibleContent(Buffer buf, int row) {
    final rowStart = row * buf.width;
    final rowEnd = rowStart + buf.width;
    for (var cell = rowStart; cell < rowEnd; cell++) {
      if (buf.characters[cell] != ' ') return true;
      final attrIdx = cell * 3;
      if (buf.attributes[attrIdx + 1] != 0 ||
          (buf.attributes[attrIdx + 2] & ~Modifier.transparent) != 0) {
        return true;
      }
    }
    return false;
  }

  void _healRightEdgeWideGraphemes(Buffer buf) {
    final rightCol = buf.width - 1;
    for (var y = 0; y < buf.height; y++) {
      final cellIdx = y * buf.width + rightCol;
      if (isWideGrapheme(buf.characters[cellIdx])) {
        _resetSplitCell(buf, cellIdx);
      }
    }
  }

  void _resetSplitCell(Buffer buf, int cellIdx) {
    buf.characters[cellIdx] = ' ';
    final attrIdx = cellIdx * 3;
    buf.attributes[attrIdx] = 0;
    buf.attributes[attrIdx + 1] = 0;
    buf.attributes[attrIdx + 2] = transparentBackground
        ? Modifier.transparent
        : Modifier.none;
  }

  /// Feeds a chunk of UTF-8 encoded bytes into the terminal.
  void write(List<int> chunk) {
    _utf8Sink.add(chunk);
    _notifyListeners();
  }

  /// Feeds an already-decoded Dart string directly into the terminal.
  void writeString(String text) {
    _parser.parse(text);
    _notifyListeners();
  }

  (int fg, int bg, int mod) _eraseAttributes() {
    final bgArg = _currentStyle.background?.argb ?? 0;
    if (transparentBackground && (bgArg == 0 || bgArg == 0xFF000000)) {
      return (0, 0, Modifier.transparent);
    }
    return (0, bgArg, Modifier.none);
  }

  void _eraseRowSpan(int y, int startX, int endX) {
    if (startX >= endX || y < 0 || y >= height) return;
    final (fg, bg, mod) = _eraseAttributes();
    buffer.fillRect(
      Rect(startX, y, endX - startX, 1),
      char: ' ',
      fg: fg,
      bg: bg,
      modifiers: mod,
    );
  }

  void _eraseInDisplay(int mode) {
    final active = buffer;
    switch (mode) {
      case 0: // Cursor (inclusive) to end of screen
        _clampPendingWrap();
        _eraseRowSpan(cursorY, cursorX, width);
        _clearLineWrapOnErase(clearStart: cursorX == 0, clearEnd: true);
        if (cursorY + 1 < height) {
          final (fg, bg, mod) = _eraseAttributes();
          active.fillRect(
            Rect(0, cursorY + 1, width, height - (cursorY + 1)),
            char: ' ',
            fg: fg,
            bg: bg,
            modifiers: mod,
          );
          _clearWrappedRange(cursorY + 1, height);
        }
      case 1: // Start of screen to cursor (inclusive)
        _clampPendingWrap();
        if (cursorY > 0) {
          final (fg, bg, mod) = _eraseAttributes();
          active.fillRect(
            Rect(0, 0, width, cursorY),
            char: ' ',
            fg: fg,
            bg: bg,
            modifiers: mod,
          );
        }
        _eraseRowSpan(cursorY, 0, math.min(width, cursorX + 1));
        _clearWrappedRange(0, cursorY + 1);
      case 2: // Entire screen
        _clampPendingWrap();
        final (fg, bg, mod) = _eraseAttributes();
        active.fillAttributes(char: ' ', fg: fg, bg: bg, modifiers: mod);
        _clearWrappedRange(0, height);
      case 3: // Saved scrollback lines only
        if (!_usingAltScreen) _scrollback.clear();
    }
  }

  void _eraseInLine(int mode) {
    _clampPendingWrap();
    switch (mode) {
      case 0: // Cursor (inclusive) to end of line
        _eraseRowSpan(cursorY, cursorX, width);
        _clearLineWrapOnErase(clearStart: cursorX == 0, clearEnd: true);
      case 1: // Start of line to cursor (inclusive)
        _eraseRowSpan(cursorY, 0, math.min(width, cursorX + 1));
        _clearLineWrapOnErase(clearStart: true, clearEnd: false);
      case 2: // Entire line
        _eraseRowSpan(cursorY, 0, width);
        _clearLineWrapOnErase(clearStart: true, clearEnd: true);
    }
  }

  void _clearWrappedRange(int start, int end) {
    if (_usingAltScreen || start >= end) return;
    _primaryWrapped.fillRange(start, end, false);
  }

  void _clearLineWrapOnErase({
    required bool clearStart,
    required bool clearEnd,
  }) {
    if (_usingAltScreen) return;
    if (clearStart) _primaryWrapped[cursorY] = false;
    if (clearEnd && cursorY + 1 < height) _primaryWrapped[cursorY + 1] = false;
  }

  void _indexDown() {
    final wrapped = _wrappingNextIndexDown;
    _wrappingNextIndexDown = false;
    var advanced = false;
    if (cursorY == _scrollBottom) {
      _scrollRegion(_scrollTop, _scrollBottom, 1, up: true, evictTop: true);
      advanced = true;
    } else if (cursorY < height - 1) {
      cursorY++;
      advanced = true;
    }
    if (wrapped && advanced && !_usingAltScreen) {
      _primaryWrapped[cursorY] = true;
    }
  }

  void _reverseIndex() {
    _clampPendingWrap();
    if (cursorY == _scrollTop) {
      _scrollRegion(_scrollTop, _scrollBottom, 1, up: false);
    } else if (cursorY > 0) {
      cursorY--;
    }
  }

  void _scrollRegion(
    int top,
    int bottom,
    int count, {
    required bool up,
    bool evictTop = false,
  }) {
    if (top < 0 || bottom >= height || top > bottom || count <= 0) return;
    final regionRows = bottom - top + 1;
    final shift = math.min(count, regionRows);
    _evictTopRowsToScrollback(top, shift, up: up, evictTop: evictTop);
    final keepRows = regionRows - shift;
    final active = buffer;
    if (keepRows > 0) {
      final dstRow = up ? top : top + shift;
      final srcRow = up ? top + shift : top;
      _copyCellSpan(active, dstRow * width, srcRow * width, keepRows * width);
      if (!_usingAltScreen) {
        _primaryWrapped.setRange(
          dstRow,
          dstRow + keepRows,
          _primaryWrapped,
          srcRow,
        );
      }
    }
    final fillStart = up ? bottom - shift + 1 : top;
    final fillEnd = up ? bottom + 1 : top + shift;
    _fillRowsWithEraseAttributes(active, fillStart, fillEnd);
    _clearWrappedRange(fillStart, fillEnd);
  }

  void _evictTopRowsToScrollback(
    int top,
    int shift, {
    required bool up,
    required bool evictTop,
  }) {
    if (!evictTop || !up || _usingAltScreen || top != 0) return;
    _pushPrimaryRowsToScrollback(shift);
  }

  void _pushPrimaryRowsToScrollback(int count) {
    if (_scrollback.maxLines <= 0) return;
    for (var r = 0; r < count; r++) {
      _scrollback.push(
        ScrollbackLine.fromBufferRow(
          _primaryBuffer,
          r,
          isWrapped: _primaryWrapped[r],
        ),
      );
    }
  }

  static void _copyCellSpan(
    Buffer buf,
    int dstCell,
    int srcCell,
    int cellCount,
  ) {
    if (cellCount <= 0) return;
    buf.characters.setRange(
      dstCell,
      dstCell + cellCount,
      buf.characters,
      srcCell,
    );
    buf.attributes.setRange(
      dstCell * 3,
      (dstCell + cellCount) * 3,
      buf.attributes,
      srcCell * 3,
    );
  }

  void _fillRowsWithEraseAttributes(
    Buffer buf,
    int startRow,
    int endRowExclusive,
  ) {
    final startCell = startRow * width;
    final endCell = endRowExclusive * width;
    if (startCell >= endCell) return;
    buf.characters.fillRange(startCell, endCell, ' ');
    final (fg, bg, mod) = _eraseAttributes();
    for (var i = startCell * 3; i < endCell * 3; i += 3) {
      buf.attributes[i] = fg;
      buf.attributes[i + 1] = bg;
      buf.attributes[i + 2] = mod;
    }
  }

  @override
  void printText(String text) {
    for (final char in text.characters) {
      _printGrapheme(char);
    }
  }

  void _wrapLineDown() {
    cursorX = 0;
    _wrappingNextIndexDown = true;
    _indexDown();
    _wrappingNextIndexDown = false;
  }

  void _printGrapheme(String rawChar, {bool translateCharset = true}) {
    if (rawChar.isEmpty || _containsControlCodeUnit(rawChar)) return;
    final char = translateCharset ? _translateCharset(rawChar) : rawChar;
    _lastPrintedGrapheme = char;
    if (cursorX >= width) {
      if (_autoWrap) {
        _wrapLineDown();
      } else {
        cursorX = width - 1;
      }
    }

    final (fgArg, bgArg, modArg, isBgTransparent) = _resolvePrintAttributes(
      char,
    );
    if (isWideGrapheme(char)) {
      _printWideGrapheme(char, fgArg, bgArg, modArg, isBgTransparent);
      return;
    }
    if (_insertMode) _insertBlankChars(1);
    buffer.setAttributes(
      cursorX,
      cursorY,
      char: char,
      fg: fgArg,
      bg: bgArg,
      modifiers: modArg,
    );
    _advanceCursorAfterPrint(1);
  }

  String _translateCharset(String char) {
    if (!(_useG1 ? _g1DecGraphics : _g0DecGraphics) || char.length != 1) {
      return char;
    }
    final code = char.codeUnitAt(0);
    if (code < 0x5F || code > 0x7E) return char;
    return _decSpecialGraphics[code - 0x5F];
  }

  static bool _containsControlCodeUnit(String grapheme) {
    for (var i = 0; i < grapheme.length; i++) {
      final codeUnit = grapheme.codeUnitAt(i);
      if (codeUnit <= 0x1F || (codeUnit >= 0x7F && codeUnit <= 0x9F)) {
        return true;
      }
    }
    return false;
  }

  (int fg, int bg, int mod, bool bgTransparent) _resolvePrintAttributes(
    String char,
  ) {
    var fgArg = _currentStyle.foreground?.argb ?? 0;
    var bgArg = _currentStyle.background?.argb ?? 0;
    var modArg = _currentStyle.modifiers;

    final bgTransparent =
        transparentBackground && (bgArg == 0 || bgArg == 0xFF000000);
    if (bgTransparent) {
      bgArg = 0;
      if (fgArg == 0) fgArg = defaultForeground?.argb ?? 0xFFFFFFFF;
      if (char == ' ') modArg |= Modifier.transparent;
    } else if (fgArg == 0 && defaultForeground != null) {
      fgArg = defaultForeground!.argb;
    }
    return (fgArg, bgArg, modArg, bgTransparent);
  }

  void _printWideGrapheme(
    String char,
    int fgArg,
    int bgArg,
    int modArg,
    bool bgTransparent,
  ) {
    if (cursorX == width - 1) {
      buffer.setAttributes(
        cursorX,
        cursorY,
        char: ' ',
        fg: fgArg,
        bg: bgArg,
        modifiers: bgTransparent ? (modArg | Modifier.transparent) : modArg,
      );
      if (width == 1 || !_autoWrap) {
        cursorX = (width == 1 && _autoWrap) ? 1 : width - 1;
        return;
      }
      _wrapLineDown();
    }
    if (_insertMode) _insertBlankChars(2);
    buffer.setAttributes(
      cursorX,
      cursorY,
      char: char,
      fg: fgArg,
      bg: bgArg,
      modifiers: modArg,
    );
    _advanceCursorAfterPrint(2);
  }

  void _advanceCursorAfterPrint(int step) {
    final nextX = cursorX + step;
    if (nextX >= width) {
      cursorX = _autoWrap ? width : width - 1;
    } else {
      cursorX = nextX;
    }
  }

  @override
  void execute(int charCode) {
    switch (charCode) {
      case 8: // Backspace
        _clampPendingWrap();
        if (cursorX > 0) cursorX--;
      case 9: // Horizontal tab
        _advanceTabStops(1);
      case 10 || 11 || 12: // Line feed, vertical tab, form feed
        _clampPendingWrap();
        _indexDown();
      case 13: // Carriage return
        cursorX = 0;
      case 14: // Shift Out (SO -> G1)
        _useG1 = true;
      case 15: // Shift In (SI -> G0)
        _useG1 = false;
    }
  }

  void _handleDecPrivateMode(String command, List<int> params) {
    switch (command) {
      case 'J':
        _eraseInDisplay(params.isEmpty ? 0 : params[0]);
      case 'K':
        _eraseInLine(params.isEmpty ? 0 : params[0]);
      case 'n':
        if (params.length == 1 && params[0] == 6) {
          _replyCursorPosition(extended: true);
        }
      case 'W':
        if (params.length == 1 && params[0] == 5) _resetDefaultTabStops();
      case 'h' || 'l':
        final enable = command == 'h';
        for (final param in params) {
          _applyDecPrivateModeParam(param, enable);
        }
    }
  }

  void _applyDecPrivateModeParam(int param, bool enable) {
    switch (param) {
      case 1: // DECCKM (Application Cursor Keys)
        _applicationCursorKeys = enable;
      case 6: // DECOM (Origin Mode)
        _originMode = enable;
        cursorX = 0;
        cursorY = enable ? _scrollTop : 0;
      case 7: // DECAWM (Auto-Wrap Mode)
        _autoWrap = enable;
        if (!enable) _clampPendingWrap();
      case 25: // DECTCEM (Text Cursor Enable Mode)
        _cursorVisible = enable;
      case 47 || 1047: // Alternate Screen Buffer
        _switchAlternateScreen(enable, saveRestoreCursor: false);
      case 1048: // Save / Restore Cursor (DECSC / DECRC)
        enable ? _saveCursor() : _restoreCursor();
      case 1049: // Save Cursor + Alternate Screen Buffer
        _switchAlternateScreen(enable, saveRestoreCursor: true);
      case 9 || 1000 || 1002 || 1003:
        final bit = _mouseModeBit(param);
        _mouseTrackingMask = enable
            ? (_mouseTrackingMask | bit)
            : (_mouseTrackingMask & ~bit);
      case 1004: // Focus Reporting
        _focusReporting = enable;
      case 1006:
        sgrMouseMode = enable;
      case 1007: // Alternate Scroll Mode
        _alternateScrollMode = enable;
      case 2004:
        bracketedPasteMode = enable;
      case 2026:
        synchronizedOutput = enable;
      case 2027:
        _graphemeClusterMode = enable;
    }
  }

  void _switchAlternateScreen(bool enable, {required bool saveRestoreCursor}) {
    if (enable && !_usingAltScreen) {
      if (saveRestoreCursor) _saveCursor();
      _altBuffer = _newBuffer(width, height);
      _usingAltScreen = true;
      _scrollTop = 0;
      _scrollBottom = height - 1;
      if (saveRestoreCursor) {
        cursorX = 0;
        cursorY = 0;
      } else {
        _clampPendingWrap();
      }
      return;
    }
    if (!enable && _usingAltScreen) {
      _usingAltScreen = false;
      _altBuffer = null;
      _scrollTop = 0;
      _scrollBottom = height - 1;
      if (saveRestoreCursor) {
        _restoreCursor();
      } else {
        _clampPendingWrap();
      }
    }
  }

  void _saveCursor() {
    final snapshot = (
      x: cursorX.clamp(0, width - 1),
      y: cursorY.clamp(0, height - 1),
      style: _currentStyle,
      pendingWrap: cursorX >= width,
      originMode: _originMode,
      g0DecGraphics: _g0DecGraphics,
      g1DecGraphics: _g1DecGraphics,
      useG1: _useG1,
    );
    if (_usingAltScreen) {
      _savedAlt = snapshot;
    } else {
      _savedPrimary = snapshot;
    }
  }

  void _restoreCursor() {
    final saved = _usingAltScreen ? _savedAlt : _savedPrimary;
    final restoredX = saved.x.clamp(0, width - 1);
    cursorX = (saved.pendingWrap && _autoWrap && restoredX == width - 1)
        ? width
        : restoredX;
    _originMode = saved.originMode;
    cursorY = _originMode
        ? saved.y.clamp(_scrollTop, _scrollBottom)
        : saved.y.clamp(0, height - 1);
    _currentStyle = saved.style;
    _g0DecGraphics = saved.g0DecGraphics;
    _g1DecGraphics = saved.g1DecGraphics;
    _useG1 = saved.useG1;
  }

  @override
  void csi(
    String command,
    List<int> params, {
    String? intermediate,
    List<List<int>?>? subparams,
  }) {
    if (intermediate == null && command == 'm') {
      _applySgr(params, subparams: subparams);
      return;
    }
    if (subparams != null) return;
    if (intermediate != null) {
      _handleIntermediateCsi(intermediate, command, params);
      return;
    }

    final p1 = _clampedPositiveParam(params, 0);
    final p2 = _clampedPositiveParam(params, 1);
    if (_tryHandleCursorCsi(command, p1, p2)) return;
    if (_tryHandleQueryCsi(command, params)) return;
    _handleEditingOrModeCsi(command, params, p1);
  }

  void _handleIntermediateCsi(
    String intermediate,
    String command,
    List<int> params,
  ) {
    switch ((intermediate, command)) {
      case ('?', _):
        _handleDecPrivateMode(command, params);
      case ('!', 'p'):
        _resetState(fullReset: false);
      case ('>', 'c'):
        if (_isZeroOrEmptyParam(params)) onReply?.call('\x1b[>1;10;0c');
      case (r'?$', 'p'):
        _replyDecrqm(params, decPrivate: true);
      case (r'$', 'p'):
        _replyDecrqm(params, decPrivate: false);
      case (' ', 'q'):
        _setCursorShape(params);
    }
  }

  static int _mouseModeBit(int mode) => switch (mode) {
    9 => 1 << 0,
    1000 => 1 << 1,
    1002 => 1 << 2,
    1003 => 1 << 3,
    _ => 0,
  };

  void _setCursorShape(List<int> params) {
    if (params.length > 1) return;
    final code = params.isEmpty ? 0 : params[0];
    final shape = switch (code) {
      0 => TerminalCursorShape.defaultShape,
      1 => TerminalCursorShape.blinkingBlock,
      2 => TerminalCursorShape.steadyBlock,
      3 => TerminalCursorShape.blinkingUnderline,
      4 => TerminalCursorShape.steadyUnderline,
      5 => TerminalCursorShape.blinkingBar,
      6 => TerminalCursorShape.steadyBar,
      _ => null,
    };
    if (shape != null) _cursorShape = shape;
  }

  static bool _isZeroOrEmptyParam(List<int> params) =>
      params.isEmpty || (params.length == 1 && params[0] == 0);

  bool _tryHandleQueryCsi(String command, List<int> params) {
    switch (command) {
      case 'c':
        if (_isZeroOrEmptyParam(params)) onReply?.call('\x1b[?62;22c');
      case 'n':
        if (params.length == 1 && params[0] == 5) {
          onReply?.call('\x1b[0n');
        } else if (params.length == 1 && params[0] == 6) {
          _replyCursorPosition(extended: false);
        }
      case 't':
        if (params.length == 1 && params[0] == 18) {
          onReply?.call('\x1b[8;$height;${width}t');
        }
      default:
        return false;
    }
    return true;
  }

  void _replyCursorPosition({required bool extended}) {
    final reply = onReply;
    if (reply == null) return;
    final row = _originMode
        ? cursorY.clamp(_scrollTop, _scrollBottom) - _scrollTop + 1
        : cursorY.clamp(0, height - 1) + 1;
    final col = cursorX.clamp(0, width - 1) + 1;
    reply(extended ? '\x1b[?$row;$col;1R' : '\x1b[$row;${col}R');
  }

  void _replyDecrqm(List<int> params, {required bool decPrivate}) {
    final reply = onReply;
    if (reply == null || params.length != 1) return;
    final mode = params[0];
    final pm = decPrivate
        ? _decPrivateModeStatus(mode)
        : (mode == 4 ? (_insertMode ? 1 : 2) : 0);
    final prefix = decPrivate ? '?' : '';
    reply('\x1b[$prefix$mode;$pm\$y');
  }

  int _decPrivateModeStatus(int mode) {
    final enabled = switch (mode) {
      1 => _applicationCursorKeys,
      6 => _originMode,
      7 => _autoWrap,
      25 => _cursorVisible,
      47 || 1047 || 1049 => _usingAltScreen,
      9 ||
      1000 ||
      1002 ||
      1003 => (_mouseTrackingMask & _mouseModeBit(mode)) != 0,
      1004 => _focusReporting,
      1006 => sgrMouseMode,
      1007 => _alternateScrollMode,
      1048 => false,
      2004 => bracketedPasteMode,
      2026 => synchronizedOutput,
      2027 => _graphemeClusterMode,
      _ => null,
    };
    if (enabled == null) return 0;
    return enabled ? 1 : 2;
  }

  static int _clampedPositiveParam(List<int> params, int index) {
    if (index >= params.length || params[index] <= 0) return 1;
    return math.min(params[index], 0xFFFF);
  }

  int _moveCursorUp(int rows) =>
      math.max(cursorY >= _scrollTop ? _scrollTop : 0, cursorY - rows);

  int _moveCursorDown(int rows) => math.min(
    cursorY <= _scrollBottom ? _scrollBottom : height - 1,
    cursorY + rows,
  );

  int _resolveAbsoluteRow(int oneBasedRow) => _originMode
      ? (_scrollTop + oneBasedRow - 1).clamp(_scrollTop, _scrollBottom)
      : (oneBasedRow - 1).clamp(0, height - 1);

  bool _tryHandleCursorCsi(String command, int p1, int p2) {
    switch (command) {
      case 'A': // Cursor Up (CUU)
        _clampPendingWrap();
        cursorY = _moveCursorUp(p1);
      case 'B' || 'e': // Cursor Down (CUD) / Line Position Relative (VPR)
        _clampPendingWrap();
        cursorY = _moveCursorDown(p1);
      case 'C' ||
          'a': // Cursor Forward (CUF) / Character Position Relative (HPR)
        _clampPendingWrap();
        cursorX = math.min(width - 1, cursorX + p1);
      case 'D': // Cursor Back (CUB)
        _clampPendingWrap();
        cursorX = math.max(0, cursorX - p1);
      case 'E': // Cursor Next Line (CNL)
        cursorX = 0;
        cursorY = _moveCursorDown(p1);
      case 'F': // Cursor Preceding Line (CPL)
        cursorX = 0;
        cursorY = _moveCursorUp(p1);
      case 'G' || '`': // Cursor Character Absolute (CHA / HPA)
        cursorX = (p1 - 1).clamp(0, width - 1);
      case 'I': // Cursor Horizontal Forward Tabulation (CHT)
        _advanceTabStops(p1);
      case 'Z': // Cursor Backward Tabulation (CBT)
        _retreatTabStops(p1);
      case 'd': // Line Position Absolute (VPA)
        _clampPendingWrap();
        cursorY = _resolveAbsoluteRow(p1);
      case 'H' || 'f': // Cursor Position (CUP / HVP)
        cursorX = (p2 - 1).clamp(0, width - 1);
        cursorY = _resolveAbsoluteRow(p1);
      default:
        return false;
    }
    return true;
  }

  void _handleEditingOrModeCsi(String command, List<int> params, int p1) {
    switch (command) {
      case 'J':
        _eraseInDisplay(params.isEmpty ? 0 : params[0]);
      case 'K':
        _eraseInLine(params.isEmpty ? 0 : params[0]);
      case 'X':
        _clampPendingWrap();
        _eraseRowSpan(cursorY, cursorX, math.min(width, cursorX + p1));
      case 'P':
        _deleteChars(p1);
      case '@':
        _insertBlankChars(p1);
      case 'L':
        _insertLines(p1);
      case 'M':
        _deleteLines(p1);
      case 'S':
        _scrollRegion(_scrollTop, _scrollBottom, p1, up: true, evictTop: true);
      case 'T':
        if (params.length <= 1) {
          _scrollRegion(_scrollTop, _scrollBottom, p1, up: false);
        }
      case 'r':
        _setScrollRegion(params);
      case 'b':
        _repeatLastGrapheme(p1);
      case 's':
        if (params.isEmpty) _saveCursor();
      case 'u':
        if (params.isEmpty) _restoreCursor();
      case 'h' || 'l':
        _setAnsiMode(params, command == 'h');
      case 'g':
        _clearTabStop(params.isEmpty ? 0 : params[0]);
    }
  }

  void _clearTabStop(int mode) {
    if (mode == 0) {
      _tabStops.remove(cursorX.clamp(0, width - 1));
    } else if (mode == 3) {
      _tabStops.clear();
    }
  }

  int _nextTabStopAfter(int x) {
    var best = width - 1;
    for (final stop in _tabStops) {
      if (stop > x && stop < best) best = stop;
    }
    return best;
  }

  int _prevTabStopBefore(int x) {
    var best = 0;
    for (final stop in _tabStops) {
      if (stop < x && stop > best) best = stop;
    }
    return best;
  }

  void _advanceTabStops(int count) {
    _clampPendingWrap();
    for (var i = 0; i < count && cursorX < width - 1; i++) {
      cursorX = _nextTabStopAfter(cursorX);
    }
  }

  void _retreatTabStops(int count) {
    _clampPendingWrap();
    for (var i = 0; i < count && cursorX > 0; i++) {
      cursorX = _prevTabStopBefore(cursorX);
    }
  }

  void _setAnsiMode(List<int> params, bool enable) {
    for (final param in params) {
      if (param == 4) _insertMode = enable;
    }
  }

  void _repeatLastGrapheme(int count) {
    final last = _lastPrintedGrapheme;
    if (last == null) return;
    final limit = math.min(count, width * height);
    for (var i = 0; i < limit; i++) {
      _printGrapheme(last, translateCharset: false);
    }
  }

  void _setScrollRegion(List<int> params) {
    final rawTop = _clampedPositiveParam(params, 0);
    final rawBottom = params.length > 1 && params[1] > 0
        ? math.min(params[1], 0xFFFF)
        : height;
    if (rawTop > rawBottom) return;
    final top = (rawTop - 1).clamp(0, height - 1);
    final bottom = (rawBottom - 1).clamp(0, height - 1);
    if (top < bottom || (height == 1 && rawTop == 1)) {
      _scrollTop = top;
      _scrollBottom = bottom;
      cursorX = 0;
      cursorY = _originMode ? _scrollTop : 0;
    }
  }

  void _insertLines(int count) {
    _clampPendingWrap();
    if (cursorY < _scrollTop || cursorY > _scrollBottom) return;
    cursorX = 0;
    _scrollRegion(cursorY, _scrollBottom, count, up: false);
  }

  void _deleteLines(int count) {
    _clampPendingWrap();
    if (cursorY < _scrollTop || cursorY > _scrollBottom) return;
    cursorX = 0;
    _scrollRegion(cursorY, _scrollBottom, count, up: true);
  }

  void _deleteChars(int count) {
    _clampPendingWrap();
    final active = buffer;
    final rowBase = cursorY * width;
    if (cursorX > 0 && active.characters[rowBase + cursorX] == '') {
      _resetSplitCell(active, rowBase + cursorX - 1);
    }
    final remaining = width - cursorX;
    final del = math.min(count, remaining);
    final srcEnd = cursorX + del;
    if (srcEnd < width && active.characters[rowBase + srcEnd] == '') {
      _resetSplitCell(active, rowBase + srcEnd);
    }
    _copyCellSpan(active, rowBase + cursorX, rowBase + srcEnd, remaining - del);
    _eraseRowSpan(cursorY, width - del, width);
  }

  void _insertBlankChars(int count) {
    _clampPendingWrap();
    final active = buffer;
    final rowBase = cursorY * width;
    if (cursorX > 0 && active.characters[rowBase + cursorX] == '') {
      _resetSplitCell(active, rowBase + cursorX - 1);
      _resetSplitCell(active, rowBase + cursorX);
    }
    final remaining = width - cursorX;
    final ins = math.min(count, remaining);
    final shiftCols = remaining - ins;
    if (shiftCols > 0) {
      final src = rowBase + cursorX;
      if (isWideGrapheme(active.characters[src + shiftCols - 1])) {
        _resetSplitCell(active, src + shiftCols - 1);
      }
      _copyCellSpan(active, src + ins, src, shiftCols);
    }
    _eraseRowSpan(cursorY, cursorX, cursorX + ins);
  }

  void _applySgr(List<int> params, {List<List<int>?>? subparams}) {
    if (params.isEmpty) {
      _currentStyle = .empty;
      return;
    }
    var i = 0;
    while (i < params.length) {
      final code = params[i];
      final sub = (subparams != null && i < subparams.length)
          ? subparams[i]
          : null;
      if (sub != null) {
        _applyColonSgr(code, sub);
        i++;
        continue;
      }
      if (code == 38 || code == 48 || code == 58) {
        final (color, consumed) = _parseExtendedColor(
          params,
          i,
          subparams: subparams,
        );
        _applyExtendedSgrColor(code, color);
        i += consumed;
        continue;
      }
      _applySingleSgrCode(code);
      i++;
    }
  }

  void _applyColonSgr(int code, List<int> sub) {
    switch ((code, sub)) {
      case (4, [0, ...]):
        _setModifier(Modifier.underline, enable: false);
      case (4, [>= 1 && <= 5, ...]):
        _setModifier(Modifier.underline, enable: true);
      case (38 || 48, _):
        _applyExtendedSgrColor(code, _parseColonExtendedColor(sub));
    }
  }

  void _applyExtendedSgrColor(int code, Color? color) {
    if (color == null || code == 58) return;
    _currentStyle = code == 38
        ? _currentStyle.merge(Style(foreground: color))
        : _currentStyle.merge(Style(background: color));
  }

  Color? _parseColonExtendedColor(List<int> sub) => switch (sub) {
    [5, final index, ...] => _colorFromAnsi256(index),
    [2, _, final r, final g, final b, ...] || [2, final r, final g, final b] =>
      Color(r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255)),
    _ => null,
  };

  static int _semicolonSpanEnd(
    List<int> params,
    List<List<int>?>? subparams,
    int index,
  ) {
    final limit = math.min(params.length, index + 5);
    if (subparams == null) return limit;
    var end = index + 1;
    while (end < limit && (end >= subparams.length || subparams[end] == null)) {
      end++;
    }
    return end;
  }

  (Color?, int) _parseExtendedColor(
    List<int> params,
    int index, {
    List<List<int>?>? subparams,
  }) {
    final end = _semicolonSpanEnd(params, subparams, index);
    if (index + 1 >= end) return (null, 1);
    final mode = params[index + 1];
    if (mode == 5) {
      if (index + 2 >= end) return (null, end - index);
      return (_colorFromAnsi256(params[index + 2]), 3);
    }
    if (mode == 2) {
      if (index + 4 >= end) return (null, end - index);
      final r = params[index + 2].clamp(0, 255);
      final g = params[index + 3].clamp(0, 255);
      final b = params[index + 4].clamp(0, 255);
      return (Color(r, g, b), 5);
    }
    return (null, 2);
  }

  void _applySingleSgrCode(int code) {
    switch (code) {
      case 0:
        _currentStyle = .empty;
      case 1 || 2 || 3 || 4 || 5 || 6 || 7 || 8 || 9 || 21:
        _setModifier(_modifierBitForSet(code), enable: true);
      case 22:
        _setModifier(Modifier.bold | Modifier.dim, enable: false);
      case 23 || 24 || 25 || 27 || 28 || 29:
        _setModifier(_modifierBitForReset(code), enable: false);
      case 39:
        _currentStyle = Style(
          background: _currentStyle.background,
          modifiers: _currentStyle.modifiers,
        );
      case 49:
        _currentStyle = Style(
          foreground: _currentStyle.foreground,
          modifiers: _currentStyle.modifiers,
        );
      default:
        _applyBasicPaletteCode(code);
    }
  }

  static int _modifierBitForSet(int code) => switch (code) {
    1 => Modifier.bold,
    2 => Modifier.dim,
    3 => Modifier.italic,
    4 || 21 => Modifier.underline,
    5 || 6 => Modifier.blink,
    7 => Modifier.reverse,
    8 => Modifier.hidden,
    9 => Modifier.crossedOut,
    _ => Modifier.none,
  };

  static int _modifierBitForReset(int code) => switch (code) {
    23 => Modifier.italic,
    24 => Modifier.underline,
    25 => Modifier.blink,
    27 => Modifier.reverse,
    28 => Modifier.hidden,
    29 => Modifier.crossedOut,
    _ => Modifier.none,
  };

  void _setModifier(int mask, {required bool enable}) {
    final nextModifiers = enable
        ? (_currentStyle.modifiers | mask)
        : (_currentStyle.modifiers & ~mask);
    _currentStyle = Style(
      foreground: _currentStyle.foreground,
      background: _currentStyle.background,
      modifiers: nextModifiers,
    );
  }

  void _applyBasicPaletteCode(int code) {
    if (code >= 30 && code <= 37) {
      _currentStyle = _currentStyle.merge(
        Style(foreground: _colorFromAnsi256(code - 30)),
      );
    } else if (code >= 90 && code <= 97) {
      _currentStyle = _currentStyle.merge(
        Style(foreground: _colorFromAnsi256(code - 90 + 8)),
      );
    } else if (code >= 40 && code <= 47) {
      _currentStyle = _currentStyle.merge(
        Style(background: _colorFromAnsi256(code - 40)),
      );
    } else if (code >= 100 && code <= 107) {
      _currentStyle = _currentStyle.merge(
        Style(background: _colorFromAnsi256(code - 100 + 8)),
      );
    }
  }

  @override
  void osc(int command, String payload) {
    if (command == 52) {
      _handleOsc52(payload);
    }
  }

  void _handleOsc52(String payload) {
    if (payload.length > _maxOsc52PayloadLength) return;
    final semi = payload.indexOf(';');
    if (semi < 0) return;
    final rawSelection = payload.substring(0, semi);
    final selection = rawSelection.isEmpty ? 'c' : rawSelection;
    final body = payload.substring(semi + 1).trim();
    if (body == '?') {
      onClipboardReadBlocked?.call(selection);
      return;
    }
    final writer = onClipboardWrite;
    if (writer == null) return;
    final text = _decodeOsc52Payload(body);
    if (text != null) {
      writer(selection, text);
    }
  }

  static String? _decodeOsc52Payload(String body) {
    final cleaned = body.replaceAll(_whitespaceRegex, '');
    try {
      final decodedBytes = base64.decode(base64.normalize(cleaned));
      if (decodedBytes.length > _maxOsc52DecodedBytes) return null;
      final text = utf8.decode(decodedBytes, allowMalformed: true);
      if (utf8.encode(text).length > _maxOsc52DecodedBytes) return null;
      return text;
    } on FormatException {
      return null;
    }
  }

  @override
  void esc(String command) {
    switch (command) {
      case 'c': // RIS (Reset to Initial State)
        _resetState(fullReset: true);
      case '7': // DECSC (Save Cursor)
        _saveCursor();
      case '8': // DECRC (Restore Cursor)
        _restoreCursor();
      case 'D': // IND (Index)
        _clampPendingWrap();
        _indexDown();
      case 'E': // NEL (Next Line)
        cursorX = 0;
        _indexDown();
      case 'M': // RI (Reverse Index)
        _reverseIndex();
      case 'H': // HTS (Horizontal Tab Set)
        _tabStops.add(cursorX.clamp(0, width - 1));
      case '(0': // Designate G0 as DEC Special Graphics
        _g0DecGraphics = true;
      case _ when command.startsWith('('): // Designate G0 as ASCII / non-DEC
        _g0DecGraphics = false;
      case ')0': // Designate G1 as DEC Special Graphics
        _g1DecGraphics = true;
      case _ when command.startsWith(')'): // Designate G1 as ASCII / non-DEC
        _g1DecGraphics = false;
    }
  }

  Color _colorFromAnsi256(int code) {
    if (code < 0 || code > 255) return Colors.white;
    if (code < 16) {
      final rgb = _ansi16Rgb[code];
      return Color((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);
    }
    if (code < 232) {
      final cube = code - 16;
      final r = (cube ~/ 36) % 6;
      final g = (cube ~/ 6) % 6;
      final b = cube % 6;
      return Color(
        r == 0 ? 0 : r * 40 + 55,
        g == 0 ? 0 : g * 40 + 55,
        b == 0 ? 0 : b * 40 + 55,
      );
    }
    final gray = (code - 232) * 10 + 8;
    return Color(gray, gray, gray);
  }
}

final class _ParserStringSink extends StringConversionSinkBase {
  final void Function(String) _onChunk;

  _ParserStringSink(this._onChunk);

  @override
  void addSlice(String str, int start, int end, bool isLast) {
    if (start < end) {
      _onChunk(str.substring(start, end));
    }
  }

  @override
  void close() {}
}
