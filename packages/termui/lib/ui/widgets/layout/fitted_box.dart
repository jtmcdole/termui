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
    this.fit = .contain,
    this.alignment = .center,
    this.clipBehavior = .none,
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
      final childConstraints = switch (w.fit) {
        BoxFit.contain => BoxConstraints(
          minWidth: 0,
          maxWidth: constraints.maxWidth,
          minHeight: 0,
          maxHeight: constraints.maxHeight,
        ),
        BoxFit.cover => BoxConstraints(
          minWidth: constraints.hasBoundedWidth ? constraints.maxWidth : 0,
          maxWidth: BoxConstraints.infinity,
          minHeight: constraints.hasBoundedHeight ? constraints.maxHeight : 0,
          maxHeight: BoxConstraints.infinity,
        ),
        BoxFit.none => const BoxConstraints(),
      };

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
      _blitHardEdgeBuffer(
        buffer,
        virtualBuffer,
        offset,
        size.width,
        size.height,
      );
      buffer.propagateMetadataFrom(
        virtualBuffer,
        dx: offset.dx,
        dy: offset.dy,
        clip: Rect(offset.dx, offset.dy, size.width, size.height),
      );
    } else {
      _childElement!.paint(buffer, offset + _childElement!.relativeOffset);
    }
  }

  static void _blitHardEdgeBuffer(
    Buffer buffer,
    Buffer virtualBuffer,
    Offset offset,
    int w,
    int h,
  ) {
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        _mergeHardEdgeCell(
          buffer,
          virtualBuffer,
          x,
          y,
          offset.dx + x,
          offset.dy + y,
        );
      }
    }
  }

  static void _mergeHardEdgeCell(
    Buffer buffer,
    Buffer virtualBuffer,
    int x,
    int y,
    int dstX,
    int dstY,
  ) {
    final char = virtualBuffer.getCharacter(x, y);
    final modifiers = virtualBuffer.getModifiers(x, y);
    final isTransparent = (modifiers & Modifier.transparent) != 0;
    if (char == ' ' && isTransparent) return;

    final targetFg = buffer.getForeground(dstX, dstY);
    final targetBg = buffer.getBackground(dstX, dstY);
    final targetModifiers = buffer.getModifiers(dstX, dstY);
    final vFg = virtualBuffer.getForeground(x, y);
    final vBg = virtualBuffer.getBackground(x, y);
    final vUl = virtualBuffer.getUnderlineColor(x, y);
    final vUri = virtualBuffer.getUri(x, y);

    var nextModifiers = Modifier.mergeLayered(modifiers, targetModifiers);
    if (!isTransparent) {
      nextModifiers &= ~Modifier.transparent;
    }

    buffer.setAttributes(
      dstX,
      dstY,
      char: char,
      fg: vFg != 0 ? vFg : targetFg,
      bg: vBg != 0 ? vBg : targetBg,
      modifiers: nextModifiers,
      underlineColor: vUl != 0 ? vUl : buffer.getUnderlineColor(dstX, dstY),
      uri: vUri ?? buffer.getUri(dstX, dstY),
    );
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
