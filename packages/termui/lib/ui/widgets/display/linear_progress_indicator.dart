import 'package:termui/termui.dart';

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
///   startColor: Color(0xFF00FF00), // Green
///   endColor: Color(0xFFFF0000),   // Red
///   easing: Easing.easeInOutQuad,
/// );
/// ```
///
/// ### Properties and Settings
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `fraction` | [double] | Progress percentage from `0.0` to `1.0`. |
/// | `style` | [Style] | Rendering style (foreground/background color). |
/// | `showPercentage` | [bool] | Overlay the text representation (e.g. "75%"). |
/// | `smooth` | [bool] | Draw fractional widths (1/8 to 7/8 characters). |
/// | `startColor` | [Color]? | Starting color for the horizontal gradient. |
/// | `endColor` | [Color]? | Ending color for the horizontal gradient. |
/// | `easing` | [EasingFunction] | Mathematical formula adjusting progress speed. |
class LinearProgressIndicator extends Widget {
  /// Progress percentage from `0.0` to `1.0`.
  final double fraction; // 0.0 to 1.0

  /// Rendering style (foreground/background color).
  final Style style;

  /// Overlay the text representation (e.g. "75%").
  final bool showPercentage;

  /// Draw fractional widths (1/8 to 7/8 characters).
  final bool smooth;

  /// Starting color for the horizontal gradient.
  final Color? startColor;

  /// Ending color for the horizontal gradient.
  final Color? endColor;

  /// Mathematical formula adjusting progress speed.
  final EasingFunction easing;

  /// Creates a [LinearProgressIndicator].
  const LinearProgressIndicator(
    this.fraction, {
    this.style = Style.empty,
    this.showPercentage = true,
    this.smooth = false,
    this.startColor,
    this.endColor,
    this.easing = Easing.linear,
  });

  /// List of fractional block characters for smooth progress representation.
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

  @override
  Element createElement() => LinearProgressIndicatorElement(this);
}

/// An element that manages the rendering of a [LinearProgressIndicator] widget.
class LinearProgressIndicatorElement extends Element {
  /// Creates a [LinearProgressIndicatorElement] for the given [widget].
  LinearProgressIndicatorElement(LinearProgressIndicator super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final w = constraints.maxWidth == BoxConstraints.infinity
        ? 20
        : constraints.maxWidth;
    return constraints.constrain(Size(w, 1));
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
    final progressVal = (eased * size.width).clamp(0.0, size.width.toDouble());
    final filledWidth = progressVal.floor();

    String? pctText;
    int? pctStartIdx;
    if (progress.showPercentage) {
      pctText = '${(eased * 100).toInt().clamp(0, 100)}%';
      if (pctText.length < size.width - 2) {
        pctStartIdx = ((size.width - pctText.length) / 2).floor();
      } else {
        pctText = null;
      }
    }

    final hasGradient =
        progress.startColor != null && progress.endColor != null;
    var cellStyle = progress.style;

    for (var x = 0; x < size.width; x++) {
      if (hasGradient) {
        final t = size.width > 1 ? x / (size.width - 1) : 0.0;
        final r =
            (progress.startColor!.r +
                    t * (progress.endColor!.r - progress.startColor!.r))
                .round();
        final g =
            (progress.startColor!.g +
                    t * (progress.endColor!.g - progress.startColor!.g))
                .round();
        final b =
            (progress.startColor!.b +
                    t * (progress.endColor!.b - progress.startColor!.b))
                .round();
        cellStyle = Style(
          foreground: Color(r, g, b),
          background: progress.style.background,
          modifiers: progress.style.modifiers,
        );
      }

      String char = '░';

      if (pctText != null &&
          pctStartIdx != null &&
          x >= pctStartIdx &&
          x < pctStartIdx + pctText.length) {
        char = pctText[x - pctStartIdx];
      } else {
        if (x < filledWidth) {
          char = '█';
        } else if (x == filledWidth) {
          final remainder = progressVal - filledWidth;
          if (progress.smooth) {
            final idx = (remainder * 8).round() - 1;
            if (idx >= 0 && idx < 8) {
              char = LinearProgressIndicator.eighths[idx];
            } else if (idx >= 8) {
              char = '█';
            }
          } else {
            if (remainder >= 0.5) {
              char = '█';
            }
          }
        }
      }

      final cell = viewport.getCell(x, 0);
      if (cell != null) {
        cell.char = char;
        cell.style = cellStyle;
      }
    }
  }
}
