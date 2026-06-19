import 'dart:math';
import 'package:characters/characters.dart';
import '../buffer.dart';
import '../style.dart';
import '../layout.dart';
import '../event.dart' hide Modifier;
import 'text.dart';

/// A scrollable list of child widgets.
class ListView extends Widget {
  /// The child widgets inside the list.
  final List<Widget> children;

  /// The style applied to unselected list items.
  final Style itemStyle;

  /// The style applied to the currently selected list item.
  final Style selectedStyle;

  /// The style applied to the hovered list item, if any.
  final Style? hoveredStyle;

  /// The initially selected item index.
  final int initialSelectedIndex;

  /// The initially hovered item index.
  final int? initialHoveredIndex;

  /// Whether to render a vertical scrollbar on the right edge.
  final bool showScrollbar;

  /// Callback when an item is selected by mouse click or other interaction.
  final void Function(int)? onSelect;

  /// Callback when an item is hovered by mouse.
  final void Function(int?)? onHover;

  /// Creates a [ListView] containing the specified [children].
  ListView({
    super.key,
    required this.children,
    int selectedIndex = 0,
    int? hoveredIndex,
    this.itemStyle = Style.empty,
    this.selectedStyle = const Style(modifiers: Modifier.reverse),
    this.hoveredStyle,
    this.showScrollbar = false,
    this.onSelect,
    this.onHover,
  }) : initialSelectedIndex = selectedIndex,
       initialHoveredIndex = hoveredIndex;

  /// Creates a [ListView] from a list of raw string [items].
  factory ListView.fromStrings(
    List<String> items, {
    Key? key,
    int selectedIndex = 0,
    int? hoveredIndex,
    Style itemStyle = Style.empty,
    Style selectedStyle = const Style(modifiers: Modifier.reverse),
    Style? hoveredStyle,
    bool showScrollbar = false,
    void Function(int)? onSelect,
    void Function(int?)? onHover,
  }) {
    return ListView(
      key: key,
      children: items.map((text) => Text(text)).toList(),
      selectedIndex: selectedIndex,
      hoveredIndex: hoveredIndex,
      itemStyle: itemStyle,
      selectedStyle: selectedStyle,
      hoveredStyle: hoveredStyle,
      showScrollbar: showScrollbar,
      onSelect: onSelect,
      onHover: onHover,
    );
  }

  /// Creates a high-performance [ListView] that bypasses the element tree for raw lines.
  factory ListView.raw({
    Key? key,
    required List<String> lines,
    int selectedIndex = 0,
    int? hoveredIndex,
    Style itemStyle = Style.empty,
    Style selectedStyle = const Style(modifiers: Modifier.reverse),
    Style? hoveredStyle,
    bool showScrollbar = false,
    void Function(int)? onSelect,
    void Function(int?)? onHover,
  }) {
    return _RawListWidget(
      key: key,
      lines: lines,
      selectedIndex: selectedIndex,
      hoveredIndex: hoveredIndex,
      itemStyle: itemStyle,
      selectedStyle: selectedStyle,
      hoveredStyle: hoveredStyle,
      showScrollbar: showScrollbar,
      onSelect: onSelect,
      onHover: onHover,
    );
  }

  @override
  Element createElement() => ListViewElement(this);
}

/// The element managing a [ListView] widget.
class ListViewElement extends Element implements MouseEventHandlerWithArea {
  /// The active child elements.
  List<Element> childElements = [];

  /// The indices of the currently visible items.
  List<int> visibleIndices = [];

  /// The current vertical scroll offset (index of top visible item).
  int scrollOffset = 0;

  /// The currently selected list item index.
  int selectedIndex = 0;

  /// The index of the item currently being hovered over, if any.
  int? hoveredIndex;

  /// Creates a [ListViewElement] for [widget].
  ListViewElement(ListView super.widget);

  @override
  void mount(Element? parent) {
    final listView = widget as ListView;
    selectedIndex = listView.initialSelectedIndex;
    hoveredIndex = listView.initialHoveredIndex;
    super.mount(parent);
    rebuild();
  }

  @override
  void update(Widget newWidget) {
    final oldListView = widget as ListView;
    final newListView = newWidget as ListView;

    if (newListView.initialSelectedIndex != oldListView.initialSelectedIndex) {
      selectedIndex = newListView.initialSelectedIndex;
    }

    super.update(newWidget);
    rebuild();
  }

  /// Adjusts the scroll offset to ensure the currently selected item is visible
  /// within the [viewportHeight].
  void adjustScroll(int viewportHeight) {
    final listView = widget as ListView;
    final itemCount = listView.children.length;
    if (itemCount <= 0 || viewportHeight <= 0) return;
    selectedIndex = selectedIndex.clamp(0, itemCount - 1);

    if (selectedIndex < scrollOffset) {
      scrollOffset = selectedIndex;
    } else if (selectedIndex >= scrollOffset + viewportHeight) {
      scrollOffset = selectedIndex - viewportHeight + 1;
    }
  }

  @override
  void rebuild() {
    final listView = widget as ListView;
    final newElements = <Element>[];
    for (var i = 0; i < listView.children.length; i++) {
      final childWidget = listView.children[i];
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
    for (var i = listView.children.length; i < childElements.length; i++) {
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
    final listView = widget as ListView;
    // Fallbacks to prevent 0,0 crashes while you debug the Column/Expanded constraints
    final width = constraints.hasBoundedWidth && constraints.maxWidth > 0
        ? constraints.maxWidth
        : 80;
    final height = constraints.hasBoundedHeight && constraints.maxHeight > 0
        ? constraints.maxHeight
        : listView.children.length;

    adjustScroll(height);

    visibleIndices = [];
    final childConstraints = BoxConstraints.tight(Size(width, 1));

    for (var i = 0; i < height; i++) {
      final itemIdx = scrollOffset + i;
      if (itemIdx >= childElements.length) break;

      final childElement = childElements[itemIdx];
      // 1. Tell the child how big it is
      childElement.layout(childConstraints);

      // Store the layout offset in the element!
      childElement.relativeOffset = Offset(0, i);

      visibleIndices.add(itemIdx);
    }

    return constraints.constrain(Size(width, height));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final listView = widget as ListView;
    final w = size.width;

    for (var i = 0; i < visibleIndices.length; i++) {
      final itemIdx = visibleIndices[i];

      final child = childElements[itemIdx];

      // Get the spatial coordinate calculated during performLayout
      final childOffset = child.relativeOffset;

      final isSelected = itemIdx == selectedIndex;
      final isHovered = itemIdx == hoveredIndex;

      var style = listView.itemStyle;
      if (isSelected) {
        style = listView.selectedStyle;
      } else if (isHovered) {
        style = listView.hoveredStyle ?? const Style(modifiers: Modifier.dim);
      }

      // Fill background row with space characters and target style
      buffer.writeString(
        offset.dx.toInt(),
        offset.dy.toInt() + i,
        ' ' * w,
        style,
      );

      // Paint child
      // Provide the background and foreground via InheritedTheme or just write it first.
      // But we can just use the target style as the default for the child
      // However since this is legacy code, we paint child on top of background
      child.paint(buffer, offset + childOffset);

      // Apply the inherited style to the text
      // Instead of reading every cell, we can just use composite buffer or accept that child.paint wrote with correct styles.
      // For brevity and correct O(1) text rendering, let's just write the child again?
      // Wait, we can't change child's render pipeline here, so we must mutate cells.
      // But we can optimize to only merge if the style isn't empty!
      if (style != Style.empty) {
        for (var col = 0; col < w; col++) {
          final cell = buffer.getCell(
            offset.dx.toInt() + col,
            offset.dy.toInt() + i,
          );
          if (cell != null) {
            cell.style = style.merge(cell.style);
          }
        }
      }
    }

    if (listView.showScrollbar && listView.children.isNotEmpty) {
      final total = listView.children.length;
      final viewportHeight = size.height.toInt();
      if (total > viewportHeight) {
        final thumbSize = max(1, (viewportHeight * viewportHeight) ~/ total);
        final maxScrollOffset = total - viewportHeight;
        final scrollPercent = scrollOffset / maxScrollOffset;
        final thumbOffset = (scrollPercent * (viewportHeight - thumbSize))
            .round();

        for (var i = 0; i < viewportHeight; i++) {
          final isThumb = i >= thumbOffset && i < thumbOffset + thumbSize;
          final char = isThumb ? '█' : '│';
          buffer.writeString(
            offset.dx.toInt() + w - 1,
            offset.dy.toInt() + i,
            char,
            Style.empty,
          );
        }
      }
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    childElements.forEach(visitor);
  }

  @override
  void handleMouseEvent(MouseEvent event, int localX, int localY, Rect area) {
    final listView = widget as ListView;
    if (event.button == MouseButton.wheelUp) {
      scrollOffset = max(0, scrollOffset - 1);
      if (selectedIndex >= scrollOffset + size.height.toInt()) {
        selectedIndex = scrollOffset + size.height.toInt() - 1;
      }
      rebuild();
    } else if (event.button == MouseButton.wheelDown) {
      scrollOffset = min(
        max(0, listView.children.length - size.height.toInt()),
        scrollOffset + 1,
      );
      if (selectedIndex < scrollOffset) {
        selectedIndex = scrollOffset;
      }
      rebuild();
    } else if (event.type == MouseEventType.press &&
        event.button == MouseButton.left) {
      final clickedIndex = scrollOffset + localY;
      if (clickedIndex >= 0 && clickedIndex < listView.children.length) {
        selectedIndex = clickedIndex;
        listView.onSelect?.call(clickedIndex);
        rebuild();
      }
    } else if (event.type == MouseEventType.move ||
        event.type == MouseEventType.drag) {
      final hoveredIdx = scrollOffset + localY;
      if (localX >= 0 && localX < area.width && localY >= 0 && localY < area.height && hoveredIdx >= 0 && hoveredIdx < listView.children.length) {
        if (hoveredIndex != hoveredIdx) {
          hoveredIndex = hoveredIdx;
          listView.onHover?.call(hoveredIdx);
          rebuild();
        }
      } else {
        if (hoveredIndex != null) {
          hoveredIndex = null;
          listView.onHover?.call(null);
          rebuild();
        }
      }
    }
  }
}

class _RawListWidget extends ListView {
  final List<String> lines;

  _RawListWidget({
    super.key,
    required this.lines,
    super.selectedIndex,
    super.hoveredIndex,
    super.itemStyle,
    super.selectedStyle,
    super.hoveredStyle,
    super.showScrollbar,
    super.onSelect,
    super.onHover,
  }) : super(children: const []);

  @override
  Element createElement() => _RawListWidgetElement(this);
}

class _RawListWidgetElement extends LeafElement
    implements MouseEventHandlerWithArea {
  List<int> visibleIndices = [];

  int scrollOffset = 0;
  int selectedIndex = 0;
  int? hoveredIndex;

  _RawListWidgetElement(_RawListWidget super.widget);

  @override
  void mount(Element? parent) {
    final listView = widget as _RawListWidget;
    selectedIndex = listView.initialSelectedIndex;
    hoveredIndex = listView.initialHoveredIndex;
    super.mount(parent);
    rebuild();
  }

  @override
  void update(Widget newWidget) {
    final oldListView = widget as _RawListWidget;
    final newListView = newWidget as _RawListWidget;

    if (newListView.initialSelectedIndex != oldListView.initialSelectedIndex) {
      selectedIndex = newListView.initialSelectedIndex;
    }
    super.update(newWidget);
  }

  void adjustScroll(int viewportHeight) {
    final rawWidget = widget as _RawListWidget;
    final itemCount = rawWidget.lines.length;
    if (itemCount <= 0 || viewportHeight <= 0) return;
    selectedIndex = selectedIndex.clamp(0, itemCount - 1);

    if (selectedIndex < scrollOffset) {
      scrollOffset = selectedIndex;
    } else if (selectedIndex >= scrollOffset + viewportHeight) {
      scrollOffset = selectedIndex - viewportHeight + 1;
    }
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    final rawWidget = widget as _RawListWidget;
    final width = constraints.hasBoundedWidth ? constraints.maxWidth : 80;
    final height = constraints.hasBoundedHeight
        ? constraints.maxHeight
        : rawWidget.lines.length;

    adjustScroll(height);

    visibleIndices = [];
    for (var i = 0; i < height; i++) {
      final itemIdx = scrollOffset + i;
      if (itemIdx >= rawWidget.lines.length) break;
      visibleIndices.add(itemIdx);
    }

    return constraints.constrain(Size(width, height));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final rawWidget = widget as _RawListWidget;
    final w = size.width;

    for (var i = 0; i < visibleIndices.length; i++) {
      final itemIdx = visibleIndices[i];
      final isSelected = itemIdx == selectedIndex;
      final isHovered = itemIdx == hoveredIndex;
      final text = rawWidget.lines[itemIdx];

      final chars = text.characters;
      final padded = chars.length >= w
          ? chars.take(w).toString()
          : chars.toString() + (' ' * (w - chars.length));

      var style = rawWidget.itemStyle;
      if (isSelected) {
        style = rawWidget.selectedStyle;
      } else if (isHovered) {
        style = rawWidget.hoveredStyle ?? const Style(modifiers: Modifier.dim);
      }

      buffer.writeString(
        offset.dx.toInt(),
        offset.dy.toInt() + i,
        padded,
        style,
      );
    }

    if (rawWidget.showScrollbar && rawWidget.lines.isNotEmpty) {
      final total = rawWidget.lines.length;
      final viewportHeight = size.height.toInt();
      if (total > viewportHeight) {
        final thumbSize = max(1, (viewportHeight * viewportHeight) ~/ total);
        final maxScrollOffset = total - viewportHeight;
        final scrollPercent = scrollOffset / maxScrollOffset;
        final thumbOffset = (scrollPercent * (viewportHeight - thumbSize))
            .round();

        for (var i = 0; i < viewportHeight; i++) {
          final isThumb = i >= thumbOffset && i < thumbOffset + thumbSize;
          final char = isThumb ? '█' : '│';
          buffer.writeString(
            offset.dx.toInt() + w - 1,
            offset.dy.toInt() + i,
            char,
            Style.empty,
          );
        }
      }
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    // Leaf node, no dynamic child elements.
  }

  @override
  void handleMouseEvent(MouseEvent event, int localX, int localY, Rect area) {
    final rawWidget = widget as _RawListWidget;
    if (event.button == MouseButton.wheelUp) {
      scrollOffset = max(0, scrollOffset - 1);
      if (selectedIndex >= scrollOffset + size.height.toInt()) {
        selectedIndex = scrollOffset + size.height.toInt() - 1;
      }
      rebuild();
    } else if (event.button == MouseButton.wheelDown) {
      scrollOffset = min(
        max(0, rawWidget.lines.length - size.height.toInt()),
        scrollOffset + 1,
      );
      if (selectedIndex < scrollOffset) {
        selectedIndex = scrollOffset;
      }
      rebuild();
    } else if (event.type == MouseEventType.press &&
        event.button == MouseButton.left) {
      final clickedIndex = scrollOffset + localY;
      if (clickedIndex >= 0 && clickedIndex < rawWidget.lines.length) {
        selectedIndex = clickedIndex;
        rawWidget.onSelect?.call(clickedIndex);
        rebuild();
      }
    } else if (event.type == MouseEventType.move ||
        event.type == MouseEventType.drag) {
      final hoveredIdx = scrollOffset + localY;
      if (localX >= 0 && localX < area.width && localY >= 0 && localY < area.height && hoveredIdx >= 0 && hoveredIdx < rawWidget.lines.length) {
        if (hoveredIndex != hoveredIdx) {
          hoveredIndex = hoveredIdx;
          rawWidget.onHover?.call(hoveredIdx);
          rebuild();
        }
      } else {
        if (hoveredIndex != null) {
          hoveredIndex = null;
          rawWidget.onHover?.call(null);
          rebuild();
        }
      }
    }
  }
}
