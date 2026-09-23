import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';

void main() {
  group('Unicode 16.0 Full Wide Character Coverage (126 Ranges)', () {
    const ranges = <(int, int)>[
      (0x1100, 0x115F),
      (0x231A, 0x231B),
      (0x2329, 0x232A),
      (0x23E9, 0x23EC),
      (0x23F0, 0x23F0),
      (0x23F3, 0x23F3),
      (0x25FD, 0x25FE),
      (0x2614, 0x2615),
      (0x2630, 0x2637),
      (0x2648, 0x2653),
      (0x267F, 0x267F),
      (0x268A, 0x268F),
      (0x2693, 0x2693),
      (0x26A1, 0x26A1),
      (0x26AA, 0x26AB),
      (0x26BD, 0x26BE),
      (0x26C4, 0x26C5),
      (0x26CE, 0x26CE),
      (0x26D4, 0x26D4),
      (0x26EA, 0x26EA),
      (0x26F2, 0x26F3),
      (0x26F5, 0x26F5),
      (0x26FA, 0x26FA),
      (0x26FD, 0x26FD),
      (0x2705, 0x2705),
      (0x270A, 0x270B),
      (0x2728, 0x2728),
      (0x274C, 0x274C),
      (0x274E, 0x274E),
      (0x2753, 0x2755),
      (0x2757, 0x2757),
      (0x2795, 0x2797),
      (0x27B0, 0x27B0),
      (0x27BF, 0x27BF),
      (0x2B1B, 0x2B1C),
      (0x2B50, 0x2B50),
      (0x2B55, 0x2B55),
      (0x2E80, 0x2E99),
      (0x2E9B, 0x2EF3),
      (0x2F00, 0x2FD5),
      (0x2FF0, 0x303E),
      (0x3041, 0x3096),
      (0x3099, 0x30FF),
      (0x3105, 0x312F),
      (0x3131, 0x318E),
      (0x3190, 0x31E5),
      (0x31EF, 0x321E),
      (0x3220, 0x3247),
      (0x3250, 0xA48C),
      (0xA490, 0xA4C6),
      (0xA960, 0xA97C),
      (0xAC00, 0xD7A3),
      (0xF900, 0xFAFF),
      (0xFE10, 0xFE19),
      (0xFE30, 0xFE52),
      (0xFE54, 0xFE66),
      (0xFE68, 0xFE6B),
      (0xFF01, 0xFF60),
      (0xFFE0, 0xFFE6),
      (0x16FE0, 0x16FE4),
      (0x16FF0, 0x16FF6),
      (0x17000, 0x18CDA),
      (0x18CFF, 0x18D20),
      (0x18D80, 0x18DF2),
      (0x18E00, 0x19191),
      (0x191A0, 0x191D2),
      (0x1AFF0, 0x1AFF3),
      (0x1AFF5, 0x1AFFB),
      (0x1AFFD, 0x1AFFE),
      (0x1B000, 0x1B128),
      (0x1B132, 0x1B132),
      (0x1B150, 0x1B152),
      (0x1B155, 0x1B155),
      (0x1B164, 0x1B168),
      (0x1B170, 0x1B2FB),
      (0x1D300, 0x1D356),
      (0x1D360, 0x1D376),
      (0x1F004, 0x1F004),
      (0x1F0CF, 0x1F0CF),
      (0x1F18E, 0x1F18E),
      (0x1F191, 0x1F19A),
      (0x1F1AE, 0x1F1AE),
      (0x1F1E6, 0x1F202),
      (0x1F210, 0x1F23B),
      (0x1F240, 0x1F248),
      (0x1F250, 0x1F251),
      (0x1F260, 0x1F265),
      (0x1F300, 0x1F320),
      (0x1F32D, 0x1F335),
      (0x1F337, 0x1F37C),
      (0x1F37E, 0x1F393),
      (0x1F3A0, 0x1F3CA),
      (0x1F3CF, 0x1F3D3),
      (0x1F3E0, 0x1F3F0),
      (0x1F3F4, 0x1F3F4),
      (0x1F3F8, 0x1F43E),
      (0x1F440, 0x1F440),
      (0x1F442, 0x1F4FC),
      (0x1F4FF, 0x1F53D),
      (0x1F54B, 0x1F54E),
      (0x1F550, 0x1F567),
      (0x1F57A, 0x1F57A),
      (0x1F595, 0x1F596),
      (0x1F5A4, 0x1F5A4),
      (0x1F5FB, 0x1F64F),
      (0x1F680, 0x1F6C5),
      (0x1F6CC, 0x1F6CC),
      (0x1F6D0, 0x1F6D2),
      (0x1F6D5, 0x1F6D9),
      (0x1F6DC, 0x1F6DF),
      (0x1F6EB, 0x1F6EC),
      (0x1F6F4, 0x1F6FC),
      (0x1F7DA, 0x1F7DA),
      (0x1F7E0, 0x1F7EB),
      (0x1F7F0, 0x1F7F0),
      (0x1F90C, 0x1F93A),
      (0x1F93C, 0x1F945),
      (0x1F947, 0x1F9FF),
      (0x1FA70, 0x1FA7C),
      (0x1FA80, 0x1FAC6),
      (0x1FAC8, 0x1FAC8),
      (0x1FACC, 0x1FADD),
      (0x1FADF, 0x1FAEB),
      (0x1FAEF, 0x1FAFA),
      (0x20000, 0x2FFFD),
      (0x30000, 0x3FFFD),
    ];

    test('All 126 ranges are recognized by isWideCodePoint', () {
      expect(ranges.length, 126);

      for (var i = 0; i < ranges.length; i++) {
        final (start, end) = ranges[i];

        // 1. Verify start codepoint
        expect(
          isWideCodePoint(start),
          isTrue,
          reason:
              'Range ${i + 1} start U+${start.toRadixString(16).toUpperCase()} must be wide',
        );

        // 2. Verify end codepoint
        expect(
          isWideCodePoint(end),
          isTrue,
          reason:
              'Range ${i + 1} end U+${end.toRadixString(16).toUpperCase()} must be wide',
        );

        // 3. Verify midpoint if range is larger than 2
        if (end - start >= 2) {
          final mid = (start + end) ~/ 2;
          expect(
            isWideCodePoint(mid),
            isTrue,
            reason:
                'Range ${i + 1} midpoint U+${mid.toRadixString(16).toUpperCase()} must be wide',
          );
        }

        // 4. Verify boundary immediately before start (unless contiguous with previous range or < 0x1100)
        if (start > 0x1100) {
          final prev = start - 1;
          final isInPrevRange = i > 0 && prev <= ranges[i - 1].$2;
          if (!isInPrevRange) {
            expect(
              isWideCodePoint(prev),
              isFalse,
              reason:
                  'Codepoint U+${prev.toRadixString(16).toUpperCase()} immediately before Range ${i + 1} must not be wide',
            );
          }
        }

        // 5. Verify boundary immediately after end (unless contiguous with next range)
        final next = end + 1;
        final isInNextRange = i + 1 < ranges.length && next >= ranges[i + 1].$1;
        if (!isInNextRange && next <= 0x3FFFD) {
          expect(
            isWideCodePoint(next),
            isFalse,
            reason:
                'Codepoint U+${next.toRadixString(16).toUpperCase()} immediately after Range ${i + 1} must not be wide',
          );
        }
      }
    });

    test(
      'isWideGrapheme works for representative codepoints from BMP and SMP ranges',
      () {
        // Hangul Jamo initial (Range 1)
        expect(isWideGrapheme(String.fromCharCode(0x1100)), isTrue);
        // CJK Ideograph (Range 49)
        expect(isWideGrapheme('中'), isTrue);
        // Tangut (Range 62)
        expect(isWideGrapheme(String.fromCharCode(0x17000)), isTrue);
        // SMP Emoji (Range 88)
        expect(isWideGrapheme('🌀'), isTrue);
        // Plane 2 CJK Ext B (Range 125)
        expect(isWideGrapheme(String.fromCharCode(0x20000)), isTrue);
        // Plane 3 CJK Ext G (Range 126)
        expect(isWideGrapheme(String.fromCharCode(0x30000)), isTrue);
      },
    );
  });
}
