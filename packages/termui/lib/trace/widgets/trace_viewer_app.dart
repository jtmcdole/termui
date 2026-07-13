import 'dart:typed_data';
import "package:file/file.dart";
import "package:file/local.dart";
import "package:termui/termui_trace.dart";
import "package:termui/termui.dart";
// ignore_for_file: public_member_api_docs
import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'dart:math';
import 'package:termui/ui/event.dart' as evt;
import 'package:termui/trace/trace_logger.dart';

late SceneManager globalSceneManager;

class TraceViewerApp extends StatefulWidget {
  final String? filePath;
  final List<TraceSpan>? spans;
  final int? minTs;
  final int? maxTs;
  final FileSystem fileSystem;
  final void Function(String filename, Uint8List bytes)? onExport;
  final VoidCallback? onOpenFileRequested;

  const TraceViewerApp({
    super.key,
    this.filePath,
    this.spans,
    this.minTs,
    this.maxTs,
    this.fileSystem = const LocalFileSystem(),
    this.onExport,
    this.onOpenFileRequested,
  });

  @override
  State<TraceViewerApp> createState() => _TraceViewerAppState();
}

class _TraceViewState {
  final List<TraceSpan> spans;
  final int minTs;
  final int maxTs;
  final double offsetX;
  final double zoomLevel;

  _TraceViewState({
    required this.spans,
    required this.minTs,
    required this.maxTs,
    required this.offsetX,
    required this.zoomLevel,
  });
}

enum TimeDisplayMode { formatted, rawRelative, rawAbsolute }

class _TraceViewerAppState extends State<TraceViewerApp>
    implements evt.KeyEventHandler, evt.MouseEventHandler, evt.Focusable {
  List<TraceSpan>? spans;
  int? minTs;
  int? maxTs;
  int? baseTime;
  int maxSpanDuration = 0;
  late double offsetX;
  late double zoomLevel;
  int offsetY = 0;
  TraceSpan? hoveredSpan;
  TimeDisplayMode timeDisplayMode = TimeDisplayMode.formatted;
  int? selectionStartUs;
  int? selectionEndUs;
  String? exportMessage;

  final List<_TraceViewState> _undoStack = [];
  final List<_TraceViewState> _redoStack = [];

  void _cropSelection() {
    if (selectionStartUs == null ||
        selectionEndUs == null ||
        spans == null ||
        minTs == null ||
        maxTs == null) {
      return;
    }
    final start = selectionStartUs!;
    final end = selectionEndUs!;

    _undoStack.add(
      _TraceViewState(
        spans: List.of(spans!),
        minTs: minTs!,
        maxTs: maxTs!,
        offsetX: offsetX,
        zoomLevel: zoomLevel,
      ),
    );
    if (_undoStack.length > 50) _undoStack.removeAt(0);
    _redoStack.clear();

    final newSpans = spans!
        .where((s) => s.startUs <= end && s.endUs >= start)
        .toList();
    if (newSpans.isEmpty) return; // Don't crop if it results in an empty trace

    int newMinTs = newSpans.map((s) => s.startUs).reduce(min);
    int newMaxTs = newSpans.map((s) => s.endUs).reduce(max);

    setState(() {
      spans = newSpans;
      minTs = newMinTs;
      maxTs = newMaxTs;
      selectionStartUs = null;
      selectionEndUs = null;
      exportMessage = 'Cropped to ${newSpans.length} events.';
    });
  }

  void _undo() {
    if (_undoStack.isNotEmpty &&
        spans != null &&
        minTs != null &&
        maxTs != null) {
      _redoStack.add(
        _TraceViewState(
          spans: List.of(spans!),
          minTs: minTs!,
          maxTs: maxTs!,
          offsetX: offsetX,
          zoomLevel: zoomLevel,
        ),
      );
      final state = _undoStack.removeLast();
      setState(() {
        spans = state.spans;
        minTs = state.minTs;
        maxTs = state.maxTs;
        offsetX = state.offsetX;
        zoomLevel = state.zoomLevel;
        selectionStartUs = null;
        selectionEndUs = null;
        exportMessage = 'Undo crop';
      });
    }
  }

  void _redo() {
    if (_redoStack.isNotEmpty &&
        spans != null &&
        minTs != null &&
        maxTs != null) {
      _undoStack.add(
        _TraceViewState(
          spans: List.of(spans!),
          minTs: minTs!,
          maxTs: maxTs!,
          offsetX: offsetX,
          zoomLevel: zoomLevel,
        ),
      );
      final state = _redoStack.removeLast();
      setState(() {
        spans = state.spans;
        minTs = state.minTs;
        maxTs = state.maxTs;
        offsetX = state.offsetX;
        zoomLevel = state.zoomLevel;
        selectionStartUs = null;
        selectionEndUs = null;
        exportMessage = 'Redo crop';
      });
    }
  }

  SceneLayer? _saveLayer;

  void _spawnSaveModal() {
    if (_saveLayer != null) return;
    if (spans == null || minTs == null || maxTs == null) {
      return;
    }

    final start = selectionStartUs ?? minTs!;
    final end = selectionEndUs ?? maxTs!;
    final overlappingSpans = spans!
        .where((s) => s.startUs <= end && s.endUs >= start)
        .toList();

    final w = 50;
    final h = 10;
    final term = globalSceneManager.terminal;
    final x = (term.backend.size.x - w) ~/ 2;
    final y = (term.backend.size.y - h) ~/ 2;

    print(
      '[${DateTime.now().toIso8601String()}] [TraceViewerApp] Spawning layer with size: ${term.backend.size}, w=$w, h=$h, x=$x, y=$y',
    );

    late PromptRunner<void> runner;

    void handleClose() {
      if (_saveLayer != null) {
        globalSceneManager.layers.remove(_saveLayer!);
        globalSceneManager.focusedLayer = globalSceneManager.layers.first;
        _saveLayer = null;
        // Since we closed a focus-stealing layer, we must clear the primary focus
        // so that the TraceViewerApp (which relies on `focused == true` without a node)
        // can receive fallback key events again.
        FocusManager.instance.setPrimaryFocus(null);
        globalSceneManager.render();
      }
    }

    final originalName =
        widget.filePath?.split(Platform.pathSeparator).last ?? 'trace.json';
    final defaultExportName =
        '${originalName.replaceAll('.json', '')}_cropped.json';
    final textController = TextEditingController(text: defaultExportName);

    final overlay = Focus(
      onKeyEvent: (event) {
        if (event.type == evt.KeyType.escape) {
          handleClose();
          runner.dispose();
          return true;
        }
        if (event.baseKey == TermKey.enter) {
          _exportSelection(textController.text, overlappingSpans);
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
          SizedBox(
            height: 1,
            child: Row([
              Expanded(
                child: Text(
                  ' Export Cropped Trace ',
                  style: const Style(foreground: Color(0, 255, 255)),
                ),
              ),
              SizedBox(
                width: 5,
                child: InkwellButton(
                  width: 5,
                  onPressed: () {
                    handleClose();
                    runner.dispose();
                  },
                  text: '[x]',
                  textStyle: const Style(foreground: Colors.white),
                ),
              ),
            ]),
          ),
          SizedBox(
            height: 1,
            child: Text(
              '─' * 50,
              style: const Style(foreground: Color(128, 128, 128)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 1, right: 1, top: 1),
            child: Text(' File:', style: const Style(foreground: Colors.white)),
          ),
          Padding(
            padding: const EdgeInsets.only(
              left: 4,
              right: 4,
              top: 0,
              bottom: 1,
            ),
            child: SizedBox(
              height: 1,
              child: TextField(
                controller: textController,
                focusNode: FocusNode(id: 'save_input')..requestFocus(),
                style: const Style(
                  foreground: Colors.black,
                  background: Colors.white,
                ),
              ),
            ),
          ),
        ]),
      ),
    );

    runner = PromptRunner<void>(
      widget: overlay,
      terminal: globalSceneManager.terminal,
      alternateScreen: false,
      mode: ExecutionMode.managed,
      onFramePainted: (_) => globalSceneManager.render(),
    );

    _saveLayer = SceneLayer(
      renderer: runner,
      sizing: LayerSizing.fixed,
      x: x,
      y: y,
      width: w,
      height: h,
      zIndex: 110,
    );

    globalSceneManager.layers.add(_saveLayer!);
    globalSceneManager.focusedLayer = _saveLayer;

    // We don't await runner.run() because we want to return immediately
    // so the main app continues rendering.
    runner.run().catchError((_) {
      // Ignore unhandled prompt aborts (e.g. from Ctrl+C)
    });
  }

  // Memoized search overlay state
  int _searchWindowW = 40;
  int _searchWindowH = 10;
  String _searchQuery = '';
  HitGrid? _latestHitGrid;

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
        FocusManager.instance.setPrimaryFocus(null);
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
          SizedBox(
            height: 1,
            child: Row([
              Text(
                ' Help / Shortcuts [Esc to close]',
                style: const Style(foreground: Color(0, 255, 255)),
              ),
            ]),
          ),
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
                  't           : Cycle Time Format',
                  'Mouse Drag  : Pan Timeline',
                  'Ctrl+Drag   : Box Select Zoom',
                  'Scroll Wheel: Zoom in/out at mouse',
                  'Ctrl+S/Alt+S: Save Cropped Trace',
                ],
                onSelect: (index) {
                  if (index == 11) {
                    handleClose();
                    runner.dispose();
                    _spawnSaveModal();
                  }
                },
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

    runner.run().catchError((_) {
      // Ignore unhandled prompt aborts (e.g. from Ctrl+C)
    });
  }

  SceneLayer? _searchLayer;

  void _spawnSearchOverlay() {
    if (_searchLayer != null) return;

    final term = globalSceneManager.terminal;
    final w = max(20, min(_searchWindowW, term.backend.size.x - 4));
    final h = max(10, min(_searchWindowH, term.backend.size.y - 4));
    final x = (term.backend.size.x - w) ~/ 2;
    final y = (term.backend.size.y - h) ~/ 2;

    late PromptRunner<void> runner;

    void handleClose() {
      if (_searchLayer != null) {
        _searchWindowW = _searchLayer!.width ?? _searchWindowW;
        _searchWindowH = _searchLayer!.height ?? _searchWindowH;
        globalSceneManager.layers.remove(_searchLayer!);
        globalSceneManager.focusedLayer = globalSceneManager.layers.first;
        _searchLayer = null;
        FocusManager.instance.setPrimaryFocus(null);
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

    runner.resize(w, h);
    runner
        .run()
        .then((_) {
          TraceLogger.info('TraceViewerApp', 'runner.run() completed normally');
        })
        .catchError((e, s) {
          TraceLogger.error('TraceViewerApp', 'runner.run() threw error', e, s);
        });
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
      maxSpanDuration = 1000000000; // fallback if not loaded from json
      final duration = maxTs! - minTs!;
      zoomLevel = duration > 0 ? duration / 80.0 : 1.0;
      offsetX = minTs!.toDouble();
      isLoading = false;
    }
  }

  Future<void> _loadTraceData() async {
    widget.fileSystem
        .file('debug.log')
        .writeAsStringSync(
          'Started loading trace data\n',
          mode: FileMode.append,
        );
    try {
      final result = await parseTraceFile(widget.filePath!);
      widget.fileSystem
          .file('debug.log')
          .writeAsStringSync(
            'Finished parseTraceFile\n',
            mode: FileMode.append,
          );

      if (mounted) {
        if (result != null) {
          setState(() {
            spans = result['spans'] as List<TraceSpan>;
            minTs = result['minTs'] as int;
            maxTs = result['maxTs'] as int;
            baseTime = result['baseTime'] as int;
            maxSpanDuration = result['maxSpanDuration'] as int? ?? 1000000000;
            final duration = maxTs! - minTs!;
            zoomLevel = duration > 0 ? duration / 80.0 : 1.0;
            offsetX = minTs!.toDouble();
            isLoading = false;
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

  Timer? _exportMessageTimer;

  void _showExportMessage(String message) {
    setState(() {
      exportMessage = message;
    });
    _exportMessageTimer?.cancel();
    _exportMessageTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          exportMessage = null;
        });
        globalSceneManager.render();
      }
    });
  }

  void _exportSelection(String filename, List<TraceSpan> overlappingSpans) {
    final exportedEvents = <Map<String, dynamic>>[];
    for (final span in overlappingSpans) {
      // Emit Begin Event
      exportedEvents.add({
        'name': span.name,
        'ph': 'B',
        'ts': span.startUs,
        'pid': 1,
        'tid': 1,
        'args': span.args,
      });
      // Emit End Event
      exportedEvents.add({
        'name': span.name,
        'ph': 'E',
        'ts': span.endUs,
        'pid': 1,
        'tid': 1,
      });
    }

    final jsonString = jsonEncode(exportedEvents);
    final file = widget.fileSystem.file(filename);
    file.writeAsStringSync(jsonString);

    if (widget.onExport != null) {
      widget.onExport!(filename, Uint8List.fromList(utf8.encode(jsonString)));
    }

    _showExportMessage(
      'Exported ${exportedEvents.length ~/ 2} spans to $filename',
    );
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

    if (keyLower == 't') {
      setState(() {
        timeDisplayMode =
            TimeDisplayMode.values[(timeDisplayMode.index + 1) %
                TimeDisplayMode.values.length];
      });
      return true;
    }

    if (event.baseKey == TermKey.openSquareBracket) {
      if (hoveredSpan != null) {
        setState(() {
          selectionStartUs = hoveredSpan!.startUs;
          if (selectionEndUs != null && selectionStartUs! > selectionEndUs!) {
            final temp = selectionStartUs;
            selectionStartUs = selectionEndUs;
            selectionEndUs = temp;
          }
          exportMessage = null;
        });
      }
      return true;
    }

    if (event.baseKey == TermKey.closingSquareBracket) {
      if (hoveredSpan != null) {
        setState(() {
          selectionEndUs = hoveredSpan!.endUs;
          if (selectionStartUs != null && selectionStartUs! > selectionEndUs!) {
            final temp = selectionStartUs;
            selectionStartUs = selectionEndUs;
            selectionEndUs = temp;
          }
          exportMessage = null;
        });
      }
      return true;
    }

    final hasCtrlOrMeta =
        event.modifiers.contains(evt.Modifier.control) ||
        event.modifiers.contains(evt.Modifier.meta);
    final hasAlt = event.modifiers.contains(evt.Modifier.alt);

    if (keyLower == 'x' && hasCtrlOrMeta) {
      _cropSelection();
      return true;
    }

    if (keyLower == 's' && (hasCtrlOrMeta || hasAlt)) {
      _spawnSaveModal();
      return true;
    }

    if (keyLower == 'z' && (hasCtrlOrMeta || hasAlt)) {
      _undo();
      return true;
    }

    if (keyLower == 'y' && (hasCtrlOrMeta || hasAlt)) {
      _redo();
      return true;
    }

    if (type == evt.KeyType.escape) {
      if (selectionStartUs != null || selectionEndUs != null) {
        setState(() {
          selectionStartUs = null;
          selectionEndUs = null;
          exportMessage = null;
        });
        return true;
      }
    }

    if (keyLower == 'z' && !hasCtrlOrMeta && !hasAlt) {
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

    if (keyLower == 'o') {
      if (widget.onOpenFileRequested != null) {
        widget.onOpenFileRequested!();
        return true;
      }
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
    TraceSpan? hit;

    if (_latestHitGrid != null) {
      final col =
          localX -
          2; // TimelineCanvas interior starts at X=2 (startX=0, then +1 for border)
      final visualY = localY - 3;
      hit = _latestHitGrid!.getHit(col, visualY);
    }

    setState(() {
      hoveredSpan = hit;
    });
  }

  Widget buildHeader(String modeText, Style modeStyle) {
    final borderStyle = const Style(foreground: Color(120, 120, 120));
    return SizedBox(
      height: 1,
      child: Row(
        [
          Text('┌─ [ termui trace viewer ] ─', style: borderStyle),
          Row([
            Text('─ [ Mode: ', style: borderStyle),
            Text(' $modeText ', style: modeStyle),
            Text(' ] ─┐', style: borderStyle),
          ]),
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
            final (col, align) = switch (i) {
              0 => (0, TextAlign.left),
              _ when i == tickCount - 1 => (segmentsWidth, TextAlign.right),
              _ => (
                ((i + 0.5) * segmentsWidth / tickCount).round(),
                TextAlign.center,
              ),
            };

            final tickTimeMs = (offsetX + col * zoomLevel) / 1000.0;
            final label = switch (timeDisplayMode) {
              TimeDisplayMode.formatted => formatDuration(tickTimeMs),
              TimeDisplayMode.rawRelative =>
                (tickTimeMs * 1000).round().toString(),
              TimeDisplayMode.rawAbsolute =>
                ((tickTimeMs * 1000).round() + (baseTime ?? 0)).toString(),
            };

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

    final modeText = isCaliperMode
        ? 'Caliper'
        : isBoxSelectMode
        ? 'Box Zoom'
        : 'Pan';

    final modeStyle = isCaliperMode
        ? const Style(foreground: Colors.black, background: Colors.yellow)
        : isBoxSelectMode
        ? const Style(foreground: Colors.white, background: Colors.blue)
        : const Style(foreground: Colors.white, background: Color(60, 60, 60));

    return Column([
      buildHeader(modeText, modeStyle),
      buildRuler(),
      buildSeparator('Main Isolate'),
      Expanded(
        child: TimelineCanvas(
          spans: spans!,
          offsetX: offsetX,
          offsetY: offsetY,
          zoomLevel: zoomLevel,
          maxSpanDuration: maxSpanDuration,
          measureStartMs: measureStartMs,
          measureEndMs: measureEndMs,
          selectionStartUs: selectionStartUs,
          selectionEndUs: selectionEndUs,
          onHitGridUpdated: (grid) {
            _latestHitGrid = grid;
          },
        ),
      ),
      buildInspectorPanel(
        exportMessage,
        hoveredSpan,
        timeDisplayMode,
        baseTime,
      ),
    ], crossAxisAlignment: CrossAxisAlignment.stretch);
  }
}

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
  bool handleKeyEvent(evt.KeyEvent event) {
    return false;
  }

  @override
  bool handleMouseEvent(evt.MouseEvent event) => false;

  void render() {}

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
          _buffer!.setAttributes(
            x,
            y,
            char: char,
            fg: style.foreground?.argb ?? 0,
            bg: style.background?.argb ?? 0,
            modifiers: style.modifiers,
          );
        } else {
          _buffer!.setAttributes(x, y, char: ' ', fg: 0, bg: 0, modifiers: 0);
        }
      }
    }

    // Use writeString to handle double-width character properly
    _buffer!.writeString(width ~/ 2, height ~/ 2, '🔎', style);
  }

  @override
  void dispose() {}
}
