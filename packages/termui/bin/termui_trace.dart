import 'dart:io';
import 'package:termui/termui.dart';
import 'package:termui/termui_trace.dart';

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

    try {
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

      await runner.run();
    } on UserInterruptException {
      // Restore terminal cleanly when interrupted by Ctrl+C.
    } finally {
      globalSceneManager.dispose();
      terminal.disableMouseTracking();
      terminal.exitAlternateScreen();
      terminal.showCursor();
      terminal.dispose();
    }
  });

  exit(0);
}
