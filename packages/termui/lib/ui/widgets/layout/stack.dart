import 'package:termui/termui.dart';

/// Undocumented public member.
class Stack extends Widget {
  /// The children widgets to stack.
  final List<Widget> children;

  /// Creates a stack layout for [children].
  const Stack(this.children);

  @override
  Element createElement() => StackElement(this);

  @override
  int getIntrinsicHeight(int width) {
    var maxH = 0;
    for (final child in children) {
      final h = child.getIntrinsicHeight(width);
      if (h > maxH) maxH = h;
    }
    return maxH;
  }

  @override
  int getIntrinsicWidth(int height) {
    var maxW = 0;
    for (final child in children) {
      final w = child.getIntrinsicWidth(height);
      if (w > maxW) maxW = w;
    }
    return maxW;
  }
}

/// An element that manages a [Stack] widget.
class StackElement extends Element {
  /// The list of managed child elements.
  List<Element> childElements = [];

  /// Creates a stack element for a [Stack] widget.
  StackElement(Stack super.widget);

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
    final stack = widget as Stack;
    final newElements = <Element>[];
    for (var i = 0; i < stack.children.length; i++) {
      final childWidget = stack.children[i];
      if (i < childElements.length &&
          childElements[i].widget.runtimeType == childWidget.runtimeType) {
        childElements[i].update(childWidget);
        newElements.add(childElements[i]);
      } else {
        if (i < childElements.length) {
          childElements[i].unmount();
        }
        final newEl = childWidget.createElement();
        newEl.mount(this);
        newElements.add(newEl);
      }
    }
    for (var i = stack.children.length; i < childElements.length; i++) {
      childElements[i].unmount();
    }
    childElements = newElements;
  }

  @override
  void unmount() {
    for (final child in childElements) {
      child.unmount();
    }
    super.unmount();
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    final width = constraints.maxWidth == BoxConstraints.infinity
        ? 0
        : constraints.maxWidth;
    final height = constraints.maxHeight == BoxConstraints.infinity
        ? 0
        : constraints.maxHeight;

    var maxW = 0;
    var maxH = 0;

    for (var i = 0; i < childElements.length; i++) {
      final childEl = childElements[i];
      final childWidget = childEl.widget;

      if (childWidget is Positioned) {
        int childX = 0;
        int childY = 0;
        int childWidth = width;
        int childHeight = height;

        if (childWidget.isCentered) {
          childWidth = childWidget.width ?? width;
          childHeight = childWidget.height ?? height;
          childX = (width - childWidth) ~/ 2;
          childY = (height - childHeight) ~/ 2;
        } else {
          if (childWidget.left != null) {
            childX = childWidget.left!;
            if (childWidget.right != null) {
              childWidth = width - childWidget.left! - childWidget.right!;
            } else if (childWidget.width != null) {
              childWidth = childWidget.width!;
            } else {
              childWidth = width - childWidget.left!;
            }
          } else if (childWidget.right != null) {
            if (childWidget.width != null) {
              childWidth = childWidget.width!;
              childX = width - childWidget.right! - childWidth;
            } else {
              childWidth = width - childWidget.right!;
            }
          } else if (childWidget.width != null) {
            childWidth = childWidget.width!;
          }

          if (childWidget.top != null) {
            childY = childWidget.top!;
            if (childWidget.bottom != null) {
              childHeight = height - childWidget.top! - childWidget.bottom!;
            } else if (childWidget.height != null) {
              childHeight = childWidget.height!;
            } else {
              childHeight = height - childWidget.top!;
            }
          } else if (childWidget.bottom != null) {
            if (childWidget.height != null) {
              childHeight = childWidget.height!;
              childY = height - childWidget.bottom! - childHeight;
            } else {
              childHeight = height - childWidget.bottom!;
            }
          } else if (childWidget.height != null) {
            childHeight = childWidget.height!;
          }
        }

        childEl.relativeOffset = Offset(childX, childY);
        if (childWidth > 0 && childHeight > 0) {
          final childSize = childEl.layout(
            BoxConstraints.tight(Size(childWidth, childHeight)),
          );
          final rightEdge = childX + childSize.width;
          final bottomEdge = childY + childSize.height;
          if (rightEdge > maxW) maxW = rightEdge;
          if (bottomEdge > maxH) maxH = bottomEdge;
        }
      } else {
        childEl.relativeOffset = Offset.zero;
        final childSize = childEl.layout(constraints);
        if (childSize.width > maxW) maxW = childSize.width;
        if (childSize.height > maxH) maxH = childSize.height;
      }
    }

    return Size(maxW, maxH);
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    if (size.width <= 0 || size.height <= 0) return;
    for (final child in childElements) {
      child.paint(buffer, offset + child.relativeOffset);
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    childElements.forEach(visitor);
  }

  @override
  int getIntrinsicHeight(int width) {
    var maxH = 0;
    for (final child in childElements) {
      final h = child.getIntrinsicHeight(width);
      if (h > maxH) maxH = h;
    }
    return maxH;
  }

  @override
  int getIntrinsicWidth(int height) {
    var maxW = 0;
    for (final child in childElements) {
      final w = child.getIntrinsicWidth(height);
      if (w > maxW) maxW = w;
    }
    return maxW;
  }
}

/// Places a widget inside a [Stack] at specific coordinate offsets.
