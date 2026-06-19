import 'package:fake_async/fake_async.dart';
import 'package:termui/termui.dart';
import 'package:test/test.dart';

import '../example/02_progress_bars.dart';

import 'package:termui_test/termui_test.dart';

void main() {
  group('Progress Bars Example Tests', () {
    late MockTerminalBackend backend;
    late MockTerminal terminal;

    setUp(() {
      backend = MockTerminalBackend();
      terminal = MockTerminal(backend);
      FocusManager.instance.setPrimaryFocus(null);
    });

    tearDown(() {
      terminal.dispose();
      FocusManager.instance.setPrimaryFocus(null);
    });

    test('BuildDashboard completes and disposes cleanly in fake time', () {
      fakeAsync((async) {
        final runner = PromptRunner<void>(
          terminal: terminal,
          widget: const BuildDashboard(totalDurationMs: 1000),
          mode: ExecutionMode.managed,
        );

        bool completed = false;
        Object? error;
        runner.run().then(
          (_) {
            completed = true;
          },
          onError: (e) {
            error = e;
          },
        );

        // Run the initial frame draw / microtasks.
        async.flushMicrotasks();

        // Initially we are in Task 1 (elapsed < 3000, since duration is 1000)
        expect(runner.currentBuffer, isNotNull);

        // Advance time to 500ms
        async.elapse(const Duration(milliseconds: 500));
        expect(completed, isFalse);

        // Advance time to 1500ms total (completes totalDurationMs and runs next timer tick)
        async.elapse(const Duration(milliseconds: 1000));
        async.flushMicrotasks();

        expect(completed, isTrue);
        expect(error, isNull);
        expect(runner.isDisposed, isTrue);
      });
    });
  });
}
