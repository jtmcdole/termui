import 'dart:math';
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
    this.crossAxisAlignment = .start,
    this.mainAxisAlignment = .start,
    this.backgroundChar,
    this.backgroundStyle,
  });

  @override
  Element createElement() => RowElement(this);

  @override
  int getIntrinsicHeight(int width) {
    if (children.isEmpty) return 0;
    final rowConstraints = [
      for (final c in children) getConstraint(c, .horizontal, crossSize: 0),
    ];
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

  @override
  int getIntrinsicWidth(int height) {
    var totalWidth = 0;
    for (final child in children) {
      totalWidth += child.getIntrinsicWidth(height);
    }
    return totalWidth;
  }
}

/// An element that manages a [Row] widget.
class RowElement extends Element {
  /// The list of managed child elements.
  List<Element> childElements = [];

  int _overflowAmount = 0;
  int _overflowLeft = 0;
  int _overflowRight = 0;

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
    final rowConstraints = [
      for (final el in childElements)
        getConstraint(el.widget, .horizontal, crossSize: height, element: el),
    ];
    final rects = splitRect(
      area,
      rowConstraints,
      LayoutDirection.horizontal,
      mainAxisAlignment: row.mainAxisAlignment,
    );

    var maxChildHeight = 0;
    var totalWidth = 0;

    var minChildX = 0;
    var maxChildX = 0;

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
      totalWidth += childSize.width;

      if (childArea.x < minChildX) minChildX = childArea.x;
      if (childArea.x + childSize.width > maxChildX) {
        maxChildX = childArea.x + childSize.width;
      }
    }

    final resolvedWidth = max(
      totalWidth,
      maxChildX,
    ).clamp(constraints.minWidth, constraints.maxWidth);
    _overflowAmount = totalWidth - resolvedWidth;
    _overflowLeft = minChildX < 0 ? -minChildX : 0;
    _overflowRight = maxChildX > resolvedWidth ? maxChildX - resolvedWidth : 0;

    // Fallback if elements aren't technically out of bounds but totalWidth exceeds
    if (_overflowAmount > 0 && _overflowLeft == 0 && _overflowRight == 0) {
      _overflowRight = _overflowAmount;
    }

    if (_overflowAmount > 0) {
      logError('Layout Overflow: Row overflowed by $_overflowAmount columns.');
    }

    return Size(resolvedWidth, maxChildHeight);
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    if (size.width <= 0 || size.height <= 0) return;

    final hasOverflow = _overflowLeft > 0 || _overflowRight > 0;
    if (hasOverflow) {
      buffer.pushClip(
        Rect(offset.dx.toInt(), offset.dy.toInt(), size.width, size.height),
      );
    }

    final row = widget as Row;
    if (row.backgroundChar != null) {
      final char = row.backgroundChar!;
      final style = row.backgroundStyle ?? Style.empty;
      buffer.fillRect(
        Rect(offset.dx.toInt(), offset.dy.toInt(), size.width, size.height),
        char: char,
        fg: style.foreground?.argb ?? 0,
        bg: style.background?.argb ?? 0,
        modifiers: style.modifiers,
      );
    }

    for (final child in childElements) {
      child.paint(buffer, offset + child.relativeOffset);
    }

    if (_overflowLeft > 0 || _overflowRight > 0) {
      final tapeWidth = size.width < 3 ? size.width : 3;

      if (_overflowLeft > 0) {
        final bounds = Rect(
          offset.dx.toInt(),
          offset.dy.toInt(),
          tapeWidth,
          size.height,
        );
        buffer.drawCautionTape(bounds, offset.dx.toInt(), offset.dy.toInt());
      }

      if (_overflowRight > 0) {
        final bounds = Rect(
          (offset.dx + size.width - tapeWidth).toInt(),
          offset.dy.toInt(),
          tapeWidth,
          size.height,
        );
        buffer.drawCautionTape(bounds, bounds.left, offset.dy.toInt());
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
  int getIntrinsicHeight(int width) {
    var maxH = 0;
    for (final child in childElements) {
      final h = child.getIntrinsicHeight(width);
      if (h > maxH) maxH = h;
    }
    return maxH;
  }

  @override
  int getIntrinsicWidth(int height) =>
      childElements.fold(0, (sum, el) => sum + el.getIntrinsicWidth(height));
}

/// A layout widget that arranges its children vertically.
