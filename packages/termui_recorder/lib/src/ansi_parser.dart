import 'package:characters/characters.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/style.dart';

/// A simple parser that reconstructs a [Buffer] from a styled ANSI string or stream.
abstract final class AnsiParser {
  /// Parses a styled ANSI string back into a [Buffer].
  ///
  /// If [width] or [height] are not specified, they are computed from the ANSI content.
  static Buffer parse(String ansi, {int? width, int? height}) =>
      BufferAnsiSerialization.fromAnsi(ansi, width: width, height: height);

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

    final iterator = ansiStream.characters.iterator;
    while (iterator.moveNext()) {
      final char = iterator.current;
      if (char == '\n' || char == '\r\n') {
        x = 0;
        y++;
      } else if (char == '\r') {
        x = 0;
      } else if (char == '\x1b') {
        if (_consumeCsiSequence(iterator) case (final command, final params)) {
          (x, y, style) = _applyCsiCommand(
            command,
            params,
            buffer,
            x,
            y,
            style,
          );
        }
      } else {
        x = _writeStreamGrapheme(buffer, x, y, char, style);
      }
    }

    return (x, y, style);
  }

  static (String command, String params)? _consumeCsiSequence(
    Iterator<String> iterator,
  ) {
    if (!iterator.moveNext() || iterator.current != '[') return null;
    final paramBuffer = StringBuffer();
    while (iterator.moveNext()) {
      final nextChar = iterator.current;
      if (_isAnsiTerminator(nextChar)) {
        return (nextChar, paramBuffer.toString());
      }
      paramBuffer.write(nextChar);
    }
    return null;
  }

  static (int x, int y, Style style) _applyCsiCommand(
    String command,
    String params,
    Buffer buffer,
    int x,
    int y,
    Style style,
  ) => switch (command) {
    'm' => (x, y, _applyAnsiCodes(style, params)),
    'H' => _moveCursorToPosition(params, x, y, style),
    'A' => (x, y - (int.tryParse(params) ?? 1), style),
    'C' => (x + (int.tryParse(params) ?? 1), y, style),
    'D' => (x - (int.tryParse(params) ?? 1), y, style),
    'F' => (0, y - (int.tryParse(params) ?? 1), style),
    'J' => (x, y, _clearIfFullErase(buffer, params, style)),
    _ => (x, y, style),
  };

  static (int x, int y, Style style) _moveCursorToPosition(
    String params,
    int fallbackX,
    int fallbackY,
    Style style,
  ) {
    if (params.isEmpty) return (0, 0, style);
    if (params.split(';') case [final rStr, final cStr]) {
      return (
        (int.tryParse(cStr) ?? 1) - 1,
        (int.tryParse(rStr) ?? 1) - 1,
        style,
      );
    }
    return (fallbackX, fallbackY, style);
  }

  static Style _clearIfFullErase(Buffer buffer, String params, Style style) {
    if (params == '2') buffer.clear();
    return style;
  }

  static int _writeStreamGrapheme(
    Buffer buffer,
    int x,
    int y,
    String char,
    Style style,
  ) {
    final w = graphemeWidth(char);
    if (w == 0) return x;
    if (y >= 0 && y < buffer.height && x >= 0 && x < buffer.width) {
      buffer.setAttributes(
        x,
        y,
        char: char,
        fg: style.foreground?.argb ?? 0,
        bg: style.background?.argb ?? 0,
        modifiers: style.modifiers,
        blend: false,
      );
      return x + w;
    }
    return x;
  }

  static bool _isAnsiTerminator(String char) {
    if (char.isEmpty) return false;
    final code = char.codeUnitAt(0);
    return code >= 0x40 && code <= 0x7E;
  }

  static Style _applyAnsiCodes(Style current, String paramString) {
    if (paramString.isEmpty || paramString == '0') {
      return .empty;
    }

    final codes = [
      for (final s in paramString.split(';')) int.tryParse(s) ?? 0,
    ];
    var style = current;
    var i = 0;

    while (i < codes.length) {
      final code = codes[i];
      if ((code == 38 || code == 48) &&
          i + 4 < codes.length &&
          codes[i + 1] == 2) {
        final color = Color(codes[i + 2], codes[i + 3], codes[i + 4]);
        style = code == 38
            ? Style(
                foreground: color,
                background: style.background,
                modifiers: style.modifiers,
              )
            : Style(
                foreground: style.foreground,
                background: color,
                modifiers: style.modifiers,
              );
        i += 5;
      } else {
        style = _applySingleAnsiCode(style, code);
        i++;
      }
    }

    return style;
  }

  static Style _applySingleAnsiCode(Style s, int code) => switch (code) {
    0 => .empty,
    1 => Style(
      foreground: s.foreground,
      background: s.background,
      modifiers: s.modifiers | Modifier.bold,
    ),
    2 => Style(
      foreground: s.foreground,
      background: s.background,
      modifiers: s.modifiers | Modifier.dim,
    ),
    3 => Style(
      foreground: s.foreground,
      background: s.background,
      modifiers: s.modifiers | Modifier.italic,
    ),
    4 => Style(
      foreground: s.foreground,
      background: s.background,
      modifiers: s.modifiers | Modifier.underline,
    ),
    5 => Style(
      foreground: s.foreground,
      background: s.background,
      modifiers: s.modifiers | Modifier.blink,
    ),
    7 => Style(
      foreground: s.foreground,
      background: s.background,
      modifiers: s.modifiers | Modifier.reverse,
    ),
    8 => Style(
      foreground: s.foreground,
      background: s.background,
      modifiers: s.modifiers | Modifier.hidden,
    ),
    9 => Style(
      foreground: s.foreground,
      background: s.background,
      modifiers: s.modifiers | Modifier.crossedOut,
    ),
    22 => Style(
      foreground: s.foreground,
      background: s.background,
      modifiers: s.modifiers & ~(Modifier.bold | Modifier.dim),
    ),
    23 => Style(
      foreground: s.foreground,
      background: s.background,
      modifiers: s.modifiers & ~Modifier.italic,
    ),
    24 => Style(
      foreground: s.foreground,
      background: s.background,
      modifiers: s.modifiers & ~Modifier.underline,
    ),
    25 => Style(
      foreground: s.foreground,
      background: s.background,
      modifiers: s.modifiers & ~Modifier.blink,
    ),
    27 => Style(
      foreground: s.foreground,
      background: s.background,
      modifiers: s.modifiers & ~Modifier.reverse,
    ),
    28 => Style(
      foreground: s.foreground,
      background: s.background,
      modifiers: s.modifiers & ~Modifier.hidden,
    ),
    29 => Style(
      foreground: s.foreground,
      background: s.background,
      modifiers: s.modifiers & ~Modifier.crossedOut,
    ),
    39 => Style(
      foreground: null,
      background: s.background,
      modifiers: s.modifiers,
    ),
    49 => Style(
      foreground: s.foreground,
      background: null,
      modifiers: s.modifiers,
    ),
    _ => s,
  };
}
