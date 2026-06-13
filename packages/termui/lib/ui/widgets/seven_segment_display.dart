import '../buffer.dart';
import '../color.dart';
import '../layout.dart';
import '../style.dart';

/// A widget that displays a multi-line segmented numerical readout.
class SevenSegmentDisplay extends Widget {
  /// The value to display (can be numbers or some characters).
  final String value;

  /// The color of the active segments.
  final Color activeColor;

  /// The color of the inactive segments.
  final Color inactiveColor;

  /// Creates a seven segment display.
  SevenSegmentDisplay({
    required this.value,
    this.activeColor = Colors.green,
    this.inactiveColor = const Color(30, 30, 30),
  });

  // A 5x5 block mapping for digits 0-9
  // 1 is active, 0 is inactive
  static const Map<String, List<List<int>>> _digits = {
    '0': [
      [1, 1, 1, 1, 1],
      [1, 0, 0, 0, 1],
      [1, 0, 0, 0, 1],
      [1, 0, 0, 0, 1],
      [1, 1, 1, 1, 1],
    ],
    '1': [
      [0, 0, 0, 0, 1],
      [0, 0, 0, 0, 1],
      [0, 0, 0, 0, 1],
      [0, 0, 0, 0, 1],
      [0, 0, 0, 0, 1],
    ],
    '2': [
      [1, 1, 1, 1, 1],
      [0, 0, 0, 0, 1],
      [1, 1, 1, 1, 1],
      [1, 0, 0, 0, 0],
      [1, 1, 1, 1, 1],
    ],
    '3': [
      [1, 1, 1, 1, 1],
      [0, 0, 0, 0, 1],
      [1, 1, 1, 1, 1],
      [0, 0, 0, 0, 1],
      [1, 1, 1, 1, 1],
    ],
    '4': [
      [1, 0, 0, 0, 1],
      [1, 0, 0, 0, 1],
      [1, 1, 1, 1, 1],
      [0, 0, 0, 0, 1],
      [0, 0, 0, 0, 1],
    ],
    '5': [
      [1, 1, 1, 1, 1],
      [1, 0, 0, 0, 0],
      [1, 1, 1, 1, 1],
      [0, 0, 0, 0, 1],
      [1, 1, 1, 1, 1],
    ],
    '6': [
      [1, 1, 1, 1, 1],
      [1, 0, 0, 0, 0],
      [1, 1, 1, 1, 1],
      [1, 0, 0, 0, 1],
      [1, 1, 1, 1, 1],
    ],
    '7': [
      [1, 1, 1, 1, 1],
      [0, 0, 0, 0, 1],
      [0, 0, 0, 0, 1],
      [0, 0, 0, 0, 1],
      [0, 0, 0, 0, 1],
    ],
    '8': [
      [1, 1, 1, 1, 1],
      [1, 0, 0, 0, 1],
      [1, 1, 1, 1, 1],
      [1, 0, 0, 0, 1],
      [1, 1, 1, 1, 1],
    ],
    '9': [
      [1, 1, 1, 1, 1],
      [1, 0, 0, 0, 1],
      [1, 1, 1, 1, 1],
      [0, 0, 0, 0, 1],
      [1, 1, 1, 1, 1],
    ],
    '-': [
      [0, 0, 0, 0, 0],
      [0, 0, 0, 0, 0],
      [1, 1, 1, 1, 1],
      [0, 0, 0, 0, 0],
      [0, 0, 0, 0, 0],
    ],
    ' ': [
      [0, 0, 0, 0, 0],
      [0, 0, 0, 0, 0],
      [0, 0, 0, 0, 0],
      [0, 0, 0, 0, 0],
      [0, 0, 0, 0, 0],
    ],
  };

  @override
  Element createElement() => SevenSegmentDisplayElement(this);
}

/// An element that manages the rendering and layout of a [SevenSegmentDisplay] widget.
class SevenSegmentDisplayElement extends Element {
  /// Creates a [SevenSegmentDisplayElement] for the given [widget].
  SevenSegmentDisplayElement(SevenSegmentDisplay super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final display = widget as SevenSegmentDisplay;
    final count = display.value.length;
    final w = count > 0 ? (count * 6 - 1) : 0;
    return constraints.constrain(Size(w, 5));
  }

  @override
  void paint(Buffer buffer, Offset offset) {
    final viewport = Viewport(
      buffer,
      Rect(offset.dx, offset.dy, size.width, size.height),
    );
    final display = widget as SevenSegmentDisplay;
    if (size.width <= 0 || size.height < 5) return;

    final activeSt = Style(foreground: display.activeColor);
    final inactiveSt = Style(foreground: display.inactiveColor);

    int offsetX = 0;
    for (int i = 0; i < display.value.length; i++) {
      final char = display.value[i];
      final matrix =
          SevenSegmentDisplay._digits[char] ?? SevenSegmentDisplay._digits[' '];

      if (matrix != null) {
        for (int y = 0; y < 5; y++) {
          for (int x = 0; x < 5; x++) {
            if (offsetX + x < size.width && y < size.height) {
              final active = matrix[y][x] == 1;
              viewport.writeString(
                offsetX + x,
                y,
                '█',
                active ? activeSt : inactiveSt,
              );
            }
          }
        }
        offsetX += 6; // 5 width + 1 spacing
      }
    }
  }
}
