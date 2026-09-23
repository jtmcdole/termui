import 'package:test/test.dart';
import 'package:termui/termui.dart';

void main() {
  group(
    'Issue #122 - Narrow Technical & Media Symbols U+23ED..U+23EF, U+23F1..U+23F2, U+23F8..U+23FA',
    () {
      test('isWideGrapheme returns false for narrow symbols without VS16', () {
        // U+23ED..U+23EF
        expect(
          isWideGrapheme('⏭'),
          isFalse,
          reason: 'U+23ED Next Track without VS16 is 1 column (EAW=N)',
        );
        expect(
          isWideGrapheme('⏮'),
          isFalse,
          reason: 'U+23EE Previous Track without VS16 is 1 column (EAW=N)',
        );
        expect(
          isWideGrapheme('⏯'),
          isFalse,
          reason: 'U+23EF Play/Pause without VS16 is 1 column (EAW=N)',
        );

        // U+23F1..U+23F2
        expect(
          isWideGrapheme('⏱'),
          isFalse,
          reason: 'U+23F1 Stopwatch without VS16 is 1 column (EAW=N)',
        );
        expect(
          isWideGrapheme('⏲'),
          isFalse,
          reason: 'U+23F2 Timer Clock without VS16 is 1 column (EAW=N)',
        );

        // U+23F8..U+23FA
        expect(
          isWideGrapheme('⏸'),
          isFalse,
          reason: 'U+23F8 Pause without VS16 is 1 column (EAW=N)',
        );
        expect(
          isWideGrapheme('⏹'),
          isFalse,
          reason: 'U+23F9 Stop without VS16 is 1 column (EAW=N)',
        );
        expect(
          isWideGrapheme('⏺'),
          isFalse,
          reason: 'U+23FA Record without VS16 is 1 column (EAW=N)',
        );
      });

      test('isWideGrapheme returns true for symbols with VS16 (U+FE0F)', () {
        expect(
          isWideGrapheme('⏭️'),
          isTrue,
          reason: 'U+23ED + VS16 should be wide (2 cells)',
        );
        expect(
          isWideGrapheme('⏮️'),
          isTrue,
          reason: 'U+23EE + VS16 should be wide (2 cells)',
        );
        expect(
          isWideGrapheme('⏯️'),
          isTrue,
          reason: 'U+23EF + VS16 should be wide (2 cells)',
        );
        expect(
          isWideGrapheme('⏱️'),
          isTrue,
          reason: 'U+23F1 + VS16 should be wide (2 cells)',
        );
        expect(
          isWideGrapheme('⏲️'),
          isTrue,
          reason: 'U+23F2 + VS16 should be wide (2 cells)',
        );
        expect(
          isWideGrapheme('⏸️'),
          isTrue,
          reason: 'U+23F8 + VS16 should be wide (2 cells)',
        );
        expect(
          isWideGrapheme('⏹️'),
          isTrue,
          reason: 'U+23F9 + VS16 should be wide (2 cells)',
        );
        expect(
          isWideGrapheme('⏺️'),
          isTrue,
          reason: 'U+23FA + VS16 should be wide (2 cells)',
        );
      });

      test(
        'isWideGrapheme preserves true for actual wide BMP symbols (EAW=W)',
        () {
          expect(
            isWideGrapheme('⏩'),
            isTrue,
            reason: 'U+23E9 Fast Forward is wide (EAW=W)',
          );
          expect(
            isWideGrapheme('⏪'),
            isTrue,
            reason: 'U+23EA Fast Rewind is wide (EAW=W)',
          );
          expect(
            isWideGrapheme('⏫'),
            isTrue,
            reason: 'U+23EB Fast Up is wide (EAW=W)',
          );
          expect(
            isWideGrapheme('⏬'),
            isTrue,
            reason: 'U+23EC Fast Down is wide (EAW=W)',
          );
          expect(
            isWideGrapheme('⏰'),
            isTrue,
            reason: 'U+23F0 Alarm Clock is wide (EAW=W)',
          );
          expect(
            isWideGrapheme('⏳'),
            isTrue,
            reason: 'U+23F3 Hourglass is wide (EAW=W)',
          );
        },
      );

      test(
        'measureStringWidth returns 1 for narrow symbols and 2 for VS16 symbols',
        () {
          expect(measureStringWidth('⏭'), 1);
          expect(measureStringWidth('⏱'), 1);
          expect(measureStringWidth('⏸'), 1);

          expect(measureStringWidth('⏭️'), 2);
          expect(measureStringWidth('⏱️'), 2);
          expect(measureStringWidth('⏸️'), 2);
        },
      );

      test(
        'Buffer.writeString does not allocate continuation cell for narrow symbol',
        () {
          final buffer = Buffer(5, 1);
          buffer.writeString(0, 0, '⏭A', Style.empty);

          expect(buffer.getCharacter(0, 0), '⏭');
          expect(
            buffer.getCharacter(1, 0),
            'A',
            reason: "'A' must be at column 1 since '⏭' occupies 1 column",
          );
          expect(
            buffer.getCharacter(2, 0),
            ' ',
            reason: "Column 2 should be empty",
          );
        },
      );
    },
  );
}
