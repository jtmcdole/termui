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
    // Reconcile cell elements list
    while (cellElements.length < table.rows.length) {
      cellElements.add(
        List.filled(table.headers.length, null, growable: false),
      );
    }
    while (cellElements.length > table.rows.length) {
      final removed = cellElements.removeLast();
      for (final el in removed) {
        el?.unmount();
      }
    }

    for (var r = 0; r < table.rows.length; r++) {
      final rowData = table.rows[r];
      if (cellElements[r].length != table.headers.length) {
        for (final el in cellElements[r]) {
          el?.unmount();
        }
        cellElements[r] = List.filled(
          table.headers.length,
          null,
          growable: false,
        );
      }
      for (var c = 0; c < table.headers.length; c++) {
        final cellData = c < rowData.length ? rowData[c] : '';
        if (cellData is Widget) {
          Element? cellEl = cellElements[r][c];
          if (cellEl != null &&
              cellEl.widget.runtimeType == cellData.runtimeType) {
            cellEl.update(cellData);
          } else {
            cellEl?.unmount();
            cellEl = cellData.createElement();
            cellEl.mount(this);
            cellElements[r][c] = cellEl;
          }
        } else {
          cellElements[r][c]?.unmount();
          cellElements[r][c] = null;
        }
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

    // 1. Render Headers
    final headerSb = StringBuffer();
    for (var i = 0; i < table.headers.length; i++) {
      final width = resolvedColumnWidths[i];
      final text = table.headers[i];
      final padded = padOrTruncate(text, width);
      headerSb.write(padded);
      if (i < table.headers.length - 1) headerSb.write(' ');
    }

    final int columnsTotalWidth =
        resolvedColumnWidths.fold<int>(0, (prev, val) => prev + val) +
        (table.headers.isNotEmpty ? table.headers.length - 1 : 0);

    String headerStr;
    if (columnsTotalWidth <= w) {
      if (columnsTotalWidth < w) {
        headerSb.write(' ' * (w - columnsTotalWidth));
      }
      headerStr = headerSb.toString();
    } else {
      headerStr = padOrTruncate(headerSb.toString(), w);
    }
    buffer.writeString(offset.dx, offset.dy, headerStr, table.headerStyle);

    // 2. Render Header Divider Line
    final dividerChar = '─';
    final divider = dividerChar * w;
    buffer.writeString(offset.dx, offset.dy + 1, divider, table.borderStyle);

    // 3. Render Rows
    final usableHeight = h - 2;
    for (var r = 0; r < usableHeight; r++) {
      final rowIdx = table.scrollOffset + r;
      if (rowIdx >= table.rows.length) break;

      final rowData = table.rows[rowIdx];
      final isSelected = rowIdx == table.selectedRowIndex;
      final currentStyle = isSelected ? table.selectedRowStyle : table.rowStyle;

      int startX = 0;
      for (var c = 0; c < table.headers.length; c++) {
        final colWidth = resolvedColumnWidths[c];
        final cellData = c < rowData.length ? rowData[c] : '';
        final cellStartX = columnXOffsets[c];

        final cellRect = Rect(
          offset.dx + cellStartX,
          offset.dy + 2 + r,
          colWidth,
          1,
        );
        final vp = Viewport(buffer, cellRect);

        if (cellData is Widget) {
          vp.fillAttributes(
            char: ' ',
            fg: currentStyle.foreground?.argb ?? 0,
            bg: currentStyle.background?.argb ?? 0,
            modifiers: currentStyle.modifiers,
          );
          final cellEl = cellElements[rowIdx][c];
          if (cellEl != null) {
            cellEl.paint(vp, Offset.zero);
          }
        } else {
          final cellText = cellData.toString();
          final padded = padOrTruncate(cellText, colWidth);
          vp.writeString(0, 0, padded, currentStyle);
        }

        if (c < table.headers.length - 1) {
          final sepX = cellStartX + colWidth;
          if (sepX < w) {
            buffer.writeString(
              offset.dx + sepX,
              offset.dy + 2 + r,
              ' ',
              currentStyle,
            );
          }
        }

        startX += colWidth + 1;
      }

      if (startX < w) {
        final remainder = w - startX;
        buffer.writeString(
          offset.dx + startX,
          offset.dy + 2 + r,
          ' ' * remainder,
          currentStyle,
        );
      }
    }
  }
}
