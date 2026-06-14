import 'dart:async';
import 'dart:math';
import 'package:termui_shared_examples/widget_book/layout_state.dart';
import 'package:test/test.dart';
import 'package:termui/terminal/terminal.dart';
import 'package:termui/terminal/backend/terminal_backend.dart';
import 'package:termui/ui/event.dart' as ui;
import 'package:termui/ui/buffer.dart';
import 'package:termui/perf/tracer.dart';
import 'package:termui_shared_examples/widget_book/widget_book_runner.dart';
import 'package:termui_shared_examples/widget_book/widget_book_platform.dart';
import 'package:termui_test/termui_test.dart';
import 'package:termui/ui/widget_toolkit.dart';
import 'package:termui/ui/window.dart';

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
  setUp(() {
    FocusManager.instance.setPrimaryFocus(null);
  });

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
        expect(find.text(' COMPONENTS '), findsOneWidget);
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
          expect(find.textPattern('Text Inputs Preview'), findsOneWidget);

          // Inject arrowDown key
          tester.sendKey(LogicalKey.arrowDown);
          await tester.pump();

          // Assert selected page updated to 'Data Displays'
          expect(find.textPattern('Data Displays Preview'), findsOneWidget);

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
          expect(
            find.textPattern(r'Text Inputs Preview \[ACTIVE\]'),
            findsOneWidget,
          );

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
          expect(find.textPattern('Text Inputs Preview'), findsOneWidget);
          expect(find.textPattern('Data Displays Preview'), findsNothing);

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
          alternateScreen: true,
        );

        final runnerFuture = tester.runPrompt(runner, () async {
          await tester.pump();

          // 1. Navigate down the sidebar to "Layout & State" (Index 5)
          for (var i = 0; i < 5; i++) {
            tester.sendKey(LogicalKey.arrowDown);
            await tester.pump();
          }

          final menuEntry = find.descendant(
            of: find.byType<SidebarWidget>(),
            matching: find.text('Layout & State'),
          );
          expect(menuEntry, findsOneWidget);

          tester.tap(menuEntry);

          await tester.pump();

          debugDumpTree(tester.rootElement);

          // Verify the routing worked and the right pane rebuilt
          expect(find.textPattern('Layout & State Preview'), findsOneWidget);

          // 2. Handoff focus to the preview pane
          tester.sendKey(LogicalKey.tab);
          await tester.pump();

          // Verify the pane is active
          expect(
            find.textPattern(r'Layout & State Preview \[ACTIVE\]'),
            findsOneWidget,
          );

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

    test('TextField - Cursor Navigation and Edit Operations', () async {
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
          alternateScreen: true,
        );

        final runnerFuture = tester.runPrompt(runner, () async {
          await tester.pump();

          // 1. Navigate to "Text Inputs" using the newly fixed spatial hit-testing
          tester.tap(find.text('Text Inputs'));
          await tester.pump();

          // 2. Handoff focus to the right pane
          tester.sendKey(LogicalKey.tab);
          await tester.pump();

          // Verify the pane is active and the first text field reports focus
          expect(
            find.textPattern(r'Text Inputs Preview \[ACTIVE\]'),
            findsOneWidget,
          );
          expect(find.textPattern(r'\(focused\)'), findsOneWidget);

          // Helper function to simulate typing a string
          void typeText(String text) {
            for (final char in text.split('')) {
              tester.sendKey(LogicalKey.character(char));
            }
          }

          // 3. Initial Input
          typeText('one two three');
          await tester.pump();
          expect(find.textPattern('one two three'), findsOneWidget);

          // 4. Test Home & End Keys
          tester.sendKey(LogicalKey.home);
          typeText('start ');
          await tester.pump();
          expect(find.textPattern('start one two three'), findsOneWidget);

          tester.sendKey(LogicalKey.end);
          typeText(' end');
          await tester.pump();
          expect(find.textPattern('start one two three end'), findsOneWidget);

          // 5. Test Single Character Arrows (Left / Right)
          // Move left 3 spaces (cursor before 'end'), insert 'X'
          for (var i = 0; i < 3; i++) {
            tester.sendKey(LogicalKey.arrowLeft);
          }
          typeText('X');
          await tester.pump();
          tester.expectUI(
            find.textPattern('start one two three Xend'),
            findsOneWidget,
          );

          // Move right 1 space (cursor after 'e'), insert 'Y'
          tester.sendKey(LogicalKey.arrowRight);
          typeText('Y');
          await tester.pump();
          expect(find.textPattern('start one two three XeYnd'), findsOneWidget);

          // 6. Test Word Jumps (Ctrl + Left / Right)
          // Note: Assuming tester.sendKey supports a control boolean flag or chord mapping.
          // Jump back two words (over 'XeYnd' and 'three'). Cursor before 'three'.
          tester.sendKey(LogicalKey.arrowLeft, control: true);
          tester.sendKey(LogicalKey.arrowLeft, control: true);

          // 7. Test Word Deletions (Ctrl+W / Ctrl+D)
          // Delete word backward (deletes 'two ')
          tester.sendKey(LogicalKey.character('W'), control: true);
          await tester.pump();
          expect(find.textPattern('start one three XeYnd'), findsOneWidget);

          // print(tester.screenshot());

          // Delete word forward (deletes 'three')
          tester.sendKey(LogicalKey.character('D'), control: true);
          await tester.pump();
          expect(find.textPattern('start one  XeYnd'), findsOneWidget);

          // 8. Test Line Deletions (Ctrl+Backspace / Ctrl+K)
          // Delete from cursor to start of line (deletes 'start one  ')
          tester.sendKey(LogicalKey.backspace, control: true);
          await tester.pump();
          tester.expectUI(find.text(' XeYnd'), findsOneWidget);

          print(tester.screenshot());

          // Move cursor right by 1 (after 'X'), delete to end of line (deletes 'eYnd')
          tester.sendKey(LogicalKey.home);
          tester.sendKey(LogicalKey.arrowRight);
          tester.sendKey(LogicalKey.arrowRight); // past the X
          tester.sendKey(LogicalKey.character('K'), control: true);
          await tester.pump();
          tester.expectUI(find.text(' X'), findsOneWidget);

          // 9. Test Undo / Redo (Ctrl+Z / Ctrl+Y)
          // Undo the Ctrl+K deletion
          tester.sendKey(LogicalKey.character('Z'), control: true);
          await tester.pump();
          expect(find.textPattern(' XeYnd'), findsOneWidget);

          // Redo the Ctrl+K deletion
          tester.sendKey(LogicalKey.character('Y'), control: true);
          await tester.pump();
          expect(find.textPattern(' X'), findsOneWidget);

          // Clean exit
          tester.sendKey(LogicalKey.escape);
          await tester.pump();

          tester.expectUI(find.textPattern(r'\(focused\)'), findsNothing);
          tester.expectUI(
            find.textPattern(r'Text Inputs Preview \[ACTIVE\]'),
            findsNothing,
          );

          runner.dispose();
        });

        await runnerFuture;
      });
    });

    test('Multi-line TextField - Focus Cycling and Line Breaks', () async {
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
          alternateScreen: true, // Let it breathe
        );

        final runnerFuture = tester.runPrompt(runner, () async {
          await tester.pump();

          // 1. Navigate to the component
          tester.tap(find.text('Text Inputs'));
          await tester.pump();

          // 2. Tab into the right pane (Focuses Single-line TextField)
          tester.sendKey(LogicalKey.tab);
          await tester.pump();

          // Helper for typing strings
          void typeText(String text) {
            for (final char in text.split('')) {
              tester.sendKey(LogicalKey.character(char));
            }
          }

          // 3. Type in the first input
          typeText('one line');
          await tester.pump();
          tester.expectUI(find.text('one line'), findsOneWidget);

          // 4. Cycle Focus to the Multi-line TextField
          tester.sendKey(LogicalKey.tab);
          await tester.pump();

          // 5. Verify focus shifted.
          // (Assuming your UI moves the "▶" and "(focused)" labels)
          tester.expectUI(
            find.textPattern(r'▶ Multi-line TextField \(focused\)'),
            findsOneWidget,
          );
          // Ensure the single-line field lost focus
          tester.expectUI(
            find.textPattern(r'▶ Single-line TextField \(focused\)'),
            findsNothing,
          );

          // 6. Test Multi-line specific behavior (Enter key)
          typeText('first line');
          tester.sendKey(
            LogicalKey.enter,
          ); // This should create a newline, not exit!
          typeText('second line');
          await tester.pump();

          // 7. Verify both lines exist in the buffer
          tester.expectUI(find.text('first line'), findsOneWidget);
          tester.expectUI(find.text('second line'), findsOneWidget);

          // Clean exit
          tester.sendKey(LogicalKey.escape);
          runner.dispose();
        });

        await runnerFuture;
      });
    });

    test('Forms & Validation - Focus Traversal and Enter Key Validation', () async {
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
          alternateScreen: true,
        );

        final runnerFuture = tester.runPrompt(runner, () async {
          await tester.pump();

          // 1. Navigate to "Forms & Validation" page
          tester.tap(find.text('Forms & Validation'));
          await tester.pump();

          // 2. Focus the preview pane (Handoff focus to the right pane)
          tester.sendKey(LogicalKey.tab);
          await tester.pump();

          // Verify the preview is active
          expect(
            find.textPattern(r'Forms & Validation Preview \[ACTIVE\]'),
            findsOneWidget,
          );

          // Get the Form widget from the tree to inspect field states
          final formElements = find.byType<Form>().apply(
            collectAllElements(tester.rootElement!),
          );
          final form = formElements.first.widget as Form;

          // Initially, the first field (Email Address) is focused
          expect(form.fields[0].focused, isTrue);
          expect(form.fields[1].focused, isFalse);

          // Type some text in the Email field
          tester.sendKey(LogicalKey.character('t'));
          tester.sendKey(LogicalKey.character('e'));
          tester.sendKey(LogicalKey.character('s'));
          tester.sendKey(LogicalKey.character('t'));
          await tester.pump();
          expect(form.fields[0].value, equals('test'));

          // 3. Tab to move focus forward
          tester.sendKey(LogicalKey.tab);
          await tester.pump();

          // Verify focus shifted to the Favorite Programming Language field
          expect(form.fields[0].focused, isFalse);
          expect(form.fields[1].focused, isTrue);

          // Verify that the email value is NOT erased!
          expect(form.fields[0].value, equals('test'));

          // Tab to move to Agree to Terms
          tester.sendKey(LogicalKey.tab);
          await tester.pump();
          expect(form.fields[2].focused, isTrue);

          // Tab back to Email Address (cycles)
          tester.sendKey(LogicalKey.tab);
          await tester.pump();
          expect(form.fields[0].focused, isTrue);
          expect(form.fields[0].value, equals('test'));

          // 4. Test Enter key validation and shifting
          tester.sendKey(LogicalKey.enter);
          await tester.pump();

          // Verify focus shifted forward to the Favorite Programming Language field on Enter
          expect(form.fields[0].focused, isFalse);
          expect(form.fields[1].focused, isTrue);

          // Clean exit: Escape to sidebar
          tester.sendKey(LogicalKey.escape);
          await tester.pump();

          // Verify sidebar is focused
          final sidebarElements = find.byType<SidebarWidget>().apply(
            collectAllElements(tester.rootElement!),
          );
          expect(sidebarElements, isNotEmpty);
          final sidebar = sidebarElements.first.widget as SidebarWidget;
          expect(sidebar.focusNode.hasFocus, isTrue);

          // Tap "Text Inputs" to navigate back
          tester.tap(find.text('Text Inputs'));
          await tester.pump();

          // Verify Text Inputs preview is now selected
          expect(find.textPattern(r'Text Inputs Preview'), findsOneWidget);

          // Tab to focus the Text Inputs preview pane
          tester.sendKey(LogicalKey.tab);
          await tester.pump();

          // Verify Text Inputs preview is active
          expect(
            find.textPattern(r'Text Inputs Preview \[ACTIVE\]'),
            findsOneWidget,
          );

          // Verify we can tab around inside Text Inputs (starts at Single-line, tabs to Multi-line)
          expect(
            find.textPattern(r'▶ Single-line TextField \(focused\):'),
            findsOneWidget,
          );

          // Press Tab to cycle focus to Multi-line
          tester.sendKey(LogicalKey.tab);
          await tester.pump();
          expect(
            find.textPattern(r'▶ Multi-line TextField \(focused\):'),
            findsOneWidget,
          );

          runner.dispose();
        });

        await runnerFuture;
      });
    });
  });
}
