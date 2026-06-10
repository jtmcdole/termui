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

  @override
  void render(Buffer buffer, Rect area) {
    // Fallback for direct widget rendering outside of active element tree
    final rootContext = LeftBorderElement(this)..mount(null);
    rootContext.render(buffer, area);
  }
}

/// The Element corresponding to a [LeftBorder] widget.
class LeftBorderElement extends Element {
  /// The element corresponding to the child widget.
  Element? childElement;

  /// Creates a new [LeftBorderElement].
  LeftBorderElement(LeftBorder super.widget);

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement != null) visitor(childElement!);
  }

  @override
  void render(Buffer buffer, Rect area) {
    final borderWidget = widget as LeftBorder;
    final padding = borderWidget.padding;
    final requiredWidth = 1 + padding.left + padding.right;
    final requiredHeight = padding.top + padding.bottom;
    if (area.width <= requiredWidth || area.height <= requiredHeight) return;

    final limit = borderWidget.borderHeight ?? area.height;
    // 1. Draw the vertical line on the left
    for (var y = 0; y < area.height; y++) {
      final cellChar = y < limit ? borderWidget.char : ' ';
      final cell = buffer.getCell(area.x, area.y + y);
      if (cell != null) {
        cell.char = cellChar;
        cell.style = borderWidget.style;
      }
    }

    // 2. Render the child in the remaining area
    final childX = area.x + 1 + padding.left;
    final childWidth = area.width - 1 - padding.left - padding.right;
    final childY = area.y + padding.top;
    final childHeight = area.height - padding.top - padding.bottom;
    final childArea = Rect(childX, childY, childWidth, childHeight);

    if (childElement != null &&
        childElement!.widget.runtimeType == borderWidget.child.runtimeType) {
      childElement!.update(borderWidget.child);
    } else {
      childElement = borderWidget.child.createElement();
      childElement!.mount(this);
    }

    final childViewport = Viewport(buffer, childArea);
    childElement!.render(childViewport, Rect(0, 0, childWidth, childHeight));
  }
}
