import 'package:characters/characters.dart';
import 'package:termui/termui.dart';
import 'package:termui/terminal/terminal.dart' as term;

/// Undocumented public member.
class Switch extends StatefulWidget implements Focusable {
  /// The switch toggle state (on/off).
  final bool value;

  /// The text label accompanying the switch.
  final String label;

  /// The callback triggered when the state changes.
  final void Function(bool newValue) onChanged;

  /// Whether this switch has keyboard focus.
  @override
  final bool focused;

  /// The normal rendering style.
  final Style style;

  /// The rendering style applied when the switch is focused.
  final Style focusedStyle;

  /// Creates a new [Switch].
  Switch({
    super.key,
    required this.value,
    required this.label,
    required this.onChanged,
    this.focused = false,
    this.style = Style.empty,
    this.focusedStyle = const Style(modifiers: Modifier.reverse),
  });

  @override
  State<Switch> createState() {
    return SwitchState();
  }
}

/// Undocumented public member.
class SwitchState extends State<Switch>
    with FocusableStateMixin<Switch>
    implements KeyEventHandler, MouseEventHandler {
  @override
  bool get isWidgetFocused => widget.focused;

  @override
  String get focusNodeIdPrefix => 'switch';

  /// Handles mouse events for the switch.
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
        (event.key == ' ' ||
            event.key == 'space' ||
            event.key == '\n' ||
            event.key == '\r' ||
            event.key == 'enter' ||
            event.type == term.KeyType.enter)) {
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
      child: _SwitchRenderWidget(
        value: widget.value,
        label: widget.label,
        focused: focusNode.hasFocus || widget.focused,
        style: widget.style,
        focusedStyle: widget.focusedStyle,
      ),
    );
  }
}

class _SwitchRenderWidget extends Widget {
  final bool value;
  final String label;
  final bool focused;
  final Style style;
  final Style focusedStyle;

  const _SwitchRenderWidget({
    required this.value,
    required this.label,
    required this.focused,
    required this.style,
    required this.focusedStyle,
  });

  @override
  Element createElement() => _SwitchElement(this);
}

class _SwitchElement extends Element {
  _SwitchElement(_SwitchRenderWidget super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final wWidget = widget as _SwitchRenderWidget;
    final marker = wWidget.value ? '[─●]' : '[○─]';
    final label = '$marker ${wWidget.label}';
    return constraints.constrain(Size(label.characters.length, 1));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final wWidget = widget as _SwitchRenderWidget;
    final marker = wWidget.value ? '[─●]' : '[○─]';
    final label = '$marker ${wWidget.label}';
    buffer.writeString(
      offset.dx,
      offset.dy,
      label,
      wWidget.focused ? wWidget.focusedStyle : wWidget.style,
    );
  }
}
