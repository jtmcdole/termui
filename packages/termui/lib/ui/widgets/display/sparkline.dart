import 'package:termui/termui.dart';

/// A sparkline widget for rendering high-density historical data.
class Sparkline extends Widget {
  /// The historical data points.
  final Iterable<double> data;

  /// The maximum value used to calculate bar fraction (0.0 to 1.0).
  final double max;

  /// The direction time flows. In horizontal flow, bars grow vertically.
  /// In vertical flow, bars grow horizontally.
  final ProgressDirection direction;

  /// The type of characters used to render the graph (braille, quads, or blocks).
  final ProgressBarType barType;

  /// Optional dynamic coloring per cell.
  final ProgressColors Function(int cellIndex, List<double> cellValues)?
  colorBuilder;

  /// Fallback rendering style.
  final Style style;

  /// Creates a [Sparkline].
  const Sparkline(
    this.data, {
    this.max = 1.0,
    this.direction = ProgressDirection.leftToRight,
    this.barType = ProgressBarType.braille,
    this.colorBuilder,
    this.style = Style.empty,
  });

  @override
  Element createElement() => SparklineElement(this);
}

/// An element that manages the rendering of a [Sparkline].
class SparklineElement extends Element {
  /// Creates a [SparklineElement].
  SparklineElement(Sparkline super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final sparkline = widget as Sparkline;
    // For sparkline, standard orientation rules apply
    final isHorizontal =
        sparkline.direction == ProgressDirection.bottomToTop ||
        sparkline.direction == ProgressDirection.topToBottom;

    double w = constraints.maxWidth == BoxConstraints.infinity
        ? (isHorizontal ? 20 : 1)
        : constraints.maxWidth.toDouble();
    double h = constraints.maxHeight == BoxConstraints.infinity
        ? (isHorizontal ? 1 : 20)
        : constraints.maxHeight.toDouble();

    return constraints.constrain(Size(w.floor(), h.floor()));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final viewport = Viewport(
      buffer,
      Rect(offset.dx, offset.dy, size.width, size.height),
    );
    if (size.width <= 0 || size.height <= 0) return;

    final sparkline = widget as Sparkline;

    int subWidth = 1;
    int subHeight = 1;
    if (sparkline.barType == ProgressBarType.braille) {
      subWidth = 2;
      subHeight = 4;
    } else if (sparkline.barType == ProgressBarType.quads) {
      subWidth = 2;
      subHeight = 2;
    } else {
      // blocks
      final isHorizontal =
          sparkline.direction == ProgressDirection.bottomToTop ||
          sparkline.direction == ProgressDirection.topToBottom;
      if (isHorizontal) {
        // Bars grow vertically, subHeight = 8
        subWidth = 1;
        subHeight = 8;
      } else {
        // Bars grow horizontally, subWidth = 8
        subWidth = 8;
        subHeight = 1;
      }
    }

    final timeFlowsHorizontally =
        sparkline.direction == ProgressDirection.bottomToTop ||
        sparkline.direction == ProgressDirection.topToBottom;

    final maxTimeLength = timeFlowsHorizontally
        ? size.width * subWidth
        : size.height * subHeight;
    final crossLength = timeFlowsHorizontally
        ? size.height * subHeight
        : size.width * subWidth;

    final listData = sparkline.data.toList();
    List<double> normalizedData;

    if (listData.length >= maxTimeLength) {
      normalizedData = listData.sublist(listData.length - maxTimeLength);
    } else {
      normalizedData =
          List.filled(maxTimeLength - listData.length, 0.0) + listData;
    }

    bool isFilledDot(int x, int y, int dx, int dy) {
      int gx = x * subWidth + dx;
      int gy = y * subHeight + dy;

      int timeIndex;
      int crossIndex;

      if (timeFlowsHorizontally) {
        timeIndex = gx; // time flows left to right
        if (sparkline.direction == ProgressDirection.bottomToTop) {
          crossIndex = (size.height * subHeight - 1) - gy;
        } else {
          crossIndex = gy;
        }
      } else {
        timeIndex = gy; // time flows top to bottom
        if (sparkline.direction == ProgressDirection.rightToLeft) {
          crossIndex = (size.width * subWidth - 1) - gx;
        } else {
          crossIndex = gx;
        }
      }

      double val = normalizedData[timeIndex];
      double fraction = sparkline.max <= 0 ? 0 : (val / sparkline.max);
      double filledCrossUnits = fraction * crossLength;

      return crossIndex < filledCrossUnits.round();
    }

    // Prepare cell values for colorBuilder
    Map<int, List<double>> cellValuesMap = {};
    if (sparkline.colorBuilder != null) {
      for (int i = 0; i < maxTimeLength; i++) {
        int cellIndex;
        if (timeFlowsHorizontally) {
          cellIndex = i ~/ subWidth;
        } else {
          cellIndex = i ~/ subHeight;
        }
        cellValuesMap.putIfAbsent(cellIndex, () => []).add(normalizedData[i]);
      }
    }

    for (var y = 0; y < size.height; y++) {
      for (var x = 0; x < size.width; x++) {
        int cellIndex = timeFlowsHorizontally ? x : y;
        Color? cellFg = sparkline.style.foreground;
        Color? cellBg = sparkline.style.background;

        if (sparkline.colorBuilder != null) {
          List<double> cellValues = cellValuesMap[cellIndex] ?? [];
          final colors = sparkline.colorBuilder!(cellIndex, cellValues);

          Color? interpolate(List<GradientStop>? stops, double t) {
            if (stops == null || stops.isEmpty) return null;
            if (stops.length == 1) return stops.first.color;
            for (int i = 0; i < stops.length - 1; i++) {
              final s1 = stops[i];
              final s2 = stops[i + 1];
              if (t >= s1.stop && t <= s2.stop) {
                final range = s2.stop - s1.stop;
                if (range == 0) return s2.color;
                final localT = (t - s1.stop) / range;
                final r = (s1.color.r + localT * (s2.color.r - s1.color.r))
                    .round();
                final g = (s1.color.g + localT * (s2.color.g - s1.color.g))
                    .round();
                final b = (s1.color.b + localT * (s2.color.b - s1.color.b))
                    .round();
                return Color(r, g, b);
              }
            }
            if (t < stops.first.stop) return stops.first.color;
            if (t > stops.last.stop) return stops.last.color;
            return null;
          }

          double cellT = 0.0;
          if (size.height > 1 || size.width > 1) {
            if (sparkline.direction == ProgressDirection.bottomToTop) {
              cellT = (size.height - 1 - y) / (size.height - 1);
            } else if (sparkline.direction == ProgressDirection.topToBottom) {
              cellT = y / (size.height - 1);
            } else if (sparkline.direction == ProgressDirection.leftToRight) {
              cellT = x / (size.width - 1);
            } else if (sparkline.direction == ProgressDirection.rightToLeft) {
              cellT = (size.width - 1 - x) / (size.width - 1);
            }
          }

          if (colors.fg != null) {
            cellFg = interpolate(colors.fg, cellT) ?? cellFg;
          }
          if (colors.bg != null) {
            cellBg = interpolate(colors.bg, cellT) ?? cellBg;
          }
        }

        String char = ' ';
        if (sparkline.barType == ProgressBarType.braille) {
          int offset = 0;
          if (isFilledDot(x, y, 0, 0)) offset |= 1;
          if (isFilledDot(x, y, 0, 1)) offset |= 2;
          if (isFilledDot(x, y, 0, 2)) offset |= 4;
          if (isFilledDot(x, y, 1, 0)) offset |= 8;
          if (isFilledDot(x, y, 1, 1)) offset |= 16;
          if (isFilledDot(x, y, 1, 2)) offset |= 32;
          if (isFilledDot(x, y, 0, 3)) offset |= 64;
          if (isFilledDot(x, y, 1, 3)) offset |= 128;
          char = String.fromCharCode(0x2800 + offset);
        } else if (sparkline.barType == ProgressBarType.quads) {
          int offset = 0;
          if (isFilledDot(x, y, 0, 0)) offset |= 1;
          if (isFilledDot(x, y, 1, 0)) offset |= 2;
          if (isFilledDot(x, y, 0, 1)) offset |= 4;
          if (isFilledDot(x, y, 1, 1)) offset |= 8;
          const quads = [
            ' ',
            '▘',
            '▝',
            '▀',
            '▖',
            '▌',
            '▞',
            '▛',
            '▗',
            '▚',
            '▐',
            '▜',
            '▄',
            '▙',
            '▟',
            '█',
          ];
          char = quads[offset];
        } else {
          int filledCount = 0;
          for (int dy = 0; dy < subHeight; dy++) {
            for (int dx = 0; dx < subWidth; dx++) {
              if (isFilledDot(x, y, dx, dy)) filledCount++;
            }
          }
          if (subWidth > 1) {
            // horizontal growth
            const blocksHorizontal = [
              ' ',
              '▏',
              '▎',
              '▍',
              '▌',
              '▋',
              '▊',
              '▉',
              '█',
            ];
            char = blocksHorizontal[filledCount.clamp(0, 8)];
          } else if (subHeight > 1) {
            // vertical growth
            const blocksVertical = [
              ' ',
              '\u2581',
              '▂',
              '▃',
              '▄',
              '▅',
              '▆',
              '▇',
              '█',
            ];
            char = blocksVertical[filledCount.clamp(0, 8)];
          } else {
            char = filledCount > 0 ? '█' : ' ';
          }
        }

        viewport.setAttributes(
          x,
          y,
          char: char,
          fg: cellFg?.argb,
          bg: cellBg?.argb,
          modifiers: sparkline.style.modifiers,
        );
      }
    }
  }
}
