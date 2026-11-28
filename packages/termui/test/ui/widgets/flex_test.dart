import 'package:termui/termui.dart';
import 'package:test/test.dart';

void main() {
  group('splitRect', () {
    test('returns empty list for empty constraints', () {
      expect(
        splitRect(const Rect(0, 0, 20, 10), const [], .horizontal),
        isEmpty,
      );
    });

    group('alignments with remaining space', () {
      const area = Rect(2, 3, 20, 5);
      const constraints = [
        LengthConstraint(2),
        LengthConstraint(4),
        LengthConstraint(2),
      ];
      // usedSize = 8, remaining = 12
      final cases = <(MainAxisAlignment, List<int>)>[
        (.start, [2, 4, 8]),
        (.end, [14, 16, 20]),
        (.center, [8, 10, 14]),
        (.spaceBetween, [2, 10, 20]),
        (.spaceAround, [4, 10, 18]),
        (.spaceEvenly, [5, 10, 17]),
      ];

      for (final (alignment, expectedX) in cases) {
        test('horizontal $alignment', () {
          final rects = splitRect(
            area,
            constraints,
            .horizontal,
            mainAxisAlignment: alignment,
          );
          expect([for (final r in rects) r.x], expectedX);
          expect([for (final r in rects) r.width], [2, 4, 2]);
          expect([for (final r in rects) r.y], [3, 3, 3]);
          expect([for (final r in rects) r.height], [5, 5, 5]);
        });
      }

      test('single child with spaceBetween starts at origin', () {
        final rects = splitRect(
          const Rect(0, 0, 20, 5),
          const [LengthConstraint(6)],
          .horizontal,
          mainAxisAlignment: .spaceBetween,
        );
        expect(rects, [const Rect(0, 0, 6, 5)]);
      });
    });

    group('overflow (remaining <= 0)', () {
      const area = Rect(0, 0, 10, 5);
      const constraints = [LengthConstraint(8), LengthConstraint(6)];
      // usedSize = 14, remaining = -4
      final cases = <(MainAxisAlignment, List<int>)>[
        (.start, [0, 8]),
        (.end, [-4, 4]),
        (.center, [-2, 6]),
        (.spaceBetween, [0, 8]),
        (.spaceAround, [0, 8]),
        (.spaceEvenly, [0, 8]),
      ];

      for (final (alignment, expectedX) in cases) {
        test('horizontal overflow $alignment', () {
          final rects = splitRect(
            area,
            constraints,
            .horizontal,
            mainAxisAlignment: alignment,
          );
          expect([for (final r in rects) r.x], expectedX);
          expect([for (final r in rects) r.width], [8, 6]);
        });
      }
    });
  });
}
