import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/widget_toolkit.dart';

class LabelWidget extends Widget {
  final String text;
  const LabelWidget(this.text);

  @override
  void render(Buffer buffer, Rect area) {
    buffer.writeString(0, 0, text, Style.empty);
  }
}

void main() {
  group('Layout Splitting Tests', () {
    test('Length and Percentage split', () {
      final area = const Rect(0, 0, 10, 5);
      final rects = splitRect(area, [
        const LengthConstraint(3),
        const PercentageConstraint(50),
      ], LayoutDirection.horizontal);

      expect(rects.length, 2);
      expect(rects[0], const Rect(0, 0, 3, 5));
      expect(rects[1], const Rect(3, 0, 5, 5)); // 50% of 10 is 5
    });

    test('Flex splits remaining space proportionally', () {
      final area = const Rect(0, 0, 10, 5);
      final rects = splitRect(area, [
        const LengthConstraint(4),
        const FlexConstraint(1),
        const FlexConstraint(2),
      ], LayoutDirection.horizontal);

      // Total size 10, used 4, remaining 6.
      // Flex 1 gets 2, Flex 2 gets 4.
      expect(rects.length, 3);
      expect(rects[0], const Rect(0, 0, 4, 5));
      expect(rects[1], const Rect(4, 0, 2, 5));
      expect(rects[2], const Rect(6, 0, 4, 5));
    });

    test('MinMax constraint clamping', () {
      final area = const Rect(0, 0, 10, 5);
      final rects = splitRect(area, [
        const MinMaxConstraint(min: 2, max: 4),
        const FlexConstraint(1),
      ], LayoutDirection.horizontal);

      expect(rects[0].width, inClosedOpenRange(2, 5));
    });
  });

  group('Viewport Clipping Tests', () {
    test('Clipping outer-bounds writes', () {
      final rootBuffer = Buffer.blank(10, 5);
      final viewport = Viewport(rootBuffer, const Rect(2, 1, 4, 3));

      // Viewport width = 4, height = 3.
      // Write 'ABCDEFGHI' starting at (0, 0) relative.
      // Expected to write 'ABCD' within viewport, clipping 'EFGHI' because it exceeds viewport width.
      viewport.writeString(0, 0, 'ABCDEFGHI', Style.empty);

      // Check root buffer values:
      // Viewport starts at (2, 1) in root buffer coordinate.
      expect(rootBuffer.getCell(2, 1)!.char, 'A');
      expect(rootBuffer.getCell(3, 1)!.char, 'B');
      expect(rootBuffer.getCell(4, 1)!.char, 'C');
      expect(rootBuffer.getCell(5, 1)!.char, 'D');

      // (6, 1) is outside the viewport (x bounds 2-5). Should be empty space.
      expect(rootBuffer.getCell(6, 1)!.char, ' ');

      // Write with vertical wrap: 'A\nB\nC\nD' relative to viewport.
      // Viewport height = 3. 'D' should be clipped vertically.
      viewport.writeString(1, 0, 'X\nY\nZ\nW', Style.empty);
      expect(rootBuffer.getCell(3, 1)!.char, 'X');
      expect(rootBuffer.getCell(3, 2)!.char, 'Y');
      expect(rootBuffer.getCell(3, 3)!.char, 'Z');
      expect(rootBuffer.getCell(3, 4)!.char, ' '); // clipped
    });
  });

  group('Nested Box layouts', () {
    test('Column inside Row nesting', () {
      final root = Buffer.blank(10, 10);
      final layout = Row([
        SizedBox(
          width: 5,
          child: Column([
            SizedBox(height: 2, child: const LabelWidget('1')),
            const Expanded(child: LabelWidget('2')),
          ]),
        ),
        const Expanded(child: LabelWidget('3')),
      ]);

      layout.render(root, const Rect(0, 0, 10, 10));

      // Left column (0..4) is handled by Column.
      // Row 0 has LabelWidget('1') -> '1' at (0, 0)
      expect(root.getCell(0, 0)!.char, '1');
      // Row 2 has LabelWidget('2') -> '2' at (0, 2)
      expect(root.getCell(0, 2)!.char, '2');

      // Right column (5..9) is handled by LabelWidget('3') -> '3' at (5, 0)
      expect(root.getCell(5, 0)!.char, '3');
    });
  });

  group('Padding Widget Tests', () {
    test('Padding shrinks viewport and shifts coordinates', () {
      final root = Buffer.blank(10, 5);
      final padding = Padding(
        padding: const EdgeInsets.fromLTRB(2, 1, 2, 1),
        child: const LabelWidget('Hi'),
      );

      padding.render(root, const Rect(0, 0, 10, 5));

      // Root buffer starts at (0, 0).
      // Padding adds left=2, top=1.
      // So the child LabelWidget renders 'Hi' at (2, 1) relative to root.
      expect(root.getCell(2, 1)!.char, 'H');
      expect(root.getCell(3, 1)!.char, 'i');

      // The areas outside the padding should remain blank spaces.
      expect(root.getCell(1, 1)!.char, ' ');
      expect(root.getCell(2, 0)!.char, ' ');
    });

    test('Padding handles zero-area gracefully', () {
      final root = Buffer.blank(5, 5);
      final padding = Padding(
        padding: const EdgeInsets.all(3),
        child: const LabelWidget('No'),
      );

      // Width = 5, padding left=3 + right=3 = 6 (which exceeds 5).
      // Should not crash and should not render anything.
      padding.render(root, const Rect(0, 0, 5, 5));
      for (var y = 0; y < 5; y++) {
        for (var x = 0; x < 5; x++) {
          expect(root.getCell(x, y)!.char, ' ');
        }
      }
    });
  });
}
