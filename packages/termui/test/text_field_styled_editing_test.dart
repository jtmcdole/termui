import 'dart:math';

import 'package:characters/characters.dart';
import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:termui/syntax.dart';
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

  group('TextField spanBuilder & RichText/TextSpan styling', () {
    test(
      'renders TextSpan fg/bg/UnderlineStyle.curly + SGR 58 underlineColor, merges cursor style, handles wide graphemes, and clears trailing/EOL squiggles on reused buffers',
      () {
        const keywordColor = Color(0x56, 0x9C, 0xD6);
        const bgTint = Color(0x1E, 0x22, 0x2A);
        const squiggleColor = Color(0xFF, 0x44, 0x44);
        const cursorBg = Color(0x44, 0x55, 0x66);

        final controller = TextEditingController(text: 'vec 🔥x\nerr');
        // Place cursor on 'v' (line 0, col 0) first.
        controller.value = const TextEditingValue(
          text: 'vec 🔥x\nerr',
          selection: TextSelection.collapsed(offset: 0, line: 0, column: 0),
        );

        var includeSquiggle = true;
        TextSpan buildSpans(String text, Style baseStyle) {
          if (!includeSquiggle) {
            return TextSpan(text: text, style: baseStyle);
          }
          return TextSpan(
            style: baseStyle,
            children: const <TextSpan>[
              TextSpan(
                text: 'vec',
                style: Style(
                  foreground: keywordColor,
                  background: bgTint,
                  modifiers: Modifier.bold,
                ),
              ),
              TextSpan(text: ' '),
              TextSpan(
                text: '🔥',
                style: Style(
                  foreground: Color(0xFF, 0xCC, 0x00),
                  underlineStyle: UnderlineStyle.curly,
                  underlineColor: squiggleColor,
                ),
              ),
              TextSpan(text: 'x\n'),
              TextSpan(
                text: 'err',
                style: Style(
                  underlineStyle: UnderlineStyle.curly,
                  underlineColor: squiggleColor,
                ),
              ),
            ],
          );
        }

        final field = TextField(
          controller: controller,
          multiline: true,
          focused: true,
          cursorStyle: const Style(
            background: cursorBg,
            modifiers: Modifier.reverse,
          ),
          spanBuilder: buildSpans,
        );

        final element = field.createElement();
        element.mount(null);
        element.rebuild();
        element.layout(BoxConstraints.tight(const Size(12, 3)));

        final buffer = Buffer.blank(12, 3);
        // Seed stale SGR 58 underlineColor across entire buffer to prove clearing.
        for (var y = 0; y < 3; y++) {
          for (var x = 0; x < 12; x++) {
            buffer.setUnderlineColor(x, y, 0xFF00FF00);
          }
        }

        element.paint(buffer, Offset.zero);

        // Cell (0, 0) is 'v' under cursor: preserves token fg & bold, merges cursor bg & reverse.
        expect(buffer.getCharacter(0, 0), equals('v'));
        expect(buffer.getForeground(0, 0), equals(keywordColor.argb));
        expect(buffer.getBackground(0, 0), equals(cursorBg.argb));
        expect(Modifier.has(buffer.getModifiers(0, 0), Modifier.bold), isTrue);
        expect(
          Modifier.has(buffer.getModifiers(0, 0), Modifier.reverse),
          isTrue,
        );
        expect(buffer.getUnderlineColor(0, 0), equals(0));

        // Cell (1, 0) is 'e': styled token without cursor.
        expect(buffer.getCharacter(1, 0), equals('e'));
        expect(buffer.getForeground(1, 0), equals(keywordColor.argb));
        expect(buffer.getBackground(1, 0), equals(bgTint.argb));

        // Wide grapheme '🔥' at columns 4 and 5 carries curly underline + SGR 58 on both cells.
        expect(buffer.getCharacter(4, 0), equals('🔥'));
        expect(
          Modifier.getUnderlineStyle(buffer.getModifiers(4, 0)),
          equals(UnderlineStyle.curly),
        );
        expect(buffer.getUnderlineColor(4, 0), equals(squiggleColor.argb));
        expect(buffer.getUnderlineColor(5, 0), equals(squiggleColor.argb));
        expect(
          Modifier.getUnderlineStyle(buffer.getModifiers(5, 0)),
          equals(UnderlineStyle.curly),
        );

        // Trailing space at column 7 cleared stale underlineColor to 0.
        expect(buffer.getCharacter(7, 0), equals(' '));
        expect(buffer.getUnderlineColor(7, 0), equals(0));

        // Line 1 'err' has curly squiggle color.
        expect(buffer.getUnderlineColor(0, 1), equals(squiggleColor.argb));
        expect(buffer.getUnderlineColor(2, 1), equals(squiggleColor.argb));
        expect(buffer.getUnderlineColor(3, 1), equals(0));

        // Move cursor to EOL of line 1 (col 3) and remove squiggles: verify
        // EOL cursor and previously squiggled cells clear underlineColor to 0.
        includeSquiggle = false;
        controller.value = const TextEditingValue(
          text: 'vec 🔥x\nerr',
          selection: TextSelection.collapsed(offset: 10, line: 1, column: 3),
        );
        element.rebuild();
        element.layout(BoxConstraints.tight(const Size(12, 3)));
        element.paint(buffer, Offset.zero);

        expect(buffer.getUnderlineColor(0, 1), equals(0));
        expect(buffer.getUnderlineColor(2, 1), equals(0));
        expect(buffer.getUnderlineColor(3, 1), equals(0));
        expect(buffer.getBackground(3, 1), equals(cursorBg.argb));
        expect(buffer.getUnderlineColor(4, 0), equals(0));
        expect(buffer.getUnderlineColor(5, 0), equals(0));

        element.unmount();
      },
    );
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

    test(
      'supports multi-line Shift/Ctrl+A/mouse-drag selection, visual highlight, and single-undo block delete/replace',
      () {
        final controller = TextEditingController(
          text: 'line one\nline two\nline three\nline four',
        );
        controller.value = TextEditingValue(
          text: controller.text,
          selection: const TextSelection.collapsed(offset: 0),
        );
        const selBg = Color(0x22, 0x44, 0x88);
        const selFg = Color(0xFF, 0xFF, 0xFF);
        final field = TextField(
          controller: controller,
          multiline: true,
          tabSize: 2,
          selectionStyle: const Style(foreground: selFg, background: selBg),
          spanBuilder: (text, baseStyle) => TextSpan(
            text: text,
            style: const Style(foreground: Color(0xCC, 0xCC, 0xCC)),
          ),
        );

        final elem = field.createElement();
        elem.mount(null);
        elem.layout(BoxConstraints.tight(const Size(30, 6)));
        MouseEventConsumer? consumer;
        void findConsumer(Element e) {
          if (e case final MouseEventConsumer c) {
            consumer = c;
            return;
          }
          e.visitChildren(findConsumer);
        }

        findConsumer(elem);
        final renderElem = consumer!;

        // Shift+Down selects across line 0 into line 1.
        field.handleKeyEvent(
          const KeyEvent('', KeyType.down, modifiers: {ev.Modifier.shift}),
        );
        field.handleKeyEvent(
          const KeyEvent('', KeyType.end, modifiers: {ev.Modifier.shift}),
        );
        expect(controller.selectedText, equals('line one\nline two'));

        // Visual selection highlight paints selBg on selected styled cells and EOL.
        final highlighted = Buffer.blank(30, 6);
        elem.paint(highlighted, Offset.zero);
        expect(highlighted.getBackground(0, 0), equals(selBg.argb));
        expect(highlighted.getBackground(8, 0), equals(selBg.argb));
        expect(highlighted.getBackground(2, 1), equals(selBg.argb));

        // Escape collapses selection without deleting text.
        expect(
          field.handleKeyEvent(const KeyEvent('', KeyType.escape)),
          isTrue,
        );
        expect(controller.value.selection.isCollapsed, isTrue);
        expect(controller.selectedText, isEmpty);

        // Mouse press on (0, 1) + drag to (4, 2) selects across lines 1..2.
        expect(
          renderElem.handleMouseEvent(
            const MouseEvent(
              x: 1,
              y: 2,
              button: MouseButton.left,
              type: MouseEventType.press,
            ),
            0,
            1,
          ),
          isTrue,
        );
        expect(
          renderElem.handleMouseEvent(
            const MouseEvent(
              x: 5,
              y: 3,
              button: MouseButton.left,
              type: MouseEventType.drag,
            ),
            4,
            2,
          ),
          isTrue,
        );
        expect(controller.selectedText, equals('line two\nline'));

        // Backspace deletes the selected block in one undoable step.
        field.handleKeyEvent(const KeyEvent('', KeyType.backspace));
        expect(field.value, equals('line one\n three\nline four'));
        controller.undo();
        expect(
          field.value,
          equals('line one\nline two\nline three\nline four'),
        );

        // Ctrl+A selects all, typing replaces the entire buffer cleanly.
        field.handleKeyEvent(
          const KeyEvent(
            'a',
            KeyType.character,
            modifiers: {ev.Modifier.control},
          ),
        );
        expect(controller.selectedText, equals(field.value));
        field.handleKeyEvent(const KeyEvent('x', KeyType.character));
        expect(field.value, equals('x'));
        controller.undo();
        expect(
          field.value,
          equals('line one\nline two\nline three\nline four'),
        );

        // Left arrow collapses selection to start; Right arrow collapses to end.
        field.handleKeyEvent(
          const KeyEvent(
            'a',
            KeyType.character,
            modifiers: {ev.Modifier.control},
          ),
        );
        field.handleKeyEvent(const KeyEvent('', KeyType.left));
        expect(controller.value.selection.isCollapsed, isTrue);
        expect(controller.value.selection.baseOffset, equals(0));
        field.handleKeyEvent(
          const KeyEvent(
            'a',
            KeyType.character,
            modifiers: {ev.Modifier.control},
          ),
        );
        field.handleKeyEvent(const KeyEvent('', KeyType.right));
        expect(controller.value.selection.isCollapsed, isTrue);
        expect(
          controller.value.selection.baseOffset,
          equals(field.value.characters.length),
        );
      },
    );

    test(
      'auto-scroll does not notify during layout, no-op scrollOffset keeps auto-scroll active, wide cursor stays visible, off-screen EOL does not paint at col 0, CRLF splits styled lines, and Shift+Up/Down stay inside multiline field',
      () {
        // H1 + M1: Layout auto-scroll must not notify listeners, and no-op
        // scrollOffset = 0 assignment must not lock manual scroll.
        var notifyCount = 0;
        final scrollCtrl = TextEditingController(
          text: 'line0\nline1\nline2\nline3\nline4',
        );
        scrollCtrl.addListener(() => notifyCount++);
        scrollCtrl.scrollOffset = 0; // no-op should not lock manual scroll
        scrollCtrl.horizontalScrollOffset = 0;
        expect(notifyCount, equals(0));

        final scrollField = TextField(
          controller: scrollCtrl,
          multiline: true,
          focused: true,
        );
        final scrollEl = scrollField.createElement();
        scrollEl.mount(null);
        scrollEl.layout(BoxConstraints.tight(const Size(20, 2)));
        expect(scrollCtrl.scrollOffset, equals(3));
        expect(notifyCount, equals(0));
        scrollEl.unmount();

        // H2: Wide emoji glyph at right edge of viewport stays visible.
        final wideCtrl = TextEditingController(text: '0123456789🔥');
        wideCtrl.value = const TextEditingValue(
          text: '0123456789🔥',
          selection: TextSelection.collapsed(offset: 10, line: 0, column: 10),
        );
        final wideField = TextField(
          controller: wideCtrl,
          multiline: false,
          focused: true,
        );
        final wideEl = wideField.createElement();
        wideEl.mount(null);
        wideEl.layout(BoxConstraints.tight(const Size(10, 1)));
        expect(wideCtrl.horizontalScrollOffset, equals(2));
        final wideBuf = Buffer.blank(10, 1);
        wideEl.paint(wideBuf, Offset.zero);
        expect(wideBuf.getCharacter(8, 0), equals('🔥'));
        wideEl.unmount();

        // M2: Off-screen EOL selection/cursor must not paint at screen col 0.
        final eolCtrl = TextEditingController(text: '0123456789abcdef\nhi');
        eolCtrl.value = const TextEditingValue(
          text: '0123456789abcdef\nhi',
          selection: TextSelection(
            baseOffset: 0,
            extentOffset: 19,
            cursorLine: 1,
            cursorColumn: 2,
          ),
        );
        eolCtrl.horizontalScrollOffset = 10;
        final eolField = TextField(
          controller: eolCtrl,
          multiline: true,
          focused: true,
          selectionStyle: const Style(background: Colors.blue),
          cursorStyle: const Style(background: Colors.green),
        );
        final eolEl = eolField.createElement();
        eolEl.mount(null);
        eolEl.layout(BoxConstraints.tight(const Size(10, 2)));
        final eolBuf = Buffer.blank(10, 2);
        eolEl.paint(eolBuf, Offset.zero);
        expect(eolBuf.getBackground(0, 1), isNot(equals(Colors.blue.argb)));
        expect(eolBuf.getBackground(0, 1), isNot(equals(Colors.green.argb)));
        eolEl.unmount();

        // M3: CRLF styled lines split cleanly across rows.
        final crlfCtrl = TextEditingController(text: 'first\r\nsecond');
        final crlfField = TextField(
          controller: crlfCtrl,
          multiline: true,
          focused: false,
          spanBuilder: (text, baseStyle) =>
              TextSpan(text: text, style: baseStyle),
        );
        final crlfEl = crlfField.createElement();
        crlfEl.mount(null);
        crlfEl.layout(BoxConstraints.tight(const Size(10, 2)));
        final crlfBuf = Buffer.blank(10, 2);
        crlfEl.paint(crlfBuf, Offset.zero);
        expect(crlfBuf.getCharacter(0, 0), equals('f'));
        expect(crlfBuf.getCharacter(0, 1), equals('s'));
        crlfEl.unmount();

        // M4: Shift+Up on line 0 and Shift+Down on last line stay handled.
        final selCtrl = TextEditingController(text: 'top\nbottom');
        selCtrl.value = const TextEditingValue(
          text: 'top\nbottom',
          selection: TextSelection.collapsed(offset: 0, line: 0, column: 0),
        );
        final selField = TextField(
          controller: selCtrl,
          multiline: true,
          focused: true,
        );
        expect(
          selField.handleKeyEvent(
            const KeyEvent('', KeyType.up, modifiers: {ev.Modifier.shift}),
          ),
          isTrue,
        );
        selCtrl.value = const TextEditingValue(
          text: 'top\nbottom',
          selection: TextSelection.collapsed(offset: 10, line: 1, column: 6),
        );
        expect(
          selField.handleKeyEvent(
            const KeyEvent('', KeyType.down, modifiers: {ev.Modifier.shift}),
          ),
          isTrue,
        );
      },
    );
  });

  group('TextField review regressions (H1-H9, M1-M5, M9)', () {
    MouseEventConsumer findMouseConsumer(Element root) {
      MouseEventConsumer? consumer;
      void visit(Element e) {
        if (e case final MouseEventConsumer c) {
          consumer = c;
          return;
        }
        e.visitChildren(visit);
      }

      visit(root);
      return consumer!;
    }

    test('H1: out-of-bounds external TextEditingValue is clamped safely', () {
      final controller = TextEditingController(text: 'hello');
      controller.value = const TextEditingValue(
        text: 'hello',
        selection: TextSelection.collapsed(offset: 10, line: 3, column: 9),
      );
      final field = TextField(controller: controller, multiline: true);

      expect(
        () => field.handleKeyEvent(const KeyEvent('', KeyType.right)),
        returnsNormally,
      );
      expect(field.cursorLine, equals(0));
      expect(field.cursorColumn, equals(5));

      controller.value = const TextEditingValue(
        text: 'hello',
        selection: TextSelection.collapsed(offset: 10, line: 3, column: 9),
      );
      expect(
        () => field.handleKeyEvent(
          const KeyEvent('', KeyType.left, modifiers: {ev.Modifier.control}),
        ),
        returnsNormally,
      );
      expect(field.cursorColumn, equals(0));

      controller.value = const TextEditingValue(
        text: 'hello',
        selection: TextSelection.collapsed(offset: 10, line: 3, column: 9),
      );
      expect(
        () => field.handleKeyEvent(const KeyEvent('!', KeyType.character)),
        returnsNormally,
      );
      expect(field.value, equals('hello!'));

      // Collapsing an out-of-bounds selection clamps offsets to text length.
      controller.value = const TextEditingValue(
        text: 'hi',
        selection: TextSelection(
          baseOffset: 0,
          extentOffset: 99,
          cursorLine: 4,
          cursorColumn: 99,
        ),
      );
      field.handleKeyEvent(const KeyEvent('', KeyType.right));
      expect(controller.value.selection.baseOffset, equals(2));
      expect(controller.value.selection.cursorLine, equals(0));
      expect(controller.value.selection.cursorColumn, equals(2));

      controller.value = const TextEditingValue(
        text: 'hi',
        selection: TextSelection(
          baseOffset: 0,
          extentOffset: 99,
          cursorLine: 4,
          cursorColumn: 99,
        ),
      );
      field.handleKeyEvent(const KeyEvent('', KeyType.escape));
      expect(controller.value.selection.isCollapsed, isTrue);
      expect(controller.value.selection.baseOffset, equals(2));
    });

    test(
      'H2: CRLF grapheme offsets, editing, mouse selection, and plain/styled paint stay synchronized',
      () {
        // insertText at line 1 col 0 inserts before first char of line 1.
        final ctrl = TextEditingController(text: 'first\r\nsecond');
        ctrl.value = const TextEditingValue(
          text: 'first\r\nsecond',
          selection: TextSelection.collapsed(offset: 6, line: 1, column: 0),
        );
        ctrl.insertText('X');
        expect(ctrl.text, equals('first\r\nXsecond'));
        expect(ctrl.value.selection.cursorLine, equals(1));
        expect(ctrl.value.selection.cursorColumn, equals(1));

        // Plain paint on CRLF must not emit raw '\r' into buffer cells.
        final plainCtrl = TextEditingController(text: 'first\r\nsecond');
        final plainField = TextField(
          controller: plainCtrl,
          multiline: true,
          focused: false,
        );
        final plainEl = plainField.createElement()
          ..mount(null)
          ..layout(BoxConstraints.tight(const Size(12, 2)));
        final plainBuf = Buffer.blank(12, 2);
        plainEl.paint(plainBuf, Offset.zero);
        expect(plainBuf.getCharacter(5, 0), equals(' '));
        expect(_rowText(plainBuf, 0), equals('first'));
        expect(_rowText(plainBuf, 1), equals('second'));

        // Mouse selection on line 1 col 0..1 selects 's'.
        final consumer = findMouseConsumer(plainEl);
        consumer.handleMouseEvent(
          const MouseEvent(
            x: 1,
            y: 2,
            button: MouseButton.left,
            type: MouseEventType.press,
          ),
          0,
          1,
        );
        consumer.handleMouseEvent(
          const MouseEvent(
            x: 2,
            y: 2,
            button: MouseButton.left,
            type: MouseEventType.drag,
          ),
          1,
          1,
        );
        expect(plainCtrl.selectedText, equals('s'));
        plainEl.unmount();

        // Ctrl+A highlights last char on CRLF styled line and Right lands at col 6.
        const selBg = Color(0x22, 0x44, 0x88);
        final styledCtrl = TextEditingController(text: 'first\r\nsecond');
        final styledField = TextField(
          controller: styledCtrl,
          multiline: true,
          focused: false,
          selectionStyle: const Style(background: selBg),
          spanBuilder: (text, baseStyle) =>
              TextSpan(text: text, style: baseStyle),
        );
        styledField.handleKeyEvent(
          const KeyEvent(
            'a',
            KeyType.character,
            modifiers: {ev.Modifier.control},
          ),
        );
        final styledEl = styledField.createElement()
          ..mount(null)
          ..layout(BoxConstraints.tight(const Size(12, 2)));
        final styledBuf = Buffer.blank(12, 2);
        styledEl.paint(styledBuf, Offset.zero);
        expect(styledBuf.getBackground(5, 1), equals(selBg.argb));
        styledEl.unmount();

        styledField.handleKeyEvent(const KeyEvent('', KeyType.right));
        expect(styledField.cursorLine, equals(1));
        expect(styledField.cursorColumn, equals(6));

        // Typing at EOL of CRLF line 0 preserves CRLF; Backspace at (1, 0) merges cleanly.
        final editCtrl = TextEditingController(text: 'first\r\nsecond');
        editCtrl.value = const TextEditingValue(
          text: 'first\r\nsecond',
          selection: TextSelection.collapsed(offset: 5, line: 0, column: 5),
        );
        final editField = TextField(controller: editCtrl, multiline: true);
        editField.handleKeyEvent(const KeyEvent('!', KeyType.character));
        expect(editField.value, equals('first!\r\nsecond'));
        expect(editField.cursorLine, equals(0));
        expect(editField.cursorColumn, equals(6));

        editField.handleKeyEvent(const KeyEvent('', KeyType.right));
        expect(editField.cursorLine, equals(1));
        expect(editField.cursorColumn, equals(0));
        editField.handleKeyEvent(const KeyEvent('', KeyType.backspace));
        expect(editField.value, equals('first!second'));
        expect(editField.cursorLine, equals(0));
        expect(editField.cursorColumn, equals(6));
      },
    );

    test(
      'H3 & H4: combining marks and regional indicator pairs keep cursor in bounds',
      () {
        // H3a: combining mark after base char does not push cursorColumn past EOL.
        final combiningField = TextField(initialText: 'e', multiline: false);
        combiningField.handleKeyEvent(
          const KeyEvent('\u0301', KeyType.character),
        );
        expect(combiningField.value, equals('e\u0301'));
        expect(combiningField.value.characters.length, equals(1));
        expect(combiningField.cursorColumn, equals(1));
        combiningField.handleKeyEvent(
          const KeyEvent('', KeyType.left, modifiers: {ev.Modifier.control}),
        );
        expect(combiningField.cursorColumn, equals(0));

        // H3b: regional indicator pair merges into one flag grapheme and deletes cleanly.
        final flagField = TextField(initialText: '🇺', multiline: false);
        flagField.handleKeyEvent(const KeyEvent('🇸', KeyType.character));
        expect(flagField.value, equals('🇺🇸'));
        expect(flagField.cursorColumn, equals(1));
        flagField.handleKeyEvent(const KeyEvent('', KeyType.backspace));
        expect(flagField.value, isEmpty);

        // H4: insertText with combining mark keeps cursor on line 0.
        final multi = TextEditingController(text: 'e\nnext');
        multi.value = const TextEditingValue(
          text: 'e\nnext',
          selection: TextSelection.collapsed(offset: 1, line: 0, column: 1),
        );
        multi.insertText('\u0301');
        expect(multi.text, equals('e\u0301\nnext'));
        expect(multi.value.selection.cursorLine, equals(0));
        expect(multi.value.selection.cursorColumn, equals(1));
      },
    );

    test(
      'H5: 60 repaints of 2000-line doc with cached spanBuilder stay under 4ms/frame',
      () {
        final source = [
          for (var i = 0; i < 2000; i++)
            'vec4 c$i = texture(iChannel0, uv) + sin(iTime * 0.5) * float($i);',
        ].join('\n');
        final controller = TextEditingController(text: source);
        final highlighter = SyntaxTextHighlighter(language: kGlslLanguageId);
        final field = TextField(
          controller: controller,
          multiline: true,
          style: const Style(background: Color(0x14, 0x17, 0x1F)),
          spanBuilder: highlighter.buildFieldSpan,
        );
        final el = field.createElement()
          ..mount(null)
          ..rebuild();
        el.layout(BoxConstraints.tight(const Size(80, 24)));
        final buf = Buffer.blank(80, 24);
        el.paint(buf, Offset.zero);

        // Scroll deep into document and benchmark 60 cursor/scroll repaints.
        controller.scrollOffset = 1500;
        final sw = Stopwatch()..start();
        for (var i = 0; i < 60; i++) {
          el.paint(buf, Offset.zero);
        }
        sw.stop();
        el.unmount();

        expect(highlighter.debugHighlightCount, equals(1));
        expect(sw.elapsedMicroseconds / 60000.0, lessThan(4.0));
      },
    );

    test(
      'H6 & H7: TextAreaFormField PageDown uses fieldHeight and rebuild keeps auto-scroll unlocked',
      () {
        final text = [for (var i = 0; i < 25; i++) 'line_$i'].join('\n');
        final field = TextAreaFormField(
          label: 'Code',
          fieldHeight: 4,
          initialValue: text,
          focused: true,
        );
        final el = field.createElement()
          ..mount(null)
          ..rebuild();
        el.layout(BoxConstraints.tight(const Size(30, 8)));

        for (var i = 0; i < 25; i++) {
          field.handleKeyEvent(const KeyEvent('up', KeyType.up));
        }
        expect(field.cursorLine, equals(0));
        field.handleKeyEvent(const KeyEvent('pageDown', KeyType.pageDown));
        expect(field.cursorLine, equals(3));
        el.unmount();

        // H6b: parent rebuild preserves viewport height on controller before layout.
        final sharedCtrl = TextEditingController(text: text);
        sharedCtrl.value = TextEditingValue(
          text: text,
          selection: const TextSelection.collapsed(offset: 0),
        );
        final firstField = TextField(controller: sharedCtrl, multiline: true);
        final firstEl = firstField.createElement()
          ..mount(null)
          ..rebuild()
          ..layout(BoxConstraints.tight(const Size(20, 4)));
        firstEl.unmount();

        final rebuiltField = TextField(controller: sharedCtrl, multiline: true);
        rebuiltField.handleKeyEvent(
          const KeyEvent('pageDown', KeyType.pageDown),
        );
        expect(rebuiltField.cursorLine, equals(3));

        // H7: TextAreaFormField rebuild via didUpdateWidget keeps cursor visible on shrink.
        final shortText = [for (var i = 0; i < 10; i++) 'line_$i'].join('\n');
        final f1 = TextAreaFormField(
          label: 'Code',
          fieldHeight: 6,
          initialValue: shortText,
          focused: true,
        );
        final formEl = f1.createElement()
          ..mount(null)
          ..rebuild();
        formEl.layout(BoxConstraints.tight(const Size(30, 10)));
        formEl.update(
          TextAreaFormField(
            label: 'Code',
            fieldHeight: 3,
            initialValue: shortText,
            focused: true,
          ),
        );
        formEl.rebuild();
        formEl.layout(BoxConstraints.tight(const Size(30, 7)));
        final buf = Buffer.blank(30, 7);
        formEl.paint(buf, Offset.zero);
        final visible = [
          for (var y = 1; y <= 3; y++)
            [for (var x = 2; x < 20; x++) buf.getCharacter(x, y)].join().trim(),
        ];
        formEl.unmount();
        expect(visible, contains('line_9'));
      },
    );

    test(
      'H8: unfocused TextField resets stale auto horizontalScrollOffset when text shrinks',
      () {
        final controller = TextEditingController(text: '0123456789abcdefghij');
        final focusedEl =
            TextField(
                controller: controller,
                multiline: true,
                focused: true,
              ).createElement()
              ..mount(null)
              ..layout(BoxConstraints.tight(const Size(10, 2)));
        expect(controller.horizontalScrollOffset, equals(11));
        focusedEl.unmount();

        controller.text = 'short';
        final unfocusedEl =
            TextField(
                controller: controller,
                multiline: true,
                focused: false,
              ).createElement()
              ..mount(null)
              ..layout(BoxConstraints.tight(const Size(10, 2)));
        final buf = Buffer.blank(10, 2);
        unfocusedEl.paint(buf, Offset.zero);
        unfocusedEl.unmount();

        expect(controller.horizontalScrollOffset, equals(0));
        expect(_rowText(buf, 0), equals('short'));
      },
    );

    test(
      'H9: mouse drag originating outside TextField does not steal focus or select text',
      () {
        final tester = TerminalTester(size: const Point(20, 4));
        tester.run(() async {
          final controller = TextEditingController(text: 'hello world');
          final headerFocus = FocusNode(id: 'header_focus');
          final focusNode = FocusNode(id: 'tf_drag_guard');
          final runner = PromptRunner<void>(
            terminal: tester.terminal,
            widget: Column([
              Focus(
                focusNode: headerFocus,
                autofocus: true,
                child: const SizedBox(
                  width: 20,
                  height: 1,
                  child: Text('header'),
                ),
              ),
              SizedBox(
                width: 20,
                height: 2,
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  multiline: true,
                  focused: false,
                ),
              ),
            ]),
            alternateScreen: false,
          );
          await tester.runPrompt(runner, () async {
            try {
              await tester.pump();
              expect(focusNode.hasFocus, isFalse);

              // Press on header (row 1), drag into TextField (row 2).
              runner.handleMouseEvent(
                const MouseEvent(
                  x: 1,
                  y: 1,
                  button: MouseButton.left,
                  type: MouseEventType.press,
                ),
              );
              runner.handleMouseEvent(
                const MouseEvent(
                  x: 4,
                  y: 2,
                  button: MouseButton.left,
                  type: MouseEventType.drag,
                ),
              );
              await tester.pump();
              expect(focusNode.hasFocus, isFalse);
              expect(controller.selectedText, isEmpty);

              // Press inside TextField + drag selects normally, release ends drag.
              runner.handleMouseEvent(
                const MouseEvent(
                  x: 1,
                  y: 2,
                  button: MouseButton.left,
                  type: MouseEventType.press,
                ),
              );
              runner.handleMouseEvent(
                const MouseEvent(
                  x: 6,
                  y: 2,
                  button: MouseButton.left,
                  type: MouseEventType.drag,
                ),
              );
              runner.handleMouseEvent(
                const MouseEvent(
                  x: 6,
                  y: 2,
                  button: MouseButton.left,
                  type: MouseEventType.release,
                ),
              );
              await tester.pump();
              expect(focusNode.hasFocus, isTrue);
              expect(controller.selectedText, equals('hello'));

              // After release, another stray drag from header must not steal focus.
              headerFocus.requestFocus();
              await tester.pump();
              expect(focusNode.hasFocus, isFalse);
              runner.handleMouseEvent(
                const MouseEvent(
                  x: 1,
                  y: 1,
                  button: MouseButton.left,
                  type: MouseEventType.press,
                ),
              );
              runner.handleMouseEvent(
                const MouseEvent(
                  x: 3,
                  y: 2,
                  button: MouseButton.left,
                  type: MouseEventType.drag,
                ),
              );
              await tester.pump();
              expect(focusNode.hasFocus, isFalse);
            } finally {
              runner.dispose();
            }
          });
        });
      },
    );

    test(
      'M1 & M2: Ctrl+K/Ctrl+Backspace delete active selection and Up/Down collapse selection at boundary lines',
      () {
        // M1: Ctrl+K on Ctrl+A selection deletes entire buffer.
        final kCtrl = TextEditingController(text: 'hello world');
        final kField = TextField(controller: kCtrl, multiline: true);
        kField.handleKeyEvent(
          const KeyEvent(
            'a',
            KeyType.character,
            modifiers: {ev.Modifier.control},
          ),
        );
        kField.handleKeyEvent(
          const KeyEvent(
            'k',
            KeyType.character,
            modifiers: {ev.Modifier.control},
          ),
        );
        expect(kField.value, isEmpty);

        // M1: Ctrl+Backspace on backward selection deletes only the selection.
        final bsCtrl = TextEditingController(text: 'hello');
        bsCtrl.value = const TextEditingValue(
          text: 'hello',
          selection: TextSelection(
            baseOffset: 5,
            extentOffset: 2,
            cursorLine: 0,
            cursorColumn: 2,
          ),
        );
        final bsField = TextField(controller: bsCtrl, multiline: true);
        bsField.handleKeyEvent(
          const KeyEvent(
            '',
            KeyType.backspace,
            modifiers: {ev.Modifier.control},
          ),
        );
        expect(bsField.value, equals('he'));

        // M2: Down arrow at last line collapses active Ctrl+A selection.
        final navCtrl = TextEditingController(text: 'top\nbottom');
        final navField = TextField(controller: navCtrl, multiline: true);
        navField.handleKeyEvent(
          const KeyEvent(
            'a',
            KeyType.character,
            modifiers: {ev.Modifier.control},
          ),
        );
        expect(
          navField.handleKeyEvent(const KeyEvent('', KeyType.down)),
          isTrue,
        );
        expect(navCtrl.value.selection.isCollapsed, isTrue);

        // M2: Up arrow at line 0 collapses active backward selection.
        navCtrl.value = const TextEditingValue(
          text: 'top\nbottom',
          selection: TextSelection(
            baseOffset: 10,
            extentOffset: 0,
            cursorLine: 0,
            cursorColumn: 0,
          ),
        );
        expect(navField.handleKeyEvent(const KeyEvent('', KeyType.up)), isTrue);
        expect(navCtrl.value.selection.isCollapsed, isTrue);
      },
    );

    test('M3: backward wall-clock jump does not coalesce typing edits', () {
      var now = DateTime.utc(2026, 11, 24, 12, 0, 10);
      withClock(Clock(() => now), () {
        final controller = TextEditingController(
          text: '',
          undoCoalesceWindow: const Duration(milliseconds: 500),
        );
        final field = TextField(controller: controller, multiline: true);
        field.handleKeyEvent(const KeyEvent('a', KeyType.character));
        now = DateTime.utc(2026, 11, 24, 12, 0, 0);
        field.handleKeyEvent(const KeyEvent('b', KeyType.character));
        controller.undo();
        expect(field.value, equals('a'));
      });
    });

    test(
      'M4: GLSL single-line rules on CRLF do not paint raw CR into TextField',
      () {
        final highlighter = SyntaxTextHighlighter(
          language: kGlslLanguageId,
          theme: TerminalColorTheme.termuiDark,
        );
        final field = TextField(
          controller: TextEditingController(
            text: '// @fterm-stage: fg\r\n// comment\r\n"hi"\r\nfloat x = 1.0;',
          ),
          multiline: true,
          focused: false,
          spanBuilder: highlighter.buildFieldSpan,
        );
        final el = field.createElement()
          ..mount(null)
          ..layout(BoxConstraints.tight(const Size(24, 4)));
        final buf = Buffer.blank(24, 4);
        el.paint(buf, Offset.zero);
        el.unmount();

        for (var y = 0; y < 4; y++) {
          for (var x = 0; x < 24; x++) {
            expect(buf.getCharacter(x, y), isNot(equals('\r')));
          }
        }
        expect(buf.getCharacter(10, 1), equals(' '));
      },
    );

    test(
      'M5: wide grapheme straddling left edge preserves cellStyle on column 0',
      () {
        final controller = TextEditingController(text: '🔥abcd');
        const selBg = Color(0x22, 0x44, 0x88);
        final field = TextField(
          controller: controller,
          multiline: false,
          focused: false,
          selectionStyle: const Style(background: selBg),
        );
        field.handleKeyEvent(
          const KeyEvent(
            'a',
            KeyType.character,
            modifiers: {ev.Modifier.control},
          ),
        );
        controller.horizontalScrollOffset = 1;
        final el = field.createElement()
          ..mount(null)
          ..layout(BoxConstraints.tight(const Size(6, 1)));
        final buf = Buffer.blank(6, 1);
        el.paint(buf, Offset.zero);
        el.unmount();
        expect(buf.getBackground(0, 0), equals(selBg.argb));
      },
    );

    test(
      'M9: mouse click with horizontalScrollOffset maps to scrolled column',
      () {
        final controller = TextEditingController(text: '0123456789abcdef');
        final elem =
            TextField(
                controller: controller,
                multiline: true,
                focused: true,
              ).createElement()
              ..mount(null)
              ..layout(BoxConstraints.tight(const Size(8, 2)));
        controller.horizontalScrollOffset = 5;
        final consumer = findMouseConsumer(elem);
        expect(
          consumer.handleMouseEvent(
            const MouseEvent(
              x: 3,
              y: 1,
              button: MouseButton.left,
              type: MouseEventType.press,
            ),
            2,
            0,
          ),
          isTrue,
        );
        expect(controller.value.selection.cursorColumn, equals(7));
        elem.unmount();
      },
    );
  });
}
