import '../buffer.dart';
import '../color.dart';
import '../event.dart' hide Modifier;
import '../layout.dart';
import '../style.dart';

/// The orientation of the slider.
enum SliderAxis {
  /// Horizontal slider.
  horizontal,

  /// Vertical slider.
  vertical,
}

/// A widget for selecting a numeric value by sliding a thumb along a track.
class Slider extends Widget {
  /// The current value.
  double value;

  /// The minimum value.
  final double min;

  /// The maximum value.
  final double max;

  /// The orientation of the slider.
  final SliderAxis axis;

  /// The style for the track.
  final Style trackStyle;

  /// The style for the thumb.
  final Style thumbStyle;

  /// The character used for the thumb.
  final String thumbChar;

  /// The character used for the track.
  final String trackChar;

  /// Callback when the value changes.
  final void Function(double value)? onChanged;

  /// Creates a slider.
  Slider({
    required this.value,
    required this.min,
    required this.max,
    this.axis = SliderAxis.horizontal,
    this.trackStyle = const Style(foreground: CharmColors.iron),
    this.thumbStyle = const Style(modifiers: Modifier.bold),
    this.thumbChar = '█',
    this.trackChar = '─',
    this.onChanged,
  });

  /// Handles mouse events for dragging the slider thumb.
  void handleMouseEvent(MouseEvent event, int localX, int localY, Rect area) {
    if (event.type != MouseEventType.press &&
        event.type != MouseEventType.drag) {
      return;
    }

    if (axis == SliderAxis.horizontal) {
      if (localY != 0) return;
      final trackLength = area.width;
      if (trackLength <= 1) return;

      final percent = (localX / (trackLength - 1)).clamp(0.0, 1.0);
      value = min + percent * (max - min);
      onChanged?.call(value);
    } else {
      if (localX != 0) return;
      final trackLength = area.height;
      if (trackLength <= 1) return;

      // For vertical slider, top (y=0) is max, bottom (y=height-1) is min
      final percent = 1.0 - (localY / (trackLength - 1)).clamp(0.0, 1.0);
      value = min + percent * (max - min);
      onChanged?.call(value);
    }
  }

  /// Handles keyboard events for moving the slider.
  void handleKeyEvent(KeyEvent event) {
    final step = (max - min) / 20.0; // 5% step size
    if (axis == SliderAxis.horizontal) {
      if (event.type == KeyType.left) {
        value = (value - step).clamp(min, max);
        onChanged?.call(value);
      } else if (event.type == KeyType.right) {
        value = (value + step).clamp(min, max);
        onChanged?.call(value);
      }
    } else {
      if (event.type == KeyType.up) {
        value = (value + step).clamp(min, max);
        onChanged?.call(value);
      } else if (event.type == KeyType.down) {
        value = (value - step).clamp(min, max);
        onChanged?.call(value);
      }
    }
  }

  @override
  void render(Buffer buffer, Rect area) {
    final percent = ((value - min) / (max - min)).clamp(0.0, 1.0);

    if (axis == SliderAxis.horizontal) {
      final trackLength = area.width;
      if (trackLength <= 0) return;
      final thumbPos = (percent * (trackLength - 1)).round();
      final tc = trackChar == '─' ? '─' : trackChar;

      for (int i = 0; i < trackLength; i++) {
        if (i == thumbPos) {
          buffer.writeString(i, 0, thumbChar, thumbStyle);
        } else {
          buffer.writeString(i, 0, tc, trackStyle);
        }
      }
    } else {
      final trackLength = area.height;
      if (trackLength <= 0) return;
      // In terminal, Y=0 is top. For vertical sliders, top is max.
      final thumbPos = trackLength - 1 - (percent * (trackLength - 1)).round();
      final tc = trackChar == '─' ? '│' : trackChar;

      for (int i = 0; i < trackLength; i++) {
        if (i == thumbPos) {
          buffer.writeString(0, i, thumbChar, thumbStyle);
        } else {
          buffer.writeString(0, i, tc, trackStyle);
        }
      }
    }
  }
}
