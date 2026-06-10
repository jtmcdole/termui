import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/widgets/text.dart';
import 'package:termui/ui/widgets/rich_text.dart';

void main() {
  group('TextSpan Nesting and Style Merging Tests', () {
    test('Flat TextSpan styled characters build', () {
      final span = TextSpan(
        text: 'hello',
        style: const Style(foreground: Color(255, 0, 0)),
      );
      final chars = <StyledChar>[];
      span.buildStyledChars(chars, Style.empty);

      expect(chars.length, equals(5));
      for (final char in chars) {
        expect(char.style.foreground, equals(const Color(255, 0, 0)));
      }
    });

    test('Nested TextSpan tree flattens and merges styles', () {
      final span = TextSpan(
        style: const Style(foreground: Color(255, 0, 0)),
        children: [
          TextSpan(text: 'red '),
          TextSpan(
            text: 'blue ',
            style: const Style(foreground: Color(0, 0, 255)),
          ),
          TextSpan(
            style: const Style(modifiers: Modifier.bold),
            children: [TextSpan(text: 'bold red')],
          ),
        ],
      );
      final chars = <StyledChar>[];
      span.buildStyledChars(chars, Style.empty);

      // 'red blue bold red'
      expect(chars.length, equals(17));

      // 'red ' -> fg is red, modifiers: none
      for (var i = 0; i < 4; i++) {
        expect(chars[i].style.foreground, equals(const Color(255, 0, 0)));
        expect(chars[i].style.modifiers, equals(Modifier.none));
      }

      // 'blue ' -> fg is blue, modifiers: none
      for (var i = 4; i < 9; i++) {
        expect(chars[i].style.foreground, equals(const Color(0, 0, 255)));
        expect(chars[i].style.modifiers, equals(Modifier.none));
      }

      // 'bold red' -> fg is red, modifiers: bold
      for (var i = 9; i < 17; i++) {
        expect(chars[i].style.foreground, equals(const Color(255, 0, 0)));
        expect(chars[i].style.modifiers, equals(Modifier.bold));
      }
    });
  });

  group('RichText Widget Alignment and Wrap Tests', () {
    test('RichText text alignment (Center and Right)', () {
      final buffer = Buffer.blank(10, 2);
      final centerRich = RichText(
        text: const TextSpan(text: 'abc'),
        wrap: false,
        textAlign: TextAlign.center,
      );
      centerRich.render(buffer, const Rect(0, 0, 10, 1));

      // 'abc' centered in 10 width -> startX = (10 - 3) ~/ 2 = 3.
      // Cells 3-5: 'abc'
      expect(buffer.getCell(3, 0)!.char, equals('a'));
      expect(buffer.getCell(4, 0)!.char, equals('b'));
      expect(buffer.getCell(5, 0)!.char, equals('c'));
      expect(buffer.getCell(2, 0)!.char, equals(' '));

      final rightRich = RichText(
        text: const TextSpan(text: 'xyz'),
        wrap: false,
        textAlign: TextAlign.right,
      );
      final viewport = Viewport(buffer, const Rect(0, 1, 10, 1));
      rightRich.render(viewport, const Rect(0, 0, 10, 1));

      // 'xyz' right-aligned in 10 width -> startX = 10 - 3 = 7.
      // Cells 7-9: 'xyz' on line 1
      expect(buffer.getCell(7, 1)!.char, equals('x'));
      expect(buffer.getCell(8, 1)!.char, equals('y'));
      expect(buffer.getCell(9, 1)!.char, equals('z'));
      expect(buffer.getCell(6, 1)!.char, equals(' '));
    });
  });
}
