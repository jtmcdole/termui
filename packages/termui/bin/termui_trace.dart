import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:isolate';

import 'package:termui/termui.dart';
import 'package:termui/ui/event.dart' as evt;
import 'package:termui/ui/renderer.dart';

class TraceEvent {
  final String name;
  final String phase;
  final String category;
  final int timestamp;
  final int tid;
  final Map<String, String> args;

  TraceEvent({
    required this.name,
    required this.phase,
    required this.category,
    required this.timestamp,
    required this.tid,
    required this.args,
  });

  factory TraceEvent.fromJson(Map<String, dynamic> json) {
    final argsRaw = json['args'] ?? json['metadata'];
    final Map<String, String> parsedArgs = {};
    if (argsRaw is Map) {
      argsRaw.forEach((k, v) {
        parsedArgs[k.toString()] = jsonEncode(v);
      });
    }
    return TraceEvent(
      name: json['name'] as String? ?? 'Unknown',
      phase: json['ph'] as String? ?? 'i',
      category: json['cat'] as String? ?? 'TUI',
      timestamp: json['ts'] as int? ?? 0,
      tid: json['tid'] as int? ?? 0,
      args: parsedArgs,
    );
  }
}

/// Interval representing a matched Begin/End trace event.
class TraceSpan {
  final String name;
  final String category;
  final int startUs;
  final int endUs;
  final int depth;
  final Map<String, String> args;

  final String displayLabel;

  TraceSpan({
    required this.name,
    required this.category,
    required this.startUs,
    required this.endUs,
    required this.depth,
    required this.args,
    String? displayLabel,
  }) : displayLabel = displayLabel ?? _computeDisplayLabel(name, args);

  static String _computeDisplayLabel(String name, Map<String, String> args) {
    if (args.containsKey('text')) {
      // The text value might be JSON encoded with quotes, let's strip surrounding quotes if they exist, or just use it.
      var text = args['text']!;
      if (text.startsWith('"') && text.endsWith('"') && text.length >= 2) {
        text = text.substring(1, text.length - 1);
      }
      final truncated = text.length > 20 ? '${text.substring(0, 17)}...' : text;
      return '$name "$truncated"';
    } else if (args.containsKey('widget')) {
      var widgetStr = args['widget']!;
      if (widgetStr.startsWith('"') &&
          widgetStr.endsWith('"') &&
          widgetStr.length >= 2) {
        widgetStr = widgetStr.substring(1, widgetStr.length - 1);
      }
      return '$name <$widgetStr>';
    }
    return name;
  }
}

class _StackEntry {
  final TraceEvent event;
  final int depth;
  _StackEntry(this.event, this.depth);
}

/// Reconstructs TraceSpans from raw TraceEvents.
List<TraceSpan> computeSpans(List<TraceEvent> events) {
  final sorted = List<TraceEvent>.from(events)
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

  final absoluteMaxTimestamp = sorted.isEmpty ? 0 : sorted.last.timestamp;

  final List<TraceSpan> spans = [];
  final Map<int, List<_StackEntry>> activeStacksByTid = {};

  for (final event in sorted) {
    final tid = event.tid;
    activeStacksByTid.putIfAbsent(tid, () => []);
    final stack = activeStacksByTid[tid]!;

    if (event.phase == 'B') {
      stack.add(_StackEntry(event, stack.length));
    } else if (event.phase == 'E') {
      int matchIdx = -1;
      for (int i = stack.length - 1; i >= 0; i--) {
        if (stack[i].event.name == event.name) {
          matchIdx = i;
          break;
        }
      }
      if (matchIdx != -1) {
        // Pop orphaned children above the matched parent
        while (stack.length > matchIdx + 1) {
          final orphanEntry = stack.removeLast();
          final orphanEvent = orphanEntry.event;
          spans.add(
            TraceSpan(
              name: orphanEvent.name,
              category: orphanEvent.category,
              startUs: orphanEvent.timestamp,
              endUs: event.timestamp, // Auto-closed at parent's end
              depth: orphanEntry.depth,
              args: orphanEvent.args,
            ),
          );
        }

        // Pop the actual matched parent
        final beginEntry = stack.removeLast();
        final begin = beginEntry.event;
        spans.add(
          TraceSpan(
            name: begin.name,
            category: begin.category,
            startUs: begin.timestamp,
            endUs: event.timestamp,
            depth: beginEntry.depth,
            args: begin.args,
          ),
        );
      }
    } else if (event.phase == 'i') {
      spans.add(
        TraceSpan(
          name: event.name,
          category: event.category,
          startUs: event.timestamp,
          endUs: event.timestamp + 1,
          depth: stack.length,
          args: event.args,
        ),
      );
    }
  }
  for (final tid in activeStacksByTid.keys) {
    for (final entry in activeStacksByTid[tid]!) {
      final begin = entry.event;
      spans.add(
        TraceSpan(
          name: begin.name,
          category: begin.category,
          startUs: begin.timestamp,
          endUs:
              absoluteMaxTimestamp, // Indicates missing 'E' phase is clamped to trace end
          depth: entry.depth,
          args: begin.args,
        ),
      );
    }
  }
  return spans;
}

int fnv1aHash(String string) {
  int hash = 0x811c9dc5;
  for (int i = 0; i < string.length; i++) {
    hash ^= string.codeUnitAt(i);
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

Color hslToRgb(double h, double s, double l) {
  double c = (1 - (2 * l - 1).abs()) * s;
  double x = c * (1 - ((h / 60.0) % 2.0 - 1).abs());
  double m = l - c / 2.0;
  double r = 0, g = 0, b = 0;
  if (h >= 0 && h < 60) {
    r = c;
    g = x;
    b = 0;
  } else if (h >= 60 && h < 120) {
    r = x;
    g = c;
    b = 0;
  } else if (h >= 120 && h < 180) {
    r = 0;
    g = c;
    b = x;
  } else if (h >= 180 && h < 240) {
    r = 0;
    g = x;
    b = c;
  } else if (h >= 240 && h < 300) {
    r = x;
    g = 0;
    b = c;
  } else if (h >= 300 && h < 360) {
    r = c;
    g = 0;
    b = x;
  }
  return Color(
    ((r + m) * 255).round(),
    ((g + m) * 255).round(),
    ((b + m) * 255).round(),
  );
}

Style getCategoryStyle(String category, String name) {
  int h = fnv1aHash(name).abs() % 360;
  return Style(foreground: hslToRgb(h.toDouble(), 0.75, 0.60));
}

void _safeSetCell(Buffer buffer, int x, int y, String char, Style style) {
  final cell = buffer.getCell(x, y);
  if (cell != null) {
    cell.char = char;
    cell.style = style;
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

List<TraceSpan> _getCulledSpans(
  List<TraceSpan> spans,
  double viewportStartUs,
  double viewportEndUs,
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
    if (spans[i].endUs >= viewportStartUs) {
      visibleSpans.add(spans[i]);
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
class TimelineCanvas extends Widget {
  final List<TraceSpan> spans;
  final double offsetX;
  final int offsetY;
  final double zoomLevel;
  final double? measureStartMs;
  final double? measureEndMs;

  const TimelineCanvas({
    super.key,
    required this.spans,
    required this.offsetX,
    required this.offsetY,
    required this.zoomLevel,
    this.measureStartMs,
    this.measureEndMs,
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

    // Paint left/right borders
    for (var y = 0; y < height; y++) {
      drawCell(startX, startY + y, '│', borderStyle);
      drawCell(startX + width - 1, startY + y, '│', borderStyle);
    }

    final viewportStartUs = w.offsetX;
    final viewportEndUs = w.offsetX + (width - 2) * w.zoomLevel;
    final visibleSpans = _getCulledSpans(
      w.spans,
      viewportStartUs,
      viewportEndUs,
    );
    final mainSpans = visibleSpans;

    final Set<int> drawnCells = {};

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

      final style = getCategoryStyle(span.category, span.name);

      if (spanStartUs == spanEndUs) {
        final x = startX + 1 + startCol;
        final cellKey = (x << 16) | y;
        if (drawnCells.contains(cellKey)) continue;

        final existing = buffer.getCell(x, y);
        final bg = existing?.style.background;
        drawCell(x, y, '│', style.merge(Style(background: bg)));
        drawnCells.add(cellKey);
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
        if (drawnCells.contains(cellKey)) continue;

        final cellStart = w.offsetX + col * w.zoomLevel;
        final cellEnd = cellStart + w.zoomLevel;

        final cov = _coverage(spanStartUs, spanEndUs, cellStart, cellEnd);
        if (cov > 0) {
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
            drawnCells.add(cellKey);
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
              drawnCells.add(cellKey);
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
          final existingCell = buffer.getCell(cx, caliperRow);
          final bg = existingCell?.style.background;
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
        final ex1 = buffer.getCell(startX + leftCol, y);
        final bg1 = ex1?.style.background;
        drawCell(
          startX + leftCol,
          y,
          '│',
          caliperStyle.merge(Style(background: bg1)),
        );

        if (rightCol > leftCol) {
          final ex2 = buffer.getCell(startX + rightCol, y);
          final bg2 = ex2?.style.background;
          drawCell(
            startX + rightCol,
            y,
            '│',
            caliperStyle.merge(Style(background: bg2)),
          );
        }
      }
    }
  }
}

Future<Map<String, Object>?> _parseTraceFile(String path) async {
  return await Isolate.run(() {
    final file = File(path);
    if (!file.existsSync()) return null;

    final content = file.readAsStringSync();
    final jsonList = jsonDecode(content) as List<dynamic>;
    final events = jsonList
        .map((e) => TraceEvent.fromJson(e as Map<String, dynamic>))
        .toList();

    if (events.isNotEmpty) {
      final baseTime = events.map((e) => e.timestamp).reduce(min);
      for (var i = 0; i < events.length; i++) {
        final ev = events[i];
        events[i] = TraceEvent(
          name: ev.name,
          phase: ev.phase,
          category: ev.category,
          timestamp: ev.timestamp - baseTime,
          tid: ev.tid,
          args: ev.args,
        );
      }
    }

    final computedSpans = computeSpans(events);
    if (computedSpans.isEmpty) return null;

    computedSpans.sort((a, b) => a.startUs.compareTo(b.startUs));

    final mMinTs = computedSpans.map((s) => s.startUs).reduce(min);
    final mMaxTs = computedSpans.map((s) => s.endUs).reduce(max);

    return {'spans': computedSpans, 'minTs': mMinTs, 'maxTs': mMaxTs};
  });
}

class TraceViewerApp extends StatefulWidget {
  final String? filePath;
  final List<TraceSpan>? spans;
  final int? minTs;
  final int? maxTs;

  const TraceViewerApp({
    super.key,
    this.filePath,
    this.spans,
    this.minTs,
    this.maxTs,
  });

  @override
  State<TraceViewerApp> createState() => _TraceViewerAppState();
}

class _TraceViewerAppState extends State<TraceViewerApp>
    implements evt.KeyEventHandler, evt.MouseEventHandler, evt.Focusable {
  List<TraceSpan>? spans;
  int? minTs;
  int? maxTs;

  late double offsetX;
  late double zoomLevel;
  int offsetY = 0;

  // Memoized search overlay state
  int _searchWindowW = 40;
  int _searchWindowH = 10;
  int _searchWindowX = 2;
  int _searchWindowY = 2;
  String _searchQuery = '';
  TraceSpan? hoveredSpan;

  int? _dragStartX;
  double? _dragStartOffsetX;

  double? measureStartMs;
  double? measureEndMs;
  SceneLayer? _marqueeLayer;
  int? _marqueeStartX;
  int? _marqueeStartY;

  SceneLayer? _helpLayer;

  void _spawnHelpOverlay() {
    if (_helpLayer != null) return;

    final w = 45;
    final h = 18;
    final x = 2;
    final y = 2;

    late PromptRunner<void> runner;

    void handleClose() {
      if (_helpLayer != null) {
        globalSceneManager.layers.remove(_helpLayer!);
        globalSceneManager.focusedLayer = globalSceneManager.layers.first;
        _helpLayer = null;
        globalSceneManager.render();
      }
    }

    final overlay = Focus(
      onKeyEvent: (event) {
        if (event.type == evt.KeyType.escape ||
            event.key.toLowerCase() == 'q' ||
            event.key.toLowerCase() == 'x') {
          handleClose();
          runner.dispose();
          return true;
        }
        return false;
      },
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(
            topChar: '─',
            bottomChar: '─',
            leftChar: '│',
            rightChar: '│',
            topLeftChar: '┌',
            topRightChar: '┐',
            bottomLeftChar: '└',
            bottomRightChar: '┘',
            style: Style(foreground: Colors.white),
          ),
          backgroundColor: Color(30, 30, 30),
        ),
        child: Column([
          Row([
            Text(
              ' Help / Shortcuts [Esc to close]',
              style: const Style(foreground: Color(0, 255, 255)),
            ),
          ]),
          SizedBox(
            height: 1,
            child: Text(
              '─' * 45,
              style: const Style(foreground: Color(128, 128, 128)),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(1),
              child: ListView.raw(
                lines: const [
                  'w / = / Up  : Zoom In',
                  's / - / Down: Zoom Out',
                  'a / Left    : Pan Left',
                  'd / Right   : Pan Right',
                  '/           : Search Overlay',
                  '? / h       : Help Overlay',
                  'z           : Toggle Box Select',
                  'm           : Toggle Caliper',
                  'Mouse Drag  : Pan Timeline',
                  'Ctrl+Drag   : Box Select Zoom',
                  'Scroll Wheel: Zoom in/out at mouse',
                ],
              ),
            ),
          ),
        ]),
      ),
    );

    runner = PromptRunner<void>(
      terminal: globalSceneManager.terminal,
      widget: overlay,
      alternateScreen: false,
      mode: ExecutionMode.managed,
      onFramePainted: (_) => globalSceneManager.render(),
    );

    _helpLayer = SceneLayer(
      renderer: runner,
      sizing: LayerSizing.fixed,
      x: x,
      y: y,
      width: w,
      height: h,
      zIndex: 110,
      draggable: true,
    );

    globalSceneManager.layers.add(_helpLayer!);
    globalSceneManager.focusedLayer = _helpLayer;

    runner.run().ignore();
  }

  SceneLayer? _searchLayer;

  void _spawnSearchOverlay() {
    if (_searchLayer != null) return;

    final w = _searchWindowW;
    final h = _searchWindowH;
    final x = _searchWindowX;
    final y = _searchWindowY;

    late PromptRunner<void> runner;

    void handleClose() {
      if (_searchLayer != null) {
        _searchWindowX = _searchLayer!.x;
        _searchWindowY = _searchLayer!.y;
        _searchWindowW = _searchLayer!.width ?? _searchWindowW;
        _searchWindowH = _searchLayer!.height ?? _searchWindowH;
        globalSceneManager.layers.remove(_searchLayer!);
        globalSceneManager.focusedLayer = globalSceneManager.layers.first;
        _searchLayer = null;
        globalSceneManager.render();
      }
    }

    final overlay = SearchOverlay(
      spans: spans ?? [],
      initialQuery: _searchQuery,
      onQueryChanged: (query) {
        _searchQuery = query;
      },
      onMatchSelected: (span) {
        setState(() {
          final centerCol = (w - 2) / 2.0;
          offsetX = span.startUs.toDouble() - centerCol * zoomLevel;
          hoveredSpan = span;
        });
      },
      onClose: handleClose,
    );

    runner = PromptRunner<void>(
      terminal: globalSceneManager.terminal,
      widget: overlay,
      alternateScreen: false,
      mode: ExecutionMode.managed,
      onFramePainted: (_) => globalSceneManager.render(),
    );

    _searchLayer = SceneLayer(
      renderer: runner,
      sizing: LayerSizing.fixed,
      x: x,
      y: y,
      width: w,
      height: h,
      zIndex: 100,
      draggable: true,
      resizable: true,
    );

    globalSceneManager.layers.add(_searchLayer!);
    globalSceneManager.focusedLayer = _searchLayer;

    runner.run().ignore();
  }

  bool isCaliperMode = false;
  bool isBoxSelectMode = false;
  bool isLoading = true;
  String? loadError;

  @override
  bool get focused => true;

  @override
  void initState() {
    super.initState();
    if (widget.filePath != null) {
      _loadTraceData();
    } else {
      spans = widget.spans;
      minTs = widget.minTs;
      maxTs = widget.maxTs;
      final duration = maxTs! - minTs!;
      zoomLevel = duration > 0 ? duration / 80.0 : 1.0;
      offsetX = minTs!.toDouble();
      isLoading = false;
    }
  }

  Future<void> _loadTraceData() async {
    File(
      'debug.log',
    ).writeAsStringSync('Started loading trace data\n', mode: FileMode.append);
    try {
      final result = await _parseTraceFile(widget.filePath!);
      File(
        'debug.log',
      ).writeAsStringSync('Finished _parseTraceFile\n', mode: FileMode.append);

      if (mounted) {
        if (result != null) {
          setState(() {
            spans = result['spans'] as List<TraceSpan>;
            minTs = result['minTs'] as int;
            maxTs = result['maxTs'] as int;
            final duration = maxTs! - minTs!;
            zoomLevel = duration > 0 ? duration / 80.0 : 1.0;
            offsetX = minTs!.toDouble();
            isLoading = false;
            File('debug.log').writeAsStringSync(
              'setState called successfully\n',
              mode: FileMode.append,
            );
          });
        } else {
          // error case
          setState(() {
            isLoading = false;
            loadError = "Parsed 0 spans";
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          isLoading = false;
          loadError = 'Error parsing trace: $e';
        });
      }
    }
  }

  @override
  bool handleKeyEvent(evt.KeyEvent event) {
    if (isLoading || spans == null) return false;
    final keyLower = event.key.toLowerCase();
    final type = event.type;

    if (keyLower == 'q') {
      PromptScope.of(context)?.done();
      return true;
    }

    if (keyLower == 'z') {
      setState(() {
        isBoxSelectMode = !isBoxSelectMode;
        if (isBoxSelectMode) {
          isCaliperMode = false;
          measureStartMs = null;
          measureEndMs = null;
        }
        if (!isBoxSelectMode) {
          if (_marqueeLayer != null) {
            globalSceneManager.layers.remove(_marqueeLayer);
            _marqueeLayer = null;
            globalSceneManager.render();
          }
          _marqueeStartX = null;
          _marqueeStartY = null;
        }
      });
      return true;
    }

    if (keyLower == 'm') {
      setState(() {
        isCaliperMode = !isCaliperMode;
        if (isCaliperMode) {
          isBoxSelectMode = false;
          if (_marqueeLayer != null) {
            globalSceneManager.layers.remove(_marqueeLayer);
            _marqueeLayer = null;
            globalSceneManager.render();
          }
          _marqueeStartX = null;
          _marqueeStartY = null;
        }
        if (!isCaliperMode) {
          measureStartMs = null;
          measureEndMs = null;
        }
      });
      return true;
    }

    if (keyLower == 'escape' || type == evt.KeyType.escape) {
      setState(() {
        isCaliperMode = false;
        isBoxSelectMode = false;
        if (_marqueeLayer != null) {
          globalSceneManager.layers.remove(_marqueeLayer);
          _marqueeLayer = null;
          globalSceneManager.render();
        }
        _marqueeStartX = null;
        _marqueeStartY = null;

        measureStartMs = null;
        measureEndMs = null;
      });
      return true;
    }

    if (keyLower == '/') {
      _spawnSearchOverlay();
      return true;
    }

    if (keyLower == '?' || keyLower == 'h') {
      _spawnHelpOverlay();
      return true;
    }

    if (keyLower == 'a' || type == evt.KeyType.left) {
      setState(() {
        offsetX = max(minTs!.toDouble() - 1000000.0, offsetX - 10 * zoomLevel);
      });
      return true;
    }
    if (keyLower == 'd' || type == evt.KeyType.right) {
      setState(() {
        offsetX = min(maxTs!.toDouble(), offsetX + 10 * zoomLevel);
      });
      return true;
    }

    if (keyLower == 'w' || type == evt.KeyType.up) {
      setState(() {
        offsetY = max(0, offsetY - 1);
      });
      return true;
    }
    if (keyLower == 's' || type == evt.KeyType.down) {
      setState(() {
        offsetY++;
      });
      return true;
    }

    if (keyLower == '=' || keyLower == '+') {
      final width = ((context as Element).size.width).toDouble();
      final centerCol = (width - 2) / 2.0;
      final focusTime = offsetX + centerCol * zoomLevel;
      final newZoom = max(0.001, zoomLevel * 0.9);
      setState(() {
        zoomLevel = newZoom;
        offsetX = focusTime - centerCol * newZoom;
      });
      return true;
    }
    if (keyLower == '-') {
      final width = ((context as Element).size.width).toDouble();
      final centerCol = (width - 2) / 2.0;
      final focusTime = offsetX + centerCol * zoomLevel;
      final newZoom = min(1000000.0, zoomLevel * 1.1);
      setState(() {
        zoomLevel = newZoom;
        offsetX = focusTime - centerCol * newZoom;
      });
      return true;
    }

    return false;
  }

  @override
  void handleMouseEvent(evt.MouseEvent event, int localX, int localY) {
    if (isLoading || spans == null) return;
    final isBoxSelect =
        isBoxSelectMode || event.modifiers.contains(evt.Modifier.control);

    if (event.type == evt.MouseEventType.press) {
      if (isBoxSelect) {
        _marqueeStartX = event.globalX ?? localX;
        _marqueeStartY = event.globalY ?? localY;
        setState(() {
          measureStartMs = null;
          measureEndMs = null;
          _dragStartX = null;
          _dragStartOffsetX = null;
        });
      } else if (isCaliperMode) {
        final timeMs = (offsetX + (localX - 1) * zoomLevel) / 1000.0;
        setState(() {
          measureStartMs = timeMs;
          measureEndMs = timeMs;
        });
      } else {
        _dragStartX = localX;
        _dragStartOffsetX = offsetX;
        setState(() {
          measureStartMs = null;
          measureEndMs = null;
        });
      }
    } else if (event.type == evt.MouseEventType.drag) {
      if (isBoxSelect && _marqueeStartX != null) {
        if (_marqueeLayer == null) {
          final renderer = MarqueeRenderer();
          _marqueeLayer = SceneLayer(
            renderer: renderer,
            sizing: LayerSizing.fixed,
            zIndex: 1000,
          );
          globalSceneManager.layers.add(_marqueeLayer!);
        }

        final currX = event.globalX ?? localX;
        final currY = event.globalY ?? localY;

        final minX = min(_marqueeStartX!, currX);
        final w = (currX - _marqueeStartX!).abs() + 1;
        final minY = min(_marqueeStartY!, currY);
        final h = (currY - _marqueeStartY!).abs() + 1;

        _marqueeLayer!.x = minX - 1;
        _marqueeLayer!.y = minY - 1;
        _marqueeLayer!.renderer.resize(w, h);

        globalSceneManager.render();
      } else if (isCaliperMode && measureStartMs != null) {
        final timeMs = (offsetX + (localX - 1) * zoomLevel) / 1000.0;
        setState(() {
          measureEndMs = timeMs;
        });
      } else if (_dragStartX != null &&
          _dragStartOffsetX != null &&
          !isBoxSelect) {
        final dx = localX - _dragStartX!;
        setState(() {
          offsetX = _dragStartOffsetX! - (dx * zoomLevel);
        });
      }
    } else if (event.type == evt.MouseEventType.release) {
      if (_marqueeLayer != null) {
        final currX = event.globalX ?? localX;
        final minX = min(_marqueeStartX!, currX);
        final w = (currX - _marqueeStartX!).abs() + 1;

        final startUs = offsetX + (minX - 1) * zoomLevel;
        final durationUs = w * zoomLevel;

        if (durationUs > 0) {
          final width = ((context as Element).size.width).toDouble();
          final newZoom = durationUs / max(1.0, width - 2);
          setState(() {
            zoomLevel = max(0.001, newZoom);
            offsetX = startUs;
          });
        }

        globalSceneManager.layers.remove(_marqueeLayer);
        _marqueeLayer = null;
        globalSceneManager.render();
      }
      _marqueeStartX = null;
      _marqueeStartY = null;
      _dragStartX = null;
      _dragStartOffsetX = null;
    }

    // Scroll zooming
    if (event.button == evt.MouseButton.wheelUp) {
      final col = (localX - 1).toDouble();
      final focusTime = offsetX + col * zoomLevel;
      final newZoom = max(0.001, zoomLevel * 0.9);
      setState(() {
        zoomLevel = newZoom;
        offsetX = focusTime - col * newZoom;
      });
      return;
    } else if (event.button == evt.MouseButton.wheelDown) {
      final col = (localX - 1).toDouble();
      final focusTime = offsetX + col * zoomLevel;
      final newZoom = min(1000000.0, zoomLevel * 1.1);
      setState(() {
        zoomLevel = newZoom;
        offsetX = focusTime - col * newZoom;
      });
      return;
    }

    // Hover detection
    final H = (context as Element).size.height;
    final hoveredTime = offsetX + (localX - 1) * zoomLevel;
    TraceSpan? hit;

    final hoveredDepth = localY - 3 + offsetY;
    if (localY >= 3 && localY <= H - 7 && hoveredDepth >= 0) {
      for (final span in spans!) {
        if (span.depth == hoveredDepth &&
            hoveredTime >= span.startUs &&
            hoveredTime <= span.endUs) {
          hit = span;
          break;
        }
      }
    }

    setState(() {
      hoveredSpan = hit;
    });
  }

  Widget buildHeader(String modeText) {
    final borderStyle = const Style(foreground: Color(120, 120, 120));
    return SizedBox(
      height: 1,
      child: Row(
        [
          Text('┌─ [ termui trace viewer ] ─', style: borderStyle),
          Text('─ [ Mode: $modeText ] ─┐', style: borderStyle),
        ],
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        backgroundChar: '─',
        backgroundStyle: borderStyle,
      ),
    );
  }

  Widget buildRuler() {
    return SizedBox(
      height: 1,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final borderStyle = const Style(foreground: Color(120, 120, 120));
          final tickStyle = const Style(foreground: Color(180, 180, 180));
          if (width <= 2) {
            return Row([
              Text('│', style: borderStyle),
              Expanded(child: const SizedBox()),
              Text('│', style: borderStyle),
            ]);
          }

          final tickCount = 6;
          final segmentsWidth = width - 2;
          final children = <Widget>[Text('│', style: borderStyle)];

          for (var i = 0; i < tickCount; i++) {
            int col;
            TextAlign align;
            if (i == 0) {
              col = 0;
              align = TextAlign.left;
            } else if (i == tickCount - 1) {
              col = segmentsWidth;
              align = TextAlign.right;
            } else {
              col = ((i + 0.5) * segmentsWidth / tickCount).round();
              align = TextAlign.center;
            }

            final tickTimeMs = (offsetX + col * zoomLevel) / 1000.0;
            final label = formatDuration(tickTimeMs);

            children.add(
              Expanded(
                child: Text(label, style: tickStyle, textAlign: align),
              ),
            );
          }

          children.add(Text('│', style: borderStyle));

          return Row(children);
        },
      ),
    );
  }

  Widget buildSeparator(String title) {
    final borderStyle = const Style(foreground: Color(120, 120, 120));
    return SizedBox(
      height: 1,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final titlePart = '─ $title ';
          String separatorStr;
          if (width >= titlePart.length + 6) {
            separatorStr =
                '├─$titlePart${'─' * (width - 3 - titlePart.length)}┤';
          } else {
            separatorStr = '├${'─' * (width - 2)}┤';
          }
          return Text(separatorStr, style: borderStyle);
        },
      ),
    );
  }

  String formatDuration(double ms) {
    if (ms < 0.001) {
      return '${(ms * 1000000).toStringAsFixed(1)} ns';
    } else if (ms < 1.0) {
      return '${(ms * 1000).toStringAsFixed(1)} μs';
    } else {
      return '${ms.toStringAsFixed(2)} ms';
    }
  }

  Widget buildInspectorPanel() {
    return SizedBox(
      height: 6,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxWidth = constraints.maxWidth;

          Widget contentWidget;
          if (hoveredSpan == null) {
            contentWidget = Text(
              'No event hovered. Hover over a span to inspect details.',
              style: const Style(foreground: Colors.white),
            );
          } else {
            final span = hoveredSpan!;
            final durMs = (span.endUs - span.startUs) / 1000.0;
            final startMs = span.startUs / 1000.0;
            final endMs = span.endUs / 1000.0;

            final children = <Widget>[];

            String titleLine = '[Hovered] ${span.displayLabel}';
            if (titleLine.length > maxWidth - 4) {
              titleLine = '${titleLine.substring(0, maxWidth - 7)}...';
            }
            children.add(
              Text(
                titleLine,
                style: const Style(foreground: Colors.white),
                wrap: false,
              ),
            );

            String timingLine =
                'Start: ${formatDuration(startMs)}  |  End: ${formatDuration(endMs)}  |  Duration: ${formatDuration(durMs)}';
            if (timingLine.length > maxWidth - 4) {
              timingLine = '${timingLine.substring(0, maxWidth - 7)}...';
            }
            children.add(
              Text(
                timingLine,
                style: const Style(foreground: Colors.white),
                wrap: false,
              ),
            );

            if (span.args.isNotEmpty) {
              children.add(
                Text(
                  'Args:',
                  style: const Style(foreground: Colors.white),
                  wrap: false,
                ),
              );

              final argChildren = <Widget>[];
              for (final entry in span.args.entries) {
                var line = '  ${entry.key}: ${entry.value}';
                if (line.length > maxWidth - 4) {
                  line = '${line.substring(0, maxWidth - 7)}...';
                }
                argChildren.add(
                  Text(
                    line,
                    style: const Style(foreground: Colors.white),
                    wrap: false,
                  ),
                );
              }
              children.add(
                Expanded(
                  child: ListView(
                    children: argChildren,
                    selectedStyle: Style.empty,
                  ),
                ),
              );
            }

            contentWidget = Column(children);
          }

          return DecoratedBox(
            decoration: const BoxDecoration(
              border: Border(
                topChar: '─',
                bottomChar: '─',
                leftChar: '│',
                rightChar: '│',
                topLeftChar: '├',
                topRightChar: '┤',
                bottomLeftChar: '└',
                bottomRightChar: '┘',
                style: Style(foreground: Color(120, 120, 120)),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
              child: contentWidget,
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Center(
        child: Text(
          '[ Loading Trace Data... ]',
          style: const Style(foreground: Colors.yellow),
        ),
      );
    }

    if (loadError != null) {
      return Center(
        child: Text(
          '[ $loadError ]',
          style: const Style(foreground: Colors.red),
        ),
      );
    }

    if (spans == null || spans!.isEmpty) {
      return Center(
        child: Text(
          '[ Error loading trace ]',
          style: const Style(foreground: Colors.red),
        ),
      );
    }

    final modeText = isCaliperMode ? 'Caliper' : 'Pan';
    return Column([
      buildHeader(modeText),
      buildRuler(),
      buildSeparator('Main Isolate'),
      Expanded(
        child: TimelineCanvas(
          spans: spans!,
          offsetX: offsetX,
          offsetY: offsetY,
          zoomLevel: zoomLevel,
          measureStartMs: measureStartMs,
          measureEndMs: measureEndMs,
        ),
      ),
      buildInspectorPanel(),
    ], crossAxisAlignment: CrossAxisAlignment.stretch);
  }
}

late SceneManager globalSceneManager;

class MarqueeRenderer implements SceneRenderer {
  Buffer? _buffer;

  @override
  Buffer? get currentBuffer => _buffer;

  @override
  bool get wantsMouseTracking => false;

  @override
  bool get wantsAlternateScreen => false;

  @override
  bool get showsCursor => false;

  @override
  Point<int>? get requestedCursorPosition => null;

  @override
  void handleKeyEvent(evt.KeyEvent event) {}

  @override
  void handleMouseEvent(evt.MouseEvent event) {}

  @override
  void resize(int width, int height) {
    _buffer = Buffer.blank(width, height);
    final style = Style(foreground: const Color(100, 200, 255));
    if (width == 1 && height == 1) {
      _buffer!.writeString(0, 0, '🔎', style);
      return;
    }

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        String? char;
        if (x == 0 && y == 0) {
          char = '┌';
        } else if (x == width - 1 && y == 0) {
          char = '┐';
        } else if (x == 0 && y == height - 1) {
          char = '└';
        } else if (x == width - 1 && y == height - 1) {
          char = '┘';
        } else if (x == 0 || x == width - 1) {
          char = '│';
        } else if (y == 0 || y == height - 1) {
          char = '─';
        }

        if (char != null) {
          _buffer!.setCell(x, y, Cell(char, style));
        } else {
          _buffer!.setCell(x, y, Cell.empty());
        }
      }
    }

    // Use writeString to handle double-width character properly
    _buffer!.writeString(width ~/ 2, height ~/ 2, '🔎', style);
  }
}

void main(List<String> arguments) async {
  if (arguments.isEmpty) {
    print('Usage: termui_trace <path_to_json>');
    exit(1);
  }

  final filePath = arguments[0];

  await Terminal.runGuarded((terminal) async {
    globalSceneManager = SceneManager(
      terminal,
      renderingMode: RenderingMode.alternateScreen,
    );
    globalSceneManager.enableMouseTracking = true;

    terminal.enterAlternateScreen();
    terminal.hideCursor();
    terminal.enableMouseTracking();

    final app = TraceViewerApp(filePath: filePath);

    final runner = PromptRunner<void>(
      terminal: terminal,
      widget: app,
      alternateScreen: true,
      mode: ExecutionMode.managed,
      onFramePainted: (_) => globalSceneManager.render(),
    );

    final appLayer = SceneLayer(
      renderer: runner,
      sizing: LayerSizing.fullscreen,
      zIndex: 0,
    );

    globalSceneManager.layers.add(appLayer);
    globalSceneManager.focusedLayer = appLayer;

    // Force an initial layout/resize to prevent uninitialized buffers
    final termSize = await terminal.size;
    runner.resize(termSize.x, termSize.y);

    // We run it as a future, but since we await it, when PromptScope done() is called, it unblocks

    // We need to wait for exit. Since it's managed, we just wait for runner's future? No, run() doesn't return until done?
    // Wait, let's just await runner.run()! Wait, if we await it, the event loop keeps running because Terminal is listening, but actually SceneManager is listening!

    // Actually, SceneManager listens, but if we block on runner.run(), it might not get events if it's managed?
    // In managed mode, PromptRunner DOES NOT listen to terminal events. SceneManager does! SceneManager routes them to runner!
    // So if we await runner.run(), we block until runner's completer is finished (which happens when q is pressed).
    await runner.run();

    globalSceneManager.dispose();
    terminal.exitAlternateScreen();
    terminal.showCursor();
    terminal.disableMouseTracking();
  });

  exit(0);
}

class QueryToken {
  /// Whether this token should exclude matching events (starts with '-').
  final bool isExclusion;

  /// The targeted field for this token (e.g., 'dur', 'name', 'widget').
  /// If null, matches against name, category, and all metadata.
  final String? field;

  /// The comparison operator, used for duration fields (e.g., '>', '<', '>=').
  final String? operator;

  /// The raw value to match or parse.
  final String value;

  /// If [value] is wrapped in slashes (e.g. `/foo/`), this holds the compiled RegExp.
  final RegExp? regex;

  /// If [field] is a duration field, this holds the parsed time in microseconds.
  final double? durationUs;

  /// Optimization: whether [value] contains any uppercase letters (Smart Case).
  final bool isSmartCase;

  static final RegExp _smartCaseDetector = RegExp(r'[A-Z]');

  /// Creates a [QueryToken] representing a single search requirement.
  ///
  /// Examples:
  /// * `QueryToken(isExclusion: false, field: 'name', operator: null, value: 'paint')`
  /// * `QueryToken(isExclusion: true, field: 'dur', operator: '>=', value: '16ms')`
  QueryToken({
    required this.isExclusion,
    required this.field,
    required this.operator,
    required this.value,
  }) : regex = _parseRegex(value),
       durationUs = _parseDuration(field, value),
       isSmartCase = value.contains(_smartCaseDetector);

  static RegExp? _parseRegex(String value) {
    if (value.length >= 2 && value.startsWith('/') && value.endsWith('/')) {
      try {
        return RegExp(value.substring(1, value.length - 1));
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static double? _parseDuration(String? field, String value) {
    if (field != 'dur' && field != 'duration') return null;
    final valLower = value.toLowerCase();
    if (valLower.endsWith('ms')) {
      final numStr = valLower.substring(0, valLower.length - 2);
      final val = double.tryParse(numStr);
      if (val != null) return val * 1000.0;
    } else if (valLower.endsWith('us')) {
      final numStr = valLower.substring(0, valLower.length - 2);
      final val = double.tryParse(numStr);
      if (val != null) return val;
    } else if (valLower.endsWith('s')) {
      final numStr = valLower.substring(0, valLower.length - 1);
      final val = double.tryParse(numStr);
      if (val != null) return val * 1000000.0;
    } else {
      return double.tryParse(valLower);
    }
    return null;
  }

  /// Evaluates whether the given [span] satisfies this query token.
  bool matches(TraceSpan span) {
    var match = false;

    if (field == 'dur' || field == 'duration') {
      if (durationUs != null) {
        final spanDur = (span.endUs - span.startUs).toDouble();
        match = switch (operator) {
          '>' => spanDur > durationUs!,
          '<' => spanDur < durationUs!,
          '>=' => spanDur >= durationUs!,
          '<=' => spanDur <= durationUs!,
          _ => spanDur == durationUs!,
        };
      }
    } else {
      final searchTargets = <String>[];

      switch (field) {
        case 'name':
          searchTargets.add(span.name);
        case 'cat':
        case 'category':
          searchTargets.add(span.category);
        case String f:
          if (span.args.containsKey(f)) {
            searchTargets.add(span.args[f]!);
          }
        case null:
          searchTargets.add(span.name);
          searchTargets.add(span.category);
          searchTargets.addAll(span.args.values);
      }

      for (final target in searchTargets) {
        if (regex != null) {
          if (regex!.hasMatch(target)) {
            match = true;
            break;
          }
        } else {
          final targetLower = target.toLowerCase();
          final valLower = value.toLowerCase();

          if (isSmartCase) {
            if (target.contains(value)) {
              match = true;
              break;
            }
          } else {
            if (targetLower.contains(valLower)) {
              match = true;
              break;
            }
          }
        }
      }
    }

    return isExclusion ? !match : match;
  }

  static List<QueryToken> parseQuery(String query) {
    final tokens = <QueryToken>[];
    final regex = RegExp(
      r'(-?)(?:([a-zA-Z0-9_]+):)?([<>=]+)?(?:\"([^\"]*)\"|([^\s]+))',
    );

    for (final match in regex.allMatches(query)) {
      final isExcl = match.group(1) == '-';
      final field = match.group(2);
      final op = match.group(3);
      final val = match.group(4) ?? match.group(5);
      if (val != null && val.isNotEmpty) {
        tokens.add(
          QueryToken(
            isExclusion: isExcl,
            field: field,
            operator: op,
            value: val,
          ),
        );
      }
    }
    return tokens;
  }
}

class SearchOverlay extends StatefulWidget {
  final List<TraceSpan> spans;
  final void Function(TraceSpan span) onMatchSelected;
  final void Function(String query) onQueryChanged;
  final VoidCallback onClose;
  final String initialQuery;

  const SearchOverlay({
    required this.spans,
    required this.onMatchSelected,
    required this.onQueryChanged,
    required this.onClose,
    this.initialQuery = '',
  });

  @override
  State<SearchOverlay> createState() => SearchOverlayState();
}

class SearchOverlayState extends State<SearchOverlay> {
  late TextEditingController searchController;
  List<TraceSpan> filteredSpans = [];
  int selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    searchController = TextEditingController(text: widget.initialQuery);
    searchController.addListener(_onSearchChanged);
    _onSearchChanged();
  }

  @override
  void dispose() {
    searchController.removeListener(_onSearchChanged);
    super.dispose();
  }

  void _onSearchChanged() {
    final query = searchController.text;
    widget.onQueryChanged(query);

    if (query.isEmpty) {
      setState(() {
        filteredSpans = [];
        selectedIndex = 0;
      });
      return;
    }

    final tokens = QueryToken.parseQuery(query);
    final results = <TraceSpan>[];

    for (final span in widget.spans) {
      var allMatch = true;
      for (final token in tokens) {
        if (!token.matches(span)) {
          allMatch = false;
          break;
        }
      }
      if (allMatch) {
        results.add(span);
      }
    }

    setState(() {
      filteredSpans = results;
      selectedIndex = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: (event) {
        if (event.type == evt.KeyType.escape) {
          PromptScope.of(context)?.done();
          widget.onClose();
          return true;
        }
        if (event.type == evt.KeyType.up) {
          if (filteredSpans.isNotEmpty) {
            setState(() {
              selectedIndex = (selectedIndex - 1).clamp(
                0,
                filteredSpans.length - 1,
              );
            });
          }
          return true;
        }
        if (event.type == evt.KeyType.down) {
          if (filteredSpans.isNotEmpty) {
            setState(() {
              selectedIndex = (selectedIndex + 1).clamp(
                0,
                filteredSpans.length - 1,
              );
            });
          }
          return true;
        }
        if (event.type == evt.KeyType.enter) {
          if (filteredSpans.isNotEmpty &&
              selectedIndex < filteredSpans.length) {
            widget.onMatchSelected(filteredSpans[selectedIndex]);
            return true;
          }
        }
        return false;
      },
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(
            topChar: '─',
            bottomChar: '─',
            leftChar: '│',
            rightChar: '│',
            topLeftChar: '╔',
            topRightChar: '╗',
            bottomLeftChar: '╚',
            bottomRightChar: '╝',
            style: Style(foreground: Colors.white),
          ),
          backgroundColor: Color(30, 30, 30),
        ),
        child: Column([
          Row([
            Text(
              ' Search [Esc or X to close]',
              style: const Style(foreground: Color(0, 255, 255)),
            ),
            Expanded(child: const SizedBox()),
            InkwellButton(onPressed: widget.onClose, text: '[X]'),
          ]),
          SizedBox(
            height: 1,
            child: Text(
              '─' * 50,
              style: const Style(foreground: Color(128, 128, 128)),
            ),
          ),
          Row([
            Text(' > ', style: const Style(foreground: Colors.yellow)),
            Expanded(
              child: TextField(
                controller: searchController,

                style: const Style(foreground: Colors.white),
              ),
            ),
          ]),
          SizedBox(
            height: 1,
            child: Text(
              '─' * 50,
              style: const Style(foreground: Color(128, 128, 128)),
            ),
          ),
          SizedBox(
            height: 1,
            child: Row([
              Text(
                ' Matches: ${filteredSpans.length} / ${searchController.text.isNotEmpty ? widget.spans.length : 0}',
                style: const Style(foreground: Colors.green),
              ),
            ]),
          ),
          Expanded(
            child: ListView(
              showScrollbar: true,
              selectedIndex: selectedIndex,
              onSelect: (index) {
                setState(() {
                  selectedIndex = index;
                });
                widget.onMatchSelected(filteredSpans[index]);
              },
              children: filteredSpans
                  .map((span) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: Text(
                        ' • ${span.name} (${(span.endUs - span.startUs) / 1000.0}ms)',
                      ),
                    );
                  })
                  .toList()
                  .cast<Widget>(),
            ),
          ),
        ]),
      ),
    );
  }
}
