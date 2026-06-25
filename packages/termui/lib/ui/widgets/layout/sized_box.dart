import 'package:termui/termui.dart';

/// Undocumented public member.
class SizedBox extends Widget {
  /// The constrained width.
  final int? width;

  /// The constrained height.
  final int? height;

  /// The child widget.
  final Widget? child;

  /// Creates a sized box to enforce [width] and [height].
  const SizedBox({this.width, this.height, this.child});

  /// Creates a sized box with 0 width and height.
  const SizedBox.shrink({this.child}) : width = 0, height = 0;

  /// Creates a sized box that expands to fit its parent.
  const SizedBox.expand({this.child})
    : width = BoxConstraints.infinity,
      height = BoxConstraints.infinity;

  @override
  Element createElement() => SizedBoxElement(this);

  @override
  int getIntrinsicHeight(int width) {
    if (height != null) return height!;
    if (child != null) {
      return child!.getIntrinsicHeight(this.width ?? width);
    }
    return 0;
  }

  @override
  int getIntrinsicWidth(int height) {
    if (width != null) return width!;
    if (child != null) {
      return child!.getIntrinsicWidth(this.height ?? height);
    }
    return 0;
  }
}

/// An element that manages a [SizedBox] widget.
class SizedBoxElement extends SingleChildElement {
  /// Creates a sized box element for a [SizedBox] widget.
  SizedBoxElement(SizedBox super.widget);

  @override
  Widget? get childWidget => (widget as SizedBox).child;

  @override
  Size performLayout(BoxConstraints constraints) {
    final sb = widget as SizedBox;
    final tightened = constraints.tighten(width: sb.width, height: sb.height);
    if (childElement != null) {
      final childSize = childElement!.layout(tightened);
      childElement!.relativeOffset = Offset.zero;
      return childSize;
    }
    return tightened.constrain(Size.zero);
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    if (childElement != null) {
      childElement!.paint(buffer, offset + childElement!.relativeOffset);
    }
  }

  @override
  int getIntrinsicHeight(int width) {
    final sb = widget as SizedBox;
    if (sb.height != null) return sb.height!;
    return childElement?.getIntrinsicHeight(sb.width ?? width) ?? 0;
  }

  @override
  int getIntrinsicWidth(int height) {
    final sb = widget as SizedBox;
    if (sb.width != null) return sb.width!;
    return childElement?.getIntrinsicWidth(sb.height ?? height) ?? 0;
  }
}

/// A widget that imposes [BoxConstraints] on its child.
