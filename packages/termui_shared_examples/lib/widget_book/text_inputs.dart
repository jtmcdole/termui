import 'package:termui/ui/layout.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/widget_toolkit.dart';
import 'package:termui/ui/event.dart' as ui;
import 'example_base.dart';

import 'package:termui/ui/window.dart';

/// An example showcasing single-line and multi-line text input fields.
class TextInputsExample extends WidgetBookExample {
  /// The single-line text field controller.
  late final TextEditingController singleLineController =
      TextEditingController();

  /// The multi-line text field controller.
  late final TextEditingController multiLineController = TextEditingController(
    text:
        'Multi-line TextField editor.\nPress [Tab] to cycle focus.\nUse arrows to navigate.',
  );

  /// Key to find/access the stateful widget's state.
  final GlobalKey<TextInputsDemoWidgetState> _key = GlobalKey();

  @override
  Widget build({
    required bool focusDemoPane,
    required int width,
    required int height,
  }) {
    return TextInputsDemoWidget(
      key: _key,
      singleLineController: singleLineController,
      multiLineController: multiLineController,
      focusDemoPane: focusDemoPane,
    );
  }

  @override
  bool handleKeyEvent(ui.KeyEvent event) {
    return false;
  }

  @override
  Map<String, String> get helpBindings => {
    'Tab': 'Toggle Input',
    'Arrows/Keys': 'Edit active input',
  };
}

/// Stateful widget to manage index focus and field states.
class TextInputsDemoWidget extends StatefulWidget {
  /// The single-line controller.
  final TextEditingController singleLineController;

  /// The multi-line controller.
  final TextEditingController multiLineController;

  /// Whether the parent demo pane has focus.
  final bool focusDemoPane;

  /// Creates a new [TextInputsDemoWidget].
  const TextInputsDemoWidget({
    super.key,
    required this.singleLineController,
    required this.multiLineController,
    required this.focusDemoPane,
  });

  @override
  State<TextInputsDemoWidget> createState() => TextInputsDemoWidgetState();
}

/// The state for [TextInputsDemoWidget].
class TextInputsDemoWidgetState extends State<TextInputsDemoWidget> {
  late final FocusNode _singleLineFocusNode = FocusNode(
    id: 'single_line_input',
  );
  late final FocusNode _multiLineFocusNode = FocusNode(id: 'multi_line_input');

  @override
  void dispose() {
    _singleLineFocusNode.dispose();
    _multiLineFocusNode.dispose();
    super.dispose();
  }

  /// Helper to build the single-line text field widget.
  TextField _buildSingleLineField(bool active) {
    return TextField(
      controller: widget.singleLineController,
      focusNode: _singleLineFocusNode,
      onFocusChange: (hasFocus) {
        if (mounted) setState(() {});
      },
      placeholder: 'Enter text here...',
      style: active
          ? const Style(foreground: CharmColors.charple)
          : const Style(foreground: CharmColors.soda),
      cursorStyle: active
          ? const Style(
              foreground: CharmColors.pepper,
              background: CharmColors.charple,
              modifiers: Modifier.reverse,
            )
          : const Style(modifiers: Modifier.none),
      multiline: false,
      focused: active,
    );
  }

  /// Helper to build the multi-line text field widget.
  TextField _buildMultiLineField(bool active) {
    return TextField(
      controller: widget.multiLineController,
      focusNode: _multiLineFocusNode,
      onFocusChange: (hasFocus) {
        if (mounted) setState(() {});
      },
      style: active
          ? const Style(foreground: CharmColors.charple)
          : const Style(foreground: CharmColors.soda),
      cursorStyle: active
          ? const Style(
              foreground: CharmColors.pepper,
              background: CharmColors.charple,
              modifiers: Modifier.reverse,
            )
          : const Style(modifiers: Modifier.none),
      placeholder: 'Type multi-line text...',
      multiline: true,
      focused: active,
    );
  }

  @override
  Widget build(BuildContext context) {
    final singleLineActive =
        widget.focusDemoPane && _singleLineFocusNode.hasFocus;
    final multiLineActive =
        widget.focusDemoPane && _multiLineFocusNode.hasFocus;

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
}
