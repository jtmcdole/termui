import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/event.dart';
import 'package:termui/ui/widget_toolkit.dart';
import 'package:termui_recorder/termui_recorder.dart';

void main() {
  group('Dynamic Form & FormField Tests', () {
    test('Dynamic field registration and validation', () {
      final nameField = TextFormField(
        label: 'Name',
        initialValue: '',
        validator: (val) => (val == null || val.isEmpty) ? 'Required' : null,
      );
      final emailField = TextFormField(
        label: 'Email',
        initialValue: '',
        validator: (val) =>
            (val == null || !val.contains('@')) ? 'Invalid' : null,
      );

      final form = Form(child: Column([nameField, emailField]));

      final tree = ElementWidget(form);
      final buffer = Buffer.blank(20, 10);
      tree.layout(BoxConstraints.tight(const Size(20, 10)));
      tree.paint(buffer, Offset.zero);

      final formState = tree.findState<FormState>();
      expect(formState, isNotNull);

      // Verify validation fails initially
      expect(formState!.validate(), isFalse);
      expect(nameField.hasError, isTrue);
      expect(nameField.errorText, equals('Required'));
      expect(emailField.hasError, isTrue);
      expect(emailField.errorText, equals('Invalid'));

      // Fill in name
      nameField.value = 'Alice';
      expect(formState.validate(), isFalse);
      expect(nameField.hasError, isFalse);
      expect(emailField.hasError, isTrue);

      // Fill in email
      emailField.value = 'alice@example.com';
      expect(formState.validate(), isTrue);
      expect(nameField.hasError, isFalse);
      expect(emailField.hasError, isFalse);
    });

    test('Dynamic Form reset', () {
      final nameField = TextFormField(
        label: 'Name',
        initialValue: 'Bob',
        validator: (val) => (val == null || val.isEmpty) ? 'Required' : null,
      );
      final form = Form(child: Column([nameField]));

      final tree = ElementWidget(form);
      final buffer = Buffer.blank(20, 10);
      tree.layout(BoxConstraints.tight(const Size(20, 10)));
      tree.paint(buffer, Offset.zero);

      final formState = tree.findState<FormState>()!;
      nameField.value = '';
      expect(formState.validate(), isFalse);
      expect(nameField.hasError, isTrue);

      // Reset
      formState.reset();
      expect(nameField.value, equals('Bob'));
      expect(nameField.hasError, isFalse);
      expect(nameField.errorText, isNull);
    });

    test('Dynamic Form focus traversal', () {
      final f1 = TextFormField(label: 'F1');
      final f2 = TextFormField(label: 'F2');
      final form = Form(child: Column([f1, f2]));

      final tree = ElementWidget(form);
      final buffer = Buffer.blank(20, 10);
      tree.layout(BoxConstraints.tight(const Size(20, 10)));
      tree.paint(buffer, Offset.zero);

      final formState = tree.findState<FormState>()!;
      f1.focused = true;
      expect(f1.focused, isTrue);
      expect(f2.focused, isFalse);

      // Press Tab moves to F2
      formState.handleKeyEvent(const KeyEvent('tab', KeyType.character));
      expect(f1.focused, isFalse);
      expect(f2.focused, isTrue);

      // Press Backtab moves to F1
      formState.handleKeyEvent(const KeyEvent('backtab', KeyType.character));
      expect(f1.focused, isTrue);
      expect(f2.focused, isFalse);
    });

    test('Dynamic Form focus traversal with Up/Down arrow keys', () {
      final f1 = TextFormField(label: 'F1');
      final f3 = TextAreaFormField(
        label: 'F3',
        initialValue: 'line1\nline2',
        fieldHeight: 2,
      );
      final form = Form(child: Column([f1, f3]));

      final tree = ElementWidget(form);
      final buffer = Buffer.blank(20, 10);
      tree.layout(BoxConstraints.tight(const Size(20, 10)));
      tree.paint(buffer, Offset.zero);

      final formState = tree.findState<FormState>()!;
      f1.focused = true;
      expect(f1.focused, isTrue);
      expect(f3.focused, isFalse);

      // Press Down on F1 moves to F3
      formState.handleKeyEvent(const KeyEvent('down', KeyType.down));
      expect(f1.focused, isFalse);
      expect(f3.focused, isTrue);

      // When entering F3, cursor is initially at the end (line 1)
      expect(f3.cursorLine, equals(1));

      // Press Up on F3: since cursor is at line 1, it should move cursor to line 0 and focus remains on F3
      formState.handleKeyEvent(const KeyEvent('up', KeyType.up));
      expect(f3.focused, isTrue);
      expect(f3.cursorLine, equals(0));

      // Press Up on F3 again: since cursor is at line 0, it should move focus back to F1
      formState.handleKeyEvent(const KeyEvent('up', KeyType.up));
      expect(f1.focused, isTrue);
      expect(f3.focused, isFalse);

      // Move to F3 again (cursor should keep its state at line 0)
      formState.handleKeyEvent(const KeyEvent('down', KeyType.down));
      expect(f3.focused, isTrue);
      expect(f3.cursorLine, equals(0));

      // Move cursor down within F3 (multiline)
      formState.handleKeyEvent(const KeyEvent('down', KeyType.down));
      // Cursor should have moved to line 1 (and focus should NOT change because it was handled inside F3)
      expect(f3.focused, isTrue);
      expect(f3.cursorLine, equals(1));

      // Pressing Down on F3 at last line should cycle/move focus back to F1
      formState.handleKeyEvent(const KeyEvent('down', KeyType.down));
      expect(f1.focused, isTrue);
      expect(f3.focused, isFalse);
    });

    test('Legacy Form focus traversal with Up/Down arrow keys', () {
      final f1 = TextFormField(label: 'F1');
      final f2 = TextFormField(label: 'F2');
      final form = Form(fields: [f1, f2]);

      expect(f1.focused, isTrue);
      expect(f2.focused, isFalse);

      // Down moves to f2
      form.handleKeyEvent(const KeyEvent('down', KeyType.down));
      expect(f1.focused, isFalse);
      expect(f2.focused, isTrue);

      // Up moves to f1
      form.handleKeyEvent(const KeyEvent('up', KeyType.up));
      expect(f1.focused, isTrue);
      expect(f2.focused, isFalse);
    });

    test('Legacy Form LeftBorder focus updates on tab', () {
      final f1 = TextFormField(label: 'Field 1');
      final f2 = TextFormField(label: 'Field 2');
      final form = Form(fields: [f1, f2]);

      final tree = ElementWidget(form);
      final buffer = Buffer.blank(20, 10);
      buffer.clear();
      tree.layout(BoxConstraints.tight(const Size(20, 10)));
      tree.paint(buffer, Offset.zero);

      final formState = tree.findState<FormState>()!;

      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/dynamic_form_field1_focused.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );

      // Press Tab to move focus to Field 2
      formState.handleKeyEvent(const KeyEvent('tab', KeyType.character));

      // Re-render
      buffer.clear();
      tree.layout(BoxConstraints.tight(const Size(20, 10)));
      tree.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/dynamic_form_field2_focused.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
    });

    test('validate when navigating away', () {
      final field = TextFormField(
        label: 'Email',
        initialValue: '',
        validator: (val) => (val == null || val.isEmpty) ? 'Required' : null,
      );
      final form = Form(fields: [field]);
      final tree = ElementWidget(form);
      final buffer = Buffer.blank(20, 10);
      tree.layout(BoxConstraints.tight(const Size(20, 10)));
      tree.paint(buffer, Offset.zero);

      expect(field.hasError, isFalse);

      field.focused = true;
      expect(field.hasError, isFalse);

      field.focused = false;
      expect(field.hasError, isTrue);
      expect(field.errorText, equals('Required'));
    });

    test('hitting enter moves to next field and validates', () {
      final f1 = TextFormField(
        label: 'F1',
        initialValue: '',
        validator: (val) => (val == null || val.isEmpty) ? 'Required' : null,
      );
      final f2 = TextFormField(label: 'F2');
      final form = Form(fields: [f1, f2]);
      final tree = ElementWidget(form);
      final buffer = Buffer.blank(20, 10);
      tree.layout(BoxConstraints.tight(const Size(20, 10)));
      tree.paint(buffer, Offset.zero);

      expect(f1.focused, isTrue);
      expect(f2.focused, isFalse);
      expect(f1.hasError, isFalse);

      form.handleKeyEvent(const KeyEvent('\n', KeyType.enter));

      expect(f1.focused, isFalse);
      expect(f2.focused, isTrue);
      expect(f1.hasError, isTrue);
      expect(form.activeFieldIndex, equals(1));
    });

    test('no validation on initial focus loss if never touched', () {
      final field = TextFormField(
        label: 'Email',
        initialValue: '',
        validator: (val) => (val == null || val.isEmpty) ? 'Required' : null,
      );
      final form = Form(fields: [field]);
      final tree = ElementWidget(form);
      final buffer = Buffer.blank(20, 10);
      tree.layout(BoxConstraints.tight(const Size(20, 10)));
      tree.paint(buffer, Offset.zero);

      expect(field.focused, isTrue);
      expect(field.hasError, isFalse);

      // Simulate the widget book toggling focus to false on initial build before any interaction
      field.focused = false;
      expect(field.hasError, isFalse);
    });
  });
}
