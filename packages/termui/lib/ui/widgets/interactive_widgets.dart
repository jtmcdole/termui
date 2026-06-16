import 'dart:async';
import '../buffer.dart';
import '../layout.dart';
import '../style.dart';
import '../event.dart' hide Modifier;
import '../../terminal/terminal.dart' as term;
import 'prompt_runner.dart';
import 'focus.dart';
import '../window.dart';
import 'package:characters/characters.dart';

/// An interactive TUI button widget that triggers a callback when activated.
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

/// The state for a [Button] widget.
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
  void paint(Buffer buffer, Offset offset) {
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

/// An interactive checkbox widget supporting toggled true/false options.
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

/// The state for a [Checkbox] widget.
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
  void paint(Buffer buffer, Offset offset) {
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

/// An interactive radio button widget to select a single value from a group.
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

/// The state for a [Radio] widget.
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
  void paint(Buffer buffer, Offset offset) {
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

/// An interactive visual switch toggle widget representing true/false state.
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

/// The state for a [Switch] widget.
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
  void paint(Buffer buffer, Offset offset) {
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
