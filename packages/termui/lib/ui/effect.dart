import 'dart:math';
import 'dart:typed_data';
import 'package:termui/termui.dart';

/// A mathematical mutator for 24-bit TrueColor and [Color.ansi] cells.
final class ColorMutator {
  /// The scalar to multiply each RGB channel by (or interpolation weight toward [barrierColor]).
  final double scalar;

  /// Optional backdrop color to blend toward instead of `#000000`.
  final Color? barrierColor;

  /// Palette used when resolving [Color.ansi] indices before dimming.
  final TerminalColorTheme palette;

  /// Creates a [ColorMutator] with the given [scalar].
  const ColorMutator(
    this.scalar, {
    this.barrierColor,
    this.palette = TerminalColorTheme.legacyVga,
  });

  /// Dims the raw packed 32-bit integer color without allocating Color objects.
  int dimPacked(int argb) {
    if (argb == 0) return 0;

    final resolved = argb.isAnsiIndexed
        ? palette.resolvePackedColor(argb)
        : argb;
    final int a = (resolved >> 24) & 0xFF;
    if (a == 0) return argb;

    final int r = (resolved >> 16) & 0xFF;
    final int g = (resolved >> 8) & 0xFF;
    final int b = resolved & 0xFF;

    final barrier = barrierColor;
    if (barrier != null) {
      final inv = 1.0 - scalar;
      final outR = (r * scalar + barrier.r * inv).round().clamp(0, 255);
      final outG = (g * scalar + barrier.g * inv).round().clamp(0, 255);
      final outB = (b * scalar + barrier.b * inv).round().clamp(0, 255);
      return (a << 24) | (outR << 16) | (outG << 8) | outB;
    }

    final int outR = (r * scalar).toInt().clamp(0, 255);
    final int outG = (g * scalar).toInt().clamp(0, 255);
    final int outB = (b * scalar).toInt().clamp(0, 255);

    return (a << 24) | (outR << 16) | (outG << 8) | outB;
  }

  /// Dims the given [color] by multiplying its RGB channels by [scalar].
  Color dim(Color color) {
    return Color.argb(dimPacked(color.argb));
  }
}

/// A post-paint mutation applied to the composite terminal buffer.
abstract base class TerminalEffect {
  /// Creates a terminal effect.
  const TerminalEffect();

  /// Applies the effect directly to the [target] buffer within [bounds].
  void applyEffect(Buffer target, Rect bounds);
}

/// An effect registered with its layout bounds and stacking order.
final class RegisteredEffect {
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
    while (start < end) {
      final cx1 = startX + start;
      final cx2 = startX + end;
      if (cx1 >= 0 && cx1 < width && cx2 >= 0 && cx2 < width) {
        _swapCells(cx1, y, cx2, y);
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
        _swapCells(x, cy1, x, cy2);
      }
      start++;
      end--;
    }
  }

  void _swapCells(int x1, int y1, int x2, int y2) {
    final idx1 = y1 * width + x1;
    final idx2 = y2 * width + x2;
    final idx1Attr = idx1 * 3;
    final idx2Attr = idx2 * 3;

    final tempChar = characters[idx1];
    final tempFg = attributes[idx1Attr + 0];
    final tempBg = attributes[idx1Attr + 1];
    final tempMod = attributes[idx1Attr + 2];

    characters[idx1] = characters[idx2];
    attributes[idx1Attr + 0] = attributes[idx2Attr + 0];
    attributes[idx1Attr + 1] = attributes[idx2Attr + 1];
    attributes[idx1Attr + 2] = attributes[idx2Attr + 2];

    characters[idx2] = tempChar;
    attributes[idx2Attr + 0] = tempFg;
    attributes[idx2Attr + 1] = tempBg;
    attributes[idx2Attr + 2] = tempMod;

    if (hasUnderlineColors) {
      final tempUl = getUnderlineColor(x1, y1);
      setUnderlineColor(x1, y1, getUnderlineColor(x2, y2));
      setUnderlineColor(x2, y2, tempUl);
    }
    if (hasUris) {
      final tempUri = getUri(x1, y1);
      setUri(x1, y1, getUri(x2, y2));
      setUri(x2, y2, tempUri);
    }
  }

  /// Fills the foreground style of all cells in [bounds] using [blend].
  void fillForegroundStyle(Rect bounds, Style style, BlendOption blend) {
    final fgVal = style.foreground?.argb ?? 0;
    final styleMods = style.modifiers;
    final startY = max(0, bounds.y);
    final endY = min(height, bounds.y + bounds.height);
    final startX = max(0, bounds.x);
    final endX = min(width, bounds.x + bounds.width);

    if (startX >= endX || startY >= endY) return;

    for (var y = startY; y < endY; y++) {
      final rowOffset = y * width;
      for (var x = startX; x < endX; x++) {
        final idx = rowOffset + x;
        final attrIdx = idx * 3;
        if (blend == BlendOption.replace) {
          attributes[attrIdx + 0] = fgVal;
          attributes[attrIdx + 1] = style.background?.argb ?? 0;
          attributes[attrIdx + 2] = styleMods;
        } else if (blend == BlendOption.colorOnly) {
          if (fgVal != 0) {
            attributes[attrIdx + 0] = fgVal;
          }
        } else if (blend == BlendOption.addModifiers) {
          attributes[attrIdx + 2] = Modifier.mergeLayered(
            styleMods,
            attributes[attrIdx + 2],
          );
        }
      }
    }
  }

  /// Fills the background style of all cells in [bounds] using [blend].
  void fillBackgroundStyle(Rect bounds, Style style, BlendOption blend) {
    final bgVal = style.background?.argb ?? 0;
    final styleMods = style.modifiers;
    final startY = max(0, bounds.y);
    final endY = min(height, bounds.y + bounds.height);
    final startX = max(0, bounds.x);
    final endX = min(width, bounds.x + bounds.width);

    if (startX >= endX || startY >= endY) return;

    for (var y = startY; y < endY; y++) {
      final rowOffset = y * width;
      for (var x = startX; x < endX; x++) {
        final idx = rowOffset + x;
        final attrIdx = idx * 3;
        if (blend == BlendOption.replace) {
          attributes[attrIdx + 0] = style.foreground?.argb ?? 0;
          attributes[attrIdx + 1] = bgVal;
          attributes[attrIdx + 2] = styleMods;
        } else if (blend == BlendOption.colorOnly) {
          if (bgVal != 0) {
            attributes[attrIdx + 1] = bgVal;
          }
        } else if (blend == BlendOption.addModifiers) {
          attributes[attrIdx + 2] = Modifier.mergeLayered(
            styleMods,
            attributes[attrIdx + 2],
          );
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
/// A terminal effect that dims the colors of all cells in its bounds.
final class DimmerEffect extends TerminalEffect {
  /// The scalar to dim colors by.
  final double scalar;

  /// Optional backdrop color to blend toward instead of `#000000`.
  final Color? barrierColor;

  /// Optional fallback foreground used when dimming default (`fg == 0`) cells.
  final Color? defaultForeground;

  /// Optional fallback background used when dimming default (`bg == 0`) cells.
  final Color? defaultBackground;

  /// Palette used when resolving [Color.ansi] indices before dimming.
  final TerminalColorTheme palette;

  /// Creates a dimmer effect.
  const DimmerEffect({
    this.scalar = 0.5,
    this.barrierColor,
    this.defaultForeground,
    this.defaultBackground,
    this.palette = TerminalColorTheme.legacyVga,
  });

  @override
  void applyEffect(Buffer target, Rect bounds) {
    final startY = max(0, bounds.y);
    final endY = min(target.height, bounds.y + bounds.height);
    final startX = max(0, bounds.x);
    final endX = min(target.width, bounds.x + bounds.width);
    if (startX >= endX || startY >= endY) return;

    final mutator = ColorMutator(
      scalar,
      barrierColor: barrierColor,
      palette: palette,
    );
    final defFg = defaultForeground?.argb ?? 0;
    final defBg = defaultBackground?.argb ?? 0;
    final attrs = target.attributes;
    final width = target.width;

    for (var y = startY; y < endY; y++) {
      final rowOffset = y * width;
      for (var x = startX; x < endX; x++) {
        _dimCell(
          attrs,
          (rowOffset + x) * 3,
          mutator,
          defFg: defFg,
          defBg: defBg,
        );
      }
    }
  }

  @pragma('vm:prefer-inline')
  static void _dimCell(
    Uint32List attrs,
    int attrIdx,
    ColorMutator mutator, {
    required int defFg,
    required int defBg,
  }) {
    final mods = attrs[attrIdx + 2];
    if ((mods & Modifier.transparent) != 0) return;

    final fg = attrs[attrIdx];
    final effectiveFg = fg != 0 ? fg : defFg;
    if (effectiveFg != 0 && (mods & Modifier.kittyPlaceholder) == 0) {
      attrs[attrIdx] = mutator.dimPacked(effectiveFg);
    }

    final bg = attrs[attrIdx + 1];
    final effectiveBg = bg != 0 ? bg : defBg;
    if (effectiveBg != 0) {
      attrs[attrIdx + 1] = mutator.dimPacked(effectiveBg);
    }
  }
}

/// A terminal effect that randomly shifts horizontal character rows within bounds.
final class GlitchEffect extends TerminalEffect {
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

  /// Optional backdrop color to blend toward instead of `#000000`.
  final Color? barrierColor;

  /// Optional fallback foreground used when dimming default (`fg == 0`) cells.
  final Color? defaultForeground;

  /// Optional fallback background used when dimming default (`bg == 0`) cells.
  final Color? defaultBackground;

  /// Palette used when resolving [Color.ansi] indices before dimming.
  final TerminalColorTheme palette;

  /// Creates a dimming barrier.
  const DimmingBarrier({
    super.key,
    this.scalar = 0.5,
    this.barrierColor,
    this.defaultForeground,
    this.defaultBackground,
    this.palette = TerminalColorTheme.legacyVga,
  });

  @override
  Widget build(BuildContext context) {
    return AbsorbPointer(
      child: EffectWidget(
        effect: DimmerEffect(
          scalar: scalar,
          barrierColor: barrierColor,
          defaultForeground: defaultForeground,
          defaultBackground: defaultBackground,
          palette: palette,
        ),
        globalComposite: true,
        child: const SizedBox.expand(),
      ),
    );
  }
}
