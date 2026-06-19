import 'package:test/test.dart';
import 'package:termui/ui/widgets/interactive/text_field.dart';

void main() {
  group('TextEditingController Tests', () {
    test('Initializes with default empty values', () {
      final controller = TextEditingController();
      expect(controller.text, isEmpty);
      expect(controller.value.selection.baseOffset, equals(0));
      expect(controller.value.selection.extentOffset, equals(0));
      expect(controller.value.selection.cursorLine, equals(0));
      expect(controller.value.selection.cursorColumn, equals(0));
    });

    test('Initializes with text', () {
      final controller = TextEditingController(text: 'Hello\nWorld');
      expect(controller.text, equals('Hello\nWorld'));
      expect(controller.value.lines, equals(['Hello', 'World']));
      // Cursor should be at the end
      expect(controller.value.selection.cursorLine, equals(1));
      expect(controller.value.selection.cursorColumn, equals(5));
    });

    test('Notifies listeners on value change', () {
      final controller = TextEditingController();
      var count = 0;
      controller.addListener(() {
        count++;
      });

      controller.text = 'New Text';
      expect(count, equals(1));
      expect(controller.text, equals('New Text'));

      // Listener shouldn't notify if value hasn't changed
      controller.value = controller.value;
      expect(count, equals(1));
    });

    test('Undo and Redo stacks', () {
      final controller = TextEditingController(text: 'Initial');
      controller.saveStateToHistory();
      controller.text = 'Change 1';
      controller.saveStateToHistory();
      controller.text = 'Change 2';

      expect(controller.text, equals('Change 2'));

      // Undo 1
      controller.undo();
      expect(controller.text, equals('Change 1'));

      // Undo 2
      controller.undo();
      expect(controller.text, equals('Initial'));

      // Redo 1
      controller.redo();
      expect(controller.text, equals('Change 1'));

      // Redo 2
      controller.redo();
      expect(controller.text, equals('Change 2'));
    });
  });
}
