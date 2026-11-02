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
  final ProgressColors Function(
    int cellIndex,
    double v0, [
    double? v1,
    double? v2,
    double? v3,
  ])?
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

  static const List<String> _quads = [
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
  static const List<String> _blocksHorizontal = [
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
  static const List<String> _blocksVertical = [
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

  @override
  Element createElement() => SparklineElement(this);
}

final class _SparklinePaintPlan {
  final Sparkline sparkline;
  final List<double> values;
  final int width;
  final int height;
  final int subWidth;
  final int subHeight;
  final bool timeFlowsHorizontally;
  final int crossLength;
  final int skipCount;
  final int paddingCount;

  const _SparklinePaintPlan({
    required this.sparkline,
    required this.values,
    required this.width,
    required this.height,
    required this.subWidth,
    required this.subHeight,
    required this.timeFlowsHorizontally,
    required this.crossLength,
    required this.skipCount,
    required this.paddingCount,
  });

  double valueAt(int index) {
    if (index < paddingCount) return 0.0;
    return values[index - paddingCount + skipCount];
  }

  bool isFilledDot(int x, int y, int dx, int dy) {
    final gx = x * subWidth + dx;
    final gy = y * subHeight + dy;
    final timeIndex = timeFlowsHorizontally ? gx : gy;
    final crossIndex = switch (sparkline.direction) {
      ProgressDirection.bottomToTop => (height * subHeight - 1) - gy,
      ProgressDirection.topToBottom => gy,
      ProgressDirection.rightToLeft => (width * subWidth - 1) - gx,
      ProgressDirection.leftToRight => gx,
    };

    final val = valueAt(timeIndex);
    final fraction = sparkline.max <= 0 ? 0.0 : (val / sparkline.max);
    return crossIndex < (fraction * crossLength).round();
  }

  @pragma('vm:prefer-inline')
  int dotBit(int x, int y, int dx, int dy, int bit) =>
      isFilledDot(x, y, dx, dy) ? bit : 0;
}

/// An element that manages the rendering of a [Sparkline].
class SparklineElement extends Element {
  /// Creates a [SparklineElement].
  SparklineElement(Sparkline super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final sparkline = widget as Sparkline;
    final isHorizontal = _timeFlowsHorizontally(sparkline.direction);

    final w = constraints.maxWidth == BoxConstraints.infinity
        ? (isHorizontal ? 20 : 1)
        : constraints.maxWidth;
    final h = constraints.maxHeight == BoxConstraints.infinity
        ? (isHorizontal ? 1 : 20)
        : constraints.maxHeight;

    return constraints.constrain(Size(w, h));
  }

  static bool _timeFlowsHorizontally(ProgressDirection direction) =>
      direction == ProgressDirection.bottomToTop ||
      direction == ProgressDirection.topToBottom;

  static Color? _interpolate(List<GradientStop>? stops, double t) {
    if (stops == null || stops.isEmpty) return null;
    if (stops.length == 1) return stops.first.color;
    for (var i = 0; i < stops.length - 1; i++) {
      final s1 = stops[i];
      final s2 = stops[i + 1];
      if (t >= s1.stop && t <= s2.stop) {
        final range = s2.stop - s1.stop;
        if (range == 0) return s2.color;
        final localT = (t - s1.stop) / range;
        final r = (s1.color.r + localT * (s2.color.r - s1.color.r)).round();
        final g = (s1.color.g + localT * (s2.color.g - s1.color.g)).round();
        final b = (s1.color.b + localT * (s2.color.b - s1.color.b)).round();
        return Color(r, g, b);
      }
    }
    if (t < stops.first.stop) return stops.first.color;
    if (t > stops.last.stop) return stops.last.color;
    return null;
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    if (size.width <= 0 || size.height <= 0) return;
    final viewport = Viewport(
      buffer,
      Rect(offset.dx, offset.dy, size.width, size.height),
    );
    final sparkline = widget as Sparkline;
    final plan = _buildPaintPlan(sparkline);

    for (var y = 0; y < plan.height; y++) {
      for (var x = 0; x < plan.width; x++) {
        final (cellFg, cellBg) = _resolveCellColors(plan, x, y);
        final char = _resolveSparkGlyph(plan, x, y);
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

  _SparklinePaintPlan _buildPaintPlan(Sparkline sparkline) {
    final timeFlowsHorizontally = _timeFlowsHorizontally(sparkline.direction);
    final (subWidth, subHeight) = _computeSubGrid(
      sparkline.barType,
      timeFlowsHorizontally,
    );
    final maxTimeLength = timeFlowsHorizontally
        ? size.width * subWidth
        : size.height * subHeight;
    final crossLength = timeFlowsHorizontally
        ? size.height * subHeight
        : size.width * subWidth;

    final values = sparkline.data is List<double>
        ? sparkline.data as List<double>
        : [...sparkline.data];
    final dataLength = values.length;

    return _SparklinePaintPlan(
      sparkline: sparkline,
      values: values,
      width: size.width,
      height: size.height,
      subWidth: subWidth,
      subHeight: subHeight,
      timeFlowsHorizontally: timeFlowsHorizontally,
      crossLength: crossLength,
      skipCount: dataLength > maxTimeLength ? dataLength - maxTimeLength : 0,
      paddingCount: maxTimeLength > dataLength ? maxTimeLength - dataLength : 0,
    );
  }

  static (int subWidth, int subHeight) _computeSubGrid(
    ProgressBarType barType,
    bool timeFlowsHorizontally,
  ) => switch (barType) {
    ProgressBarType.braille => (2, 4),
    ProgressBarType.quads => (2, 2),
    ProgressBarType.blocks => timeFlowsHorizontally ? (1, 8) : (8, 1),
  };

  static (Color?, Color?) _resolveCellColors(
    _SparklinePaintPlan plan,
    int x,
    int y,
  ) {
    final sparkline = plan.sparkline;
    final baseFg = sparkline.style.foreground;
    final baseBg = sparkline.style.background;
    final builder = sparkline.colorBuilder;
    if (builder == null) return (baseFg, baseBg);

    final cellIndex = plan.timeFlowsHorizontally ? x : y;
    final baseTimeIndex = plan.timeFlowsHorizontally
        ? x * plan.subWidth
        : y * plan.subHeight;
    final timeSubUnits = plan.timeFlowsHorizontally
        ? plan.subWidth
        : plan.subHeight;

    final v0 = plan.valueAt(baseTimeIndex);
    final v1 = timeSubUnits > 1 ? plan.valueAt(baseTimeIndex + 1) : null;
    final v2 = timeSubUnits > 2 ? plan.valueAt(baseTimeIndex + 2) : null;
    final v3 = timeSubUnits > 3 ? plan.valueAt(baseTimeIndex + 3) : null;
    final colors = builder(cellIndex, v0, v1, v2, v3);
    final cellT = _computeCellT(plan, x, y);

    final fg = colors.fg != null
        ? (_interpolate(colors.fg, cellT) ?? baseFg)
        : baseFg;
    final bg = colors.bg != null
        ? (_interpolate(colors.bg, cellT) ?? baseBg)
        : baseBg;
    return (fg, bg);
  }

  static double _computeCellT(_SparklinePaintPlan plan, int x, int y) =>
      switch (plan.sparkline.direction) {
        ProgressDirection.bottomToTop =>
          plan.height > 1 ? (plan.height - 1 - y) / (plan.height - 1) : 0.0,
        ProgressDirection.topToBottom =>
          plan.height > 1 ? y / (plan.height - 1) : 0.0,
        ProgressDirection.leftToRight =>
          plan.width > 1 ? x / (plan.width - 1) : 0.0,
        ProgressDirection.rightToLeft =>
          plan.width > 1 ? (plan.width - 1 - x) / (plan.width - 1) : 0.0,
      };

  static String _resolveSparkGlyph(_SparklinePaintPlan plan, int x, int y) =>
      switch (plan.sparkline.barType) {
        ProgressBarType.braille => _paintBrailleCell(plan, x, y),
        ProgressBarType.quads => _paintQuadrantCell(plan, x, y),
        ProgressBarType.blocks => _paintBlockCell(plan, x, y),
      };

  static String _paintBrailleCell(_SparklinePaintPlan plan, int x, int y) {
    final offset =
        plan.dotBit(x, y, 0, 0, 1) |
        plan.dotBit(x, y, 0, 1, 2) |
        plan.dotBit(x, y, 0, 2, 4) |
        plan.dotBit(x, y, 1, 0, 8) |
        plan.dotBit(x, y, 1, 1, 16) |
        plan.dotBit(x, y, 1, 2, 32) |
        plan.dotBit(x, y, 0, 3, 64) |
        plan.dotBit(x, y, 1, 3, 128);
    return String.fromCharCode(0x2800 + offset);
  }

  static String _paintQuadrantCell(_SparklinePaintPlan plan, int x, int y) {
    final offset =
        plan.dotBit(x, y, 0, 0, 1) |
        plan.dotBit(x, y, 1, 0, 2) |
        plan.dotBit(x, y, 0, 1, 4) |
        plan.dotBit(x, y, 1, 1, 8);
    return Sparkline._quads[offset];
  }

  static String _paintBlockCell(_SparklinePaintPlan plan, int x, int y) {
    var filledCount = 0;
    for (var dy = 0; dy < plan.subHeight; dy++) {
      for (var dx = 0; dx < plan.subWidth; dx++) {
        if (plan.isFilledDot(x, y, dx, dy)) filledCount++;
      }
    }
    if (plan.subWidth > 1) {
      return Sparkline._blocksHorizontal[filledCount.clamp(0, 8)];
    }
    if (plan.subHeight > 1) {
      return Sparkline._blocksVertical[filledCount.clamp(0, 8)];
    }
    return filledCount > 0 ? '█' : ' ';
  }
}
