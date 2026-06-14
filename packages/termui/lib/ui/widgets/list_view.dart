import 'package:characters/characters.dart';
import '../buffer.dart';
import '../style.dart';
import '../layout.dart';
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

  /// Creates a [ListView] containing the specified [children].
  const ListView({
    super.key,
    required this.children,
    int selectedIndex = 0,
    int? hoveredIndex,
    this.itemStyle = Style.empty,
    this.selectedStyle = const Style(modifiers: Modifier.reverse),
    this.hoveredStyle,
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
  }) {
    return ListView(
      key: key,
      children: items.map((text) => Text(text)).toList(),
      selectedIndex: selectedIndex,
      hoveredIndex: hoveredIndex,
      itemStyle: itemStyle,
      selectedStyle: selectedStyle,
      hoveredStyle: hoveredStyle,
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
  }) {
    return _RawListWidget(
      key: key,
      lines: lines,
      selectedIndex: selectedIndex,
      hoveredIndex: hoveredIndex,
      itemStyle: itemStyle,
      selectedStyle: selectedStyle,
      hoveredStyle: hoveredStyle,
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
class ListViewElement extends Element {
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
  void paint(Buffer buffer, Offset offset) {
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
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    childElements.forEach(visitor);
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
  }) : super(children: const []);

  @override
  void adjustScroll(int viewportHeight) {
    _state.adjustScroll(viewportHeight, lines.length);
  }

  @override
  Element createElement() => _RawListWidgetElement(this);
}

class _RawListWidgetElement extends Element {
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
  void paint(Buffer buffer, Offset offset) {
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
  }
}
