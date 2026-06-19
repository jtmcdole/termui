import 'dart:async';
import 'dart:math';
import 'package:test/test.dart';
import 'package:termui/termui.dart';
import 'package:termui/ui/window.dart';
import '../example/compositor_demo.dart';

import 'package:termui_test/termui_test.dart';

void main() {
  group('Compositor Demo Integration Tests', () {
    late MockTerminalBackend backend;
    late MockTerminal terminal;
    late SceneManager sceneManager;

    setUp(() {
      backend = MockTerminalBackend();
      terminal = MockTerminal(backend);
      sceneManager = SceneManager(terminal);
    });

    tearDown(() {
      sceneManager.dispose();
      terminal.dispose();
    });

    test('compositor demo setup and window dragging', () async {
      // 1. Setup background layer
      final bgWidget = buildBackgroundWidget(null, sceneManager.layers);
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

      // 2. Setup floating window layer (matching demo coordinates: x=15, y=5, bounds=40x15)
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
        draggable: true,
      );

      sceneManager.layers.add(bgLayer);
      sceneManager.layers.add(fgLayer);
      sceneManager.focusedLayer = fgLayer;

      // Start the runners
      unawaited(bgRunner.run());
      unawaited(fgRunner.run());

      // Wait for layout initialization
      await Future.delayed(const Duration(milliseconds: 10));

      bgRunner.resize(80, 24);
      fgRunner.resize(40, 15);

      // Re-build background with correct initial layers state
      bgRunner.widget = buildBackgroundWidget(null, sceneManager.layers);
      bgRunner.pump();

      // Paint initial frame
      sceneManager.render();

      // Initial positions validation
      expect(bgLayer.x, equals(0));
      expect(bgLayer.y, equals(0));
      expect(fgLayer.x, equals(15));
      expect(fgLayer.y, equals(5));

      // Check that mouse position debug text is initially "no event"
      // Verify by checking if the background buffer contains the debug text
      final bgBuf = bgRunner.currentBuffer!;
      final bufferContent = StringBuffer();
      for (var y = 0; y < bgBuf.height; y++) {
        for (var x = 0; x < bgBuf.width; x++) {
          bufferContent.write(bgBuf.getCell(x, y)?.char ?? ' ');
        }
      }
      expect(
        bufferContent.toString(),
        contains('Mouse Position (1-based): no event'),
      );
      expect(
        bufferContent.toString(),
        contains(
          'Layer 1 - zIndex: 10, bounds: Rect(15, 5, 40, 15), draggable: true',
        ),
      );

      // 3. Inject Mouse Press at 1-based (20, 7) which is global 0-based (19, 6)
      // This is inside the fg window bounds (15 <= 19 < 55, 5 <= 6 < 20).
      terminal.injectTestEvent(
        const MouseEvent(
          x: 20,
          y: 7,
          button: MouseButton.left,
          type: MouseEventType.press,
        ),
      );

      await Future.delayed(Duration.zero);

      // Trigger listener in demo
      final mousePos = const Point<int>(20, 7);
      bgRunner.widget = buildBackgroundWidget(mousePos, sceneManager.layers);
      bgRunner.pump();
      sceneManager.render();

      // 4. Inject Mouse Drag to 1-based (25, 9) which is global 0-based (24, 8)
      // dx = 25 - 20 = 5, dy = 9 - 7 = 2.
      terminal.injectTestEvent(
        const MouseEvent(
          x: 25,
          y: 9,
          button: MouseButton.left,
          type: MouseEventType.drag,
        ),
      );

      await Future.delayed(Duration.zero);

      // Trigger listener in demo for the drag event
      final dragPos = const Point<int>(25, 9);
      bgRunner.widget = buildBackgroundWidget(dragPos, sceneManager.layers);
      bgRunner.pump();
      sceneManager.render();

      // Verify that the floating window layer was successfully dragged by dx=5, dy=2
      // x = 15 + 5 = 20
      // y = 5 + 2 = 7
      expect(fgLayer.x, equals(20));
      expect(fgLayer.y, equals(7));

      // Check that mouse position and layer bounds updated in the printed buffer
      final updatedBgBuf = bgRunner.currentBuffer!;
      final updatedContent = StringBuffer();
      for (var y = 0; y < updatedBgBuf.height; y++) {
        for (var x = 0; x < updatedBgBuf.width; x++) {
          updatedContent.write(updatedBgBuf.getCell(x, y)?.char ?? ' ');
        }
      }
      expect(
        updatedContent.toString(),
        contains('Mouse Position (1-based): x: 25, y: 9'),
      );
      expect(
        updatedContent.toString(),
        contains(
          'Layer 1 - zIndex: 10, bounds: Rect(20, 7, 40, 15), draggable: true',
        ),
      );

      // 5. Inject a second Mouse Drag to 1-based (28, 10) which is global 0-based (27, 9)
      // dx = 28 - 25 = 3, dy = 10 - 9 = 1.
      // Total delta from start should be: x = 20 + 3 = 23, y = 7 + 1 = 8.
      terminal.injectTestEvent(
        const MouseEvent(
          x: 28,
          y: 10,
          button: MouseButton.left,
          type: MouseEventType.drag,
        ),
      );

      await Future.delayed(Duration.zero);

      // Trigger listener in demo for the second drag event
      final dragPos2 = const Point<int>(28, 10);
      bgRunner.widget = buildBackgroundWidget(dragPos2, sceneManager.layers);
      bgRunner.pump();
      sceneManager.render();

      // Verify that the floating window layer was successfully dragged by another dx=3, dy=1
      // x = 20 + 3 = 23
      // y = 7 + 1 = 8
      expect(fgLayer.x, equals(23));
      expect(fgLayer.y, equals(8));

      // Check that mouse position and layer bounds updated in the printed buffer again
      final finalBgBuf = bgRunner.currentBuffer!;
      final finalContent = StringBuffer();
      for (var y = 0; y < finalBgBuf.height; y++) {
        for (var x = 0; x < finalBgBuf.width; x++) {
          finalContent.write(finalBgBuf.getCell(x, y)?.char ?? ' ');
        }
      }
      expect(
        finalContent.toString(),
        contains('Mouse Position (1-based): x: 28, y: 10'),
      );
      expect(
        finalContent.toString(),
        contains(
          'Layer 1 - zIndex: 10, bounds: Rect(23, 8, 40, 15), draggable: true',
        ),
      );
    });
  });
}
