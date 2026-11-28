import 'package:termui/termui.dart';

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
  final List<List<Object?>> rows;

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
}

/// Mount element class corresponding to [Table], preserving per-cell states.
class TableElement extends Element {
  /// Caches child elements created for cells with widget values.
  List<List<Element?>> cellElements = [];

  /// Caching column widths resolved during layout.
  List<int> resolvedColumnWidths = [];

  /// Caching column X offsets computed during layout.
  List<int> columnXOffsets = [];

  /// Caching total content width of the table.
  int totalContentWidth = 0;

  /// Instantiates the rendering element for the given table.
  TableElement(Table super.widget);

  @override
  void mount(Element? parent) {
    super.mount(parent);
    rebuild();
  }

  @override
  void unmount() {
    for (final row in cellElements) {
      for (final el in row) {
        el?.unmount();
      }
    }
    cellElements.clear();
    super.unmount();
  }

  @override
  void update(Widget newWidget) {
    super.update(newWidget);
    rebuild();
  }

  @override
  void rebuild() {
    final table = widget as Table;
    final colCount = table.headers.length;
    while (cellElements.length < table.rows.length) {
      cellElements.add(List.filled(colCount, null, growable: false));
    }
    while (cellElements.length > table.rows.length) {
      _unmountRow(cellElements.removeLast());
    }

    for (var r = 0; r < table.rows.length; r++) {
      _reconcileRow(r, table.rows[r], colCount);
    }
  }

  static void _unmountRow(List<Element?> row) {
    for (final el in row) {
      el?.unmount();
    }
  }

  void _reconcileRow(int rowIdx, List<Object?> rowData, int colCount) {
    if (cellElements[rowIdx].length != colCount) {
      _unmountRow(cellElements[rowIdx]);
      cellElements[rowIdx] = List.filled(colCount, null, growable: false);
    }
    for (var c = 0; c < colCount; c++) {
      final cellData = c < rowData.length ? rowData[c] : '';
      if (cellData is Widget) {
        final existing = cellElements[rowIdx][c];
        if (existing != null && Widget.canUpdate(existing.widget, cellData)) {
          existing.update(cellData);
        } else {
          existing?.unmount();
          final created = cellData.createElement();
          created.mount(this);
          cellElements[rowIdx][c] = created;
        }
      } else {
        cellElements[rowIdx][c]?.unmount();
        cellElements[rowIdx][c] = null;
      }
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    for (final row in cellElements) {
      for (final el in row) {
        if (el != null) visitor(el);
      }
    }
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    final table = widget as Table;
    final width = constraints.hasBoundedWidth ? constraints.maxWidth : 80;
    final height = constraints.hasBoundedHeight
        ? constraints.maxHeight
        : (table.rows.length + 2);

    final usableHeight = height - 2;
    table.adjustScroll(usableHeight);

    // Calculate column widths
    resolvedColumnWidths = List<int>.generate(table.headers.length, (c) {
      return c < table.columnWidths.length ? table.columnWidths[c] : 10;
    });

    // Compute cell offsets
    columnXOffsets = [];
    int startX = 0;
    for (var c = 0; c < table.headers.length; c++) {
      columnXOffsets.add(startX);
      startX += resolvedColumnWidths[c] + 1;
    }
    totalContentWidth = startX > 0 ? startX - 1 : 0;

    // Layout child elements
    for (var r = 0; r < table.rows.length; r++) {
      for (var c = 0; c < table.headers.length; c++) {
        final cellEl = cellElements[r][c];
        if (cellEl != null) {
          final colWidth = resolvedColumnWidths[c];
          cellEl.layout(BoxConstraints.tight(Size(colWidth, 1)));
        }
      }
    }

    return constraints.constrain(Size(width, height));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final table = widget as Table;
    final w = size.width;
    final h = size.height;
    if (table.headers.isEmpty ||
        table.columnWidths.isEmpty ||
        h <= 2 ||
        w <= 0) {
      return;
    }

    final headerSb = StringBuffer();
    for (var i = 0; i < table.headers.length; i++) {
      headerSb.write(padOrTruncate(table.headers[i], resolvedColumnWidths[i]));
      if (i < table.headers.length - 1) headerSb.write(' ');
    }
    final String headerStr;
    if (totalContentWidth <= w) {
      headerSb.write(' ' * (w - totalContentWidth));
      headerStr = headerSb.toString();
    } else {
      headerStr = padOrTruncate(headerSb.toString(), w);
    }
    buffer.writeString(offset.dx, offset.dy, headerStr, table.headerStyle);
    buffer.writeString(offset.dx, offset.dy + 1, '─' * w, table.borderStyle);

    final usableHeight = h - 2;
    for (var r = 0; r < usableHeight; r++) {
      final rowIdx = table.scrollOffset + r;
      if (rowIdx >= table.rows.length) break;
      _paintRow(buffer, offset, table, rowIdx, offset.dy + 2 + r, w);
    }
  }

  void _paintRow(
    Buffer buffer,
    Offset offset,
    Table table,
    int rowIdx,
    int targetY,
    int width,
  ) {
    final rowData = table.rows[rowIdx];
    final currentStyle = rowIdx == table.selectedRowIndex
        ? table.selectedRowStyle
        : table.rowStyle;

    var startX = 0;
    for (var c = 0; c < table.headers.length; c++) {
      final colWidth = resolvedColumnWidths[c];
      final cellData = c < rowData.length ? rowData[c] : '';
      final cellStartX = columnXOffsets[c];
      final vp = Viewport(
        buffer,
        Rect(offset.dx + cellStartX, targetY, colWidth, 1),
      );

      if (cellData is Widget) {
        vp.fillAttributes(
          char: ' ',
          fg: currentStyle.foreground?.argb ?? 0,
          bg: currentStyle.background?.argb ?? 0,
          modifiers: currentStyle.modifiers,
        );
        cellElements[rowIdx][c]?.paint(vp, Offset.zero);
      } else {
        vp.writeString(
          0,
          0,
          padOrTruncate('$cellData', colWidth),
          currentStyle,
        );
      }

      final sepX = cellStartX + colWidth;
      if (c < table.headers.length - 1 && sepX < width) {
        buffer.writeString(offset.dx + sepX, targetY, ' ', currentStyle);
      }
      startX += colWidth + 1;
    }

    if (startX < width) {
      buffer.writeString(
        offset.dx + startX,
        targetY,
        ' ' * (width - startX),
        currentStyle,
      );
    }
  }
}
