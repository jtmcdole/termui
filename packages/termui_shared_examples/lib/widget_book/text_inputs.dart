import 'package:termui/ui/layout.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/widget_toolkit.dart';
import 'package:termui/ui/event.dart' as ui;
import 'example_base.dart';

/// An example showcasing single-line and multi-line text input fields.
class TextInputsExample extends WidgetBookExample {
  /// The index of the currently active text field.
  int activeFieldIndex = 0;

  /// The single-line text field controller.
  late final TextEditingController singleLineController =
      TextEditingController();

  /// The multi-line text field controller.
  late final TextEditingController multiLineController = TextEditingController(
    text:
        'Multi-line TextField editor.\nPress [Tab] to cycle focus.\nUse arrows to navigate.',
  );

  /// Helper to build the single-line text field widget.
  TextField _buildSingleLineField(bool active) {
    return TextField(
      controller: singleLineController,
      placeholder: 'Enter text here...',
      style: active
          ? const Style(foreground: CharmColors.charple)
          : const Style(foreground: CharmColors.soda),
      cursorStyle: active
          ? const Style(
              foreground: CharmColors.pepper,
              background: CharmColors.charple,
            )
          : const Style(modifiers: Modifier.none),
      multiline: false,
      focused: active,
    );
  }

  /// Helper to build the multi-line text field widget.
  TextField _buildMultiLineField(bool active) {
    return TextField(
      controller: multiLineController,
      style: active
          ? const Style(foreground: CharmColors.charple)
          : const Style(foreground: CharmColors.soda),
      cursorStyle: active
          ? const Style(
              foreground: CharmColors.pepper,
              background: CharmColors.charple,
            )
          : const Style(modifiers: Modifier.none),
      placeholder: 'Type multi-line text...',
      multiline: true,
      focused: active,
    );
  }

  @override
  Widget build({
    required bool focusDemoPane,
    required int width,
    required int height,
  }) {
    final singleLineActive = focusDemoPane && activeFieldIndex == 0;
    final multiLineActive = focusDemoPane && activeFieldIndex == 1;

    final singleLineField = _buildSingleLineField(singleLineActive);
    final multiLineField = _buildMultiLineField(multiLineActive);

    return Column([
      SizedBox(
        height: 1,
        child: Text(
          singleLineActive
              ? '▶ Single-line TextField (focused):'
              : '  Single-line TextField:',
          style: singleLineActive
              ? const Style(
                  foreground: CharmColors.charple,
                  modifiers: Modifier.bold,
                )
              : const Style(foreground: CharmColors.soda),
        ),
      ),
      SizedBox(height: 1, child: singleLineField),
      const SizedBox(height: 1, child: Text('')),
      SizedBox(
        height: 1,
        child: Text(
          multiLineActive
              ? '▶ Multi-line TextField (focused):'
              : '  Multi-line TextField:',
          style: multiLineActive
              ? const Style(
                  foreground: CharmColors.charple,
                  modifiers: Modifier.bold,
                )
              : const Style(foreground: CharmColors.soda),
        ),
      ),
      Expanded(child: multiLineField),
    ]);
  }

  @override
  bool handleKeyEvent(ui.KeyEvent event) {
    if (event.key == '\t' || event.key == 'backtab') {
      if (event.key == 'backtab') {
        activeFieldIndex = (activeFieldIndex - 1 + 2) % 2;
      } else {
        activeFieldIndex = (activeFieldIndex + 1) % 2;
      }
      return true;
    }

    final singleLineField = _buildSingleLineField(activeFieldIndex == 0);
    final multiLineField = _buildMultiLineField(activeFieldIndex == 1);

    if (activeFieldIndex == 0) {
      if (event.type == ui.KeyType.down || event.type == ui.KeyType.enter) {
        activeFieldIndex = 1;
      } else {
        singleLineField.handleKeyEvent(event);
      }
    } else {
      if (event.type == ui.KeyType.up && multiLineField.cursorLine == 0) {
        activeFieldIndex = 0;
      } else {
        multiLineField.handleKeyEvent(event);
      }
    }
    return true;
  }

  @override
  Map<String, String> get helpBindings => {
    'Tab': 'Toggle Input',
    'Arrows/Keys': 'Edit active input',
  };
}
