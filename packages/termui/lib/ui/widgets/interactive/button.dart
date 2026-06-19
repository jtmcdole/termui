import 'dart:async';
import 'package:characters/characters.dart';
import 'package:termui/termui.dart';
import 'package:termui/terminal/terminal.dart' as term;

/// Undocumented public member.
class Button extends StatefulWidget
    implements Focusable, KeyEventHandler, MouseEventHandler {
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

  // ignore: must_be_immutable
  ButtonState? _state;

  @override
  bool handleKeyEvent(term.KeyEvent event) {
    final hasFocus = focused || (_state?._focusNode.hasFocus ?? false);
    if (hasFocus &&
        (event.key == ' ' ||
            event.key == 'space' ||
            event.key == '\n' ||
            event.key == '\r' ||
            event.key == 'enter' ||
            event.type == term.KeyType.enter)) {
      onPressed();
      _state?.setState(() {});
      return true;
    }
    return false;
  }

  /// Delegated mouse event handler.
  @override
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    if (event.type == MouseEventType.press) {
      onPressed();
      _state?.setState(() {});
    }
  }

  @override
  State<Button> createState() {
    final state = ButtonState();
    _state = state;
    return state;
  }
}

/// Undocumented public member.
class ButtonState extends State<Button>
    implements KeyEventHandler, MouseEventHandler {
  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    widget._state = this;
    _focusNode = FocusNode(id: 'button_${widget.hashCode}');
    if (widget.focused) {
      scheduleMicrotask(() {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(Button oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget._state = this;
    if (widget.focused != oldWidget.focused) {
      if (widget.focused) {
        _focusNode.requestFocus();
      } else {
        _focusNode.unfocus();
      }
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  /// Handles mouse events for the button.
  @override
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    widget.handleMouseEvent(event, localX, localY);
  }

  @override
  bool handleKeyEvent(term.KeyEvent event) {
    return widget.handleKeyEvent(event);
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      onFocusChange: (hasFocus) {
        if (mounted) setState(() {});
      },
      onKeyEvent: (event) {
        return handleKeyEvent(event);
      },
      child: _ButtonRenderWidget(
        text: widget.text,
        focused: _focusNode.hasFocus || widget.focused,
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
