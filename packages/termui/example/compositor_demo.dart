import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:termui/termui.dart';
import 'package:termui/terminal/event.dart' as ev;

Widget buildBackgroundWidget(Point<int>? mousePos, List<SceneLayer> layers) {
  final debugInfo = <Widget>[
    const SizedBox(
      height: 1,
      child: Text(
        '=== COMPOSITOR DEMO DEBUG INFO ===',
        style: Style(foreground: Colors.yellow, modifiers: Modifier.bold),
      ),
    ),
    SizedBox(
      height: 1,
      child: Text(
        'Mouse Position (1-based): ${mousePos != null ? "x: ${mousePos.x}, y: ${mousePos.y}" : "no event"}',
        style: const Style(foreground: Colors.white),
      ),
    ),
    const SizedBox(height: 1),
    const SizedBox(
      height: 1,
      child: Text(
        'Layer Hitboxes (0-based offsets):',
        style: Style(modifiers: Modifier.bold),
      ),
    ),
  ];

  for (var i = 0; i < layers.length; i++) {
    final layer = layers[i];
    final buf = layer.renderer.currentBuffer;
    final w = buf?.width ?? 0;
    final h = buf?.height ?? 0;
    debugInfo.add(
      SizedBox(
        height: 1,
        child: Text(
          '  Layer $i - zIndex: ${layer.zIndex}, bounds: Rect(${layer.x}, ${layer.y}, $w, $h), draggable: ${layer.draggable}',
          style: Style(
            foreground: layer.draggable ? Colors.green : Colors.white,
          ),
        ),
      ),
    );
  }

  debugInfo.add(const SizedBox(height: 2));

  // Add the textured lines after the debug info (capped to 10 to fit in 24-high terminal)
  debugInfo.addAll(
    List.generate(
      10,
      (_) => const SizedBox(
        height: 1,
        child: Text(
          'Background Application Layer Background Application Layer Background Application Layer',
          style: Style(foreground: Color(80, 80, 80)),
        ),
      ),
    ),
  );

  return Column(debugInfo);
}

void main() async {
  Tracer.activeCategories = {TraceCategory.compositor, TraceCategory.events};
  debugMouseCursorEnabled = true;
  debugPaintLayerBordersEnabled = true;

  await Tracer.initialize();
  await Tracer.start('compositor_trace.json');

  // We run the application inside runGuarded to guarantee terminal settings restoration.
  await Terminal.runGuarded((terminal) async {
    // 1. Setup alternate screen and clean terminal state
    terminal.enterAlternateScreen();
    terminal.hideCursor();
    terminal
        .enableMouseTracking(); // Enabled to capture drag & click coordinate inputs

    final sceneManager = SceneManager(terminal);

    // 2. Initial Background Layer Widget
    var bgWidget = buildBackgroundWidget(null, sceneManager.layers);

    final bgRunner = PromptRunner<void>(
      terminal: terminal,
      widget: bgWidget,
      mode: ExecutionMode.managed,
      alternateScreen: true,
    );

    final bgLayer = SceneLayer(
      renderer: bgRunner,
      sizing: LayerSizing.fullscreen,
      x: 0,
      y: 0,
      zIndex: 0,
    );

    // 3. The Floating Window Layer
    // Isolated Window widget containing simple text
    late final SceneLayer fgLayer;
    late final PromptRunner<void> fgRunner;

    late final Window windowWidget;
    windowWidget = Window(
      title: 'Compositor Test',
      width: 40,
      height: 15,
      borderStyle: const Style(
        foreground: Colors.green,
        modifiers: Modifier.bold,
      ),
      titleStyle: const Style(
        foreground: Colors.yellow,
        modifiers: Modifier.bold,
      ),
      backgroundStyle: const Style(background: Color(25, 25, 35)),
      onPan: (dx, dy) {
        fgLayer.x += dx;
        fgLayer.y += dy;
        sceneManager.render();
      },
      onResize: (w, h) {
        windowWidget.width = w;
        windowWidget.height = h;
        fgRunner.resize(w, h);
        sceneManager.render();
      },
      child: const Center(
        child: Text('I am floating!', style: Style(foreground: Colors.white)),
      ),
    );

    fgRunner = PromptRunner<void>(
      terminal: terminal,
      widget: windowWidget,
      mode: ExecutionMode.managed,
      alternateScreen: false,
    );

    fgLayer = SceneLayer(
      renderer: fgRunner,
      sizing: LayerSizing.fixed,
      x: 15,
      y: 5,
      zIndex: 10,
      draggable: false,
    );

    // Register layers in the SceneManager
    sceneManager.layers.add(bgLayer);
    sceneManager.layers.add(fgLayer);
    sceneManager.focusedLayer = fgLayer;

    // Start both PromptRunners asynchronously to build elements and mount them
    unawaited(bgRunner.run());
    unawaited(fgRunner.run());

    // Allow a brief moment for size futures and tree mount initialization
    await Future.delayed(const Duration(milliseconds: 20));

    // 4. Boot Sequence: Force initial resizing to draw layouts to layer buffers
    final termSize = await terminal.size;
    bgRunner.resize(termSize.x, termSize.y);
    fgRunner.resize(40, 15);

    // Populate initial background with loaded layer list info
    bgRunner.widget = buildBackgroundWidget(null, sceneManager.layers);
    bgRunner.pump();

    // Paint the first composited frame
    sceneManager.render();

    // Graceful exit & mouse input listener
    final exitCompleter = Completer<void>();
    final subscription = terminal.events.listen((event) {
      if (event is KeyEvent) {
        final isCtrlC =
            event.key == 'c' && event.modifiers.contains(ev.Modifier.control);
        final isQ = event.key == 'q';
        if (isCtrlC || isQ) {
          if (!exitCompleter.isCompleted) {
            exitCompleter.complete();
          }
        }
      } else if (event is MouseEvent) {
        // Update the background runner debug info with current mouse position
        final mousePos = Point<int>(event.x, event.y);
        bgRunner.widget = buildBackgroundWidget(mousePos, sceneManager.layers);
        bgRunner.pump();
        sceneManager.render();
      }
    });

    try {
      await exitCompleter.future;
    } finally {
      await subscription.cancel();
      bgRunner.dispose();
      fgRunner.dispose();
      sceneManager.dispose();
      terminal.exitAlternateScreen();
      terminal.showCursor();
      terminal.disableMouseTracking();
      await Tracer.stop();
    }
  });

  print('Compositor demo completed. Exited cleanly.');
  exit(0);
}
