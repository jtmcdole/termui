import 'package:termui/termui.dart';

/// Undocumented public member.
class Row extends Widget {
  /// The children widgets to align horizontally.
  final List<Widget> children;

  /// How the children should be placed along the cross axis.
  final CrossAxisAlignment crossAxisAlignment;

  /// How the children should be placed along the main axis.
  final MainAxisAlignment mainAxisAlignment;

  /// A background fill character.
  final String? backgroundChar;

  /// A background fill style.
  final Style? backgroundStyle;

  /// Creates a horizontal layout for [children].
  const Row(
    this.children, {
    super.key,
    this.crossAxisAlignment = CrossAxisAlignment.start,
    this.mainAxisAlignment = MainAxisAlignment.start,
    this.backgroundChar,
    this.backgroundStyle,
  });

  @override
  Element createElement() => RowElement(this);

  @override
  int getIntrinsicHeight(int width) {
    if (children.isEmpty) return 0;
    final rowConstraints = children
        .map((c) => getConstraint(c, LayoutDirection.horizontal, crossSize: 0))
        .toList();
    final rects = splitRect(
      Rect(0, 0, width, 1),
      rowConstraints,
      LayoutDirection.horizontal,
      mainAxisAlignment: mainAxisAlignment,
    );
    var maxH = 0;
    for (var i = 0; i < children.length; i++) {
      final h = children[i].getIntrinsicHeight(rects[i].width);
      if (h > maxH) maxH = h;
    }
    return maxH;
  }
}

/// An element that manages a [Row] widget.
class RowElement extends Element {
  /// The list of managed child elements.
  List<Element> childElements = [];

  /// Creates a row element for a [Row] widget.
  RowElement(Row super.widget);

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
    final row = widget as Row;
    final newElements = <Element>[];
    for (var i = 0; i < row.children.length; i++) {
      final childWidget = row.children[i];
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
    for (var i = row.children.length; i < childElements.length; i++) {
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
    final row = widget as Row;
    final width = constraints.maxWidth == BoxConstraints.infinity
        ? 0
        : constraints.maxWidth;
    final height = constraints.maxHeight == BoxConstraints.infinity
        ? 0
        : constraints.maxHeight;
    final area = Rect(0, 0, width, height);

    // Map directly over childElements to retrieve their widgets and calculate
    // constraints, avoiding index desyncs or out-of-bounds errors that could occur
    // if we relied on zip-indexing between row.children and childElements.
    final rowConstraints = childElements
        .map(
          (el) => getConstraint(
            el.widget,
            LayoutDirection.horizontal,
            crossSize: height,
            element: el,
          ),
        )
        .toList();
    final rects = splitRect(
      area,
      rowConstraints,
      LayoutDirection.horizontal,
      mainAxisAlignment: row.mainAxisAlignment,
    );

    var maxChildHeight = 0;

    for (var i = 0; i < childElements.length; i++) {
      final childEl = childElements[i];
      final childArea = rects[i];
      final minH = row.crossAxisAlignment == CrossAxisAlignment.stretch
          ? height
          : 0;
      final childSize = childEl.layout(
        BoxConstraints(
          minWidth: childArea.width,
          maxWidth: childArea.width,
          minHeight: minH,
          maxHeight: height,
        ),
      );
      childEl.relativeOffset = Offset(childArea.x, childArea.y);
      if (childSize.height > maxChildHeight) {
        maxChildHeight = childSize.height;
      }
    }
    return Size(width, maxChildHeight);
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    if (size.width <= 0 || size.height <= 0) return;
    final row = widget as Row;
    if (row.backgroundChar != null) {
      final char = row.backgroundChar!;
      final style = row.backgroundStyle ?? Style.empty;
      final startX = offset.dx;
      final startY = offset.dy;
      for (var y = 0; y < size.height; y++) {
        for (var x = 0; x < size.width; x++) {
          buffer.setAttributes(
            startX + x,
            startY + y,
            char: char,
            fg: style.foreground?.argb ?? 0,
            bg: style.background?.argb ?? 0,
            modifiers: style.modifiers,
          );
        }
      }
    }
    for (final child in childElements) {
      child.paint(buffer, offset + child.relativeOffset);
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    childElements.forEach(visitor);
  }
}

/// A layout widget that arranges its children vertically.
