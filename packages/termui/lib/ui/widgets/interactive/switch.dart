import 'dart:async';
import 'package:characters/characters.dart';
import 'package:termui/termui.dart';
import 'package:termui/terminal/terminal.dart' as term;

/// Undocumented public member.
class Switch extends StatefulWidget
    implements Focusable, KeyEventHandler, MouseEventHandler {
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

  // ignore: must_be_immutable
  SwitchState? _state;

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
      onChanged(!value);
      _state?.setState(() {});
      return true;
    }
    return false;
  }

  /// Delegated mouse event handler.
  @override
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    if (event.type == MouseEventType.press) {
      onChanged(!value);
      _state?.setState(() {});
    }
  }

  @override
  State<Switch> createState() {
    final state = SwitchState();
    _state = state;
    return state;
  }
}

/// Undocumented public member.
class SwitchState extends State<Switch>
    implements KeyEventHandler, MouseEventHandler {
  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    widget._state = this;
    _focusNode = FocusNode(id: 'switch_${widget.hashCode}');
    if (widget.focused) {
      scheduleMicrotask(() {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(Switch oldWidget) {
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

  /// Handles mouse events for the switch.
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
      child: _SwitchRenderWidget(
        value: widget.value,
        label: widget.label,
        focused: _focusNode.hasFocus || widget.focused,
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
