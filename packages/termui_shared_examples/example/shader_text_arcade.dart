import 'dart:async';
import 'dart:io';

import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/termui.dart';
import 'package:termui_shared_examples/widget_book/shader_text_arcade_demo.dart';

/// Standalone interactive CLI launcher for the 5-scene Shader Text Arcade:
/// 1. One Ring — dragging fire over hidden golden runes (`one_ring`)
/// 2. Vortext — Black Hole spaghettification & Top-Down Hurricane (`vortex`)
/// 3. Frost & Shatter — 2-stage cryo freeze + crystal shatter (`ice_frost`)
/// 4. Neon & Glitch — neon glass glow + chromatic tear burst (`neon_pulse`, `glitch_tear`)
/// 5. Forge — anvil typing forge with per-character welding sparks (`forge_spark`)
Future<void> main() async {
  await term.Terminal.runGuarded((terminal) async {
    terminal
      ..enterAlternateScreen()
      ..hideCursor()
      ..enableMouseTracking();

    final controller = ShaderTextArcadeController();
    final sceneManager = SceneManager(
      terminal,
      renderingMode: RenderingMode.alternateScreen,
    )..enableMouseTracking = true;

    final runner = PromptRunner<void>(
      terminal: terminal,
      widget: _StandaloneArcadeShell(controller: controller),
      alternateScreen: false,
      mode: ExecutionMode.managed,
      exitConditions: const {},
      onFramePainted: (_) => sceneManager.scheduleRender(),
    );
    final layer = SceneLayer(
      renderer: runner,
      sizing: LayerSizing.fullscreen,
      zIndex: 10,
    );
    sceneManager.layers.add(layer);
    sceneManager.focusedLayer = layer;
    final completer = Completer<void>();
    sceneManager.onKeyEvent = (event) => _handleStandaloneKey(
      event,
      controller: controller,
      completer: completer,
    );

    final physicsTimer = Timer.periodic(
      const Duration(milliseconds: 40),
      (_) => controller.stepPhysics(),
    );
    final eventsSub = terminal.events.listen(
      (event) {
        if (event is term.ShaderCapabilitiesEvent) {
          controller.setGpuShadersSupported(event.isAnySupported);
        }
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
    );

    unawaited(runner.run().catchError((Object _) {}));
    terminal.backend.write(ShaderApcEncoder.encodeQuery());

    try {
      await completer.future;
    } finally {
      unawaited(eventsSub.cancel());
      physicsTimer.cancel();
      controller.dispose();
      runner.abort();
      sceneManager.dispose();
      terminal
        ..disableMouseTracking()
        ..exitAlternateScreen()
        ..showCursor();
    }
  });
  exit(0);
}

bool _handleStandaloneKey(
  KeyEvent event, {
  required ShaderTextArcadeController controller,
  required Completer<void> completer,
}) {
  final isQuitCtrl =
      event.key == '\x03' || event.logicalKey == TermKey.controlC;
  if (isQuitCtrl) {
    if (!completer.isCompleted) completer.complete();
    return true;
  }
  if (!controller.isEditingRingPrompt && _isTopLevelQuit(event)) {
    if (!completer.isCompleted) completer.complete();
    return true;
  }
  return controller.handleKeyEvent(event);
}

bool _isTopLevelQuit(KeyEvent event) =>
    event.key == 'q' ||
    event.key == 'Q' ||
    event.logicalKey == TermKey.escape ||
    event.type == KeyType.escape;

final class _StandaloneArcadeShell extends StatelessWidget {
  final ShaderTextArcadeController controller;

  const _StandaloneArcadeShell({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 1, 2, 1),
      child: Column([
        const SizedBox(
          height: 1,
          child: Text(
            ' SHADER TEXT ARCADE  │  [1-5] or Click Tabs  │  [Q / Esc] Quit ',
            style: Style(
              foreground: CharmColors.pepper,
              background: CharmColors.soda,
              modifiers: Modifier.bold,
            ),
            wrap: false,
          ),
        ),
        const SizedBox(height: 1),
        Expanded(child: ShaderTextArcadeWidget(controller: controller)),
      ], crossAxisAlignment: CrossAxisAlignment.stretch),
    );
  }
}
