import 'dart:io';
import 'package:termui/termui.dart';
import 'package:termui/termui_trace.dart';
import 'package:termui/ui/renderer.dart';

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
