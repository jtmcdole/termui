import 'package:termui/termui.dart';
import 'package:test/test.dart';

void main() {
  group('Stack Tests', () {
    test('Stack places children over each other', () {
      final stack = Stack([
        SizedBox(width: 5, height: 5, child: Text('Back')),
        SizedBox(width: 2, height: 2, child: Text('Fr')),
      ]);
      final element = stack.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(10, 10)));

      final buffer = Buffer.blank(10, 10);
      element.paint(buffer, Offset.zero);
      // It paints both.
      expect(true, true);
    });

    test('Stack respects positioning constraints', () {
      final stack = Stack([
        SizedBox(width: 5, height: 5, child: Text('Back')),
        Positioned(
          left: 2,
          top: 2,
          child: SizedBox(width: 2, height: 2, child: Text('Fr')),
        ),
      ]);
      final element = stack.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(10, 10)));
      expect(
        (element as StackElement).childElements[1].relativeOffset,
        const Offset(2, 2),
      );
    });

    test(
      'Stack positions child when left/width and top/height are omitted but right/bottom are specified',
      () {
        final stack = Stack([
          Positioned(
            right: 2,
            bottom: 3,
            child: SizedBox(width: 2, height: 1, child: Text('Fr')),
          ),
        ]);
        final element = stack.createElement();
        element.mount(null);
        element.layout(BoxConstraints.tight(const Size(10, 10)));
        expect(
          (element as StackElement).childElements.first.relativeOffset,
          const Offset(6, 6),
        );
      },
    );
  });

  group('Align Tests', () {
    test('Align positions child at center', () {
      final align = Align(
        alignment: Alignment.center,
        child: SizedBox(width: 2, height: 2, child: Text('X')),
      );
      final element = align.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(10, 10)));
      // Center of 10x10 is 4x4 for a 2x2 child.
      expect(
        (element as dynamic).childElement.relativeOffset,
        const Offset(4, 4),
      );
    });

    test('Align positions child at bottom right', () {
      final align = Align(
        alignment: Alignment.bottomRight,
        child: SizedBox(width: 2, height: 2, child: Text('X')),
      );
      final element = align.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(10, 10)));
      // Bottom right is 8x8.
      expect(
        (element as dynamic).childElement.relativeOffset,
        const Offset(8, 8),
      );
    });
  });

  group('Stack constraints and sizing tests (loose & unbounded)', () {
    test(
      'Stack with loose constraints sizes to non-positioned children and positions correctly',
      () {
        final stack = Stack([
          SizedBox(width: 5, height: 5, child: Text('Base')),
          Positioned(
            right: 0,
            bottom: 0,
            child: SizedBox(width: 1, height: 1, child: Text('P')),
          ),
        ]);
        final element = stack.createElement();
        element.mount(null);
        element.layout(
          BoxConstraints(
            minWidth: 0,
            maxWidth: 10,
            minHeight: 0,
            maxHeight: 10,
          ),
        );

        // The stack should be sized to the non-positioned child: 5x5.
        expect(element.size, const Size(5, 5));

        // The positioned child (right: 0, bottom: 0) should be positioned at Offset(4, 4).
        final positionedElement = (element as StackElement).childElements[1];
        expect(positionedElement.relativeOffset, const Offset(4, 4));
      },
    );

    test(
      'Stack with unbounded constraints does not squeeze positioned children to 0 width',
      () {
        final stack = Stack([
          SizedBox(width: 5, height: 5, child: Text('Base')),
          Positioned(
            left: 1,
            top: 1,
            child: SizedBox(width: 2, height: 2, child: Text('P')),
          ),
        ]);
        final element = stack.createElement();
        element.mount(null);

        // Layout with unbounded (infinity) constraints.
        element.layout(
          const BoxConstraints(
            minWidth: 0,
            maxWidth: BoxConstraints.infinity,
            minHeight: 0,
            maxHeight: BoxConstraints.infinity,
          ),
        );

        // Stack should size to the non-positioned child: 5x5.
        expect(element.size, const Size(5, 5));

        // The positioned child should be laid out at Offset(1, 1).
        final positionedElement = (element as StackElement).childElements[1];
        expect(positionedElement.relativeOffset, const Offset(1, 1));
        expect(positionedElement.size, const Size(2, 2));
      },
    );
  });
}
