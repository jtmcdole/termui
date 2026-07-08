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

  @override
  Element createElement() => LinearProgressIndicatorElement(this);
}

/// An element that manages the rendering of a [LinearProgressIndicator] widget.
class LinearProgressIndicatorElement extends Element {
  /// Creates a [LinearProgressIndicatorElement] for the given [widget].
  LinearProgressIndicatorElement(LinearProgressIndicator super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final progress = widget as LinearProgressIndicator;
    final isHorizontal =
        progress.direction == ProgressDirection.leftToRight ||
        progress.direction == ProgressDirection.rightToLeft;

    double w = constraints.maxWidth == BoxConstraints.infinity
        ? (isHorizontal ? 20 : 1)
        : constraints.maxWidth.toDouble();
    double h = constraints.maxHeight == BoxConstraints.infinity
        ? (isHorizontal ? 1 : 20)
        : constraints.maxHeight.toDouble();

    return constraints.constrain(Size(w.floor(), h.floor()));
  }

  Color? _interpolateColor(List<GradientStop>? stops, double t) {
    if (stops == null || stops.isEmpty) return null;
    if (stops.length == 1) return stops.first.color;

    for (int i = 0; i < stops.length - 1; i++) {
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
    final viewport = Viewport(
      buffer,
      Rect(offset.dx, offset.dy, size.width, size.height),
    );
    final progress = widget as LinearProgressIndicator;
    if (size.width <= 0 || size.height <= 0) return;

    final clamped = progress.fraction.clamp(0.0, 1.0);
    final eased = progress.easing(clamped);

    int subWidth = 1;
    int subHeight = 1;
    if (progress.barType == ProgressBarType.braille) {
      subWidth = 2;
      subHeight = 4;
    } else if (progress.smooth) {
      if (progress.direction == ProgressDirection.leftToRight ||
          progress.direction == ProgressDirection.rightToLeft) {
        subWidth = 8;
        subHeight = 1;
      } else {
        subWidth = 1;
        subHeight = 8;
      }
    }

    final isHorizontal =
        progress.direction == ProgressDirection.leftToRight ||
        progress.direction == ProgressDirection.rightToLeft;
    final mainAxisCells = isHorizontal ? size.width : size.height;
    final crossAxisCells = isHorizontal ? size.height : size.width;
    final mainSubunitsPerCell = isHorizontal ? subWidth : subHeight;
    final crossSubunitsPerCell = isHorizontal ? subHeight : subWidth;

    final gridMainAxis = mainAxisCells * mainSubunitsPerCell;
    final gridCrossAxis = crossAxisCells * crossSubunitsPerCell;

    final totalFilledSpan = eased * gridMainAxis;
    final totalFilledPrecise = eased * (gridMainAxis * gridCrossAxis);

    String? pctText;
    int? pctStartX;
    int? pctY;
    if (progress.showPercentage) {
      pctText = '${(eased * 100).toInt().clamp(0, 100)}%';
      if (pctText.length <= size.width) {
        pctStartX = ((size.width - pctText.length) / 2).floor();
        pctY = size.height ~/ 2;
      } else {
        pctText = null;
      }
    }

    final colors = progress.colorBuilder?.call(clamped, eased);
    List<GradientStop>? fgStops = colors?.fg;
    List<GradientStop>? bgStops = colors?.bg;

    // ignore: deprecated_member_use_from_same_package
    if (progress.colorBuilder == null &&
        (progress.startColor != null || progress.endColor != null)) {
      // ignore: deprecated_member_use_from_same_package
      final start =
          progress.startColor ??
          progress.style.foreground ??
          const Color(255, 255, 255);
      // ignore: deprecated_member_use_from_same_package
      final end =
          progress.endColor ??
          progress.style.foreground ??
          const Color(255, 255, 255);
      fgStops = [(color: start, stop: 0.0), (color: end, stop: 1.0)];
    }

    bool isFilledDot(int x, int y, int dx, int dy) {
      int gx = x * subWidth + dx;
      int gy = y * subHeight + dy;
      int gMain, gCross;
      switch (progress.direction) {
        case ProgressDirection.leftToRight:
          gMain = gx;
          gCross = gy;
          break;
        case ProgressDirection.rightToLeft:
          gMain = (size.width * subWidth - 1) - gx;
          gCross = gy;
          break;
        case ProgressDirection.topToBottom:
          gMain = gy;
          gCross = gx;
          break;
        case ProgressDirection.bottomToTop:
          gMain = (size.height * subHeight - 1) - gy;
          gCross = gx;
          break;
      }

      if (progress.crossAxisFill == CrossAxisFill.span) {
        return gMain < totalFilledSpan.round();
      } else {
        return (gMain * gridCrossAxis + gCross) < totalFilledPrecise.round();
      }
    }

    for (var y = 0; y < size.height; y++) {
      for (var x = 0; x < size.width; x++) {
        double cellT = 0.0;
        if (mainAxisCells > 1) {
          int mainCellIndex;
          switch (progress.direction) {
            case ProgressDirection.leftToRight:
              mainCellIndex = x;
              break;
            case ProgressDirection.rightToLeft:
              mainCellIndex = size.width - 1 - x;
              break;
            case ProgressDirection.topToBottom:
              mainCellIndex = y;
              break;
            case ProgressDirection.bottomToTop:
              mainCellIndex = size.height - 1 - y;
              break;
          }
          cellT = mainCellIndex / (mainAxisCells - 1);
        }

        final cellFg =
            _interpolateColor(fgStops, cellT) ?? progress.style.foreground;
        final cellBg =
            _interpolateColor(bgStops, cellT) ?? progress.style.background;

        bool invertColors = false;

        String char = ' ';
        if (pctText != null &&
            y == pctY &&
            x >= pctStartX! &&
            x < pctStartX + pctText.length) {
          char = pctText[x - pctStartX];
        } else {
          if (progress.barType == ProgressBarType.braille) {
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
          } else {
            int filledCount = 0;
            for (int dy = 0; dy < subHeight; dy++) {
              for (int dx = 0; dx < subWidth; dx++) {
                if (isFilledDot(x, y, dx, dy)) filledCount++;
              }
            }

            bool canInvert = cellBg != null;

            if (subWidth > 1) {
              if (progress.direction == ProgressDirection.rightToLeft &&
                  canInvert &&
                  filledCount > 0 &&
                  filledCount < 8) {
                char = LinearProgressIndicator
                    ._blocksHorizontal[(8 - filledCount).clamp(0, 8)];
                invertColors = true;
              } else {
                char = LinearProgressIndicator
                    ._blocksHorizontal[filledCount.clamp(0, 8)];
              }
            } else if (subHeight > 1) {
              if (progress.direction == ProgressDirection.topToBottom &&
                  canInvert &&
                  filledCount > 0 &&
                  filledCount < 8) {
                char = LinearProgressIndicator
                    ._blocksVertical[(8 - filledCount).clamp(0, 8)];
                invertColors = true;
              } else {
                char = LinearProgressIndicator
                    ._blocksVertical[filledCount.clamp(0, 8)];
              }
            } else {
              char = filledCount > 0 ? '█' : ' ';
            }
          }
        }

        final renderFg = invertColors ? cellBg : cellFg;
        final renderBg = invertColors ? cellFg : cellBg;

        viewport.setAttributes(
          x,
          y,
          char: char,
          fg: renderFg?.argb,
          bg: renderBg?.argb,
          modifiers: progress.style.modifiers,
        );
      }
    }
  }
}
