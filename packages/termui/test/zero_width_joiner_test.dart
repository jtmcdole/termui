import 'package:test/test.dart';
import 'package:termui/termui.dart';

void main() {
  group('Zero-Width Characters & Format Controls', () {
    test('isZeroWidthGrapheme identifies standalone zero-width characters', () {
      expect(isZeroWidthGrapheme(''), isTrue);
      expect(
        isZeroWidthGrapheme('\u200D'),
        isTrue,
        reason: 'Zero-Width Joiner (U+200D)',
      );
      expect(
        isZeroWidthGrapheme('\u200C'),
        isTrue,
        reason: 'Zero-Width Non-Joiner (U+200C)',
      );
      expect(
        isZeroWidthGrapheme('\u00AD'),
        isTrue,
        reason: 'Soft Hyphen (U+00AD)',
      );
      expect(
        isZeroWidthGrapheme('\u200B'),
        isTrue,
        reason: 'Zero-Width Space (U+200B)',
      );
      expect(
        isZeroWidthGrapheme('\uFEFF'),
        isTrue,
        reason: 'BOM / Zero-Width No-Break Space (U+FEFF)',
      );
      expect(
        isZeroWidthGrapheme('\u0300'),
        isTrue,
        reason: 'Standalone Combining Grave Accent (U+0300)',
      );
      expect(
        isZeroWidthGrapheme('\u0301'),
        isTrue,
        reason: 'Standalone Combining Acute Accent (U+0301)',
      );
    });

    test('graphemeWidth returns 0 for standalone zero-width characters', () {
      expect(graphemeWidth(''), 0);
      expect(graphemeWidth('\u200D'), 0);
      expect(graphemeWidth('\u200C'), 0);
      expect(graphemeWidth('\u00AD'), 0);
      expect(graphemeWidth('\u200B'), 0);
      expect(graphemeWidth('\uFEFF'), 0);
      expect(graphemeWidth('\u0300'), 0);
    });

    test('Standard ASCII and visible characters are not zero-width', () {
      expect(isZeroWidthGrapheme('A'), isFalse);
      expect(isZeroWidthGrapheme(' '), isFalse);
      expect(isZeroWidthGrapheme('1'), isFalse);
      expect(isZeroWidthGrapheme('中'), isFalse);
      expect(graphemeWidth('A'), 1);
      expect(graphemeWidth(' '), 1);
    });
  });

  group('Zero-Width Joiner (ZWJ) Emoji Sequences', () {
    test(
      'isWideGrapheme identifies complex ZWJ emoji sequences as wide (2 cells)',
      () {
        // Woman technologist (U+1F469 + U+200D + U+1F4BB)
        expect(isWideGrapheme('👩‍💻'), isTrue);
        expect(graphemeWidth('👩‍💻'), 2);

        // Ninja cat (U+1F431 + U+200D + U+1F464)
        expect(isWideGrapheme('🐱‍👤'), isTrue);
        expect(graphemeWidth('🐱‍👤'), 2);

        // Family (U+1F468 + U+200D + U+1F469 + U+200D + U+1F467 + U+200D + U+1F466)
        expect(isWideGrapheme('👨‍👩‍👧‍👦'), isTrue);
        expect(graphemeWidth('👨‍👩‍👧‍👦'), 2);

        // Rainbow flag (U+1F3F3 + U+FE0F + U+200D + U+1F308)
        expect(isWideGrapheme('🏳️‍🌈'), isTrue);
        expect(graphemeWidth('🏳️‍🌈'), 2);

        // Heart on fire (U+2764 + U+FE0F + U+200D + U+1F525)
        expect(isWideGrapheme('❤️‍🔥'), isTrue);
        expect(graphemeWidth('❤️‍🔥'), 2);

        // Eye in speech bubble (U+1F441 + U+FE0F + U+200D + U+1F5E8 + U+FE0F)
        expect(isWideGrapheme('👁️‍🗨️'), isTrue);
        expect(graphemeWidth('👁️‍🗨️'), 2);
      },
    );

    test(
      'measureStringWidth handles zero-width characters and ZWJ sequences correctly',
      () {
        // Zero-width space embedded in string does not inflate width
        expect(measureStringWidth('Hello\u200BWorld'), 10);
        expect(measureStringWidth('Hello\u200DWorld'), 10);
        expect(measureStringWidth('Soft\u00ADHyphen'), 10);

        // ZWJ emojis occupy exactly 2 cells
        expect(
          measureStringWidth('Status: 👩‍💻'),
          10,
        ); // 8 ASCII + 2 for emoji = 10
        expect(measureStringWidth('👩‍💻 + 🐱‍👤'), 7); // 2 + 3 + 2 = 7
        expect(
          measureStringWidth('Family: 👨‍👩‍👧‍👦!'),
          11,
        ); // 8 + 2 + 1 = 11
      },
    );

    test(
      'padOrTruncate preserves zero-width characters without inflating column width',
      () {
        final padded = padOrTruncate('Hi\u200B', 5);
        expect(measureStringWidth(padded), 5);
        expect(padded, 'Hi\u200B   ');
      },
    );
  });

  group('Buffer Writing with Zero-Width and ZWJ Characters', () {
    test(
      'Buffer.writeString does not advance column for zero-width characters',
      () {
        final buffer = Buffer(5, 1);
        buffer.writeString(0, 0, 'A\u200DB', Style.empty);

        expect(buffer.getCharacter(0, 0), 'A\u200D');
        expect(
          buffer.getCharacter(1, 0),
          'B',
          reason: 'Zero-width joiner must not advance column',
        );
        expect(buffer.getCharacter(2, 0), ' ');
      },
    );

    test(
      'Buffer.writeString allocates continuation cell and 2 columns for ZWJ emoji',
      () {
        final buffer = Buffer(5, 1);
        buffer.writeString(0, 0, '👩‍💻A', Style.empty);

        expect(buffer.getCharacter(0, 0), '👩‍💻');
        expect(
          buffer.getCharacter(1, 0),
          '',
          reason: 'Column 1 must be continuation cell',
        );
        expect(
          buffer.getCharacter(2, 0),
          'A',
          reason: "'A' must be at column 2",
        );
      },
    );
  });
}
