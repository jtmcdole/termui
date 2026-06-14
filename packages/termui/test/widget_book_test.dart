import 'dart:async';
import 'dart:math';
import 'package:termui_shared_examples/widget_book/layout_state.dart';
import 'package:test/test.dart';
import 'package:termui/terminal/terminal.dart';
import 'package:termui/terminal/backend/terminal_backend.dart';
import 'package:termui/ui/event.dart' as ui;
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/layout.dart' as ui;
import 'package:termui/perf/tracer.dart';
import 'package:termui_shared_examples/widget_book/widget_book_runner.dart';
import 'package:termui_shared_examples/widget_book/widget_book_platform.dart';
import 'package:termui_test/termui_test.dart';
import 'package:termui/ui/widget_toolkit.dart';

class FakeTerminalBackend implements TerminalBackend {
  final StreamController<List<int>> _inputController =
      StreamController<List<int>>();
  final List<String> writtenData = [];
  final Point<int> _size = const Point(80, 24);

  @override
  bool get isWindows => false;

  @override
  Stream<List<int>> get rawInput => _inputController.stream;

  @override
  void write(String data) {
    writtenData.add(data);
  }

  @override
  Point<int> get size => _size;

  @override
  Stream<Point<int>> watchSize() => const Stream.empty();

  @override
  void enableRawMode() {}

  @override
  void disableRawMode() {}

  @override
  void dispose() {
    _inputController.close();
  }

  void injectBytes(List<int> bytes) {
    _inputController.add(bytes);
  }
}

class TestWidgetBookPlatform implements WidgetBookPlatform {
  @override
  bool get shouldRenderToTerminal => false;

  @override
  void onFrameRedrawn(Buffer buffer) {}

  @override
  void startTicker(void Function(Duration elapsed) onTick) {}

  @override
  void stopTicker() {}

  @override
  bool handleKeyEvent(Terminal terminal, ui.KeyEvent event) => false;

  @override
  void onExit() {}
}

class MockTerminal extends Terminal {
  final _eventsController = StreamController<ui.InputEvent>.broadcast();

  MockTerminal(super.backend);

  @override
  Stream<ui.InputEvent> get events => _eventsController.stream;

  void injectTestEvent(ui.InputEvent event) {
    _eventsController.add(event);
  }

  @override
  void dispose() {
    _eventsController.close();
    super.dispose();
  }
}

void main() {
  group('Widget Book Runner Mouse Event Tests', () {
    test('Sidebar navigation clicks change page correctly', () async {
      final backend = FakeTerminalBackend();
      final terminal = Terminal(backend);
      final platform = TestWidgetBookPlatform();

      // Run widget book runner
      final bookFuture = runWidgetBookShared(terminal, platform);

      // Wait for initialization
      await Future.delayed(const Duration(milliseconds: 50));

      // Clear written data from initial frame renders
      backend.writtenData.clear();

      // Click on the second sidebar item (Data Displays, index 1, 1-indexed row 4)
      // SGR mouse press sequence: \x1b[<0;5;4M
      backend.injectBytes('\x1b[<0;5;4M'.codeUnits);

      // Wait for event processing
      await Future.delayed(const Duration(milliseconds: 50));

      // Changing page should trigger terminal.resetMousePointer() which writes '\x1b]22;\x1b\\'
      expect(
        backend.writtenData.any((s) => s.contains('\x1b]22;\x1b\\')),
        isTrue,
      );

      terminal.dispose();
      await bookFuture;
    });

    test('Ctrl+C terminates widget book runner loop', () async {
      // 1. Test standard Ctrl+C parsed from byte stream
      {
        final backend = FakeTerminalBackend();
        final terminal = Terminal(backend);
        final platform = TestWidgetBookPlatform();

        final bookFuture = runWidgetBookShared(terminal, platform);
        await Future.delayed(const Duration(milliseconds: 50));

        // Inject Ctrl+C bytes (code 3)
        backend.injectBytes([3]);

        await bookFuture.timeout(
          const Duration(seconds: 2),
          onTimeout: () => throw TimeoutException(
            'Widget book did not exit on Ctrl+C bytes',
          ),
        );
        terminal.dispose();
      }

      // 2. Test Flutter-injected Ctrl+C KeyEvent using MockTerminal
      {
        final backend = FakeTerminalBackend();
        final terminal = MockTerminal(backend);
        final platform = TestWidgetBookPlatform();

        final bookFuture = runWidgetBookShared(terminal, platform);
        await Future.delayed(const Duration(milliseconds: 50));

        // Inject Flutter-style Ctrl+C KeyEvent
        terminal.injectTestEvent(
          const ui.KeyEvent(
            '\x03',
            ui.KeyType.character,
            modifiers: {ui.Modifier.control},
          ),
        );

        await bookFuture.timeout(
          const Duration(seconds: 2),
          onTimeout: () => throw TimeoutException(
            'Widget book did not exit on injected KeyEvent',
          ),
        );
        terminal.dispose();
      }
    });

    test(
      'Focused text field consumes character keys and prevents global hotkeys',
      () async {
        final backend = FakeTerminalBackend();
        final terminal = MockTerminal(backend);
        final platform = TestWidgetBookPlatform();

        // Run widget book runner
        final bookFuture = runWidgetBookShared(terminal, platform);

        // Wait for initialization
        await Future.delayed(const Duration(milliseconds: 50));

        // By default, focusDemoPane is false.
        // Press Tab to focus the demo pane.
        terminal.injectTestEvent(const ui.KeyEvent('\t', ui.KeyType.tab));
        await Future.delayed(const Duration(milliseconds: 50));

        // Now focusDemoPane is true.
        // Inject a key event like 't' which is a global shortcut to start/stop tracing.
        terminal.injectTestEvent(const ui.KeyEvent('t', ui.KeyType.character));
        await Future.delayed(const Duration(milliseconds: 50));

        // If 't' was consumed by the demo pane, Tracer should NOT be enabled.
        expect(Tracer.isEnabled, isFalse);

        // Inject 'q' key event while focused.
        // 'q' is a global shortcut to quit. Since we are focused, it should be consumed and NOT quit.
        terminal.injectTestEvent(const ui.KeyEvent('q', ui.KeyType.character));
        await Future.delayed(const Duration(milliseconds: 50));

        // We should still be running. Let's verify by checking that the book future hasn't completed.
        var isCompleted = false;
        bookFuture.then((_) => isCompleted = true);
        await Future.delayed(const Duration(milliseconds: 50));
        expect(isCompleted, isFalse);

        // Now unfocus the demo pane by injecting escape
        terminal.injectTestEvent(
          const ui.KeyEvent('\u001b', ui.KeyType.escape),
        );
        await Future.delayed(const Duration(milliseconds: 50));

        // Now focusDemoPane should be false.
        // Injecting 'q' now should exit the runner loop.
        terminal.injectTestEvent(const ui.KeyEvent('q', ui.KeyType.character));

        await bookFuture.timeout(
          const Duration(seconds: 2),
          onTimeout: () => throw TimeoutException(
            'Widget book did not exit on "q" after unfocusing',
          ),
        );

        terminal.dispose();
      },
    );
  });

  group('Widget Book Integration Tests (TerminalTester)', () {
    test('The Boot & Mount Test', () {
      final tester = TerminalTester();
      tester.run(() async {
        final app = WidgetBookApp(
          terminal: tester.terminal,
          platform: TestWidgetBookPlatform(),
          isInline: false,
        );
        await tester.pumpWidget(app);
        expect(find.text('COMPONENTS'), findsOneWidget);
      });
    });

    test('The Spatial Input Routing Test', () {
      final tester = TerminalTester();
      tester.run(() async {
        final app = WidgetBookApp(
          terminal: tester.terminal,
          platform: TestWidgetBookPlatform(),
          isInline: false,
        );
        final runner = PromptRunner<void>(
          terminal: tester.terminal,
          widget: app,
          alternateScreen: false,
        );

        final runnerFuture = tester.runPrompt(runner, () async {
          await tester.pump();

          // Assert initial page is 'Text Inputs'
          expect(find.text('Text Inputs Preview'), findsOneWidget);

          // Inject arrowDown key
          tester.sendKey(LogicalKey.arrowDown);
          await tester.pump();

          // Assert selected page updated to 'Data Displays'
          expect(find.text('Data Displays Preview'), findsOneWidget);

          runner.dispose();
        });

        await runnerFuture;
      });
    });

    test('The Focus Handoff Test (Tab Traversal)', () {
      final tester = TerminalTester();
      tester.run(() async {
        final app = WidgetBookApp(
          terminal: tester.terminal,
          platform: TestWidgetBookPlatform(),
          isInline: false,
        );
        final runner = PromptRunner<void>(
          terminal: tester.terminal,
          widget: app,
          alternateScreen: false,
        );

        final runnerFuture = tester.runPrompt(runner, () async {
          await tester.pump();

          // Initially, preview should NOT be active
          expect(find.text('[ACTIVE]'), findsNothing);

          // Send tab key to traversal focus to the preview pane
          tester.sendKey(LogicalKey.tab);
          await tester.pump();

          // Preview pane should now be [ACTIVE]
          expect(find.text('[ACTIVE]'), findsOneWidget);

          runner.dispose();
        });

        await runnerFuture;
      });
    });

    test('The Modal Z-Index Test', () {
      final tester = TerminalTester();
      tester.run(() async {
        final app = WidgetBookApp(
          terminal: tester.terminal,
          platform: TestWidgetBookPlatform(),
          isInline: false,
        );
        final runner = PromptRunner<void>(
          terminal: tester.terminal,
          widget: app,
          alternateScreen: false,
        );

        final runnerFuture = tester.runPrompt(runner, () async {
          await tester.pump();

          // Assert help dialog is NOT shown initially
          expect(find.byType<HelpDialog>(), findsNothing);

          // Press 'h' to show help dialog
          tester.sendKey(LogicalKey.character('h'));
          await tester.pump();

          // Assert help dialog is shown
          expect(find.byType<HelpDialog>(), findsOneWidget);

          // Inject arrowDown key
          tester.sendKey(LogicalKey.arrowDown);
          await tester.pump();

          // Assert that the sidebar did NOT change page (remain on 'Text Inputs')
          expect(find.text('Text Inputs Preview'), findsOneWidget);
          expect(find.text('Data Displays Preview'), findsNothing);

          runner.dispose();
        });

        await runnerFuture;
      });
    });

    test('Layout & State Demo - Button Interaction and State Mutation', () {
      final tester = TerminalTester();
      tester.run(() async {
        final app = WidgetBookApp(
          terminal: tester.terminal,
          platform: TestWidgetBookPlatform(),
          isInline: false,
        );
        final runner = PromptRunner<void>(
          terminal: tester.terminal,
          widget: app,
          alternateScreen: false,
        );

        final runnerFuture = tester.runPrompt(runner, () async {
          await tester.pump();

          // 1. Navigate down the sidebar to "Layout & State" (Index 5)
          for (var i = 0; i < 5; i++) {
            tester.sendKey(LogicalKey.arrowDown);
          }
          await tester.pump();

          // Verify the routing worked and the right pane rebuilt
          expect(find.text('Layout & State Preview'), findsOneWidget);

          // 2. Handoff focus to the preview pane
          tester.sendKey(LogicalKey.tab);
          await tester.pump();

          // Verify the pane is active
          expect(find.text('Layout & State Preview [ACTIVE]'), findsOneWidget);

          // 3. Verify the initial state of the counter
          expect(
            find.descendant(
              of: find.byType<StatefulCounter>(),
              matching: find.text('0'),
            ),
            findsOneWidget,
          );
          expect(find.text('[ INACTIVE ]'), findsOneWidget);

          // 4. Trigger the interaction
          // Assuming the button accepts 'Space' to trigger its onPressed callback
          tester.sendKey(LogicalKey.character(' '));
          await tester.pump();

          // You can dump the tree on failure.
          // debugDumpTree(tester.rootElement);

          // 5. Verify the state mutated and the UI repainted
          expect(
            find.descendant(
              of: find.byType<StatefulCounter>(),
              matching: find.text('1'),
            ),
            findsOneWidget,
          );
          expect(find.text('[ ACTIVE ]'), findsOneWidget);

          // 4. Trigger the interaction
          // Assuming the button accepts 'Space' to trigger its onPressed callback
          tester.sendKey(LogicalKey.character(' '));
          await tester.pump();

          // You can dump the tree on failure.
          // debugDumpTree(tester.rootElement);

          expect(
            find.descendant(
              of: find.byType<StatefulCounter>(),
              matching: find.text('2'),
            ),
            findsOneWidget,
          );
          expect(find.text('[ INACTIVE ]'), findsOneWidget);

          // 4. Exit the panel
          tester.sendKey(LogicalKey.escape);
          await tester.pump();

          // Verify the pane is not active
          expect(find.text('Layout & State Preview [ACTIVE]'), findsNothing);

          // Clean exit
          runner.dispose();
        });

        await runnerFuture;
      });
    });
  });
}
