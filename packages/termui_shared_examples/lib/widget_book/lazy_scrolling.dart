import 'package:termui/termui.dart';
import 'package:termui/ui/event.dart' as ui;
import 'example_base.dart';

/// Example demonstrating a lazily-rendered table with a large number of items.
class LazyScrollingExample extends WidgetBookExample {
  /// The current scroll offset of the table.
  int lazyTableOffset = 0;

  /// The index of the currently selected row.
  int lazyTableSelected = 0;

  /// Whether the user is currently dragging the scrollbar.
  bool isDraggingScrollbar = false;
  int _lastHeight = 16;

  /// The table widget displaying the items lazily.
  final lazyTableDemo = LazyTable(
    headers: const ['Index', 'Item Name', 'Status'],
    columnWidths: const [10, 25, 12],
    itemCount: 1000000,
    itemBuilder: (index) => [
      '#$index',
      'Virtual Item $index',
      index % 3 == 0 ? 'Success' : (index % 3 == 1 ? 'Pending' : 'Failed'),
    ],
    headerStyle: const Style(
      foreground: CharmColors.charple,
      modifiers: Modifier.bold,
    ),
    selectedRowStyle: const Style(
      foreground: CharmColors.pepper,
      background: CharmColors.julep,
      modifiers: Modifier.bold,
    ),
    borderStyle: const Style(
      foreground: CharmColors.squid,
      modifiers: Modifier.dim,
    ),
  );

  @override
  Widget build({
    required bool focusDemoPane,
    required int width,
    required int height,
  }) {
    _lastHeight = height;
    lazyTableDemo.scrollOffset = lazyTableOffset;
    lazyTableDemo.selectedRowIndex = lazyTableSelected;

    final scrollBar = ScrollBar(
      viewportHeight: height,
      totalItems: 1000000,
      scrollOffset: lazyTableOffset,
      onScrollChanged: (val) {},
    );

    return Row([
      Expanded(child: lazyTableDemo),
      SizedBox(width: 1, child: scrollBar),
    ]);
  }

  @override
  bool handleKeyEvent(ui.KeyEvent event) {
    final usableHeight = _lastHeight - 2;
    if (event.type == ui.KeyType.up) {
      lazyTableSelected = (lazyTableSelected - 1).clamp(0, 999999);
      lazyTableDemo.selectedRowIndex = lazyTableSelected;
      lazyTableDemo.adjustScroll(usableHeight);
      lazyTableOffset = lazyTableDemo.scrollOffset;
      return true;
    } else if (event.type == ui.KeyType.down) {
      lazyTableSelected = (lazyTableSelected + 1).clamp(0, 999999);
      lazyTableDemo.selectedRowIndex = lazyTableSelected;
      lazyTableDemo.adjustScroll(usableHeight);
      lazyTableOffset = lazyTableDemo.scrollOffset;
      return true;
    } else if (event.type == ui.KeyType.pageUp) {
      lazyTableSelected = (lazyTableSelected - usableHeight).clamp(0, 999999);
      lazyTableDemo.selectedRowIndex = lazyTableSelected;
      lazyTableDemo.adjustScroll(usableHeight);
      lazyTableOffset = lazyTableDemo.scrollOffset;
      return true;
    } else if (event.type == ui.KeyType.pageDown) {
      lazyTableSelected = (lazyTableSelected + usableHeight).clamp(0, 999999);
      lazyTableDemo.selectedRowIndex = lazyTableSelected;
      lazyTableDemo.adjustScroll(usableHeight);
      lazyTableOffset = lazyTableDemo.scrollOffset;
      return true;
    }
    return false;
  }

  @override
  void handleMouseEvent(
    ui.MouseEvent event,
    int localX,
    int localY,
    int width,
    int height,
  ) {
    if (event.type == ui.MouseEventType.press) {
      if (localX == width - 1) {
        isDraggingScrollbar = true;
        final scrollBarDemo = ScrollBar(
          viewportHeight: height,
          totalItems: 1000000,
          scrollOffset: lazyTableOffset,
          onScrollChanged: (val) {
            lazyTableOffset = val;
          },
        );
        scrollBarDemo.handleMouseEvent(event, 0, localY);
      }
    } else if (event.type == ui.MouseEventType.drag && isDraggingScrollbar) {
      final scrollBarDemo = ScrollBar(
        viewportHeight: height,
        totalItems: 1000000,
        scrollOffset: lazyTableOffset,
        onScrollChanged: (val) {
          lazyTableOffset = val;
        },
      );
      scrollBarDemo.handleMouseEvent(event, 0, localY);
    } else if (event.type == ui.MouseEventType.release) {
      isDraggingScrollbar = false;
    }

    if (event.button == ui.MouseButton.wheelDown) {
      lazyTableOffset = (lazyTableOffset + 1).clamp(0, 1000000 - height);
    } else if (event.button == ui.MouseButton.wheelUp) {
      lazyTableOffset = (lazyTableOffset - 1).clamp(0, 1000000 - height);
    }
  }

  @override
  Map<String, String> get helpBindings => {
    'Up/Down': 'Select row',
    'Mouse Scroll/Drag': 'Scroll Table',
  };
}
