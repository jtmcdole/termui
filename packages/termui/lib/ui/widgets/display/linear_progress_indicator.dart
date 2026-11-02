import 'package:characters/characters.dart';
import 'package:termui/termui.dart';

/// The direction the progress bar fills.
enum ProgressDirection {
  /// Fills from left to right.
  leftToRight,

  /// Fills from right to left.
  rightToLeft,

  /// Fills from top to bottom.
  topToBottom,

  /// Fills from bottom to top.
  bottomToTop,
}

/// The type of characters used to render the progress bar.
enum ProgressBarType {
  /// Uses block characters (e.g., █).
  blocks,

  /// Uses braille characters (e.g., ⣿).
  braille,

  /// Uses quad characters (e.g., ▚).
  quads,
}

/// How to fill the cross axis for fractional steps.
enum CrossAxisFill {
  /// Fractional steps span the entire cross axis uniformly.
  span,

  /// Fractional steps are rendered precisely dot-by-dot.
  precise,
}

/// A single color stop in a gradient.
typedef GradientStop = ({Color color, double stop});

/// A set of foreground and background gradients.
typedef ProgressColors = ({List<GradientStop>? fg, List<GradientStop>? bg});

/// A progress bar widget that fills its horizontal area with block characters.
///
/// It supports custom styling, progress smoothing (using fractional block
/// Unicode characters), gradient coloring (interpolating between start and end
/// colors), and custom mathematical easing curves.
///
/// ### Example Usage
///
/// ```dart
/// LinearProgressIndicator(
///   0.75,
///   smooth: true,
///   colorBuilder: (fraction, fill) => (fg: [(color: Colors.green, stop: 0.0), (color: Colors.red, stop: 1.0)], bg: null),
///   easing: Easing.easeInOutQuad,
/// );
/// ```
class LinearProgressIndicator extends Widget {
  /// Progress percentage from `0.0` to `1.0`.
  final double fraction; // 0.0 to 1.0

  /// Rendering style (foreground/background color).
  final Style style;

  /// Overlay the text representation (e.g. "75%").
  final bool showPercentage;

  /// Draw fractional widths (1/8 to 7/8 characters).
  final bool smooth;

  /// The direction the progress bar fills.
  final ProgressDirection direction;

  /// The type of characters used to render the progress bar.
  final ProgressBarType barType;

  /// How to fill the cross axis for fractional steps.
  final CrossAxisFill crossAxisFill;

  /// Builder for dynamic colors and gradients.
  final ProgressColors Function(double fraction, double fill)? colorBuilder;

  /// Deprecated. Use [colorBuilder] instead.
  @Deprecated('Use colorBuilder instead')
  final Color? startColor;

  /// Deprecated. Use [colorBuilder] instead.
  @Deprecated('Use colorBuilder instead')
  final Color? endColor;

  /// Mathematical formula adjusting progress speed.
  final EasingFunction easing;

  /// Creates a [LinearProgressIndicator].
  const LinearProgressIndicator(
    this.fraction, {
    this.style = Style.empty,
    this.showPercentage = true,
    this.smooth = false,
    this.direction = ProgressDirection.leftToRight,
    this.barType = ProgressBarType.blocks,
    this.crossAxisFill = CrossAxisFill.span,
    this.colorBuilder,
    @Deprecated('Use colorBuilder instead') this.startColor,
    @Deprecated('Use colorBuilder instead') this.endColor,
    this.easing = Easing.linear,
  });

  /// Deprecated. Internal implementation detail no longer used directly.
  @Deprecated('Internal implementation detail no longer used directly')
  static const List<String> eighths = [
    '▏', // 1/8
    '▎', // 2/8
    '▍', // 3/8
    '▌', // 4/8
    '▋', // 5/8
    '▊', // 6/8
    '▉', // 7/8
    '█', // 8/8
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
    '\u2581', // 1/8
    '▂', // 2/8
    '▃', // 3/8
    '▄', // 4/8
    '▅', // 5/8
    '▆', // 6/8
    '▇', // 7/8
    '█', // 8/8
  ];
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
  static const List<String> _quadStepsHorizontal = [' ', '▖', '▌', '▙', '█'];
  static const List<String> _quadStepsVertical = [' ', '▖', '▄', '▙', '█'];

  @override
  Element createElement() => LinearProgressIndicatorElement(this);
}

typedef _PercentageOverlay = ({List<String> chars, int startX, int y});

final class _ProgressPaintPlan {
  final LinearProgressIndicator progress;
  final int width;
  final int height;
  final int subWidth;
  final int subHeight;
  final bool isHorizontal;
  final bool isSpan;
  final int mainAxisCells;
  final int gridW;
  final int gridH;
  final int gridCrossAxis;
  final int totalFilledSpan;
  final int totalFilledPrecise;
  final double eased;
  final _PercentageOverlay? pctOverlay;
  final List<GradientStop>? fgStops;
  final List<GradientStop>? bgStops;

  const _ProgressPaintPlan({
    required this.progress,
    required this.width,
    required this.height,
    required this.subWidth,
    required this.subHeight,
    required this.isHorizontal,
    required this.isSpan,
    required this.mainAxisCells,
    required this.gridW,
    required this.gridH,
    required this.gridCrossAxis,
    required this.totalFilledSpan,
    required this.totalFilledPrecise,
    required this.eased,
    required this.pctOverlay,
    required this.fgStops,
    required this.bgStops,
  });
}

/// An element that manages the rendering of a [LinearProgressIndicator] widget.
class LinearProgressIndicatorElement extends Element {
  /// Creates a [LinearProgressIndicatorElement] for the given [widget].
  LinearProgressIndicatorElement(LinearProgressIndicator super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final progress = widget as LinearProgressIndicator;
    final isHorizontal = _isHorizontalDirection(progress.direction);

    final w = constraints.maxWidth == BoxConstraints.infinity
        ? (isHorizontal ? 20 : 1)
        : constraints.maxWidth;
    final h = constraints.maxHeight == BoxConstraints.infinity
        ? (isHorizontal ? 1 : 20)
        : constraints.maxHeight;

    return constraints.constrain(Size(w, h));
  }

  static bool _isHorizontalDirection(ProgressDirection direction) =>
      direction == ProgressDirection.leftToRight ||
      direction == ProgressDirection.rightToLeft;

  Color? _interpolateColor(List<GradientStop>? stops, double t) {
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
    final progress = widget as LinearProgressIndicator;
    final plan = _buildPaintPlan(progress);

    for (var y = 0; y < plan.height; y++) {
      for (var x = 0; x < plan.width; x++) {
        _paintCell(viewport, plan, x, y);
      }
    }
  }

  _ProgressPaintPlan _buildPaintPlan(LinearProgressIndicator progress) {
    final clamped = progress.fraction.clamp(0.0, 1.0);
    final eased = progress.easing(clamped);
    final isHorizontal = _isHorizontalDirection(progress.direction);
    final (subWidth, subHeight) = _computeSubGrid(
      progress.barType,
      progress.smooth,
      isHorizontal,
    );

    final mainAxisCells = isHorizontal ? size.width : size.height;
    final crossAxisCells = isHorizontal ? size.height : size.width;
    final mainSubunitsPerCell = isHorizontal ? subWidth : subHeight;
    final crossSubunitsPerCell = isHorizontal ? subHeight : subWidth;
    final gridMainAxis = mainAxisCells * mainSubunitsPerCell;
    final gridCrossAxis = crossAxisCells * crossSubunitsPerCell;
    final (fgStops, bgStops) = _resolveColorStops(progress, clamped, eased);

    return _ProgressPaintPlan(
      progress: progress,
      width: size.width,
      height: size.height,
      subWidth: subWidth,
      subHeight: subHeight,
      isHorizontal: isHorizontal,
      isSpan: progress.crossAxisFill == CrossAxisFill.span,
      mainAxisCells: mainAxisCells,
      gridW: size.width * subWidth,
      gridH: size.height * subHeight,
      gridCrossAxis: gridCrossAxis,
      totalFilledSpan: (eased * gridMainAxis).round(),
      totalFilledPrecise: (eased * (gridMainAxis * gridCrossAxis)).round(),
      eased: eased,
      pctOverlay: _resolvePercentageOverlay(progress, eased),
      fgStops: fgStops,
      bgStops: bgStops,
    );
  }

  static (int subWidth, int subHeight) _computeSubGrid(
    ProgressBarType barType,
    bool smooth,
    bool isHorizontal,
  ) => switch (barType) {
    ProgressBarType.braille => (2, 4),
    ProgressBarType.quads => (2, 2),
    ProgressBarType.blocks when !smooth => (1, 1),
    ProgressBarType.blocks => isHorizontal ? (8, 1) : (1, 8),
  };

  _PercentageOverlay? _resolvePercentageOverlay(
    LinearProgressIndicator progress,
    double eased,
  ) {
    if (!progress.showPercentage) return null;
    final text = '${(eased * 100).toInt().clamp(0, 100)}%';
    final chars = [...text.characters];
    if (chars.length > size.width) return null;
    return (
      chars: chars,
      startX: ((size.width - chars.length) / 2).floor(),
      y: size.height ~/ 2,
    );
  }

  static (List<GradientStop>?, List<GradientStop>?) _resolveColorStops(
    LinearProgressIndicator progress,
    double clamped,
    double eased,
  ) {
    final colors = progress.colorBuilder?.call(clamped, eased);
    // ignore: deprecated_member_use_from_same_package
    final hasLegacyColors =
        // ignore: deprecated_member_use_from_same_package
        progress.startColor != null || progress.endColor != null;
    if (progress.colorBuilder != null || !hasLegacyColors) {
      return (colors?.fg, colors?.bg);
    }
    final fallback = progress.style.foreground ?? const Color(255, 255, 255);
    // ignore: deprecated_member_use_from_same_package
    final start = progress.startColor ?? fallback;
    // ignore: deprecated_member_use_from_same_package
    final end = progress.endColor ?? fallback;
    return ([(color: start, stop: 0.0), (color: end, stop: 1.0)], colors?.bg);
  }

  void _paintCell(Viewport viewport, _ProgressPaintPlan plan, int x, int y) {
    final cellT = _computeCellT(plan, x, y);
    final style = plan.progress.style;
    final cellFg = _interpolateColor(plan.fgStops, cellT) ?? style.foreground;
    final cellBg = _interpolateColor(plan.bgStops, cellT) ?? style.background;

    final pctChar = _percentageCharAt(plan.pctOverlay, x, y);
    final (char, invertColors) = pctChar != null
        ? (pctChar, false)
        : _resolveBarGlyph(plan, x, y, canInvert: cellBg != null);

    final renderFg = invertColors ? cellBg : cellFg;
    final renderBg = invertColors ? cellFg : cellBg;
    viewport.setAttributes(
      x,
      y,
      char: char,
      fg: renderFg?.argb,
      bg: renderBg?.argb,
      modifiers: style.modifiers,
    );
  }

  static double _computeCellT(_ProgressPaintPlan plan, int x, int y) {
    if (plan.mainAxisCells <= 1) return 0.0;
    final mainCellIndex = switch (plan.progress.direction) {
      ProgressDirection.leftToRight => x,
      ProgressDirection.rightToLeft => plan.width - 1 - x,
      ProgressDirection.topToBottom => y,
      ProgressDirection.bottomToTop => plan.height - 1 - y,
    };
    return mainCellIndex / (plan.mainAxisCells - 1);
  }

  static String? _percentageCharAt(_PercentageOverlay? overlay, int x, int y) {
    if (overlay == null || y != overlay.y) return null;
    final localIdx = x - overlay.startX;
    if (localIdx < 0 || localIdx >= overlay.chars.length) return null;
    return overlay.chars[localIdx];
  }

  (String char, bool invertColors) _resolveBarGlyph(
    _ProgressPaintPlan plan,
    int x,
    int y, {
    required bool canInvert,
  }) {
    final threshold = _computeCellThreshold(plan, x, y);
    return switch (plan.progress.barType) {
      ProgressBarType.braille => (_paintBrailleCell(plan, threshold), false),
      ProgressBarType.quads => (
        _paintQuadrantCell(plan, x, y, threshold),
        false,
      ),
      ProgressBarType.blocks => _paintBlockCell(
        plan,
        threshold,
        canInvert: canInvert,
      ),
    };
  }

  static int _computeCellThreshold(_ProgressPaintPlan plan, int x, int y) {
    final baseGx = x * plan.subWidth;
    final baseGy = y * plan.subHeight;
    if (plan.isSpan) {
      return switch (plan.progress.direction) {
        ProgressDirection.leftToRight => plan.totalFilledSpan - baseGx,
        ProgressDirection.rightToLeft =>
          (plan.gridW - 1) - baseGx - plan.totalFilledSpan,
        ProgressDirection.topToBottom => plan.totalFilledSpan - baseGy,
        ProgressDirection.bottomToTop =>
          (plan.gridH - 1) - baseGy - plan.totalFilledSpan,
      };
    }
    final c = plan.gridCrossAxis;
    return switch (plan.progress.direction) {
      ProgressDirection.leftToRight =>
        plan.totalFilledPrecise - (baseGx * c + baseGy),
      ProgressDirection.rightToLeft =>
        plan.totalFilledPrecise - ((plan.gridW - 1 - baseGx) * c + baseGy),
      ProgressDirection.topToBottom =>
        plan.totalFilledPrecise - (baseGy * c + baseGx),
      ProgressDirection.bottomToTop =>
        plan.totalFilledPrecise - ((plan.gridH - 1 - baseGy) * c + baseGx),
    };
  }

  static String _paintBrailleCell(_ProgressPaintPlan plan, int threshold) {
    final offset = plan.isSpan
        ? _brailleSpanOffset(plan.progress.direction, threshold)
        : _braillePreciseOffset(
            plan.progress.direction,
            plan.gridCrossAxis,
            threshold,
          );
    return String.fromCharCode(0x2800 + offset);
  }

  static int _brailleSpanOffset(ProgressDirection direction, int threshold) =>
      switch (direction) {
        ProgressDirection.leftToRight =>
          _bitIfLess(0, threshold, 71) | _bitIfLess(1, threshold, 184),
        ProgressDirection.rightToLeft =>
          _bitIfGreater(0, threshold, 71) | _bitIfGreater(1, threshold, 184),
        ProgressDirection.topToBottom =>
          _bitIfLess(0, threshold, 9) |
              _bitIfLess(1, threshold, 18) |
              _bitIfLess(2, threshold, 36) |
              _bitIfLess(3, threshold, 192),
        ProgressDirection.bottomToTop =>
          _bitIfGreater(0, threshold, 9) |
              _bitIfGreater(1, threshold, 18) |
              _bitIfGreater(2, threshold, 36) |
              _bitIfGreater(3, threshold, 192),
      };

  static int _braillePreciseOffset(
    ProgressDirection direction,
    int c,
    int threshold,
  ) => switch (direction) {
    ProgressDirection.leftToRight =>
      _bitIfLess(0, threshold, 1) |
          _bitIfLess(1, threshold, 2) |
          _bitIfLess(2, threshold, 4) |
          _bitIfLess(c, threshold, 8) |
          _bitIfLess(c + 1, threshold, 16) |
          _bitIfLess(c + 2, threshold, 32) |
          _bitIfLess(3, threshold, 64) |
          _bitIfLess(c + 3, threshold, 128),
    ProgressDirection.rightToLeft =>
      _bitIfLess(0, threshold, 1) |
          _bitIfLess(1, threshold, 2) |
          _bitIfLess(2, threshold, 4) |
          _bitIfLess(-c, threshold, 8) |
          _bitIfLess(1 - c, threshold, 16) |
          _bitIfLess(2 - c, threshold, 32) |
          _bitIfLess(3, threshold, 64) |
          _bitIfLess(3 - c, threshold, 128),
    ProgressDirection.topToBottom =>
      _bitIfLess(0, threshold, 1) |
          _bitIfLess(c, threshold, 2) |
          _bitIfLess(2 * c, threshold, 4) |
          _bitIfLess(1, threshold, 8) |
          _bitIfLess(c + 1, threshold, 16) |
          _bitIfLess(2 * c + 1, threshold, 32) |
          _bitIfLess(3 * c, threshold, 64) |
          _bitIfLess(3 * c + 1, threshold, 128),
    ProgressDirection.bottomToTop =>
      _bitIfLess(0, threshold, 1) |
          _bitIfLess(-c, threshold, 2) |
          _bitIfLess(-2 * c, threshold, 4) |
          _bitIfLess(1, threshold, 8) |
          _bitIfLess(1 - c, threshold, 16) |
          _bitIfLess(1 - 2 * c, threshold, 32) |
          _bitIfLess(-3 * c, threshold, 64) |
          _bitIfLess(1 - 3 * c, threshold, 128),
  };

  static String _paintQuadrantCell(
    _ProgressPaintPlan plan,
    int x,
    int y,
    int threshold,
  ) {
    if (plan.isSpan && plan.progress.smooth) {
      return _quadSmoothSpanChar(plan, x, y);
    }
    final offset = plan.isSpan
        ? _quadSpanOffset(plan.progress.direction, threshold)
        : _quadPreciseOffset(
            plan.progress.direction,
            plan.gridCrossAxis,
            threshold,
          );
    return LinearProgressIndicator._quads[offset];
  }

  static String _quadSmoothSpanChar(_ProgressPaintPlan plan, int x, int y) {
    final maxSteps = plan.mainAxisCells * 4;
    final filledSteps = (plan.eased * maxSteps).round();
    final cellSteps = switch (plan.progress.direction) {
      ProgressDirection.leftToRight => filledSteps - (x * 4),
      ProgressDirection.rightToLeft => filledSteps - ((plan.width - 1 - x) * 4),
      ProgressDirection.topToBottom => filledSteps - (y * 4),
      ProgressDirection.bottomToTop =>
        filledSteps - ((plan.height - 1 - y) * 4),
    };
    final step = cellSteps.clamp(0, 4);
    return plan.isHorizontal
        ? LinearProgressIndicator._quadStepsHorizontal[step]
        : LinearProgressIndicator._quadStepsVertical[step];
  }

  static int _quadSpanOffset(ProgressDirection direction, int threshold) =>
      switch (direction) {
        ProgressDirection.leftToRight =>
          _bitIfLess(0, threshold, 5) | _bitIfLess(1, threshold, 10),
        ProgressDirection.rightToLeft =>
          _bitIfGreater(0, threshold, 5) | _bitIfGreater(1, threshold, 10),
        ProgressDirection.topToBottom =>
          _bitIfLess(0, threshold, 3) | _bitIfLess(1, threshold, 12),
        ProgressDirection.bottomToTop =>
          _bitIfGreater(0, threshold, 3) | _bitIfGreater(1, threshold, 12),
      };

  static int _quadPreciseOffset(
    ProgressDirection direction,
    int c,
    int threshold,
  ) => switch (direction) {
    ProgressDirection.leftToRight =>
      _bitIfLess(0, threshold, 1) |
          _bitIfLess(1, threshold, 4) |
          _bitIfLess(c, threshold, 2) |
          _bitIfLess(c + 1, threshold, 8),
    ProgressDirection.rightToLeft =>
      _bitIfLess(0, threshold, 1) |
          _bitIfLess(1, threshold, 4) |
          _bitIfLess(-c, threshold, 2) |
          _bitIfLess(1 - c, threshold, 8),
    ProgressDirection.topToBottom =>
      _bitIfLess(0, threshold, 1) |
          _bitIfLess(1, threshold, 2) |
          _bitIfLess(c, threshold, 4) |
          _bitIfLess(c + 1, threshold, 8),
    ProgressDirection.bottomToTop =>
      _bitIfLess(0, threshold, 1) |
          _bitIfLess(1, threshold, 2) |
          _bitIfLess(-c, threshold, 4) |
          _bitIfLess(1 - c, threshold, 8),
  };

  static (String char, bool invertColors) _paintBlockCell(
    _ProgressPaintPlan plan,
    int threshold, {
    required bool canInvert,
  }) {
    final filledCount = plan.isSpan
        ? _blockSpanFilledCount(plan, threshold)
        : _blockPreciseFilledCount(plan, threshold);

    if (plan.subWidth > 1) {
      final shouldInvert =
          plan.progress.direction == ProgressDirection.rightToLeft &&
          canInvert &&
          filledCount > 0 &&
          filledCount < 8;
      final idx = (shouldInvert ? 8 - filledCount : filledCount).clamp(0, 8);
      return (LinearProgressIndicator._blocksHorizontal[idx], shouldInvert);
    }
    if (plan.subHeight > 1) {
      final shouldInvert =
          plan.progress.direction == ProgressDirection.topToBottom &&
          canInvert &&
          filledCount > 0 &&
          filledCount < 8;
      final idx = (shouldInvert ? 8 - filledCount : filledCount).clamp(0, 8);
      return (LinearProgressIndicator._blocksVertical[idx], shouldInvert);
    }
    return (filledCount > 0 ? '█' : ' ', false);
  }

  static int _blockSpanFilledCount(_ProgressPaintPlan plan, int threshold) =>
      switch (plan.progress.direction) {
        ProgressDirection.leftToRight => threshold.clamp(0, plan.subWidth),
        ProgressDirection.rightToLeft =>
          plan.subWidth - (threshold + 1).clamp(0, plan.subWidth),
        ProgressDirection.topToBottom => threshold.clamp(0, plan.subHeight),
        ProgressDirection.bottomToTop =>
          plan.subHeight - (threshold + 1).clamp(0, plan.subHeight),
      };

  static int _blockPreciseFilledCount(_ProgressPaintPlan plan, int threshold) {
    var filledCount = 0;
    final c = plan.gridCrossAxis;
    final dir = plan.progress.direction;
    for (var dy = 0; dy < plan.subHeight; dy++) {
      for (var dx = 0; dx < plan.subWidth; dx++) {
        final val = switch (dir) {
          ProgressDirection.leftToRight => dx * c + dy,
          ProgressDirection.rightToLeft => dy - dx * c,
          ProgressDirection.topToBottom => dy * c + dx,
          ProgressDirection.bottomToTop => dx - dy * c,
        };
        if (val < threshold) filledCount++;
      }
    }
    return filledCount;
  }

  @pragma('vm:prefer-inline')
  static int _bitIfLess(int val, int threshold, int bit) =>
      val < threshold ? bit : 0;

  @pragma('vm:prefer-inline')
  static int _bitIfGreater(int val, int threshold, int bit) =>
      val > threshold ? bit : 0;
}
