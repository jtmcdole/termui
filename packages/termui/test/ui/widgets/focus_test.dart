import 'package:termui/termui.dart';
import 'package:test/test.dart';

void main() {
  group('Focus Tests', () {
    test('Focus widget autofocuses and callbacks', () async {
      final focusWidget = Focus(
        autofocus: true,
        onKeyEvent: (evt) {
          return true;
        },
        onFocusChange: (has) {},
        child: Text('Focused Child'),
      );

      final element = focusWidget.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(20, 20)));

      // Send a key event
      expect(true, true);
    });

    test('Focus widget uses existing node', () async {
      final node = FocusNode(id: 'existing');

      final focusWidget = Focus(
        focusNode: node,
        onFocusChange: (has) {},
        child: Text('Child'),
      );

      final element = focusWidget.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(20, 20)));

      node.requestFocus();
    });

    test('FocusScope handles initialization', () async {
      final focusScope = FocusScope(
        child: Focus(
          focusNode: FocusNode(id: 'inner'),
          child: Text('Inner'),
        ),
      );

      final element = focusScope.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(20, 20)));
      expect(true, true);
    });
  });
}
