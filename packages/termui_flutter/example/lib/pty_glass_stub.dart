import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'package:termui/termui.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/ui/termui_debug.dart' as dbg;
import 'package:termui_shared_examples/glass_compositing/glass_compositing.dart';
import 'package:termui_pty/termui_pty.dart';

class VirtualTerminalStubWidget extends StatefulWidget {
  final FocusNode? focusNode;

  const VirtualTerminalStubWidget({super.key, this.focusNode});

  @override
  State<VirtualTerminalStubWidget> createState() =>
      _VirtualTerminalStubWidgetState();
}

class _VirtualTerminalStubWidgetState extends State<VirtualTerminalStubWidget> {
  late VirtualTerminal _terminal;
  late Timer _timer;
  final Random _random = Random();
  final List<Color> _colors = [
    CharmColors.julep,
    CharmColors.charple,
    CharmColors.malibu,
    CharmColors.mustard,
    CharmColors.flamingo,
  ];

  final List<String> _messages = [
    'Connection established',
    'Handshake completed',
    'Receiving packets...',
    'PING',
    'PONG',
    'Buffer flush',
    'Heartbeat OK',
    'Analyzing telemetry',
    'Re-routing traffic',
  ];

  @override
  void initState() {
    super.initState();
    _terminal = VirtualTerminal(
      width: 80,
      height: 24,
      transparentBackground: true,
      defaultForeground: CharmColors.julep,
    );

    // We must rebuild when the terminal repaints, since VirtualTerminal works outside of element state tracking.
    _terminal.addListener(() {
      if (mounted) setState(() {});
    });

    _timer = Timer.periodic(const Duration(milliseconds: 500), (t) {
      if (!mounted) return;
      final color = _colors[_random.nextInt(_colors.length)];
      final msg = _messages[_random.nextInt(_messages.length)];
      final ip =
          '${_random.nextInt(255)}.${_random.nextInt(255)}.${_random.nextInt(255)}.${_random.nextInt(255)}';

      final fgCode = color.foregroundCode;
      final resetCode = '\x1b[0m';
      final timestamp = DateTime.now().toIso8601String().substring(11, 19);

      final ansiString = '[$timestamp] $fgCode$ip$resetCode - $msg\r\n';
      _terminal.write(utf8.encode(ansiString));
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    _terminal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth == BoxConstraints.infinity
            ? 80
            : constraints.maxWidth.toInt();
        final h = constraints.maxHeight == BoxConstraints.infinity
            ? 24
            : constraints.maxHeight.toInt();
        _terminal.resize(w, h);
        return TerminalView(
          terminal: _terminal,
          focusNode: widget.focusNode,
          onInput: (_) {}, // dummy input handler
        );
      },
    );
  }
}

Future<void> runPtyGlassDemo(
  dynamic terminal, {
  void Function(Buffer)? onFrameRedrawn,
}) async {
  final term.Terminal t = terminal as term.Terminal;
  final sceneManager = SceneManager(
    t,
    renderingMode: RenderingMode.alternateScreen,
  );
  sceneManager.enableMouseTracking = true;
  sceneManager.onFrameRedrawn = onFrameRedrawn;

  t.enterAlternateScreen();
  t.hideCursor();
  t.enableMouseTracking();

  final config = FireConfig();
  config.flameHeight = 1.0;
  config.speed = 1.5;

  // 1. Bottom Layer: Virtual Terminal (instead of PTY)
  final ptyFocusNode = FocusNode(id: 'pty');
  final ptyRunner = PromptRunner(
    terminal: t,
    widget: SizedBox.expand(
      child: VirtualTerminalStubWidget(focusNode: ptyFocusNode),
    ),
    alternateScreen: false,
    mode: ExecutionMode.managed,
    onFramePainted: (_) {
      sceneManager.scheduleRender();
    },
  );

  final initialSize = t.backend.size;
  int ptyWidth = 80;
  int ptyHeight = 25;
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
    terminal: t,
    widget: FireApp(config: config),
    alternateScreen: false,
    mode: ExecutionMode.managed,
    onFramePainted: (_) {
      sceneManager.scheduleRender();
    },
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
    terminal: t,
    widget: KeyboardListener(
      focusNode: glassFocusNode,
      onKeyEvent: (event) {
        if (event.baseKey == term.TermKey.s) {
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
    onFramePainted: (_) {
      sceneManager.scheduleRender();
    },
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
    terminal: t,
    widget: KeyboardListener(
      focusNode: settingsFocusNode,
      onKeyEvent: (event) {
        if (event.baseKey == term.TermKey.s) {
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
    onFramePainted: (_) {
      sceneManager.scheduleRender();
    },
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

  final fontTimer = Timer.periodic(const Duration(seconds: 10), (time) {
    config.fontIndex = (config.fontIndex + 1) % 5;
  });
  final themeTimer = Timer.periodic(const Duration(seconds: 15), (time) {
    config.themeIndex = (config.themeIndex + 1) % 6;
  });

  final completer = Completer<void>();

  sceneManager.onKeyEvent = (event) {
    if (event.baseKey == term.TermKey.q ||
        event.logicalKey == term.TermKey.controlC) {
      completer.complete();
      return true;
    }
    if (event.baseKey == term.TermKey.d) {
      dbg.debugMouseCursorEnabled = !dbg.debugMouseCursorEnabled;
      dbg.debugShowTouchesEnabled = !dbg.debugShowTouchesEnabled;
      dbg.debugPaintHoverEnabled = !dbg.debugPaintHoverEnabled;
      sceneManager.scheduleRender();
      return true;
    }
    if (event.logicalKey == term.TermKey.controlT) {
      if (sceneManager.focusedLayer == ptyLayer) {
        sceneManager.focusedLayer = glassLayer;
        glassFocusNode.requestFocus();
      } else {
        sceneManager.focusedLayer = ptyLayer;
        ptyFocusNode.requestFocus();
      }
      sceneManager.scheduleRender();
      return true;
    }
    return false;
  };

  try {
    await completer.future;
  } finally {
    fontTimer.cancel();
    themeTimer.cancel();
    settingsRunner.abort();
    glassRunner.abort();
    fireRunner.abort();
    ptyRunner.abort();
    sceneManager.dispose();
    t.exitAlternateScreen();
  }
}
