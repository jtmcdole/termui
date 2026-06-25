import 'dart:async';
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
      () async {
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
        expect(activeBuffer!.getCharacter(0, 1), equals('┌'));
        expect(
          Color.argb(activeBuffer.getForeground(0, 1)),
          equals(const Color(255, 0, 255)),
        );

        // The badge ' SizedBox ' should start at (1, 4) due to expanded bounds
        // Check character 'S' at (2, 4)
        expect(activeBuffer.getCharacter(2, 4), equals('S'));
        expect(
          Color.argb(activeBuffer.getForeground(2, 4)),
          equals(const Color(255, 255, 255)),
        );
        expect(
          Color.argb(activeBuffer.getBackground(2, 4)),
          equals(const Color(255, 0, 255)),
        );

        // Abort runner
        runner.abort();
        await future.catchError((_) {});

        expect(terminal.mouseTrackingEnabled, isFalse);
      },
    );
  });
}
