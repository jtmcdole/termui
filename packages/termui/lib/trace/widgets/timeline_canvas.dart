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

List<TraceSpan> getCulledSpans(
  List<TraceSpan> spans,
  double viewportStartUs,
  double viewportEndUs,
  int maxSpanDuration,
) {
  if (spans.isEmpty) return [];
  int idx = 0;
  int low = 0;
  int high = spans.length - 1;
  while (low <= high) {
    int mid = (low + high) ~/ 2;
    if (spans[mid].startUs >= viewportStartUs) {
      idx = mid;
      high = mid - 1;
    } else {
      low = mid + 1;
    }
  }

  final visibleSpans = <TraceSpan>[];
  for (int i = idx - 1; i >= 0; i--) {
    final span = spans[i];
    if (span.endUs >= viewportStartUs) {
      visibleSpans.add(span);
    }
    if (span.startUs < viewportStartUs - maxSpanDuration) {
      break;
    }
  }
  for (int i = idx; i < spans.length; i++) {
    if (spans[i].startUs <= viewportEndUs) {
      visibleSpans.add(spans[i]);
    } else {
      break;
    }
  }
  return visibleSpans;
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
  TimelineCanvasElement(super.widget);

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

    void drawCell(int cx, int cy, String char, Style style) {
      if (cx >= startX &&
          cx < startX + width &&
          cy >= startY &&
          cy < startY + height) {
        _safeSetCell(buffer, cx, cy, char, style);
      }
    }

    final borderStyle = const Style(foreground: Color(120, 120, 120));
    final hitGrid = HitGrid(width, height);

    // Paint left/right borders
    for (var y = 0; y < height; y++) {
      drawCell(startX, startY + y, '│', borderStyle);
      drawCell(startX + width - 1, startY + y, '│', borderStyle);
    }

    if (w.selectionStartUs != null && w.selectionEndUs != null) {
      final startUs = w.selectionStartUs!.toDouble();
      final endUs = w.selectionEndUs!.toDouble();

      final startColF = (startUs - w.offsetX) / w.zoomLevel;
      final endColF = (endUs - w.offsetX) / w.zoomLevel;

      final startCol = startColF.floor().clamp(0, width - 3);
      final endCol = endColF.floor().clamp(0, width - 3);

      if (endCol >= 0 && startCol < width - 2) {
        final highlightStyle = const Style(background: Color(40, 40, 80));
        for (var col = startCol; col <= endCol; col++) {
          final x = startX + 1 + col;
          for (var cy = startY; cy < startY + height; cy++) {
            _safeSetCell(buffer, x, cy, ' ', highlightStyle);
          }
        }
      }
    }

    final viewportStartUs = w.offsetX;
    final viewportEndUs = w.offsetX + (width - 2) * w.zoomLevel;
    final visibleSpans = getCulledSpans(
      w.spans,
      viewportStartUs,
      viewportEndUs,
      w.maxSpanDuration,
    );
    final mainSpans = visibleSpans;

    final Set<int>? drawnCellsSet = TimelineCanvas.debugUseBoolArray
        ? null
        : {};
    final BoolArray? drawnCellsArray = TimelineCanvas.debugUseBoolArray
        ? BoolArray(width * height)
        : null;

    for (final span in mainSpans) {
      final depth = span.depth;
      final visualY = depth - w.offsetY;
      if (visualY < 0 || visualY >= height) continue;
      final y = startY + visualY;

      final spanStartUs = span.startUs.toDouble();
      final spanEndUs = span.endUs.toDouble();

      final startColF = (spanStartUs - w.offsetX) / w.zoomLevel;
      final endColF = (spanEndUs - w.offsetX) / w.zoomLevel;

      final startCol = startColF.floor().clamp(0, width - 3);
      final endCol = endColF.floor().clamp(0, width - 3);

      var style = getCategoryStyle(span.category, span.name);

      if (w.animatedSpan == span &&
          w.animationProgress != null &&
          w.animationProgress! > 0) {
        final flashIntensity = (sin(w.animationProgress! * pi * 6).abs());
        if (flashIntensity > 0.5) {
          style = const Style(
            foreground: Colors.black,
            background: Colors.yellow,
          );
        }
      }

      if (spanStartUs == spanEndUs) {
        final x = startX + 1 + startCol;
        final cellKey = (x << 16) | y;
        if (TimelineCanvas.debugUseBoolArray) {
          final idx = visualY * width + startCol;
          if (drawnCellsArray![idx]) continue;
          drawnCellsArray[idx] = true;
        } else {
          if (drawnCellsSet!.contains(cellKey)) continue;
          drawnCellsSet.add(cellKey);
        }

        final bgArgb = buffer.getBackground(x, y);
        final bg = bgArgb == 0 ? null : Color.argb(bgArgb);
        drawCell(x, y, '│', style.merge(Style(background: bg)));
        hitGrid.setHit(startCol, visualY, span);
        continue;
      }

      final bgColStyle = Style(
        background: style.foreground,
        foreground: Colors.white,
      );
      final fallbackStyle = style;

      final nameWithPrefix = '▼ ${span.displayLabel}';
      final spanColWidth = endCol - startCol + 1;

      for (var col = startCol; col <= endCol; col++) {
        final x = startX + 1 + col;
        final cellKey = (x << 16) | y;
        if (TimelineCanvas.debugUseBoolArray) {
          final idx = visualY * width + col;
          if (drawnCellsArray![idx]) continue;
          drawnCellsArray[idx] = true;
        } else {
          if (drawnCellsSet!.contains(cellKey)) continue;
          drawnCellsSet.add(cellKey);
        }

        final cellStart = w.offsetX + col * w.zoomLevel;
        final cellEnd = cellStart + w.zoomLevel;

        final cov = _coverage(spanStartUs, spanEndUs, cellStart, cellEnd);
        if (cov > 0) {
          hitGrid.setHit(col, visualY, span);
          String char;
          Style cellStyle = bgColStyle;

          if (cov > 0.99) {
            final relativeCol = col - startCol;
            if (spanColWidth >= nameWithPrefix.length &&
                relativeCol >= 0 &&
                relativeCol < nameWithPrefix.length) {
              char = nameWithPrefix[relativeCol];
            } else {
              char = ' ';
            }
            if (TimelineCanvas.debugUseBoolArray) {
              final idx = visualY * width + col;
              drawnCellsArray![idx] = true;
            } else {
              drawnCellsSet!.add(cellKey);
            }
          } else {
            if (startCol == endCol) {
              char = cov <= 0.1 ? '│' : _getFractionalBlock(cov);
              cellStyle = fallbackStyle;
            } else if (col == startCol) {
              char = _getFractionalBlock(1.0 - cov);
              cellStyle = style.merge(
                Style(
                  foreground: null,
                  background: style.foreground ?? const Color(255, 255, 255),
                ),
              );
            } else {
              char = _getFractionalBlock(cov);
              cellStyle = fallbackStyle;
            }
            if (char == '│' || char == '█') {
              if (TimelineCanvas.debugUseBoolArray) {
                final idx = visualY * width + col;
                drawnCellsArray![idx] = true;
              } else {
                drawnCellsSet!.add(cellKey);
              }
            }
          }
          drawCell(x, y, char, cellStyle);
        }
      }
    }

    // Draw Caliper Overlay
    if (w.measureStartMs != null && w.measureEndMs != null) {
      final startUs = w.measureStartMs! * 1000.0;
      final endUs = w.measureEndMs! * 1000.0;
      final col1 = ((startUs - w.offsetX) / w.zoomLevel).round();
      final col2 = ((endUs - w.offsetX) / w.zoomLevel).round();
      final leftCol = min(col1, col2).clamp(0, width - 3) + 1;
      final rightCol = max(col1, col2).clamp(0, width - 3) + 1;
      final spanWidth = rightCol - leftCol + 1;
      final durationMs = (endUs - startUs).abs() / 1000.0;
      final text = ' ${durationMs.toStringAsFixed(1)}ms ';
      String caliperStr;
      if (spanWidth >= text.length + 4) {
        final dashes = spanWidth - 2 - text.length;
        final leftDashes = dashes ~/ 2;
        final rightDashes = dashes - leftDashes;
        caliperStr = '├${'─' * leftDashes}$text${'─' * rightDashes}┤';
      } else if (spanWidth >= 2) {
        caliperStr = '├${'─' * (spanWidth - 2)}┤';
      } else {
        caliperStr = '│';
      }

      final caliperStyle = const Style(
        foreground: Color(0, 255, 255),
        modifiers: Modifier.bold,
      );
      final caliperRow = startY - 1;
      // We draw directly into the buffer for startY - 1, bypassing drawCell's cy >= startY check
      for (var i = 0; i < caliperStr.length; i++) {
        final cx = startX + leftCol + i;
        if (cx >= startX && cx < startX + width) {
          final bgArgb = buffer.getBackground(cx, caliperRow);
          final bg = bgArgb == 0 ? null : Color.argb(bgArgb);
          _safeSetCell(
            buffer,
            cx,
            caliperRow,
            caliperStr[i],
            caliperStyle.merge(Style(background: bg)),
          );
        }
      }

      for (var y = caliperRow + 1; y < startY + height; y++) {
        final bgArgb1 = buffer.getBackground(startX + leftCol, y);
        final bg1 = bgArgb1 == 0 ? null : Color.argb(bgArgb1);
        drawCell(
          startX + leftCol,
          y,
          '│',
          caliperStyle.merge(Style(background: bg1)),
        );

        if (rightCol > leftCol) {
          final bgArgb2 = buffer.getBackground(startX + rightCol, y);
          final bg2 = bgArgb2 == 0 ? null : Color.argb(bgArgb2);
          drawCell(
            startX + rightCol,
            y,
            '│',
            caliperStyle.merge(Style(background: bg2)),
          );
        }
      }
    }

    if (w.onHitGridUpdated != null) {
      w.onHitGridUpdated!(hitGrid);
    }
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
