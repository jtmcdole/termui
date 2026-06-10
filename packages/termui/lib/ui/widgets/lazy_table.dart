import 'package:characters/characters.dart';
import '../buffer.dart';
import '../layout.dart';
import '../style.dart';

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
  void render(Buffer buffer, Rect area) {
    if (area.width <= 0 || area.height <= 0 || itemCount <= 0) return;

    scrollOffset = scrollOffset.clamp(0, itemCount - 1);

    for (var i = 0; i < area.height; i++) {
      final index = scrollOffset + i;
      if (index >= itemCount) break;

      final childWidget = itemBuilder(index);
      final childArea = Rect(0, i, area.width, 1);
      final vp = Viewport(buffer, childArea);
      childWidget.render(vp, Rect(0, 0, area.width, 1));
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
  void render(Buffer buffer, Rect area) {
    if (area.width <= 0 || area.height <= 0) return;

    final hasHeaders = headers.isNotEmpty;
    final headerRowsCount = hasHeaders ? 2 : 0;
    final usableHeight = area.height - headerRowsCount;

    if (usableHeight <= 0) return;

    // 1. Render Headers
    if (hasHeaders) {
      final headerSb = StringBuffer();
      for (var i = 0; i < headers.length; i++) {
        final width = i < columnWidths.length ? columnWidths[i] : 10;
        final text = headers[i];
        final chars = text.characters;
        final padded = chars.length >= width
            ? chars.take(width).toString()
            : chars.toString() + (' ' * (width - chars.length));
        headerSb.write(padded);
        if (i < headers.length - 1) headerSb.write(' ');
      }
      final headerChars = headerSb.toString().characters;
      final headerStr = headerChars.length >= area.width
          ? headerChars.take(area.width).toString()
          : headerChars.toString() + (' ' * (area.width - headerChars.length));
      buffer.writeString(0, 0, headerStr, headerStyle);

      // Render Divider Line
      final dividerChar = '─';
      final divider = dividerChar * area.width;
      buffer.writeString(0, 1, divider, borderStyle);
    }

    // 2. Adjust Scroll
    adjustScroll(usableHeight);

    // 3. Render Visible Rows
    for (var r = 0; r < usableHeight; r++) {
      final rowIdx = scrollOffset + r;
      if (rowIdx >= itemCount) break;

      final rowData = itemBuilder(rowIdx);
      final isSelected = rowIdx == selectedRowIndex;
      final currentStyle = isSelected ? selectedRowStyle : rowStyle;

      final rowSb = StringBuffer();
      for (var c = 0; c < headers.length; c++) {
        final width = c < columnWidths.length ? columnWidths[c] : 10;
        final cellText = c < rowData.length ? rowData[c] : '';
        final chars = cellText.characters;
        final padded = chars.length >= width
            ? chars.take(width).toString()
            : chars.toString() + (' ' * (width - chars.length));
        rowSb.write(padded);
        if (c < headers.length - 1) rowSb.write(' ');
      }

      final rowChars = rowSb.toString().characters;
      final targetY = headerRowsCount + r;

      for (var x = 0; x < area.width; x++) {
        final char = x < rowChars.length ? rowChars.elementAt(x) : ' ';
        final cell = buffer.getCell(x, targetY);
        if (cell != null) {
          cell.char = char;
          cell.style = currentStyle;
        }
      }
    }
  }
}
