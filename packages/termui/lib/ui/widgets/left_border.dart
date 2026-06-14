import 'dart:math';
import '../buffer.dart';
import '../layout.dart';
import '../style.dart';

/// A layout widget that draws a vertical line (left border) on the left side of its child.
class LeftBorder extends Widget {
  /// The child widget to be wrapped with a border.
  final Widget child;

  /// The style applied to the border character.
  final Style style;

  /// The character used to draw the vertical border line.
  final String char;

  /// The padding space around the child.
  final EdgeInsets padding;

  /// Optional fixed height for the border line. If null, it takes full available height.
  final int? borderHeight;

  /// Creates a left border widget.
  const LeftBorder({
    required this.child,
    this.style = const Style(),
    this.char = '│',
    this.padding = const EdgeInsets.only(left: 1),
    this.borderHeight,
  });

  @override
  Element createElement() => LeftBorderElement(this);
}

/// The Element corresponding to a [LeftBorder] widget.
class LeftBorderElement extends Element {
  /// The element corresponding to the child widget.
  Element? childElement;

  /// Creates a new [LeftBorderElement].
  LeftBorderElement(LeftBorder super.widget);

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
    final borderWidget = widget as LeftBorder;
    if (childElement != null &&
        childElement!.widget.runtimeType == borderWidget.child.runtimeType) {
      childElement!.update(borderWidget.child);
    } else {
      childElement?.unmount();
      childElement = borderWidget.child.createElement();
      childElement!.mount(this);
    }
  }

  @override
  void unmount() {
    childElement?.unmount();
    super.unmount();
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement != null) visitor(childElement!);
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    final borderWidget = widget as LeftBorder;
    final padding = borderWidget.padding;
    final extraW = 1 + padding.left + padding.right;
    final extraH = padding.top + padding.bottom;

    if (childElement != null) {
      final childConstraints = BoxConstraints(
        minWidth: max(0, constraints.minWidth - extraW),
        maxWidth: constraints.maxWidth == BoxConstraints.infinity
            ? BoxConstraints.infinity
            : max(0, constraints.maxWidth - extraW),
        minHeight: max(0, constraints.minHeight - extraH),
        maxHeight: constraints.maxHeight == BoxConstraints.infinity
            ? BoxConstraints.infinity
            : max(0, constraints.maxHeight - extraH),
      );
      final childSize = childElement!.layout(childConstraints);
      childElement!.relativeOffset = Offset(1 + padding.left, padding.top);
      return constraints.constrain(
        Size(childSize.width + extraW, childSize.height + extraH),
      );
    }
    return constraints.constrain(Size(extraW, extraH));
  }

  @override
  void paint(Buffer buffer, Offset offset) {
    final borderWidget = widget as LeftBorder;
    final padding = borderWidget.padding;
    final requiredWidth = 1 + padding.left + padding.right;
    final requiredHeight = padding.top + padding.bottom;
    if (size.width <= requiredWidth || size.height <= requiredHeight) return;

    final limit = borderWidget.borderHeight ?? size.height;
    // 1. Draw the vertical line on the left
    for (var y = 0; y < size.height; y++) {
      final cellChar = y < limit ? borderWidget.char : ' ';
      final cell = buffer.getCell(offset.dx, offset.dy + y);
      if (cell != null) {
        cell.char = cellChar;
        cell.style = borderWidget.style;
      }
    }

    // 2. Render the child in the remaining area
    if (childElement != null) {
      childElement!.paint(buffer, offset + childElement!.relativeOffset);
    }
  }
}
