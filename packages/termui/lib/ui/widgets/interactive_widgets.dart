import '../buffer.dart';
import '../layout.dart';
import '../style.dart';
import '../event.dart' hide Modifier;
import '../../terminal/terminal.dart' as term;
import 'prompt_runner.dart';

/// An interactive TUI button widget that triggers a callback when activated.
///
/// ### Interfaces
/// - **Keyboard**: When [focused] is true, pressing Space (`' '`), Enter
///   (`'\n'`), or Carriage Return (`'\r'`) will trigger [onPressed].
/// - **Mouse**: Left-clicking (mouse press event) inside the bounds of the
///   button triggers [onPressed].
///
/// ### Example Usage
///
/// ```dart
/// Button(
///   text: 'Submit',
///   focused: true,
///   onPressed: () {
///     print('Button clicked!');
///   },
/// );
/// ```
///
/// ### Properties and Styling
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `text` | [String] | Label displayed on the button. |
/// | `onPressed` | `void Function()` | Callback executed when activated. |
/// | `focused` | [bool] | Whether this button currently has keyboard focus. |
/// | `style` | [Style] | Normal rendering style. |
/// | `focusedStyle` | [Style] | Rendering style applied when [focused] is true. |
class Button extends Widget implements Focusable, KeyEventHandler {
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
  const Button({
    required this.text,
    required this.onPressed,
    this.focused = false,
    this.style = Style.empty,
    this.focusedStyle = const Style(modifiers: Modifier.reverse),
  });

  @override
  void render(Buffer buffer, Rect area) {
    if (area.width <= 0 || area.height <= 0) return;
    final label = focused ? '[ $text ]' : '  $text  ';
    buffer.writeString(0, 0, label, focused ? focusedStyle : style);
  }

  /// Handles key activations (Space or Enter).
  @override
  bool handleKeyEvent(term.KeyEvent event) {
    if (focused &&
        (event.key == ' ' || event.key == '\n' || event.key == '\r')) {
      onPressed();
      return true;
    }
    return false;
  }

  /// Handles mouse clicks.
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    if (event.type == MouseEventType.press) {
      onPressed();
    }
  }
}

/// An interactive checkbox widget for toggling boolean flags.
///
/// ### Interfaces
/// - **Keyboard**: When [focused] is true, pressing Space (`' '`), Enter
///   (`'\n'`), or Carriage Return (`'\r'`) toggles [value] and triggers [onChanged].
/// - **Mouse**: Left-clicking inside bounds toggles [value] and triggers [onChanged].
///
/// ### Example Usage
///
/// ```dart
/// Checkbox(
///   value: isAgreed,
///   label: 'I agree to the terms',
///   onChanged: (val) {
///     setState(() => isAgreed = val);
///   },
/// );
/// ```
///
/// ### Properties and Styling
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `value` | [bool] | Current check state (checked if true). |
/// | `label` | [String] | Descriptive text label next to the checkbox. |
/// | `onChanged` | `Function(bool)` | Callback triggered when state toggles. |
/// | `focused` | [bool] | Whether the widget has keyboard focus. |
/// | `style` | [Style] | Normal rendering style. |
/// | `focusedStyle` | [Style] | Style applied when [focused] is true. |
class Checkbox extends Widget implements Focusable, KeyEventHandler {
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
  const Checkbox({
    required this.value,
    required this.label,
    required this.onChanged,
    this.focused = false,
    this.style = Style.empty,
    this.focusedStyle = const Style(modifiers: Modifier.reverse),
  });

  @override
  void render(Buffer buffer, Rect area) {
    if (area.width <= 0 || area.height <= 0) return;
    final box = value ? '[X]' : '[ ]';
    buffer.writeString(0, 0, '$box $label', focused ? focusedStyle : style);
  }

  /// Handles key activations (Space or Enter).
  @override
  bool handleKeyEvent(term.KeyEvent event) {
    if (focused &&
        (event.key == ' ' || event.key == '\n' || event.key == '\r')) {
      onChanged(!value);
      return true;
    }
    return false;
  }

  /// Handles mouse clicks.
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    if (event.type == MouseEventType.press) {
      onChanged(!value);
    }
  }
}

/// An interactive radio button widget to select a single value from a group.
///
/// ### Interfaces
/// - **Keyboard**: When [focused] is true, pressing Space (`' '`), Enter
///   (`'\n'`), or Carriage Return (`'\r'`) selects [value] and triggers [onChanged].
/// - **Mouse**: Left-clicking inside bounds selects [value] and triggers [onChanged].
///
/// ### Example Usage
///
/// ```dart
/// Radio<ThemeMode>(
///   value: ThemeMode.dark,
///   groupValue: activeTheme,
///   label: 'Dark Mode',
///   onChanged: (ThemeMode val) {
///     setState(() => activeTheme = val);
///   },
/// );
/// ```
///
/// ### Properties and Styling
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `value` | `T` | The specific value represented by this radio button. |
/// | `groupValue` | `T` | The currently selected value of the radio group. |
/// | `label` | [String] | Descriptive label text next to the radio circle. |
/// | `onChanged` | `Function(T)` | Callback triggered when this option is selected. |
/// | `focused` | [bool] | Whether the widget has keyboard focus. |
/// | `style` | [Style] | Normal rendering style. |
/// | `focusedStyle` | [Style] | Style applied when [focused] is true. |
class Radio<T> extends Widget implements Focusable, KeyEventHandler {
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
  const Radio({
    required this.value,
    required this.groupValue,
    required this.label,
    required this.onChanged,
    this.focused = false,
    this.style = Style.empty,
    this.focusedStyle = const Style(modifiers: Modifier.reverse),
  });

  /// Whether this radio button is currently selected.
  bool get isSelected => value == groupValue;

  @override
  void render(Buffer buffer, Rect area) {
    if (area.width <= 0 || area.height <= 0) return;
    final marker = isSelected ? '(*)' : '( )';
    buffer.writeString(0, 0, '$marker $label', focused ? focusedStyle : style);
  }

  /// Handles key activations (Space or Enter).
  @override
  bool handleKeyEvent(term.KeyEvent event) {
    if (focused &&
        (event.key == ' ' || event.key == '\n' || event.key == '\r')) {
      onChanged(value);
      return true;
    }
    return false;
  }

  /// Handles mouse clicks.
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    if (event.type == MouseEventType.press) {
      onChanged(value);
    }
  }
}

/// An interactive visual switch toggle widget representing true/false state.
///
/// ### Interfaces
/// - **Keyboard**: When [focused] is true, pressing Space (`' '`), Enter
///   (`'\n'`), or Carriage Return (`'\r'`) toggles [value] and triggers [onChanged].
/// - **Mouse**: Left-clicking inside bounds toggles [value] and triggers [onChanged].
///
/// ### Example Usage
///
/// ```dart
/// Switch(
///   value: isNotificationsEnabled,
///   label: 'Enable Notifications',
///   onChanged: (val) {
///     setState(() => isNotificationsEnabled = val);
///   },
/// );
/// ```
///
/// ### Properties and Styling
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `value` | [bool] | The switch toggle state (on/off). |
/// | `label` | [String] | The text label accompanying the switch. |
/// | `onChanged` | `Function(bool)` | Callback triggered when the state changes. |
/// | `focused` | [bool] | Whether this switch has focus. |
/// | `style` | [Style] | Normal rendering style. |
/// | `focusedStyle` | [Style] | Style applied when [focused] is true. |
class Switch extends Widget implements Focusable, KeyEventHandler {
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
  const Switch({
    required this.value,
    required this.label,
    required this.onChanged,
    this.focused = false,
    this.style = Style.empty,
    this.focusedStyle = const Style(modifiers: Modifier.reverse),
  });

  @override
  void render(Buffer buffer, Rect area) {
    if (area.width <= 0 || area.height <= 0) return;
    final marker = value ? '[─●]' : '[○─]';
    buffer.writeString(0, 0, '$marker $label', focused ? focusedStyle : style);
  }

  /// Handles key activations (Space or Enter).
  @override
  bool handleKeyEvent(term.KeyEvent event) {
    if (focused &&
        (event.key == ' ' || event.key == '\n' || event.key == '\r')) {
      onChanged(!value);
      return true;
    }
    return false;
  }

  /// Handles mouse clicks.
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    if (event.type == MouseEventType.press) {
      onChanged(!value);
    }
  }
}
