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
    var maxW = 0;
    var maxH = 0;
    var hasNonPositioned = false;

    // 1. First pass: lay out non-positioned children to determine the Stack's size.
    final childConstraints = BoxConstraints(
      minWidth: 0,
      maxWidth: constraints.maxWidth < 0 ? 0 : constraints.maxWidth,
      minHeight: 0,
      maxHeight: constraints.maxHeight < 0 ? 0 : constraints.maxHeight,
    );
    for (var i = 0; i < childElements.length; i++) {
      final childEl = childElements[i];
      final childWidget = childEl.widget;

      if (childWidget is! Positioned) {
        hasNonPositioned = true;
        childEl.relativeOffset = Offset.zero;
        final childSize = childEl.layout(childConstraints);
        if (childSize.width > maxW) maxW = childSize.width;
        if (childSize.height > maxH) maxH = childSize.height;
      }
    }

    // 2. Resolve the final size of the Stack.
    int resolvedW;
    int resolvedH;
    if (hasNonPositioned) {
      final resolvedSize = constraints.constrain(Size(maxW, maxH));
      resolvedW = resolvedSize.width;
      resolvedH = resolvedSize.height;
    } else {
      resolvedW = constraints.maxWidth == BoxConstraints.infinity
          ? constraints.minWidth
          : constraints.maxWidth;
      resolvedH = constraints.maxHeight == BoxConstraints.infinity
          ? constraints.minHeight
          : constraints.maxHeight;
    }

    // 3. Second pass: lay out and position Positioned children using the resolved Stack size.
    for (var i = 0; i < childElements.length; i++) {
      final childEl = childElements[i];
      final childWidget = childEl.widget;

      if (childWidget is Positioned) {
        int minChildW;
        int maxChildW;
        int? childX;

        if (childWidget.isCentered) {
          if (childWidget.width != null) {
            minChildW = maxChildW = childWidget.width!;
          } else {
            minChildW = 0;
            maxChildW = resolvedW;
          }
        } else {
          if (childWidget.left != null && childWidget.right != null) {
            final w = resolvedW - childWidget.left! - childWidget.right!;
            minChildW = maxChildW = w < 0 ? 0 : w;
            childX = childWidget.left!;
          } else if (childWidget.left != null && childWidget.width != null) {
            minChildW = maxChildW = childWidget.width!;
            childX = childWidget.left!;
          } else if (childWidget.right != null && childWidget.width != null) {
            minChildW = maxChildW = childWidget.width!;
            childX = resolvedW - childWidget.right! - childWidget.width!;
          } else if (childWidget.left != null) {
            minChildW = 0;
            final w = resolvedW - childWidget.left!;
            maxChildW = w < 0 ? 0 : w;
            childX = childWidget.left!;
          } else if (childWidget.right != null) {
            minChildW = 0;
            final w = resolvedW - childWidget.right!;
            maxChildW = w < 0 ? 0 : w;
            childX = null;
          } else if (childWidget.width != null) {
            minChildW = maxChildW = childWidget.width!;
            childX = 0;
          } else {
            minChildW = 0;
            maxChildW = resolvedW;
            childX = 0;
          }
        }

        int minChildH;
        int maxChildH;
        int? childY;

        if (childWidget.isCentered) {
          if (childWidget.height != null) {
            minChildH = maxChildH = childWidget.height!;
          } else {
            minChildH = 0;
            maxChildH = resolvedH;
          }
        } else {
          if (childWidget.top != null && childWidget.bottom != null) {
            final h = resolvedH - childWidget.top! - childWidget.bottom!;
            minChildH = maxChildH = h < 0 ? 0 : h;
            childY = childWidget.top!;
          } else if (childWidget.top != null && childWidget.height != null) {
            minChildH = maxChildH = childWidget.height!;
            childY = childWidget.top!;
          } else if (childWidget.bottom != null && childWidget.height != null) {
            minChildH = maxChildH = childWidget.height!;
            childY = resolvedH - childWidget.bottom! - childWidget.height!;
          } else if (childWidget.top != null) {
            minChildH = 0;
            final h = resolvedH - childWidget.top!;
            maxChildH = h < 0 ? 0 : h;
            childY = childWidget.top!;
          } else if (childWidget.bottom != null) {
            minChildH = 0;
            final h = resolvedH - childWidget.bottom!;
            maxChildH = h < 0 ? 0 : h;
            childY = null;
          } else if (childWidget.height != null) {
            minChildH = maxChildH = childWidget.height!;
            childY = 0;
          } else {
            minChildH = 0;
            maxChildH = resolvedH;
            childY = 0;
          }
        }

        final childSize = childEl.layout(
          BoxConstraints(
            minWidth: minChildW,
            maxWidth: maxChildW,
            minHeight: minChildH,
            maxHeight: maxChildH,
          ),
        );

        if (childWidget.isCentered) {
          childX = (resolvedW - childSize.width) ~/ 2;
          childY = (resolvedH - childSize.height) ~/ 2;
        } else {
          childX ??= resolvedW - childWidget.right! - childSize.width;
          childY ??= resolvedH - childWidget.bottom! - childSize.height;
        }

        childEl.relativeOffset = Offset(childX, childY);
      }
    }

    return Size(resolvedW, resolvedH);
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
