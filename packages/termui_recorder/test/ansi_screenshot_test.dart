import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/style.dart';
import 'package:termui_recorder/termui_recorder.dart';

void main() {
  group('AnsiScreenshot', () {
    test('renders plain text buffer without styles', () {
      final buffer = Buffer.blank(5, 2);
      buffer.setCell(0, 0, Cell('H', Style.empty));
      buffer.setCell(1, 0, Cell('e', Style.empty));
      buffer.setCell(2, 0, Cell('l', Style.empty));
      buffer.setCell(3, 0, Cell('l', Style.empty));
      buffer.setCell(4, 0, Cell('o', Style.empty));

      buffer.setCell(0, 1, Cell('W', Style.empty));
      buffer.setCell(1, 1, Cell('o', Style.empty));
      buffer.setCell(2, 1, Cell('r', Style.empty));
      buffer.setCell(3, 1, Cell('l', Style.empty));
      buffer.setCell(4, 1, Cell('d', Style.empty));

      final ansi = AnsiScreenshot.capture(buffer, resetLineEndings: true);
      expect(ansi, equals('Hello\nWorld\n'));
    });

    test('renders buffer with foreground and background colors', () {
      final buffer = Buffer.blank(3, 1);
      final redFgStyle = const Style(foreground: Color(255, 0, 0));
      final greenBgStyle = const Style(background: Color(0, 255, 0));

      buffer.setCell(0, 0, Cell('R', redFgStyle));
      buffer.setCell(1, 0, Cell('G', greenBgStyle));
      buffer.setCell(2, 0, Cell('B', Style.empty));

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

      buffer.setCell(0, 0, Cell('B', boldStyle));
      buffer.setCell(1, 0, Cell('I', italicStyle));

      final ansi = AnsiScreenshot.capture(buffer, resetLineEndings: true);

      expect(ansi, equals('\x1b[1mB\x1b[0m\x1b[3mI\x1b[0m\n'));
    });
  });

  group('AnsiParser', () {
    test('round-trips an ANSI styled string back to a Buffer', () {
      final buffer = Buffer.blank(3, 1);
      final redFgStyle = const Style(foreground: Color(255, 0, 0));
      final greenBgStyle = const Style(background: Color(0, 255, 0));

      buffer.setCell(0, 0, Cell('R', redFgStyle));
      buffer.setCell(1, 0, Cell('G', greenBgStyle));
      buffer.setCell(2, 0, Cell('B', Style.empty));

      final ansi = AnsiScreenshot.capture(buffer, resetLineEndings: true);

      final parsedBuffer = AnsiParser.parse(ansi);

      expect(parsedBuffer.width, equals(buffer.width));
      expect(parsedBuffer.height, equals(buffer.height));

      final cellR = parsedBuffer.getCell(0, 0)!;
      expect(cellR.char, equals('R'));
      expect(cellR.style.foreground, equals(const Color(255, 0, 0)));

      final cellG = parsedBuffer.getCell(1, 0)!;
      expect(cellG.char, equals('G'));
      expect(cellG.style.background, equals(const Color(0, 255, 0)));

      final cellB = parsedBuffer.getCell(2, 0)!;
      expect(cellB.char, equals('B'));
      expect(cellB.style, equals(Style.empty));
    });
  });
}
