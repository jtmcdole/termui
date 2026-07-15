import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:termui/terminal/terminal.dart' as termui;
import 'package:termui/ui/buffer.dart';
import 'package:termui_flutter/termui_flutter.dart';
import 'widget_book.dart';

import 'package:termui_shared_examples/glass_compositing/glass_compositing.dart';
import 'package:termui_shared_examples/glass_compositing/pty_glass_runner.dart';
import 'package:termui_shared_examples/widget_book/events.dart';
import 'package:core_bus/core_bus.dart';
import 'url_helper.dart';
import 'package:file_selector/file_selector.dart';
import 'src/tui_player/run_tui_player.dart';
import 'src/tui_player/run_trace_viewer.dart';
import 'src/tui_player/file_upload_zone.dart';
import 'src/events.dart';
import 'src/recording/recording_service.dart';
import 'src/recording/recording_view_model.dart';
import 'src/repository/repository.dart';
import 'package:termui/perf/tracer.dart';

enum TuiDemo {
  widgetBook('Widget Book', 'widgetbook'),
  glassCompositing('Glass Compositing', 'glass'),
  ptyGlassCompositing('PTY Glass Compositing', 'pty'),
  asciicastPlayer('Asciicast Player', 'player'),
  traceViewer('Trace Viewer', 'trace');

  final String label;
  final String queryName;
  const TuiDemo(this.label, this.queryName);
}

final watch = Stopwatch()..start();

void _log(String message) {
  if (kIsWeb || Platform.environment.containsKey('FLUTTER_TEST')) {
    // ignore: avoid_print
    print('${watch.elapsed} [TUI] $message');
  }
  if (kIsWeb) return;
  try {
    final file = File('tui_diagnostics.log');
    file
        .writeAsString(
          '[${DateTime.now().toIso8601String()}] $message\n',
          mode: FileMode.append,
        )
        .then((_) {}, onError: (_) {});
  } catch (_) {}
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Tracer.initialize();
  if (!kIsWeb) {
    try {
      final file = File('tui_diagnostics.log');
      if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (_) {}
  } else {
    try {
      final fontLoader = FontLoader('Cascadia Mono');
      fontLoader.addFont(rootBundle.load('fonts/CascadiaMonoPL.ttf'));
      await fontLoader.load();
      final fontLoader2 = FontLoader('MesloLGS NF');
      fontLoader2.addFont(rootBundle.load('fonts/MesloLGS_NF_Regular.ttf'));
      await fontLoader2.load();

      final brailleLoader = FontLoader('Noto Sans Braille');
      brailleLoader.addFont(
        rootBundle.load('fonts/NotoSansBraille-Regular.ttf'),
      );
      await brailleLoader.load();
    } catch (e) {
      debugPrint('FONT LOADER ERROR: $e');
    }
  }
  _log('main.dart: main() started');
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  final Map<String, String>? initialQuery;
  const MainApp({super.key, this.initialQuery});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TermUI Direct TuiView Demo',
      theme: ThemeData.dark(),
      home: TermUIWebHome(initialQuery: initialQuery),
      debugShowCheckedModeBanner: false,
    );
  }
}

class TermUIWebHome extends StatefulWidget {
  final Map<String, String>? initialQuery;
  const TermUIWebHome({super.key, this.initialQuery});

  @override
  State<TermUIWebHome> createState() => TermUIWebHomeState();
}

class TermUIWebHomeState extends State<TermUIWebHome> {
  late final FlutterTerminal _terminal;

  TuiDemo currentDemo = TuiDemo.asciicastPlayer;
  String? initialPage;
  StreamSubscription? _pageChangedSub;
  StreamSubscription? _urlChangesSub;
  StreamSubscription? _uploadRequestedSub;
  StreamSubscription? _uploadTraceRequestedSub;
  bool _switching = false;
  bool _tuiRunning = false;
  void Function(Buffer)? _onDrawFrame;

  Uint8List? _initialTraceBytes;
  String? _initialTraceFilename;

  late final RecordingViewModel _recordingViewModel;

  bool _handleGlobalKey(KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.f7) {
        _recordingViewModel.toggleTrace();
        return true;
      }
      if (event.logicalKey == LogicalKeyboardKey.f8) {
        _recordingViewModel.toggleAsciicast(_terminal);
        return true;
      }
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _recordingViewModel = RecordingViewModel(
      RecordingService(SavedCastsRepository()),
      onLog: _log,
    );
    _recordingViewModel.addListener(() {
      if (mounted) setState(() {});
    });
    HardwareKeyboard.instance.addHandler(_handleGlobalKey);
    _log('main.dart: initState() started');
    _terminal = FlutterTerminal();

    final query = widget.initialQuery ?? getUrlParams();
    currentDemo = switch (query['demo']) {
      'widgetbook' => TuiDemo.widgetBook,
      'glass' => TuiDemo.glassCompositing,
      'pty' => TuiDemo.ptyGlassCompositing,
      'player' => TuiDemo.asciicastPlayer,
      'trace' => TuiDemo.traceViewer,
      _ => TuiDemo.glassCompositing,
    };
    initialPage = query['page'];

    _pageChangedSub = pageChangedEvent.on(widgetBookEventBus).listen((
      pageName,
    ) {
      initialPage = pageName;
      updateUrlParams(demo: currentDemo.queryName, page: pageName);
    });

    _urlChangesSub = listenToUrlChanges((newQuery) {
      final targetDemo = switch (newQuery['demo']) {
        'widgetbook' => TuiDemo.widgetBook,
        'glass' => TuiDemo.glassCompositing,
        'pty' => TuiDemo.ptyGlassCompositing,
        'player' => TuiDemo.asciicastPlayer,
        'trace' => TuiDemo.traceViewer,
        _ => null,
      };

      if (targetDemo != null && targetDemo != currentDemo) {
        _switchDemo(targetDemo);
      }

      final pageParam = newQuery['page'];
      if (pageParam != initialPage) {
        initialPage = pageParam;
        if (pageParam != null) {
          pageSelectedEvent.post(widgetBookEventBus, pageParam);
        }
      }
    });

    _uploadRequestedSub = uploadCastRequestedEvent.on(playerEventBus).listen((
      _,
    ) async {
      try {
        const typeGroup = XTypeGroup(
          label: 'Asciicasts',
          extensions: ['cast', 'gz'],
        );
        final file = await openFile(acceptedTypeGroups: [typeGroup]);
        if (file != null) {
          final bytes = await file.readAsBytes();
          castUploadedEvent.post(
            playerEventBus,
            UploadedCastData(file.name, bytes),
          );
        }
      } catch (e) {
        _log('main.dart: Error during file selection: $e');
      }
    });

    _uploadTraceRequestedSub = uploadTraceRequestedEvent
        .on(playerEventBus)
        .listen((_) async {
          try {
            const typeGroup = XTypeGroup(
              label: 'Traces',
              extensions: ['json', 'gz'],
            );
            final file = await openFile(acceptedTypeGroups: [typeGroup]);
            if (file != null) {
              final bytes = await file.readAsBytes();
              traceUploadedEvent.post(
                playerEventBus,
                UploadedTraceData(file.name, bytes),
              );
            }
          } catch (e) {
            _log('main.dart: Error during trace file selection: $e');
          }
        });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalKey);
    _pageChangedSub?.cancel();
    _urlChangesSub?.cancel();
    _uploadRequestedSub?.cancel();
    _uploadTraceRequestedSub?.cancel();
    if (_tuiRunning) {
      _terminal.injectEvent(
        const termui.KeyEvent(
          'c',
          termui.KeyType.character,
          modifiers: {termui.Modifier.control},
        ),
      );
    }
    _terminal.dispose();
    super.dispose();
  }

  void _runTUI(void Function(Buffer) onDrawFrame) async {
    _log(
      'main.dart: _runTUI() started, _tuiRunning: $_tuiRunning, State: $hashCode',
    );
    _onDrawFrame = onDrawFrame;
    if (_tuiRunning) return;
    _tuiRunning = true;

    try {
      while (mounted) {
        _log(
          'main.dart: Loop iteration, demo: $currentDemo, State: $hashCode, mounted: $mounted',
        );
        if (currentDemo == TuiDemo.widgetBook) {
          _log('main.dart: Running WidgetBook');
          await runWidgetBook(
            _terminal,
            onFrameRedrawn: onDrawFrame,
            initialPage: initialPage,
          );
          _log(
            'main.dart: WidgetBook returned, State: $hashCode, mounted: $mounted',
          );
        } else if (currentDemo == TuiDemo.glassCompositing) {
          _log('main.dart: Running Glass Compositing');
          await runGlassCompositingShared(
            _terminal,
            isInline: false,
            onFrameRedrawn: onDrawFrame,
          );
          _log('main.dart: Glass Compositing returned');
        } else if (currentDemo == TuiDemo.ptyGlassCompositing) {
          _log('main.dart: Running PTY Glass Compositing');
          await runPtyGlassDemo(_terminal, onFrameRedrawn: onDrawFrame);
          _log('main.dart: PTY Glass Compositing returned');
        } else if (currentDemo == TuiDemo.asciicastPlayer) {
          _log('main.dart: Running TUI Asciicast Player');
          await runAsciicastPlayerTui(_terminal, onFrameRedrawn: onDrawFrame);
          _log('main.dart: TUI Asciicast Player returned');
        } else if (currentDemo == TuiDemo.traceViewer) {
          _log('main.dart: Running TUI Trace Viewer');
          await runTraceViewerTui(
            _terminal,
            initialBytes: _initialTraceBytes,
            initialFilename: _initialTraceFilename,
            onFrameRedrawn: onDrawFrame,
          );
          _log('main.dart: TUI Trace Viewer returned');
          _initialTraceBytes = null;
          _initialTraceFilename = null;
        }

        if (!mounted) {
          _log('main.dart: Not mounted, exiting loop');
          break;
        }
        if (!_switching) {
          _log('main.dart: Exited loop without switching, showing dialog');
          _showSwitchDemoDialog(title: 'TUI Application Exited');
          break;
        } else {
          _log('main.dart: Exited loop due to switching');
          _switching = false;
        }
      }
    } catch (e, stack) {
      _log('main.dart: ERROR in _runTUI loop: $e\n$stack');
      rethrow;
    } finally {
      _tuiRunning = false;
      _log('main.dart: _runTUI finished');
    }
  }

  void _switchDemo(TuiDemo target) {
    _log('main.dart: Switch demo requested to: ${target.label}');
    if (currentDemo == target && _tuiRunning) return;

    currentDemo = target;
    initialPage = null;
    setState(() {});

    updateUrlParams(demo: target.queryName, page: null);

    if (_tuiRunning) {
      _switching = true;
      // Inject Ctrl+C to terminate current loop
      _terminal.injectEvent(
        const termui.KeyEvent(
          'c',
          termui.KeyType.character,
          modifiers: {termui.Modifier.control},
        ),
      );
    } else if (_onDrawFrame != null) {
      _runTUI(_onDrawFrame!);
    }
  }

  void _showSwitchDemoDialog({String title = 'Switch TUI Application'}) {
    showDialog(
      context: context,
      barrierDismissible: _tuiRunning,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: const Text(
          'Select which TUI application to run in the terminal emulator:',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _switchDemo(TuiDemo.asciicastPlayer);
            },
            child: const Text('Asciicast Player'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _switchDemo(TuiDemo.traceViewer);
            },
            child: const Text('Trace Viewer'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _switchDemo(TuiDemo.widgetBook);
            },
            child: const Text('Widget Book'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _switchDemo(TuiDemo.glassCompositing);
            },
            child: const Text('Glass Compositing'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _switchDemo(TuiDemo.ptyGlassCompositing);
            },
            child: const Text('PTY Glass Compositing'),
          ),
        ],
      ),
    );
  }

  double _baseFontSize = 13.0;
  double _currentFontSize = 13.0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: FileUploadZone(
              targetPath: currentDemo == TuiDemo.traceViewer
                  ? 'Trace Viewer'
                  : 'Asciicast Player',
              onFilesSelected: (files) async {
                if (files.isNotEmpty) {
                  final firstFile = files.values.first;
                  try {
                    final bytes = await firstFile.readAsBytes();
                    _log(
                      'main.dart: Processing dropped file: ${firstFile.name} (${bytes.length} bytes)',
                    );
                    if (firstFile.name.endsWith('.json') ||
                        firstFile.name.endsWith('.json.gz')) {
                      _initialTraceBytes = bytes;
                      _initialTraceFilename = firstFile.name;

                      if (currentDemo != TuiDemo.traceViewer) {
                        _switchDemo(TuiDemo.traceViewer);
                      } else {
                        await Future.delayed(const Duration(milliseconds: 150));
                        traceUploadedEvent.post(
                          playerEventBus,
                          UploadedTraceData(firstFile.name, bytes),
                        );
                      }
                    } else {
                      if (currentDemo != TuiDemo.asciicastPlayer) {
                        _switchDemo(TuiDemo.asciicastPlayer);
                      }
                      await Future.delayed(const Duration(milliseconds: 150));
                      castUploadedEvent.post(
                        playerEventBus,
                        UploadedCastData(firstFile.name, bytes),
                      );
                    }
                  } catch (e) {
                    _log('main.dart: Drag-and-drop error: $e');
                  }
                }
              },
              child: GestureDetector(
                onScaleStart: (details) {
                  _baseFontSize = _currentFontSize;
                },
                onScaleUpdate: (details) {
                  setState(() {
                    _currentFontSize = (_baseFontSize * details.scale).clamp(
                      4.0,
                      72.0,
                    );
                    _terminal.setFontSize(_currentFontSize);
                  });
                },
                child: Terminal(
                  terminal: _terminal,
                  fontSize: _currentFontSize,
                  fontFamily: 'MesloLGS NF',
                  fontFamilyFallback: const [
                    'Noto Color Emoji',
                    'Noto Sans Braille',
                  ],
                  onRun: (terminal, drawFrame) async {
                    void wrappedDrawFrame(Buffer buf) {
                      if (_recordingViewModel.asciicastRecorder != null) {
                        _recordingViewModel.asciicastRecorder!.recordFrame(buf);
                      }
                      drawFrame(buf);
                    }

                    _runTUI(wrappedDrawFrame);
                  },
                ),
              ),
            ),
          ),
          Positioned(
            top: 16.0,
            right: 16.0,
            child: Material(
              color: Colors.transparent,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(150),
                  borderRadius: BorderRadius.circular(8.0),
                ),
                child: IconButton(
                  icon: const Icon(Icons.swap_horiz, color: Colors.white70),
                  tooltip: 'Switch TUI App',
                  onPressed: () => _showSwitchDemoDialog(),
                ),
              ),
            ),
          ),
          if (_recordingViewModel.isRecordingTrace ||
              _recordingViewModel.isRecordingAsciicast)
            Positioned(
              top: 16.0,
              left: 16.0,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12.0,
                    vertical: 8.0,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withAlpha(150),
                    borderRadius: BorderRadius.circular(8.0),
                    border: Border.all(color: Colors.redAccent.withAlpha(100)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: const BoxDecoration(
                          color: Colors.redAccent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8.0),
                      Text(
                        _recordingViewModel.isRecordingTrace
                            ? 'Recording Trace [F7]'
                            : 'Recording Asciicast [F8]',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'MesloLGS NF',
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
