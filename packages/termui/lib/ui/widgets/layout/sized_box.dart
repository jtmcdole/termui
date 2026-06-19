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
}

/// An element that manages a [SizedBox] widget.
class SizedBoxElement extends Element {
  /// The child element.
  Element? childElement;

  /// Creates a sized box element for a [SizedBox] widget.
  SizedBoxElement(SizedBox super.widget);

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
    final sb = widget as SizedBox;
    if (sb.child != null) {
      if (childElement != null &&
          childElement!.widget.runtimeType == sb.child!.runtimeType) {
        childElement!.update(sb.child!);
      } else {
        childElement?.unmount();
        childElement = sb.child!.createElement();
        childElement!.mount(this);
      }
    } else {
      childElement?.unmount();
      childElement = null;
    }
  }

  @override
  void unmount() {
    childElement?.unmount();
    super.unmount();
  }

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
  void visitChildren(void Function(Element child) visitor) {
    if (childElement != null) visitor(childElement!);
  }
}

/// A widget that imposes [BoxConstraints] on its child.
