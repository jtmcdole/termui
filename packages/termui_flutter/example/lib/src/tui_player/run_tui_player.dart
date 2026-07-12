import 'dart:async';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/termui.dart';
import '../viewmodel.dart';
import 'tui_player_app.dart';

/// Runs the Asciicast Player TUI application under [SceneManager] and [PromptRunner].
Future<void> runAsciicastPlayerTui(
  term.Terminal terminal, {
  void Function(Buffer buffer)? onFrameRedrawn,
}) async {
  final viewModel = AsciicastPlayerViewModel();

  final sceneManager = SceneManager(
    terminal,
    renderingMode: RenderingMode.alternateScreen,
  )..enableMouseTracking = true;

  final runner = PromptRunner<void>(
    terminal: terminal,
    widget: AsciicastPlayerTuiApp(viewModel: viewModel),
    alternateScreen: true,
    mode: ExecutionMode.managed,
    exitConditions: const {PromptExitTrigger.controlC: PromptExitAction.abort},
    onFramePainted: (buf) {
      onFrameRedrawn?.call(buf);
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

  // Attempt to load default demo cast if present
  try {
    final demoRaw = await viewModel.repository.loadCast('demo.cast');
    if (demoRaw != null) {
      await viewModel.loadCastData('demo.cast', demoRaw);
    }
  } catch (_) {}

  try {
    await runner.run();
  } on PromptAbortedException catch (_) {
    // Aborted via Ctrl+C
  } finally {
    sceneManager.dispose();
    viewModel.dispose();
  }
}
