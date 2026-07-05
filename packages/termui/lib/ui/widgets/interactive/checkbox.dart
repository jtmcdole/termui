import 'package:characters/characters.dart';
import 'package:termui/termui.dart';
import 'package:termui/terminal/terminal.dart' as term;

/// Undocumented public member.
class Checkbox extends StatefulWidget implements Focusable {
  /// The current check state (checked if true).
  final bool value;

  /// The descriptive text label next to the checkbox.
  final String label;

  /// The callback triggered when the state toggles.
  final void Function(bool newValue) onChanged;

  /// Whether the widget has keyboard focus.
  @override
  final bool focused;

  /// The normal rendering style.
  final Style style;

  /// The rendering style applied when the checkbox is focused.
  final Style focusedStyle;

  /// Creates a new [Checkbox].
  Checkbox({
    super.key,
    required this.value,
    required this.label,
    required this.onChanged,
    this.focused = false,
    this.style = Style.empty,
    this.focusedStyle = const Style(modifiers: Modifier.reverse),
  });

  @override
  State<Checkbox> createState() {
    return CheckboxState();
  }
}

/// Undocumented public member.
class CheckboxState extends State<Checkbox>
    with FocusableStateMixin<Checkbox>
    implements KeyEventHandler, MouseEventHandler {
  @override
  bool get isWidgetFocused => widget.focused;

  @override
  String get focusNodeIdPrefix => 'checkbox';

  /// Handles mouse events for the checkbox.
  @override
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    if (event.type == MouseEventType.press) {
      widget.onChanged(!widget.value);
      setState(() {});
    }
  }

  @override
  bool handleKeyEvent(term.KeyEvent event) {
    final hasFocus = widget.focused || focusNode.hasFocus;
    if (hasFocus &&
        (event.baseKey == term.TermKey.space ||
            event.baseKey == term.TermKey.enter)) {
      widget.onChanged(!widget.value);
      setState(() {});
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      onFocusChange: (hasFocus) {
        if (mounted) setState(() {});
      },
      onKeyEvent: (event) {
        return handleKeyEvent(event);
      },
      child: _CheckboxRenderWidget(
        value: widget.value,
        label: widget.label,
        focused: focusNode.hasFocus || widget.focused,
        style: widget.style,
        focusedStyle: widget.focusedStyle,
      ),
    );
  }
}

class _CheckboxRenderWidget extends Widget {
  final bool value;
  final String label;
  final bool focused;
  final Style style;
  final Style focusedStyle;

  const _CheckboxRenderWidget({
    required this.value,
    required this.label,
    required this.focused,
    required this.style,
    required this.focusedStyle,
  });

  @override
  Element createElement() => _CheckboxElement(this);
}

class _CheckboxElement extends Element {
  _CheckboxElement(_CheckboxRenderWidget super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final wWidget = widget as _CheckboxRenderWidget;
    final box = wWidget.value ? '[X]' : '[ ]';
    final label = '$box ${wWidget.label}';
    return constraints.constrain(Size(label.characters.length, 1));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final wWidget = widget as _CheckboxRenderWidget;
    final box = wWidget.value ? '[X]' : '[ ]';
    final label = '$box ${wWidget.label}';
    buffer.writeString(
      offset.dx,
      offset.dy,
      label,
      wWidget.focused ? wWidget.focusedStyle : wWidget.style,
    );
  }
}
