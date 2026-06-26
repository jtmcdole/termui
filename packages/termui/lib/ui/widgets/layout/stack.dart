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
        final (minChildW, maxChildW, childX) = switch ((
          childWidget.isCentered,
          childWidget.left,
          childWidget.right,
          childWidget.width,
        )) {
          (true, _, _, int w) => (w, w, null as int?),
          (true, _, _, null) => (0, resolvedW, null as int?),
          (false, int left, int right, _) => (
            (resolvedW - left - right) < 0 ? 0 : resolvedW - left - right,
            (resolvedW - left - right) < 0 ? 0 : resolvedW - left - right,
            left as int?,
          ),
          (false, int left, null, int w) => (w, w, left as int?),
          (false, null, int right, int w) => (w, w, resolvedW - right - w),
          (false, int left, null, null) => (
            0,
            (resolvedW - left) < 0 ? 0 : resolvedW - left,
            left as int?,
          ),
          (false, null, int right, null) => (
            0,
            (resolvedW - right) < 0 ? 0 : resolvedW - right,
            null as int?,
          ),
          (false, null, null, int w) => (w, w, 0 as int?),
          (false, null, null, null) => (0, resolvedW, 0 as int?),
        };

        final (minChildH, maxChildH, childY) = switch ((
          childWidget.isCentered,
          childWidget.top,
          childWidget.bottom,
          childWidget.height,
        )) {
          (true, _, _, int h) => (h, h, null as int?),
          (true, _, _, null) => (0, resolvedH, null as int?),
          (false, int top, int bottom, _) => (
            (resolvedH - top - bottom) < 0 ? 0 : resolvedH - top - bottom,
            (resolvedH - top - bottom) < 0 ? 0 : resolvedH - top - bottom,
            top as int?,
          ),
          (false, int top, null, int h) => (h, h, top as int?),
          (false, null, int bottom, int h) => (h, h, resolvedH - bottom - h),
          (false, int top, null, null) => (
            0,
            (resolvedH - top) < 0 ? 0 : resolvedH - top,
            top as int?,
          ),
          (false, null, int bottom, null) => (
            0,
            (resolvedH - bottom) < 0 ? 0 : resolvedH - bottom,
            null as int?,
          ),
          (false, null, null, int h) => (h, h, 0 as int?),
          (false, null, null, null) => (0, resolvedH, 0 as int?),
        };

        final childSize = childEl.layout(
          BoxConstraints(
            minWidth: minChildW,
            maxWidth: maxChildW,
            minHeight: minChildH,
            maxHeight: maxChildH,
          ),
        );

        final finalX = childWidget.isCentered
            ? (resolvedW - childSize.width) ~/ 2
            : (childX ?? resolvedW - childWidget.right! - childSize.width);

        final finalY = childWidget.isCentered
            ? (resolvedH - childSize.height) ~/ 2
            : (childY ?? resolvedH - childWidget.bottom! - childSize.height);

        childEl.relativeOffset = Offset(finalX, finalY);
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
