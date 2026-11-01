import 'dart:convert';
import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:termui/termui.dart';

import 'ansi_parser.dart';

typedef _SavedCursor = ({int x, int y, Style style, bool pendingWrap});

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
  );

  /// The width of the virtual terminal in columns.
  int width;

  /// The height of the virtual terminal in rows.
  int height;

  final Buffer _primaryBuffer;
  Buffer? _altBuffer;
  bool _usingAltScreen = false;

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

  int _scrollTop = 0;
  int _scrollBottom;
  Style _currentStyle = .empty;
  _SavedCursor _savedPrimary = _initialSavedCursor;
  _SavedCursor _savedAlt = _initialSavedCursor;
  late AnsiParser _parser;
  late ByteConversionSink _utf8Sink;

  /// Whether the terminal background should be rendered as transparent.
  final bool transparentBackground;

  /// The default foreground color applied to characters when no explicit color is set.
  final Color? defaultForeground;

  /// Whether mouse tracking is enabled (set by DECSET `1000`, `1002`, or `1003`).
  bool mouseTrackingEnabled = false;

  /// Whether SGR mouse reporting mode is enabled (set by DECSET `1006`).
  bool sgrMouseMode = false;

  final List<void Function()> _listeners = [];

  /// Creates a new virtual terminal with the specified dimensions and settings.
  VirtualTerminal({
    int width = 80,
    int height = 24,
    this.transparentBackground = false,
    this.defaultForeground,
  }) : width = math.max(1, width),
       height = math.max(1, height),
       _scrollBottom = math.max(1, height) - 1,
       _primaryBuffer = _createBuffer(
         math.max(1, width),
         math.max(1, height),
         transparent: transparentBackground,
       ) {
    _initParser();
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
    _cursorVisible = true;
    _autoWrap = true;
    mouseTrackingEnabled = false;
    sgrMouseMode = false;
    _scrollTop = 0;
    _scrollBottom = height - 1;
    if (fullReset) {
      _savedPrimary = _initialSavedCursor;
      _savedAlt = _initialSavedCursor;
      _usingAltScreen = false;
      _altBuffer = null;
      cursorX = 0;
      cursorY = 0;
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
    final shrunkHorizontally = clampedWidth < width;
    _primaryBuffer.resize(clampedWidth, clampedHeight);
    if (shrunkHorizontally) _healRightEdgeWideGraphemes(_primaryBuffer);
    final alt = _altBuffer;
    if (alt != null) {
      alt.resize(clampedWidth, clampedHeight);
      if (shrunkHorizontally) _healRightEdgeWideGraphemes(alt);
    }
    width = clampedWidth;
    height = clampedHeight;
    _scrollTop = 0;
    _scrollBottom = height - 1;
    cursorX = cursorX.clamp(0, width - 1);
    cursorY = cursorY.clamp(0, height - 1);
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

  /// Feeds a chunk of data into the terminal.
  void write(List<int> chunk) {
    if (chunk.any((b) => b > 0xFF)) {
      _parser.parse(String.fromCharCodes(chunk));
    } else {
      _utf8Sink.add(chunk);
    }
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
        if (cursorY + 1 < height) {
          final (fg, bg, mod) = _eraseAttributes();
          active.fillRect(
            Rect(0, cursorY + 1, width, height - (cursorY + 1)),
            char: ' ',
            fg: fg,
            bg: bg,
            modifiers: mod,
          );
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
      case 2: // Entire screen
        _clampPendingWrap();
        final (fg, bg, mod) = _eraseAttributes();
        active.fillAttributes(char: ' ', fg: fg, bg: bg, modifiers: mod);
      case 3: // Saved scrollback lines only (no-op without scrollback buffer)
        break;
    }
  }

  void _eraseInLine(int mode) {
    _clampPendingWrap();
    switch (mode) {
      case 0: // Cursor (inclusive) to end of line
        _eraseRowSpan(cursorY, cursorX, width);
      case 1: // Start of line to cursor (inclusive)
        _eraseRowSpan(cursorY, 0, math.min(width, cursorX + 1));
      case 2: // Entire line
        _eraseRowSpan(cursorY, 0, width);
    }
  }

  void _indexDown() {
    if (cursorY == _scrollBottom) {
      _scrollRegion(_scrollTop, _scrollBottom, 1, up: true);
    } else if (cursorY < height - 1) {
      cursorY++;
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

  void _scrollRegion(int top, int bottom, int count, {required bool up}) {
    if (top < 0 || bottom >= height || top > bottom || count <= 0) return;
    final regionRows = bottom - top + 1;
    final shift = math.min(count, regionRows);
    final keepRows = regionRows - shift;
    final active = buffer;
    if (keepRows > 0) {
      final dstRow = up ? top : top + shift;
      final srcRow = up ? top + shift : top;
      _copyCellSpan(active, dstRow * width, srcRow * width, keepRows * width);
    }
    final fillStart = up ? bottom - shift + 1 : top;
    final fillEnd = up ? bottom + 1 : top + shift;
    _fillRowsWithEraseAttributes(active, fillStart, fillEnd);
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

  void _printGrapheme(String char) {
    if (cursorX >= width) {
      if (_autoWrap) {
        cursorX = 0;
        _indexDown();
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
      cursorX = 0;
      _indexDown();
    }
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
        _clampPendingWrap();
        cursorX = (((cursorX ~/ 8) + 1) * 8).clamp(0, width - 1);
      case 10 || 11 || 12: // Line feed, vertical tab, form feed
        _clampPendingWrap();
        _indexDown();
      case 13: // Carriage return
        cursorX = 0;
    }
  }

  void _handleDecPrivateMode(String command, List<int> params) {
    if (command != 'h' && command != 'l') return;
    final enable = command == 'h';
    for (final param in params) {
      _applyDecPrivateModeParam(param, enable);
    }
  }

  void _applyDecPrivateModeParam(int param, bool enable) {
    switch (param) {
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
      case 1000 || 1002 || 1003:
        mouseTrackingEnabled = enable;
      case 1006:
        sgrMouseMode = enable;
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
    cursorY = saved.y.clamp(0, height - 1);
    _currentStyle = saved.style;
  }

  @override
  void csi(String command, List<int> params, {String? intermediate}) {
    if (intermediate != null) {
      if (intermediate == '?') {
        _handleDecPrivateMode(command, params);
      } else if (intermediate == '!' && command == 'p') {
        _resetState(fullReset: false);
      }
      return;
    }

    final p1 = _clampedPositiveParam(params, 0);
    final p2 = _clampedPositiveParam(params, 1);
    if (_tryHandleCursorCsi(command, p1, p2)) return;
    _handleEditingOrModeCsi(command, params, p1);
  }

  static int _clampedPositiveParam(List<int> params, int index) {
    if (index >= params.length || params[index] <= 0) return 1;
    return math.min(params[index], 0xFFFF);
  }

  bool _tryHandleCursorCsi(String command, int p1, int p2) {
    switch (command) {
      case 'A': // Cursor Up (CUU)
        _clampPendingWrap();
        cursorY = math.max(0, cursorY - p1);
      case 'B': // Cursor Down (CUD)
        _clampPendingWrap();
        cursorY = math.min(height - 1, cursorY + p1);
      case 'C': // Cursor Forward (CUF)
        _clampPendingWrap();
        cursorX = math.min(width - 1, cursorX + p1);
      case 'D': // Cursor Back (CUB)
        _clampPendingWrap();
        cursorX = math.max(0, cursorX - p1);
      case 'E': // Cursor Next Line (CNL)
        cursorX = 0;
        cursorY = math.min(height - 1, cursorY + p1);
      case 'F': // Cursor Preceding Line (CPL)
        cursorX = 0;
        cursorY = math.max(0, cursorY - p1);
      case 'G' || '`': // Cursor Character Absolute (CHA / HPA)
        cursorX = (p1 - 1).clamp(0, width - 1);
      case 'd': // Line Position Absolute (VPA)
        _clampPendingWrap();
        cursorY = (p1 - 1).clamp(0, height - 1);
      case 'H' || 'f': // Cursor Position (CUP / HVP)
        cursorX = (p2 - 1).clamp(0, width - 1);
        cursorY = (p1 - 1).clamp(0, height - 1);
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
        _scrollRegion(_scrollTop, _scrollBottom, p1, up: true);
      case 'T':
        _scrollRegion(_scrollTop, _scrollBottom, p1, up: false);
      case 'r':
        _setScrollRegion(params);
      case 's':
        if (params.isEmpty) _saveCursor();
      case 'u':
        _restoreCursor();
      case 'm':
        _applySgr(params);
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
      cursorY = 0;
    }
  }

  void _insertLines(int count) {
    _clampPendingWrap();
    if (cursorY < _scrollTop || cursorY > _scrollBottom) return;
    _scrollRegion(cursorY, _scrollBottom, count, up: false);
  }

  void _deleteLines(int count) {
    _clampPendingWrap();
    if (cursorY < _scrollTop || cursorY > _scrollBottom) return;
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

  void _applySgr(List<int> params) {
    if (params.isEmpty) {
      _currentStyle = .empty;
      return;
    }
    var i = 0;
    while (i < params.length) {
      final code = params[i];
      if (code == 38 || code == 48) {
        final (color, consumed) = _parseExtendedColor(params, i);
        if (color != null) {
          _currentStyle = code == 38
              ? _currentStyle.merge(Style(foreground: color))
              : _currentStyle.merge(Style(background: color));
        }
        i += consumed;
        continue;
      }
      _applySingleSgrCode(code);
      i++;
    }
  }

  (Color?, int) _parseExtendedColor(List<int> params, int index) {
    if (index + 1 >= params.length) return (null, 1);
    final mode = params[index + 1];
    if (mode == 5) {
      if (index + 2 >= params.length) return (null, params.length - index);
      return (_colorFromAnsi256(params[index + 2]), 3);
    }
    if (mode == 2) {
      if (index + 4 >= params.length) return (null, params.length - index);
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
      case 1 || 2 || 3 || 4 || 5 || 7 || 8 || 9:
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
    4 => Modifier.underline,
    5 => Modifier.blink,
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
    // Ignore OSC for now
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
