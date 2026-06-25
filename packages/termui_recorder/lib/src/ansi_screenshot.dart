import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';

/// A utility class to serialize a [Buffer] into a styled ANSI string representation.
class AnsiScreenshot {
  /// Converts the given [Buffer] to a styled ANSI string representation.
  ///
  /// Set [resetLineEndings] to true to output `\x1b[0m` at the end of every row.
  static String capture(Buffer buffer, {bool resetLineEndings = true}) {
    final sb = StringBuffer();
    Style activeStyle = Style.empty;

    for (var y = 0; y < buffer.height; y++) {
      for (var x = 0; x < buffer.width; x++) {
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

      if (resetLineEndings && activeStyle != Style.empty) {
        sb.write('\x1b[0m');
        activeStyle = Style.empty;
      }
      sb.write('\n');
    }

    // Ensure final reset
    if (activeStyle != Style.empty) {
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

    if (target == Style.empty) {
      sb.write('\x1b[0m');
      return Style.empty;
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
      effectiveCurrent = Style.empty;
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
        int code = 0;
        switch (mod) {
          case Modifier.bold:
            code = 1;
            break;
          case Modifier.dim:
            code = 2;
            break;
          case Modifier.italic:
            code = 3;
            break;
          case Modifier.underline:
            code = 4;
            break;
          case Modifier.blink:
            code = 5;
            break;
          case Modifier.reverse:
            code = 7;
            break;
          case Modifier.hidden:
            code = 8;
            break;
          case Modifier.crossedOut:
            code = 9;
            break;
        }
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
