import 'dart:async';
import 'dart:math';
import 'package:test/test.dart';
import 'package:termui/terminal/terminal.dart';
import 'package:termui/terminal/backend/terminal_backend.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/widgets/prompt_runner.dart';
import 'package:termui/ui/widgets/scene_manager.dart';
import 'package:termui/ui/style.dart';

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
  });
}
