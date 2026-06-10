import 'package:characters/characters.dart';
import '../buffer.dart';
import '../style.dart';
import '../layout.dart';
import '../event.dart' hide Modifier;

/// A widget for selecting a numeric value using '<' and '>' buttons.
class NumberSelector extends Widget {
  /// The text label displayed before the selector.
  final String label;

  /// The currently selected numeric value.
  int value;

  /// The minimum allowable value.
  final int min;

  /// The maximum allowable value.
  final int max;

  /// The text style applied to the label and value.
  final Style style;

  /// The text style applied to the '<' and '>' increment buttons.
  final Style buttonStyle;

  /// Callback fired when the [value] changes.
  final void Function(int value)? onChanged;

  /// Creates a [NumberSelector] widget.
  NumberSelector({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    this.style = Style.empty,
    this.buttonStyle = const Style(modifiers: Modifier.bold),
    this.onChanged,
  });

  /// Increases the selected [value] by 1, up to [max].
  void increment() {
    if (value < max) {
      value++;
      onChanged?.call(value);
    }
  }

  /// Decreases the selected [value] by 1, down to [min].
  void decrement() {
    if (value > min) {
      value--;
      onChanged?.call(value);
    }
  }

  /// Interprets mouse interactions to increment or decrement the selector.
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    if (event.type != MouseEventType.press) return;
    if (localY != 0) return;

    final labelLen = label.characters.length;
    final displayChars = '$label: < $value >'.characters;
    final leftArrowIdx = labelLen + 2;
    final rightArrowIdx = displayChars.length - 1;

    if (localX == leftArrowIdx) {
      decrement();
    } else if (localX == rightArrowIdx) {
      increment();
    }
  }

  @override
  void render(Buffer buffer, Rect area) {
    final labelLen = label.characters.length;
    final displayChars = '$label: < $value >'.characters;
    final leftArrowIdx = labelLen + 2;
    final rightArrowIdx = displayChars.length - 1;

    // Render the label and spacing
    buffer.writeString(0, 0, '$label: ', style);

    // Render '<' button
    buffer.writeString(leftArrowIdx, 0, '<', buttonStyle);

    // Render value
    buffer.writeString(leftArrowIdx + 2, 0, '$value', style);

    // Render '>' button
    buffer.writeString(rightArrowIdx, 0, '>', buttonStyle);
  }
}
