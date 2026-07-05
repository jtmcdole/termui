import 'package:termui/termui.dart';
import 'ansi_parser.dart';

/// A virtual terminal that maintains a screen buffer and cursor state,
/// mutating them in response to ANSI escape sequences.
class VirtualTerminal implements TerminalHandler {
  /// The width of the virtual terminal in columns.
  int width;

  /// The height of the virtual terminal in rows.
  int height;

  final Buffer _buffer;

  /// The underlying screen buffer of this terminal.
  Buffer get buffer => _buffer;

  /// The 0-indexed X coordinate of the cursor.
  int cursorX = 0;

  /// The 0-indexed Y coordinate of the cursor.
  int cursorY = 0;

  Style _currentStyle = Style.empty;
  late final AnsiParser _parser;

  /// Whether the terminal background should be rendered as transparent.
  final bool transparentBackground;

  /// The default foreground color applied to characters when no explicit color is set.
  final Color? defaultForeground;

  /// Whether mouse tracking is enabled (set by DECSET 1000 or similar).
  bool mouseTrackingEnabled = false;

  /// Whether SGR mouse reporting mode is enabled (set by DECSET 1006).
  bool sgrMouseMode = false;

  final List<void Function()> _listeners = [];

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
    _listeners.clear();
  }

  void _notifyListeners() {
    for (final listener in _listeners) {
      listener();
    }
  }

  /// Creates a new virtual terminal with the specified dimensions and settings.
  VirtualTerminal({
    this.width = 80,
    this.height = 24,
    this.transparentBackground = false,
    this.defaultForeground,
  }) : _buffer = Buffer.blank(width, height) {
    if (transparentBackground) {
      _buffer.fillAttributes(
        char: ' ',
        fg: 0,
        bg: 0,
        modifiers: Modifier.transparent,
      );
    }
    _parser = AnsiParser(this);
  }

  /// Resizes the virtual terminal to the new [newWidth] and [newHeight].
  void resize(int newWidth, int newHeight) {
    if (newWidth == width && newHeight == height) return;
    _buffer.resize(newWidth, newHeight);

    if (transparentBackground) {
      final size = newWidth * newHeight;
      for (var i = 0; i < size; i++) {
        if (_buffer.characters[i] == ' ' &&
            _buffer.attributes[i * 3 + 1] == 0) {
          _buffer.attributes[i * 3 + 2] |= Modifier.transparent;
        }
      }
    }

    width = newWidth;
    height = newHeight;
    cursorX = cursorX.clamp(0, width - 1);
    cursorY = cursorY.clamp(0, height - 1);
  }

  /// Feeds a chunk of data into the terminal.
  void write(List<int> chunk) {
    _parser.parse(String.fromCharCodes(chunk));
    _notifyListeners();
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

      int fgArg = _currentStyle.foreground?.argb ?? 0;
      int bgArg = _currentStyle.background?.argb ?? 0;
      int modArg = _currentStyle.modifiers;

      final isBgTransparent =
          transparentBackground && (bgArg == 0 || bgArg == 0xFF000000);
      if (isBgTransparent) {
        bgArg = 0;
        if (fgArg == 0) {
          fgArg =
              defaultForeground?.argb ??
              0xFFFFFFFF; // Use defaultForeground if provided, otherwise white
        }
        if (char == ' ') {
          modArg |= Modifier.transparent;
        }
      } else if (fgArg == 0 && defaultForeground != null) {
        // Even if not transparent, apply default foreground to empty styles if configured
        fgArg = defaultForeground!.argb;
      }

      _buffer.setAttributes(
        cursorX,
        cursorY,
        char: char,
        fg: fgArg,
        bg: bgArg,
        modifiers: modArg,
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

    if (intermediate == '?') {
      if (command == 'h') {
        for (final param in params) {
          if (param == 1000) mouseTrackingEnabled = true;
          if (param == 1002) mouseTrackingEnabled = true;
          if (param == 1003) mouseTrackingEnabled = true;
          if (param == 1006) sgrMouseMode = true;
        }
        return;
      } else if (command == 'l') {
        for (final param in params) {
          if (param == 1000) mouseTrackingEnabled = false;
          if (param == 1002) mouseTrackingEnabled = false;
          if (param == 1003) mouseTrackingEnabled = false;
          if (param == 1006) sgrMouseMode = false;
        }
        return;
      }
    }

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
        final eraseMod = transparentBackground
            ? Modifier.transparent
            : Modifier.none;
        if (param == 0) {
          // Below
          for (var y = cursorY; y < height; y++) {
            final startX = (y == cursorY) ? cursorX : 0;
            for (var x = startX; x < width; x++) {
              _buffer.setAttributes(
                x,
                y,
                char: ' ',
                fg: 0,
                bg: 0,
                modifiers: eraseMod,
              );
            }
          }
        } else if (param == 1) {
          // Above
          for (var y = 0; y <= cursorY; y++) {
            final endX = (y == cursorY) ? cursorX : width - 1;
            for (var x = 0; x <= endX; x++) {
              _buffer.setAttributes(
                x,
                y,
                char: ' ',
                fg: 0,
                bg: 0,
                modifiers: eraseMod,
              );
            }
          }
        } else if (param == 2 || param == 3) {
          // All
          _buffer.fillAttributes(char: ' ', fg: 0, bg: 0, modifiers: eraseMod);
        }
        break;
      case 'K': // Erase in Line
        final param = params.isEmpty ? 0 : params[0];
        final eraseMod = transparentBackground
            ? Modifier.transparent
            : Modifier.none;
        if (param == 0) {
          // Right
          for (var x = cursorX; x < width; x++) {
            _buffer.setAttributes(
              x,
              cursorY,
              char: ' ',
              fg: 0,
              bg: 0,
              modifiers: eraseMod,
            );
          }
        } else if (param == 1) {
          // Left
          for (var x = 0; x <= cursorX; x++) {
            _buffer.setAttributes(
              x,
              cursorY,
              char: ' ',
              fg: 0,
              bg: 0,
              modifiers: eraseMod,
            );
          }
        } else if (param == 2) {
          // All
          for (var x = 0; x < width; x++) {
            _buffer.setAttributes(
              x,
              cursorY,
              char: ' ',
              fg: 0,
              bg: 0,
              modifiers: eraseMod,
            );
          }
        }
        break;
      case 'm': // SGR (Select Graphic Rendition)
        if (params.isEmpty) {
          _currentStyle = Style.empty;
        } else {
          var i = 0;
          while (i < params.length) {
            final code = params[i];

            // True color & 256 color for Foreground
            if (code == 38) {
              if (i + 1 < params.length) {
                final mode = params[i + 1];
                if (mode == 5 && i + 2 < params.length) {
                  // 256 color
                  final colorIdx = params[i + 2];
                  _currentStyle = _currentStyle.merge(
                    Style(foreground: _colorFromAnsi256(colorIdx)),
                  );
                  i += 3;
                  continue;
                } else if (mode == 2 && i + 4 < params.length) {
                  // True color (RGB)
                  final r = params[i + 2];
                  final g = params[i + 3];
                  final b = params[i + 4];
                  _currentStyle = _currentStyle.merge(
                    Style(foreground: Color(r, g, b)),
                  );
                  i += 5;
                  continue;
                }
              }
            }
            // True color & 256 color for Background
            else if (code == 48) {
              if (i + 1 < params.length) {
                final mode = params[i + 1];
                if (mode == 5 && i + 2 < params.length) {
                  // 256 color
                  final colorIdx = params[i + 2];
                  _currentStyle = _currentStyle.merge(
                    Style(background: _colorFromAnsi256(colorIdx)),
                  );
                  i += 3;
                  continue;
                } else if (mode == 2 && i + 4 < params.length) {
                  // True color (RGB)
                  final r = params[i + 2];
                  final g = params[i + 3];
                  final b = params[i + 4];
                  _currentStyle = _currentStyle.merge(
                    Style(background: Color(r, g, b)),
                  );
                  i += 5;
                  continue;
                }
              }
            }

            // Standard SGR Codes
            switch (code) {
              case 0:
                _currentStyle = Style.empty;
                break;
              case 1:
                _currentStyle = _currentStyle.merge(
                  const Style(modifiers: Modifier.bold),
                );
                break;
              case 2:
                _currentStyle = _currentStyle.merge(
                  const Style(modifiers: Modifier.dim),
                );
                break;
              case 3:
                _currentStyle = _currentStyle.merge(
                  const Style(modifiers: Modifier.italic),
                );
                break;
              case 4:
                _currentStyle = _currentStyle.merge(
                  const Style(modifiers: Modifier.underline),
                );
                break;
              case 7:
                _currentStyle = _currentStyle.merge(
                  const Style(modifiers: Modifier.reverse),
                );
                break;
              case 8:
                _currentStyle = _currentStyle.merge(
                  const Style(modifiers: Modifier.hidden),
                );
                break;
              case 9:
                _currentStyle = _currentStyle.merge(
                  const Style(modifiers: Modifier.crossedOut),
                );
                break;
              case 22:
                _currentStyle = Style(
                  foreground: _currentStyle.foreground,
                  background: _currentStyle.background,
                  modifiers:
                      _currentStyle.modifiers & ~(Modifier.bold | Modifier.dim),
                );
                break;
              case 23:
                _currentStyle = Style(
                  foreground: _currentStyle.foreground,
                  background: _currentStyle.background,
                  modifiers: _currentStyle.modifiers & ~Modifier.italic,
                );
                break;
              case 24:
                _currentStyle = Style(
                  foreground: _currentStyle.foreground,
                  background: _currentStyle.background,
                  modifiers: _currentStyle.modifiers & ~Modifier.underline,
                );
                break;
              case 27:
                _currentStyle = Style(
                  foreground: _currentStyle.foreground,
                  background: _currentStyle.background,
                  modifiers: _currentStyle.modifiers & ~Modifier.reverse,
                );
                break;
              case 28:
                _currentStyle = Style(
                  foreground: _currentStyle.foreground,
                  background: _currentStyle.background,
                  modifiers: _currentStyle.modifiers & ~Modifier.hidden,
                );
                break;
              case 29:
                _currentStyle = Style(
                  foreground: _currentStyle.foreground,
                  background: _currentStyle.background,
                  modifiers: _currentStyle.modifiers & ~Modifier.crossedOut,
                );
                break;
              case 39: // Default Foreground
                _currentStyle = _currentStyle.merge(
                  const Style(foreground: null),
                );
                break;
              case 49: // Default Background
                _currentStyle = _currentStyle.merge(
                  const Style(background: null),
                );
                break;
              default:
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
                break;
            }
            i++;
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

  Color _colorFromAnsi256(int code) {
    if (code < 0 || code > 255) return Colors.white;

    // Standard 16 colors (0-15)
    if (code < 16) {
      const List<int> standard = [
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
      final rgb = standard[code];
      return Color((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);
    }

    // 6x6x6 color cube (16-231)
    if (code < 232) {
      code -= 16;
      final b = code % 6;
      final g = (code ~/ 6) % 6;
      final r = (code ~/ 36) % 6;
      final rVal = r == 0 ? 0 : r * 40 + 55;
      final gVal = g == 0 ? 0 : g * 40 + 55;
      final bVal = b == 0 ? 0 : b * 40 + 55;
      return Color(rVal, gVal, bVal);
    }

    // Grayscale ramp (232-255)
    final gray = (code - 232) * 10 + 8;
    return Color(gray, gray, gray);
  }
}
