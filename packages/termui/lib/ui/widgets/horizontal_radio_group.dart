import 'package:characters/characters.dart';
import '../color.dart';
import '../event.dart' hide Modifier;
import '../layout.dart';
import '../style.dart';
import 'text.dart';
import 'selection_controller.dart';

/// A horizontal group of radio-like choices.
class HorizontalRadioGroup extends StatefulWidget {
  /// The controller managing the selection state and options.
  final SelectionController<String> controller;

  /// Whether this group has active keyboard focus.
  final bool focused;

  /// Creates a [HorizontalRadioGroup].
  const HorizontalRadioGroup({
    super.key,
    required this.controller,
    this.focused = false,
  });

  @override
  State<HorizontalRadioGroup> createState() => HorizontalRadioGroupState();
}

/// The state class for [HorizontalRadioGroup] managing selections and keyboard routing.
class HorizontalRadioGroupState extends State<HorizontalRadioGroup> {
  SelectionController<String>? _listenedController;

  void _onControllerChanged() {
    setState(() {});
  }

  void _updateListener() {
    if (_listenedController != widget.controller) {
      _listenedController?.removeListener(_onControllerChanged);
      _listenedController = widget.controller;
      _listenedController?.addListener(_onControllerChanged);
    }
  }

  @override
  void initState() {
    super.initState();
    _updateListener();
  }

  @override
  void dispose() {
    _listenedController?.removeListener(_onControllerChanged);
    super.dispose();
  }

  /// Handles option selection and navigation.
  void handleKeyEvent(KeyEvent event) {
    final controller = widget.controller;
    if (event.key == 'left' || event.key == 'h' || event.key == 'backtab') {
      setState(() {
        controller.focusedIndex =
            (controller.focusedIndex - 1) % controller.options.length;
        if (controller.focusedIndex < 0) {
          controller.focusedIndex += controller.options.length;
        }
      });
    } else if (event.key == 'right' || event.key == 'l' || event.key == 'tab') {
      setState(() {
        controller.focusedIndex =
            (controller.focusedIndex + 1) % controller.options.length;
      });
    } else if (event.key == ' ' ||
        event.key == 'space' ||
        event.key == 'enter' ||
        event.key == '\n' ||
        event.key == '\r') {
      setState(() {
        controller.selectedIndex = controller.focusedIndex;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    _updateListener();
    final optionWidgets = <Widget>[];
    final controller = widget.controller;
    for (var i = 0; i < controller.options.length; i++) {
      if (i > 0) {
        optionWidgets.add(const SizedBox(width: 4));
      }
      final option = controller.options[i];
      final isSelected = (controller.selectedIndex == i);
      final isFocused = widget.focused && (controller.focusedIndex == i);

      final box = isSelected ? '[X]' : '[ ]';
      final text = '$box $option';

      final style = isFocused
          ? const Style(modifiers: Modifier.reverse, foreground: Colors.yellow)
          : (isSelected
                ? const Style(
                    foreground: Colors.yellow,
                    modifiers: Modifier.bold,
                  )
                : const Style(foreground: Colors.white));

      optionWidgets.add(
        SizedBox(
          width: text.characters.length,
          child: Text(text, style: style),
        ),
      );
    }

    return Row(optionWidgets);
  }
}
