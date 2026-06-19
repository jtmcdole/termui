import 'package:characters/characters.dart';
import 'package:termui/termui.dart';
import 'package:termui/terminal/terminal.dart' as term;

/// Undocumented public member.
class Button extends StatefulWidget implements Focusable {
  /// The text label displayed on the button.
  final String text;

  /// The callback executed when the button is activated.
  final void Function() onPressed;

  /// Whether this button currently has keyboard focus.
  @override
  final bool focused;

  /// The normal rendering style.
  final Style style;

  /// The rendering style applied when the button is focused.
  final Style focusedStyle;

  /// Creates a new [Button].
  Button({
    super.key,
    required this.text,
    required this.onPressed,
    this.focused = false,
    this.style = Style.empty,
    this.focusedStyle = const Style(modifiers: Modifier.reverse),
  });

  @override
  State<Button> createState() {
    return ButtonState();
  }
}

/// Undocumented public member.
class ButtonState extends State<Button>
    with FocusableStateMixin<Button>
    implements KeyEventHandler, MouseEventHandler {
  @override
  bool get isWidgetFocused => widget.focused;

  @override
  String get focusNodeIdPrefix => 'button';

  /// Handles mouse events for the button.
  @override
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    if (event.type == MouseEventType.press) {
      widget.onPressed();
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
      widget.onPressed();
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
      child: _ButtonRenderWidget(
        text: widget.text,
        focused: focusNode.hasFocus || widget.focused,
        style: widget.style,
        focusedStyle: widget.focusedStyle,
      ),
    );
  }
}

class _ButtonRenderWidget extends Widget {
  final String text;
  final bool focused;
  final Style style;
  final Style focusedStyle;

  const _ButtonRenderWidget({
    required this.text,
    required this.focused,
    required this.style,
    required this.focusedStyle,
  });

  @override
  Element createElement() => _ButtonElement(this);
}

class _ButtonElement extends Element {
  _ButtonElement(_ButtonRenderWidget super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final wWidget = widget as _ButtonRenderWidget;
    final label = wWidget.focused
        ? '[ ${wWidget.text} ]'
        : '  ${wWidget.text}  ';
    return constraints.constrain(Size(label.characters.length, 1));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final wWidget = widget as _ButtonRenderWidget;
    final label = wWidget.focused
        ? '[ ${wWidget.text} ]'
        : '  ${wWidget.text}  ';
    buffer.writeString(
      offset.dx,
      offset.dy,
      label,
      wWidget.focused ? wWidget.focusedStyle : wWidget.style,
    );
  }
}
