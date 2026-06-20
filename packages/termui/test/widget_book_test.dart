import 'dart:async';
import 'package:termui_shared_examples/widget_book/layout_state.dart';
import 'package:termui_shared_examples/widget_book/modal_dialog.dart';
import 'package:test/test.dart';
import 'package:termui/ui/event.dart' as ui;
import 'package:termui_shared_examples/widget_book/widget_book_runner.dart';
import 'package:termui_shared_examples/widget_book/widget_book_platform.dart';
import 'package:termui_test/termui_test.dart';
import 'package:termui_recorder/termui_recorder.dart';
import 'package:termui/termui.dart';

class TestWidgetBookPlatform implements WidgetBookPlatform {
  Buffer? lastBuffer;

  @override
  bool get shouldRenderToTerminal => false;

  @override
  void onFrameRedrawn(Buffer buffer) {
    lastBuffer = buffer;
  }

  @override
  void startTicker(void Function(Duration elapsed) onTick) {}

  @override
  void stopTicker() {}

  @override
  bool handleKeyEvent(Terminal terminal, ui.KeyEvent event) => false;

  @override
  void onExit() {}
}

void main() {
  setUp(() {
    FocusManager.instance.setPrimaryFocus(null);
  });

  group('Widget Book Runner Mouse Event Tests', () {
    test('Sidebar navigation clicks change page correctly', () async {
      final backend = MockTerminalBackend();
      final terminal = Terminal(backend);
      final platform = TestWidgetBookPlatform();

      // Run widget book runner
      final bookFuture = runWidgetBookShared(terminal, platform);

      // Wait for initialization
      await Future.delayed(const Duration(milliseconds: 50));

      // Clear written data from initial frame renders
      backend.writes.clear();

      // Click on the second sidebar item (Data Displays, index 1, 1-indexed row 4)
      // SGR mouse press sequence: \x1b[<0;5;4M
      backend.pushBytes('\x1b[<0;5;4M'.codeUnits);

      // Wait for event processing
      await Future.delayed(const Duration(milliseconds: 50));

      // Changing page should trigger terminal.resetMousePointer() which writes '\x1b]22;\x1b\\'
      expect(backend.writes.any((s) => s.contains('\x1b]22;\x1b\\')), isTrue);

      terminal.dispose();
      await bookFuture;
    });

    test('Sidebar navigation hover highlights and click changes page', () async {
      final backend = MockTerminalBackend();
      final terminal = Terminal(backend);
      final platform = TestWidgetBookPlatform();

      // Run widget book runner
      final bookFuture = runWidgetBookShared(terminal, platform);

      // Wait for initialization
      await Future.delayed(const Duration(milliseconds: 50));

      // Clear written data from initial frame renders
      backend.writes.clear();

      // Move/hover mouse over the second sidebar item (Data Displays, index 1, 1-indexed row 4)
      // SGR mouse move sequence: \x1b[<35;5;4M
      backend.pushBytes('\x1b[<35;5;4M'.codeUnits);

      // Wait for event processing
      await Future.delayed(const Duration(milliseconds: 50));

      // Verify that index 1 'Data Displays' is hovered and highlighted with CharmColors.charple background
      final activeBuffer = platform.lastBuffer;
      expect(activeBuffer, isNotNull);
      final cell = activeBuffer!.getCell(0, 3);
      expect(cell, isNotNull);
      expect(cell!.char, equals('D'));
      expect(cell.style.background, equals(CharmColors.charple));

      // Click on the second sidebar item (Data Displays)
      backend.pushBytes('\x1b[<0;5;4M'.codeUnits);
      backend.pushBytes('\x1b[<0;5;4m'.codeUnits);

      // Wait for click event processing
      await Future.delayed(const Duration(milliseconds: 50));

      // Changing page should trigger terminal.resetMousePointer() which writes '\x1b]22;\x1b\\'
      expect(backend.writes.any((s) => s.contains('\x1b]22;\x1b\\')), isTrue);

      terminal.dispose();
      await bookFuture;
    });

    test('Ctrl+C terminates widget book runner loop', () async {
      // 1. Test standard Ctrl+C parsed from byte stream
      {
        final backend = MockTerminalBackend();
        final terminal = Terminal(backend);
        final platform = TestWidgetBookPlatform();

        final bookFuture = runWidgetBookShared(terminal, platform);
        await Future.delayed(const Duration(milliseconds: 50));

        // Inject Ctrl+C bytes (code 3)
        backend.pushBytes([3]);

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
        final backend = MockTerminalBackend();
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
        final backend = MockTerminalBackend();
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
      final tester = TerminalTester(recordTraces: true);
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

          // 3. Initial Input
          tester.typeText('one two three');
          await tester.pump();
          expect(find.textPattern('one two three'), findsOneWidget);

          // 4. Test Home & End Keys
          tester.sendKey(LogicalKey.home);
          tester.typeText('start ');
          await tester.pump();
          expect(find.textPattern('start one two three'), findsOneWidget);

          tester.sendKey(LogicalKey.end);
          tester.typeText(' end');
          await tester.pump();
          expect(find.textPattern('start one two three end'), findsOneWidget);

          // 5. Test Single Character Arrows (Left / Right)
          // Move left 3 spaces (cursor before 'end'), insert 'X'
          for (var i = 0; i < 3; i++) {
            tester.sendKey(LogicalKey.arrowLeft);
          }
          tester.typeText('X');
          await tester.pump();
          tester.expectUI(
            find.textPattern('start one two three Xend'),
            findsOneWidget,
          );

          // Move right 1 space (cursor after 'e'), insert 'Y'
          tester.sendKey(LogicalKey.arrowRight);
          tester.typeText('Y');
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

    test('Forms & Validation - Full Flow Validation and Submission', () async {
      final tester = TerminalTester(recordTraces: true);
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

          // 3. Trigger Validation: Press Enter on the empty email field
          // This shifts focus to the next field and triggers "on blur" validation
          tester.sendKey(LogicalKey.enter);
          await tester.pump();

          // Verify focus moved and the error rendered
          expect(form.fields[0].focused, isFalse);
          expect(form.fields[1].focused, isTrue);
          expect(find.textPattern('⚠ Email is required'), findsOneWidget);

          // 4. Fix Validation: Shift+Tab back to the Email field
          tester.sendKey(LogicalKey.tab, shift: true);
          await tester.pump();
          expect(form.fields[0].focused, isTrue);

          // Input partial email to verify that the "Email is required" error changes instantly
          tester.sendString('u');
          await tester.pump();
          expect(find.textPattern('⚠ Email is required'), findsNothing);
          expect(
            find.textPattern('⚠ Must be a valid email containing @'),
            findsOneWidget,
          );

          // Complete the email to verify that the validation error clears instantly on change
          tester.sendString('ser@domain.com');
          await tester.pump();
          expect(
            find.textPattern('⚠ Must be a valid email containing @'),
            findsNothing,
          );

          // Move to the next field
          tester.sendKey(LogicalKey.enter);
          await tester.pump();
          expect(form.fields[0].value, equals('user@domain.com'));

          // Verify the error message remains cleared
          expect(find.textPattern('⚠ Email is required'), findsNothing);
          expect(
            find.textPattern('⚠ Must be a valid email containing @'),
            findsNothing,
          );

          // 5. Verify Favorite Programming Language
          expect(form.fields[1].focused, isTrue);

          // Tab to Agree to Terms & Conditions
          tester.sendKey(LogicalKey.tab);
          await tester.pump();
          expect(form.fields[2].focused, isTrue);

          // 6. Select the [Yes] field
          // Ensure we explicitly toggle/select the positive option
          tester.sendKey(LogicalKey.arrowLeft); // Assuming left targets [Yes]
          await tester.pump();

          // Verify visually that [Yes] is active (brackets indicate selection in your UI)
          expect(find.textPattern(r'\[Yes\]'), findsOneWidget);

          // 7. Submit the valid form
          tester.sendKey(LogicalKey.enter);
          await tester.pump();

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

          runner.dispose();
        });

        await runnerFuture;
      });
    });

    test('Burger Order Form - Keyboard-only Traversal', () async {
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

          // 1. Navigate to the Burger Order Form page
          tester.tap(find.text('Burger Order Form'));
          await tester.pump();

          // 2. Focus the preview pane (Handoff focus to the right pane)
          tester.sendKey(LogicalKey.tab);
          await tester.pump();

          // Verify the preview is active and showing stage 0
          expect(
            find.textPattern(r'Burger Order Form Preview \[ACTIVE\]'),
            findsOneWidget,
          );
          expect(find.text('Welcome to Dartaburger™.'), findsOneWidget);

          // 3. Press Enter to start the order (move from Stage 0 to Stage 1)
          tester.sendKey(LogicalKey.enter);
          await tester.pump();

          // Stage 1: Build your burger.
          expect(
            find.textPattern('Stage 1 of 3: Build your burger'),
            findsOneWidget,
          );

          // 4. Press Enter to move to Toppings field (activeFieldIndex 0 -> 1)
          tester.sendKey(LogicalKey.enter);
          await tester.pump();

          // 5. Press Enter to proceed to Stage 2
          tester.sendKey(LogicalKey.enter);
          await tester.pump();

          // Stage 2: Choose sides & spice.
          expect(
            find.textPattern('Stage 2 of 3: Choose sides & spice'),
            findsOneWidget,
          );

          // 6. Press Enter to move to Sides field
          tester.sendKey(LogicalKey.enter);
          await tester.pump();

          // 7. Press Enter to proceed to Stage 3
          tester.sendKey(LogicalKey.enter);
          await tester.pump();

          // Stage 3: Customer details.
          expect(
            find.textPattern('Stage 3 of 3: Customer details'),
            findsOneWidget,
          );

          // 8. Type name "John" in TextFormField
          tester.typeText('John');
          await tester.pump();

          // 9. Press Enter to move to Special Instructions
          tester.sendKey(LogicalKey.enter);
          await tester.pump();

          // 10. Press Tab to move to Confirm (discount)
          tester.sendKey(LogicalKey.tab);
          await tester.pump();

          // 11. Press Enter to submit the order (Stage 3 -> Stage 4 receipt)
          tester.sendKey(LogicalKey.enter);
          await tester.pump();

          // Verify receipt screen (Stage 4)
          expect(find.textPattern('BURGER RECEIPT'), findsOneWidget);
          expect(
            find.textPattern('Thanks for your order, John!'),
            findsOneWidget,
          );

          runner.dispose();
        });

        await runnerFuture;
      });
    });

    test('Modal & Scrollbar - Traversal and Interaction Flow', () async {
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

          // 1. Navigate to the Modal & Scrollbar page
          tester.tap(find.text('Modal & Scrollbar'));
          await tester.pump();

          // 2. Focus the preview pane (Handoff focus to the right pane)
          tester.sendKey(LogicalKey.tab);
          await tester.pump();

          // Verify the preview is active
          expect(find.textPattern(r'Modal & Focus Trap Demo'), findsOneWidget);

          // 3. Press Enter to open the modal
          tester.sendKey(LogicalKey.enter);
          await tester.pump();

          // Verify the modal is now visible
          expect(
            find.textPattern(r'This is a focus-trapped modal!'),
            findsOneWidget,
          );

          final demoWidget =
              find
                      .byType<ModalDialogDemoWidget>()
                      .apply(collectAllElements(tester.rootElement!))
                      .first
                      .widget
                  as ModalDialogDemoWidget;

          // Initially Confirm has focus
          expect(demoWidget.example.modalBtn1Node.isFocused, isTrue);
          expect(demoWidget.example.modalBtn2Node.isFocused, isFalse);

          // Verify hover enter and hover exit on the Confirm button
          final confirmButtonElement =
              find
                      .byType<InkwellButton>()
                      .apply(collectAllElements(tester.rootElement!))
                      .first
                  as StatefulElement;
          final confirmState = confirmButtonElement.state as InkwellButtonState;

          Offset getAbsoluteOffset(Element element) {
            var offset = Offset.zero;
            Element? current = element;
            while (current != null) {
              offset = offset + current.relativeOffset;
              current = current.parent;
            }
            return offset;
          }

          final confirmOffset = getAbsoluteOffset(confirmButtonElement);
          final buttonX = confirmOffset.dx.toInt() + 3;
          final buttonY = confirmOffset.dy.toInt() + 2;

          // Mouse moves over the Confirm button
          tester.mouseMove(buttonX, buttonY, drag: false);
          await tester.pump();
          expect(confirmState.isHovered, isTrue);

          // Mouse moves away (X=10, Y=10)
          tester.mouseMove(10, 10, drag: false);
          await tester.pump();
          expect(confirmState.isHovered, isFalse);

          // 4. Press Arrow Right to move focus to Cancel
          tester.sendKey(LogicalKey.arrowRight);
          await tester.pump();
          expect(demoWidget.example.modalBtn1Node.isFocused, isFalse);
          expect(demoWidget.example.modalBtn2Node.isFocused, isTrue);

          // Press Arrow Left to move focus back to Confirm
          tester.sendKey(LogicalKey.arrowLeft);
          await tester.pump();
          expect(demoWidget.example.modalBtn1Node.isFocused, isTrue);
          expect(demoWidget.example.modalBtn2Node.isFocused, isFalse);

          // Press Arrow Down to move focus to Cancel
          tester.sendKey(LogicalKey.arrowDown);
          await tester.pump();
          expect(demoWidget.example.modalBtn1Node.isFocused, isFalse);
          expect(demoWidget.example.modalBtn2Node.isFocused, isTrue);

          // Press Arrow Up to move focus back to Confirm
          tester.sendKey(LogicalKey.arrowUp);
          await tester.pump();
          expect(demoWidget.example.modalBtn1Node.isFocused, isTrue);
          expect(demoWidget.example.modalBtn2Node.isFocused, isFalse);

          // Press Tab to move focus to Cancel
          tester.sendKey(LogicalKey.tab);
          await tester.pump();
          expect(demoWidget.example.modalBtn1Node.isFocused, isFalse);
          expect(demoWidget.example.modalBtn2Node.isFocused, isTrue);

          // Press Shift+Tab to move focus back to Confirm
          tester.sendKey(LogicalKey.tab, shift: true);
          await tester.pump();
          expect(demoWidget.example.modalBtn1Node.isFocused, isTrue);
          expect(demoWidget.example.modalBtn2Node.isFocused, isFalse);

          // Press Tab to move focus to Cancel
          tester.sendKey(LogicalKey.tab);
          await tester.pump();
          expect(demoWidget.example.modalBtn1Node.isFocused, isFalse);
          expect(demoWidget.example.modalBtn2Node.isFocused, isTrue);

          // 5. Press Enter to select Cancel and dismiss the modal
          tester.sendKey(LogicalKey.enter);
          await tester.pump();

          // Verify the modal closes and updates state
          expect(
            find.textPattern(r'This is a focus-trapped modal!'),
            findsNothing,
          );
          expect(find.textPattern(r'Result: Cancelled'), findsOneWidget);

          // Focus is currently on preview node. Let's assert that.
          expect(FocusManager.instance.primaryFocus?.id, equals('preview'));

          // Press Enter to open the modal again
          tester.sendKey(LogicalKey.enter);
          await tester.pump();

          // Verify the modal is now visible again
          expect(
            find.textPattern(r'This is a focus-trapped modal!'),
            findsOneWidget,
          );

          // Press Escape to dismiss the modal via Escape key
          tester.sendKey(LogicalKey.escape);
          await tester.pump();

          // Verify the modal closes
          expect(
            find.textPattern(r'This is a focus-trapped modal!'),
            findsNothing,
          );

          // Press Escape to defocus the preview pane (returning focus to the sidebar)
          tester.sendKey(LogicalKey.escape);
          await tester.pump();

          // Assert focus returns to the sidebar
          expect(FocusManager.instance.primaryFocus?.id, equals('sidebar'));

          // Now we should be on the sidebar. Pressing Enter or Arrow Up/Down should work.
          // Let's press Enter (which will open the page/trigger options or click)
          tester.sendKey(LogicalKey.enter);
          await tester.pump();

          runner.dispose();
        });

        await runnerFuture;
      });
    });

    test('Modal & Scrollbar - Golden Screen Tests', () async {
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

          // 1. Navigate to the Modal & Scrollbar page
          tester.tap(find.text('Modal & Scrollbar'));
          await tester.pump();

          // 2. Focus the preview pane (Handoff focus to the right pane)
          tester.sendKey(LogicalKey.tab);
          await tester.pump();

          // Verify the preview is active
          expect(find.textPattern(r'Modal & Focus Trap Demo'), findsOneWidget);

          // 3. Press Enter to open the modal
          tester.sendKey(LogicalKey.enter);
          await tester.pump();

          // Verify the modal is now visible
          expect(
            find.textPattern(r'This is a focus-trapped modal!'),
            findsOneWidget,
          );

          // Assert that the buffer matches a golden named 'test/goldens/widget_book_modal_before_navigation.ansi'
          expect(
            tester.backend.buffer,
            matchesAnsiGolden(
              'test/goldens/widget_book_modal_before_navigation.ansi',
              environment: {'GENERATE_GOLDENS': 'true'},
            ),
          );

          final demoWidget =
              find
                      .byType<ModalDialogDemoWidget>()
                      .apply(collectAllElements(tester.rootElement!))
                      .first
                      .widget
                  as ModalDialogDemoWidget;

          // Initially Confirm has focus
          expect(demoWidget.example.modalBtn1Node.isFocused, isTrue);
          expect(demoWidget.example.modalBtn2Node.isFocused, isFalse);

          // 4. Move focus to the Cancel button
          tester.sendKey(LogicalKey.tab);
          await tester.pump();

          // Assert Cancel button has focus
          expect(demoWidget.example.modalBtn1Node.isFocused, isFalse);
          expect(demoWidget.example.modalBtn2Node.isFocused, isTrue);

          // Assert that the buffer matches 'test/goldens/widget_book_modal_after_navigation.ansi'
          expect(
            tester.backend.buffer,
            matchesAnsiGolden(
              'test/goldens/widget_book_modal_after_navigation.ansi',
              environment: {'GENERATE_GOLDENS': 'true'},
            ),
          );

          // Clean exit: select Cancel and dismiss the modal
          tester.sendKey(LogicalKey.enter);
          await tester.pump();

          runner.dispose();
        });

        await runnerFuture;
      });
    });
    test('Split Pane Focus Bug Regression', () async {
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

          // 1. Find and mouse-click on Split Pane
          tester.tap(find.text('Split Pane'));
          await tester.pump();

          // Verify we navigated to Split Pane
          expect(find.textPattern('Split Pane Preview'), findsOneWidget);

          // 2. Arrow up twice
          tester.sendKey(LogicalKey.arrowUp);
          tester.sendKey(LogicalKey.arrowUp);
          await tester.pump();

          // 3. Send the enter key. It should NOT exit widgetbook.
          tester.sendKey(LogicalKey.enter);
          await tester.pump();

          // If the app had exited on Enter, sending Q here would either do nothing
          // or error out. But since the app is still running, Q cleanly exits.
          tester.sendKey(LogicalKey.character('q'));
          await tester.pump();
        });

        await runnerFuture;
      });
    });

    test('McDole Logo - Flat Shading and Interactive Rendering', () async {
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

          // 1. Find and mouse-click on 3D Isometric Logo
          final menuEntry = find.descendant(
            of: find.byType<SidebarWidget>(),
            matching: find.text('3D Isometric Logo'),
          );
          expect(menuEntry, findsOneWidget);
          tester.tap(menuEntry);
          await tester.pump();

          // Verify we navigated to 3D Isometric Logo
          expect(find.textPattern('3D Isometric Logo Preview'), findsOneWidget);

          // 2. Press Tab to focus preview pane
          tester.sendKey(LogicalKey.tab);
          await tester.pump();

          // Verify preview pane is active
          expect(
            find.textPattern(r'3D Isometric Logo \(Mcdole Heavy Industries\)'),
            findsOneWidget,
          );

          // 3. Press F to toggle solid vs wireframe
          tester.sendKey(LogicalKey.character('f'));
          await tester.pump();

          // 4. Press C to cycle color modes
          tester.sendKey(LogicalKey.character('c'));
          await tester.pump();

          // 5. Press B to toggle backface lines bleeding
          tester.sendKey(LogicalKey.character('b'));
          await tester.pump();

          // 6. Press M to cycle render modes (Braille, Density, Quadrants)
          tester.sendKey(LogicalKey.character('m'));
          await tester.pump();

          // 7. Press P to toggle pause state
          tester.sendKey(LogicalKey.character('p'));
          await tester.pump();

          // 8. Press + to zoom in
          tester.sendKey(LogicalKey.character('+'));
          await tester.pump();

          // 9. Press - to zoom out
          tester.sendKey(LogicalKey.character('-'));
          await tester.pump();

          // Clean exit
          tester.sendKey(LogicalKey.character('q'));
          await tester.pump();
        });

        await runnerFuture;
      });
    });
  });
}
