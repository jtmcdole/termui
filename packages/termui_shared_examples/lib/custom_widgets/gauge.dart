import 'package:termui/termui.dart';

/// A widget that displays a value as a linear or semi-circular meter.
final class Gauge extends Widget {
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
  const Gauge({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.thresholds,
  });

  @override
  Element createElement() => _GaugeElement(this);
}

final class _GaugeElement extends Element {
  _GaugeElement(super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return Size(constraints.maxWidth, constraints.maxHeight);
  }

  @override
  void paint(Buffer buffer, Offset offset) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;
    final gauge = widget as Gauge;

    final percent = ((gauge.value - gauge.min) / (gauge.max - gauge.min)).clamp(
      0.0,
      1.0,
    );
    final needlePos = (percent * (w - 1)).round();

    for (int i = 0; i < w; i++) {
      final posPercent = i / (w - 1 > 0 ? w - 1 : 1);

      Color activeColor = gauge.thresholds.isNotEmpty
          ? gauge.thresholds.first.$2
          : Colors.white;
      for (final (thresholdPos, color) in gauge.thresholds) {
        if (posPercent >= thresholdPos) {
          activeColor = color;
        }
      }

      final style = Style(foreground: activeColor);

      if (i == needlePos) {
        if (h > 1) {
          buffer.writeString(
            offset.dx + i,
            offset.dy,
            '▼',
            style.merge(const Style(modifiers: Modifier.bold)),
          );
          buffer.writeString(offset.dx + i, offset.dy + 1, '█', style);
        } else {
          buffer.writeString(offset.dx + i, offset.dy, '█', style);
        }
      } else {
        if (h > 1) {
          buffer.writeString(offset.dx + i, offset.dy + 1, '▒', style);
        } else {
          buffer.writeString(offset.dx + i, offset.dy, '▒', style);
        }
      }
    }
  }
}
