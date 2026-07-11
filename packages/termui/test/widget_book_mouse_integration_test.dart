import 'package:test/test.dart';
import 'package:termui/termui.dart';
import 'package:termui_test/termui_test.dart';
import 'package:termui_shared_examples/widget_book/widget_book_examples.dart';
import 'dart:math';
import 'package:termui/terminal/event.dart' as ui;

class TestPlatform implements WidgetBookPlatform {
  void Function(Duration)? _onTick;

  @override
  void startTicker(void Function(Duration) onTick) {
    _onTick = onTick;
  }

  @override
  void stopTicker() {
    _onTick = null;
  }

  void pumpTicker(Duration duration) {
    _onTick?.call(duration);
  }

  @override
  bool get shouldRenderToTerminal => false;

  @override
  void onFrameRedrawn(Buffer buffer) {}

  @override
  bool handleKeyEvent(Terminal terminal, ui.KeyEvent event) => false;

  @override
  String? get initialPage => null;

  @override
  void onExit() {}
}

void main() {
  test('WidgetBook scrolls off screen bug verification', () async {
    final tester = TerminalTester(size: Point(120, 40));
    final platform = TestPlatform();

    tester.run(() async {
      // Instead of pumpWidget, we need to run runWidgetBookShared which uses runPrompt!
      final app = WidgetBookApp(
        terminal: tester.terminal,
        platform: platform,
        isInline: false,
      );

      final runner = PromptRunner<void>(
        terminal: tester.terminal,
        widget: app,
        alternateScreen: true,
      );

      try {
        await tester.runPrompt(runner, () async {
          await tester.pump();

          // Simulate user selecting an item in the sidebar by clicking on the 5th item
          tester.mouseDown(1, 5);
          tester.mouseUp(1, 5);

          await tester.pump();
          platform.pumpTicker(Duration(milliseconds: 16));
          await tester.pump();

          final listViewElement =
              find
                      .byType<ListView>()
                      .apply(collectAllElements(tester.rootElement!))
                      .first
                  as ListViewElement;
          expect(
            listViewElement.selectedIndex,
            greaterThan(0),
            reason: "Sidebar should have responded to keys",
          );
          final originalSelectedIndex = listViewElement.selectedIndex;

          // Move mouse over the sidebar
          tester.mouseMove(5, 5);
          await tester.pump();

          // Ticker rebuilds the app
          platform.pumpTicker(Duration(milliseconds: 16));
          await tester.pump();

          final updatedListViewElement =
              find
                      .byType<ListView>()
                      .apply(collectAllElements(tester.rootElement!))
                      .first
                  as ListViewElement;
          expect(
            updatedListViewElement.selectedIndex,
            equals(originalSelectedIndex),
            reason:
                "Mouse move + ticker rebuild caused the Sidebar ListView selectedIndex to reset to 0! This is the 'scrolls off screen' bug!",
          );

          runner.abort();
        });
      } on PromptAbortedException {
        // Expected
      }
    });
  });

  test('WidgetBook record cast button hit target works', () async {
    final tester = TerminalTester(size: Point(120, 40));
    final platform = TestPlatform();

    tester.run(() async {
      final app = WidgetBookApp(
        terminal: tester.terminal,
        platform: platform,
        isInline: false,
      );

      final runner = PromptRunner<void>(
        terminal: tester.terminal,
        widget: app,
        alternateScreen: true,
      );
      runner.resize(120, 40);

      try {
        await tester.runPrompt(runner, () async {
          await tester.pump();

          // Force a resize event to trigger a rebuild so the WidgetBookApp uses 120x40 instead of 0x0
          runner.resize(120, 40);
          find
              .byType<WidgetBookApp>()
              .apply(collectAllElements(tester.rootElement!))
              .first
              .markNeedsBuild();
          await tester.pump();

          // Get the Text widgets to find the Record Cast button
          var texts = find
              .byType<Text>()
              .apply(collectAllElements(tester.rootElement!))
              .cast<TextElement>();
          var headerText = texts
              .map((e) => (e.widget as Text).data)
              .firstWhere((s) => s.contains('[Record Cast]'), orElse: () => '');
          expect(headerText, contains('⏺ [Record Cast]'));

          // Find the exact X coordinate of the ⏺ symbol
          final startX = headerText.indexOf('⏺');
          expect(startX, greaterThanOrEqualTo(0));

          // Click on the Record Cast button
          tester.mouseDown(startX + 1, 1);
          tester.mouseUp(startX + 1, 1);

          await tester.pump();
          platform.pumpTicker(Duration(milliseconds: 16));
          await tester.pump();

          // Verify the button text changed to Stop Cast
          texts = find
              .byType<Text>()
              .apply(collectAllElements(tester.rootElement!))
              .cast<TextElement>();
          headerText = texts
              .map((e) => (e.widget as Text).data)
              .firstWhere(
                (s) => s.contains('[Stop Cast]') || s.contains('[Record Cast]'),
                orElse: () => '',
              );
          expect(headerText, contains('🔴 [Stop Cast]'));

          // Find the new X coordinate of the 🔴 symbol
          final stopX = headerText.indexOf('🔴');
          expect(stopX, greaterThanOrEqualTo(0));

          // Click on the Stop Cast button
          tester.mouseDown(stopX + 1, 1);
          tester.mouseUp(stopX + 1, 1);

          await tester.pump();
          platform.pumpTicker(Duration(milliseconds: 16));
          await tester.pump();

          // Verify the button text changed back to Record Cast
          texts = find
              .byType<Text>()
              .apply(collectAllElements(tester.rootElement!))
              .cast<TextElement>();
          headerText = texts
              .map((e) => (e.widget as Text).data)
              .firstWhere((s) => s.contains('[Record Cast]'), orElse: () => '');
          expect(headerText, contains('⏺ [Record Cast]'));

          runner.abort();
        });
      } on PromptAbortedException {
        // Expected
      }
    });
  });

  test('WidgetBook MouseCursors highlights and changes OS pointer', () async {
    final tester = TerminalTester(size: Point(120, 40));
    final platform = TestPlatform();

    tester.run(() async {
      final app = WidgetBookApp(
        terminal: tester.terminal,
        platform: platform,
        isInline: false,
      );

      final runner = PromptRunner<void>(
        terminal: tester.terminal,
        widget: app,
        alternateScreen: true,
      );
      runner.resize(120, 40);

      try {
        await tester.runPrompt(runner, () async {
          await tester.pump();
          runner.resize(120, 40);
          find
              .byType<WidgetBookApp>()
              .apply(collectAllElements(tester.rootElement!))
              .first
              .markNeedsBuild();
          await tester.pump();

          // Scroll down to the 17th item in the sidebar by pressing Down 16 times
          for (var i = 0; i < 16; i++) {
            tester.sendKey(LogicalKey.arrowDown);
            await tester.pump();
          }

          // Verify we reached the Mouse Cursors page
          final texts = find
              .byType<Text>()
              .apply(collectAllElements(tester.rootElement!))
              .cast<TextElement>();
          final hasMouseCursorsTitle = texts
              .map((e) => (e.widget as Text).data)
              .any((s) => s.contains('[ DEFAULT ]') || s.contains('[ TEXT ]'));
          expect(hasMouseCursorsTitle, isTrue);

          // Simulate hovering over the [ HELP ] cursor box
          // Layout info: PreviewPane starts at x=31, y=1.
          // help cursor is index 4 (row 1, col 1 in a 3x7 grid)
          // Width: 89, Height: 38
          // colWidth = 29, rowHeight = 5
          // Center of col 1, row 1 is roughly localX = 43, localY = 7
          // absolute x = 31 + 43 = 74, y = 3 + 7 = 10 (event.y = 11)

          final mockBackend = tester.terminal.backend as MockTerminalBackend;
          mockBackend.clearStdout();

          tester.mouseMove(74, 11);
          await tester.pump();
          platform.pumpTicker(Duration(milliseconds: 16));
          await tester.pump();

          // Check if the UI highlighted it and OS pointer changed to "help"
          expect(mockBackend.stdout, contains('\x1b]22;help\x1b\\'));
          // Verify that the UI background is set to the 'charple' highlight color
          expect(mockBackend.stdout, contains('\x1b[48;2;107;80;255m'));

          runner.abort();
        });
      } on PromptAbortedException {
        // Expected
      }
    });
  });
}
