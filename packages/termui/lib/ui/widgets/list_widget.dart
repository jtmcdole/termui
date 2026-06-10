import 'package:characters/characters.dart';
import '../buffer.dart';
import '../style.dart';
import '../layout.dart';

/// A scrollable list of string items.
class ListWidget extends Widget {
  /// The items to display in the list.
  final List<String> items;

  /// The currently selected item index.
  int selectedIndex;

  /// The current scroll offset, representing the index of the first visible item.
  int scrollOffset = 0;

  /// The style applied to unselected items.
  final Style itemStyle;

  /// The style applied to the selected item.
  final Style selectedStyle;

  /// Creates a [ListWidget] to display a selectable list of items.
  ListWidget(
    this.items, {
    this.selectedIndex = 0,
    this.itemStyle = Style.empty,
    this.selectedStyle = const Style(modifiers: Modifier.reverse),
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
  void render(Buffer buffer, Rect area) {
    adjustScroll(area.height);

    for (var i = 0; i < area.height; i++) {
      final itemIdx = scrollOffset + i;
      if (itemIdx >= items.length) break;

      final isSelected = itemIdx == selectedIndex;
      final text = items[itemIdx];
      // Pad line to fit full width in a grapheme-safe way
      final chars = text.characters;
      final padded = chars.length >= area.width
          ? chars.take(area.width).toString()
          : chars.toString() + (' ' * (area.width - chars.length));

      buffer.writeString(0, i, padded, isSelected ? selectedStyle : itemStyle);
    }
  }
}
