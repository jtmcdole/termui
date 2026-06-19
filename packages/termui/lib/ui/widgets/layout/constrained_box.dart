import 'package:termui/termui.dart';

/// Undocumented public member.
class ConstrainedBox extends Widget {
  /// The additional constraints to impose on the child.
  final BoxConstraints constraints;

  /// The child widget.
  final Widget child;

  /// Creates a widget that imposes additional constraints on its child.
  const ConstrainedBox({required this.constraints, required this.child});

  @override
  Element createElement() => ConstrainedBoxElement(this);

  @override
  int getIntrinsicHeight(int width) {
    final w = width.clamp(constraints.minWidth, constraints.maxWidth);
    final h = child.getIntrinsicHeight(w);
    return h.clamp(constraints.minHeight, constraints.maxHeight);
  }
}

/// An element that manages a [ConstrainedBox] widget.
class ConstrainedBoxElement extends Element {
  /// The child element.
  Element? childElement;

  /// Creates a constrained box element for a [ConstrainedBox] widget.
  ConstrainedBoxElement(ConstrainedBox super.widget);

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
    final cb = widget as ConstrainedBox;
    if (childElement != null &&
        childElement!.widget.runtimeType == cb.child.runtimeType) {
      childElement!.update(cb.child);
    } else {
      childElement?.unmount();
      childElement = cb.child.createElement();
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
    final cb = widget as ConstrainedBox;
    final childConstraints = constraints.enforce(cb.constraints);
    if (childElement != null) {
      final size = childElement!.layout(childConstraints);
      childElement!.relativeOffset = Offset.zero;
      return size;
    }
    return childConstraints.constrain(Size.zero);
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

/// Controls how a child widget of a [Row] or [Column] scales.
