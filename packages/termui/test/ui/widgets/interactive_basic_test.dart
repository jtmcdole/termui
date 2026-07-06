import 'package:termui/termui.dart';
import 'package:termui/terminal/event.dart' as evt;
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

void main() {
  group('Interactive Widgets Paint and Interact Tests', () {
    test('Button responds to keyboard events and paints correctly', () async {
      var pressed = false;
      final btn = Button(
        text: 'Click Me',
        onPressed: () {
          pressed = true;
        },
        focused: true,
      );
      final tester = TerminalTester();
      await tester.pumpWidget(btn);

      ((tester.rootElement as StatefulElement).state as dynamic).handleKeyEvent(
        const evt.KeyEvent(' ', evt.KeyType.character),
      );
      expect(pressed, true);

      pressed = false;
      ((tester.rootElement as StatefulElement).state as ButtonState)
          .handleMouseEvent(
            evt.MouseEvent(
              x: 1,
              y: 1,
              button: evt.MouseButton.left,
              type: evt.MouseEventType.press,
              modifiers: const {},
            ),
            0,
            0,
          );
      expect(pressed, true);
    });

    test('Checkbox handles toggle and paints', () async {
      var checked = false;
      final chk = Checkbox(
        value: checked,
        label: 'Chk',
        onChanged: (v) {
          checked = v;
        },
        focused: true,
      );
      final tester = TerminalTester();
      await tester.pumpWidget(chk);

      ((tester.rootElement as StatefulElement).state as dynamic).handleKeyEvent(
        const evt.KeyEvent(' ', evt.KeyType.character),
      );
      expect(checked, true);

      ((tester.rootElement as StatefulElement).state as CheckboxState)
          .handleMouseEvent(
            evt.MouseEvent(
              x: 1,
              y: 1,
              button: evt.MouseButton.left,
              type: evt.MouseEventType.press,
              modifiers: const {},
            ),
            0,
            0,
            const Rect(0, 0, 0, 0),
          );
      expect(checked, true);
    });

    test('Radio handles toggle and paints', () async {
      var selected = false;
      final rad = Radio<String>(
        value: 'A',
        groupValue: 'B',
        label: 'Rad',
        onChanged: (v) {
          selected = true;
        },
        focused: true,
      );
      final tester = TerminalTester();
      await tester.pumpWidget(rad);

      ((tester.rootElement as StatefulElement).state as dynamic).handleKeyEvent(
        const evt.KeyEvent(' ', evt.KeyType.character),
      );
      expect(selected, true);

      selected = false;
      ((tester.rootElement as StatefulElement).state as RadioState<String>)
          .handleMouseEvent(
            evt.MouseEvent(
              x: 1,
              y: 1,
              button: evt.MouseButton.left,
              type: evt.MouseEventType.press,
              modifiers: const {},
            ),
            0,
            0,
          );
      expect(selected, true);
    });

    test('Switch handles toggle and paints', () async {
      var switched = false;
      final sw = Switch(
        value: switched,
        label: 'Sw',
        onChanged: (v) {
          switched = v;
        },
        focused: true,
      );
      final tester = TerminalTester();
      await tester.pumpWidget(sw);

      ((tester.rootElement as StatefulElement).state as dynamic).handleKeyEvent(
        const evt.KeyEvent(' ', evt.KeyType.character),
      );
      expect(switched, true);

      ((tester.rootElement as StatefulElement).state as SwitchState)
          .handleMouseEvent(
            evt.MouseEvent(
              x: 1,
              y: 1,
              button: evt.MouseButton.left,
              type: evt.MouseEventType.press,
              modifiers: const {},
            ),
            0,
            0,
          );
      expect(switched, true);
    });
  });
}
