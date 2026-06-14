import 'package:characters/characters.dart';
import '../buffer.dart';
import '../style.dart';
import '../layout.dart';

/// A scrollable list of string items.
///
/// Example usage:
/// ```dart
/// final listWidget = ListWidget(
///   ['Item 1', 'Item 2', 'Item 3'],
///   selectedIndex: 1,
///   selectedStyle: Style(modifiers: Modifier.reverse),
/// );
/// ```
class ListWidget extends Widget {
  /// The items to display in the list.
  final List<String> items;

  /// The currently selected item index.
  int selectedIndex;

  /// The index of the item currently hovered, if any.
  int? hoveredIndex;

  /// The current scroll offset, representing the index of the first visible item.
  int scrollOffset = 0;

  /// The style applied to unselected items.
  final Style itemStyle;

  /// The style applied to the selected item.
  final Style selectedStyle;

  /// The style applied to the hovered item.
  final Style? hoveredStyle;

  /// Creates a [ListWidget] to display a selectable list of items.
  ListWidget(
    this.items, {
    this.selectedIndex = 0,
    this.hoveredIndex,
    this.itemStyle = Style.empty,
    this.selectedStyle = const Style(modifiers: Modifier.reverse),
    this.hoveredStyle,
  });

  /// Updates scroll offset based on selected index to keep selection visible.
  void adjustScroll(int viewportHeight) {
    if (items.isEmpty || viewportHeight <= 0) return;
    selectedIndex = selectedIndex.clamp(0, items.length - 1);

    if (selectedIndex < scrollOffset) {
      scrollOffset = selectedIndex;
    } else if (selectedIndex >= scrollOffset + viewportHeight) {
      scrollOffset = selectedIndex - viewportHeight + 1;
    }
  }

  @override
  Element createElement() => ListWidgetElement(this);
}

/// Mount element class corresponding to [ListWidget].
class ListWidgetElement extends Element {
  /// The indices of the visible items calculated in [performLayout].
  List<int> visibleIndices = [];

  /// Instantiates the rendering element for the given ListWidget.
  ListWidgetElement(ListWidget super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final listWidget = widget as ListWidget;
    final width = constraints.hasBoundedWidth ? constraints.maxWidth : 80;
    final height = constraints.hasBoundedHeight
        ? constraints.maxHeight
        : listWidget.items.length;

    listWidget.adjustScroll(height);

    visibleIndices = [];
    for (var i = 0; i < height; i++) {
      final itemIdx = listWidget.scrollOffset + i;
      if (itemIdx >= listWidget.items.length) break;
      visibleIndices.add(itemIdx);
    }

    return constraints.constrain(Size(width, height));
  }

  @override
  void paint(Buffer buffer, Offset offset) {
    final listWidget = widget as ListWidget;
    final w = size.width;

    for (var i = 0; i < visibleIndices.length; i++) {
      final itemIdx = visibleIndices[i];
      final isSelected = itemIdx == listWidget.selectedIndex;
      final isHovered = itemIdx == listWidget.hoveredIndex;
      final text = listWidget.items[itemIdx];

      final chars = text.characters;
      final padded = chars.length >= w
          ? chars.take(w).toString()
          : chars.toString() + (' ' * (w - chars.length));

      var style = listWidget.itemStyle;
      if (isSelected) {
        style = listWidget.selectedStyle;
      } else if (isHovered) {
        style = listWidget.hoveredStyle ?? const Style(modifiers: Modifier.dim);
      }

      buffer.writeString(offset.dx, offset.dy + i, padded, style);
    }
  }
}
