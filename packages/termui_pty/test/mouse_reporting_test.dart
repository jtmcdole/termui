import 'package:termui/terminal/event.dart' as ev;
import 'package:termui_pty/termui_pty.dart';
import 'package:test/test.dart';

void main() {
  test('InputEncoder encodes MouseEvent with VT100 SGR sequence', () {
    // Mouse Down (Left) at (10, 5)
    final downEvent = ev.MouseEvent(
      x: 10,
      y: 5,
      globalX: 10,
      globalY: 5,
      button: ev.MouseButton.left,
      type: ev.MouseEventType.press,
      modifiers: const {},
    );
    expect(InputEncoder.encode(downEvent), equals('\x1b[<0;10;5M'));

    // Mouse Up (Left) at (10, 5)
    final upEvent = ev.MouseEvent(
      x: 10,
      y: 5,
      globalX: 10,
      globalY: 5,
      button: ev.MouseButton.left,
      type: ev.MouseEventType.release,
      modifiers: const {},
    );
    expect(InputEncoder.encode(upEvent), equals('\x1b[<0;10;5m'));

    // Mouse Drag (Left) at (12, 6)
    final dragEvent = ev.MouseEvent(
      x: 12,
      y: 6,
      globalX: 12,
      globalY: 6,
      button: ev.MouseButton.left,
      type: ev.MouseEventType.drag,
      modifiers: const {},
    );
    expect(InputEncoder.encode(dragEvent), equals('\x1b[<32;12;6M')); // 0 + 32
  });

  test('InputEncoder encodes MouseEvent with modifiers', () {
    // Ctrl + Mouse Down (Left) at (2, 2)
    final ctrlDown = ev.MouseEvent(
      x: 2,
      y: 2,
      globalX: 2,
      globalY: 2,
      button: ev.MouseButton.left,
      type: ev.MouseEventType.press,
      modifiers: const {ev.Modifier.control},
    );
    expect(InputEncoder.encode(ctrlDown), equals('\x1b[<16;2;2M')); // 0 + 16

    // Shift + Wheel Up at (3, 3)
    final shiftWheelUp = ev.MouseEvent(
      x: 3,
      y: 3,
      globalX: 3,
      globalY: 3,
      button: ev.MouseButton.wheelUp,
      type: ev.MouseEventType.press, // Wheel uses press
      modifiers: const {ev.Modifier.shift},
    );
    expect(
      InputEncoder.encode(shiftWheelUp),
      equals('\x1b[<68;3;3M'),
    ); // 64 + 4
  });
}
