import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:termui/terminal/terminal.dart' as termui;
import 'package:termui/ui/buffer.dart';
import 'package:termui_flutter/termui_flutter.dart';
import 'widget_book.dart';

import 'package:termui_shared_examples/glass_compositing/glass_compositing.dart';
import 'pty_glass_stub.dart' if (dart.library.io) 'pty_glass_io.dart';

enum TuiDemo {
  widgetBook('Widget Book'),
  glassCompositing('Glass Compositing'),
  ptyGlassCompositing('PTY Glass Compositing (Desktop Only)');

  final String label;
  const TuiDemo(this.label);
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
    } catch (_) {}
  }
  _log('main.dart: main() started');
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TermUI Direct TuiView Demo',
      theme: ThemeData.dark(),
      home: const TermUIWebHome(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class TermUIWebHome extends StatefulWidget {
  const TermUIWebHome({super.key});

  @override
  State<TermUIWebHome> createState() => _TermUIWebHomeState();
}

class _TermUIWebHomeState extends State<TermUIWebHome> {
  late final FlutterTerminal _terminal;

  TuiDemo _currentDemo = TuiDemo.glassCompositing;
  bool _switching = false;
  bool _tuiRunning = false;
  void Function(Buffer)? _onDrawFrame;

  @override
  void initState() {
    super.initState();
    _log('main.dart: initState() started');
    _terminal = FlutterTerminal();
  }

  @override
  void dispose() {
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
        _log('main.dart: Loop iteration, demo: $_currentDemo');
        if (_currentDemo == TuiDemo.widgetBook) {
          _log('main.dart: Running WidgetBook');
          await runWidgetBook(_terminal, onFrameRedrawn: onDrawFrame);
          _log('main.dart: WidgetBook returned');
        } else if (_currentDemo == TuiDemo.glassCompositing) {
          _log('main.dart: Running Glass Compositing');
          await runGlassCompositingShared(
            _terminal,
            isInline: false,
            onFrameRedrawn: onDrawFrame,
          );
          _log('main.dart: Glass Compositing returned');
        } else if (_currentDemo == TuiDemo.ptyGlassCompositing) {
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
    if (_currentDemo == target && _tuiRunning) return;

    _currentDemo = target;
    setState(() {});

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
          if (!kIsWeb)
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.black87,
        actions: [
          IconButton(
            icon: const Icon(Icons.swap_horiz),
            tooltip: 'Switch TUI App',
            onPressed: () => _showSwitchDemoDialog(),
          ),
        ],
      ),
      body: Terminal(
        terminal: _terminal,
        fontSize: 13,
        fontFamily: 'Cascadia Mono',
        onRun: (terminal, drawFrame) async {
          _runTUI(drawFrame);
        },
      ),
    );
  }
}
