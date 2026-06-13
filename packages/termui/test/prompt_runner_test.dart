import 'dart:async';
import 'dart:math';
import 'package:test/test.dart';
import 'package:termui/terminal/terminal.dart';
import 'package:termui/terminal/backend/terminal_backend.dart';
import 'package:termui/ui/event.dart' as ui;
import 'package:termui/ui/widgets/prompt_runner.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/widgets/text.dart';

class FakeTerminalBackend implements TerminalBackend {
  final List<String> writtenData = [];

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

  MockTerminal(super.backend);

  @override
  Stream<ui.InputEvent> get events => _eventsController.stream;

  void injectTestEvent(ui.InputEvent event) {
    _eventsController.add(event);
  }

  @override
  void showCursor() {
    isCursorVisible = true;
    super.showCursor();
  }

  @override
  void hideCursor() {
    isCursorVisible = false;
    super.hideCursor();
  }

  @override
  void dispose() {
    _eventsController.close();
    super.dispose();
  }
}

class TestKeyConsumerWidget extends Widget {
  final bool focused;
  final bool shouldConsume;

  const TestKeyConsumerWidget({this.focused = true, this.shouldConsume = true});

  @override
  void render(Buffer buffer, Rect area) {}

  bool handleKeyEvent(ui.KeyEvent event) {
    return shouldConsume;
  }
}

void main() {
  group('PromptRunner Refactoring Tests', () {
    late FakeTerminalBackend backend;
    late MockTerminal terminal;

    setUp(() {
      backend = FakeTerminalBackend();
      terminal = MockTerminal(backend);
    });

    tearDown(() {
      terminal.dispose();
    });

    test('Enter Key Completion', () async {
      final runner = PromptRunner<String>(
        terminal: terminal,
        widget: const TestKeyConsumerWidget(shouldConsume: false),
        exitConditions: {PromptExitTrigger.enter: PromptExitAction.complete},
        onComplete: () => 'Completed Value',
      );

      final future = runner.run();

      // Small delay to allow prompt to initialize and start listening
      await Future.delayed(const Duration(milliseconds: 10));

      terminal.injectTestEvent(const ui.KeyEvent('enter', ui.KeyType.enter));

      final result = await future;
      expect(result, 'Completed Value');
    });

    test('Escape Key Cancellation', () async {
      final runner = PromptRunner<String>(
        terminal: terminal,
        widget: const TestKeyConsumerWidget(shouldConsume: false),
        exitConditions: {PromptExitTrigger.escape: PromptExitAction.cancel},
        onComplete: () => 'Should not see this',
      );

      final future = runner.run();
      await Future.delayed(const Duration(milliseconds: 10));

      terminal.injectTestEvent(const ui.KeyEvent('escape', ui.KeyType.escape));

      final result = await future;
      expect(result, isNull);
    });

    test('Ctrl+C Exception Generation', () async {
      final runner = PromptRunner<String>(
        terminal: terminal,
        widget: const TestKeyConsumerWidget(shouldConsume: false),
        exitConditions: {PromptExitTrigger.controlC: PromptExitAction.abort},
      );

      final future = runner.run();
      await Future.delayed(const Duration(milliseconds: 10));

      terminal.injectTestEvent(
        const ui.KeyEvent(
          'c',
          ui.KeyType.character,
          modifiers: {ui.Modifier.control},
        ),
      );

      expect(future, throwsA(isA<UserInterruptException>()));
    });

    test('Resource Recovery Verification', () async {
      final runner = PromptRunner<String>(
        terminal: terminal,
        widget: const TestKeyConsumerWidget(shouldConsume: false),
        exitConditions: {PromptExitTrigger.controlC: PromptExitAction.abort},
      );

      final future = runner.run();
      await Future.delayed(const Duration(milliseconds: 10));

      // Hide cursor initially
      terminal.hideCursor();
      expect(terminal.isCursorVisible, isFalse);

      terminal.injectTestEvent(
        const ui.KeyEvent(
          'c',
          ui.KeyType.character,
          modifiers: {ui.Modifier.control},
        ),
      );

      try {
        await future;
      } catch (_) {}

      // Repaint handler should be cleared and cursor restored
      expect(State.onNeedRepaint, isNull);
      expect(terminal.isCursorVisible, isTrue);
    });

    test('Exact User Overrides', () {
      final runner = PromptRunner<String>(
        terminal: terminal,
        widget: const TestKeyConsumerWidget(),
        exitConditions: {PromptExitTrigger.escape: PromptExitAction.cancel},
      );

      expect(runner.exitConditions, {
        PromptExitTrigger.escape: PromptExitAction.cancel,
      });
    });

    test(
      'Boolean Event Routing - Consumed event does not trigger standard exit',
      () async {
        final runner = PromptRunner<String>(
          terminal: terminal,
          widget: const TestKeyConsumerWidget(shouldConsume: true),
          onComplete: () => 'Completed',
        );

        final future = runner.run();
        await Future.delayed(const Duration(milliseconds: 10));

        // Inject Enter key. Since our widget consumes it (returns true), it should NOT trigger prompt completion.
        terminal.injectTestEvent(const ui.KeyEvent('enter', ui.KeyType.enter));

        // Yield event loop to let events process
        await Future.delayed(const Duration(milliseconds: 10));

        // Programmatically abort to resolve future so the test completes
        runner.abort(Exception('Finished Test'));

        expect(future, throwsA(isA<Exception>()));
      },
    );

    test('Case-Insensitive Interception', () async {
      final runner = PromptRunner<String>(
        terminal: terminal,
        widget: const TestKeyConsumerWidget(shouldConsume: false),
        exitConditions: {PromptExitTrigger.controlC: PromptExitAction.abort},
      );

      final future = runner.run();
      await Future.delayed(const Duration(milliseconds: 10));

      // Inject Ctrl+C (uppercase C character with control modifier)
      terminal.injectTestEvent(
        const ui.KeyEvent(
          'C',
          ui.KeyType.character,
          modifiers: {ui.Modifier.control},
        ),
      );

      expect(future, throwsA(isA<UserInterruptException>()));
    });

    test('Programmatic Abort and Dispose', () async {
      final runner = PromptRunner<String>(
        terminal: terminal,
        widget: const TestKeyConsumerWidget(),
      );

      final future = runner.run();
      await Future.delayed(const Duration(milliseconds: 10));

      runner.abort(
        const PromptAbortedException(
          trigger: PromptExitTrigger.controlC,
          message: 'Custom Abort',
        ),
      );

      expect(future, throwsA(isA<PromptAbortedException>()));
    });

    test('PromptScope.done Programmatic Completion', () async {
      final runner = PromptRunner<String>(
        terminal: terminal,
        widget: const PromptScopeTestWidget('Scope Completed!'),
      );

      final result = await runner.run();
      expect(result, 'Scope Completed!');
    });
  });
}

class PromptScopeTestWidget extends StatefulWidget {
  final String completionValue;
  const PromptScopeTestWidget(this.completionValue);

  @override
  State<PromptScopeTestWidget> createState() => _PromptScopeTestWidgetState();
}

class _PromptScopeTestWidgetState extends State<PromptScopeTestWidget> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Safely complete on next microtask/tick to ensure build cycle completes.
    Future.microtask(() {
      if (mounted) {
        PromptScope.of(context)?.done(widget.completionValue);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Text('Test PromptScope');
  }
}
