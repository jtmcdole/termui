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
    debugPaintHoverEnabled = false;
  });

  tearDown(() {
    debugPaintHoverEnabled = false;
    terminal.dispose();
  });

  group('Visual Debug Overlays', () {
    test(
      'debugPaintHoverEnabled enables mouse tracking and highlights hovered leaf element with a magenta border and a badge',
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

        // Top-left corner of the hovered SizedBox is at (0, 1) due to expanded bounds
        final cornerCell = activeBuffer!.getCell(0, 1);
        expect(cornerCell, isNotNull);
        expect(cornerCell!.char, equals('┌'));
        expect(cornerCell.style.foreground, equals(const Color(255, 0, 255)));

        // The badge ' SizedBox ' should start at (1, 4) due to expanded bounds
        // Check character 'S' at (2, 4)
        final charCell = activeBuffer.getCell(2, 4);
        expect(charCell, isNotNull);
        expect(charCell!.char, equals('S'));
        expect(charCell.style.foreground, equals(const Color(255, 255, 255)));
        expect(charCell.style.background, equals(const Color(255, 0, 255)));

        // Abort runner
        runner.abort();
        await future.catchError((_) {});

        expect(terminal.mouseTrackingEnabled, isFalse);
      },
    );
  });
}
