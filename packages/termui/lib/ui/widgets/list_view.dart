import 'dart:math';
import 'package:characters/characters.dart';
import '../buffer.dart';
import '../style.dart';
import '../layout.dart';
import '../event.dart' hide Modifier;
import 'text.dart';

class _ListViewState {
  int selectedIndex;
  int? hoveredIndex;
  int scrollOffset = 0;

  _ListViewState({required this.selectedIndex, this.hoveredIndex});

  void adjustScroll(int viewportHeight, int itemCount) {
    if (itemCount <= 0 || viewportHeight <= 0) return;
    selectedIndex = selectedIndex.clamp(0, itemCount - 1);

    if (selectedIndex < scrollOffset) {
      scrollOffset = selectedIndex;
    } else if (selectedIndex >= scrollOffset + viewportHeight) {
      scrollOffset = selectedIndex - viewportHeight + 1;
    }
  }
}

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

  final int _initialSelectedIndex;
  final int? _initialHoveredIndex;

  /// Whether to render a vertical scrollbar on the right edge.
  final bool showScrollbar;

  /// Callback when an item is selected by mouse click or other interaction.
  final void Function(int)? onSelect;

  /// Callback when an item is hovered by mouse.
  final void Function(int?)? onHover;

  /// Creates a [ListView] containing the specified [children].
  const ListView({
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
  }) : _initialSelectedIndex = selectedIndex,
       _initialHoveredIndex = hoveredIndex;

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

  static final _stateExpando = Expando<_ListViewState>();

  _ListViewState get _state {
    return _stateExpando[this] ??= _ListViewState(
      selectedIndex: _initialSelectedIndex,
      hoveredIndex: _initialHoveredIndex,
    );
  }

  /// The currently selected item index.
  int get selectedIndex => _state.selectedIndex;
  set selectedIndex(int val) => _state.selectedIndex = val;

  /// The currently hovered item index, if any.
  int? get hoveredIndex => _state.hoveredIndex;
  set hoveredIndex(int? val) => _state.hoveredIndex = val;

  /// The current scroll offset, representing the index of the first visible item.
  int get scrollOffset => _state.scrollOffset;
  set scrollOffset(int val) => _state.scrollOffset = val;

  /// Updates scroll offset based on selected index to keep selection visible.
  void adjustScroll(int viewportHeight) {
    _state.adjustScroll(viewportHeight, children.length);
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

  /// Creates a [ListViewElement] for [widget].
  ListViewElement(ListView super.widget);

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

    listView.adjustScroll(height);

    visibleIndices = [];
    final childConstraints = BoxConstraints.tight(Size(width, 1));

    for (var i = 0; i < height; i++) {
      final itemIdx = listView.scrollOffset + i;
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

      final isSelected = itemIdx == listView.selectedIndex;
      final isHovered = itemIdx == listView.hoveredIndex;

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
      child.paint(buffer, offset + childOffset);

      // Merge style onto the written cells
      for (var col = 0; col < w; col++) {
        final cellX = offset.dx.toInt() + col;
        final cellY = offset.dy.toInt() + i;
        final cell = buffer.getCell(cellX, cellY);
        if (cell != null) {
          cell.style = style.merge(cell.style);
        }
      }
    }

    if (listView.showScrollbar && listView.children.isNotEmpty) {
      final total = listView.children.length;
      final viewportHeight = size.height.toInt();
      if (total > viewportHeight) {
        final thumbSize = max(1, (viewportHeight * viewportHeight) ~/ total);
        final maxScrollOffset = total - viewportHeight;
        final scrollPercent = listView.scrollOffset / maxScrollOffset;
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
      listView.scrollOffset = max(0, listView.scrollOffset - 1);
      if (listView.selectedIndex >=
          listView.scrollOffset + size.height.toInt()) {
        listView.selectedIndex =
            listView.scrollOffset + size.height.toInt() - 1;
      }
      rebuild();
    } else if (event.button == MouseButton.wheelDown) {
      listView.scrollOffset = min(
        max(0, listView.children.length - size.height.toInt()),
        listView.scrollOffset + 1,
      );
      if (listView.selectedIndex < listView.scrollOffset) {
        listView.selectedIndex = listView.scrollOffset;
      }
      rebuild();
    } else if (event.type == MouseEventType.press &&
        event.button == MouseButton.left) {
      final clickedIndex = listView.scrollOffset + localY;
      if (clickedIndex >= 0 && clickedIndex < listView.children.length) {
        listView.selectedIndex = clickedIndex;
        listView.onSelect?.call(clickedIndex);
        rebuild();
      }
    } else if (event.type == MouseEventType.move ||
        event.type == MouseEventType.drag) {
      final hoveredIndex = listView.scrollOffset + localY;
      if (hoveredIndex >= 0 && hoveredIndex < listView.children.length) {
        if (listView.hoveredIndex != hoveredIndex) {
          listView.hoveredIndex = hoveredIndex;
          listView.onHover?.call(hoveredIndex);
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
  void adjustScroll(int viewportHeight) {
    _state.adjustScroll(viewportHeight, lines.length);
  }

  @override
  Element createElement() => _RawListWidgetElement(this);
}

class _RawListWidgetElement extends Element
    implements MouseEventHandlerWithArea {
  List<int> visibleIndices = [];

  _RawListWidgetElement(_RawListWidget super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final rawWidget = widget as _RawListWidget;
    final width = constraints.hasBoundedWidth ? constraints.maxWidth : 80;
    final height = constraints.hasBoundedHeight
        ? constraints.maxHeight
        : rawWidget.lines.length;

    rawWidget.adjustScroll(height);

    visibleIndices = [];
    for (var i = 0; i < height; i++) {
      final itemIdx = rawWidget.scrollOffset + i;
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
      final isSelected = itemIdx == rawWidget.selectedIndex;
      final isHovered = itemIdx == rawWidget.hoveredIndex;
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
        final scrollPercent = rawWidget.scrollOffset / maxScrollOffset;
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
      rawWidget.scrollOffset = max(0, rawWidget.scrollOffset - 1);
      if (rawWidget.selectedIndex >=
          rawWidget.scrollOffset + size.height.toInt()) {
        rawWidget.selectedIndex =
            rawWidget.scrollOffset + size.height.toInt() - 1;
      }
      rebuild();
    } else if (event.button == MouseButton.wheelDown) {
      rawWidget.scrollOffset = min(
        max(0, rawWidget.lines.length - size.height.toInt()),
        rawWidget.scrollOffset + 1,
      );
      if (rawWidget.selectedIndex < rawWidget.scrollOffset) {
        rawWidget.selectedIndex = rawWidget.scrollOffset;
      }
      rebuild();
    } else if (event.type == MouseEventType.press &&
        event.button == MouseButton.left) {
      final clickedIndex = rawWidget.scrollOffset + localY;
      if (clickedIndex >= 0 && clickedIndex < rawWidget.lines.length) {
        rawWidget.selectedIndex = clickedIndex;
        rawWidget.onSelect?.call(clickedIndex);
        rebuild();
      }
    } else if (event.type == MouseEventType.move ||
        event.type == MouseEventType.drag) {
      final hoveredIndex = rawWidget.scrollOffset + localY;
      if (hoveredIndex >= 0 && hoveredIndex < rawWidget.lines.length) {
        if (rawWidget.hoveredIndex != hoveredIndex) {
          rawWidget.hoveredIndex = hoveredIndex;
          rawWidget.onHover?.call(hoveredIndex);
          rebuild();
        }
      }
    }
  }
}
