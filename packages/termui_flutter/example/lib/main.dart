import 'dart:async';
import 'dart:io';
import 'package:clock/clock.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:termui/terminal/terminal.dart' as termui;
import 'package:termui/ui/buffer.dart';
import 'package:termui_flutter/termui_flutter.dart';
import 'widget_book.dart';

import 'package:termui_shared_examples/glass_compositing/glass_compositing.dart';
import 'package:termui_shared_examples/glass_compositing/pty_glass_runner.dart';
import 'package:termui_shared_examples/ktty_probe/ktty_probe.dart';
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
  kittyProtocol('Kitty Protocol (KTTY)', 'ktty'),
  kttyProbe('KTTY Probe (VirtualTerminal)', 'ktty-probe'),
  glassCompositing('Glass Compositing', 'glass'),
  ptyGlassCompositing('PTY Glass Compositing', 'pty'),
  asciicastPlayer('Asciicast Player', 'player'),
  traceViewer('Trace Viewer', 'trace');

  final String label;
  final String queryName;
  const TuiDemo(this.label, this.queryName);

  static TuiDemo? fromQuery(String? value) => switch (value) {
    'widgetbook' => TuiDemo.widgetBook,
    'ktty' => TuiDemo.kittyProtocol,
    'ktty-probe' => TuiDemo.kttyProbe,
    'glass' => TuiDemo.glassCompositing,
    'pty' => TuiDemo.ptyGlassCompositing,
    'player' => TuiDemo.asciicastPlayer,
    'trace' => TuiDemo.traceViewer,
    _ => null,
  };
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
          '[${clock.now().toIso8601String()}] $message\n',
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
    } catch (e) {
      debugPrint('FONT LOADER ERROR: $e');
    }
  }
  _log('main.dart: main() started');
  runApp(const MainApp());
}

final class MainApp extends StatelessWidget {
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

final class TermUIWebHome extends StatefulWidget {
  final Map<String, String>? initialQuery;
  const TermUIWebHome({super.key, this.initialQuery});

  @override
  State<TermUIWebHome> createState() => TermUIWebHomeState();
}

class TermUIWebHomeState extends State<TermUIWebHome> {
  static const List<String> _defaultFontFallback = [
    'Noto Color Emoji',
    'Cascadia Mono',
  ];
  static const List<String> _ligatureFontFallback = [
    'Fira Code',
    'JetBrains Mono',
    'MesloLGS NF',
    'Noto Color Emoji',
    'Cascadia Mono',
  ];

  late final FlutterTerminal _terminal;

  TuiDemo currentDemo = TuiDemo.asciicastPlayer;
  String? initialPage;
  StreamSubscription<String>? _pageChangedSub;
  StreamSubscription<Object?>? _urlChangesSub;
  StreamSubscription<void>? _uploadRequestedSub;
  StreamSubscription<void>? _uploadTraceRequestedSub;
  StreamSubscription<bool>? _ligaturesSub;
  bool _ligaturesEnabled = false;
  bool _userToggledLigatures = false;
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
      if (event.logicalKey == LogicalKeyboardKey.f9) {
        _toggleUserLigatures();
        return true;
      }
    }
    return false;
  }

  void _toggleUserLigatures() {
    _userToggledLigatures = true;
    _terminal.toggleLigatures();
  }

  @override
  void initState() {
    super.initState();
    _recordingViewModel = RecordingViewModel(
      RecordingService(SavedCastsRepository()),
      onLog: _log,
    );
    _recordingViewModel.addListener(_onRecordingStateChanged);
    HardwareKeyboard.instance.addHandler(_handleGlobalKey);
    _log('main.dart: initState() started');
    _terminal = FlutterTerminal();
    _ligaturesEnabled = _terminal.enableLigatures;
    _ligaturesSub = _terminal.watchEnableLigatures().listen(
      _onLigaturesChanged,
    );

    final query = widget.initialQuery ?? getUrlParams();
    currentDemo = TuiDemo.fromQuery(query['demo']) ?? TuiDemo.glassCompositing;
    initialPage = currentDemo == TuiDemo.kittyProtocol
        ? 'kittyProtocol'
        : query['page'];

    _pageChangedSub = pageChangedEvent
        .on(widgetBookEventBus)
        .listen(_onPageChanged);
    _urlChangesSub = listenToUrlChanges(_onUrlQueryChanged);
    _uploadRequestedSub = uploadCastRequestedEvent
        .on(playerEventBus)
        .listen((_) => _pickAndPostCastFile());
    _uploadTraceRequestedSub = uploadTraceRequestedEvent
        .on(playerEventBus)
        .listen((_) => _pickAndPostTraceFile());
  }

  void _onRecordingStateChanged() {
    if (mounted) setState(() {});
  }

  void _onLigaturesChanged(bool enabled) {
    if (!mounted || _ligaturesEnabled == enabled) return;
    setState(() {
      _ligaturesEnabled = enabled;
    });
  }

  void _onPageChanged(String pageName) {
    initialPage = pageName;
    updateUrlParams(demo: currentDemo.queryName, page: pageName);
  }

  void _onUrlQueryChanged(Map<String, String> newQuery) {
    final targetDemo = TuiDemo.fromQuery(newQuery['demo']);
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
  }

  Future<void> _pickAndPostCastFile() async {
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
  }

  Future<void> _pickAndPostTraceFile() async {
    try {
      const typeGroup = XTypeGroup(label: 'Traces', extensions: ['json', 'gz']);
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
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalKey);
    _pageChangedSub?.cancel();
    _urlChangesSub?.cancel();
    _uploadRequestedSub?.cancel();
    _uploadTraceRequestedSub?.cancel();
    _ligaturesSub?.cancel();
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

  Future<void>? tuiFuture;

  Future<void> _executeCurrentDemo(void Function(Buffer) onDrawFrame) async {
    switch (currentDemo) {
      case TuiDemo.widgetBook:
        _log('main.dart: Running WidgetBook');
        await runWidgetBook(
          _terminal,
          onFrameRedrawn: onDrawFrame,
          initialPage: initialPage,
        );
      case TuiDemo.kittyProtocol:
        _log('main.dart: Running Kitty Protocol Demo');
        await runWidgetBook(
          _terminal,
          onFrameRedrawn: onDrawFrame,
          initialPage: 'kittyProtocol',
        );
      case TuiDemo.kttyProbe:
        _log('main.dart: Running KTTY Probe inside VirtualTerminal');
        await _runKttyProbeDemo(onDrawFrame);
      case TuiDemo.glassCompositing:
        _log('main.dart: Running Glass Compositing');
        await runGlassCompositingShared(
          _terminal,
          isInline: false,
          onFrameRedrawn: onDrawFrame,
        );
      case TuiDemo.ptyGlassCompositing:
        _log('main.dart: Running PTY Glass Compositing');
        await runPtyGlassDemo(_terminal, onFrameRedrawn: onDrawFrame);
      case TuiDemo.asciicastPlayer:
        _log('main.dart: Running TUI Asciicast Player');
        await runAsciicastPlayerTui(_terminal, onFrameRedrawn: onDrawFrame);
      case TuiDemo.traceViewer:
        _log('main.dart: Running TUI Trace Viewer');
        await runTraceViewerTui(
          _terminal,
          initialBytes: _initialTraceBytes,
          initialFilename: _initialTraceFilename,
          onFrameRedrawn: onDrawFrame,
        );
        _initialTraceBytes = null;
        _initialTraceFilename = null;
    }
  }

  Future<void> _runKttyProbeDemo(void Function(Buffer) onDrawFrame) async {
    final prevLigatures = _terminal.enableLigatures;
    if (!_userToggledLigatures) {
      _terminal.setEnableLigatures(true);
    }
    final (cellPxW, cellPxH) = _terminal.cellPixelSize;
    try {
      await runVirtualTerminalKttyProbe(
        _terminal,
        onFrameRedrawn: onDrawFrame,
        cellPixelWidth: cellPxW,
        cellPixelHeight: cellPxH,
        cellPixelSizeChanges: _terminal.watchCellPixelSize(),
      );
    } finally {
      if (mounted && !_userToggledLigatures) {
        _terminal.setEnableLigatures(prevLigatures);
      }
    }
  }

  Future<void> _runTUI(void Function(Buffer) onDrawFrame) async {
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
        await _executeCurrentDemo(onDrawFrame);

        if (!mounted || !context.mounted) {
          _log('main.dart: Not mounted, exiting loop');
          break;
        }
        if (!_switching) {
          _log('main.dart: Exited loop without switching, showing dialog');
          _showSwitchDemoDialog(title: 'TUI Application Exited');
          break;
        }
        _log('main.dart: Exited loop due to switching');
        _switching = false;
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
    if (!mounted || !context.mounted) return;
    if (currentDemo == target && _tuiRunning) return;

    currentDemo = target;
    initialPage = target == TuiDemo.kittyProtocol ? 'kittyProtocol' : null;
    setState(() {});

    updateUrlParams(demo: target.queryName, page: initialPage);

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
      tuiFuture = _runTUI(_onDrawFrame!);
    }
  }

  Widget _buildDemoDialogButton(BuildContext dialogContext, TuiDemo demo) {
    return TextButton(
      onPressed: () {
        if (dialogContext.mounted) Navigator.pop(dialogContext);
        _switchDemo(demo);
      },
      child: Text(demo.label),
    );
  }

  void _showSwitchDemoDialog({String title = 'Switch TUI Application'}) {
    if (!mounted || !context.mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: _tuiRunning,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: const Text(
          'Select which TUI application to run in the terminal emulator:',
        ),
        actions: [
          _buildDemoDialogButton(dialogContext, TuiDemo.asciicastPlayer),
          _buildDemoDialogButton(dialogContext, TuiDemo.traceViewer),
          _buildDemoDialogButton(dialogContext, TuiDemo.widgetBook),
          _buildDemoDialogButton(dialogContext, TuiDemo.kittyProtocol),
          _buildDemoDialogButton(dialogContext, TuiDemo.kttyProbe),
          _buildDemoDialogButton(dialogContext, TuiDemo.glassCompositing),
          _buildDemoDialogButton(dialogContext, TuiDemo.ptyGlassCompositing),
        ],
      ),
    );
  }

  double _baseFontSize = 13.0;
  double _currentFontSize = 13.0;

  Future<void> _handleDroppedFiles(Map<String, XFile> files) async {
    if (files.isEmpty) return;
    final firstFile = files.values.first;
    try {
      final bytes = await firstFile.readAsBytes();
      _log(
        'main.dart: Processing dropped file: ${firstFile.name} (${bytes.length} bytes)',
      );
      final isTrace =
          firstFile.name.endsWith('.json') ||
          firstFile.name.endsWith('.json.gz');
      if (isTrace) {
        await _loadDroppedTrace(firstFile.name, bytes);
      } else {
        await _loadDroppedCast(firstFile.name, bytes);
      }
    } catch (e) {
      _log('main.dart: Drag-and-drop error: $e');
    }
  }

  Future<void> _loadDroppedTrace(String name, Uint8List bytes) async {
    _initialTraceBytes = bytes;
    _initialTraceFilename = name;
    if (currentDemo != TuiDemo.traceViewer) {
      _switchDemo(TuiDemo.traceViewer);
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
    traceUploadedEvent.post(playerEventBus, UploadedTraceData(name, bytes));
  }

  Future<void> _loadDroppedCast(String name, Uint8List bytes) async {
    if (currentDemo != TuiDemo.asciicastPlayer) {
      _switchDemo(TuiDemo.asciicastPlayer);
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
    castUploadedEvent.post(playerEventBus, UploadedCastData(name, bytes));
  }

  Future<void> _onTerminalRun(
    FlutterTerminal terminal,
    void Function(Buffer) drawFrame,
  ) async {
    void wrappedDrawFrame(Buffer buf) {
      _recordingViewModel.asciicastRecorder?.recordFrame(buf);
      drawFrame(buf);
    }

    tuiFuture = _runTUI(wrappedDrawFrame);
  }

  Widget _buildRecordingBadge() {
    final label = _recordingViewModel.isRecordingTrace
        ? 'Recording Trace [F7]'
        : 'Recording Asciicast [F8]';
    return Positioned(
      top: 16.0,
      left: 16.0,
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
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
                label,
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final isRecording =
        _recordingViewModel.isRecordingTrace ||
        _recordingViewModel.isRecordingAsciicast;
    final targetPath = currentDemo == TuiDemo.traceViewer
        ? 'Trace Viewer'
        : 'Asciicast Player';

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: FileUploadZone(
              targetPath: targetPath,
              onFilesSelected: _handleDroppedFiles,
              child: GestureDetector(
                onScaleStart: (_) {
                  _baseFontSize = _currentFontSize;
                },
                onScaleUpdate: (details) {
                  if (details.scale == 1.0) return;
                  final nextSize = (_baseFontSize * details.scale).clamp(
                    4.0,
                    72.0,
                  );
                  if (nextSize != _currentFontSize) {
                    setState(() {
                      _currentFontSize = nextSize;
                      _terminal.setFontSize(_currentFontSize);
                    });
                  }
                },
                child: Terminal(
                  terminal: _terminal,
                  fontSize: _currentFontSize,
                  enableLigatures: _ligaturesEnabled,
                  fontFamily: _ligaturesEnabled
                      ? 'Cascadia Code'
                      : 'MesloLGS NF',
                  fontFamilyFallback: _ligaturesEnabled
                      ? _ligatureFontFallback
                      : _defaultFontFallback,
                  onRun: _onTerminalRun,
                ),
              ),
            ),
          ),
          _buildTopRightControls(),
          if (isRecording) _buildRecordingBadge(),
        ],
      ),
    );
  }

  Widget _buildTopRightControls() {
    return Positioned(
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
            onPressed: _showSwitchDemoDialog,
          ),
        ),
      ),
    );
  }
}
