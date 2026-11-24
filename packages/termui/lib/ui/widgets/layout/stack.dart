import 'dart:math';

import 'package:termui/src/element_children.dart';
import 'package:termui/termui.dart';

/// A layout widget that stacks its children on top of each other.
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
    childElements = reconcileChildElements(this, childElements, stack.children);
  }

  @override
  void unmount() {
    unmountChildElements(childElements);
    super.unmount();
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    final (hasNonPositioned, maxW, maxH) = _layoutNonPositionedChildren(
      constraints,
    );
    final resolvedSize = _resolveStackSize(
      constraints,
      hasNonPositioned,
      maxW,
      maxH,
    );

    for (final childEl in childElements) {
      if (childEl.widget case final Positioned positioned) {
        _layoutPositionedChild(childEl, positioned, resolvedSize);
      }
    }

    return resolvedSize;
  }

  (bool, int, int) _layoutNonPositionedChildren(BoxConstraints constraints) {
    var maxW = 0;
    var maxH = 0;
    var hasNonPositioned = false;
    final childConstraints = BoxConstraints(
      minWidth: 0,
      maxWidth: max(0, constraints.maxWidth),
      minHeight: 0,
      maxHeight: max(0, constraints.maxHeight),
    );
    for (final childEl in childElements) {
      if (childEl.widget is Positioned) continue;
      hasNonPositioned = true;
      childEl.relativeOffset = Offset.zero;
      final childSize = childEl.layout(childConstraints);
      maxW = max(maxW, childSize.width);
      maxH = max(maxH, childSize.height);
    }
    return (hasNonPositioned, maxW, maxH);
  }

  static Size _resolveStackSize(
    BoxConstraints constraints,
    bool hasNonPositioned,
    int maxW,
    int maxH,
  ) {
    if (hasNonPositioned) {
      return constraints.constrain(Size(maxW, maxH));
    }
    final resolvedW = constraints.maxWidth == BoxConstraints.infinity
        ? constraints.minWidth
        : constraints.maxWidth;
    final resolvedH = constraints.maxHeight == BoxConstraints.infinity
        ? constraints.minHeight
        : constraints.maxHeight;
    return Size(resolvedW, resolvedH);
  }

  static void _layoutPositionedChild(
    Element childEl,
    Positioned positioned,
    Size stackSize,
  ) {
    final (minChildW, maxChildW, childX) = _resolvePositionedAxis(
      isCentered: positioned.isCentered,
      start: positioned.left,
      end: positioned.right,
      extent: positioned.width,
      containerSize: stackSize.width,
    );
    final (minChildH, maxChildH, childY) = _resolvePositionedAxis(
      isCentered: positioned.isCentered,
      start: positioned.top,
      end: positioned.bottom,
      extent: positioned.height,
      containerSize: stackSize.height,
    );

    final childSize = childEl.layout(
      BoxConstraints(
        minWidth: minChildW,
        maxWidth: maxChildW,
        minHeight: minChildH,
        maxHeight: maxChildH,
      ),
    );

    final finalX = positioned.isCentered
        ? (stackSize.width - childSize.width) ~/ 2
        : (childX ?? stackSize.width - positioned.right! - childSize.width);
    final finalY = positioned.isCentered
        ? (stackSize.height - childSize.height) ~/ 2
        : (childY ?? stackSize.height - positioned.bottom! - childSize.height);

    childEl.relativeOffset = Offset(finalX, finalY);
  }

  static (int, int, int?) _resolvePositionedAxis({
    required bool isCentered,
    required int? start,
    required int? end,
    required int? extent,
    required int containerSize,
  }) => switch ((isCentered, start, end, extent)) {
    (true, _, _, int v) => (v, v, null),
    (true, _, _, null) => (0, containerSize, null),
    (false, int s, int e, _) => (
      max(0, containerSize - s - e),
      max(0, containerSize - s - e),
      s,
    ),
    (false, int s, null, int v) => (v, v, s),
    (false, null, int e, int v) => (v, v, containerSize - e - v),
    (false, int s, null, null) => (0, max(0, containerSize - s), s),
    (false, null, int e, null) => (0, max(0, containerSize - e), null),
    (false, null, null, int v) => (v, v, 0),
    (false, null, null, null) => (0, containerSize, 0),
  };

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
