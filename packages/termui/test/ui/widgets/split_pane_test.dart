import 'package:termui/termui.dart';
import 'package:termui/terminal/event.dart' as evt;
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

void main() {
  group('SplitPane Tests', () {
    test('SplitPane handles resizing via mouse drag', () {
      final pane = SplitPane(
        direction: LayoutDirection.horizontal,
        constraint1: const PercentageConstraint(50),
        constraint2: const PercentageConstraint(50),
        child1: const Text('Left'),
        child2: const Text('Right'),
      );

      final element = pane.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(20, 10)));

      // Initial fraction 0.5 -> splitter at x=10
      // drag splitter
      (element as SplitPaneElement).handleMouseEvent(
        evt.MouseEvent(
          x: 10,
          y: 5,
          button: evt.MouseButton.left,
          type: evt.MouseEventType.press,
          modifiers: const {},
        ),
        10,
        5,
      );

      element.handleMouseEvent(
        evt.MouseEvent(
          x: 15,
          y: 5,
          button: evt.MouseButton.left,
          type: evt.MouseEventType.drag,
          modifiers: const {},
        ),
        15,
        5,
      );

      element.handleMouseEvent(
        evt.MouseEvent(
          x: 15,
          y: 5,
          button: evt.MouseButton.left,
          type: evt.MouseEventType.release,
          modifiers: const {},
        ),
        15,
        5,
      );

      // Re-layout and verify sizes if we had access to fraction, or just check it doesn't crash
      element.layout(BoxConstraints.tight(const Size(20, 10)));
    });

    test('SplitPane axis vertical mouse drag', () {
      final pane = SplitPane(
        direction: LayoutDirection.vertical,
        constraint1: const PercentageConstraint(50),
        constraint2: const PercentageConstraint(50),
        child1: const Text('Top'),
        child2: const Text('Bottom'),
      );

      final element = pane.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(10, 20)));

      // splitter at y=10
      (element as SplitPaneElement).handleMouseEvent(
        evt.MouseEvent(
          x: 5,
          y: 10,
          button: evt.MouseButton.left,
          type: evt.MouseEventType.press,
          modifiers: const {},
        ),
        5,
        10,
      );

      element.handleMouseEvent(
        evt.MouseEvent(
          x: 5,
          y: 15,
          button: evt.MouseButton.left,
          type: evt.MouseEventType.drag,
          modifiers: const {},
        ),
        5,
        15,
      );
    });

    test('SplitPane renders correctly', () async {
      final tester = TerminalTester();
      await tester.pumpWidget(
        SplitPane(
          child1: const Text('A'),
          child2: const Text('B'),
          direction: LayoutDirection.horizontal,
          constraint1: const PercentageConstraint(50),
          constraint2: const PercentageConstraint(50),
        ),
      );

      expect(tester.buffer!.getCharacter(0, 0), 'A');
    });

    test('vertical SplitPane paints divider across full width', () {
      final pane = SplitPane(
        direction: .vertical,
        dividerChar: '─',
        constraint1: const LengthConstraint(4),
        constraint2: const FlexConstraint(1),
        child1: const Text('Top'),
        child2: const Text('Bot'),
      );

      final element = pane.createElement() as SplitPaneElement;
      addTearDown(element.unmount);
      element.mount(null);
      element.layout(.tight(const Size(10, 11)));

      final buffer = Buffer.blank(10, 11);
      element.paint(buffer, .zero);

      expect(pane.lastArea, const Rect(0, 0, 10, 11));
      expect(pane.dividerPosition, 4);
      expect(buffer.getCharacter(0, 0), 'T');
      expect(buffer.getCharacter(0, 5), 'B');
      for (var x = 0; x < 10; x++) {
        expect(buffer.getCharacter(x, 4), '─');
      }
    });

    test(
      'PercentageConstraint drag updates constraints and release stops drag',
      () {
        final pane = SplitPane(
          direction: .horizontal,
          constraint1: const PercentageConstraint(50),
          constraint2: const PercentageConstraint(50),
          child1: const Text('L'),
          child2: const Text('R'),
        );

        final element = pane.createElement() as SplitPaneElement;
        addTearDown(element.unmount);
        element.mount(null);
        element.layout(.tight(const Size(20, 5)));
        element.paint(Buffer.blank(20, 5), .zero);

        expect(pane.dividerPosition, 10);
        expect(pane.isDragging, isFalse);

        element.handleMouseEvent(
          evt.MouseEvent(
            x: 10,
            y: 2,
            button: .left,
            type: .press,
            modifiers: const {},
          ),
          10,
          2,
        );
        expect(pane.isDragging, isTrue);

        element.handleMouseEvent(
          evt.MouseEvent(
            x: 15,
            y: 2,
            button: .left,
            type: .drag,
            modifiers: const {},
          ),
          15,
          2,
        );
        expect(pane.dividerPosition, 15);
        expect(pane.constraint1, isA<PercentageConstraint>());
        expect((pane.constraint1 as PercentageConstraint).percentage, 75);
        expect((pane.constraint2 as PercentageConstraint).percentage, 25);

        element.handleMouseEvent(
          evt.MouseEvent(
            x: 15,
            y: 2,
            button: .left,
            type: .release,
            modifiers: const {},
          ),
          15,
          2,
        );
        expect(pane.isDragging, isFalse);

        // Drag after release must not move the divider.
        element.handleMouseEvent(
          evt.MouseEvent(
            x: 5,
            y: 2,
            button: .left,
            type: .drag,
            modifiers: const {},
          ),
          5,
          2,
        );
        expect(pane.dividerPosition, 15);
      },
    );

    test('FlexConstraint drag updates flex weights', () {
      final pane = SplitPane(
        direction: .horizontal,
        constraint1: const FlexConstraint(1),
        constraint2: const FlexConstraint(1),
        child1: const Text('L'),
        child2: const Text('R'),
      );

      final element = pane.createElement() as SplitPaneElement;
      addTearDown(element.unmount);
      element.mount(null);
      element.layout(.tight(const Size(20, 5)));
      element.paint(Buffer.blank(20, 5), .zero);

      expect(pane.dividerPosition, 10);

      element.handleMouseEvent(
        evt.MouseEvent(
          x: 10,
          y: 1,
          button: .left,
          type: .press,
          modifiers: const {},
        ),
        10,
        1,
      );
      element.handleMouseEvent(
        evt.MouseEvent(
          x: 6,
          y: 1,
          button: .left,
          type: .drag,
          modifiers: const {},
        ),
        6,
        1,
      );
      element.handleMouseEvent(
        evt.MouseEvent(
          x: 6,
          y: 1,
          button: .left,
          type: .release,
          modifiers: const {},
        ),
        6,
        1,
      );

      expect(pane.dividerPosition, 6);
      expect(pane.constraint1, isA<FlexConstraint>());
      expect((pane.constraint1 as FlexConstraint).flex, 6);
      expect((pane.constraint2 as FlexConstraint).flex, 13);
      expect(pane.isDragging, isFalse);
    });

    test('two-sided MinMaxConstraint clamps divider to both pane limits', () {
      final pane = SplitPane(
        direction: .horizontal,
        constraint1: const MinMaxConstraint(min: 3, max: 14),
        constraint2: const MinMaxConstraint(min: 6, max: 10),
        child1: const Text('L'),
        child2: const Text('R'),
      );

      final element = pane.createElement() as SplitPaneElement;
      addTearDown(element.unmount);
      element.mount(null);
      // totalSize = 20 (1 cell for divider):
      // minW1 = max(3, 20 - 10 - 1) = 9
      // maxW1 = min(14, 20 - 6 - 1) = 13
      element.layout(.tight(const Size(20, 5)));
      element.paint(Buffer.blank(20, 5), .zero);

      expect(pane.dividerPosition, 9);

      element.handleMouseEvent(
        evt.MouseEvent(
          x: 9,
          y: 2,
          button: .left,
          type: .press,
          modifiers: const {},
        ),
        9,
        2,
      );

      // Drag below minW1 (constrained by constraint2.max = 10) -> clamped to 9.
      element.handleMouseEvent(
        evt.MouseEvent(
          x: 2,
          y: 2,
          button: .left,
          type: .drag,
          modifiers: const {},
        ),
        2,
        2,
      );
      expect(pane.dividerPosition, 9);
      expect(pane.constraint1, isA<MinMaxConstraint>());
      expect((pane.constraint1 as MinMaxConstraint).min, 9);
      expect((pane.constraint1 as MinMaxConstraint).max, 14);
      expect((pane.constraint2 as MinMaxConstraint).min, 10);
      expect((pane.constraint2 as MinMaxConstraint).max, 10);

      // Drag above maxW1 (constrained by constraint2.min = 6) -> clamped to 13.
      element.handleMouseEvent(
        evt.MouseEvent(
          x: 18,
          y: 2,
          button: .left,
          type: .drag,
          modifiers: const {},
        ),
        18,
        2,
      );
      expect(pane.dividerPosition, 13);
      expect((pane.constraint1 as MinMaxConstraint).min, 13);
      expect((pane.constraint1 as MinMaxConstraint).max, 14);
      expect((pane.constraint2 as MinMaxConstraint).min, 6);
      expect((pane.constraint2 as MinMaxConstraint).max, 10);

      element.handleMouseEvent(
        evt.MouseEvent(
          x: 13,
          y: 2,
          button: .left,
          type: .release,
          modifiers: const {},
        ),
        13,
        2,
      );
      expect(pane.isDragging, isFalse);
    });
  });
}
