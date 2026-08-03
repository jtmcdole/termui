import 'package:termui/termui.dart';

/// Undocumented public member.
class Column extends Widget {
  /// The children widgets to align vertically.
  final List<Widget> children;

  /// How the children should be placed along the cross axis.
  final CrossAxisAlignment crossAxisAlignment;

  /// How the children should be placed along the main axis.
  final MainAxisAlignment mainAxisAlignment;

  /// Creates a vertical layout for [children].
  const Column(
    this.children, {
    super.key,
    this.crossAxisAlignment = CrossAxisAlignment.start,
    this.mainAxisAlignment = MainAxisAlignment.start,
  });

  @override
  Element createElement() => ColumnElement(this);

  @override
  int getIntrinsicHeight(int width) {
    var totalHeight = 0;
    for (final child in children) {
      totalHeight += child.getIntrinsicHeight(width);
    }
    return totalHeight;
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

/// An element that manages a [Column] widget.
class ColumnElement extends Element {
  /// The list of managed child elements.
  List<Element> childElements = [];

  int _overflowAmount = 0;
  int _overflowTop = 0;
  int _overflowBottom = 0;

  /// Creates a column element for a [Column] widget.
  ColumnElement(Column super.widget);

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
    final column = widget as Column;
    final newElements = <Element>[];
    for (var i = 0; i < column.children.length; i++) {
      final childWidget = column.children[i];
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
    for (var i = column.children.length; i < childElements.length; i++) {
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
    final column = widget as Column;
    final width = constraints.maxWidth == BoxConstraints.infinity
        ? 0
        : constraints.maxWidth;
    final height = constraints.maxHeight == BoxConstraints.infinity
        ? 0
        : constraints.maxHeight;
    final area = Rect(0, 0, width, height);

    // Map directly over childElements to retrieve their widgets and calculate
    // constraints, avoiding index desyncs or out-of-bounds errors that could occur
    // if we relied on zip-indexing between column.children and childElements.
    final columnConstraints = childElements
        .map(
          (el) => getConstraint(
            el.widget,
            LayoutDirection.vertical,
            crossSize: width,
            element: el,
          ),
        )
        .toList();
    final rects = splitRect(
      area,
      columnConstraints,
      LayoutDirection.vertical,
      mainAxisAlignment: column.mainAxisAlignment,
    );

    var totalHeight = 0;
    var minChildY = 0;
    var maxChildY = 0;

    for (var i = 0; i < childElements.length; i++) {
      final childEl = childElements[i];
      final childArea = rects[i];
      final minW = column.crossAxisAlignment == CrossAxisAlignment.stretch
          ? width
          : 0;
      final childSize = childEl.layout(
        BoxConstraints(
          minWidth: minW,
          maxWidth: width,
          minHeight: childArea.height,
          maxHeight: childArea.height,
        ),
      );
      childEl.relativeOffset = Offset(childArea.x, childArea.y);
      totalHeight += childSize.height;

      if (childArea.y < minChildY) minChildY = childArea.y;
      if (childArea.y + childSize.height > maxChildY) {
        maxChildY = childArea.y + childSize.height;
      }
    }

    final resolvedHeight = totalHeight.clamp(
      constraints.minHeight,
      constraints.maxHeight,
    );
    _overflowAmount = totalHeight - resolvedHeight;
    _overflowTop = minChildY < 0 ? -minChildY : 0;
    _overflowBottom = maxChildY > resolvedHeight
        ? maxChildY - resolvedHeight
        : 0;

    // Fallback if elements aren't technically out of bounds but totalHeight exceeds
    if (_overflowAmount > 0 && _overflowTop == 0 && _overflowBottom == 0) {
      _overflowBottom = _overflowAmount;
    }

    if (_overflowAmount > 0) {
      logError('Layout Overflow: Column overflowed by $_overflowAmount lines.');
    }

    return Size(width, resolvedHeight);
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    if (size.width <= 0 || size.height <= 0) return;

    final hasOverflow = _overflowTop > 0 || _overflowBottom > 0;
    if (hasOverflow) {
      buffer.pushClip(
        Rect(offset.dx.toInt(), offset.dy.toInt(), size.width, size.height),
      );
    }

    for (final child in childElements) {
      child.paint(buffer, offset + child.relativeOffset);
    }

    if (_overflowTop > 0 || _overflowBottom > 0) {
      final tapeHeight = size.height < 3 ? size.height : 3;

      if (_overflowTop > 0) {
        final bounds = Rect(
          offset.dx.toInt(),
          offset.dy.toInt(),
          size.width,
          tapeHeight,
        );
        buffer.drawCautionTape(bounds, offset.dx.toInt(), offset.dy.toInt());
      }

      if (_overflowBottom > 0) {
        final bounds = Rect(
          offset.dx.toInt(),
          (offset.dy + size.height - tapeHeight).toInt(),
          size.width,
          tapeHeight,
        );
        buffer.drawCautionTape(bounds, offset.dx.toInt(), bounds.top);
      }
    }

    if (hasOverflow) {
      buffer.popClip();
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    childElements.forEach(visitor);
  }

  @override
  int getIntrinsicHeight(int width) =>
      childElements.fold(0, (sum, el) => sum + el.getIntrinsicHeight(width));

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

/// A layout widget that stacks its children on top of each other.
