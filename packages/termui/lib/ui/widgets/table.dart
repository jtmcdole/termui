import 'package:characters/characters.dart';
import '../buffer.dart';
import '../style.dart';
import '../layout.dart';

/// A widget for displaying tabular columns of data with optional row selection.
///
/// ### Column Widths and Layout Alignment
/// - Layout alignments are governed by [columnWidths], representing the physical
///   column span sizes in character cells.
/// - Cell text content is truncated or space-padded to exactly fit the specified
///   width of its column.
/// - Separate cells within the same row are separated by a space divider character.
///
/// ### Row Selection and Scrolling
/// - Selected row index is tracked via [selectedRowIndex].
/// - The selected row is highlighted using [selectedRowStyle] (by default, reverse video).
/// - Dynamic scroll tracking keeps the selected row inside the visible viewport:
///   [adjustScroll] calculates the required [scrollOffset] such that
///   `scrollOffset <= selectedRowIndex < scrollOffset + viewportHeight`.
///
/// ### Example Usage
///
/// ```dart
/// Table(
///   headers: const ['Name', 'Role'],
///   columnWidths: const [10, 15],
///   rows: const [
///     ['Alice', 'Developer'],
///     ['Bob', 'Designer'],
///   ],
///   selectedRowIndex: 0,
/// );
/// ```
///
/// ### Properties and Settings
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `headers` | [List]<[String]> | Header titles of the columns. |
/// | `rows` | [List]<[List]> | Grid rows containing values or sub-widgets. |
/// | `columnWidths` | [List]<[int]> | Custom column widths in character count. |
/// | `selectedRowIndex`| [int] | The index of the row currently selected/active. |
/// | `selectedRowStyle`| [Style] | Highlighter styling for the selected row cells. |
class Table extends Widget {
  /// The text labels for each column header.
  final List<String> headers;

  /// The rows of data, containing text or widget elements.
  final List<List<dynamic>> rows;

  /// The defined widths for each column, in character cells.
  final List<int> columnWidths;

  /// The index of the currently highlighted row.
  int selectedRowIndex;

  /// The current vertical scrolling offset index.
  int scrollOffset = 0;

  /// Styling applied to the table header labels.
  final Style headerStyle;

  /// Styling applied to standard unselected rows.
  final Style rowStyle;

  /// Styling applied to the highlighted row.
  final Style selectedRowStyle;

  /// Styling for structural borders and dividers.
  final Style borderStyle;

  /// Creates a new Table widget with the provided data and column definitions.
  Table({
    required this.headers,
    required this.rows,
    required this.columnWidths,
    this.selectedRowIndex = 0,
    this.headerStyle = const Style(modifiers: Modifier.bold),
    this.rowStyle = Style.empty,
    this.selectedRowStyle = const Style(modifiers: Modifier.reverse),
    this.borderStyle = const Style(modifiers: Modifier.dim),
  });

  /// Adjusts the scroll offset based on the selected row and table height.
  void adjustScroll(int viewportHeight) {
    if (rows.isEmpty || viewportHeight <= 0) return;
    selectedRowIndex = selectedRowIndex.clamp(0, rows.length - 1);

    if (selectedRowIndex < scrollOffset) {
      scrollOffset = selectedRowIndex;
    } else if (selectedRowIndex >= scrollOffset + viewportHeight) {
      scrollOffset = selectedRowIndex - viewportHeight + 1;
    }
  }

  @override
  Element createElement() => TableElement(this);

  @override
  void render(Buffer buffer, Rect area) {
    // Fallback if rendered outside element tree
    final el = TableElement(this)..mount(null);
    el.render(buffer, area);
  }
}

/// Mount element class corresponding to [Table], preserving per-cell states.
class TableElement extends Element {
  /// Caches child elements created for cells with widget values.
  List<List<Element?>> cellElements = [];

  /// Instantiates the rendering element for the given table.
  TableElement(Table super.widget);

  @override
  void visitChildren(void Function(Element child) visitor) {
    for (final row in cellElements) {
      for (final el in row) {
        if (el != null) visitor(el);
      }
    }
  }

  @override
  void render(Buffer buffer, Rect area) {
    final table = widget as Table;
    if (table.headers.isEmpty ||
        table.columnWidths.isEmpty ||
        area.height <= 2 ||
        area.width <= 0) {
      return;
    }

    // 1. Render Headers
    final headerSb = StringBuffer();
    for (var i = 0; i < table.headers.length; i++) {
      final width = i < table.columnWidths.length ? table.columnWidths[i] : 10;
      final text = table.headers[i];
      final chars = text.characters;
      final padded = chars.length >= width
          ? chars.take(width).toString()
          : chars.toString() + (' ' * (width - chars.length));
      headerSb.write(padded);
      if (i < table.headers.length - 1) headerSb.write(' ');
    }
    final headerChars = headerSb.toString().characters;
    final headerStr = headerChars.length >= area.width
        ? headerChars.take(area.width).toString()
        : headerChars.toString() + (' ' * (area.width - headerChars.length));
    buffer.writeString(0, 0, headerStr, table.headerStyle);

    // 2. Render Header Divider Line
    final dividerChar = '─';
    final divider = dividerChar * area.width;
    buffer.writeString(0, 1, divider, table.borderStyle);

    // 3. Render Rows with Scroll Adjustment
    final usableHeight = area.height - 2;
    table.adjustScroll(usableHeight);

    // Synchronize cell elements list
    while (cellElements.length < table.rows.length) {
      cellElements.add(
        List.filled(table.headers.length, null, growable: false),
      );
    }
    if (cellElements.length > table.rows.length) {
      cellElements.removeRange(table.rows.length, cellElements.length);
    }

    for (var r = 0; r < usableHeight; r++) {
      final rowIdx = table.scrollOffset + r;
      if (rowIdx >= table.rows.length) break;

      final rowData = table.rows[rowIdx];
      final isSelected = rowIdx == table.selectedRowIndex;
      final currentStyle = isSelected ? table.selectedRowStyle : table.rowStyle;

      int startX = 0;
      for (var c = 0; c < table.headers.length; c++) {
        final colWidth = c < table.columnWidths.length
            ? table.columnWidths[c]
            : 10;
        final cellData = c < rowData.length ? rowData[c] : '';

        final cellRect = Rect(startX, 2 + r, colWidth, 1);
        final vp = Viewport(buffer, cellRect);

        if (cellData is Widget) {
          // Pre-fill cell viewport with space using currentStyle
          vp.fill(Cell(' ', currentStyle));

          // Mount / update child element
          Element? cellEl = cellElements[rowIdx][c];
          if (cellEl != null &&
              cellEl.widget.runtimeType == cellData.runtimeType) {
            cellEl.update(cellData);
          } else {
            cellEl = cellData.createElement();
            cellEl.mount(this);
            cellElements[rowIdx][c] = cellEl;
          }

          cellEl.render(vp, Rect(0, 0, colWidth, 1));
          // We do NOT apply selection style on top of the rendered cell cells
          // to prevent negative image and custom styling override.
        } else {
          // Standard text rendering
          final cellText = cellData.toString();
          final chars = cellText.characters;
          final padded = chars.length >= colWidth
              ? chars.take(colWidth).toString()
              : chars.toString() + (' ' * (colWidth - chars.length));
          vp.writeString(0, 0, padded, currentStyle);
        }

        // Render spacing between columns
        if (c < table.headers.length - 1) {
          final sepX = startX + colWidth;
          if (sepX < area.width) {
            buffer.writeString(sepX, 2 + r, ' ', currentStyle);
          }
        }

        startX += colWidth + 1;
      }

      // Pad remainder of the row to fill area.width
      if (startX < area.width) {
        final remainder = area.width - startX;
        buffer.writeString(startX, 2 + r, ' ' * remainder, currentStyle);
      }
    }
  }
}
