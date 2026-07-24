import 'package:test/test.dart';
import 'package:termui/termui.dart';

class UnclippedRedBoxWidget extends Widget {
  final int width;
  final int height;

  const UnclippedRedBoxWidget({
    super.key,
    required this.width,
    required this.height,
  });

  @override
  Element createElement() => UnclippedRedBoxElement(this);
}

class UnclippedRedBoxElement extends Element {
  UnclippedRedBoxElement(super.widget);

  @override
  UnclippedRedBoxWidget get widget => super.widget as UnclippedRedBoxWidget;

  @override
  Size performLayout(BoxConstraints constraints) {
    return Size(widget.width, widget.height);
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final renderDx = offset.dx;
    final renderDy = offset.dy;

    for (int y = 0; y < size.height; y++) {
      for (int x = 0; x < size.width; x++) {
        final targetX = renderDx + x;
        final targetY = renderDy + y;

        buffer.setCell(targetX, targetY, 'X', 0xFFFF0000, 0, 0);
      }
    }
  }
}

void main() {
  test(
    'Custom painter extending past right side of screen must be clipped and not wrap to column 0',
    () {
      final buffer = Buffer(80, 20);

      // Create a 40x5 RedBox widget positioned at left: 60 on an 80-column terminal screen
      // (Extends from column 60 to column 100)
      final redBox = UnclippedRedBoxWidget(width: 40, height: 5);
      final stack = Stack([
        Positioned(left: 60, top: 0, width: 40, height: 5, child: redBox),
      ]);

      final rootElement = stack.createElement();
      rootElement.mount(null);
      rootElement.layout(
        const BoxConstraints(
          minWidth: 80,
          maxWidth: 80,
          minHeight: 20,
          maxHeight: 20,
        ),
      );
      rootElement.paint(buffer, Offset.zero);

      // Columns 60 to 79 on row 0 should contain 'X'
      expect(buffer.getCharacter(60, 0), equals('X'));
      expect(buffer.getCharacter(79, 0), equals('X'));

      // Column 0 on row 1 MUST NOT contain 'X' (proves no 1D index overflow wrapping to left side)
      expect(
        buffer.getCharacter(0, 1),
        isNot(equals('X')),
        reason:
            'Out-of-bounds cells from column 80..99 must not wrap around to column 0..19 on row 1',
      );
    },
  );
}
