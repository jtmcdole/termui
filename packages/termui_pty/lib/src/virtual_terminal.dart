import 'package:termui/termui.dart';
import 'ansi_parser.dart';

/// A virtual terminal that maintains a screen buffer and cursor state,
/// mutating them in response to ANSI escape sequences.
class VirtualTerminal implements TerminalHandler {
  final int width;
  final int height;

  Buffer _buffer;
  Buffer get buffer => _buffer;

  int cursorX = 0;
  int cursorY = 0;

  Style _currentStyle = Style.empty;
  late final AnsiParser _parser;

  VirtualTerminal({this.width = 80, this.height = 24})
      : _buffer = Buffer.blank(width, height) {
    _parser = AnsiParser(this);
  }

  void resize(int newWidth, int newHeight) {
    _buffer.resize(newWidth, newHeight);
    if (cursorX >= width) cursorX = width > 0 ? width - 1 : 0;
    if (cursorY >= height) cursorY = height > 0 ? height - 1 : 0;
  }

  /// Feeds a chunk of data into the terminal.
  void write(List<int> chunk) {
    _parser.parse(String.fromCharCodes(chunk));
  }

  void _scrollUp() {
    final chars = _buffer.characters;
    final attrs = _buffer.attributes;
    final rowCount = width;

    // Shift up by 1 row
    chars.setRange(0, chars.length - rowCount, chars, rowCount);
    chars.fillRange(chars.length - rowCount, chars.length, ' ');

    final attrCount = rowCount * 3;
    attrs.setRange(0, attrs.length - attrCount, attrs, attrCount);
    
    // Fill bottom row with empty/transparent
    for (var i = attrs.length - attrCount; i < attrs.length; i += 3) {
      attrs[i] = 0; // fg
      attrs[i + 1] = 0; // bg
      attrs[i + 2] = Modifier.transparent; // mod
    }
  }

  @override
  void printText(String text) {
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (cursorX >= width) {
        cursorX = 0;
        cursorY++;
      }
      if (cursorY >= height) {
        _scrollUp();
        cursorY = height - 1;
      }
      
      _buffer.setAttributes(
        cursorX, 
        cursorY, 
        char: char, 
        fg: _currentStyle.foreground?.argb ?? 0,
        bg: _currentStyle.background?.argb ?? 0,
        modifiers: _currentStyle.modifiers,
      );
      cursorX++;
    }
  }

  @override
  void execute(int charCode) {
    switch (charCode) {
      case 8: // Backspace
        if (cursorX > 0) cursorX--;
        break;
      case 10: // Line feed
      case 11: // Vertical tab
      case 12: // Form feed
        cursorY++;
        if (cursorY >= height) {
          _scrollUp();
          cursorY = height - 1;
        }
        break;
      case 13: // Carriage return
        cursorX = 0;
        break;
    }
  }

  @override
  void csi(String command, List<int> params, {String? intermediate}) {
    final p1 = params.isNotEmpty && params[0] != 0 ? params[0] : 1;
    final p2 = params.length > 1 && params[1] != 0 ? params[1] : 1;

    switch (command) {
      case 'A': // Cursor Up
        cursorY -= p1;
        if (cursorY < 0) cursorY = 0;
        break;
      case 'B': // Cursor Down
        cursorY += p1;
        if (cursorY >= height) cursorY = height - 1;
        break;
      case 'C': // Cursor Forward
        cursorX += p1;
        if (cursorX >= width) cursorX = width - 1;
        break;
      case 'D': // Cursor Back
        cursorX -= p1;
        if (cursorX < 0) cursorX = 0;
        break;
      case 'H': // Cursor Position
      case 'f':
        cursorY = p1 - 1;
        cursorX = p2 - 1;
        if (cursorX < 0) cursorX = 0;
        if (cursorY < 0) cursorY = 0;
        if (cursorX >= width) cursorX = width - 1;
        if (cursorY >= height) cursorY = height - 1;
        break;
      case 'J': // Erase in Display
        final param = params.isEmpty ? 0 : params[0];
        if (param == 0) { // Below
          for (var y = cursorY; y < height; y++) {
            final startX = (y == cursorY) ? cursorX : 0;
            for (var x = startX; x < width; x++) {
              _buffer.setAttributes(x, y, char: ' ', fg: 0, bg: 0, modifiers: Modifier.none);
            }
          }
        } else if (param == 1) { // Above
          for (var y = 0; y <= cursorY; y++) {
            final endX = (y == cursorY) ? cursorX : width - 1;
            for (var x = 0; x <= endX; x++) {
              _buffer.setAttributes(x, y, char: ' ', fg: 0, bg: 0, modifiers: Modifier.none);
            }
          }
        } else if (param == 2 || param == 3) { // All
          _buffer.fillAttributes(char: ' ', fg: 0, bg: 0, modifiers: Modifier.none);
        }
        break;
      case 'K': // Erase in Line
        final param = params.isEmpty ? 0 : params[0];
        if (param == 0) { // Right
          for (var x = cursorX; x < width; x++) {
            _buffer.setAttributes(x, cursorY, char: ' ', fg: 0, bg: 0, modifiers: Modifier.none);
          }
        } else if (param == 1) { // Left
          for (var x = 0; x <= cursorX; x++) {
            _buffer.setAttributes(x, cursorY, char: ' ', fg: 0, bg: 0, modifiers: Modifier.none);
          }
        } else if (param == 2) { // All
          for (var x = 0; x < width; x++) {
            _buffer.setAttributes(x, cursorY, char: ' ', fg: 0, bg: 0, modifiers: Modifier.none);
          }
        }
        break;
      case 'm': // SGR (Select Graphic Rendition)
        if (params.isEmpty) {
          _currentStyle = Style.empty;
        } else {
          for (var i = 0; i < params.length; i++) {
            final code = params[i];
            if (code == 0) {
              _currentStyle = Style.empty;
            } else if (code == 1) {
              _currentStyle = _currentStyle.merge(const Style(modifiers: Modifier.bold));
            } else if (code == 31) {
              _currentStyle = _currentStyle.merge(const Style(foreground: Colors.red));
            } // ... add more colors as needed
          }
        }
        break;
    }
  }

  @override
  void osc(int command, String payload) {
    // Ignore OSC for now
  }

  @override
  void esc(String command) {
    // Handling sequences like ESC M (Reverse Index) could be added here
  }
}
