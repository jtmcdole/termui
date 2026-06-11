import 'package:characters/characters.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/style.dart';

/// A simple parser that reconstructs a [Buffer] from a styled ANSI string or stream.
class AnsiParser {
  /// Parses a styled ANSI string back into a [Buffer].
  ///
  /// If [width] or [height] are not specified, they are computed from the ANSI content.
  static Buffer parse(String ansi, {int? width, int? height}) {
    // Determine dimensions first
    final lines = ansi.endsWith('\n')
        ? ansi.substring(0, ansi.length - 1).split('\n')
        : ansi.split('\n');

    final computedHeight = lines.length;
    var computedWidth = 0;

    for (final line in lines) {
      final plainLength = _stripAnsi(line).characters.length;
      if (plainLength > computedWidth) {
        computedWidth = plainLength;
      }
    }

    final targetWidth = width ?? computedWidth;
    final targetHeight = height ?? computedHeight;

    final buffer = Buffer.blank(targetWidth, targetHeight);

    var x = 0;
    var y = 0;
    var currentStyle = Style.empty;

    final chars = ansi.characters;
    final iterator = chars.iterator;

    while (iterator.moveNext()) {
      final char = iterator.current;

      if (char == '\n') {
        x = 0;
        y++;
        continue;
      }

      if (char == '\x1b') {
        // Parse escape sequence
        if (iterator.moveNext() && iterator.current == '[') {
          final paramBuffer = StringBuffer();
          while (iterator.moveNext()) {
            final nextChar = iterator.current;
            if (nextChar == 'm') {
              break;
            }
            paramBuffer.write(nextChar);
          }
          currentStyle = _applyAnsiCodes(currentStyle, paramBuffer.toString());
        }
        continue;
      }

      if (y < targetHeight && x < targetWidth) {
        buffer.setCell(x, y, Cell(char, currentStyle));
        x++;
      }
    }

    return buffer;
  }

  /// Applies a sequence of streaming ANSI delta commands to an existing [Buffer].
  ///
  /// Returns the updated cursor coordinates and style state as a record.
  static (int cursorX, int cursorY, Style currentStyle) parseStream(
    String ansiStream,
    Buffer buffer, {
    int cursorX = 0,
    int cursorY = 0,
    Style currentStyle = Style.empty,
  }) {
    var x = cursorX;
    var y = cursorY;
    var style = currentStyle;

    final chars = ansiStream.characters;
    final iterator = chars.iterator;

    while (iterator.moveNext()) {
      final char = iterator.current;

      if (char == '\n') {
        x = 0;
        y++;
        continue;
      }
      if (char == '\r') {
        x = 0;
        continue;
      }

      if (char == '\x1b') {
        if (iterator.moveNext() && iterator.current == '[') {
          final paramBuffer = StringBuffer();
          var command = '';
          while (iterator.moveNext()) {
            final nextChar = iterator.current;
            if (_isAnsiTerminator(nextChar)) {
              command = nextChar;
              break;
            }
            paramBuffer.write(nextChar);
          }

          final params = paramBuffer.toString();
          if (command == 'm') {
            style = _applyAnsiCodes(style, params);
          } else if (command == 'H') {
            if (params.isEmpty) {
              x = 0;
              y = 0;
            } else {
              final parts = params.split(';');
              if (parts.length == 2) {
                y = (int.tryParse(parts[0]) ?? 1) - 1;
                x = (int.tryParse(parts[1]) ?? 1) - 1;
              }
            }
          } else if (command == 'A') {
            final n = int.tryParse(params) ?? 1;
            y -= n;
          } else if (command == 'C') {
            final n = int.tryParse(params) ?? 1;
            x += n;
          } else if (command == 'D') {
            final n = int.tryParse(params) ?? 1;
            x -= n;
          } else if (command == 'F') {
            final n = int.tryParse(params) ?? 1;
            y -= n;
            x = 0;
          } else if (command == 'J') {
            if (params == '2') {
              buffer.clear();
            }
          }
        }
        continue;
      }

      // Normal character: write it
      if (y >= 0 && y < buffer.height && x >= 0 && x < buffer.width) {
        buffer.setCell(x, y, Cell(char, style));
        x++;
      }
    }

    return (x, y, style);
  }

  static bool _isAnsiTerminator(String char) {
    if (char.isEmpty) return false;
    final code = char.codeUnitAt(0);
    return (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
  }

  static String _stripAnsi(String input) {
    final ansiRegex = RegExp(r'\x1b\[[0-9;]*m');
    return input.replaceAll(ansiRegex, '');
  }

  static Style _applyAnsiCodes(Style current, String paramString) {
    if (paramString.isEmpty || paramString == '0') {
      return Style.empty;
    }

    final codes = paramString
        .split(';')
        .map((s) => int.tryParse(s) ?? 0)
        .toList();
    var foreground = current.foreground;
    var background = current.background;
    var modifiers = current.modifiers;

    var i = 0;
    while (i < codes.length) {
      final code = codes[i];
      if (code == 0) {
        foreground = null;
        background = null;
        modifiers = Modifier.none;
        i++;
      } else if (code == 1) {
        modifiers |= Modifier.bold;
        i++;
      } else if (code == 2) {
        modifiers |= Modifier.dim;
        i++;
      } else if (code == 3) {
        modifiers |= Modifier.italic;
        i++;
      } else if (code == 4) {
        modifiers |= Modifier.underline;
        i++;
      } else if (code == 5) {
        modifiers |= Modifier.blink;
        i++;
      } else if (code == 7) {
        modifiers |= Modifier.reverse;
        i++;
      } else if (code == 8) {
        modifiers |= Modifier.hidden;
        i++;
      } else if (code == 9) {
        modifiers |= Modifier.crossedOut;
        i++;
      } else if (code == 38 && i + 4 < codes.length && codes[i + 1] == 2) {
        final r = codes[i + 2];
        final g = codes[i + 3];
        final b = codes[i + 4];
        foreground = Color(r, g, b);
        i += 5;
      } else if (code == 48 && i + 4 < codes.length && codes[i + 1] == 2) {
        final r = codes[i + 2];
        final g = codes[i + 3];
        final b = codes[i + 4];
        background = Color(r, g, b);
        i += 5;
      } else {
        // Unknown code, skip
        i++;
      }
    }

    return Style(
      foreground: foreground,
      background: background,
      modifiers: modifiers,
    );
  }
}
