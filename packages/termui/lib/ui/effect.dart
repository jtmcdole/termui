import 'package:termui/termui.dart';

/// A mathematical mutator for 24-bit TrueColor cells.
class ColorMutator {
  /// The scalar to multiply each RGB channel by.
  final double scalar;

  /// Creates a [ColorMutator] with the given [scalar].
  const ColorMutator(this.scalar);

  /// Dims the raw packed 32-bit integer color without allocating Color objects.
  int dimPacked(int argb) {
    if (argb == 0) return 0;

    final int a = (argb >> 24) & 0xFF;
    if (a == 0) return argb;

    final int r = (((argb >> 16) & 0xFF) * scalar).toInt().clamp(0, 255);
    final int g = (((argb >> 8) & 0xFF) * scalar).toInt().clamp(0, 255);
    final int b = ((argb & 0xFF) * scalar).toInt().clamp(0, 255);

    return (a << 24) | (r << 16) | (g << 8) | b;
  }

  /// Dims the given [color] by multiplying its RGB channels by [scalar].
  Color dim(Color color) {
    return Color.argb(dimPacked(color.argb));
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

    final n = bounds.width;
    _reverseRow(bounds.x, y, 0, n - 1);
    _reverseRow(bounds.x, y, 0, amount - 1);
    _reverseRow(bounds.x, y, amount, n - 1);
  }

  void _reverseRow(int startX, int y, int start, int end) {
    final rowOffset = y * width;
    while (start < end) {
      final cx1 = startX + start;
      final cx2 = startX + end;
      if (cx1 >= 0 && cx1 < width && cx2 >= 0 && cx2 < width) {
        final idx1 = rowOffset + cx1;
        final idx2 = rowOffset + cx2;

        final tempChar = characters[idx1];
        final tempFg = fgColors[idx1];
        final tempBg = bgColors[idx1];
        final tempMod = modifiers[idx1];

        characters[idx1] = characters[idx2];
        fgColors[idx1] = fgColors[idx2];
        bgColors[idx1] = bgColors[idx2];
        modifiers[idx1] = modifiers[idx2];

        characters[idx2] = tempChar;
        fgColors[idx2] = tempFg;
        bgColors[idx2] = tempBg;
        modifiers[idx2] = tempMod;
      }
      start++;
      end--;
    }
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

    final n = bounds.height;
    _reverseCol(x, bounds.y, 0, n - 1);
    _reverseCol(x, bounds.y, 0, amount - 1);
    _reverseCol(x, bounds.y, amount, n - 1);
  }

  void _reverseCol(int x, int startY, int start, int end) {
    while (start < end) {
      final cy1 = startY + start;
      final cy2 = startY + end;
      if (cy1 >= 0 && cy1 < height && cy2 >= 0 && cy2 < height) {
        final idx1 = cy1 * width + x;
        final idx2 = cy2 * width + x;

        final tempChar = characters[idx1];
        final tempFg = fgColors[idx1];
        final tempBg = bgColors[idx1];
        final tempMod = modifiers[idx1];

        characters[idx1] = characters[idx2];
        fgColors[idx1] = fgColors[idx2];
        bgColors[idx1] = bgColors[idx2];
        modifiers[idx1] = modifiers[idx2];

        characters[idx2] = tempChar;
        fgColors[idx2] = tempFg;
        bgColors[idx2] = tempBg;
        modifiers[idx2] = tempMod;
      }
      start++;
      end--;
    }
  }

  /// Fills the foreground style of all cells in [bounds] using [blend].
  void fillForegroundStyle(Rect bounds, Style style, BlendOption blend) {
    final fgVal = style.foreground?.argb ?? 0;
    final styleMods = style.modifiers;
    for (var y = bounds.y; y < bounds.y + bounds.height; y++) {
      if (y < 0 || y >= height) continue;
      final rowOffset = y * width;
      for (var x = bounds.x; x < bounds.x + bounds.width; x++) {
        if (x < 0 || x >= width) continue;
        final idx = rowOffset + x;
        if (blend == BlendOption.replace) {
          fgColors[idx] = fgVal;
          bgColors[idx] = style.background?.argb ?? 0;
          modifiers[idx] = styleMods;
        } else if (blend == BlendOption.colorOnly) {
          if (fgVal != 0) {
            fgColors[idx] = fgVal;
          }
        } else if (blend == BlendOption.addModifiers) {
          modifiers[idx] |= styleMods;
        }
      }
    }
  }

  /// Fills the background style of all cells in [bounds] using [blend].
  void fillBackgroundStyle(Rect bounds, Style style, BlendOption blend) {
    final bgVal = style.background?.argb ?? 0;
    final styleMods = style.modifiers;
    for (var y = bounds.y; y < bounds.y + bounds.height; y++) {
      if (y < 0 || y >= height) continue;
      final rowOffset = y * width;
      for (var x = bounds.x; x < bounds.x + bounds.width; x++) {
        if (x < 0 || x >= width) continue;
        final idx = rowOffset + x;
        if (blend == BlendOption.replace) {
          fgColors[idx] = style.foreground?.argb ?? 0;
          bgColors[idx] = bgVal;
          modifiers[idx] = styleMods;
        } else if (blend == BlendOption.colorOnly) {
          if (bgVal != 0) {
            bgColors[idx] = bgVal;
          }
        } else if (blend == BlendOption.addModifiers) {
          modifiers[idx] |= styleMods;
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

  /// If true, the effect is applied globally during the Scene compositing phase.
  /// If false, the effect is applied locally to the widget's bounds immediately after paint.
  final bool globalComposite;

  /// Creates an effect widget.
  const EffectWidget({
    super.key,
    required this.effect,
    required this.child,
    this.globalComposite = true,
  });

  @override
  int getIntrinsicHeight(int width) => child.getIntrinsicHeight(width);

  @override
  int getIntrinsicWidth(int height) => child.getIntrinsicWidth(height);

  @override
  Element createElement() => EffectWidgetElement(this);
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
      childElement!.relativeOffset = Offset.zero;
      return size;
    }
    return constraints.constrain(Size.zero);
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
/// An effect that dims the colors beneath it.
class DimmerEffect extends TerminalEffect {
  /// The scalar to dim colors by.
  final double scalar;

  /// Creates a dimmer effect.
  const DimmerEffect({this.scalar = 0.5});

  @override
  void applyEffect(Buffer target, Rect bounds) {
    final mutator = ColorMutator(scalar);
    for (var y = bounds.y; y < bounds.y + bounds.height; y++) {
      if (y < 0 || y >= target.height) continue;
      final rowOffset = y * target.width;
      for (var x = bounds.x; x < bounds.x + bounds.width; x++) {
        if (x < 0 || x >= target.width) continue;
        final idx = rowOffset + x;
        if ((target.modifiers[idx] & Modifier.transparent) != 0) continue;

        final fg = target.fgColors[idx];
        if (fg != 0) {
          target.fgColors[idx] = mutator.dimPacked(fg);
        }

        final bg = target.bgColors[idx];
        if (bg != 0) {
          target.bgColors[idx] = mutator.dimPacked(bg);
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
    return AbsorbPointer(
      child: EffectWidget(
        effect: DimmerEffect(scalar: scalar),
        globalComposite: true,
        child: const SizedBox.expand(),
      ),
    );
  }
}
