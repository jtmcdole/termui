import 'dart:async';
import 'package:characters/characters.dart';
import 'package:termui/termui.dart';
import 'package:termui/terminal/terminal.dart' as term;

/// Undocumented public member.
class Radio<T> extends StatefulWidget
    implements Focusable, KeyEventHandler, MouseEventHandler {
  /// The specific value represented by this radio button.
  final T value;

  /// The currently selected value of the radio group.
  final T groupValue;

  /// The descriptive label text next to the radio circle.
  final String label;

  /// The callback triggered when this option is selected.
  final void Function(T newValue) onChanged;

  /// Whether the widget has keyboard focus.
  @override
  final bool focused;

  /// The normal rendering style.
  final Style style;

  /// The rendering style applied when the radio button is focused.
  final Style focusedStyle;

  /// Creates a new [Radio].
  Radio({
    super.key,
    required this.value,
    required this.groupValue,
    required this.label,
    required this.onChanged,
    this.focused = false,
    this.style = Style.empty,
    this.focusedStyle = const Style(modifiers: Modifier.reverse),
  });

  // ignore: must_be_immutable
  RadioState<T>? _state;

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
      onChanged(value);
      _state?.setState(() {});
      return true;
    }
    return false;
  }

  /// Delegated mouse event handler.
  @override
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    if (event.type == MouseEventType.press) {
      onChanged(value);
      _state?.setState(() {});
    }
  }

  @override
  State<Radio<T>> createState() {
    final state = RadioState<T>();
    _state = state;
    return state;
  }
}

/// Undocumented public member.
class RadioState<T> extends State<Radio<T>>
    implements KeyEventHandler, MouseEventHandler {
  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    widget._state = this;
    _focusNode = FocusNode(id: 'radio_${widget.hashCode}');
    if (widget.focused) {
      scheduleMicrotask(() {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(Radio<T> oldWidget) {
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

  /// Whether this radio button is currently selected.
  bool get isSelected => widget.value == widget.groupValue;

  /// Handles mouse events for the radio button.
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
      child: _RadioRenderWidget(
        isSelected: isSelected,
        label: widget.label,
        focused: _focusNode.hasFocus || widget.focused,
        style: widget.style,
        focusedStyle: widget.focusedStyle,
      ),
    );
  }
}

class _RadioRenderWidget extends Widget {
  final bool isSelected;
  final String label;
  final bool focused;
  final Style style;
  final Style focusedStyle;

  const _RadioRenderWidget({
    required this.isSelected,
    required this.label,
    required this.focused,
    required this.style,
    required this.focusedStyle,
  });

  @override
  Element createElement() => _RadioElement(this);
}

class _RadioElement extends Element {
  _RadioElement(_RadioRenderWidget super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final wWidget = widget as _RadioRenderWidget;
    final marker = wWidget.isSelected ? '(*)' : '( )';
    final label = '$marker ${wWidget.label}';
    return constraints.constrain(Size(label.characters.length, 1));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final wWidget = widget as _RadioRenderWidget;
    final marker = wWidget.isSelected ? '(*)' : '( )';
    final label = '$marker ${wWidget.label}';
    buffer.writeString(
      offset.dx,
      offset.dy,
      label,
      wWidget.focused ? wWidget.focusedStyle : wWidget.style,
    );
  }
}
