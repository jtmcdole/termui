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

enum TuiDemo {
  widgetBook('Widget Book', 'widgetbook'),
  glassCompositing('Glass Compositing', 'glass'),
  ptyGlassCompositing('PTY Glass Compositing', 'pty');

  final String label;
  final String queryName;
  const TuiDemo(this.label, this.queryName);
}

void _log(String message) {
  if (kIsWeb) {
    // ignore: avoid_print
    print('[TUI] $message');
    return;
  }
  try {
    final file = File('tui_diagnostics.log');
    file.writeAsStringSync(
      '[${DateTime.now().toIso8601String()}] $message\n',
      mode: FileMode.append,
    );
  } catch (_) {}
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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

  TuiDemo currentDemo = TuiDemo.glassCompositing;
  String? initialPage;
  StreamSubscription? _pageChangedSub;
  StreamSubscription? _urlChangesSub;
  bool _switching = false;
  bool _tuiRunning = false;
  void Function(Buffer)? _onDrawFrame;

  @override
  void initState() {
    super.initState();
    _log('main.dart: initState() started');
    _terminal = FlutterTerminal();

    final query = widget.initialQuery ?? getUrlParams();
    final demoParam = query['demo'];
    if (demoParam == 'widgetbook') {
      currentDemo = TuiDemo.widgetBook;
    } else if (demoParam == 'glass') {
      currentDemo = TuiDemo.glassCompositing;
    } else if (demoParam == 'pty') {
      currentDemo = TuiDemo.ptyGlassCompositing;
    }
    initialPage = query['page'];

    _pageChangedSub = pageChangedEvent.on(widgetBookEventBus).listen((
      pageName,
    ) {
      initialPage = pageName;
      updateUrlParams(demo: currentDemo.queryName, page: pageName);
    });

    _urlChangesSub = listenToUrlChanges((newQuery) {
      final demoParam = newQuery['demo'];
      TuiDemo? targetDemo;
      if (demoParam == 'widgetbook') {
        targetDemo = TuiDemo.widgetBook;
      } else if (demoParam == 'glass') {
        targetDemo = TuiDemo.glassCompositing;
      } else if (demoParam == 'pty') {
        targetDemo = TuiDemo.ptyGlassCompositing;
      }

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
  }

  @override
  void dispose() {
    _pageChangedSub?.cancel();
    _urlChangesSub?.cancel();
    _terminal.dispose();
    super.dispose();
  }

  void _runTUI(void Function(Buffer) onDrawFrame) async {
    _log('main.dart: _runTUI() started, _tuiRunning: $_tuiRunning');
    _onDrawFrame = onDrawFrame;
    if (_tuiRunning) return;
    _tuiRunning = true;

    try {
      while (mounted) {
        _log('main.dart: Loop iteration, demo: $currentDemo');
        if (currentDemo == TuiDemo.widgetBook) {
          _log('main.dart: Running WidgetBook');
          await runWidgetBook(
            _terminal,
            onFrameRedrawn: onDrawFrame,
            initialPage: initialPage,
          );
          _log('main.dart: WidgetBook returned');
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
                  _runTUI(drawFrame);
                },
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
        ],
      ),
    );
  }
}
