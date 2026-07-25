import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:termui/termui.dart';
import 'package:termui/ui/event.dart' as ui;

import 'package:termui_test/termui_test.dart';

void main() {
  late MockTerminalBackend backend;
  late MockTerminal terminal;

  setUp(() {
    backend = MockTerminalBackend();
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
      () {
        fakeAsync((async) {
          debugPaintHoverEnabled = true;

          // We use a small column of a few widgets
          final runner = PromptRunner<void>(
            terminal: terminal,
            widget: SizedBox(
              height: 10,
              child: Column([
                const SizedBox(width: 10, height: 2),
                const SizedBox(width: 10, height: 2),
              ]),
            ),
            alternateScreen: true,
          );

          final future = runner.run();
          async.elapse(const Duration(milliseconds: 10));

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

          async.elapse(const Duration(milliseconds: 10));

          // The runner should have completed a redraw.
          final activeBuffer = backend.buffer;
          expect(activeBuffer, isNotNull);

          // Top-left corner of the hovered SizedBox is off-screen at x = -1; row y = 1 contains top border line '─'
          expect(activeBuffer!.getCharacter(0, 1), equals('─'));
          expect(
            Color.argb(activeBuffer.getForeground(0, 1)),
            equals(const Color(255, 0, 255)),
          );

          // The badge ' SizedBox ' should start at (0, 4)
          // Check character 'S' at (1, 4)
          expect(activeBuffer.getCharacter(1, 4), equals('S'));
          expect(
            Color.argb(activeBuffer.getForeground(1, 4)),
            equals(const Color(255, 255, 255)),
          );
          expect(
            Color.argb(activeBuffer.getBackground(1, 4)),
            equals(const Color(255, 0, 255)),
          );

          // Abort runner
          runner.abort();
          future.catchError((_) => null);
          async.flushMicrotasks();

          expect(terminal.mouseTrackingEnabled, isFalse);
        });
      },
    );

    test(
      'clips out-of-bounds hover border off-screen without overwriting edge element at (0,0)',
      () {
        fakeAsync((async) {
          debugPaintHoverEnabled = true;

          final runner = PromptRunner<void>(
            terminal: terminal,
            widget: Stack([
              const Positioned(
                left: 0,
                top: 0,
                child: SizedBox(width: 1, height: 1, child: Text('X')),
              ),
            ]),
            alternateScreen: true,
          );

          final future = runner.run();
          async.elapse(const Duration(milliseconds: 10));

          // Hover over (x: 1, y: 1) -> 0-based (0, 0)
          terminal.injectTestEvent(
            ui.MouseEvent(
              x: 1,
              y: 1,
              type: ui.MouseEventType.move,
              button: ui.MouseButton.none,
            ),
          );

          async.elapse(const Duration(milliseconds: 10));

          final activeBuffer = backend.buffer;
          expect(activeBuffer, isNotNull);

          // Element content 'X' at (0, 0) MUST remain intact! (not overwritten with '┌')
          expect(activeBuffer!.getCharacter(0, 0), equals('X'));

          // Right border at (1, 0) is '│'
          expect(activeBuffer.getCharacter(1, 0), equals('│'));
          // Row y = 1 contains the badge ' TextElement '; character at (1, 1) is 'T'
          expect(activeBuffer.getCharacter(1, 1), equals('T'));

          runner.abort();
          future.catchError((_) => null);
          async.flushMicrotasks();
        });
      },
    );
  });
}
