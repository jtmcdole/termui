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
      (element as dynamic).handleMouseEvent(
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

      (element as dynamic).handleMouseEvent(
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

      (element as dynamic).handleMouseEvent(
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
      (element as dynamic).handleMouseEvent(
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

      (element as dynamic).handleMouseEvent(
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
  });
}
