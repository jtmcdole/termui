import 'package:termui/termui.dart';

/// How a box should be inscribed into another box.
enum BoxFit {
  /// Constrain the child to be no larger than the available space.
  contain,

  /// Constrain the child to be at least as large as the available space.
  cover,

  /// Do not constrain the child at all, allowing it to size to its intrinsic dimensions.
  none,
}

/// Different ways to clip a widget's content.
enum Clip {
  /// No clip at all. Content may overflow the widget's bounds.
  none,

  /// Clip the content to the widget's layout boundaries by dropping overflowing cells.
  hardEdge,
}

/// A widget that sizes and positions its child within itself according to [fit].
///
/// In a terminal context where scaling vector fonts is not physically possible,
/// this widget enforces layout constraints and provides strict cell-dropping
/// truncation when [clipBehavior] is [Clip.hardEdge].
class FittedBox extends Widget {
  /// How to inscribe the child into the available space.
  final BoxFit fit;

  /// How to align the child within the available space.
  final Alignment alignment;

  /// How to clip the content.
  final Clip clipBehavior;

  /// The child widget.
  final Widget child;

  /// Creates a [FittedBox].
  const FittedBox({
    super.key,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.clipBehavior = Clip.none,
    required this.child,
  });

  @override
  Element createElement() => _FittedBoxElement(this);
}

class _FittedBoxElement extends Element {
  Element? _childElement;

  _FittedBoxElement(FittedBox super.widget);

  @override
  void mount(Element? parent) {
    super.mount(parent);
    final w = widget as FittedBox;
    _childElement = w.child.createElement();
    _childElement!.mount(this);
  }

  @override
  void update(Widget newWidget) {
    super.update(newWidget);
    final w = widget as FittedBox;
    if (_childElement != null) {
      if (Widget.canUpdate(_childElement!.widget, w.child)) {
        _childElement!.update(w.child);
      } else {
        _childElement!.unmount();
        _childElement = w.child.createElement();
        _childElement!.mount(this);
      }
    }
  }

  @override
  void unmount() {
    _childElement?.unmount();
    _childElement = null;
    super.unmount();
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    if (_childElement != null) {
      final w = widget as FittedBox;
      BoxConstraints childConstraints;

      switch (w.fit) {
        case BoxFit.contain:
          childConstraints = BoxConstraints(
            minWidth: 0,
            maxWidth: constraints.maxWidth,
            minHeight: 0,
            maxHeight: constraints.maxHeight,
          );
          break;
        case BoxFit.cover:
          childConstraints = BoxConstraints(
            minWidth: constraints.hasBoundedWidth ? constraints.maxWidth : 0,
            maxWidth: BoxConstraints.infinity,
            minHeight: constraints.hasBoundedHeight ? constraints.maxHeight : 0,
            maxHeight: BoxConstraints.infinity,
          );
          break;
        case BoxFit.none:
          childConstraints = const BoxConstraints();
          break;
      }

      final childSize = _childElement!.layout(childConstraints);

      int width = childSize.width;
      int height = childSize.height;

      if (w.fit == BoxFit.contain || w.fit == BoxFit.cover) {
        width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : childSize.width;
        height = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : childSize.height;
      }

      final boxSize = constraints.constrain(Size(width, height));

      final wDiff = boxSize.width - childSize.width;
      final hDiff = boxSize.height - childSize.height;

      final dx = (wDiff / 2.0 * (w.alignment.x + 1.0)).round();
      final dy = (hDiff / 2.0 * (w.alignment.y + 1.0)).round();

      _childElement!.relativeOffset = Offset(dx, dy);

      return boxSize;
    }
    return constraints.constrain(Size.zero);
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    if (_childElement == null) return;

    final w = widget as FittedBox;
    final dx = _childElement!.relativeOffset.dx;
    final dy = _childElement!.relativeOffset.dy;

    if (w.clipBehavior == Clip.hardEdge) {
      if (size.width <= 0 || size.height <= 0) return;

      // We unconditionally use a virtual buffer because declarative UI layout sizes
      // DO NOT guarantee paint boundaries. Children (or their effects) may paint outside
      // their reported layout size, and Clip.hardEdge MUST intercept them.
      final virtualBuffer = Buffer.blank(size.width, size.height);
      _childElement!.paint(virtualBuffer, Offset(dx, dy));

      for (var y = 0; y < size.height; y++) {
        for (var x = 0; x < size.width; x++) {
          final char = virtualBuffer.getCharacter(x, y);
          final modifiers = virtualBuffer.getModifiers(x, y);
          final isTransparent = (modifiers & Modifier.transparent) != 0;
          if (char != ' ' || !isTransparent) {
            final targetFg = buffer.getForeground(offset.dx + x, offset.dy + y);
            final targetBg = buffer.getBackground(offset.dx + x, offset.dy + y);
            final targetModifiers = buffer.getModifiers(
              offset.dx + x,
              offset.dy + y,
            );

            final vFg = virtualBuffer.getForeground(x, y);
            final vBg = virtualBuffer.getBackground(x, y);

            var nextModifiers = targetModifiers | modifiers;
            if ((modifiers & Modifier.transparent) == 0) {
              nextModifiers &= ~Modifier.transparent;
            }

            buffer.setAttributes(
              offset.dx + x,
              offset.dy + y,
              char: char,
              fg: vFg != 0 ? vFg : targetFg,
              bg: vBg != 0 ? vBg : targetBg,
              modifiers: nextModifiers,
            );
          }
        }
      }

      for (final e in virtualBuffer.effects) {
        // Intersect the effect bounds with the clipping boundaries of the FittedBox
        final int ix = e.bounds.x < 0 ? 0 : e.bounds.x;
        final int iy = e.bounds.y < 0 ? 0 : e.bounds.y;

        final int right = e.bounds.x + e.bounds.width;
        final int bottom = e.bounds.y + e.bounds.height;

        final int iright = right > size.width ? size.width : right;
        final int ibottom = bottom > size.height ? size.height : bottom;

        final int iw = iright - ix;
        final int ih = ibottom - iy;

        if (iw > 0 && ih > 0) {
          buffer.addEffect(
            RegisteredEffect(
              e.effect,
              Rect(offset.dx + ix, offset.dy + iy, iw, ih),
              e.zIndex,
              e.originalIndex,
            ),
          );
        }
      }
    } else {
      _childElement!.paint(buffer, offset + _childElement!.relativeOffset);
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (_childElement != null) visitor(_childElement!);
  }

  @override
  int getIntrinsicHeight(int width) =>
      _childElement?.getIntrinsicHeight(width) ?? 0;

  @override
  int getIntrinsicWidth(int height) =>
      _childElement?.getIntrinsicWidth(height) ?? 0;
}
