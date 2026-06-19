import 'package:termui/termui.dart';
import 'package:termui/terminal/event.dart' as evt;
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

void main() {
  group('HorizontalRadioGroup Tests', () {
    test('Selects option via keyboard', () {
      final controller = SelectionController<String>(
        options: const ['a', 'b'],
        initialIndex: 0,
      );

      final group = HorizontalRadioGroup(
        controller: controller,
        focused: true,
      );

      final element = group.createElement();
      element.mount(null);
      element.layout(const BoxConstraints(maxWidth: 50, maxHeight: 10));

      // Right arrow moves selection
      (element as dynamic).state.handleKeyEvent(const evt.KeyEvent('right', evt.KeyType.character));
      expect(controller.focusedIndex, 1);

      (element as dynamic).state.handleKeyEvent(const evt.KeyEvent('left', evt.KeyType.character));
      expect(controller.focusedIndex, 0);
    });
  });

  group('FocusScopeNode Tests', () {
    test('FocusScopeNode logic', () {
      final focus = Focus(
        child: const Text('Foo'),
        onFocusChange: (f) {},
      );

      final element = focus.createElement();
      element.mount(null);
      element.layout(const BoxConstraints(maxWidth: 50, maxHeight: 10));

      final buffer = Buffer(10, 10);
      element.paint(buffer, Offset.zero);

      expect(buffer.getCell(0, 0)?.char, 'F');

      // Update with same widget
      element.update(Focus(child: const Text('Bar'), onFocusChange: (f){}));
      element.layout(const BoxConstraints(maxWidth: 50, maxHeight: 10));
      element.paint(buffer, Offset.zero);
      expect(buffer.getCell(0, 0)?.char, 'B');
    });
  });
}
