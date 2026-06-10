import 'package:termui/termui.dart';

/// A widget that displays a value as a linear or semi-circular meter.
class Gauge extends Widget {
  /// The current value to display.
  final double value;

  /// The minimum value.
  final double min;

  /// The maximum value.
  final double max;

  /// A list of color thresholds.
  /// For example, `[(0.0, Colors.green), (0.5, Colors.orange), (0.8, Colors.red)]`.
  final List<(double, Color)> thresholds;

  /// Creates a gauge widget.
  Gauge({
    required this.value,
    required this.min,
    required this.max,
    required this.thresholds,
  });

  @override
  void render(Buffer buffer, Rect area) {
    if (area.width <= 0) return;

    final percent = ((value - min) / (max - min)).clamp(0.0, 1.0);
    final width = area.width;
    final needlePos = (percent * (width - 1)).round();

    for (int i = 0; i < width; i++) {
      final posPercent = i / (width - 1 > 0 ? width - 1 : 1);

      Color activeColor = thresholds.isNotEmpty
          ? thresholds.first.$2
          : Colors.white;
      for (final threshold in thresholds) {
        if (posPercent >= threshold.$1) {
          activeColor = threshold.$2;
        }
      }

      final style = Style(foreground: activeColor);

      if (i == needlePos) {
        if (area.height > 1) {
          buffer.writeString(
            i,
            0,
            '▼',
            style.merge(const Style(modifiers: Modifier.bold)),
          );
          buffer.writeString(i, 1, '█', style);
        } else {
          buffer.writeString(i, 0, '█', style);
        }
      } else {
        if (area.height > 1) {
          buffer.writeString(i, 1, '▒', style);
        } else {
          buffer.writeString(i, 0, '▒', style);
        }
      }
    }
  }
}
