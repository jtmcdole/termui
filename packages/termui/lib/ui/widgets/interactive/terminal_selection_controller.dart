import 'dart:math';

import '../../buffer.dart';
import '../../style.dart';
import '../core/geometry.dart';
import '../display/kitty_image.dart';

/// Soft-wrap metadata, grapheme cells, and optional `OSC 8` URIs for a virtual row.
typedef VirtualLineSlice = ({
  bool isWrapped,
  List<String> characters,
  List<String?>? uris,
});

/// Callback returning cell data for [virtualRow], or `null` when out of bounds.
typedef VirtualLineLookup = VirtualLineSlice? Function(int virtualRow);

/// Resolved hyperlink URI and its inclusive virtual-buffer cell span.
typedef ResolvedTerminalLink = ({
  String uri,
  int startCol,
  int startRow,
  int endCol,
  int endRow,
});

/// An interface for objects that provide change notifications to listeners.
abstract interface class TerminalListenable {
  /// Adds a listener to be notified when the state changes.
  void addListener(void Function() listener);

  /// Removes a previously registered listener.
  void removeListener(void Function() listener);
}

/// The selection behavior mode for a terminal selection.
enum SelectionMode {
  /// Linear character/stream selection across rows following terminal text flow.
  character,

  /// Word-snapped selection mode.
  word,

  /// Full-row line selection mode.
  line,

  /// Rectangular block/box selection across a 2D cell coordinate rectangle.
  block;

  /// Alias for [character] stream selection.
  static const SelectionMode normal = character;

  /// Alias for [character] stream selection.
  static const SelectionMode stream = character;

  /// Alias for [block] rectangular box selection.
  static const SelectionMode box = block;
}

/// Immutable 0-based `(col, row)` coordinate in a terminal [Buffer].
final class SelectionPoint {
  /// Zero-based column index.
  final int col;

  /// Zero-based row index.
  final int row;

  /// Creates a [SelectionPoint] at ([col], [row]).
  const SelectionPoint(this.col, this.row);

  /// Alias for [col].
  int get x => col;

  /// Alias for [row].
  int get y => row;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SelectionPoint && other.col == col && other.row == row;

  @override
  int get hashCode => Object.hash(col, row);

  @override
  String toString() => 'SelectionPoint($col, $row)';
}

/// Immutable inclusive cell bounds `(minCol..maxCol, minRow..maxRow)` for selection clamping.
final class SelectionRegion {
  /// Minimum inclusive column index.
  final int minCol;

  /// Maximum inclusive column index.
  final int maxCol;

  /// Minimum inclusive row index.
  final int minRow;

  /// Maximum inclusive row index.
  final int maxRow;

  /// Creates a [SelectionRegion].
  const SelectionRegion({
    required this.minCol,
    required this.maxCol,
    required this.minRow,
    required this.maxRow,
  });

  /// Creates a [SelectionRegion] from a [Rect] with positive dimensions.
  factory SelectionRegion.fromRect(Rect rect) => SelectionRegion(
    minCol: rect.x,
    maxCol: rect.x + rect.width - 1,
    minRow: rect.y,
    maxRow: rect.y + rect.height - 1,
  );

  /// Whether ([col], [row]) lies inside this region (inclusive).
  bool contains(int col, int row) =>
      col >= minCol && col <= maxCol && row >= minRow && row <= maxRow;

  /// Returns a copy of this region translated by ([dCol], [dRow]).
  SelectionRegion translate({int dCol = 0, int dRow = 0}) =>
      (dCol == 0 && dRow == 0)
      ? this
      : SelectionRegion(
          minCol: minCol + dCol,
          maxCol: maxCol + dCol,
          minRow: minRow + dRow,
          maxRow: maxRow + dRow,
        );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SelectionRegion &&
          other.minCol == minCol &&
          other.maxCol == maxCol &&
          other.minRow == minRow &&
          other.maxRow == maxRow;

  @override
  int get hashCode => Object.hash(minCol, maxCol, minRow, maxRow);

  @override
  String toString() =>
      'SelectionRegion(minCol: $minCol, maxCol: $maxCol, '
      'minRow: $minRow, maxRow: $maxRow)';
}

/// A controller that manages terminal cell selection state, supporting character/stream,
/// word, line, and rectangular block/box selection modes, pane region clamping,
/// virtual-scrollback coordinate offsets, wide-grapheme boundary snapping,
/// unified `OSC 8` + plain-text link resolution, and clipboard text extraction.
class TerminalSelectionController implements TerminalListenable {
  static const int _maxLinkWrapRows = 16;
  static const String _urlExcludedChars =
      r'\s<>"`\\\u0000-\u001F\u007F-\u009F\u00AB\u00BB\u2018-\u201F\u2026\u2500-\u259F\[\]'
      "'";
  static final RegExp _trailingSpaces = RegExp(r' +$');
  static final RegExp _wordCharPattern = RegExp(
    r'[\p{L}\p{N}_]',
    unicode: true,
  );

  // Matches plain-text http://, https://, and mailto: candidates up to excluded delimiters.
  static final RegExp _plainLinkCandidatePattern = RegExp(
    '(?:https?://|mailto:)(?:\\[[^$_urlExcludedChars]*\\]|[^$_urlExcludedChars])+',
    caseSensitive: false,
  );

  final List<void Function()> _listeners = [];
  bool _disposed = false;

  SelectionMode _mode = SelectionMode.character;
  SelectionPoint? _anchor;
  SelectionPoint? _focus;
  (SelectionPoint start, SelectionPoint end)? _wordAnchor;
  SelectionRegion? _region;

  /// Creates a new [TerminalSelectionController].
  TerminalSelectionController();

  /// The active selection mode.
  SelectionMode get mode => _mode;

  /// The selection starting anchor point.
  SelectionPoint? get anchor => _anchor;

  /// The current active selection focus point.
  SelectionPoint? get focus => _focus;

  /// The bounding selectable region, if confined to a sub-pane.
  SelectionRegion? get region => _region;

  /// Whether there is currently an active selection with both anchor and focus.
  bool get hasSelection => _anchor != null && _focus != null;

  /// Whether a selection gesture has been initiated.
  bool get isSelecting => _anchor != null;

  /// Begins a new selection starting at `(col, row)`.
  ///
  /// If [region] is provided, selection coordinates are clamped and confined to that region.
  void startSelection(
    int col,
    int row, {
    SelectionMode mode = SelectionMode.character,
    SelectionRegion? region,
  }) {
    _mode = mode;
    _region = region;
    _anchor = _clampPoint(col, row, region);
    _focus = null;
    _wordAnchor = null;
    notifyListeners();
  }

  /// Updates the selection endpoint to `(col, row)`.
  void updateSelection(int col, int row, {SelectionMode? mode}) {
    if (_anchor == null) return;
    final modeChanged = mode != null && _mode != mode;
    if (modeChanged) {
      _mode = mode;
    }
    final newFocus = _clampPoint(col, row, _region);
    if (_focus == newFocus && !modeChanged) return;
    _focus = newFocus;
    notifyListeners();
  }

  /// Extends a word-snapped selection from the initial [_wordAnchor] to the
  /// word at `(col, row)` in [buffer], supporting forward, backward, and
  /// direction-reversed drags across wide graphemes.
  void updateWordSelection(Buffer buffer, int col, int row) {
    if (_anchor == null || buffer.width <= 0 || buffer.height <= 0) return;
    final r = _region;
    final minCol = r != null ? max(0, r.minCol) : 0;
    final maxCol = r != null
        ? min(buffer.width - 1, r.maxCol)
        : buffer.width - 1;
    final minRow = r != null ? max(0, r.minRow) : 0;
    final maxRow = r != null
        ? min(buffer.height - 1, r.maxRow)
        : buffer.height - 1;
    if (minCol > maxCol || minRow > maxRow) return;

    final clampedCol = col.clamp(minCol, maxCol);
    final clampedRow = row.clamp(minRow, maxRow);
    final (targetStart, targetEnd) = _expandWordBounds(
      buffer,
      clampedRow,
      clampedCol,
      minCol,
      maxCol,
    );
    final (anchorStart, anchorEnd) =
        _wordAnchor ?? _orderPoints(_anchor!, _focus ?? _anchor!);

    final (
      SelectionPoint nextAnchor,
      SelectionPoint nextFocus,
    ) = _resolveWordDragEndpoints(
      anchorStart: anchorStart,
      anchorEnd: anchorEnd,
      clampedRow: clampedRow,
      targetStart: targetStart,
      targetEnd: targetEnd,
    );

    if (_mode == SelectionMode.word &&
        _anchor == nextAnchor &&
        _focus == nextFocus) {
      return;
    }
    _mode = SelectionMode.word;
    _anchor = nextAnchor;
    _focus = nextFocus;
    notifyListeners();
  }

  static (SelectionPoint, SelectionPoint) _resolveWordDragEndpoints({
    required SelectionPoint anchorStart,
    required SelectionPoint anchorEnd,
    required int clampedRow,
    required int targetStart,
    required int targetEnd,
  }) {
    if (clampedRow < anchorStart.row ||
        (clampedRow == anchorStart.row && targetEnd < anchorStart.col)) {
      return (anchorEnd, SelectionPoint(targetStart, clampedRow));
    }
    if (clampedRow == anchorStart.row && targetStart <= anchorEnd.col) {
      return (
        SelectionPoint(min(anchorStart.col, targetStart), clampedRow),
        SelectionPoint(max(anchorEnd.col, targetEnd), clampedRow),
      );
    }
    return (anchorStart, SelectionPoint(targetEnd, clampedRow));
  }

  /// Selects the contiguous word at `(col, row)` in [buffer].
  void selectWord(Buffer buffer, int col, int row, {SelectionRegion? region}) {
    if (buffer.width <= 0 || row < 0 || row >= buffer.height) return;
    final minCol = region != null ? max(0, region.minCol) : 0;
    final maxCol = region != null
        ? min(buffer.width - 1, region.maxCol)
        : buffer.width - 1;
    final minRow = region != null ? max(0, region.minRow) : 0;
    final maxRow = region != null
        ? min(buffer.height - 1, region.maxRow)
        : buffer.height - 1;
    if (minCol > maxCol || minRow > maxRow) return;

    final clampedRow = row.clamp(minRow, maxRow);
    final clampedCol = col.clamp(minCol, maxCol);
    final (startCol, endCol) = _expandWordBounds(
      buffer,
      clampedRow,
      clampedCol,
      minCol,
      maxCol,
    );

    _mode = SelectionMode.word;
    _region = region;
    _anchor = SelectionPoint(startCol, clampedRow);
    _focus = SelectionPoint(endCol, clampedRow);
    _wordAnchor = (_anchor!, _focus!);
    notifyListeners();
  }

  static (int, int) _expandWordBounds(
    Buffer buffer,
    int row,
    int col,
    int minCol,
    int maxCol,
  ) {
    final leadCol = col > minCol && buffer.getCharacter(col, row).isEmpty
        ? col - 1
        : col;
    if (!_isWordChar(buffer.getCharacter(leadCol, row))) {
      final endCol =
          leadCol < maxCol && buffer.getCharacter(leadCol + 1, row).isEmpty
          ? leadCol + 1
          : leadCol;
      return (leadCol, endCol);
    }
    var start = leadCol;
    while (true) {
      final step = _wordStepLeft(buffer, row, start, minCol);
      if (step == 0) break;
      start -= step;
    }
    var end = _consumeContinuation(buffer, row, leadCol, maxCol);
    while (end < maxCol && _isWordChar(buffer.getCharacter(end + 1, row))) {
      end = _consumeContinuation(buffer, row, end + 1, maxCol);
    }
    return (start, end);
  }

  static int _wordStepLeft(Buffer buffer, int row, int start, int minCol) {
    if (start <= minCol) return 0;
    final prev = buffer.getCharacter(start - 1, row);
    if (_isWordChar(prev)) return 1;
    if (prev.isEmpty &&
        start - 2 >= minCol &&
        _isWordChar(buffer.getCharacter(start - 2, row))) {
      return 2;
    }
    return 0;
  }

  static int _consumeContinuation(
    Buffer buffer,
    int row,
    int col,
    int maxCol,
  ) =>
      col < maxCol && buffer.getCharacter(col + 1, row).isEmpty ? col + 1 : col;

  static bool _isWordChar(String ch) =>
      ch.isNotEmpty && ch != ' ' && _wordCharPattern.hasMatch(ch);

  static SelectionPoint _clampPoint(int col, int row, SelectionRegion? region) {
    if (region == null) return SelectionPoint(col, row);
    return SelectionPoint(
      col.clamp(region.minCol, region.maxCol),
      row.clamp(region.minRow, region.maxRow),
    );
  }

  /// Clears the current selection.
  void clearSelection() {
    if (_anchor == null && _focus == null && _region == null) return;
    _anchor = null;
    _focus = null;
    _wordAnchor = null;
    _region = null;
    notifyListeners();
  }

  /// Returns whether the viewport cell at `(col, row)` (offset by [topVirtualRow]
  /// and [leftVirtualCol]) is currently selected.
  bool containsCell(
    int col,
    int row, {
    int topVirtualRow = 0,
    int leftVirtualCol = 0,
  }) => isCellSelected(
    col,
    row,
    topVirtualRow: topVirtualRow,
    leftVirtualCol: leftVirtualCol,
  );

  /// Returns whether the viewport cell at `([x], [y])` (offset by [topVirtualRow]
  /// and [leftVirtualCol]) is currently selected.
  bool isCellSelected(
    int x,
    int y, {
    int topVirtualRow = 0,
    int leftVirtualCol = 0,
  }) {
    final a = _anchor;
    final b = _focus;
    if (a == null || b == null || x < 0 || y < 0) return false;

    final vx = x + leftVirtualCol;
    final vy = y + topVirtualRow;
    if (vx < 0) return false;

    final r = _region;
    if (r != null && !r.contains(vx, vy)) return false;

    return switch (_mode) {
      SelectionMode.block => _isCellInBlock(a, b, vx, vy),
      SelectionMode.line => vy >= min(a.row, b.row) && vy <= max(a.row, b.row),
      SelectionMode.character ||
      SelectionMode.word => _isCellInStream(a, b, vx, vy, r),
    };
  }

  /// Intersects the active selection with [buffer]'s `0..width-1` by
  /// `0..height-1` viewport (starting at [topVirtualRow] and [leftVirtualCol])
  /// and snaps wide-grapheme continuation (`""`) boundaries.
  List<(int y, int colStart, int colEnd)> visibleRowSpans(
    Buffer buffer, {
    int topVirtualRow = 0,
    int leftVirtualCol = 0,
  }) {
    final a = _anchor;
    final b = _focus;
    final width = buffer.width;
    final height = buffer.height;
    if (a == null || b == null || width <= 0 || height <= 0) return const [];

    final r = _region;
    final minVRow = r != null
        ? max(min(a.row, b.row), r.minRow)
        : min(a.row, b.row);
    final maxVRow = r != null
        ? min(max(a.row, b.row), r.maxRow)
        : max(a.row, b.row);
    final minScreenY = max(0, minVRow - topVirtualRow);
    final maxScreenY = min(height - 1, maxVRow - topVirtualRow);
    if (minScreenY > maxScreenY) return const [];

    final virtualMaxCol = r?.maxCol ?? (max(0, leftVirtualCol) + width - 1);
    final virtualMinCol = r?.minCol ?? 0;
    final (start, end) = _orderPoints(a, b);

    final spans = <(int y, int colStart, int colEnd)>[];
    for (var screenY = minScreenY; screenY <= maxScreenY; screenY++) {
      final virtualY = topVirtualRow + screenY;
      final (vStart, vEnd) = _virtualRowBounds(
        virtualY,
        a,
        b,
        start,
        end,
        virtualMinCol,
        virtualMaxCol,
      );
      final rawStart = vStart - leftVirtualCol;
      final rawEnd = vEnd - leftVirtualCol;
      if (rawStart >= width || rawEnd < 0 || rawStart > rawEnd) continue;
      final minScreenCol = max(0, virtualMinCol - leftVirtualCol);
      final maxScreenCol = min(width - 1, virtualMaxCol - leftVirtualCol);
      if (minScreenCol > maxScreenCol) continue;
      final (colStart, colEnd) = snapWideBounds(
        buffer.characters,
        screenY * width,
        max(minScreenCol, rawStart),
        min(maxScreenCol, rawEnd),
        minCol: minScreenCol,
        maxCol: maxScreenCol,
      );
      spans.add((screenY, colStart, colEnd));
    }
    return spans;
  }

  (int, int) _virtualRowBounds(
    int virtualY,
    SelectionPoint a,
    SelectionPoint b,
    SelectionPoint start,
    SelectionPoint end,
    int minBound,
    int maxBound,
  ) => switch (_mode) {
    SelectionMode.block => (
      max(minBound, min(a.col, b.col)),
      min(maxBound, max(a.col, b.col)),
    ),
    SelectionMode.line => (minBound, maxBound),
    SelectionMode.character || SelectionMode.word => _streamRowColBounds(
      virtualY,
      start,
      end,
      minBound,
      maxBound,
    ),
  };

  /// Snaps `(colStart, colEnd)` outward across wide-grapheme continuation (`""`)
  /// cells within `[minCol, maxCol]`.
  static (int, int) snapWideBounds(
    List<String> chars,
    int rowOffset,
    int colStart,
    int colEnd, {
    int minCol = 0,
    required int maxCol,
  }) {
    final snappedStart =
        colStart > minCol && chars[rowOffset + colStart].isEmpty
        ? colStart - 1
        : colStart;
    final snappedEnd = colEnd < maxCol && chars[rowOffset + colEnd + 1].isEmpty
        ? colEnd + 1
        : colEnd;
    return (snappedStart, snappedEnd);
  }

  static bool _isCellInBlock(
    SelectionPoint a,
    SelectionPoint b,
    int col,
    int row,
  ) =>
      col >= min(a.col, b.col) &&
      col <= max(a.col, b.col) &&
      row >= min(a.row, b.row) &&
      row <= max(a.row, b.row);

  static bool _isCellInStream(
    SelectionPoint a,
    SelectionPoint b,
    int col,
    int row,
    SelectionRegion? r,
  ) {
    final (start, end) = _orderPoints(a, b);
    if (row < start.row || row > end.row) return false;
    if (start.row == end.row) return col >= start.col && col <= end.col;

    final minBound = r?.minCol ?? 0;
    final maxBound = r?.maxCol;
    if (row == start.row) {
      return col >= start.col && (maxBound == null || col <= maxBound);
    }
    if (row == end.row) {
      return col <= end.col && col >= minBound;
    }
    return col >= minBound && (maxBound == null || col <= maxBound);
  }

  static (SelectionPoint, SelectionPoint) _orderPoints(
    SelectionPoint a,
    SelectionPoint b,
  ) => (a.row < b.row || (a.row == b.row && a.col <= b.col)) ? (a, b) : (b, a);

  /// Extracts the text contained in the current selection from [buffer].
  ///
  /// If [includeHidden] is `true` (the default), characters styled with
  /// [Modifier.hidden] are included in the extracted text.
  String extractSelectedText(
    Buffer buffer, {
    bool includeHidden = true,
    int topVirtualRow = 0,
    int leftVirtualCol = 0,
  }) {
    final a = _anchor;
    final b = _focus;
    if (a == null || b == null || buffer.width <= 0 || buffer.height <= 0) {
      return '';
    }
    if (topVirtualRow != 0 || leftVirtualCol != 0) {
      return _extractOffsetBufferText(
        buffer,
        includeHidden: includeHidden,
        topVirtualRow: topVirtualRow,
        leftVirtualCol: leftVirtualCol,
      );
    }

    return switch (_mode) {
      SelectionMode.block => _extractBlockText(buffer, a, b, includeHidden),
      SelectionMode.line => _extractLineText(
        buffer,
        a,
        b,
        _region,
        includeHidden,
      ),
      SelectionMode.character || SelectionMode.word => _extractStreamText(
        buffer,
        a,
        b,
        _region,
        includeHidden,
      ),
    };
  }

  /// Alias for [extractSelectedText].
  String extractText(
    Buffer buffer, {
    bool includeHidden = true,
    int topVirtualRow = 0,
    int leftVirtualCol = 0,
  }) => extractSelectedText(
    buffer,
    includeHidden: includeHidden,
    topVirtualRow: topVirtualRow,
    leftVirtualCol: leftVirtualCol,
  );

  String _extractOffsetBufferText(
    Buffer buffer, {
    required bool includeHidden,
    required int topVirtualRow,
    required int leftVirtualCol,
  }) {
    final spans = visibleRowSpans(
      buffer,
      topVirtualRow: topVirtualRow,
      leftVirtualCol: leftVirtualCol,
    );
    if (spans.isEmpty) return '';
    final maxBound =
        (_region?.maxCol ?? (leftVirtualCol + buffer.width - 1)) -
        leftVirtualCol;
    final lines = <String>[
      for (final (y, colStart, colEnd) in spans)
        _extractRowSlice(
          buffer,
          y,
          colStart,
          colEnd,
          includeHidden,
          trimTrailing: _mode != SelectionMode.block && colEnd >= maxBound,
        ),
    ];
    return lines.join('\n');
  }

  /// Extracts selected text across [lookup], joining soft-wrapped rows
  /// (`isWrapped == true`) without `\n` unless [mode] is [SelectionMode.block].
  String extractVirtualText(VirtualLineLookup lookup, {required int cols}) {
    final a = _anchor;
    final b = _focus;
    if (a == null || b == null || cols <= 0) return '';

    final r = _region;
    final firstRow = r != null
        ? max(min(a.row, b.row), r.minRow)
        : min(a.row, b.row);
    final lastRow = r != null
        ? min(max(a.row, b.row), r.maxRow)
        : max(a.row, b.row);
    if (firstRow > lastRow) return '';

    final (start, end) = _orderPoints(a, b);
    final out = StringBuffer();
    var isFirstRow = true;

    for (var virtualY = firstRow; virtualY <= lastRow; virtualY++) {
      final line = lookup(virtualY);
      if (line == null) continue;
      final rowWidth = max(cols, line.characters.length);
      final minBound = r?.minCol ?? 0;
      final maxBound = r?.maxCol ?? (rowWidth - 1);
      final (rawStart, rawEnd) = _virtualRowBounds(
        virtualY,
        a,
        b,
        start,
        end,
        minBound,
        maxBound,
      );
      if (rawStart >= rowWidth || rawEnd < 0 || rawStart > rawEnd) continue;
      final rowText = _extractVirtualLineSlice(
        line.characters,
        rawStart,
        rawEnd,
        minBound: minBound,
        maxBound: maxBound,
        stripTrailingSpaces: !_isFollowedBySoftWrap(lookup, virtualY),
      );
      if (!isFirstRow && _shouldInsertVirtualNewline(line)) {
        out.write('\n');
      }
      isFirstRow = false;
      out.write(rowText);
    }
    return '$out';
  }

  bool _shouldInsertVirtualNewline(VirtualLineSlice line) =>
      _mode == SelectionMode.block || _region != null || !line.isWrapped;

  bool _isFollowedBySoftWrap(VirtualLineLookup lookup, int virtualY) =>
      _mode != SelectionMode.block &&
      _region == null &&
      (lookup(virtualY + 1)?.isWrapped ?? false);

  static String _extractVirtualLineSlice(
    List<String> chars,
    int rawStart,
    int rawEnd, {
    required int minBound,
    required int maxBound,
    required bool stripTrailingSpaces,
  }) {
    if (chars.isEmpty) return '';
    final clampMin = max(0, minBound);
    final clampMax = min(chars.length - 1, maxBound);
    if (clampMin > clampMax) return '';
    final clampedStart = max(clampMin, rawStart);
    final clampedEnd = min(clampMax, rawEnd);
    if (clampedStart > clampedEnd) return '';
    final (colStart, colEnd) = snapWideBounds(
      chars,
      0,
      clampedStart,
      clampedEnd,
      minCol: clampMin,
      maxCol: clampMax,
    );
    final rowBuf = StringBuffer();
    for (var x = colStart; x <= colEnd; x++) {
      final cell = chars[x];
      if (cell.isEmpty || cell.startsWith(kittyPlaceholderChar)) continue;
      rowBuf.write(cell);
    }
    final text = '$rowBuf';
    return stripTrailingSpaces ? text.replaceFirst(_trailingSpaces, '') : text;
  }

  static String _extractBlockText(
    Buffer buffer,
    SelectionPoint a,
    SelectionPoint b,
    bool includeHidden,
  ) {
    final minC = min(a.col, b.col);
    final maxC = max(a.col, b.col);
    final minR = max(0, min(a.row, b.row));
    final maxR = min(buffer.height - 1, max(a.row, b.row));
    if (minC >= buffer.width || maxC < 0 || minR > maxR) return '';

    final lines = <String>[
      for (var y = minR; y <= maxR; y++)
        _extractRowSlice(
          buffer,
          y,
          minC,
          maxC,
          includeHidden,
          trimTrailing: false,
        ),
    ];
    return lines.join('\n');
  }

  static String _extractLineText(
    Buffer buffer,
    SelectionPoint a,
    SelectionPoint b,
    SelectionRegion? region,
    bool includeHidden,
  ) {
    final minC = region?.minCol ?? 0;
    final maxC = region?.maxCol ?? (buffer.width - 1);
    final minR = max(0, min(a.row, b.row));
    final maxR = min(buffer.height - 1, max(a.row, b.row));

    final lines = <String>[
      for (var y = minR; y <= maxR; y++)
        _extractRowSlice(
          buffer,
          y,
          minC,
          maxC,
          includeHidden,
          trimTrailing: true,
        ),
    ];
    return lines.join('\n');
  }

  static String _extractStreamText(
    Buffer buffer,
    SelectionPoint a,
    SelectionPoint b,
    SelectionRegion? region,
    bool includeHidden,
  ) {
    final (start, end) = _orderPoints(a, b);
    final minBound = region?.minCol ?? 0;
    final maxBound = region?.maxCol ?? (buffer.width - 1);

    final lines = <String>[];
    for (var y = start.row; y <= end.row; y++) {
      if (y < 0 || y >= buffer.height) continue;
      final (col0, col1) = _streamRowColBounds(
        y,
        start,
        end,
        minBound,
        maxBound,
      );
      if (col0 > maxBound || col1 < minBound || col0 > col1) continue;
      lines.add(
        _extractRowSlice(
          buffer,
          y,
          col0,
          col1,
          includeHidden,
          minCol: minBound,
          maxCol: maxBound,
          trimTrailing: col1 >= maxBound,
        ),
      );
    }
    return lines.join('\n');
  }

  static (int, int) _streamRowColBounds(
    int y,
    SelectionPoint start,
    SelectionPoint end,
    int minBound,
    int maxBound,
  ) {
    if (start.row == end.row) {
      return (max(minBound, start.col), min(maxBound, end.col));
    }
    if (y == start.row) return (max(minBound, start.col), maxBound);
    if (y == end.row) return (minBound, min(maxBound, end.col));
    return (minBound, maxBound);
  }

  static String _extractRowSlice(
    Buffer buffer,
    int y,
    int col0,
    int col1,
    bool includeHidden, {
    int? minCol,
    int? maxCol,
    required bool trimTrailing,
  }) {
    if (col0 > col1) return '';
    final sb = StringBuffer();
    final minX = (minCol ?? 0).clamp(0, buffer.width - 1);
    final maxX = (maxCol ?? (buffer.width - 1)).clamp(0, buffer.width - 1);
    if (minX > maxX || col0 > maxX || col1 < minX) return '';
    final (startX, endX) = snapWideBounds(
      buffer.characters,
      y * buffer.width,
      col0.clamp(minX, maxX),
      col1.clamp(minX, maxX),
      minCol: minX,
      maxCol: maxX,
    );

    for (var x = startX; x <= endX; x++) {
      final char = buffer.getCharacter(x, y);
      if (char.isEmpty) continue;
      final mods = buffer.getModifiers(x, y);
      if (Modifier.has(mods, Modifier.kittyPlaceholder)) continue;
      if (!includeHidden && Modifier.has(mods, Modifier.hidden)) continue;
      sb.write(char);
    }
    final result = '$sb';
    return trimTrailing ? result.replaceFirst(_trailingSpaces, '') : result;
  }

  /// Resolves a hyperlink span at `([col], [virtualRow])` across soft-wrapped
  /// rows in [lookup], preferring contiguous `OSC 8` `uris` spans first and
  /// falling back to plain-text `http://`, `https://`, and `mailto:` tokens.
  static ResolvedTerminalLink? resolveLinkSpanAt({
    required VirtualLineLookup lookup,
    required int col,
    required int virtualRow,
  }) {
    if (col < 0 || virtualRow < 0) return null;
    final clickedLine = lookup(virtualRow);
    if (clickedLine == null || col >= clickedLine.characters.length) {
      return null;
    }

    final snappedCol = col > 0 && clickedLine.characters[col].isEmpty
        ? col - 1
        : col;
    final (wrapStart, wrapEnd) = _softWrapBounds(lookup, virtualRow);
    final osc8Uri = _supportedOsc8UriAt(clickedLine, snappedCol);
    if (osc8Uri != null) {
      return _expandOsc8Span(
        lookup,
        osc8Uri,
        snappedCol,
        virtualRow,
        wrapStart,
        wrapEnd,
      );
    }

    if (clickedLine.characters[snappedCol].isEmpty) return null;
    return _matchPlainLinkSpan(
      lookup,
      snappedCol,
      virtualRow,
      wrapStart,
      wrapEnd,
    );
  }

  static String? _supportedOsc8UriAt(VirtualLineSlice line, int col) {
    final uris = line.uris;
    if (uris == null || col < 0 || col >= uris.length) return null;
    final raw = uris[col];
    if (raw == null || raw.isEmpty) return null;
    final sanitized = sanitizeOsc8Uri(raw);
    return _isSupportedOsc8Target(sanitized) ? sanitized : null;
  }

  static bool _isSupportedOsc8Target(String raw) {
    if (raw.isEmpty) return false;
    final uri = Uri.tryParse(raw);
    if (uri == null) return false;
    return switch (uri.scheme.toLowerCase()) {
      'http' || 'https' => uri.hasAuthority && uri.host.isNotEmpty,
      'mailto' => !uri.hasAuthority && uri.path.isNotEmpty,
      'file' => uri.path.isNotEmpty,
      _ => false,
    };
  }

  static ResolvedTerminalLink _expandOsc8Span(
    VirtualLineLookup lookup,
    String targetUri,
    int col,
    int row,
    int wrapStart,
    int wrapEnd,
  ) {
    final (startCol, startRow) = _walkOsc8Start(
      lookup,
      targetUri,
      col,
      row,
      wrapStart,
      wrapEnd,
    );
    final (endCol, endRow) = _walkOsc8End(lookup, targetUri, col, row, wrapEnd);
    return (
      uri: targetUri,
      startCol: startCol,
      startRow: startRow,
      endCol: endCol,
      endRow: endRow,
    );
  }

  static (int col, int row) _walkOsc8Start(
    VirtualLineLookup lookup,
    String targetUri,
    int col,
    int row,
    int wrapStart,
    int wrapEnd,
  ) {
    var curRow = row;
    var curCol = col;
    while (true) {
      final curLine = lookup(curRow);
      if (curLine == null) break;
      while (curCol > 0 &&
          _supportedOsc8UriAt(curLine, curCol - 1) == targetUri) {
        curCol--;
      }
      if (curCol > 0 || curRow <= wrapStart) break;
      final prevLine = lookup(curRow - 1);
      if (prevLine == null) break;
      final prevLen = _rowContentLength(
        lookup,
        prevLine.characters,
        curRow - 1,
        wrapEnd,
      );
      if (prevLen <= 0 ||
          _supportedOsc8UriAt(prevLine, prevLen - 1) != targetUri) {
        break;
      }
      curRow--;
      curCol = prevLen - 1;
    }
    return (curCol, curRow);
  }

  static (int col, int row) _walkOsc8End(
    VirtualLineLookup lookup,
    String targetUri,
    int col,
    int row,
    int wrapEnd,
  ) {
    var curRow = row;
    var curCol = col;
    while (true) {
      final curLine = lookup(curRow);
      if (curLine == null) break;
      final chars = curLine.characters;
      while (curCol + 1 < chars.length &&
          _supportedOsc8UriAt(curLine, curCol + 1) == targetUri) {
        curCol++;
      }
      if (curCol + 1 < chars.length && chars[curCol + 1].isEmpty) {
        curCol++;
      }
      final curLen = _rowContentLength(lookup, chars, curRow, wrapEnd);
      if (curRow >= wrapEnd || curCol < curLen - 1) break;
      final nextLine = lookup(curRow + 1);
      if (nextLine == null ||
          nextLine.characters.isEmpty ||
          _supportedOsc8UriAt(nextLine, 0) != targetUri) {
        break;
      }
      curRow++;
      curCol = 0;
    }
    return (curCol, curRow);
  }

  static ResolvedTerminalLink? _matchPlainLinkSpan(
    VirtualLineLookup lookup,
    int snappedCol,
    int virtualRow,
    int wrapStart,
    int wrapEnd,
  ) {
    final (logicalText, clickedOffset, cellByOffset) = _buildLogicalLine(
      lookup,
      wrapStart,
      wrapEnd,
      targetRow: virtualRow,
      targetCol: snappedCol,
    );
    if (clickedOffset < 0) return null;
    final match = _matchPlainUrlAtOffset(
      logicalText,
      clickedOffset,
      cellByOffset,
    );
    if (match == null) return null;
    final endChars = lookup(match.endRow)?.characters;
    if (endChars == null ||
        match.endCol + 1 >= endChars.length ||
        endChars[match.endCol + 1].isNotEmpty) {
      return match;
    }
    return (
      uri: match.uri,
      startCol: match.startCol,
      startRow: match.startRow,
      endCol: match.endCol + 1,
      endRow: match.endRow,
    );
  }

  static (int startRow, int endRow) _softWrapBounds(
    VirtualLineLookup lookup,
    int virtualY,
  ) {
    var startRow = virtualY;
    while (virtualY - startRow < _maxLinkWrapRows &&
        startRow > 0 &&
        (lookup(startRow)?.isWrapped ?? false)) {
      startRow--;
    }
    var endRow = virtualY;
    while (endRow - virtualY < _maxLinkWrapRows &&
        (lookup(endRow + 1)?.isWrapped ?? false)) {
      endRow++;
    }
    return (startRow, endRow);
  }

  static (String text, int clickedOffset, List<SelectionPoint> cellByOffset)
  _buildLogicalLine(
    VirtualLineLookup lookup,
    int startRow,
    int endRow, {
    required int targetRow,
    required int targetCol,
  }) {
    final sb = StringBuffer();
    final cellByOffset = <SelectionPoint>[];
    var clickedOffset = -1;
    for (var row = startRow; row <= endRow; row++) {
      final chars = lookup(row)?.characters ?? const <String>[];
      final limit = _rowContentLength(lookup, chars, row, endRow);
      final rowOffset = _appendLogicalRow(
        sb,
        cellByOffset,
        chars,
        row,
        limit,
        row == targetRow ? targetCol : null,
      );
      if (rowOffset != null) clickedOffset = rowOffset;
    }
    return ('$sb', clickedOffset, cellByOffset);
  }

  static int _rowContentLength(
    VirtualLineLookup lookup,
    List<String> chars,
    int row,
    int endRow,
  ) {
    if (row >= endRow || chars.isEmpty || chars.last != ' ') {
      return chars.length;
    }
    final next = lookup(row + 1)?.characters;
    final nextStartsWide =
        next != null &&
        next.length > 1 &&
        next[0].isNotEmpty &&
        next[1].isEmpty;
    return nextStartsWide ? chars.length - 1 : chars.length;
  }

  static int? _appendLogicalRow(
    StringBuffer sb,
    List<SelectionPoint> cellByOffset,
    List<String> chars,
    int row,
    int limit,
    int? targetCol,
  ) {
    int? clickedOffset;
    for (var col = 0; col < limit; col++) {
      final cell = chars[col];
      if (col == targetCol && !cell.startsWith(kittyPlaceholderChar)) {
        clickedOffset = sb.length;
      }
      if (cell.isEmpty) continue;
      final normalized = cell.startsWith(kittyPlaceholderChar) ? ' ' : cell;
      sb.write(normalized);
      final pt = SelectionPoint(col, row);
      for (var i = 0; i < normalized.length; i++) {
        cellByOffset.add(pt);
      }
    }
    return clickedOffset;
  }

  static ResolvedTerminalLink? _matchPlainUrlAtOffset(
    String text,
    int clickedOffset,
    List<SelectionPoint> cellByOffset,
  ) {
    for (final match in _plainLinkCandidatePattern.allMatches(text)) {
      if (clickedOffset < match.start || clickedOffset >= match.end) continue;
      final trimmed = _trimTrailingUrlPunctuation(match.group(0)!);
      final endOffset = match.start + trimmed.length;
      if (clickedOffset >= endOffset) return null;
      final uri = _parsePlainExternalUri(trimmed);
      if (uri == null) return null;
      final startPt = cellByOffset[match.start];
      final endPt = cellByOffset[endOffset - 1];
      return (
        uri: '$uri',
        startCol: startPt.col,
        startRow: startPt.row,
        endCol: endPt.col,
        endRow: endPt.row,
      );
    }
    return null;
  }

  static Uri? _parsePlainExternalUri(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    return switch (uri.scheme.toLowerCase()) {
      'http' || 'https' when uri.hasAuthority && uri.host.isNotEmpty => uri,
      'mailto' when !uri.hasAuthority && uri.path.isNotEmpty => uri,
      _ => null,
    };
  }

  static String _trimTrailingUrlPunctuation(String raw) {
    var end = raw.length;
    while (end > 0 && _shouldStripTrailingChar(raw, end)) {
      end--;
    }
    return end == raw.length ? raw : raw.substring(0, end);
  }

  static bool _shouldStripTrailingChar(String raw, int end) =>
      switch (raw[end - 1]) {
        '.' || ',' || ';' || ':' || '!' || '?' => true,
        ')' => _countChar(raw, end, ')') > _countChar(raw, end, '('),
        ']' => _countChar(raw, end, ']') > _countChar(raw, end, '['),
        '}' => _countChar(raw, end, '}') > _countChar(raw, end, '{'),
        _ => false,
      };

  static int _countChar(String text, int limit, String target) {
    final code = target.codeUnitAt(0);
    var count = 0;
    for (var i = 0; i < limit; i++) {
      if (text.codeUnitAt(i) == code) count++;
    }
    return count;
  }

  /// Resolves the confining [SelectionRegion] for a pointer gesture starting at
  /// `([col], [row])` in [buffer], or returns `null` when selection should span
  /// the full buffer unconstrained.
  ///
  /// - In [SelectionMode.block] (`box`), always returns `null` so `Alt+Drag`
  ///   rectangular selection is never clamped to pane dividers.
  /// - Checks [Buffer.selectableRegions] for the smallest sub-region containing
  ///   `([col], [row])`, narrowing further if vertical dividers exist inside it.
  /// - Falls back to scanning vertical box-drawing dividers (`│`, `┃`, `║`),
  ///   and only scans horizontal dividers (`─`, `━`, `═`) when vertical dividers
  ///   were also found so plain shell horizontal rules are never clamped.
  static SelectionRegion? resolveRegionForCell(
    Buffer buffer,
    int col,
    int row, {
    SelectionMode mode = SelectionMode.character,
  }) {
    if (mode == SelectionMode.block ||
        !_isWithinBufferBounds(buffer, col, row)) {
      return null;
    }

    final subregion = _findSmallestSubregion(buffer, col, row);
    if (subregion != null) {
      return _narrowRegionByDividers(
        buffer,
        col,
        row,
        SelectionRegion.fromRect(subregion),
        requireVerticalForReturn: false,
      );
    }

    final fullBounds = SelectionRegion(
      minCol: 0,
      maxCol: buffer.width - 1,
      minRow: 0,
      maxRow: buffer.height - 1,
    );
    return _narrowRegionByDividers(
      buffer,
      col,
      row,
      fullBounds,
      requireVerticalForReturn: true,
    );
  }

  static bool _isWithinBufferBounds(Buffer buffer, int col, int row) =>
      buffer.width > 0 &&
      buffer.height > 0 &&
      col >= 0 &&
      col < buffer.width &&
      row >= 0 &&
      row < buffer.height;

  static Rect? _findSmallestSubregion(Buffer buffer, int col, int row) {
    Rect? best;
    var bestArea = 0;
    var bestZ = 0;
    final regions = buffer.selectableRegions;
    for (var i = 0; i < regions.length; i++) {
      final r = regions[i];
      final isSubregion = r.width < buffer.width || r.height < buffer.height;
      if (!isSubregion || !r.contains(col, row)) continue;
      final z = buffer.selectableRegionZIndexAt(i);
      final area = r.width * r.height;
      if (best == null || z > bestZ || (z == bestZ && area < bestArea)) {
        best = r;
        bestZ = z;
        bestArea = area;
      }
    }
    return best;
  }

  static SelectionRegion? _narrowRegionByDividers(
    Buffer buffer,
    int col,
    int row,
    SelectionRegion bounds, {
    required bool requireVerticalForReturn,
  }) {
    final (minCol, maxCol, foundVertical) = _scanVerticalDividerBounds(
      buffer,
      col,
      row,
      bounds,
    );
    if (!foundVertical) {
      return requireVerticalForReturn ? null : bounds;
    }
    final (minRow, maxRow) = _scanHorizontalDividerBounds(
      buffer,
      col,
      row,
      minCol,
      maxCol,
      bounds.minRow,
      bounds.maxRow,
    );
    return SelectionRegion(
      minCol: minCol,
      maxCol: maxCol,
      minRow: minRow,
      maxRow: maxRow,
    );
  }

  static (int, int, bool) _scanVerticalDividerBounds(
    Buffer buffer,
    int col,
    int row,
    SelectionRegion bounds,
  ) {
    int? leftDiv;
    for (var x = col - 1; x >= bounds.minCol; x--) {
      if (_isVerticalPaneDivider(
        buffer,
        x,
        row,
        bounds.minRow,
        bounds.maxRow,
      )) {
        leftDiv = x;
        break;
      }
    }
    int? rightDiv;
    for (var x = col + 1; x <= bounds.maxCol; x++) {
      if (_isVerticalPaneDivider(
        buffer,
        x,
        row,
        bounds.minRow,
        bounds.maxRow,
      )) {
        rightDiv = x;
        break;
      }
    }
    if (leftDiv == null && rightDiv == null) {
      return (bounds.minCol, bounds.maxCol, false);
    }
    final minC = leftDiv != null ? leftDiv + 1 : bounds.minCol;
    final maxC = rightDiv != null ? rightDiv - 1 : bounds.maxCol;
    return minC <= maxC
        ? (minC, maxC, true)
        : (bounds.minCol, bounds.maxCol, false);
  }

  static (int, int) _scanHorizontalDividerBounds(
    Buffer buffer,
    int col,
    int row,
    int minCol,
    int maxCol,
    int baseMinRow,
    int baseMaxRow,
  ) {
    var minRow = baseMinRow;
    for (var y = row - 1; y >= baseMinRow; y--) {
      if (_isHorizontalPaneDivider(buffer, col, y, minCol, maxCol)) {
        minRow = y + 1;
        break;
      }
    }
    var maxRow = baseMaxRow;
    for (var y = row + 1; y <= baseMaxRow; y++) {
      if (_isHorizontalPaneDivider(buffer, col, y, minCol, maxCol)) {
        maxRow = y - 1;
        break;
      }
    }
    return minRow <= maxRow ? (minRow, maxRow) : (baseMinRow, baseMaxRow);
  }

  static bool _isVerticalPaneDivider(
    Buffer buf,
    int x,
    int row,
    int minRow,
    int maxRow,
  ) {
    if (!_isVerticalBoxChar(buf.getCharacter(x, row))) return false;
    final minSpan = max(2, (maxRow - minRow + 1) ~/ 2);
    var span = 1;
    for (
      var y = row - 1;
      y >= minRow && _isVerticalBoxChar(buf.getCharacter(x, y));
      y--
    ) {
      span++;
    }
    for (
      var y = row + 1;
      y <= maxRow && _isVerticalBoxChar(buf.getCharacter(x, y));
      y++
    ) {
      span++;
    }
    return span >= minSpan;
  }

  static bool _isHorizontalPaneDivider(
    Buffer buf,
    int col,
    int y,
    int minCol,
    int maxCol,
  ) {
    if (!_isHorizontalBoxChar(buf.getCharacter(col, y))) return false;
    final minSpan = max(2, (maxCol - minCol + 1) ~/ 2);
    var span = 1;
    for (
      var x = col - 1;
      x >= minCol && _isHorizontalBoxChar(buf.getCharacter(x, y));
      x--
    ) {
      span++;
    }
    for (
      var x = col + 1;
      x <= maxCol && _isHorizontalBoxChar(buf.getCharacter(x, y));
      x++
    ) {
      span++;
    }
    return span >= minSpan;
  }

  static bool _isVerticalBoxChar(String ch) =>
      ch == '│' || ch == '┃' || ch == '║';

  static bool _isHorizontalBoxChar(String ch) =>
      ch == '─' || ch == '━' || ch == '═';

  @override
  void addListener(void Function() listener) {
    if (_disposed) return;
    _listeners.add(listener);
  }

  @override
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  /// Notifies all registered listeners of a change in selection state.
  void notifyListeners() {
    if (_disposed) return;
    for (final listener in List<void Function()>.from(_listeners)) {
      listener();
    }
  }

  /// Disposes the controller, removing all listeners.
  void dispose() {
    _disposed = true;
    _listeners.clear();
  }
}
