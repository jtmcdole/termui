import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';

void main() {
  group('Wide Character Detection Tests', () {
    test('isWideGrapheme correctly identifies CJK characters', () {
      expect(isWideGrapheme('中'), isTrue);
      expect(isWideGrapheme('国'), isTrue);
      expect(isWideGrapheme('あ'), isTrue);
      expect(isWideGrapheme('ア'), isTrue);
      expect(isWideGrapheme('한'), isTrue);
    });

    test('isWideGrapheme correctly identifies emojis', () {
      expect(isWideGrapheme('🍔'), isTrue);
      expect(isWideGrapheme('😀'), isTrue);
      expect(isWideGrapheme('🚀'), isTrue);
    });

    test('isWideGrapheme correctly identifies standard ASCII as narrow', () {
      expect(isWideGrapheme('A'), isFalse);
      expect(isWideGrapheme('z'), isFalse);
      expect(isWideGrapheme('1'), isFalse);
      expect(isWideGrapheme(' '), isFalse);
      expect(isWideGrapheme(''), isFalse);
    });
  });

  group('Buffer Wide Character writeString Tests', () {
    test(
      'Writing wide character sets current cell and empty string in next cell',
      () {
        final buffer = Buffer(5, 1);
        buffer.writeString(0, 0, '中A', Style.empty);

        expect(buffer.getCell(0, 0)!.char, '中');
        expect(buffer.getCell(1, 0)!.char, '');
        expect(buffer.getCell(2, 0)!.char, 'A');
      },
    );

    test('Overwriting second cell of wide character clears the first cell', () {
      final buffer = Buffer(5, 1);
      buffer.writeString(0, 0, '中', Style.empty);
      expect(buffer.getCell(0, 0)!.char, '中');
      expect(buffer.getCell(1, 0)!.char, '');

      // Overwrite the dummy cell (1, 0) with 'A'
      buffer.writeString(1, 0, 'A', Style.empty);
      expect(buffer.getCell(0, 0)!.char, ' ');
      expect(buffer.getCell(1, 0)!.char, 'A');
    });

    test('Overwriting first cell of wide character clears the second cell', () {
      final buffer = Buffer(5, 1);
      buffer.writeString(0, 0, '中', Style.empty);
      expect(buffer.getCell(0, 0)!.char, '中');
      expect(buffer.getCell(1, 0)!.char, '');

      // Overwrite first cell (0, 0) with 'A'
      buffer.writeString(0, 0, 'A', Style.empty);
      expect(buffer.getCell(0, 0)!.char, 'A');
      expect(buffer.getCell(1, 0)!.char, ' ');
    });

    test('Writing wide character at the last column falls back to space', () {
      final buffer = Buffer(5, 1);
      buffer.writeString(4, 0, '中', Style.empty);

      expect(buffer.getCell(4, 0)!.char, ' ');
    });
  });
}
