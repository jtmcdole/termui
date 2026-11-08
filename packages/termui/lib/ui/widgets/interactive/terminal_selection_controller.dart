import 'dart:math';

import '../../buffer.dart';
import '../../style.dart';
import '../core/geometry.dart';

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
/// and clipboard text extraction.
class TerminalSelectionController implements TerminalListenable {
  static final RegExp _trailingSpaces = RegExp(r' +$');
  static final RegExp _wordCharPattern = RegExp(
    r'[\p{L}\p{N}_]',
    unicode: true,
  );

  final List<void Function()> _listeners = [];
  bool _disposed = false;

  SelectionMode _mode = SelectionMode.character;
  SelectionPoint? _anchor;
  SelectionPoint? _focus;
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
    notifyListeners();
  }

  /// Updates the selection endpoint to `(col, row)`.
  void updateSelection(int col, int row, {SelectionMode? mode}) {
    if (_anchor == null) return;
    if (mode != null) {
      _mode = mode;
    }
    final newFocus = _clampPoint(col, row, _region);
    if (_focus == newFocus) return;
    _focus = newFocus;
    notifyListeners();
  }

  /// Selects the contiguous word at `(col, row)` in [buffer].
  void selectWord(Buffer buffer, int col, int row, {SelectionRegion? region}) {
    if (buffer.width <= 0 || row < 0 || row >= buffer.height) return;
    final minCol = region != null ? max(0, region.minCol) : 0;
    final maxCol = region != null
        ? min(buffer.width - 1, region.maxCol)
        : buffer.width - 1;
    if (minCol > maxCol) return;

    final clampedRow = region != null
        ? row.clamp(region.minRow, region.maxRow)
        : row;
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
    notifyListeners();
  }

  static (int, int) _expandWordBounds(
    Buffer buffer,
    int row,
    int col,
    int minCol,
    int maxCol,
  ) {
    if (!_isWordChar(buffer.getCharacter(col, row))) {
      return (col, col);
    }
    var start = col;
    while (start > minCol && _isWordChar(buffer.getCharacter(start - 1, row))) {
      start--;
    }
    var end = col;
    while (end < maxCol && _isWordChar(buffer.getCharacter(end + 1, row))) {
      end++;
    }
    return (start, end);
  }

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
    _region = null;
    notifyListeners();
  }

  /// Returns whether the cell at `(col, row)` is currently selected.
  bool containsCell(int col, int row) => isCellSelected(col, row);

  /// Returns whether the cell at `([x], [y])` is currently selected.
  bool isCellSelected(int x, int y) {
    final a = _anchor;
    final b = _focus;
    if (a == null || b == null) return false;

    final r = _region;
    if (r != null && !r.contains(x, y)) return false;

    return switch (_mode) {
      SelectionMode.block => _isCellInBlock(a, b, x, y),
      SelectionMode.line => y >= min(a.row, b.row) && y <= max(a.row, b.row),
      SelectionMode.character ||
      SelectionMode.word => _isCellInStream(a, b, x, y, r),
    };
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

    final minBound = r?.minCol;
    final maxBound = r?.maxCol;
    if (row == start.row) {
      return col >= start.col && (maxBound == null || col <= maxBound);
    }
    if (row == end.row) {
      return col <= end.col && (minBound == null || col >= minBound);
    }
    return (minBound == null || col >= minBound) &&
        (maxBound == null || col <= maxBound);
  }

  static (SelectionPoint, SelectionPoint) _orderPoints(
    SelectionPoint a,
    SelectionPoint b,
  ) => (a.row < b.row || (a.row == b.row && a.col <= b.col)) ? (a, b) : (b, a);

  /// Extracts the text contained in the current selection from [buffer].
  ///
  /// If [includeHidden] is `true` (the default), characters styled with
  /// [Modifier.hidden] are included in the extracted text.
  String extractSelectedText(Buffer buffer, {bool includeHidden = true}) {
    final a = _anchor;
    final b = _focus;
    if (a == null || b == null || buffer.width <= 0 || buffer.height <= 0) {
      return '';
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
  String extractText(Buffer buffer, {bool includeHidden = true}) =>
      extractSelectedText(buffer, includeHidden: includeHidden);

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
      lines.add(
        _extractRowSlice(
          buffer,
          y,
          col0,
          col1,
          includeHidden,
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
    required bool trimTrailing,
  }) {
    if (col0 > col1) return '';
    final sb = StringBuffer();
    final startX = col0.clamp(0, buffer.width - 1);
    final endX = col1.clamp(0, buffer.width - 1);

    for (var x = startX; x <= endX; x++) {
      final char = buffer.getCharacter(x, y);
      if (char.isEmpty) continue;
      final mods = buffer.getModifiers(x, y);
      if (Modifier.has(mods, Modifier.kittyPlaceholder)) continue;
      if (!includeHidden && Modifier.has(mods, Modifier.hidden)) continue;
      sb.write(char);
    }
    final result = sb.toString();
    return trimTrailing ? result.replaceFirst(_trailingSpaces, '') : result;
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
