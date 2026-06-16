import 'dart:async';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:termui/terminal/backend/terminal_backend.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/ui/event.dart';
import 'package:termui/ui/ui.dart';
import 'package:termui/ui/window.dart';
import 'package:test/test.dart';

import '../example/02_progress_bars.dart';

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

class MockTerminal extends term.Terminal {
  final _eventsController = StreamController<InputEvent>.broadcast();
  final _sizeController = StreamController<Point<int>>.broadcast();

  MockTerminal(super.backend);

  @override
  Stream<InputEvent> get events => _eventsController.stream;

  @override
  Stream<Point<int>> watchSize() => _sizeController.stream;

  @override
  void dispose() {
    _eventsController.close();
    _sizeController.close();
    super.dispose();
  }
}

void main() {
  group('Progress Bars Example Tests', () {
    late FakeTerminalBackend backend;
    late MockTerminal terminal;

    setUp(() {
      backend = FakeTerminalBackend();
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
