import 'package:characters/characters.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/style.dart';

/// A simple parser that reconstructs a [Buffer] from a styled ANSI string or stream.
abstract final class AnsiParser {
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
    Style currentStyle = .empty;

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
        buffer.setAttributes(
          x,
          y,
          char: char,
          fg: currentStyle.foreground?.argb ?? 0,
          bg: currentStyle.background?.argb ?? 0,
          modifiers: currentStyle.modifiers,
        );
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
    Style currentStyle = .empty,
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
          switch (command) {
            case 'm':
              style = _applyAnsiCodes(style, params);
            case 'H':
              if (params.isEmpty) {
                x = 0;
                y = 0;
              } else if (params.split(';') case [final rStr, final cStr]) {
                y = (int.tryParse(rStr) ?? 1) - 1;
                x = (int.tryParse(cStr) ?? 1) - 1;
              }
            case 'A':
              final n = int.tryParse(params) ?? 1;
              y -= n;
            case 'C':
              final n = int.tryParse(params) ?? 1;
              x += n;
            case 'D':
              final n = int.tryParse(params) ?? 1;
              x -= n;
            case 'F':
              final n = int.tryParse(params) ?? 1;
              y -= n;
              x = 0;
            case 'J':
              if (params == '2') {
                buffer.clear();
              }
          }
        }
        continue;
      }

      // Normal character: write it
      if (y >= 0 && y < buffer.height && x >= 0 && x < buffer.width) {
        buffer.setAttributes(
          x,
          y,
          char: char,
          fg: style.foreground?.argb ?? 0,
          bg: style.background?.argb ?? 0,
          modifiers: style.modifiers,
        );
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
      return .empty;
    }

    final codes = [
      for (final s in paramString.split(';')) int.tryParse(s) ?? 0,
    ];
    var foreground = current.foreground;
    var background = current.background;
    var modifiers = current.modifiers;

    var i = 0;
    while (i < codes.length) {
      final code = codes[i];
      switch (code) {
        case 0:
          foreground = null;
          background = null;
          modifiers = Modifier.none;
          i++;
        case 1:
          modifiers |= Modifier.bold;
          i++;
        case 2:
          modifiers |= Modifier.dim;
          i++;
        case 3:
          modifiers |= Modifier.italic;
          i++;
        case 4:
          modifiers |= Modifier.underline;
          i++;
        case 5:
          modifiers |= Modifier.blink;
          i++;
        case 7:
          modifiers |= Modifier.reverse;
          i++;
        case 8:
          modifiers |= Modifier.hidden;
          i++;
        case 9:
          modifiers |= Modifier.crossedOut;
          i++;
        case 38 when i + 4 < codes.length && codes[i + 1] == 2:
          final r = codes[i + 2];
          final g = codes[i + 3];
          final b = codes[i + 4];
          foreground = Color(r, g, b);
          i += 5;
        case 48 when i + 4 < codes.length && codes[i + 1] == 2:
          final r = codes[i + 2];
          final g = codes[i + 3];
          final b = codes[i + 4];
          background = Color(r, g, b);
          i += 5;
        default:
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
