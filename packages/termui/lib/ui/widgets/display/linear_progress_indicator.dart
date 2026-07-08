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

    final (int subWidth, int subHeight) = switch (progress.barType) {
      ProgressBarType.braille => (2, 4),
      ProgressBarType.quads => (2, 2),
      ProgressBarType.blocks =>
        progress.smooth
            ? switch (progress.direction) {
                ProgressDirection.leftToRight ||
                ProgressDirection.rightToLeft => (8, 1),
                ProgressDirection.topToBottom ||
                ProgressDirection.bottomToTop => (1, 8),
              }
            : (1, 1),
    };

    final isHorizontal =
        progress.direction == ProgressDirection.leftToRight ||
        progress.direction == ProgressDirection.rightToLeft;
    final mainAxisCells = isHorizontal ? size.width : size.height;
    final crossAxisCells = isHorizontal ? size.height : size.width;
    final mainSubunitsPerCell = isHorizontal ? subWidth : subHeight;
    final crossSubunitsPerCell = isHorizontal ? subHeight : subWidth;

    final gridMainAxis = mainAxisCells * mainSubunitsPerCell;
    final gridCrossAxis = crossAxisCells * crossSubunitsPerCell;

    final totalFilledSpan = (eased * gridMainAxis).round();
    final totalFilledPrecise = (eased * (gridMainAxis * gridCrossAxis)).round();

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

    for (var y = 0; y < size.height; y++) {
      for (var x = 0; x < size.width; x++) {
        double cellT = 0.0;
        if (mainAxisCells > 1) {
          final mainCellIndex = switch (progress.direction) {
            ProgressDirection.leftToRight => x,
            ProgressDirection.rightToLeft => size.width - 1 - x,
            ProgressDirection.topToBottom => y,
            ProgressDirection.bottomToTop => size.height - 1 - y,
          };
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
          final baseGx = x * subWidth;
          final baseGy = y * subHeight;
          final isSpan = progress.crossAxisFill == CrossAxisFill.span;
          final gridW = size.width * subWidth;
          final gridH = size.height * subHeight;

          final threshold = isSpan
              ? switch (progress.direction) {
                  ProgressDirection.leftToRight => totalFilledSpan - baseGx,
                  ProgressDirection.rightToLeft =>
                    (gridW - 1) - baseGx - totalFilledSpan,
                  ProgressDirection.topToBottom => totalFilledSpan - baseGy,
                  ProgressDirection.bottomToTop =>
                    (gridH - 1) - baseGy - totalFilledSpan,
                }
              : switch (progress.direction) {
                  ProgressDirection.leftToRight =>
                    totalFilledPrecise - (baseGx * gridCrossAxis + baseGy),
                  ProgressDirection.rightToLeft =>
                    totalFilledPrecise -
                        ((gridW - 1 - baseGx) * gridCrossAxis + baseGy),
                  ProgressDirection.topToBottom =>
                    totalFilledPrecise - (baseGy * gridCrossAxis + baseGx),
                  ProgressDirection.bottomToTop =>
                    totalFilledPrecise -
                        ((gridH - 1 - baseGy) * gridCrossAxis + baseGx),
                };

          if (progress.barType == ProgressBarType.braille) {
            int offset = 0;
            if (isSpan) {
              switch (progress.direction) {
                case ProgressDirection.leftToRight:
                  if (0 < threshold) offset |= 71; // 1 | 2 | 4 | 64
                  if (1 < threshold) offset |= 184; // 8 | 16 | 32 | 128
                case ProgressDirection.rightToLeft:
                  if (0 > threshold) offset |= 71;
                  if (1 > threshold) offset |= 184;
                case ProgressDirection.topToBottom:
                  if (0 < threshold) offset |= 9; // dy=0: 1 | 8
                  if (1 < threshold) offset |= 18; // dy=1: 2 | 16
                  if (2 < threshold) offset |= 36; // dy=2: 4 | 32
                  if (3 < threshold) offset |= 192; // dy=3: 64 | 128
                case ProgressDirection.bottomToTop:
                  if (0 > threshold) offset |= 9;
                  if (1 > threshold) offset |= 18;
                  if (2 > threshold) offset |= 36;
                  if (3 > threshold) offset |= 192;
              }
            } else {
              switch (progress.direction) {
                case ProgressDirection.leftToRight:
                  if (0 < threshold) offset |= 1;
                  if (1 < threshold) offset |= 2;
                  if (2 < threshold) offset |= 4;
                  if (gridCrossAxis < threshold) offset |= 8;
                  if (gridCrossAxis + 1 < threshold) offset |= 16;
                  if (gridCrossAxis + 2 < threshold) offset |= 32;
                  if (3 < threshold) offset |= 64;
                  if (gridCrossAxis + 3 < threshold) offset |= 128;
                case ProgressDirection.rightToLeft:
                  if (0 < threshold) offset |= 1;
                  if (1 < threshold) offset |= 2;
                  if (2 < threshold) offset |= 4;
                  if (-gridCrossAxis < threshold) offset |= 8;
                  if (1 - gridCrossAxis < threshold) offset |= 16;
                  if (2 - gridCrossAxis < threshold) offset |= 32;
                  if (3 < threshold) offset |= 64;
                  if (3 - gridCrossAxis < threshold) offset |= 128;
                case ProgressDirection.topToBottom:
                  if (0 < threshold) offset |= 1;
                  if (gridCrossAxis < threshold) offset |= 2;
                  if (2 * gridCrossAxis < threshold) offset |= 4;
                  if (1 < threshold) offset |= 8;
                  if (gridCrossAxis + 1 < threshold) offset |= 16;
                  if (2 * gridCrossAxis + 1 < threshold) offset |= 32;
                  if (3 * gridCrossAxis < threshold) offset |= 64;
                  if (3 * gridCrossAxis + 1 < threshold) offset |= 128;
                case ProgressDirection.bottomToTop:
                  if (0 < threshold) offset |= 1;
                  if (-gridCrossAxis < threshold) offset |= 2;
                  if (-2 * gridCrossAxis < threshold) offset |= 4;
                  if (1 < threshold) offset |= 8;
                  if (1 - gridCrossAxis < threshold) offset |= 16;
                  if (1 - 2 * gridCrossAxis < threshold) offset |= 32;
                  if (-3 * gridCrossAxis < threshold) offset |= 64;
                  if (1 - 3 * gridCrossAxis < threshold) offset |= 128;
              }
            }
            char = String.fromCharCode(0x2800 + offset);
          } else if (progress.barType == ProgressBarType.quads) {
            if (progress.crossAxisFill == CrossAxisFill.span &&
                progress.smooth) {
              final maxSteps = isHorizontal ? size.width * 4 : size.height * 4;
              final filledSteps = (eased * maxSteps).round();
              final cellSteps = switch (progress.direction) {
                ProgressDirection.leftToRight => filledSteps - (x * 4),
                ProgressDirection.rightToLeft =>
                  filledSteps - ((size.width - 1 - x) * 4),
                ProgressDirection.topToBottom => filledSteps - (y * 4),
                ProgressDirection.bottomToTop =>
                  filledSteps - ((size.height - 1 - y) * 4),
              };

              final clamped = cellSteps.clamp(0, 4);
              if (isHorizontal) {
                const quadStepsH = [' ', '▖', '▌', '▙', '█'];
                char = quadStepsH[clamped];
              } else {
                const quadStepsV = [' ', '▖', '▄', '▙', '█'];
                char = quadStepsV[clamped];
              }
            } else {
              int offset = 0;
              if (isSpan) {
                switch (progress.direction) {
                  case ProgressDirection.leftToRight:
                    if (0 < threshold) offset |= 5; // dx=0: 1 | 4
                    if (1 < threshold) offset |= 10; // dx=1: 2 | 8
                  case ProgressDirection.rightToLeft:
                    if (0 > threshold) offset |= 5;
                    if (1 > threshold) offset |= 10;
                  case ProgressDirection.topToBottom:
                    if (0 < threshold) offset |= 3; // dy=0: 1 | 2
                    if (1 < threshold) offset |= 12; // dy=1: 4 | 8
                  case ProgressDirection.bottomToTop:
                    if (0 > threshold) offset |= 3;
                    if (1 > threshold) offset |= 12;
                }
              } else {
                switch (progress.direction) {
                  case ProgressDirection.leftToRight:
                    if (0 < threshold) offset |= 1;
                    if (1 < threshold) offset |= 4;
                    if (gridCrossAxis < threshold) offset |= 2;
                    if (gridCrossAxis + 1 < threshold) offset |= 8;
                  case ProgressDirection.rightToLeft:
                    if (0 < threshold) offset |= 1;
                    if (1 < threshold) offset |= 4;
                    if (-gridCrossAxis < threshold) offset |= 2;
                    if (1 - gridCrossAxis < threshold) offset |= 8;
                  case ProgressDirection.topToBottom:
                    if (0 < threshold) offset |= 1;
                    if (1 < threshold) offset |= 2;
                    if (gridCrossAxis < threshold) offset |= 4;
                    if (gridCrossAxis + 1 < threshold) offset |= 8;
                  case ProgressDirection.bottomToTop:
                    if (0 < threshold) offset |= 1;
                    if (1 < threshold) offset |= 2;
                    if (-gridCrossAxis < threshold) offset |= 4;
                    if (1 - gridCrossAxis < threshold) offset |= 8;
                }
              }
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
            }
          } else {
            int filledCount = 0;
            if (isSpan) {
              switch (progress.direction) {
                case ProgressDirection.leftToRight:
                  filledCount = threshold.clamp(0, subWidth);
                case ProgressDirection.rightToLeft:
                  filledCount = subWidth - (threshold + 1).clamp(0, subWidth);
                case ProgressDirection.topToBottom:
                  filledCount = threshold.clamp(0, subHeight);
                case ProgressDirection.bottomToTop:
                  filledCount = subHeight - (threshold + 1).clamp(0, subHeight);
              }
            } else {
              for (int dy = 0; dy < subHeight; dy++) {
                for (int dx = 0; dx < subWidth; dx++) {
                  final val = switch (progress.direction) {
                    ProgressDirection.leftToRight => dx * gridCrossAxis + dy,
                    ProgressDirection.rightToLeft => dy - dx * gridCrossAxis,
                    ProgressDirection.topToBottom => dy * gridCrossAxis + dx,
                    ProgressDirection.bottomToTop => dx - dy * gridCrossAxis,
                  };
                  if (val < threshold) filledCount++;
                }
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
