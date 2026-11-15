import 'dart:math';

import 'package:test/test.dart';
import 'package:termui/termui.dart' hide Modifier;
import 'package:termui_test/termui_test.dart';

void _runInPrompt(
  Widget widget,
  Future<void> Function(TerminalTester tester) body, {
  Point<int> size = const Point(50, 8),
}) {
  final tester = TerminalTester(size: size);
  tester.run(() async {
    final runner = PromptRunner<void>(
      terminal: tester.terminal,
      alternateScreen: true,
      widget: widget,
    );
    await tester.runPrompt(runner, () async {
      await tester.pump();
      await body(tester);
      runner.dispose();
    });
  });
}

void main() {
  setUp(() => FocusManager.instance.setPrimaryFocus(null));

  test(
    'TextField click-to-caret handles wide graphemes and passes wheel/hover/right-click to ListView',
    () {
      var hoveredIdx = -1;
      var unhandledEnter = false;
      final input = TextField(
        initialText: 'ab🔥d',
        onKeyEvent: (ev) => ev.type == KeyType.enter && (unhandledEnter = true),
      );
      _runInPrompt(
        ListView(
          onHover: (idx) => hoveredIdx = idx ?? -1,
          children: [
            SizedBox(
              height: 1,
              child: Focus(autofocus: true, child: const Text('Header')),
            ),
            SizedBox(height: 1, child: input),
            for (var i = 1; i <= 6; i++) Text('Row $i'),
          ],
        ),
        (tester) async {
          final listEl =
              find
                      .byType<ListView>()
                      .apply(collectAllElements(tester.rootElement!))
                      .single
                  as ListViewElement;

          tester.mouseMove(3, 2, drag: false);
          await tester.pump();
          expect(hoveredIdx, equals(1));
          expect(input.focused, isFalse);

          tester.mouseDown(3, 2, button: MouseButton.right);
          tester.mouseUp(3, 2, button: MouseButton.right);
          await tester.pump();
          expect(input.focused, isFalse);

          // Click 2nd column of wide emoji '🔥' (col index 3 -> 1-based x=4) -> caret at grapheme 2.
          tester.mouseDown(4, 2);
          tester.mouseUp(4, 2);
          await tester.pump();
          expect(input.focused, isTrue);
          expect(input.cursorColumn, equals(2));

          tester.sendKey(LogicalKey.enter);
          await tester.pump();
          expect(unhandledEnter, isTrue);

          // Wheel events over focused TextField pass through to ListView.
          tester.mouseDown(4, 2, button: MouseButton.wheelDown);
          await tester.pump();
          expect(listEl.scrollOffset, equals(1));
        },
        size: const Point(40, 4),
      );
    },
  );

  test(
    'FocusNode.seedInitialFocus and FocusScopeNode.syncChildOrder preserve sibling focus and reorder children',
    () {
      final sidebar = FocusNode(id: 'sidebar');
      final nestedScope = FocusScopeNode(id: 'nested');
      final n1 = FocusNode(id: 'n1');
      final n2 = FocusNode(id: 'n2');
      final field = TextField(initialText: 'x', focusNode: n1, focused: true);
      final second = TextField(initialText: 'y', focusNode: n2);

      _runInPrompt(
        Row([
          SizedBox(
            width: 10,
            child: Focus(
              focusNode: sidebar,
              autofocus: true,
              child: const Text('S'),
            ),
          ),
          Expanded(
            child: FocusScope(
              focusNode: nestedScope,
              child: Column([
                SizedBox(height: 1, child: field),
                SizedBox(height: 1, child: second),
              ]),
            ),
          ),
        ]),
        (tester) async {
          expect(FocusManager.instance.primaryFocus, same(sidebar));
          expect(field.focused, isFalse);
          expect(nestedScope.focusedChild, same(n1));

          nestedScope.syncChildOrder([n2, n1]);
          expect(nestedScope.children, equals([n2, n1]));

          nestedScope.requestFocus();
          await tester.pump();
          expect(field.focused, isTrue);
        },
      );
    },
  );
}
