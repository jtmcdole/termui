import 'package:characters/characters.dart';
import "package:termui/termui_trace.dart";
import "package:termui/termui.dart";
// ignore_for_file: public_member_api_docs
import 'dart:math';
import 'package:termui/utils/bool_array.dart';

void _safeSetCell(Buffer buffer, int x, int y, String char, Style style) {
  buffer.setAttributes(
    x,
    y,
    char: char,
    fg: style.foreground?.argb ?? 0,
    bg: style.background?.argb ?? 0,
    modifiers: style.modifiers,
  );
}

String _getFractionalBlock(double fraction) {
  if (fraction <= 0) return ' ';
  if (fraction <= 1 / 8) return '▏';
  if (fraction <= 2 / 8) return '▎';
  if (fraction <= 3 / 8) return '▍';
  if (fraction <= 4 / 8) return '▌';
  if (fraction <= 5 / 8) return '▋';
  if (fraction <= 6 / 8) return '▊';
  if (fraction <= 7 / 8) return '▉';
  return '█';
}

/// An imperative canvas widget drawing the Main Isolate flame chart spans.
class HitGrid {
  final int width;
  final int height;
  final List<TraceSpan?> grid;

  HitGrid(this.width, this.height)
    : grid = List<TraceSpan?>.filled(width * height, null);

  void setHit(int x, int y, TraceSpan span) {
    if (x >= 0 && x < width && y >= 0 && y < height) {
      grid[y * width + x] = span;
    }
  }

  TraceSpan? getHit(int x, int y) {
    if (x >= 0 && x < width && y >= 0 && y < height) {
      return grid[y * width + x];
    }
    return null;
  }
}

class TimelineCanvas extends Widget {
  static bool debugUseBoolArray = true;

  final List<TraceSpan> spans;
  final double offsetX;
  final int offsetY;
  final double zoomLevel;
  final int maxSpanDuration;
  final double? measureStartMs;
  final double? measureEndMs;
  final int? selectionStartUs;
  final int? selectionEndUs;
  final TraceSpan? animatedSpan;
  final double? animationProgress;
  final void Function(HitGrid)? onHitGridUpdated;

  const TimelineCanvas({
    super.key,
    required this.spans,
    required this.offsetX,
    required this.offsetY,
    required this.zoomLevel,
    required this.maxSpanDuration,
    this.onHitGridUpdated,
    this.measureStartMs,
    this.measureEndMs,
    this.selectionStartUs,
    this.selectionEndUs,
    this.animatedSpan,
    this.animationProgress,
  });

  @override
  Element createElement() => TimelineCanvasElement(this);

  @override
  int getIntrinsicHeight(int width) => 10;
}

class TimelineCanvasElement extends Element {
  late IntervalTree<int> _spanTree;

  TimelineCanvasElement(super.widget) {
    _rebuildTree();
  }

  @override
  void mount(Element? parent) {
    super.mount(parent);
    _rebuildTree();
  }

  @override
  void update(Widget newWidget) {
    final oldWidget = widget as TimelineCanvas;
    super.update(newWidget);
    final currentWidget = widget as TimelineCanvas;
    if (!identical(oldWidget.spans, currentWidget.spans)) {
      _rebuildTree();
    }
  }

  void _rebuildTree() {
    final w = widget as TimelineCanvas;
    _spanTree = IntervalTree<int>();
    _spanTree.insertAll(w.spans);
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    final h = constraints.maxHeight == BoxConstraints.infinity
        ? 10
        : constraints.maxHeight;
    final w = constraints.maxWidth == BoxConstraints.infinity
        ? 80
        : constraints.maxWidth;
    return constraints.constrain(Size(w, h));
  }

  /// Paints the flame chart timeline.
  /// Maps temporal spans into spatial columns using [w.offsetX] and [w.zoomLevel].
  @override
  void performPaint(Buffer buffer, Offset offset) {
    final w = widget as TimelineCanvas;
    final width = size.width;
    final height = size.height;
    final startX = offset.dx;
    final startY = offset.dy;

    const borderStyle = Style(foreground: Color(120, 120, 120));
    final hitGrid = HitGrid(width, height);

    if (width >= 1) {
      for (var y = 0; y < height; y++) {
        _drawClippedCell(buffer, offset, startX, startY + y, '│', borderStyle);
        if (width >= 2) {
          _drawClippedCell(
            buffer,
            offset,
            startX + width - 1,
            startY + y,
            '│',
            borderStyle,
          );
        }
      }
    }

    if (width <= 2 || height <= 0) {
      w.onHitGridUpdated?.call(hitGrid);
      return;
    }

    _paintSelectionHighlight(buffer, offset, w);

    final viewportStartUs = w.offsetX;
    final viewportEndUs = w.offsetX + (width - 2) * w.zoomLevel;
    final tracker = _CellDrawTracker(
      width: width,
      height: height,
      useBoolArray: TimelineCanvas.debugUseBoolArray,
    );

    _spanTree.query(
      viewportStartUs.floor(),
      viewportEndUs.ceil(),
      (interval) => _processSpan(
        buffer,
        offset,
        w,
        interval as TraceSpan,
        tracker,
        hitGrid,
      ),
    );

    _paintCaliperOverlay(buffer, offset, w);
    w.onHitGridUpdated?.call(hitGrid);
  }

  void _drawClippedCell(
    Buffer buffer,
    Offset offset,
    int cx,
    int cy,
    String char,
    Style style,
  ) {
    final startX = offset.dx;
    final startY = offset.dy;
    if (cx >= startX &&
        cx < startX + size.width &&
        cy >= startY &&
        cy < startY + size.height) {
      _safeSetCell(buffer, cx, cy, char, style);
    }
  }

  void _paintSelectionHighlight(
    Buffer buffer,
    Offset offset,
    TimelineCanvas w,
  ) {
    final selStart = w.selectionStartUs;
    final selEnd = w.selectionEndUs;
    if (selStart == null || selEnd == null) return;

    final width = size.width;
    final height = size.height;
    final startCol = ((selStart - w.offsetX) / w.zoomLevel).floor().clamp(
      0,
      width - 3,
    );
    final endCol = ((selEnd - w.offsetX) / w.zoomLevel).floor().clamp(
      0,
      width - 3,
    );

    if (endCol < 0 || startCol >= width - 2) return;
    const highlightStyle = Style(background: Color(40, 40, 80));
    for (var col = startCol; col <= endCol; col++) {
      final x = offset.dx + 1 + col;
      for (var cy = offset.dy; cy < offset.dy + height; cy++) {
        _safeSetCell(buffer, x, cy, ' ', highlightStyle);
      }
    }
  }

  void _processSpan(
    Buffer buffer,
    Offset offset,
    TimelineCanvas w,
    TraceSpan span,
    _CellDrawTracker tracker,
    HitGrid hitGrid,
  ) {
    final visualY = span.depth - w.offsetY;
    if (visualY < 0 || visualY >= size.height) return;

    final width = size.width;
    final y = offset.dy + visualY;
    final spanStartUs = span.startUs.toDouble();
    final spanEndUs = span.endUs.toDouble();
    final startColF = (spanStartUs - w.offsetX) / w.zoomLevel;
    final endColF = (spanEndUs - w.offsetX) / w.zoomLevel;
    final startCol = startColF.floor().clamp(0, width - 3);
    final endCol = endColF.floor().clamp(0, width - 3);

    if (tracker.isSpanOccluded(
      offset.dx,
      y,
      visualY,
      startCol,
      spanStartUs == spanEndUs ? startCol : endCol,
    )) {
      return;
    }

    final style = _resolveSpanStyle(w, span);
    if (spanStartUs == spanEndUs) {
      _paintPointSpan(
        buffer,
        offset,
        span,
        style,
        tracker,
        hitGrid,
        startCol,
        visualY,
        y,
      );
      return;
    }

    _paintRangeSpan(
      buffer: buffer,
      offset: offset,
      w: w,
      span: span,
      style: style,
      tracker: tracker,
      hitGrid: hitGrid,
      visualY: visualY,
      y: y,
      startCol: startCol,
      endCol: endCol,
      isClippedLeft: startColF < 0,
      isClippedRight: endColF > (width - 3),
    );
  }

  Style _resolveSpanStyle(TimelineCanvas w, TraceSpan span) {
    final baseStyle = getCategoryStyle(span.category, span.name);
    final progress = w.animationProgress;
    if (w.animatedSpan == span && progress != null && progress > 0) {
      if (sin(progress * pi * 6).abs() > 0.5) {
        return const Style(foreground: Colors.black, background: Colors.yellow);
      }
    }
    return baseStyle;
  }

  void _paintPointSpan(
    Buffer buffer,
    Offset offset,
    TraceSpan span,
    Style style,
    _CellDrawTracker tracker,
    HitGrid hitGrid,
    int startCol,
    int visualY,
    int y,
  ) {
    final x = offset.dx + 1 + startCol;
    if (tracker.isDrawn(x, y, startCol, visualY)) return;
    final bgArgb = buffer.getBackground(x, y);
    final bg = bgArgb == 0 ? null : Color.argb(bgArgb);
    _drawClippedCell(
      buffer,
      offset,
      x,
      y,
      '│',
      style.merge(Style(background: bg)),
    );
    tracker.markDrawn(x, y, startCol, visualY);
    hitGrid.setHit(startCol, visualY, span);
  }

  void _paintRangeSpan({
    required Buffer buffer,
    required Offset offset,
    required TimelineCanvas w,
    required TraceSpan span,
    required Style style,
    required _CellDrawTracker tracker,
    required HitGrid hitGrid,
    required int visualY,
    required int y,
    required int startCol,
    required int endCol,
    required bool isClippedLeft,
    required bool isClippedRight,
  }) {
    final bgColStyle = Style(
      background: style.foreground,
      foreground: Colors.white,
    );
    final spanStartUs = span.startUs.toDouble();
    final spanEndUs = span.endUs.toDouble();
    final labelCells = _buildLabelCells('▼ ${span.displayLabel}');
    final spanColWidth = endCol - startCol + 1;

    for (var col = startCol; col <= endCol; col++) {
      final x = offset.dx + 1 + col;
      if (tracker.isDrawn(x, y, col, visualY)) continue;

      final cellStart = w.offsetX + col * w.zoomLevel;
      final cov = _coverage(
        spanStartUs,
        spanEndUs,
        cellStart,
        cellStart + w.zoomLevel,
      );
      if (cov <= 0) continue;

      hitGrid.setHit(col, visualY, span);
      if (cov > 0.99) {
        final char = _resolveFullCoverageChar(
          labelCells: labelCells,
          spanColWidth: spanColWidth,
          col: col,
          startCol: startCol,
          endCol: endCol,
          isClippedLeft: isClippedLeft,
          isClippedRight: isClippedRight,
        );
        tracker.markDrawn(x, y, col, visualY);
        if (char != null) {
          _drawClippedCell(buffer, offset, x, y, char, bgColStyle);
        }
      } else {
        final (char, cellStyle) = _resolvePartialCoverageCell(
          cov: cov,
          col: col,
          startCol: startCol,
          endCol: endCol,
          style: style,
        );
        if (char == '│' || char == '█') {
          tracker.markDrawn(x, y, col, visualY);
        }
        _drawClippedCell(buffer, offset, x, y, char, cellStyle);
      }
    }
  }

  static List<String?> _buildLabelCells(String text) {
    final cells = <String?>[];
    for (final grapheme in text.characters) {
      final w = graphemeWidth(grapheme);
      if (w <= 0) continue;
      cells.add(grapheme);
      for (var c = 1; c < w; c++) {
        cells.add(null);
      }
    }
    return cells;
  }

  static String? _resolveFullCoverageChar({
    required List<String?> labelCells,
    required int spanColWidth,
    required int col,
    required int startCol,
    required int endCol,
    required bool isClippedLeft,
    required bool isClippedRight,
  }) {
    if (isClippedLeft && col == startCol) return '◀';
    if (isClippedRight && col == endCol) return '▶';
    final relativeCol = col - startCol;
    if (spanColWidth < labelCells.length ||
        relativeCol < 0 ||
        relativeCol >= labelCells.length) {
      return ' ';
    }
    final entry = labelCells[relativeCol];
    if (entry == null) return null;
    if (isClippedRight &&
        col == endCol - 1 &&
        relativeCol + 1 < labelCells.length &&
        labelCells[relativeCol + 1] == null) {
      return ' ';
    }
    return entry;
  }

  static (String, Style) _resolvePartialCoverageCell({
    required double cov,
    required int col,
    required int startCol,
    required int endCol,
    required Style style,
  }) {
    if (startCol == endCol) {
      return (cov <= 0.1 ? '│' : _getFractionalBlock(cov), style);
    }
    if (col == startCol) {
      return (
        _getFractionalBlock(1.0 - cov),
        style.merge(
          Style(
            foreground: null,
            background: style.foreground ?? const Color(255, 255, 255),
          ),
        ),
      );
    }
    return (_getFractionalBlock(cov), style);
  }

  void _paintCaliperOverlay(Buffer buffer, Offset offset, TimelineCanvas w) {
    final mStart = w.measureStartMs;
    final mEnd = w.measureEndMs;
    if (mStart == null || mEnd == null) return;

    final width = size.width;
    final height = size.height;
    final startX = offset.dx;
    final startY = offset.dy;
    final startUs = mStart * 1000.0;
    final endUs = mEnd * 1000.0;
    final col1 = ((startUs - w.offsetX) / w.zoomLevel).round();
    final col2 = ((endUs - w.offsetX) / w.zoomLevel).round();
    final leftCol = min(col1, col2).clamp(0, width - 3) + 1;
    final rightCol = max(col1, col2).clamp(0, width - 3) + 1;
    final spanWidth = rightCol - leftCol + 1;
    final durationMs = (endUs - startUs).abs() / 1000.0;
    final text = ' ${durationMs.toStringAsFixed(1)}ms ';
    final textLen = text.characters.length;
    final String caliperStr;
    if (spanWidth >= textLen + 4) {
      final dashes = spanWidth - 2 - textLen;
      final leftDashes = dashes ~/ 2;
      final rightDashes = dashes - leftDashes;
      caliperStr = '├${'─' * leftDashes}$text${'─' * rightDashes}┤';
    } else if (spanWidth >= 2) {
      caliperStr = '├${'─' * (spanWidth - 2)}┤';
    } else {
      caliperStr = '│';
    }

    const caliperStyle = Style(
      foreground: Color(0, 255, 255),
      modifiers: Modifier.bold,
    );
    final caliperRow = startY - 1;
    var colOffset = 0;
    for (final grapheme in caliperStr.characters) {
      final cx = startX + leftCol + colOffset;
      if (cx >= startX && cx < startX + width && caliperRow >= 0) {
        final bgArgb = buffer.getBackground(cx, caliperRow);
        final bg = bgArgb == 0 ? null : Color.argb(bgArgb);
        _safeSetCell(
          buffer,
          cx,
          caliperRow,
          grapheme,
          caliperStyle.merge(Style(background: bg)),
        );
      }
      colOffset += graphemeWidth(grapheme);
    }

    for (var y = caliperRow + 1; y < startY + height; y++) {
      _paintCaliperStem(buffer, offset, startX + leftCol, y, caliperStyle);
      if (rightCol > leftCol) {
        _paintCaliperStem(buffer, offset, startX + rightCol, y, caliperStyle);
      }
    }
  }

  void _paintCaliperStem(
    Buffer buffer,
    Offset offset,
    int cx,
    int y,
    Style caliperStyle,
  ) {
    final bgArgb = buffer.getBackground(cx, y);
    final bg = bgArgb == 0 ? null : Color.argb(bgArgb);
    _drawClippedCell(
      buffer,
      offset,
      cx,
      y,
      '│',
      caliperStyle.merge(Style(background: bg)),
    );
  }
}

final class _CellDrawTracker {
  final int width;
  final BoolArray? _array;
  final Set<int>? _set;

  _CellDrawTracker({
    required this.width,
    required int height,
    required bool useBoolArray,
  }) : _array = useBoolArray ? BoolArray(width * height) : null,
       _set = useBoolArray ? null : <int>{};

  bool isDrawn(int x, int y, int col, int visualY) {
    if (_array case final array?) {
      return array[visualY * width + col];
    }
    return _set!.contains((x << 16) | y);
  }

  void markDrawn(int x, int y, int col, int visualY) {
    if (_array case final array?) {
      array[visualY * width + col] = true;
    } else {
      _set!.add((x << 16) | y);
    }
  }

  bool isSpanOccluded(
    int startX,
    int y,
    int visualY,
    int startCol,
    int endCol,
  ) {
    for (var col = startCol; col <= endCol; col++) {
      if (!isDrawn(startX + 1 + col, y, col, visualY)) {
        return false;
      }
    }
    return true;
  }
}

double _coverage(
  double spanStart,
  double spanEnd,
  double cellStart,
  double cellEnd,
) {
  final start = max(spanStart, cellStart);
  final end = min(spanEnd, cellEnd);
  if (start >= end) return 0.0;
  return (end - start) / (cellEnd - cellStart);
}
