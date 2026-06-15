import 'dart:async';
import 'package:test/test.dart';
import 'package:termui/termui.dart';
import 'package:termui/ui/event.dart' as ui;
import 'package:termui/terminal/backend/terminal_backend.dart';
import 'dart:math';

class FakeTerminalBackend implements TerminalBackend {
  final List<String> writtenData = [];
  Buffer? buffer;

  @override
  bool get isWindows => false;

  @override
  Stream<List<int>> get rawInput => const Stream.empty();

  @override
  void write(String data) {
    writtenData.add(data);
  }

  @override
  Point<int> get size => const Point(80, 24);

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
  final _eventsController = StreamController<ui.InputEvent>.broadcast();
  bool isCursorVisible = true;
  bool mouseTrackingEnabled = false;

  MockTerminal(super.backend);

  @override
  Stream<ui.InputEvent> get events => _eventsController.stream;

  void injectTestEvent(ui.InputEvent event) {
    _eventsController.add(event);
  }

  @override
  void enableMouseTracking() {
    mouseTrackingEnabled = true;
    super.enableMouseTracking();
  }

  @override
  void disableMouseTracking() {
    mouseTrackingEnabled = false;
    super.disableMouseTracking();
  }
}

void main() {
  late FakeTerminalBackend backend;
  late MockTerminal terminal;

  setUp(() {
    backend = FakeTerminalBackend();
    terminal = MockTerminal(backend);
    debugPaintSizeEnabled = false;
    debugPaintHoverEnabled = false;
  });

  tearDown(() {
    debugPaintSizeEnabled = false;
    debugPaintHoverEnabled = false;
    terminal.dispose();
  });

  group('Visual Debug Overlays', () {
    test('debugPaintSizeEnabled draws boxes around widgets', () {
      debugPaintSizeEnabled = true;

      final widget = const SizedBox(width: 5, height: 3);
      final element = widget.createElement();
      element.mount(null);
      element.layout(const BoxConstraints(maxWidth: 5, maxHeight: 3));

      final buffer = Buffer.blank(5, 3);
      element.paint(buffer, Offset.zero);

      // Now we print it via printWidget which uses printWidget extension
      terminal.printWidget(widget);

      // Since printWidget uses _drawElementOutlines, the printed buffer should have box drawing chars:
      // ┌ ─── ┐
      // │     │
      // └ ─── ┘
      final written = backend.writtenData.join();
      expect(written, contains('┌'));
      expect(written, contains('┐'));
      expect(written, contains('└'));
      expect(written, contains('┘'));
      expect(written, contains('─'));
      expect(written, contains('│'));
    });

    test(
      'debugPaintHoverEnabled enables mouse tracking and highlights hovered leaf element',
      () async {
        debugPaintHoverEnabled = true;

        // We use a small column of a few widgets
        final runner = PromptRunner<void>(
          terminal: terminal,
          widget: Column([
            const SizedBox(width: 10, height: 2),
            const SizedBox(width: 10, height: 2),
          ]),
          height: 10,
          alternateScreen: true,
        );

        final future = runner.run();
        await Future.delayed(const Duration(milliseconds: 10));

        expect(terminal.mouseTrackingEnabled, isTrue);

        // Inject a mouse move event over the second sized box
        // Second sized box is at y: 2 (0-based) because first sized box has height 2.
        // Mouse coordinates are 1-based, so y = 3 (which translates to y = 2 in 0-based), x = 5.
        terminal.injectTestEvent(
          ui.MouseEvent(
            x: 5,
            y: 3,
            type: ui.MouseEventType.move,
            button: ui.MouseButton.none,
          ),
        );

        await Future.delayed(const Duration(milliseconds: 10));

        // The runner should have completed a redraw.
        final activeBuffer = backend.buffer;
        expect(activeBuffer, isNotNull);

        // Let's verify the cell at (5, 2) has a Magenta background.
        final cell = activeBuffer!.getCell(5, 2);
        expect(cell, isNotNull);
        expect(cell!.style.background, equals(const Color(255, 0, 255)));

        // Abort runner
        runner.abort();
        await future.catchError((_) {});

        expect(terminal.mouseTrackingEnabled, isFalse);
      },
    );
  });
}
