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
}

/// An element that manages a [Column] widget.
class ColumnElement extends Element {
  /// The list of managed child elements.
  List<Element> childElements = [];

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

    final columnConstraints = column.children
        .map(
          (c) => getConstraint(c, LayoutDirection.vertical, crossSize: width),
        )
        .toList();
    final rects = splitRect(
      area,
      columnConstraints,
      LayoutDirection.vertical,
      mainAxisAlignment: column.mainAxisAlignment,
    );

    var totalHeight = 0;

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
    }
    return Size(width, totalHeight);
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
}

/// A layout widget that stacks its children on top of each other.
