import 'package:termui/termui.dart';

/// A mathematical mutator for 24-bit TrueColor cells.
class ColorMutator {
  /// The scalar to multiply each RGB channel by.
  final double scalar;

  final Map<Color, Color> _cache = {};

  /// Creates a [ColorMutator] with the given [scalar].
  ColorMutator(this.scalar);

  /// Dims the given [color] by multiplying its RGB channels by [scalar].
  Color dim(Color color) {
    if (color.isTransparent) return color;
    final cached = _cache[color];
    if (cached != null) return cached;

    int r = (color.r * scalar).toInt().clamp(0, 255);
    int g = (color.g * scalar).toInt().clamp(0, 255);
    int b = (color.b * scalar).toInt().clamp(0, 255);

    final newColor = Color.argb((color.a << 24) | (r << 16) | (g << 8) | b);
    _cache[color] = newColor;
    return newColor;
  }
}

/// A post-paint mutation applied to the composite terminal buffer.
abstract class TerminalEffect {
  /// Creates a terminal effect.
  const TerminalEffect();

  /// Applies the effect directly to the [target] buffer within [bounds].
  void applyEffect(Buffer target, Rect bounds);
}

/// An effect registered with its layout bounds and stacking order.
class RegisteredEffect {
  /// The effect to apply.
  final TerminalEffect effect;

  /// The bounds to apply the effect within.
  final Rect bounds;

  /// The stacking order from the layer.
  final int zIndex;

  /// The original layer index to ensure stable sorting.
  final int originalIndex;

  /// Creates a registered effect.
  RegisteredEffect(this.effect, this.bounds, this.zIndex, this.originalIndex);
}

/// Options for blending styles in effect helpers.
enum BlendOption {
  /// Replace the target completely.
  replace,

  /// Only replace the color, keep modifiers.
  colorOnly,

  /// Keep existing colors, only add new modifiers.
  addModifiers,
}

/// Helper methods for [TerminalEffect] implementations.
extension EffectHelpers on Buffer {
  /// Rotates a specific row within the given bounds by [amount] rightward.
  void rotateRow(Rect bounds, int rowIndex, int amount) {
    if (rowIndex < 0 || rowIndex >= bounds.height) return;
    if (bounds.width <= 1) return;
    amount = amount % bounds.width;
    if (amount < 0) amount += bounds.width;
    if (amount == 0) return;

    final y = bounds.y + rowIndex;
    if (y < 0 || y >= height) return;

    void swap(int x1, int x2) {
      final cx1 = bounds.x + x1;
      final cx2 = bounds.x + x2;
      if (cx1 >= 0 && cx1 < width && cx2 >= 0 && cx2 < width) {
        final c1 = getCell(cx1, y);
        final c2 = getCell(cx2, y);
        if (c1 != null && c2 != null) {
          final tempChar = c1.char;
          final tempStyle = c1.style;
          c1.char = c2.char;
          c1.style = c2.style;
          c2.char = tempChar;
          c2.style = tempStyle;
        }
      }
    }

    void reverse(int start, int end) {
      while (start < end) {
        swap(start, end);
        start++;
        end--;
      }
    }

    final n = bounds.width;
    reverse(0, n - 1);
    reverse(0, amount - 1);
    reverse(amount, n - 1);
  }

  /// Rotates a specific column within the given bounds by [amount] downward.
  void rotateColumn(Rect bounds, int colIndex, int amount) {
    if (colIndex < 0 || colIndex >= bounds.width) return;
    if (bounds.height <= 1) return;
    amount = amount % bounds.height;
    if (amount < 0) amount += bounds.height;
    if (amount == 0) return;

    final x = bounds.x + colIndex;
    if (x < 0 || x >= width) return;

    void swap(int y1, int y2) {
      final cy1 = bounds.y + y1;
      final cy2 = bounds.y + y2;
      if (cy1 >= 0 && cy1 < height && cy2 >= 0 && cy2 < height) {
        final c1 = getCell(x, cy1);
        final c2 = getCell(x, cy2);
        if (c1 != null && c2 != null) {
          final tempChar = c1.char;
          final tempStyle = c1.style;
          c1.char = c2.char;
          c1.style = c2.style;
          c2.char = tempChar;
          c2.style = tempStyle;
        }
      }
    }

    void reverse(int start, int end) {
      while (start < end) {
        swap(start, end);
        start++;
        end--;
      }
    }

    final n = bounds.height;
    reverse(0, n - 1);
    reverse(0, amount - 1);
    reverse(amount, n - 1);
  }

  /// Fills the foreground style of all cells in [bounds] using [blend].
  void fillForegroundStyle(Rect bounds, Style style, BlendOption blend) {
    for (var y = bounds.y; y < bounds.y + bounds.height; y++) {
      for (var x = bounds.x; x < bounds.x + bounds.width; x++) {
        final cell = getCell(x, y);
        if (cell != null) {
          if (blend == BlendOption.replace) {
            cell.style = style;
          } else if (blend == BlendOption.colorOnly) {
            cell.style = Style(
              foreground: style.foreground ?? cell.style.foreground,
              background: cell.style.background,
              modifiers: cell.style.modifiers,
            );
          } else if (blend == BlendOption.addModifiers) {
            cell.style = Style(
              foreground: cell.style.foreground,
              background: cell.style.background,
              modifiers: cell.style.modifiers | style.modifiers,
            );
          }
        }
      }
    }
  }

  /// Fills the background style of all cells in [bounds] using [blend].
  void fillBackgroundStyle(Rect bounds, Style style, BlendOption blend) {
    for (var y = bounds.y; y < bounds.y + bounds.height; y++) {
      for (var x = bounds.x; x < bounds.x + bounds.width; x++) {
        final cell = getCell(x, y);
        if (cell != null) {
          if (blend == BlendOption.replace) {
            cell.style = style;
          } else if (blend == BlendOption.colorOnly) {
            cell.style = Style(
              foreground: cell.style.foreground,
              background: style.background ?? cell.style.background,
              modifiers: cell.style.modifiers,
            );
          } else if (blend == BlendOption.addModifiers) {
            cell.style = Style(
              foreground: cell.style.foreground,
              background: cell.style.background,
              modifiers: cell.style.modifiers | style.modifiers,
            );
          }
        }
      }
    }
  }
}

/// A wrapper widget that applies a [TerminalEffect] to its descendants post-paint.
class EffectWidget extends Widget {
  /// The effect to apply.
  final TerminalEffect effect;

  /// The child widget.
  final Widget child;

  /// Whether this effect absorbs pointer events.
  final bool absorbPointer;

  /// If true, the effect is applied globally during the Scene compositing phase.
  /// If false, the effect is applied locally to the widget's bounds immediately after paint.
  final bool globalComposite;

  /// Creates an effect widget.
  const EffectWidget({
    super.key,
    required this.effect,
    required this.child,
    this.absorbPointer = false,
    this.globalComposite = true,
  });

  @override
  int getIntrinsicHeight(int width) => child.getIntrinsicHeight(width);

  @override
  int getIntrinsicWidth(int height) => child.getIntrinsicWidth(height);

  @override
  Element createElement() => absorbPointer
      ? AbsorbingEffectWidgetElement(this)
      : EffectWidgetElement(this);
}

/// Element for [EffectWidget] that ignores pointer events.
class EffectWidgetElement extends SingleChildElement {
  /// Creates an effect widget element.
  EffectWidgetElement(EffectWidget super.widget);

  @override
  Widget? get childWidget => (widget as EffectWidget).child;

  @override
  Size performLayout(BoxConstraints constraints) {
    if (childElement != null) {
      final size = childElement!.layout(constraints);
      return size;
    }
    return Size.zero;
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    // 1. Paint children first
    super.performPaint(buffer, offset);

    final effectWidget = widget as EffectWidget;
    final bounds = Rect(offset.dx, offset.dy, size.width, size.height);

    if (effectWidget.globalComposite) {
      // 2a. Register the effect for global compositing
      buffer.addEffect(
        RegisteredEffect(
          effectWidget.effect,
          bounds,
          0, // zIndex filled during compositing
          0, // originalIndex filled during compositing
        ),
      );
    } else {
      // 2b. Apply locally to the child's output immediately
      final effectTraceId = Tracer.registerString(
        'EffectWidget:applyEffect:${effectWidget.effect.runtimeType}',
      );
      Tracer.record(effectTraceId, Phase.begin, TraceCategory.paint);
      try {
        effectWidget.effect.applyEffect(buffer, bounds);
      } finally {
        Tracer.record(effectTraceId, Phase.end, TraceCategory.paint);
      }
    }
  }
}

/// Element for [EffectWidget] that absorbs pointer events.
class AbsorbingEffectWidgetElement extends EffectWidgetElement
    implements MouseEventHandler {
  /// Creates an absorbing effect widget element.
  AbsorbingEffectWidgetElement(super.widget);

  @override
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    // Absorbs pointer events so they don't reach children.
    final effectWidget = widget as EffectWidget;
    if (effectWidget.effect is MouseEventHandler) {
      (effectWidget.effect as MouseEventHandler).handleMouseEvent(
        event,
        localX,
        localY,
      );
    }
  }
}

/// An effect that dims the colors beneath it.
class DimmerEffect extends TerminalEffect {
  /// The scalar to dim colors by.
  final double scalar;
  final ColorMutator _mutator;

  /// Creates a dimmer effect.
  DimmerEffect({this.scalar = 0.5}) : _mutator = ColorMutator(scalar);

  @override
  void applyEffect(Buffer target, Rect bounds) {
    for (var y = bounds.y; y < bounds.y + bounds.height; y++) {
      if (y < 0 || y >= target.height) continue;
      for (var x = bounds.x; x < bounds.x + bounds.width; x++) {
        if (x < 0 || x >= target.width) continue;
        final cell = target.getCell(x, y);
        if (cell != null) {
          final fg = cell.style.foreground;
          final bg = cell.style.background;
          final newFg = fg != null ? _mutator.dim(fg) : null;
          final newBg = bg != null ? _mutator.dim(bg) : null;
          if (newFg != null || newBg != null) {
            cell.style = Style(
              foreground: newFg ?? fg,
              background: newBg ?? bg,
              modifiers: cell.style.modifiers,
            );
          }
        }
      }
    }
  }
}

/// An effect that glitches the runes horizontally.
class GlitchEffect extends TerminalEffect {
  /// A function that returns a random offset for each row.
  final int Function() randomOffset;

  /// Creates a glitch effect.
  const GlitchEffect(this.randomOffset);

  @override
  void applyEffect(Buffer target, Rect bounds) {
    for (var y = 0; y < bounds.height; y++) {
      final offset = randomOffset();
      if (offset != 0) {
        target.rotateRow(bounds, y, offset);
      }
    }
  }
}

/// A modal barrier that dims the layers behind it.
class DimmingBarrier extends StatelessWidget {
  /// The scalar to dim by.
  final double scalar;

  /// Creates a dimming barrier.
  const DimmingBarrier({super.key, this.scalar = 0.5});

  @override
  Widget build(BuildContext context) {
    return EffectWidget(
      effect: DimmerEffect(scalar: scalar),
      globalComposite: true,
      absorbPointer: true,
      child: const SizedBox.expand(),
    );
  }
}
