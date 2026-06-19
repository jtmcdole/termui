import 'dart:async';
import 'package:characters/characters.dart';
import 'package:termui/termui.dart';
import 'package:termui/terminal/terminal.dart' as term;

/// Undocumented public member.
class Checkbox extends StatefulWidget
    implements Focusable, KeyEventHandler, MouseEventHandler {
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

  // ignore: must_be_immutable
  CheckboxState? _state;

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
  State<Checkbox> createState() {
    final state = CheckboxState();
    _state = state;
    return state;
  }
}

/// Undocumented public member.
class CheckboxState extends State<Checkbox>
    implements KeyEventHandler, MouseEventHandler {
  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    widget._state = this;
    _focusNode = FocusNode(id: 'checkbox_${widget.hashCode}');
    if (widget.focused) {
      scheduleMicrotask(() {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(Checkbox oldWidget) {
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

  /// Handles mouse events for the checkbox.
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
      child: _CheckboxRenderWidget(
        value: widget.value,
        label: widget.label,
        focused: _focusNode.hasFocus || widget.focused,
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
