import 'dart:async';
import 'package:test/test.dart';
import 'package:termui/ui/event.dart' as ui;
import 'package:termui/ui/widgets/core/prompt_runner.dart';
import 'package:termui/ui/widgets/core/widget.dart';
import 'package:termui/ui/widgets/core/element.dart';
import 'package:termui/ui/widgets/core/build_context.dart';
import 'package:termui/ui/widgets/core/geometry.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/widgets/display/text.dart';

import 'package:termui_test/termui_test.dart';

class TestKeyConsumerWidget extends Widget
    implements ui.Focusable, ui.KeyEventHandler {
  @override
  final bool focused;
  final bool shouldConsume;

  const TestKeyConsumerWidget({this.focused = true, this.shouldConsume = true});

  @override
  Element createElement() => _TestKeyConsumerElement(this);

  @override
  bool handleKeyEvent(ui.KeyEvent event) {
    return shouldConsume;
  }
}

class _TestKeyConsumerElement extends Element {
  _TestKeyConsumerElement(super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return constraints.constrain(Size.zero);
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {}
}

void main() {
  group('PromptRunner Refactoring Tests', () {
    late MockTerminalBackend backend;
    late MockTerminal terminal;

    setUp(() {
      backend = MockTerminalBackend();
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

      // Cursor restored
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

    test('Managed Mode Bypasses Hardware Hooks and Writes', () async {
      final runner = PromptRunner<String>(
        terminal: terminal,
        widget: const Text('Managed Mode Content'),
        mode: ExecutionMode.managed,
        exitConditions: {PromptExitTrigger.enter: PromptExitAction.complete},
        onComplete: () => 'Managed Done',
      );

      final future = runner.run();
      await Future.delayed(const Duration(milliseconds: 10));

      expect(runner.currentBuffer, isNotNull);
      expect(runner.currentBuffer!.width, equals(80));

      var hasContent = false;
      for (var y = 0; y < runner.currentBuffer!.height; y++) {
        for (var x = 0; x < runner.currentBuffer!.width; x++) {
          final char = runner.currentBuffer!.getCharacter(x, y);
          if (char.isNotEmpty && char != ' ') {
            hasContent = true;
          }
        }
      }
      expect(hasContent, isTrue);

      expect(backend.writes, isEmpty);

      runner.pump();
      expect(runner.currentBuffer, isNotNull);

      terminal.injectTestEvent(const ui.KeyEvent('enter', ui.KeyType.enter));

      bool completed = false;
      future.then((_) => completed = true);
      await Future.delayed(const Duration(milliseconds: 10));
      expect(completed, isFalse);

      runner.dispose();
      final result = await future;
      expect(result, isNull);
    });

    test('routes 4-argument mouse events correctly', () async {
      late ui.MouseEvent receivedEvent;
      late int receivedX;
      late int receivedY;
      late Rect receivedArea;

      final runner = PromptRunner<String>(
        terminal: terminal,
        widget: Test4ArgMouseWidget((event, x, y, area) {
          receivedEvent = event;
          receivedX = x;
          receivedY = y;
          receivedArea = area;
        }),
      );

      final future = runner.run();
      await Future.delayed(const Duration(milliseconds: 10));

      final click = const ui.MouseEvent(
        x: 5,
        y: 5,
        button: ui.MouseButton.left,
        type: ui.MouseEventType.press,
      );
      terminal.injectTestEvent(click);

      await Future.delayed(const Duration(milliseconds: 10));

      expect(receivedEvent.type, equals(ui.MouseEventType.press));
      expect(receivedX, equals(4)); // global 5 (1-based) is local 4 (0-based)
      expect(receivedY, equals(4));
      expect(receivedArea.width, equals(80));
      expect(receivedArea.height, equals(10));

      runner.dispose();
      await future;
    });
  });
}

class Test4ArgMouseWidget extends Widget {
  final void Function(ui.MouseEvent event, int localX, int localY, Rect area)
  onMouse;
  const Test4ArgMouseWidget(this.onMouse);

  @override
  int getIntrinsicHeight(int width) => 10;

  @override
  Element createElement() => _Test4ArgMouseElement(this);
}

class _Test4ArgMouseElement extends Element
    implements ui.MouseEventHandlerWithArea {
  _Test4ArgMouseElement(super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return constraints.constrain(const Size(10, 10));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {}

  @override
  void handleMouseEvent(
    ui.MouseEvent event,
    int localX,
    int localY,
    Rect area,
  ) {
    (widget as Test4ArgMouseWidget).onMouse(event, localX, localY, area);
  }
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
