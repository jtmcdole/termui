import 'dart:async';
import 'dart:math';
import 'package:test/test.dart';
import 'package:termui/terminal/terminal.dart';
import 'package:termui/terminal/backend/terminal_backend.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/widgets/prompt_runner.dart';
import 'package:termui/ui/widgets/scene_manager.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/termui_debug.dart';

class FakeTerminalBackend implements TerminalBackend {
  final List<String> writtenData = [];
  Point<int> currentSize = const Point(80, 24);

  @override
  bool get isWindows => false;

  @override
  Stream<List<int>> get rawInput => const Stream.empty();

  @override
  void write(String data) {
    writtenData.add(data);
  }

  @override
  Point<int> get size => currentSize;

  @override
  Stream<Point<int>> watchSize() => const Stream.empty();

  @override
  void enableRawMode() {}

  @override
  void disableRawMode() {}

  @override
  void dispose() {}
}

class MockTerminal extends Terminal {
  final _eventsController = StreamController<InputEvent>.broadcast();
  final _sizeController = StreamController<Point<int>>.broadcast();

  MockTerminal(super.backend);

  @override
  Stream<InputEvent> get events => _eventsController.stream;

  @override
  Stream<Point<int>> watchSize() => _sizeController.stream;

  void injectTestEvent(InputEvent event) {
    _eventsController.add(event);
  }

  void injectResize(Point<int> newSize) {
    final be = backend;
    if (be is FakeTerminalBackend) {
      be.currentSize = newSize;
    }
    _sizeController.add(newSize);
  }

  @override
  void dispose() {
    _eventsController.close();
    _sizeController.close();
    super.dispose();
  }
}

class MockSceneRenderer implements SceneRenderer {
  @override
  Buffer? currentBuffer;

  @override
  bool showsCursor = false;

  @override
  bool wantsMouseTracking = false;

  @override
  bool wantsAlternateScreen = false;

  @override
  Point<int>? requestedCursorPosition;

  final List<KeyEvent> keyEvents = [];
  final List<MouseEvent> mouseEvents = [];

  @override
  void handleKeyEvent(KeyEvent event) {
    keyEvents.add(event);
  }

  @override
  void handleMouseEvent(MouseEvent event) {
    mouseEvents.add(event);
  }

  void render() {}

  @override
  void resize(int width, int height) {
    currentBuffer?.resize(width, height);
  }
}

void main() {
  group('SceneManager Tests', () {
    late FakeTerminalBackend backend;
    late MockTerminal terminal;
    late SceneManager sceneManager;

    setUp(() {
      backend = FakeTerminalBackend();
      terminal = MockTerminal(backend);
      sceneManager = SceneManager(terminal);
    });

    test('composites overlapping layers correctly', () {
      // Create background layer: 80x24 filled with '.'
      final bgBuffer = Buffer(80, 24);
      for (var y = 0; y < 24; y++) {
        for (var x = 0; x < 80; x++) {
          bgBuffer.setCell(x, y, Cell('.', Style.empty));
        }
      }
      final bgRenderer = MockSceneRenderer()..currentBuffer = bgBuffer;
      final bgLayer = SceneLayer(
        renderer: bgRenderer,
        sizing: LayerSizing.fixed,
        x: 0,
        y: 0,
        zIndex: 0,
      );

      // Create floating layer: 3x3 filled with 'X'
      final fgBuffer = Buffer(3, 3);
      for (var y = 0; y < 3; y++) {
        for (var x = 0; x < 3; x++) {
          fgBuffer.setCell(x, y, Cell('X', Style.empty));
        }
      }
      final fgRenderer = MockSceneRenderer()..currentBuffer = fgBuffer;
      final fgLayer = SceneLayer(
        renderer: fgRenderer,
        sizing: LayerSizing.fixed,
        x: 2,
        y: 2,
        zIndex: 1,
      );

      sceneManager.layers.add(bgLayer);
      sceneManager.layers.add(fgLayer);

      // Perform render
      sceneManager.render();

      final renderer = sceneManager.renderer;
      expect(renderer, isNotNull);

      final front = renderer!.frontBuffer;
      // Coordinates (0, 0) should be background cell '.'
      expect(front.getCell(0, 0)?.char, equals('.'));
      // Coordinates (2, 2) should be overlay cell 'X'
      expect(front.getCell(2, 2)?.char, equals('X'));
      expect(front.getCell(4, 4)?.char, equals('X'));
      // Coordinates (5, 5) should be background cell '.'
      expect(front.getCell(5, 5)?.char, equals('.'));
    });

    test('hardware sync matches the focused layer', () {
      final renderer = MockSceneRenderer()
        ..currentBuffer = Buffer(5, 5)
        ..showsCursor = true
        ..wantsMouseTracking = true
        ..requestedCursorPosition = const Point(1, 1);

      final layer = SceneLayer(
        renderer: renderer,
        sizing: LayerSizing.fixed,
        x: 3,
        y: 3,
        zIndex: 1,
      );

      sceneManager.layers.add(layer);
      sceneManager.focusedLayer = layer;

      sceneManager.render();

      // Verify cursor shown sequence was written
      final written = backend.writtenData.join();
      expect(written, contains(Terminal.showCursorSequence));
      expect(written, contains(Terminal.enableMouseTrackingSequence));

      // Verify goto coordinates (focused.x + pos.x + 1, focused.y + pos.y + 1)
      // absX = 3 + 1 = 4 -> 1-based is 5
      // absY = 3 + 1 = 4 -> 1-based is 5
      // Esc sequence for goto(5, 5) is '\x1b[5;5H'
      expect(written, contains('\x1b[5;5H'));
    });

    test('hardware sync defaults when focused layer is null', () {
      final renderer = MockSceneRenderer()
        ..currentBuffer = Buffer(5, 5)
        ..showsCursor = true
        ..wantsMouseTracking = true;

      final layer = SceneLayer(renderer: renderer, sizing: LayerSizing.fixed);

      sceneManager.layers.add(layer);
      sceneManager.focusedLayer = null;

      sceneManager.render();

      final written = backend.writtenData.join();
      // Should hide cursor and disable mouse tracking
      expect(written, contains(Terminal.hideCursorSequence));
      expect(written, contains(Terminal.disableMouseTrackingSequence));
    });

    test(
      'enables mouse tracking when enableMouseTracking is true, even if renderer wants it false',
      () {
        final renderer = MockSceneRenderer()
          ..currentBuffer = Buffer(5, 5)
          ..showsCursor = false
          ..wantsMouseTracking = false;

        final layer = SceneLayer(renderer: renderer, sizing: LayerSizing.fixed);

        sceneManager.layers.add(layer);
        sceneManager.focusedLayer = layer;
        sceneManager.enableMouseTracking = true;

        sceneManager.render();

        final written = backend.writtenData.join();
        // Should enable mouse tracking because enableMouseTracking is true
        expect(written, contains(Terminal.enableMouseTrackingSequence));
        expect(written, isNot(contains(Terminal.disableMouseTrackingSequence)));
      },
    );

    test('hides cursor if it is requested off-screen', () {
      final renderer = MockSceneRenderer()
        ..currentBuffer = Buffer(5, 5)
        ..showsCursor = true
        ..requestedCursorPosition = const Point(1, 1);

      // Layer positioned so cursor (1,1) is at absolute (80, 0), which is off-screen (width = 80)
      final layer = SceneLayer(
        renderer: renderer,
        sizing: LayerSizing.fixed,
        x: 79,
        y: 0,
      );

      sceneManager.layers.add(layer);
      sceneManager.focusedLayer = layer;

      sceneManager.render();

      final written = backend.writtenData.join();
      // Should hide cursor because it is off-screen (absolute X = 79 + 1 = 80 which is >= width 80)
      expect(written, contains(Terminal.hideCursorSequence));
      // Should not contain the goto ESC code \x1b[1;81H
      expect(written, isNot(contains('\x1b[1;81H')));
    });

    test('reuses and resizes targetBuffer on terminal resize', () {
      final renderer = MockSceneRenderer()..currentBuffer = Buffer(5, 5);
      final layer = SceneLayer(renderer: renderer, sizing: LayerSizing.fixed);
      sceneManager.layers.add(layer);

      // First render at 80x24
      sceneManager.render();

      // Resize terminal backend
      backend.currentSize = const Point(100, 30);
      sceneManager.render();

      expect(sceneManager.renderer!.frontBuffer.width, equals(100));
      expect(sceneManager.renderer!.frontBuffer.height, equals(30));
    });

    test('dispose cleans up and restores terminal state', () {
      final renderer = MockSceneRenderer()
        ..currentBuffer = Buffer(5, 5)
        ..showsCursor =
            false // hides cursor
        ..wantsMouseTracking = true; // enables mouse tracking

      final layer = SceneLayer(renderer: renderer, sizing: LayerSizing.fixed);
      sceneManager.layers.add(layer);
      sceneManager.focusedLayer = layer;

      sceneManager.render();

      // Clear written history
      backend.writtenData.clear();

      sceneManager.dispose();

      final written = backend.writtenData.join();
      // Should show cursor and disable mouse tracking upon disposal
      expect(written, contains(Terminal.showCursorSequence));
      expect(written, contains(Terminal.disableMouseTrackingSequence));
    });

    test('routes resize event and updates fullscreen layers', () async {
      final bgBuffer = Buffer(5, 5);
      final bgRenderer = MockSceneRenderer()..currentBuffer = bgBuffer;
      final bgLayer = SceneLayer(
        renderer: bgRenderer,
        sizing: LayerSizing.fullscreen,
        x: 2,
        y: 2,
        zIndex: 0,
      );

      final fgBuffer = Buffer(3, 3);
      final fgRenderer = MockSceneRenderer()..currentBuffer = fgBuffer;
      final fgLayer = SceneLayer(
        renderer: fgRenderer,
        sizing: LayerSizing.fixed,
        x: 10,
        y: 10,
        zIndex: 1,
      );

      sceneManager.layers.add(bgLayer);
      sceneManager.layers.add(fgLayer);

      // Inject terminal resize event
      terminal.injectResize(const Point(90, 30));

      await Future.delayed(Duration.zero);

      // Fullscreen layer should be moved to (0,0) and resized
      expect(bgLayer.x, equals(0));
      expect(bgLayer.y, equals(0));
      expect(bgBuffer.width, equals(90));
      expect(bgBuffer.height, equals(30));

      // Fixed layer should remain unchanged
      expect(fgLayer.x, equals(10));
      expect(fgLayer.y, equals(10));
      expect(fgBuffer.width, equals(3));
      expect(fgBuffer.height, equals(3));
    });

    test('routes key events to focused layer', () async {
      final bgRenderer = MockSceneRenderer()..currentBuffer = Buffer(80, 24);
      final bgLayer = SceneLayer(
        renderer: bgRenderer,
        sizing: LayerSizing.fixed,
      );

      final fgRenderer = MockSceneRenderer()..currentBuffer = Buffer(10, 10);
      final fgLayer = SceneLayer(
        renderer: fgRenderer,
        sizing: LayerSizing.fixed,
      );

      sceneManager.layers.add(bgLayer);
      sceneManager.layers.add(fgLayer);

      // Focus bg layer
      sceneManager.focusedLayer = bgLayer;

      // Inject key event
      final keyEvent1 = const KeyEvent('a', KeyType.character);
      terminal.injectTestEvent(keyEvent1);

      await Future.delayed(Duration.zero);

      expect(bgRenderer.keyEvents, contains(keyEvent1));
      expect(fgRenderer.keyEvents, isEmpty);

      // Shift focus to fg layer
      sceneManager.focusedLayer = fgLayer;
      final keyEvent2 = const KeyEvent('b', KeyType.character);
      terminal.injectTestEvent(keyEvent2);

      await Future.delayed(Duration.zero);

      expect(bgRenderer.keyEvents, hasLength(1));
      expect(fgRenderer.keyEvents, contains(keyEvent2));
    });

    test('routes mouse events, performs hit-testing, and shifts focus', () async {
      final bgRenderer = MockSceneRenderer()..currentBuffer = Buffer(80, 24);
      final bgLayer = SceneLayer(
        renderer: bgRenderer,
        sizing: LayerSizing.fixed,
        x: 0,
        y: 0,
        zIndex: 0,
      );

      final fgRenderer = MockSceneRenderer()..currentBuffer = Buffer(10, 10);
      final fgLayer = SceneLayer(
        renderer: fgRenderer,
        sizing: LayerSizing.fixed,
        x: 10,
        y: 10,
        zIndex: 1,
      );

      sceneManager.layers.add(bgLayer);
      sceneManager.layers.add(fgLayer);

      // Start with fg focused
      sceneManager.focusedLayer = fgLayer;

      // 1. Mouse click at (5, 5) 1-based (which is global 0-based (4, 4))
      // This is on the bg layer only. It should shift focus to bg.
      final clickBg = const MouseEvent(
        x: 5,
        y: 5,
        button: MouseButton.left,
        type: MouseEventType.press,
      );
      terminal.injectTestEvent(clickBg);

      await Future.delayed(Duration.zero);

      expect(sceneManager.focusedLayer, equals(bgLayer));

      // Click should be translated into local coordinates for bg:
      // global 0-based is (4, 4). bg is at (0, 0) -> local 0-based is (4, 4) -> 1-based local is (5, 5).
      expect(bgRenderer.mouseEvents, hasLength(1));
      expect(bgRenderer.mouseEvents.first.x, equals(5));
      expect(bgRenderer.mouseEvents.first.y, equals(5));
      expect(fgRenderer.mouseEvents, isEmpty);

      // 2. Mouse click at (13, 13) 1-based (which is global 0-based (12, 12))
      // This is inside the bounding box of fg: (10, 10) to (20, 20).
      // Since fg is topmost (zIndex: 1), it should shift focus back to fg.
      final clickFg = const MouseEvent(
        x: 13,
        y: 13,
        button: MouseButton.left,
        type: MouseEventType.press,
      );
      terminal.injectTestEvent(clickFg);

      await Future.delayed(Duration.zero);

      expect(sceneManager.focusedLayer, equals(fgLayer));

      // Click should be translated into local coordinates for fg:
      // global 0-based is (12, 12). fg is at (10, 10) -> local 0-based is (2, 2) -> 1-based local is (3, 3).
      expect(fgRenderer.mouseEvents, hasLength(1));
      expect(fgRenderer.mouseEvents.first.x, equals(3));
      expect(fgRenderer.mouseEvents.first.y, equals(3));
    });

    test('dragging a draggable layer updates its coordinates', () async {
      final renderer = MockSceneRenderer()..currentBuffer = Buffer(5, 5);
      final layer = SceneLayer(
        renderer: renderer,
        sizing: LayerSizing.fixed,
        x: 10,
        y: 10,
        draggable: true,
      );

      sceneManager.layers.add(layer);

      // 1. Press at global 1-based (12, 12) -> hit-test succeeds
      final pressEvent = const MouseEvent(
        x: 12,
        y: 12,
        button: MouseButton.left,
        type: MouseEventType.press,
      );
      terminal.injectTestEvent(pressEvent);

      await Future.delayed(Duration.zero);

      // 2. Drag to global 1-based (15, 17) -> dx = 3, dy = 5
      final dragEvent = const MouseEvent(
        x: 15,
        y: 17,
        button: MouseButton.left,
        type: MouseEventType.drag,
      );
      terminal.injectTestEvent(dragEvent);

      await Future.delayed(Duration.zero);

      // Layer position should be updated: x = 10 + 3 = 13, y = 10 + 5 = 15
      expect(layer.x, equals(13));
      expect(layer.y, equals(15));

      // 3. Release mouse
      final releaseEvent = const MouseEvent(
        x: 15,
        y: 17,
        button: MouseButton.left,
        type: MouseEventType.release,
      );
      terminal.injectTestEvent(releaseEvent);

      await Future.delayed(Duration.zero);

      // Dragging should be cleared: subsequent drag should do nothing
      final dragEvent2 = const MouseEvent(
        x: 20,
        y: 20,
        button: MouseButton.left,
        type: MouseEventType.drag,
      );
      terminal.injectTestEvent(dragEvent2);

      await Future.delayed(Duration.zero);

      expect(layer.x, equals(13));
      expect(layer.y, equals(15));
    });

    test(
      'mouse events are captured by the pressed layer even if dragging/releasing outside',
      () async {
        final renderer = MockSceneRenderer()..currentBuffer = Buffer(5, 5);
        final layer = SceneLayer(
          renderer: renderer,
          sizing: LayerSizing.fixed,
          x: 10,
          y: 10,
          draggable: false,
        );

        sceneManager.layers.add(layer);

        // Press at global 1-based (12, 12) -> inside layer (10, 10) to (15, 15)
        terminal.injectTestEvent(
          const MouseEvent(
            x: 12,
            y: 12,
            button: MouseButton.left,
            type: MouseEventType.press,
          ),
        );
        await Future.delayed(Duration.zero);

        // Drag to global 1-based (5, 5) -> outside layer
        terminal.injectTestEvent(
          const MouseEvent(
            x: 5,
            y: 5,
            button: MouseButton.left,
            type: MouseEventType.drag,
          ),
        );
        await Future.delayed(Duration.zero);

        // Release at global 1-based (6, 6) -> outside layer
        terminal.injectTestEvent(
          const MouseEvent(
            x: 6,
            y: 6,
            button: MouseButton.left,
            type: MouseEventType.release,
          ),
        );
        await Future.delayed(Duration.zero);

        // Verify all 3 events routed to the layer
        expect(renderer.mouseEvents, hasLength(3));
        expect(renderer.mouseEvents[0].type, equals(MouseEventType.press));
        expect(
          renderer.mouseEvents[0].x,
          equals(2),
        ); // local 1-based (12 - 10) = 2
        expect(renderer.mouseEvents[0].y, equals(2));

        expect(renderer.mouseEvents[1].type, equals(MouseEventType.drag));
        expect(
          renderer.mouseEvents[1].x,
          equals(-5),
        ); // local 1-based (5 - 10) = -5
        expect(renderer.mouseEvents[1].y, equals(-5));

        expect(renderer.mouseEvents[2].type, equals(MouseEventType.release));
        expect(
          renderer.mouseEvents[2].x,
          equals(-4),
        ); // local 1-based (6 - 10) = -4
        expect(renderer.mouseEvents[2].y, equals(-4));
      },
    );

    test(
      'renders layer borders when debugPaintLayerBordersEnabled is true',
      () {
        debugPaintLayerBordersEnabled = true;
        addTearDown(() {
          debugPaintLayerBordersEnabled = false;
        });

        final layerBuf = Buffer(5, 5);
        // Fill layer buffer with 'a'
        for (var y = 0; y < 5; y++) {
          for (var x = 0; x < 5; x++) {
            layerBuf.setCell(x, y, Cell('a', Style.empty));
          }
        }

        final renderer = MockSceneRenderer()..currentBuffer = layerBuf;
        final layer = SceneLayer(
          renderer: renderer,
          sizing: LayerSizing.fixed,
          x: 2,
          y: 2,
          zIndex: 1,
        );

        sceneManager.layers.add(layer);
        sceneManager.render();

        final target = sceneManager.renderer!.frontBuffer;
        // Borders should be drawn at x: 2..6, y: 2..6.
        // Corners:
        // (2, 2) is '┌'
        // (6, 2) is '┐'
        // (2, 6) is '└'
        // (6, 6) is '┘'
        expect(target.getCell(2, 2)?.char, equals('┌'));
        expect(target.getCell(6, 2)?.char, equals('┐'));
        expect(target.getCell(2, 6)?.char, equals('└'));
        expect(target.getCell(6, 6)?.char, equals('┘'));

        // The border style should have foreground yellow
        expect(target.getCell(2, 2)?.style.foreground, equals(Colors.yellow));

        // Inside cell (e.g. 3, 3) should still be 'a' from layer buffer
        expect(target.getCell(3, 3)?.char, equals('a'));
      },
    );

    test(
      'renders mouse cursor overlay when debugMouseCursorEnabled is true',
      () async {
        debugMouseCursorEnabled = true;
        addTearDown(() {
          debugMouseCursorEnabled = false;
        });

        final layerBuf = Buffer(10, 10);
        final renderer = MockSceneRenderer()..currentBuffer = layerBuf;
        final layer = SceneLayer(
          renderer: renderer,
          sizing: LayerSizing.fixed,
          x: 0,
          y: 0,
        );

        sceneManager.layers.add(layer);
        sceneManager.render();

        // 1. Move/Press mouse to global 1-based (5, 5) -> global 0-based (4, 4)
        terminal.injectTestEvent(
          const MouseEvent(
            x: 5,
            y: 5,
            button: MouseButton.left,
            type: MouseEventType.press,
          ),
        );
        await Future.delayed(Duration.zero);

        var target = sceneManager.renderer!.frontBuffer;
        // Cell at (4, 4) should be '⦿' with bright red color (since button is down)
        expect(target.getCell(4, 4)?.char, equals('⦿'));
        expect(
          target.getCell(4, 4)?.style.foreground,
          equals(const Color(255, 0, 0)),
        );

        // 2. Move mouse to global 1-based (8, 8) with button up (move event) -> global 0-based (7, 7)
        terminal.injectTestEvent(
          const MouseEvent(
            x: 8,
            y: 8,
            button: MouseButton.none,
            type: MouseEventType.move,
          ),
        );
        await Future.delayed(Duration.zero);

        target = sceneManager.renderer!.frontBuffer;
        // Cell at (7, 7) should be '⦿' with bright cyan color (since button is up)
        expect(target.getCell(7, 7)?.char, equals('⦿'));
        expect(
          target.getCell(7, 7)?.style.foreground,
          equals(const Color(0, 255, 255)),
        );
      },
    );

    test('stable layer ordering and composition when zIndex is equal', () {
      // Create two layers with identical zIndex
      final l1Buffer = Buffer(5, 5);
      l1Buffer.fill(Cell('1', Style.empty));
      final l1Renderer = MockSceneRenderer()..currentBuffer = l1Buffer;
      final layer1 = SceneLayer(
        renderer: l1Renderer,
        sizing: LayerSizing.fixed,
        x: 0,
        y: 0,
        zIndex: 5,
      );

      final l2Buffer = Buffer(5, 5);
      l2Buffer.fill(Cell('2', Style.empty));
      final l2Renderer = MockSceneRenderer()..currentBuffer = l2Buffer;
      final layer2 = SceneLayer(
        renderer: l2Renderer,
        sizing: LayerSizing.fixed,
        x: 2,
        y: 2,
        zIndex: 5, // Same zIndex
      );

      // Add to sceneManager in order: layer1 then layer2.
      // Since layer2 is added later, it should sit on top of layer1.
      sceneManager.layers.add(layer1);
      sceneManager.layers.add(layer2);

      sceneManager.render();
      final target = sceneManager.renderer!.frontBuffer;

      // Overlap area at (2, 2) to (4, 4) should be '2', not '1'.
      expect(target.getCell(2, 2)?.char, equals('2'));
      expect(target.getCell(4, 4)?.char, equals('2'));

      // If we reverse the insertion order but keep identical zIndex
      sceneManager.layers.clear();
      sceneManager.layers.add(layer2);
      sceneManager.layers.add(layer1);

      sceneManager.render();
      final target2 = sceneManager.renderer!.frontBuffer;

      // Now layer1 is added later, so it should sit on top of layer2.
      // Overlap area at (2, 2) to (4, 4) should be '1', not '2'.
      expect(target2.getCell(2, 2)?.char, equals('1'));
      expect(target2.getCell(4, 4)?.char, equals('1'));
    });

    test('cleans up references to orphaned layers', () async {
      final renderer = MockSceneRenderer()..currentBuffer = Buffer(5, 5);
      final layer = SceneLayer(
        renderer: renderer,
        sizing: LayerSizing.fixed,
        x: 0,
        y: 0,
        draggable: true,
      );

      sceneManager.layers.add(layer);
      sceneManager.focusedLayer = layer;

      // Render first to initialize the renderer
      sceneManager.render();
      expect(sceneManager.renderer, isNotNull);

      // Simulate a press to set captured and dragging layers
      terminal.injectTestEvent(
        const MouseEvent(
          x: 1,
          y: 1,
          button: MouseButton.left,
          type: MouseEventType.press,
        ),
      );
      await Future.delayed(Duration.zero);

      expect(sceneManager.focusedLayer, equals(layer));

      // Now remove the layer from sceneManager.layers
      sceneManager.layers.remove(layer);

      // Triggering render or an event should clean them up
      sceneManager.render();

      expect(sceneManager.focusedLayer, isNull);
    });

    test('visual debug borders respect z-index occlusion', () {
      debugPaintLayerBordersEnabled = true;
      addTearDown(() {
        debugPaintLayerBordersEnabled = false;
      });

      // Bottom layer: 10x10 filled with '1', zIndex: 0
      final l1Buffer = Buffer(10, 10);
      l1Buffer.fill(Cell('1', Style.empty));
      final l1Renderer = MockSceneRenderer()..currentBuffer = l1Buffer;
      final layer1 = SceneLayer(
        renderer: l1Renderer,
        sizing: LayerSizing.fixed,
        x: 0,
        y: 0,
        zIndex: 0,
      );

      // Top layer: 5x5 filled with '2', zIndex: 10, positioned at x: 6, y: 6.
      // Its borders will be at local edges (x=6, x=10, y=6, y=10).
      // Global (9, 7) corresponds to local coordinates on layer2 of (lx=3, ly=1), which is in the interior.
      final l2Buffer = Buffer(5, 5);
      l2Buffer.fill(Cell('2', Style.empty));
      final l2Renderer = MockSceneRenderer()..currentBuffer = l2Buffer;
      final layer2 = SceneLayer(
        renderer: l2Renderer,
        sizing: LayerSizing.fixed,
        x: 6,
        y: 6,
        zIndex: 10,
      );

      sceneManager.layers.add(layer1);
      sceneManager.layers.add(layer2);

      sceneManager.render();
      final target = sceneManager.renderer!.frontBuffer;

      // The border of layer1 at (9, 7) would normally draw vertical border line '│'.
      // But layer2 is on top (zIndex 10) and covers (9, 7) with its interior content '2'.
      // Therefore, the border of layer1 at (9, 7) must be occluded by layer2's content ('2').
      expect(target.getCell(9, 7)?.char, equals('2'));

      // Also check a non-occluded border coordinate of layer1: e.g. (9, 0)
      // Since it's not occluded, it should render as a border corner '┐'
      expect(target.getCell(9, 0)?.char, equals('┐'));
    });
  });
}
