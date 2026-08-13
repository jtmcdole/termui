import 'dart:async';
import 'package:termui/termui.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/ui/termui_debug.dart' as dbg;
import 'pty_glass_backend_stub.dart'
    if (dart.library.io) 'pty_glass_backend_io.dart';
import 'package:termui_shared_examples/glass_compositing/glass_compositing.dart';

/// Runs the PTY Glass Demo logic, injecting the given [terminal].
Future<SceneManager> runPtyGlassDemo(
  term.Terminal terminal, {
  void Function(Buffer)? onFrameRedrawn,
}) async {
  final backend = PtyBackend();

  final sceneManager = SceneManager(terminal, renderingMode: .alternateScreen);
  sceneManager.enableMouseTracking = true;
  sceneManager.onFrameRedrawn = onFrameRedrawn;

  terminal.enterAlternateScreen();
  terminal.hideCursor();
  terminal.enableMouseTracking();

  final repository = InMemorySettingsRepository();
  final config = FireConfig(repository);
  config.flameHeight = 1.0;
  config.speed = 1.5;

  // 1. Bottom Layer: PseudoTerminalView running 'top'
  final ptyFocusNode = FocusNode(id: 'pty');
  final ptyRunner = PromptRunner(
    terminal: terminal,
    // Pass a custom default foreground (e.g. bright green) for a "hacker" theme look
    widget: SizedBox.expand(child: backend.buildView(ptyFocusNode)),
    alternateScreen: false,
    mode: .managed,
    onFramePainted: (_) {
      sceneManager.scheduleRender();
    },
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
    sizing: .fixed,
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
    mode: .managed,
    onFramePainted: (_) {
      sceneManager.scheduleRender();
    },
  );
  final fireLayer = SceneLayer(
    renderer: fireRunner,
    sizing: .fullscreen,
    zIndex: 10,
  );
  sceneManager.layers.add(fireLayer);
  fireRunner.run().catchError((_) {});

  bool settingsVisible = false;
  late final SceneLayer settingsLayer;
  final settingsFocusNode = FocusNode(id: 'settings');

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
            settingsFocusNode.requestFocus();
          } else {
            sceneManager.layers.remove(settingsLayer);
            sceneManager.focusedLayer = ptyLayer;
            ptyFocusNode.requestFocus();
          }
          sceneManager.scheduleRender();
          return true;
        }
        return false;
      },
      child: GlassOverlayApp(config: config),
    ),
    alternateScreen: false,
    mode: .managed,
    onFramePainted: (_) {
      sceneManager.scheduleRender();
    },
  );
  final glassLayer = SceneLayer(
    renderer: glassRunner,
    sizing: .fullscreen,
    zIndex: 20,
    mouseOpaque: true,
    onFocus: () => glassFocusNode.requestFocus(),
  );
  sceneManager.layers.add(glassLayer);
  sceneManager.focusedLayer =
      glassLayer; // Initially focus the glass layer so 's' works immediately
  glassRunner.run().catchError((_) {});
  glassFocusNode.requestFocus();
  glassFocusNode.requestFocus();

  // 3. Top Layer: Settings Window
  final settingsRunner = PromptRunner(
    terminal: terminal,
    widget: KeyboardListener(
      focusNode: settingsFocusNode,
      onKeyEvent: (event) {
        if (event.baseKey == TermKey.s) {
          settingsVisible = false;
          sceneManager.layers.remove(settingsLayer);
          sceneManager.focusedLayer = ptyLayer;
          ptyFocusNode.requestFocus();
          sceneManager.scheduleRender();
          return true;
        }
        return false;
      },
      child: SettingsApp(config: config),
    ),
    alternateScreen: false,
    mode: .managed,
    onFramePainted: (_) {
      sceneManager.scheduleRender();
    },
  );
  settingsLayer = SceneLayer(
    renderer: settingsRunner,
    sizing: .fixed,
    x: 2,
    y: 2,
    width: 42,
    height: 20,
    zIndex: 100,
    draggable: true,
    resizable: true,
  );
  settingsRunner.run().catchError((_) {});

  sceneManager.focusedLayer = ptyLayer;

  final fontTimer = Timer.periodic(const Duration(seconds: 10), (t) {
    if (config.autoAnimate) {
      config.fontIndex = (config.fontIndex + 1) % 5;
    }
  });
  final themeTimer = Timer.periodic(const Duration(seconds: 15), (t) {
    if (config.autoAnimate) {
      config.themeIndex = (config.themeIndex + 1) % 6;
    }
  });

  final completer = Completer<void>();

  sceneManager.onKeyEvent = (event) {
    switch (event) {
      case term.KeyEvent(baseKey: TermKey.q) ||
          term.KeyEvent(logicalKey: TermKey.controlC):
        completer.complete();
        return true;
      case term.KeyEvent(baseKey: TermKey.d):
        dbg.debugMouseCursorEnabled = !dbg.debugMouseCursorEnabled;
        dbg.debugShowTouchesEnabled = !dbg.debugShowTouchesEnabled;
        dbg.debugPaintHoverEnabled = !dbg.debugPaintHoverEnabled;
        dbg.debugPaintLayerBordersEnabled = !dbg.debugPaintLayerBordersEnabled;
        sceneManager.scheduleRender();
        return true;
      case term.KeyEvent(logicalKey: TermKey.controlT):
        if (sceneManager.focusedLayer == ptyLayer) {
          sceneManager.focusedLayer = glassLayer;
          glassFocusNode.requestFocus();
        } else {
          sceneManager.focusedLayer = ptyLayer;
          ptyFocusNode.requestFocus();
        }
        sceneManager.scheduleRender();
        return true;
      default:
        return false;
    }
  };

  try {
    await completer.future;
  } finally {
    fontTimer.cancel();
    themeTimer.cancel();
    backend.kill();
    settingsRunner.abort();
    glassRunner.abort();
    fireRunner.abort();
    ptyRunner.abort();
    sceneManager.dispose();
  }

  return sceneManager;
}
