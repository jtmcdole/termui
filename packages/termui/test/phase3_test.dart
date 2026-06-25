import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/widgets/layout/row.dart';
import 'package:termui/ui/widgets/layout/column.dart';
import 'package:termui/ui/widgets/layout/sized_box.dart';
import 'package:termui/ui/widgets/layout/flexible.dart';
import 'package:termui/ui/widgets/layout/flex.dart';
import 'package:termui/ui/widgets/core/widget.dart';
import 'package:termui/ui/widgets/core/element.dart';
import 'package:termui/ui/widgets/core/geometry.dart';
import 'package:termui/ui/widgets/core/viewport.dart';
import 'package:termui/ui/widget_toolkit.dart';

class LabelWidget extends Widget {
  final String text;
  const LabelWidget(this.text);

  @override
  Element createElement() => _LabelElement(this);
}

class _LabelElement extends Element {
  _LabelElement(super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return constraints.constrain(Size((widget as LabelWidget).text.length, 1));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    buffer.writeString(
      offset.dx,
      offset.dy,
      (widget as LabelWidget).text,
      Style.empty,
    );
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
      expect(rootBuffer.getCharacter(2, 1), 'A');
      expect(rootBuffer.getCharacter(3, 1), 'B');
      expect(rootBuffer.getCharacter(4, 1), 'C');
      expect(rootBuffer.getCharacter(5, 1), 'D');

      // (6, 1) is outside the viewport (x bounds 2-5). Should be empty space.
      expect(rootBuffer.getCharacter(6, 1), ' ');

      // Write with vertical wrap: 'A\nB\nC\nD' relative to viewport.
      // Viewport height = 3. 'D' should be clipped vertically.
      viewport.writeString(1, 0, 'X\nY\nZ\nW', Style.empty);
      expect(rootBuffer.getCharacter(3, 1), 'X');
      expect(rootBuffer.getCharacter(3, 2), 'Y');
      expect(rootBuffer.getCharacter(3, 3), 'Z');
      expect(rootBuffer.getCharacter(3, 4), ' '); // clipped
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

      ElementWidget(layout)
        ..layout(BoxConstraints.tight(const Size(10, 10)))
        ..paint(root, Offset.zero);

      // Left column (0..4) is handled by Column.
      // Row 0 has LabelWidget('1') -> '1' at (0, 0)
      expect(root.getCharacter(0, 0), '1');
      // Row 2 has LabelWidget('2') -> '2' at (0, 2)
      expect(root.getCharacter(0, 2), '2');

      // Right column (5..9) is handled by LabelWidget('3') -> '3' at (5, 0)
      expect(root.getCharacter(5, 0), '3');
    });
  });

  group('Padding Widget Tests', () {
    test('Padding shrinks viewport and shifts coordinates', () {
      final root = Buffer.blank(10, 5);
      final padding = Padding(
        padding: const EdgeInsets.fromLTRB(2, 1, 2, 1),
        child: const LabelWidget('Hi'),
      );

      ElementWidget(padding)
        ..layout(BoxConstraints.tight(const Size(10, 5)))
        ..paint(root, Offset.zero);

      // Root buffer starts at (0, 0).
      // Padding adds left=2, top=1.
      // So the child LabelWidget renders 'Hi' at (2, 1) relative to root.
      expect(root.getCharacter(2, 1), 'H');
      expect(root.getCharacter(3, 1), 'i');

      // The areas outside the padding should remain blank spaces.
      expect(root.getCharacter(1, 1), ' ');
      expect(root.getCharacter(2, 0), ' ');
    });

    test('Padding handles zero-area gracefully', () {
      final root = Buffer.blank(5, 5);
      final padding = Padding(
        padding: const EdgeInsets.all(3),
        child: const LabelWidget('No'),
      );

      // Width = 5, padding left=3 + right=3 = 6 (which exceeds 5).
      // Should not crash and should not render anything.
      ElementWidget(padding)
        ..layout(BoxConstraints.tight(const Size(5, 5)))
        ..paint(root, Offset.zero);
      for (var y = 0; y < 5; y++) {
        for (var x = 0; x < 5; x++) {
          expect(root.getCharacter(x, y), ' ');
        }
      }
    });
  });
}
