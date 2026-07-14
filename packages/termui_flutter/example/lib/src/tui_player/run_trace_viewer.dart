import 'dart:math';
import 'package:termui/trace/trace_logger.dart';
import 'dart:async';
import 'dart:typed_data';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/termui.dart';
import 'package:termui/perf/fs_locator.dart';
import 'package:termui/trace/models/trace_models.dart';
import 'package:termui/trace/widgets/trace_viewer_app.dart';
import 'package:core_bus/core_bus.dart';
import '../events.dart';
import '../repository/repository.dart';
import 'trace_parser.dart';

Future<Map<String, dynamic>> parseTraceBytes(
  Uint8List bytes,
  String filename,
) async {
  final watch = Stopwatch()..start();
  void traceLog(String msg) {
    TraceLogger.info('trace', '$msg (elapsed: ${watch.elapsed})');
    watch.reset();
  }

  // 1. Offload parsing to Web or IO Isolate
  TraceLogger.info('trace', 'Delegating to platform trace parser...');
  final events = await parseTraceEvents(bytes, filename);
  traceLog('Platform Parse Completed');

  int baseTime = 0;
  if (events.isNotEmpty) {
    baseTime = events[0].timestamp;
    for (var i = 1; i < events.length; i++) {
      final ts = events[i].timestamp;
      if (ts < baseTime) {
        baseTime = ts;
      }
    }
    for (var i = 0; i < events.length; i++) {
      final ev = events[i];
      events[i] = TraceEvent(
        name: ev.name,
        phase: ev.phase,
        category: ev.category,
        timestamp: ev.timestamp - baseTime,
        dur: ev.dur,
        tid: ev.tid,
        args: ev.args,
      );
    }
  }
  await Future.delayed(Duration.zero);
  traceLog('TraceEvent normalization');

  final computedSpans = computeSpans(events);
  if (computedSpans.isEmpty) {
    throw StateError("Parsed 0 spans");
  }
  await Future.delayed(Duration.zero);
  traceLog('computed spans');

  computedSpans.sort((a, b) => a.startUs.compareTo(b.startUs));
  traceLog('computed spans sort');

  final mMinTs = computedSpans.map((s) => s.startUs).reduce(min);
  final mMaxTs = computedSpans.map((s) => s.endUs).reduce(max);

  int mMaxDuration = 0;
  for (final s in computedSpans) {
    final dur = s.endUs - s.startUs;
    if (dur > mMaxDuration) {
      mMaxDuration = dur;
    }
  }

  return {
    'spans': computedSpans,
    'minTs': mMinTs,
    'maxTs': mMaxTs,
    'baseTime': baseTime,
    'maxSpanDuration': mMaxDuration,
  };
}

class TraceViewerState {
  final List<TraceSpan>? spans;
  final int? minTs;
  final int? maxTs;
  final String? filename;

  const TraceViewerState({this.spans, this.minTs, this.maxTs, this.filename});
}

class TraceViewerViewModel {
  final SavedCastsRepository repository = SavedCastsRepository();
  List<TraceSpan>? _spans;
  int? _minTs;
  int? _maxTs;
  String? _filename;

  final _stateController = StreamController<TraceViewerState>.broadcast();
  Stream<TraceViewerState> get stateChanges => _stateController.stream;

  final _savedTracesController = StreamController<List<String>>.broadcast();
  Stream<List<String>> get savedTracesChanges => _savedTracesController.stream;

  TraceViewerViewModel({
    List<TraceSpan>? initialSpans,
    int? initialMinTs,
    int? initialMaxTs,
    String? initialFilename,
  }) : _spans = initialSpans,
       _minTs = initialMinTs,
       _maxTs = initialMaxTs,
       _filename = initialFilename;

  List<TraceSpan>? get spans => _spans;
  int? get minTs => _minTs;
  int? get maxTs => _maxTs;
  String? get filename => _filename;

  void updateTrace(
    List<TraceSpan> spans,
    int minTs,
    int maxTs,
    String filename,
  ) {
    _spans = spans;
    _minTs = minTs;
    _maxTs = maxTs;
    _filename = filename;
    _stateController.add(
      TraceViewerState(
        spans: _spans,
        minTs: _minTs,
        maxTs: _maxTs,
        filename: _filename,
      ),
    );
  }

  Future<void> loadTraceBytes(Uint8List bytes, String filename) async {
    final parsed = await parseTraceBytes(bytes, filename);
    updateTrace(
      parsed['spans'] as List<TraceSpan>,
      parsed['minTs'] as int,
      parsed['maxTs'] as int,
      filename,
    );
  }

  Future<void> refreshSavedTraces() async {
    final allKeys = await repository.listCasts();
    final traces = allKeys
        .where((k) => k.endsWith('.json') || k.endsWith('.json.gz'))
        .toList();
    _savedTracesController.add(traces);
  }

  Future<void> loadSavedTrace(String filename) async {
    final bytes = await repository.loadBytes(filename);
    if (bytes != null) {
      await loadTraceBytes(bytes, filename);
    }
  }

  Future<void> uploadTrace(String filename, Uint8List bytes) async {
    await repository.saveBytes(filename, bytes);
    await refreshSavedTraces();
    await loadTraceBytes(bytes, filename);
  }

  Future<void> deleteTrace(String filename) async {
    await repository.deleteCast(filename);
    await refreshSavedTraces();
    if (_filename == filename) {
      _spans = null;
      _minTs = null;
      _maxTs = null;
      _filename = null;
      _stateController.add(const TraceViewerState());
    }
  }

  void dispose() {
    _stateController.close();
    _savedTracesController.close();
  }
}

class TraceViewerTuiApp extends StatefulWidget {
  final TraceViewerViewModel viewModel;

  const TraceViewerTuiApp({super.key, required this.viewModel});

  @override
  State<TraceViewerTuiApp> createState() => _TraceViewerTuiAppState();
}

class _TraceViewerTuiAppState extends State<TraceViewerTuiApp> {
  List<TraceSpan>? _spans;
  int? _minTs;
  int? _maxTs;
  String? _filename;
  StreamSubscription? _stateSub;
  StreamSubscription? _uploadSub;
  StreamSubscription? _savedTracesSub;

  bool _showFileSelector = false;
  int _selectedFileIndex = 0;
  List<String> _savedTraces = [];
  final FocusNode _rootFocusNode = FocusNode(id: 'trace_viewer_root');

  @override
  void initState() {
    super.initState();
    _spans = widget.viewModel.spans;
    _minTs = widget.viewModel.minTs;
    _maxTs = widget.viewModel.maxTs;
    _filename = widget.viewModel.filename;

    _stateSub = widget.viewModel.stateChanges.listen((state) {
      if (mounted) {
        setState(() {
          _spans = state.spans;
          _minTs = state.minTs;
          _maxTs = state.maxTs;
          _filename = state.filename;
        });
      }
    });

    _savedTracesSub = widget.viewModel.savedTracesChanges.listen((traces) {
      if (mounted) {
        setState(() {
          _savedTraces = traces;
          if (_selectedFileIndex >= _savedTraces.length) {
            _selectedFileIndex = _savedTraces.isEmpty
                ? 0
                : _savedTraces.length - 1;
          }
        });
      }
    });

    _uploadSub = traceUploadedEvent.on(playerEventBus).listen((data) {
      try {
        widget.viewModel.uploadTrace(data.filename, data.bytes);
      } catch (e) {
        // ignore: avoid_print
        print(
          '[${DateTime.now().toIso8601String()}] [TraceViewerTuiApp] Error loading uploaded trace: $e',
        );
      }
    });

    widget.viewModel.refreshSavedTraces();
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _uploadSub?.cancel();
    _savedTracesSub?.cancel();
    _rootFocusNode.dispose();
    super.dispose();
  }

  bool _handleKeyEvent(term.KeyEvent event) {
    if (_showFileSelector) {
      if (event.type == term.KeyType.up) {
        if (_savedTraces.isNotEmpty) {
          setState(() {
            _selectedFileIndex =
                (_selectedFileIndex - 1 + _savedTraces.length) %
                _savedTraces.length;
          });
        }
        return true;
      } else if (event.type == term.KeyType.down) {
        if (_savedTraces.isNotEmpty) {
          setState(() {
            _selectedFileIndex = (_selectedFileIndex + 1) % _savedTraces.length;
          });
        }
        return true;
      } else if (event.type == term.KeyType.enter ||
          event.key == '\n' ||
          event.key == '\r') {
        if (_savedTraces.isNotEmpty &&
            _selectedFileIndex < _savedTraces.length) {
          widget.viewModel.loadSavedTrace(_savedTraces[_selectedFileIndex]);
          setState(() {
            _showFileSelector = false;
          });
        }
        return true;
      } else if (event.key == 'd' || event.key == 'D') {
        if (_savedTraces.isNotEmpty &&
            _selectedFileIndex < _savedTraces.length) {
          widget.viewModel.deleteTrace(_savedTraces[_selectedFileIndex]);
        }
        return true;
      } else if (event.key == 'u' || event.key == 'U') {
        uploadTraceRequestedEvent.post(playerEventBus, null);
        return true;
      } else if (event.key == 'escape' ||
          event.type == term.KeyType.escape ||
          event.key == 'o' ||
          event.key == 'O') {
        setState(() {
          _showFileSelector = false;
        });
        return true;
      }
      return false; // Let it bubble if unhandled, though usually we consume
    }

    if (event.key == 'o' || event.key == 'O') {
      setState(() {
        _showFileSelector = true;
      });
      _rootFocusNode.requestFocus();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    Widget mainContent;
    if (_spans == null) {
      mainContent = const Center(
        child: Text(
          'No trace loaded. Drop a .json or .json.gz trace file to view, or press [O] to open saved traces.',
          style: Style(foreground: Colors.white),
        ),
      );
    } else {
      mainContent = TraceViewerApp(
        key: ValueKey(_filename),
        spans: _spans!,
        minTs: _minTs!,
        maxTs: _maxTs!,
        filePath: null,
        fileSystem: getDefaultFileSystem(),
        onExport: (String filename, Uint8List bytes) {
          widget.viewModel.uploadTrace(filename, bytes);
        },
        onOpenFileRequested: () {
          setState(() {
            _showFileSelector = true;
          });
          _rootFocusNode.requestFocus();
        },
      );
    }

    // Reuse terminal sizing logic to center the dialog
    return Builder(
      builder: (context) {
        final element = context as Element;
        final width = element.size.width;
        final height = element.size.height;

        Widget? fileSelectorOverlay;
        if (_showFileSelector) {
          final dialogWidth = (width * 0.7).round().clamp(30, 80);
          final dialogHeight = (height * 0.6).round().clamp(10, 20);

          final listItems = <Widget>[];
          if (_savedTraces.isEmpty) {
            listItems.add(const Text('  No saved trace files available.'));
          } else {
            for (var i = 0; i < _savedTraces.length; i++) {
              final isSelected = i == _selectedFileIndex;
              listItems.add(
                InkwellButton(
                  text: '${isSelected ? "➔ " : "  "}${_savedTraces[i]}',
                  textStyle: isSelected
                      ? const Style(
                          foreground: CharmColors.pepper,
                          background: CharmColors.charple,
                          modifiers: Modifier.bold,
                        )
                      : const Style(foreground: CharmColors.iron),
                  onPressed: () {
                    setState(() {
                      _selectedFileIndex = i;
                      widget.viewModel.loadSavedTrace(_savedTraces[i]);
                      _showFileSelector = false;
                    });
                    _rootFocusNode.requestFocus();
                  },
                ),
              );
            }
          }

          final titleStr = ' SELECT TRACE FILE ';
          final helpStr = ' [Enter]: Load  [D]: Delete  [Esc]: Close ';

          // Manual centering
          int centerPad(String text) => (dialogWidth - 2 - text.length) ~/ 2;
          String paddedCenter(String text) {
            final pad = centerPad(text);
            if (pad <= 0) {
              return text.substring(0, (dialogWidth - 2).clamp(0, text.length));
            }
            return '${" " * pad}$text${" " * (dialogWidth - 2 - pad - text.length)}';
          }

          fileSelectorOverlay = Positioned.center(
            width: dialogWidth,
            height: dialogHeight,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                backgroundStyle: Style(
                  foreground: CharmColors.pepper,
                  background: CharmColors.soda,
                ),
              ),
              child: Column([
                SizedBox(
                  height: 1,
                  child: Text(
                    '┌${"─" * (dialogWidth - 2)}┐',
                    style: const Style(foreground: CharmColors.charple),
                  ),
                ),
                SizedBox(
                  height: 1,
                  child: Text(
                    '│${paddedCenter(titleStr)}│',
                    style: const Style(
                      foreground: CharmColors.pepper,
                      modifiers: Modifier.bold,
                    ),
                  ),
                ),
                SizedBox(
                  height: 1,
                  child: Text(
                    '├${"─" * (dialogWidth - 2)}┤',
                    style: const Style(foreground: CharmColors.charple),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: Column(listItems),
                  ),
                ),
                SizedBox(
                  height: 1,
                  child: Text(
                    '├${"─" * (dialogWidth - 2)}┤',
                    style: const Style(foreground: CharmColors.charple),
                  ),
                ),
                SizedBox(
                  height: 1,
                  child: Text(
                    '│${paddedCenter(helpStr)}│',
                    style: const Style(
                      foreground: CharmColors.julep,
                      modifiers: Modifier.bold,
                    ),
                  ),
                ),
                SizedBox(
                  height: 1,
                  child: Text(
                    '└${"─" * (dialogWidth - 2)}┘',
                    style: const Style(foreground: CharmColors.charple),
                  ),
                ),
              ]),
            ),
          );
        }

        return Focus(
          focusNode: _rootFocusNode,
          autofocus: true,
          onKeyEvent: _handleKeyEvent,
          child: Stack([
            Positioned(
              left: 0,
              top: 0,
              right: 0,
              bottom: 0,
              child: mainContent,
            ),
            ?fileSelectorOverlay,
          ]),
        );
      },
    );
  }
}

Future<void> runTraceViewerTui(
  term.Terminal terminal, {
  Uint8List? initialBytes,
  String? initialFilename,
  void Function(Buffer buffer)? onFrameRedrawn,
}) async {
  final sceneManager = SceneManager(
    terminal,
    renderingMode: RenderingMode.alternateScreen,
  )..enableMouseTracking = true;
  sceneManager.onFrameRedrawn = onFrameRedrawn;

  globalSceneManager = sceneManager;
  FocusManager.instance.setPrimaryFocus(null);

  final viewModel = TraceViewerViewModel();
  if (initialBytes != null && initialFilename != null) {
    try {
      await viewModel.uploadTrace(initialFilename, initialBytes);
    } catch (e) {
      // ignore
    }
  }

  late final PromptRunner<void> runner;
  runner = PromptRunner<void>(
    terminal: terminal,
    widget: TraceViewerTuiApp(viewModel: viewModel),
    alternateScreen: true,
    mode: ExecutionMode.managed,
    exitConditions: const {PromptExitTrigger.controlC: PromptExitAction.abort},
    onKeyEvent: (event) {
      TraceLogger.info(
        'TraceViewerTuiApp',
        'PromptRunner onKeyEvent: ${event.key} (type: ${event.type})',
      );
      if (event.type == term.KeyType.character &&
          event.key.toLowerCase() == 'q') {
        runner.abort();
        return true;
      }
      return false; // let it propagate
    },
    onFramePainted: (buf) {
      sceneManager.render();
    },
  );

  final mainLayer = SceneLayer(
    renderer: runner,
    sizing: LayerSizing.fullscreen,
    x: 0,
    y: 0,
    zIndex: 0,
  );
  sceneManager.layers.add(mainLayer);
  sceneManager.focusedLayer = mainLayer;

  try {
    await runner.run();
  } on PromptAbortedException catch (_) {
    // Aborted via Ctrl+C
  } finally {
    sceneManager.dispose();
    viewModel.dispose();
  }
}
