import 'dart:async';
import 'dart:io';
import 'package:termui/termui.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui_pty/termui_pty.dart';
import 'package:termui/ui/termui_debug.dart' as dbg;
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

    // 1. Bottom Layer: PseudoTerminalView running 'top'
    final ptyFocusNode = FocusNode(id: 'pty');
    final ptyRunner = PromptRunner(
      terminal: terminal,
      // Pass a custom default foreground (e.g. bright green) for a "hacker" theme look
      widget: SizedBox.expand(
        child: PseudoTerminalView(
          pty: pty,
          transparentBackground: true,
          defaultForeground: CharmColors.julep,
          focusNode: ptyFocusNode,
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

    bool settingsVisible = false;
    late final SceneLayer settingsLayer;

    // 2. Middle Layer: Glass Overlay Text (with Glitch)
    final glassFocusNode = FocusNode(id: 'glass');
    final glassRunner = PromptRunner(
      terminal: terminal,
      widget: KeyboardListener(
        focusNode: glassFocusNode,
        onKeyEvent: (event) {
          if (event.baseKey == TermKey.s) {
            settingsVisible = !settingsVisible;
            if (settingsVisible) {
              sceneManager.layers.add(settingsLayer);
              sceneManager.focusedLayer = settingsLayer;
            } else {
              sceneManager.layers.remove(settingsLayer);
            }
            sceneManager.scheduleRender();
            return true;
          }
          return false;
        },
        child: GlassOverlayApp(config: config),
      ),
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
    glassFocusNode.requestFocus();

    // 3. Top Layer: Settings Window
    final settingsFocusNode = FocusNode(id: 'settings');
    final settingsRunner = PromptRunner(
      terminal: terminal,
      widget: KeyboardListener(
        focusNode: settingsFocusNode,
        onKeyEvent: (event) {
          if (event.baseKey == TermKey.s) {
            settingsVisible = false;
            sceneManager.layers.remove(settingsLayer);
            sceneManager.scheduleRender();
            return true;
          }
          return false;
        },
        child: SettingsApp(config: config),
      ),
      alternateScreen: false,
      mode: ExecutionMode.managed,
      onFramePainted: (_) => sceneManager.scheduleRender(),
    );
    settingsLayer = SceneLayer(
      renderer: settingsRunner,
      sizing: LayerSizing.fixed,
      x: 2,
      y: 2,
      width: 42,
      height: 18,
      zIndex: 100,
      draggable: true,
      resizable: true,
    );
    settingsRunner.run().catchError((_) {});

    sceneManager.focusedLayer = ptyLayer;

    final fontTimer = Timer.periodic(const Duration(seconds: 10), (t) {
      config.fontIndex = (config.fontIndex + 1) % 5;
    });
    final themeTimer = Timer.periodic(const Duration(seconds: 15), (t) {
      config.themeIndex = (config.themeIndex + 1) % 6;
    });

    final completer = Completer<void>();

    sceneManager.onKeyEvent = (event) {
      if (event.baseKey == TermKey.q || event.logicalKey == TermKey.controlC) {
        completer.complete();
        return true;
      }
      if (event.baseKey == TermKey.d) {
        // Toggle debug overlays
        dbg.debugMouseCursorEnabled = !dbg.debugMouseCursorEnabled;
        dbg.debugShowTouchesEnabled = !dbg.debugShowTouchesEnabled;
        dbg.debugPaintHoverEnabled = !dbg.debugPaintHoverEnabled;
        sceneManager.scheduleRender();
        return true;
      }
      if (event.logicalKey == TermKey.controlT) {
        // Ctrl+T to toggle focus
        if (sceneManager.focusedLayer == ptyLayer) {
          sceneManager.focusedLayer = glassLayer; // defocus
          glassFocusNode.requestFocus();
        } else {
          sceneManager.focusedLayer = ptyLayer; // focus
          ptyFocusNode.requestFocus();
        }
        sceneManager.scheduleRender();
        return true;
      }
      // s is now handled by the glass layer directly!
      return false; // let SceneManager route the event
    };

    try {
      await completer.future;
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
