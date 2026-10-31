import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/style.dart';
import 'package:termui_recorder/termui_recorder.dart';

void main() {
  group('AnsiScreenshot', () {
    test('renders plain text buffer without styles', () {
      final buffer = Buffer.blank(5, 2);
      buffer.setAttributes(
        0,
        0,
        char: 'H',
        fg: Style.empty.foreground?.argb,
        bg: Style.empty.background?.argb,
        modifiers: Style.empty.modifiers,
      );
      buffer.setAttributes(
        1,
        0,
        char: 'e',
        fg: Style.empty.foreground?.argb,
        bg: Style.empty.background?.argb,
        modifiers: Style.empty.modifiers,
      );
      buffer.setAttributes(
        2,
        0,
        char: 'l',
        fg: Style.empty.foreground?.argb,
        bg: Style.empty.background?.argb,
        modifiers: Style.empty.modifiers,
      );
      buffer.setAttributes(
        3,
        0,
        char: 'l',
        fg: Style.empty.foreground?.argb,
        bg: Style.empty.background?.argb,
        modifiers: Style.empty.modifiers,
      );
      buffer.setAttributes(
        4,
        0,
        char: 'o',
        fg: Style.empty.foreground?.argb,
        bg: Style.empty.background?.argb,
        modifiers: Style.empty.modifiers,
      );

      buffer.setAttributes(
        0,
        1,
        char: 'W',
        fg: Style.empty.foreground?.argb,
        bg: Style.empty.background?.argb,
        modifiers: Style.empty.modifiers,
      );
      buffer.setAttributes(
        1,
        1,
        char: 'o',
        fg: Style.empty.foreground?.argb,
        bg: Style.empty.background?.argb,
        modifiers: Style.empty.modifiers,
      );
      buffer.setAttributes(
        2,
        1,
        char: 'r',
        fg: Style.empty.foreground?.argb,
        bg: Style.empty.background?.argb,
        modifiers: Style.empty.modifiers,
      );
      buffer.setAttributes(
        3,
        1,
        char: 'l',
        fg: Style.empty.foreground?.argb,
        bg: Style.empty.background?.argb,
        modifiers: Style.empty.modifiers,
      );
      buffer.setAttributes(
        4,
        1,
        char: 'd',
        fg: Style.empty.foreground?.argb,
        bg: Style.empty.background?.argb,
        modifiers: Style.empty.modifiers,
      );

      final ansi = AnsiScreenshot.capture(buffer, resetLineEndings: true);
      expect(ansi, equals('Hello\nWorld\n'));
    });

    test('renders buffer with foreground and background colors', () {
      final buffer = Buffer.blank(3, 1);
      final redFgStyle = const Style(foreground: Color(255, 0, 0));
      final greenBgStyle = const Style(background: Color(0, 255, 0));

      buffer.setAttributes(
        0,
        0,
        char: 'R',
        fg: redFgStyle.foreground?.argb,
        bg: redFgStyle.background?.argb,
        modifiers: redFgStyle.modifiers,
      );
      buffer.setAttributes(
        1,
        0,
        char: 'G',
        fg: greenBgStyle.foreground?.argb,
        bg: greenBgStyle.background?.argb,
        modifiers: greenBgStyle.modifiers,
      );
      buffer.setAttributes(
        2,
        0,
        char: 'B',
        fg: Style.empty.foreground?.argb,
        bg: Style.empty.background?.argb,
        modifiers: Style.empty.modifiers,
      );

      final ansi = AnsiScreenshot.capture(buffer, resetLineEndings: true);

      expect(
        ansi,
        equals('\x1b[38;2;255;0;0mR\x1b[0m\x1b[48;2;0;255;0mG\x1b[0mB\n'),
      );
    });

    test('renders text modifiers correctly', () {
      final buffer = Buffer.blank(2, 1);
      final boldStyle = const Style(modifiers: Modifier.bold);
      final italicStyle = const Style(modifiers: Modifier.italic);

      buffer.setAttributes(
        0,
        0,
        char: 'B',
        fg: boldStyle.foreground?.argb,
        bg: boldStyle.background?.argb,
        modifiers: boldStyle.modifiers,
      );
      buffer.setAttributes(
        1,
        0,
        char: 'I',
        fg: italicStyle.foreground?.argb,
        bg: italicStyle.background?.argb,
        modifiers: italicStyle.modifiers,
      );

      final ansi = AnsiScreenshot.capture(buffer, resetLineEndings: true);

      expect(ansi, equals('\x1b[1mB\x1b[0m\x1b[3mI\x1b[0m\n'));
    });
  });

  group('AnsiParser', () {
    test('round-trips an ANSI styled string back to a Buffer', () {
      final buffer = Buffer.blank(3, 1);
      final redFgStyle = const Style(foreground: Color(255, 0, 0));
      final greenBgStyle = const Style(background: Color(0, 255, 0));

      buffer.setAttributes(
        0,
        0,
        char: 'R',
        fg: redFgStyle.foreground?.argb,
        bg: redFgStyle.background?.argb,
        modifiers: redFgStyle.modifiers,
      );
      buffer.setAttributes(
        1,
        0,
        char: 'G',
        fg: greenBgStyle.foreground?.argb,
        bg: greenBgStyle.background?.argb,
        modifiers: greenBgStyle.modifiers,
      );
      buffer.setAttributes(
        2,
        0,
        char: 'B',
        fg: Style.empty.foreground?.argb,
        bg: Style.empty.background?.argb,
        modifiers: Style.empty.modifiers,
      );

      final ansi = AnsiScreenshot.capture(buffer, resetLineEndings: true);

      final parsedBuffer = AnsiParser.parse(ansi);

      expect(parsedBuffer.width, equals(buffer.width));
      expect(parsedBuffer.height, equals(buffer.height));

      expect(parsedBuffer.getCharacter(0, 0), equals('R'));
      expect(
        parsedBuffer.getForeground(0, 0),
        equals(const Color(255, 0, 0).argb),
      );

      expect(parsedBuffer.getCharacter(1, 0), equals('G'));
      expect(
        parsedBuffer.getBackground(1, 0),
        equals(const Color(0, 255, 0).argb),
      );

      expect(parsedBuffer.getCharacter(2, 0), equals('B'));
      expect(parsedBuffer.getForeground(2, 0), equals(0));
      expect(parsedBuffer.getBackground(2, 0), equals(0));
    });

    test(
      'parse replaces stale colors on carriage-return overwrites and SGR 39/49',
      () {
        const red = 0xFFFF0000;
        const blue = 0xFF0000FF;
        const ansi =
            '\x1b[1;38;2;255;0;0;48;2;0;0;255mABCD'
            '\r\x1b[39mX\x1b[49mY\x1b[0mZ\n';

        final parsed = AnsiParser.parse(ansi, width: 4, height: 1);

        expect(parsed.getCharacter(0, 0), equals('X'));
        expect(parsed.getForeground(0, 0), equals(0));
        expect(parsed.getBackground(0, 0), equals(blue));
        expect(parsed.getModifiers(0, 0), equals(Modifier.bold));

        expect(parsed.getCharacter(1, 0), equals('Y'));
        expect(parsed.getForeground(1, 0), equals(0));
        expect(parsed.getBackground(1, 0), equals(0));
        expect(parsed.getModifiers(1, 0), equals(Modifier.bold));

        expect(parsed.getCharacter(2, 0), equals('Z'));
        expect(parsed.getForeground(2, 0), equals(0));
        expect(parsed.getBackground(2, 0), equals(0));
        expect(parsed.getModifiers(2, 0), equals(Modifier.none));

        expect(parsed.getCharacter(3, 0), equals('D'));
        expect(parsed.getForeground(3, 0), equals(red));
        expect(parsed.getBackground(3, 0), equals(blue));
      },
    );

    test('parseStream clears stale colors on unstyled overwrites', () {
      final buffer = Buffer.blank(4, 1);
      var state = AnsiParser.parseStream(
        '\x1b[38;2;255;0;0;48;2;0;255;0mABCD',
        buffer,
      );
      state = AnsiParser.parseStream(
        '\x1b[1;1H\x1b[0mXY',
        buffer,
        cursorX: state.$1,
        cursorY: state.$2,
        currentStyle: state.$3,
      );

      expect(buffer.getCharacter(0, 0), equals('X'));
      expect(buffer.getForeground(0, 0), equals(0));
      expect(buffer.getBackground(0, 0), equals(0));
      expect(buffer.getCharacter(1, 0), equals('Y'));
      expect(buffer.getForeground(1, 0), equals(0));
      expect(buffer.getBackground(1, 0), equals(0));
      expect(buffer.getCharacter(2, 0), equals('C'));
      expect(buffer.getForeground(2, 0), equals(0xFFFF0000));
      expect(buffer.getBackground(2, 0), equals(0xFF00FF00));
    });
  });
}
