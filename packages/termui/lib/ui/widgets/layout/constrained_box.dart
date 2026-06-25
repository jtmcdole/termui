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

  @override
  int getIntrinsicWidth(int height) {
    final h = height.clamp(constraints.minHeight, constraints.maxHeight);
    final w = child.getIntrinsicWidth(h);
    return w.clamp(constraints.minWidth, constraints.maxWidth);
  }
}

/// An element that manages a [ConstrainedBox] widget.
class ConstrainedBoxElement extends SingleChildElement {
  /// Creates a constrainedbox element for a [ConstrainedBox] widget.
  ConstrainedBoxElement(ConstrainedBox super.widget);

  @override
  Widget? get childWidget => (widget as ConstrainedBox).child;

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

  @override
  int getIntrinsicHeight(int width) {
    final cb = widget as ConstrainedBox;
    final w = width.clamp(cb.constraints.minWidth, cb.constraints.maxWidth);
    final h = childElement?.getIntrinsicHeight(w) ?? 0;
    return h.clamp(cb.constraints.minHeight, cb.constraints.maxHeight);
  }

  @override
  int getIntrinsicWidth(int height) {
    final cb = widget as ConstrainedBox;
    final h = height.clamp(cb.constraints.minHeight, cb.constraints.maxHeight);
    final w = childElement?.getIntrinsicWidth(h) ?? 0;
    return w.clamp(cb.constraints.minWidth, cb.constraints.maxWidth);
  }
}

/// Controls how a child widget of a [Row] or [Column] scales.
