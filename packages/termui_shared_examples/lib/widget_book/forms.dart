import 'package:termui/termui.dart';
import 'package:termui/ui/event.dart' as ui;
import 'example_base.dart';

/// Example demonstrating interactive form fields and validation.
///
/// Showcases [TextFormField], [SelectFormField], and [ConfirmFormField]
/// with validation logic, placeholder texts, and keyboard navigation.
final class FormsExample extends WidgetBookExample {
  /// The form layout containing text, select, and confirm fields.
  final formDemo = Form(
    fields: [
      TextFormField(
        label: 'Email Address',
        description: 'We will send a validation code here.',
        placeholder: 'e.g. user@domain.com',
        cursorStyle: const Style(
          foreground: CharmColors.pepper,
          background: CharmColors.charple,
        ),
        validator: (val) {
          if (val == null || val.isEmpty) {
            return 'Email is required';
          }
          if (!val.contains('@')) {
            return 'Must be a valid email containing @';
          }
          return null;
        },
      ),
      SelectFormField<String>(
        label: 'Favorite Programming Language',
        description: 'Choose one of the languages below.',
        options: const [
          SelectOption('Dart', 'dart'),
          SelectOption('Go', 'go'),
          SelectOption('TypeScript', 'typescript'),
        ],
        initialValue: 'dart',
      ),
      ConfirmFormField(
        label: 'Agree to Terms & Conditions',
        description: 'Please read the terms carefully.',
        initialValue: false,
        validator: (val) {
          if (val != true) {
            return 'You must agree to proceed';
          }
          return null;
        },
      ),
    ],
  );

  @override
  Widget build({
    required bool focusDemoPane,
    required int width,
    required int height,
  }) {
    if (!focusDemoPane) {
      for (final field in formDemo.fields) {
        field.focused = false;
      }
    } else {
      final activeIdx = formDemo.activeFieldIndex;
      for (var i = 0; i < formDemo.fields.length; i++) {
        formDemo.fields[i].focused = (i == activeIdx);
      }
    }

    return Column([
      SizedBox(
        height: 2,
        child: Text(
          'Fill out the form below. Use [Tab] / [Shift+Tab] to traverse fields. Press [Enter] to submit & validate.',
          style: const Style(foreground: CharmColors.squid),
        ),
      ),
      const SizedBox(height: 1, child: Text('')),
      Expanded(child: formDemo),
    ]);
  }

  @override
  bool handleKeyEvent(ui.KeyEvent event) {
    if (event.type == ui.KeyType.enter) {
      if (formDemo.activeFieldIndex == formDemo.fields.length - 1) {
        formDemo.validate();
        return true;
      }
    }

    formDemo.handleKeyEvent(event);
    return true; // Consume all keys to prevent focus escaping via Tab/Shift-Tab
  }
}
