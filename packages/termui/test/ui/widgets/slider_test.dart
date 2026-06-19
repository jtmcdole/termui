import 'package:test/test.dart';
import 'package:termui/termui.dart';
import 'package:termui_recorder/termui_recorder.dart';

void main() {
  group('Slider', () {
    test('calculates correct width and height', () {
      final widget = Slider(value: 50, min: 0, max: 100);
      final element = widget.createElement();
      element.mount(null);

      final size = element.layout(
        const BoxConstraints(
          minWidth: 0,
          maxWidth: 50,
          minHeight: 0,
          maxHeight: 10,
        ),
      );
      expect(size.width, 50);
      expect(size.height, 1);

      final vWidget = Slider(
        value: 50,
        min: 0,
        max: 100,
        axis: SliderAxis.vertical,
      );
      final vElement = vWidget.createElement();
      vElement.mount(null);

      final vSize = vElement.layout(
        const BoxConstraints(
          minWidth: 0,
          maxWidth: 50,
          minHeight: 0,
          maxHeight: 10,
        ),
      );
      expect(vSize.width, 1);
      expect(vSize.height, 10);
    });

    test('handles keyboard inputs correctly', () {
      double currentValue = 50;
      final widget = Slider(
        value: currentValue,
        min: 0,
        max: 100,
        focused: true,
        onChanged: (val) {
          currentValue = val;
        },
      );

      final element = widget.createElement() as StatefulElement;
      element.mount(null);
      element.layout(
        const BoxConstraints(
          minWidth: 0,
          maxWidth: 50,
          minHeight: 0,
          maxHeight: 10,
        ),
      );

      final state = element.state as SliderState;

      // Right arrow increases by 5% (5 units)
      state.handleKeyEvent(KeyEvent('', KeyType.right));
      expect(currentValue, 55);

      // Left arrow decreases by 5%
      state.handleKeyEvent(KeyEvent('', KeyType.left));
      expect(currentValue, 50);

      // Verify clamping
      currentValue = 0;
      widget.value = 0;
      state.handleKeyEvent(KeyEvent('', KeyType.left));
      expect(currentValue, 0);

      currentValue = 100;
      widget.value = 100;
      state.handleKeyEvent(KeyEvent('', KeyType.right));
      expect(currentValue, 100);
    });

    test('handles vertical keyboard inputs correctly', () {
      double currentValue = 50;
      final widget = Slider(
        value: currentValue,
        min: 0,
        max: 100,
        axis: SliderAxis.vertical,
        focused: true,
        onChanged: (val) {
          currentValue = val;
        },
      );

      final element = widget.createElement() as StatefulElement;
      element.mount(null);
      element.layout(
        const BoxConstraints(
          minWidth: 0,
          maxWidth: 50,
          minHeight: 0,
          maxHeight: 10,
        ),
      );

      final state = element.state as SliderState;

      state.handleKeyEvent(KeyEvent('', KeyType.up));
      expect(currentValue, 55);

      state.handleKeyEvent(KeyEvent('', KeyType.down));
      expect(currentValue, 50);
    });

    test('handles mouse drag correctly', () {
      double currentValue = 50;
      final widget = Slider(
        value: currentValue,
        min: 0,
        max: 100,
        onChanged: (val) {
          currentValue = val;
        },
      );

      final element = widget.createElement() as StatefulElement;
      element.mount(null);
      final size = element.layout(
        const BoxConstraints(
          minWidth: 0,
          maxWidth: 21,
          minHeight: 0,
          maxHeight: 1,
        ),
      );

      final state = element.state as SliderState;

      // Press at 10 (which is 50% of 20 length track)
      state.handleMouseEvent(
        MouseEvent(
          type: MouseEventType.press,
          button: MouseButton.left,
          x: 0,
          y: 0,
        ),
        10,
        0,
        Rect(0, 0, size.width, size.height),
      );
      expect(currentValue, 50);

      // Drag to 20 (which is 100% of 20 length track)
      state.handleMouseEvent(
        MouseEvent(
          type: MouseEventType.drag,
          button: MouseButton.left,
          x: 0,
          y: 0,
        ),
        20,
        0,
        Rect(0, 0, size.width, size.height),
      );
      expect(currentValue, 100);

      // Release
      state.handleMouseEvent(
        MouseEvent(
          type: MouseEventType.release,
          button: MouseButton.left,
          x: 0,
          y: 0,
        ),
        20,
        0,
        Rect(0, 0, size.width, size.height),
      );
    });

    test('handles vertical mouse drag correctly', () {
      double currentValue = 50;
      final widget = Slider(
        value: currentValue,
        min: 0,
        max: 100,
        axis: SliderAxis.vertical,
        onChanged: (val) {
          currentValue = val;
        },
      );

      final element = widget.createElement() as StatefulElement;
      element.mount(null);
      final size = element.layout(
        const BoxConstraints(
          minWidth: 0,
          maxWidth: 1,
          minHeight: 0,
          maxHeight: 21,
        ),
      );

      final state = element.state as SliderState;

      // Press at y=10 (which is 50% of 20 length track from the bottom)
      // For vertical slider, top (y=0) is max, bottom (y=height-1) is min
      state.handleMouseEvent(
        MouseEvent(
          type: MouseEventType.press,
          button: MouseButton.left,
          x: 0,
          y: 0,
        ),
        0,
        10,
        Rect(0, 0, size.width, size.height),
      );
      expect(currentValue, 50);

      // Drag to 0 (which is 100%)
      state.handleMouseEvent(
        MouseEvent(
          type: MouseEventType.drag,
          button: MouseButton.left,
          x: 0,
          y: 0,
        ),
        0,
        0,
        Rect(0, 0, size.width, size.height),
      );
      expect(currentValue, 100);

      // Drag to 20 (which is 0%)
      state.handleMouseEvent(
        MouseEvent(
          type: MouseEventType.drag,
          button: MouseButton.left,
          x: 0,
          y: 0,
        ),
        0,
        20,
        Rect(0, 0, size.width, size.height),
      );
      expect(currentValue, 0);
    });

    test('renders golden correctly', () {
      final buffer = Buffer.blank(21, 5);

      final widget = Column([
        Slider(value: 0, min: 0, max: 100),
        Slider(value: 50, min: 0, max: 100),
        Slider(value: 100, min: 0, max: 100),
      ]);

      final element = widget.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(21, 5)));
      element.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/slider_horizontal.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
    });

    test('renders vertical golden correctly', () {
      final buffer = Buffer.blank(5, 11);

      final widget = Row([
        Slider(value: 0, min: 0, max: 100, axis: SliderAxis.vertical),
        Slider(value: 50, min: 0, max: 100, axis: SliderAxis.vertical),
        Slider(value: 100, min: 0, max: 100, axis: SliderAxis.vertical),
      ]);

      final element = widget.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(5, 11)));
      element.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/slider_vertical.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
    });
    test('delegates events from widget correctly and handles lifecycle', () {
      final widget = Slider(value: 50, min: 0, max: 100);
      final element = widget.createElement() as StatefulElement;
      element.mount(null);
      element.layout(
        const BoxConstraints(
          minWidth: 0,
          maxWidth: 50,
          minHeight: 0,
          maxHeight: 10,
        ),
      );

      // Test widget-level handleKeyEvent
      final handled = widget.handleKeyEvent(KeyEvent('', KeyType.right));
      expect(handled, isTrue);
      expect(widget.value, 55);

      // Test widget-level handleMouseEvent
      widget.handleMouseEvent(
        MouseEvent(
          type: MouseEventType.press,
          button: MouseButton.left,
          x: 0,
          y: 0,
        ),
        10,
        0,
        const Rect(0, 0, 21, 1),
      );
      expect(widget.value, 50);

      // Test didUpdateWidget logic (focus change)
      final newWidget = Slider(value: 50, min: 0, max: 100, focused: true);
      element.update(newWidget);

      final unfocusedWidget = Slider(
        value: 50,
        min: 0,
        max: 100,
        focused: false,
      );
      element.update(unfocusedWidget);

      // Test dispose
      element.unmount();
    });

    test('custom trackChar', () {
      final buffer = Buffer.blank(21, 5);
      final widget = Slider(value: 50, min: 0, max: 100, trackChar: '.');
      final element = widget.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(21, 1)));
      element.paint(buffer, Offset.zero);
      expect(buffer.getCell(0, 0)?.char, '.');

      final vWidget = Slider(
        value: 50,
        min: 0,
        max: 100,
        axis: SliderAxis.vertical,
        trackChar: '.',
      );
      final vElement = vWidget.createElement();
      vElement.mount(null);
      vElement.layout(BoxConstraints.tight(const Size(1, 21)));
      buffer.clear();
      vElement.paint(buffer, Offset.zero);
      expect(buffer.getCell(0, 0)?.char, '.');
    });
  });
}
