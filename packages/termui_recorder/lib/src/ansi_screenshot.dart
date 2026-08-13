import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';

/// A utility class to serialize a [Buffer] into a styled ANSI string representation.
abstract final class AnsiScreenshot {
  /// Converts the given [Buffer] to a styled ANSI string representation.
  ///
  /// Set [resetLineEndings] to true to output `\x1b[0m` at the end of every row.
  static String capture(Buffer buffer, {bool resetLineEndings = true}) {
    final sb = StringBuffer();
    Style activeStyle = .empty;

    for (var y = 0; y < buffer.height; y++) {
      var lastCol = buffer.width - 1;
      while (lastCol >= 0) {
        final char = buffer.getCharacter(lastCol, y);
        final bg = buffer.getBackground(lastCol, y);
        final mods = buffer.getModifiers(lastCol, y);
        if ((char == ' ' || char == '') && bg == 0 && mods == 0) {
          lastCol--;
        } else {
          break;
        }
      }

      for (var x = 0; x <= lastCol; x++) {
        final char = buffer.getCharacter(x, y);
        // Do not skip transparent spaces; they are needed for alignment

        // Wide character padding cells are represented by empty strings. Skip them.
        if (char == '') continue;

        final currentStyle = Style(
          foreground: buffer.getForeground(x, y) == 0
              ? null
              : Color.argb(buffer.getForeground(x, y)),
          background: buffer.getBackground(x, y) == 0
              ? null
              : Color.argb(buffer.getBackground(x, y)),
          modifiers: buffer.getModifiers(x, y),
        );

        activeStyle = _writeStyleTransition(sb, activeStyle, currentStyle);
        sb.write(char);
      }

      if (resetLineEndings && activeStyle != .empty) {
        sb.write('\x1b[0m');
        activeStyle = .empty;
      }
      sb.write('\n');
    }

    // Ensure final reset
    if (activeStyle != .empty) {
      sb.write('\x1b[0m');
    }

    return sb.toString();
  }

  static Style _writeStyleTransition(
    StringBuffer sb,
    Style current,
    Style target,
  ) {
    if (current == target) return current;

    if (target == .empty) {
      sb.write('\x1b[0m');
      return .empty;
    }

    final colorCleared =
        (current.foreground != null && target.foreground == null) ||
        (current.background != null && target.background == null);

    bool modifierTurnedOff = false;
    for (var i = 0; i < 8; i++) {
      final mod = 1 << i;
      if (Modifier.has(current.modifiers, mod) &&
          !Modifier.has(target.modifiers, mod)) {
        modifierTurnedOff = true;
        break;
      }
    }

    var effectiveCurrent = current;
    if (colorCleared || modifierTurnedOff) {
      sb.write('\x1b[0m');
      effectiveCurrent = .empty;
    }

    final codeBuilder = StringBuffer();

    if (target.foreground != effectiveCurrent.foreground &&
        target.foreground != null) {
      final fg = target.foreground!;
      codeBuilder.write('38;2;${fg.r};${fg.g};${fg.b};');
    }

    if (target.background != effectiveCurrent.background &&
        target.background != null) {
      final bg = target.background!;
      codeBuilder.write('48;2;${bg.r};${bg.g};${bg.b};');
    }

    for (var i = 0; i < 8; i++) {
      final mod = 1 << i;
      if (Modifier.has(target.modifiers, mod) &&
          !Modifier.has(effectiveCurrent.modifiers, mod)) {
        final code = switch (mod) {
          Modifier.bold => 1,
          Modifier.dim => 2,
          Modifier.italic => 3,
          Modifier.underline => 4,
          Modifier.blink => 5,
          Modifier.reverse => 7,
          Modifier.hidden => 8,
          Modifier.crossedOut => 9,
          _ => 0,
        };
        if (code != 0) {
          codeBuilder.write('$code;');
        }
      }
    }

    var s = codeBuilder.toString();
    if (s.isNotEmpty) {
      if (s.endsWith(';')) {
        s = s.substring(0, s.length - 1);
      }
      sb.write('\x1b[${s}m');
    }

    return target;
  }
}
