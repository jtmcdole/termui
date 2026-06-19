import 'package:termui/termui.dart';
import 'package:termui/terminal/event.dart' as evt;
import 'package:test/test.dart';

void main() {
  group('NumberSelector Tests', () {
    test('NumberSelector handles mouse clicks', () {
      int val = 5;
      final selector = NumberSelector(
        value: val,
        min: 0,
        max: 10,
        label: 'Num',
        onChanged: (v) => val = v,
      );

      final element = selector.createElement();
      element.mount(null);
      element.layout(const BoxConstraints());

      // The left arrow is at Num: < (len of "Num" is 3) -> index 5
      selector.handleMouseEvent(
        evt.MouseEvent(
          x: 5,
          y: 0,
          button: evt.MouseButton.left,
          type: evt.MouseEventType.press,
          modifiers: const {},
        ),
        5,
        0,
      );
      expect(val, 4);

      // The right arrow is at the end. "Num: < 4 >" length is 10, index 9
      selector.handleMouseEvent(
        evt.MouseEvent(
          x: 9,
          y: 0,
          button: evt.MouseButton.left,
          type: evt.MouseEventType.press,
          modifiers: const {},
        ),
        9,
        0,
      );
      expect(val, 5);
    });
  });
}
