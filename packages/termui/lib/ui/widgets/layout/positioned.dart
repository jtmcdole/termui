import 'package:termui/termui.dart';

/// Undocumented public member.
class Positioned extends Widget {
  /// The distance from the left edge.
  final int? left;

  /// The distance from the top edge.
  final int? top;

  /// The distance from the right edge.
  final int? right;

  /// The distance from the bottom edge.
  final int? bottom;

  /// The constrained width.
  final int? width;

  /// The constrained height.
  final int? height;

  /// Whether this positioned widget should be centered in the stack.
  final bool isCentered;

  /// The child widget.
  final Widget child;

  /// Creates a positioned widget to place a [child] inside a [Stack].
  const Positioned({
    this.left,
    this.top,
    this.right,
    this.bottom,
    this.width,
    this.height,
    required this.child,
  }) : isCentered = false;

  /// Creates a centered positioned widget inside a [Stack].
  const Positioned.center({this.width, this.height, required this.child})
    : left = null,
      top = null,
      right = null,
      bottom = null,
      isCentered = true;

  @override
  Element createElement() => PositionedElement(this);

  @override
  int getIntrinsicHeight(int width) {
    if (height != null) return height!;
    return child.getIntrinsicHeight(width);
  }
}

/// An element that manages a [Positioned] widget.
class PositionedElement extends Element {
  /// The child element.
  Element? childElement;

  /// Creates a positioned element for a [Positioned] widget.
  PositionedElement(Positioned super.widget);

  @override
  void mount(Element? parent) {
    super.mount(parent);
    rebuild();
  }

  @override
  void update(Widget newWidget) {
    super.update(newWidget);
    rebuild();
  }

  @override
  void rebuild() {
    final pos = widget as Positioned;
    if (childElement != null &&
        childElement!.widget.runtimeType == pos.child.runtimeType) {
      childElement!.update(pos.child);
    } else {
      childElement?.unmount();
      childElement = pos.child.createElement();
      childElement!.mount(this);
    }
  }

  @override
  void unmount() {
    childElement?.unmount();
    super.unmount();
  }

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
    if (childElement != null) {
      childElement!.paint(buffer, offset + childElement!.relativeOffset);
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement != null) visitor(childElement!);
  }
}

/// A widget that imposes tight constraints on its child.
