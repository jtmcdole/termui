import 'dart:async';
import 'dart:io';
import 'package:termui/termui.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui_pty/termui_pty.dart';
import 'package:pty2/pty2.dart';
import 'package:termui_shared_examples/glass_compositing/glass_compositing.dart';

void main() async {
  final pty = PseudoTerminal.start(
    'bash',
    ['-c', 'btop'],
    environment: {...Platform.environment},
  );

  await term.Terminal.runGuarded((terminal) async {
    final sceneManager = SceneManager(
      terminal,
      renderingMode: RenderingMode.alternateScreen,
    );
    sceneManager.enableMouseTracking = true;

    terminal.enterAlternateScreen();
    terminal.hideCursor();
    terminal.enableMouseTracking();

    final config = FireConfig();
    config.flameHeight = 1.0;
    config.speed = 1.5;

    // 1. Bottom Layer: PlatformView running 'top'
    final ptyRunner = PromptRunner(
      terminal: terminal,
      // Pass a custom default foreground (e.g. bright green) for a "hacker" theme look
      widget: SizedBox.expand(
        child: PlatformView(
          pty: pty,
          transparentBackground: true,
          defaultForeground: CharmColors.julep,
        ),
      ),
      alternateScreen: false,
      mode: ExecutionMode.managed,
      onFramePainted: (_) => sceneManager.scheduleRender(),
    );

    final initialSize = terminal.backend.size;
    int ptyWidth = 100;
    int ptyHeight = 30;
    if (initialSize.x > 0 && ptyWidth > initialSize.x) {
      ptyWidth = initialSize.x - 4;
    }
    if (initialSize.y > 0 && ptyHeight > initialSize.y) {
      ptyHeight = initialSize.y - 4;
    }

    final ptyLayer = SceneLayer(
      renderer: ptyRunner,
      sizing: LayerSizing.fixed,
      width: ptyWidth,
      height: ptyHeight,
      x: (initialSize.x > 0 ? (initialSize.x - ptyWidth) ~/ 2 : 10),
      y: (initialSize.y > 0 ? (initialSize.y - ptyHeight) ~/ 2 : 5),
      zIndex: 15,
      draggable: true,
      resizable: true,
    );

    ptyLayer.onResize = (newSize) {
      ptyLayer.x = (newSize.x - (ptyLayer.width ?? 0)) ~/ 2;
      ptyLayer.y = (newSize.y - (ptyLayer.height ?? 0)) ~/ 2;
    };

    sceneManager.layers.add(ptyLayer);
    ptyRunner.run().catchError((_) {});

    // 1.5 Middle Layer: Fire Simulation
    final fireRunner = PromptRunner(
      terminal: terminal,
      widget: FireApp(config: config),
      alternateScreen: false,
      mode: ExecutionMode.managed,
      onFramePainted: (_) => sceneManager.scheduleRender(),
    );
    final fireLayer = SceneLayer(
      renderer: fireRunner,
      sizing: LayerSizing.fullscreen,
      zIndex: 10,
    );
    sceneManager.layers.add(fireLayer);
    fireRunner.run().catchError((_) {});

    // 2. Middle Layer: Glass Overlay Text (with Glitch)
    final glassRunner = PromptRunner(
      terminal: terminal,
      widget: GlassOverlayApp(config: config),
      alternateScreen: false,
      mode: ExecutionMode.managed,
      onFramePainted: (_) => sceneManager.scheduleRender(),
    );
    final glassLayer = SceneLayer(
      renderer: glassRunner,
      sizing: LayerSizing.fullscreen,
      zIndex: 20,
    );
    sceneManager.layers.add(glassLayer);
    glassRunner.run().catchError((_) {});

    // 3. Top Layer: Settings Window
    final settingsRunner = PromptRunner(
      terminal: terminal,
      widget: SettingsApp(config: config),
      alternateScreen: false,
      mode: ExecutionMode.managed,
      onFramePainted: (_) => sceneManager.scheduleRender(),
    );
    final settingsLayer = SceneLayer(
      renderer: settingsRunner,
      sizing: LayerSizing.fixed,
      x: 2,
      y: 2,
      width: 42,
      height: 18,
      zIndex: 30,
      draggable: true,
      resizable: true,
    );
    settingsRunner.run().catchError((_) {});

    sceneManager.focusedLayer = glassLayer;
    bool settingsVisible = false;

    final fontTimer = Timer.periodic(const Duration(seconds: 10), (t) {
      config.fontIndex = (config.fontIndex + 1) % 5;
    });
    final themeTimer = Timer.periodic(const Duration(seconds: 15), (t) {
      config.themeIndex = (config.themeIndex + 1) % 6;
    });

    try {
      await for (final event in terminal.events) {
        if (event is term.KeyEvent) {
          if (event.key == 'q' || event.key == 'Q' || event.key == '\x03') {
            break;
          }
          if (event.key == '\x14') {
            // Ctrl+T to toggle focus
            if (sceneManager.focusedLayer == ptyLayer) {
              sceneManager.focusedLayer = glassLayer; // defocus
            } else {
              sceneManager.focusedLayer = ptyLayer; // focus
            }
            sceneManager.scheduleRender();
            continue;
          }
          if (event.key == 's' || event.key == 'S') {
            settingsVisible = !settingsVisible;
            if (settingsVisible) {
              sceneManager.layers.add(settingsLayer);
              sceneManager.focusedLayer = settingsLayer;
            } else {
              sceneManager.layers.remove(settingsLayer);
              sceneManager.focusedLayer =
                  ptyLayer; // Focus PTY when settings hidden
            }
            sceneManager.scheduleRender();
            continue;
          }
        }

        if (event is term.KeyEvent) {
          sceneManager.handleKeyEvent(event);
        } else if (event is term.MouseEvent) {
          sceneManager.handleMouseEvent(event);
        }
      }
    } finally {
      fontTimer.cancel();
      themeTimer.cancel();
      pty.kill();
      settingsRunner.abort();
      glassRunner.abort();
      fireRunner.abort();
      ptyRunner.abort();
      sceneManager.dispose();
      terminal.exitAlternateScreen();
    }
  });

  exit(0);
}
