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
}
