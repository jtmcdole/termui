import 'dart:math';
import 'package:termui/termui.dart';

/// A virtual scrolling list widget. Only renders items within the visible viewport.
class LazyList extends Widget {
  /// Total number of items in the list.
  final int itemCount;

  /// Builder function to render a widget for the given index.
  final Widget Function(int index) itemBuilder;

  /// The current scroll position index.
  int scrollOffset;

  /// Creates a [LazyList].
  LazyList({
    required this.itemCount,
    required this.itemBuilder,
    this.scrollOffset = 0,
  });

  @override
  Element createElement() => LazyListElement(this);
}

/// Mount element class corresponding to [LazyList].
class LazyListElement extends Element {
  /// Caches child elements created for the visible items.
  List<Element?> childElements = [];

  /// Instantiates the rendering element for the given LazyList.
  LazyListElement(LazyList super.widget);

  @override
  void mount(Element? parent) {
    super.mount(parent);
    rebuild();
  }

  @override
  void unmount() {
    for (final el in childElements) {
      el?.unmount();
    }
    childElements.clear();
    super.unmount();
  }

  @override
  void update(Widget newWidget) {
    super.update(newWidget);
    rebuild();
  }

  @override
  void rebuild() {
    final lazy = widget as LazyList;
    _reconcileChildren(lazy.scrollOffset, childElements.length);
  }

  void _reconcileChildren(int start, int count) {
    final lazy = widget as LazyList;
    final targetCount = min(count, lazy.itemCount - start);

    while (childElements.length > targetCount) {
      childElements.removeLast()?.unmount();
    }

    while (childElements.length < targetCount) {
      childElements.add(null);
    }

    for (var i = 0; i < targetCount; i++) {
      final index = start + i;
      if (index >= lazy.itemCount) break;
      final childWidget = lazy.itemBuilder(index);
      final currentChild = childElements[i];
      if (currentChild != null &&
          Widget.canUpdate(currentChild.widget, childWidget)) {
        currentChild.update(childWidget);
      } else {
        currentChild?.unmount();
        final newChild = childWidget.createElement();
        newChild.mount(this);
        childElements[i] = newChild;
      }
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    for (final el in childElements) {
      if (el != null) visitor(el);
    }
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    final lazy = widget as LazyList;
    final width = constraints.hasBoundedWidth ? constraints.maxWidth : 80;
    final height = constraints.hasBoundedHeight
        ? constraints.maxHeight
        : lazy.itemCount;

    if (lazy.itemCount > 0) {
      lazy.scrollOffset = lazy.scrollOffset.clamp(0, lazy.itemCount - 1);
    } else {
      lazy.scrollOffset = 0;
    }

    final visibleCount = min(height, lazy.itemCount - lazy.scrollOffset);
    _reconcileChildren(lazy.scrollOffset, height);

    for (var i = 0; i < visibleCount; i++) {
      final el = childElements[i];
      if (el != null) {
        el.layout(BoxConstraints.tight(Size(width, 1)));
      }
    }

    return constraints.constrain(Size(width, height));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final lazy = widget as LazyList;
    final limit = min(size.height, lazy.itemCount - lazy.scrollOffset);
    for (var i = 0; i < limit; i++) {
      final el = childElements[i];
      if (el != null) {
        final childRect = Rect(offset.dx, offset.dy + i, size.width, 1);
        final vp = Viewport(buffer, childRect);
        el.paint(vp, Offset.zero);
      }
    }
  }
}

/// A virtual scrolling table widget. Only requests and renders rows within the viewport.
///
/// ### Column Widths and Layout Alignment
/// - Column alignments are mapped directly to [columnWidths] where cells are
///   truncated or padded to match specified character spans.
///
/// ### Row Selection and Scrolling
/// - Selected row index is tracked via [selectedRowIndex].
/// - [adjustScroll] dynamically recalculates [scrollOffset] to keep the active
///   selection visible in the viewport.
/// - Since only visible rows are processed via [itemBuilder], this widget scales
///   efficiently to thousands of rows without memory overhead.
///
/// ### Example Usage
///
/// ```dart
/// LazyTable(
///   headers: const ['ID', 'Logs'],
///   columnWidths: const [5, 40],
///   itemCount: 10000,
///   itemBuilder: (index) => ['#$index', 'Log message at $index'],
///   selectedRowIndex: activeRow,
/// );
/// ```
///
/// ### Properties and Settings
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `headers` | [List]<[String]> | Column title strings. |
/// | `columnWidths` | [List]<[int]> | Monospaced width boundaries for each column. |
/// | `itemCount` | [int] | Total size of the data source list. |
/// | `itemBuilder` | `List<String> Function(int)`| Dynamic row builder callback. |
/// | `selectedRowIndex`| [int] | Active highlighted row index. |
class LazyTable extends Widget {
  /// Column title strings.
  final List<String> headers;

  /// Monospaced width boundaries for each column.
  final List<int> columnWidths;

  /// Total size of the data source list.
  final int itemCount;

  /// Dynamic row builder callback.
  final List<String> Function(int index) itemBuilder;

  /// Current scroll offset for the top visible row.
  int scrollOffset;

  /// Active highlighted row index.
  int selectedRowIndex;

  /// Style applied to the header row.
  final Style headerStyle;

  /// Default style applied to unselected rows.
  final Style rowStyle;

  /// Style applied to the selected row.
  final Style selectedRowStyle;

  /// Style applied to table borders.
  final Style borderStyle;

  /// Creates a [LazyTable].
  LazyTable({
    required this.headers,
    required this.columnWidths,
    required this.itemCount,
    required this.itemBuilder,
    this.scrollOffset = 0,
    this.selectedRowIndex = 0,
    this.headerStyle = const Style(modifiers: Modifier.bold),
    this.rowStyle = Style.empty,
    this.selectedRowStyle = const Style(modifiers: Modifier.reverse),
    this.borderStyle = const Style(modifiers: Modifier.dim),
  });

  /// Adjusts the scroll offset to keep selected row visible.
  void adjustScroll(int viewportHeight) {
    if (itemCount <= 0 || viewportHeight <= 0) return;
    selectedRowIndex = selectedRowIndex.clamp(0, itemCount - 1);

    if (selectedRowIndex < scrollOffset) {
      scrollOffset = selectedRowIndex;
    } else if (selectedRowIndex >= scrollOffset + viewportHeight) {
      scrollOffset = selectedRowIndex - viewportHeight + 1;
    }
  }

  @override
  Element createElement() => LazyTableElement(this);
}

/// Mount element class corresponding to [LazyTable].
class LazyTableElement extends Element {
  /// Column widths resolved during [performLayout].
  List<int> resolvedColumnWidths = [];

  /// Instantiates the rendering element for the given LazyTable.
  LazyTableElement(LazyTable super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final table = widget as LazyTable;
    final width = constraints.hasBoundedWidth ? constraints.maxWidth : 80;
    final height = constraints.hasBoundedHeight
        ? constraints.maxHeight
        : (table.itemCount + (table.headers.isNotEmpty ? 2 : 0));

    final hasHeaders = table.headers.isNotEmpty;
    final headerRowsCount = hasHeaders ? 2 : 0;
    final usableHeight = height - headerRowsCount;

    if (usableHeight > 0) {
      table.adjustScroll(usableHeight);
    }

    resolvedColumnWidths = List<int>.generate(table.headers.length, (c) {
      return c < table.columnWidths.length ? table.columnWidths[c] : 10;
    });

    return constraints.constrain(Size(width, height));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final table = widget as LazyTable;
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    final hasHeaders = table.headers.isNotEmpty;
    final headerRowsCount = hasHeaders ? 2 : 0;
    final usableHeight = h - headerRowsCount;
    if (usableHeight <= 0) return;

    final columnsTotalWidth =
        resolvedColumnWidths.fold<int>(0, (prev, val) => prev + val) +
        (hasHeaders ? table.headers.length - 1 : 0);

    if (hasHeaders) {
      final headerStr = _formatLine(
        table.headers,
        table.headers.length,
        columnsTotalWidth,
        w,
      );
      buffer.writeString(offset.dx, offset.dy, headerStr, table.headerStyle);
      buffer.writeString(offset.dx, offset.dy + 1, '─' * w, table.borderStyle);
    }

    for (var r = 0; r < usableHeight; r++) {
      final rowIdx = table.scrollOffset + r;
      if (rowIdx >= table.itemCount) break;

      final rowData = table.itemBuilder(rowIdx);
      final currentStyle = rowIdx == table.selectedRowIndex
          ? table.selectedRowStyle
          : table.rowStyle;
      final rowStr = _formatLine(
        rowData,
        table.headers.length,
        columnsTotalWidth,
        w,
      );
      buffer.writeString(
        offset.dx,
        offset.dy + headerRowsCount + r,
        rowStr,
        currentStyle,
      );
    }
  }

  String _formatLine(
    List<String> cells,
    int colCount,
    int columnsTotalWidth,
    int width,
  ) {
    final sb = StringBuffer();
    for (var c = 0; c < colCount; c++) {
      final cellText = c < cells.length ? cells[c] : '';
      sb.write(padOrTruncate(cellText, resolvedColumnWidths[c]));
      if (c < colCount - 1) sb.write(' ');
    }
    if (columnsTotalWidth <= width) {
      if (columnsTotalWidth < width) {
        sb.write(' ' * (width - columnsTotalWidth));
      }
      return sb.toString();
    }
    return padOrTruncate(sb.toString(), width);
  }
}
