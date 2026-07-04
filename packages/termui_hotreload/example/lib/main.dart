import 'package:termui/termui.dart';
import 'package:termui_hotreload/termui_hotreload.dart';

/// To run this example with hot reload enabled:
/// dart --enable-vm-service bin/hotreload_demo.dart
///
/// Then, modify the text or colors below and save the file to see the terminal update instantly.

/// Global scene manager instance for the application.
late final SceneManager globalSceneManager;

/// Entry point for the simple hot-reload example.
void main() async {
  // 1. One-liner that encapsulates HotReloader setup in development mode
  final hotreload = await TermuiHotReload.enable(
    onError: (e) {
      // Custom fallback logic if VM service is not found
    },
  );

  final terminal = Terminal();
  final runner = PromptRunner<void>(
    terminal: terminal,
    alternateScreen: true,
    widget: const MyApp(),
    exitConditions: {
      PromptExitTrigger.escape: PromptExitAction.cancel,
      PromptExitTrigger.controlC: PromptExitAction.abort,
    },
  );

  terminal.enableMouseTracking();

  await runner.run();

  terminal.disableMouseTracking();
  await hotreload?.disable();
  terminal.dispose();
}

/// The main application widget for the hot reload demo.
class MyApp extends StatefulWidget {
  /// Creates the main application widget.
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  int _counter = 0;

  void _incrementCounter() {
    setState(() {
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column([
        const Text(
          'TermUI Stateful Demo',
          style: Style(modifiers: Modifier.bold, foreground: Colors.yellow),
        ),
        const SizedBox(height: 2),
        Text(
          'Button clicked: $_counter times',
          style: const Style(foreground: Colors.white),
        ),
        const SizedBox(height: 1),
        Button(
          text: 'Click Me!',
          onPressed: _incrementCounter,
          style: const Style(
            foreground: Colors.black,
            background: Colors.green,
          ),
          focusedStyle: const Style(
            foreground: Colors.white,
            background: Colors.blue,
            modifiers: Modifier.bold,
          ),
        ),
      ]),
    );
  }
}
