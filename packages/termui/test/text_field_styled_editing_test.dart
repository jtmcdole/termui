import 'dart:math';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:termui/termui.dart';
import 'package:termui/ui/event.dart' as ev;
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

String _rowText(Buffer buf, int y) => [
  for (var x = 0; x < buf.width; x++) buf.getCharacter(x, y),
].join().trimRight();

class _RebuildableTextField extends StatefulWidget {
  final TextEditingController controller;
  final int height;
  final void Function(void Function() triggerRebuild) onMount;

  const _RebuildableTextField({
    required this.controller,
    required this.onMount,
    this.height = 4,
  });

  @override
  State<_RebuildableTextField> createState() => _RebuildableTextFieldState();
}

class _RebuildableTextFieldState extends State<_RebuildableTextField> {
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    widget.onMount(_triggerRebuild);
  }

  void _triggerRebuild() {
    if (mounted) {
      setState(() => _generation++);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 24,
      height: widget.height,
      child: TextField(
        key: ValueKey<int>(_generation),
        controller: widget.controller,
        multiline: true,
        focused: true,
      ),
    );
  }
}

void main() {
  setUp(() {
    FocusManager.instance.setPrimaryFocus(null);
  });

  group(
    'TextField controller scroll persistence, wheel, and PageUp/PageDown',
    () {
      test(
        'persists scrollOffset and horizontalScrollOffset on controller across rebuilds and notifies listeners',
        () {
          final tester = TerminalTester(size: const Point(30, 6));
          tester.run(() async {
            final lines = [for (var i = 0; i < 20; i++) 'line_$i'];
            final controller = TextEditingController(text: lines.join('\n'));
            var listenerCalls = 0;
            controller.addListener(() => listenerCalls++);

            late void Function() triggerRebuild;
            final runner = PromptRunner<void>(
              terminal: tester.terminal,
              widget: _RebuildableTextField(
                controller: controller,
                height: 4,
                onMount: (fn) => triggerRebuild = fn,
              ),
              alternateScreen: false,
            );

            await tester.runPrompt(runner, () async {
              try {
                await tester.pump();
                // Cursor started at line 19, so top visible line is 16.
                expect(controller.scrollOffset, equals(16));
                expect(_rowText(runner.currentBuffer!, 0), equals('line_16'));

                // Scroll manually to line 5 and verify rebuild preserves it.
                final beforeCalls = listenerCalls;
                controller.scrollOffset = 5;
                controller.horizontalScrollOffset = 2;
                expect(listenerCalls, greaterThan(beforeCalls));

                triggerRebuild();
                await tester.pump();
                expect(controller.scrollOffset, equals(5));
                expect(controller.horizontalScrollOffset, equals(2));
                expect(_rowText(runner.currentBuffer!, 0), equals('ne_5'));
              } finally {
                runner.dispose();
              }
            });
          });
        },
      );

      test('handles mouse wheel scroll on multiline TextField', () {
        final tester = TerminalTester(size: const Point(30, 6));
        tester.run(() async {
          final lines = [for (var i = 0; i < 20; i++) 'row_$i'];
          final controller = TextEditingController(text: lines.join('\n'));
          controller.value = TextEditingValue(
            text: lines.join('\n'),
            selection: const TextSelection.collapsed(
              offset: 0,
              line: 0,
              column: 0,
            ),
          );

          final runner = PromptRunner<void>(
            terminal: tester.terminal,
            widget: SizedBox(
              width: 20,
              height: 4,
              child: TextField(
                controller: controller,
                multiline: true,
                focused: true,
              ),
            ),
            alternateScreen: false,
          );

          await tester.runPrompt(runner, () async {
            try {
              await tester.pump();
              expect(controller.scrollOffset, equals(0));
              expect(_rowText(runner.currentBuffer!, 0), equals('row_0'));

              tester.mouseDown(2, 2, button: MouseButton.wheelDown);
              await tester.pump();
              expect(controller.scrollOffset, equals(3));
              expect(_rowText(runner.currentBuffer!, 0), equals('row_3'));

              tester.mouseDown(2, 2, button: MouseButton.wheelUp);
              await tester.pump();
              expect(controller.scrollOffset, equals(0));
              expect(_rowText(runner.currentBuffer!, 0), equals('row_0'));
            } finally {
              runner.dispose();
            }
          });
        });
      });

      test(
        'PageDown and PageUp move cursor by viewport page in multiline mode',
        () {
          final lines = [for (var i = 0; i < 25; i++) 'line_$i'];
          final controller = TextEditingController(text: lines.join('\n'));
          controller.value = TextEditingValue(
            text: lines.join('\n'),
            selection: const TextSelection.collapsed(
              offset: 0,
              line: 0,
              column: 2,
            ),
          );

          final field = TextField(
            controller: controller,
            multiline: true,
            focused: true,
          );
          final element = field.createElement();
          element.mount(null);
          element.rebuild();
          element.layout(BoxConstraints.tight(const Size(20, 6)));

          // Viewport height 6 -> page step is 5 lines.
          expect(
            field.handleKeyEvent(const KeyEvent('pageDown', KeyType.pageDown)),
            isTrue,
          );
          expect(field.cursorLine, equals(5));
          expect(field.cursorColumn, equals(2));

          expect(
            field.handleKeyEvent(const KeyEvent('pageDown', KeyType.pageDown)),
            isTrue,
          );
          expect(field.cursorLine, equals(10));

          expect(
            field.handleKeyEvent(const KeyEvent('pageUp', KeyType.pageUp)),
            isTrue,
          );
          expect(field.cursorLine, equals(5));

          // Single-line field does not consume PageUp/PageDown.
          final singleLine = TextField(initialText: 'abc', multiline: false);
          expect(
            singleLine.handleKeyEvent(
              const KeyEvent('pageDown', KeyType.pageDown),
            ),
            isFalse,
          );
          expect(
            singleLine.handleKeyEvent(const KeyEvent('pageUp', KeyType.pageUp)),
            isFalse,
          );

          element.unmount();
        },
      );
    },
  );

  group('TextField multi-line insertText, tabSize, redo, and undo coalescing', () {
    test(
      'insertText handles CRLF/LF multi-line paste and single-line strip',
      () {
        final controller = TextEditingController(text: 'ab');
        controller.value = const TextEditingValue(
          text: 'ab',
          selection: TextSelection.collapsed(offset: 1, line: 0, column: 1),
        );

        controller.insertText('1\r\n2\n3');
        expect(controller.text, equals('a1\n2\n3b'));
        expect(controller.value.selection.cursorLine, equals(2));
        expect(controller.value.selection.cursorColumn, equals(1));

        // Single undo reverts the whole multi-line paste.
        controller.undo();
        expect(controller.text, equals('ab'));

        // Single-line mode strips line breaks.
        controller.insertText('x\r\ny', multiline: false);
        expect(controller.text, equals('axyb'));
      },
    );

    test(
      'tabSize inserts spaces when set and preserves Tab pass-through by default',
      () {
        final defaultField = TextField(initialText: 'abc', multiline: true);
        expect(
          defaultField.handleKeyEvent(const KeyEvent('tab', KeyType.tab)),
          isFalse,
        );
        expect(defaultField.value, equals('abc'));

        final tabbedField = TextField(
          initialText: 'abc',
          multiline: true,
          tabSize: 2,
        );
        expect(
          tabbedField.handleKeyEvent(const KeyEvent('tab', KeyType.tab)),
          isTrue,
        );
        expect(tabbedField.value, equals('abc  '));
        expect(tabbedField.cursorColumn, equals(5));

        // Shift+Tab still passes through for reverse focus traversal.
        expect(
          tabbedField.handleKeyEvent(
            const KeyEvent('tab', KeyType.tab, modifiers: {ev.Modifier.shift}),
          ),
          isFalse,
        );

        expect(() => TextField(tabSize: 0), throwsArgumentError);
        expect(() => TextField(tabSize: -2), throwsArgumentError);
      },
    );

    test('Ctrl+Shift+Z triggers redo', () {
      final field = TextField(initialText: 'hi', multiline: true);
      field.handleKeyEvent(const KeyEvent('!', KeyType.character));
      expect(field.value, equals('hi!'));

      field.handleKeyEvent(
        const KeyEvent(
          'z',
          KeyType.character,
          modifiers: {ev.Modifier.control},
        ),
      );
      expect(field.value, equals('hi'));

      field.handleKeyEvent(
        const KeyEvent(
          'z',
          KeyType.character,
          modifiers: {ev.Modifier.control, ev.Modifier.shift},
        ),
      );
      expect(field.value, equals('hi!'));
    });

    test(
      'clock-driven undo coalescing merges fast bursts and breaks on pause/newline/paste/delete',
      () {
        fakeAsync((async) {
          final controller = TextEditingController(
            text: '',
            undoCoalesceWindow: const Duration(milliseconds: 500),
          );
          final field = TextField(controller: controller, multiline: true);

          // Fast burst 'abc' within 500ms coalesces into one undo step.
          field.handleKeyEvent(const KeyEvent('a', KeyType.character));
          async.elapse(const Duration(milliseconds: 100));
          field.handleKeyEvent(const KeyEvent('b', KeyType.character));
          async.elapse(const Duration(milliseconds: 100));
          field.handleKeyEvent(const KeyEvent('c', KeyType.character));
          expect(field.value, equals('abc'));

          // Pause beyond 500ms starts a new undo burst 'de'.
          async.elapse(const Duration(milliseconds: 600));
          field.handleKeyEvent(const KeyEvent('d', KeyType.character));
          async.elapse(const Duration(milliseconds: 50));
          field.handleKeyEvent(const KeyEvent('e', KeyType.character));
          expect(field.value, equals('abcde'));

          // Newline breaks burst immediately.
          field.handleKeyEvent(const KeyEvent('enter', KeyType.enter));
          expect(field.value, equals('abcde\n'));

          // Paste breaks burst immediately.
          controller.insertText('XY');
          expect(field.value, equals('abcde\nXY'));

          // Deletion breaks burst immediately.
          field.handleKeyEvent(const KeyEvent('backspace', KeyType.backspace));
          expect(field.value, equals('abcde\nX'));

          // Undo step 1: reverts backspace.
          controller.undo();
          expect(field.value, equals('abcde\nXY'));

          // Undo step 2: reverts paste.
          controller.undo();
          expect(field.value, equals('abcde\n'));

          // Undo step 3: reverts newline.
          controller.undo();
          expect(field.value, equals('abcde'));

          // Undo step 4: reverts second typing burst 'de'.
          controller.undo();
          expect(field.value, equals('abc'));

          // Undo step 5: reverts first typing burst 'abc'.
          controller.undo();
          expect(field.value, equals(''));

          // Explicit saveStateToHistory() also breaks an active burst.
          withClock(async.getClock(DateTime(2026, 11, 24)), () {
            field.handleKeyEvent(const KeyEvent('1', KeyType.character));
            controller.saveStateToHistory();
            field.handleKeyEvent(const KeyEvent('2', KeyType.character));
            expect(field.value, equals('12'));
            controller.undo();
            expect(field.value, equals('1'));
          });
        });
      },
    );
  });
}
