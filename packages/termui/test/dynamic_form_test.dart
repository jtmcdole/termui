import 'dart:math';

import 'package:test/test.dart';
import 'package:termui/termui.dart' hide Modifier;
import 'package:termui/ui/event.dart';
import 'package:termui_recorder/termui_recorder.dart';
import 'package:termui_test/termui_test.dart';

void _runInPrompt(
  Widget widget,
  Future<void> Function(TerminalTester tester) body, {
  Point<int> size = const Point(60, 24),
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

Future<void> _press(TerminalTester t, LogicalKey key) async {
  t.sendKey(key);
  await t.pump();
}

Future<void> _type(TerminalTester t, String text) async {
  t.typeText(text);
  await t.pump();
}

Future<void> _click(
  TerminalTester t,
  int x,
  int y, [
  MouseButton btn = MouseButton.left,
]) async {
  t.mouseDown(x, y, button: btn);
  if (btn != MouseButton.wheelDown && btn != MouseButton.wheelUp) {
    t.mouseUp(x, y, button: btn);
  }
  await t.pump();
}

void main() {
  setUp(() => FocusManager.instance.setPrimaryFocus(null));

  group('Dynamic Form & FormField Tests', () {
    test('Dynamic field registration and validation', () {
      final nameField = TextFormField(
        label: 'Name',
        initialValue: '',
        validator: (val) => (val == null || val.isEmpty) ? 'Required' : null,
      );
      final emailField = TextFormField(
        label: 'Email',
        initialValue: '',
        validator: (val) =>
            (val == null || !val.contains('@')) ? 'Invalid' : null,
      );

      final form = Form(child: Column([nameField, emailField]));

      final tree = ElementWidget(form);
      final buffer = Buffer.blank(20, 10);
      tree.layout(BoxConstraints.tight(const Size(20, 10)));
      tree.paint(buffer, Offset.zero);

      final formState = tree.findState<FormState>();
      expect(formState, isNotNull);

      // Verify validation fails initially
      expect(formState!.validate(), isFalse);
      expect(nameField.hasError, isTrue);
      expect(nameField.errorText, equals('Required'));
      expect(emailField.hasError, isTrue);
      expect(emailField.errorText, equals('Invalid'));

      // Fill in name
      nameField.value = 'Alice';
      expect(formState.validate(), isFalse);
      expect(nameField.hasError, isFalse);
      expect(emailField.hasError, isTrue);

      // Fill in email
      emailField.value = 'alice@example.com';
      expect(formState.validate(), isTrue);
      expect(nameField.hasError, isFalse);
      expect(emailField.hasError, isFalse);
    });

    test('Dynamic Form reset', () {
      final nameField = TextFormField(
        label: 'Name',
        initialValue: 'Bob',
        validator: (val) => (val == null || val.isEmpty) ? 'Required' : null,
      );
      final form = Form(child: Column([nameField]));

      final tree = ElementWidget(form);
      final buffer = Buffer.blank(20, 10);
      tree.layout(BoxConstraints.tight(const Size(20, 10)));
      tree.paint(buffer, Offset.zero);

      final formState = tree.findState<FormState>()!;
      nameField.value = '';
      expect(formState.validate(), isFalse);
      expect(nameField.hasError, isTrue);

      // Reset
      formState.reset();
      expect(nameField.value, equals('Bob'));
      expect(nameField.hasError, isFalse);
      expect(nameField.errorText, isNull);
    });

    test('Dynamic Form focus traversal', () {
      final f1 = TextFormField(label: 'F1');
      final f2 = TextFormField(label: 'F2');
      final form = Form(child: Column([f1, f2]));

      final tree = ElementWidget(form);
      final buffer = Buffer.blank(20, 10);
      tree.layout(BoxConstraints.tight(const Size(20, 10)));
      tree.paint(buffer, Offset.zero);

      final formState = tree.findState<FormState>()!;
      f1.focused = true;
      expect(f1.focused, isTrue);
      expect(f2.focused, isFalse);

      // Press Tab moves to F2
      formState.handleKeyEvent(const KeyEvent('\\t', KeyType.tab));
      expect(f1.focused, isFalse);
      expect(f2.focused, isTrue);

      // Press Backtab moves to F1
      formState.handleKeyEvent(
        const KeyEvent('\\t', KeyType.tab, modifiers: {Modifier.shift}),
      );
      expect(f1.focused, isTrue);
      expect(f2.focused, isFalse);
    });

    test('Dynamic Form focus traversal with Up/Down arrow keys', () {
      final f1 = TextFormField(label: 'F1');
      final f3 = TextAreaFormField(
        label: 'F3',
        initialValue: 'line1\nline2',
        fieldHeight: 2,
      );
      final form = Form(child: Column([f1, f3]));

      final tree = ElementWidget(form);
      final buffer = Buffer.blank(20, 10);
      tree.layout(BoxConstraints.tight(const Size(20, 10)));
      tree.paint(buffer, Offset.zero);

      final formState = tree.findState<FormState>()!;
      f1.focused = true;
      expect(f1.focused, isTrue);
      expect(f3.focused, isFalse);

      // Press Down on F1 moves to F3
      formState.handleKeyEvent(const KeyEvent('down', KeyType.down));
      expect(f1.focused, isFalse);
      expect(f3.focused, isTrue);

      // When entering F3, cursor is initially at the end (line 1)
      expect(f3.cursorLine, equals(1));

      // Press Up on F3: since cursor is at line 1, it should move cursor to line 0 and focus remains on F3
      formState.handleKeyEvent(const KeyEvent('up', KeyType.up));
      expect(f3.focused, isTrue);
      expect(f3.cursorLine, equals(0));

      // Press Up on F3 again: since cursor is at line 0, it should move focus back to F1
      formState.handleKeyEvent(const KeyEvent('up', KeyType.up));
      expect(f1.focused, isTrue);
      expect(f3.focused, isFalse);

      // Move to F3 again (cursor should keep its state at line 0)
      formState.handleKeyEvent(const KeyEvent('down', KeyType.down));
      expect(f3.focused, isTrue);
      expect(f3.cursorLine, equals(0));

      // Move cursor down within F3 (multiline)
      formState.handleKeyEvent(const KeyEvent('down', KeyType.down));
      // Cursor should have moved to line 1 (and focus should NOT change because it was handled inside F3)
      expect(f3.focused, isTrue);
      expect(f3.cursorLine, equals(1));

      // Pressing Down on F3 at last line should cycle/move focus back to F1
      formState.handleKeyEvent(const KeyEvent('down', KeyType.down));
      expect(f1.focused, isTrue);
      expect(f3.focused, isFalse);
    });

    test('Legacy Form focus traversal with Up/Down arrow keys', () {
      final f1 = TextFormField(label: 'F1');
      final f2 = TextFormField(label: 'F2');
      final form = Form(fields: [f1, f2]);

      expect(f1.focused, isTrue);
      expect(f2.focused, isFalse);

      // Down moves to f2
      form.handleKeyEvent(const KeyEvent('down', KeyType.down));
      expect(f1.focused, isFalse);
      expect(f2.focused, isTrue);

      // Up moves to f1
      form.handleKeyEvent(const KeyEvent('up', KeyType.up));
      expect(f1.focused, isTrue);
      expect(f2.focused, isFalse);
    });

    test('Legacy Form LeftBorder focus updates on tab', () {
      final f1 = TextFormField(label: 'Field 1');
      final f2 = TextFormField(label: 'Field 2');
      final form = Form(fields: [f1, f2]);

      final tree = ElementWidget(form);
      final buffer = Buffer.blank(20, 10);
      buffer.clear();
      tree.layout(BoxConstraints.tight(const Size(20, 10)));
      tree.paint(buffer, Offset.zero);

      final formState = tree.findState<FormState>()!;

      expect(
        buffer,
        matchesAnsiGolden('test/goldens/dynamic_form_field1_focused.ansi'),
      );

      // Press Tab to move focus to Field 2
      formState.handleKeyEvent(const KeyEvent('tab', KeyType.character));

      // Re-render
      buffer.clear();
      tree.layout(BoxConstraints.tight(const Size(20, 10)));
      tree.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden('test/goldens/dynamic_form_field2_focused.ansi'),
      );
    });

    test('validate when navigating away', () {
      final field = TextFormField(
        label: 'Email',
        initialValue: '',
        validator: (val) => (val == null || val.isEmpty) ? 'Required' : null,
      );
      final form = Form(fields: [field]);
      final tree = ElementWidget(form);
      final buffer = Buffer.blank(20, 10);
      tree.layout(BoxConstraints.tight(const Size(20, 10)));
      tree.paint(buffer, Offset.zero);

      expect(field.hasError, isFalse);

      field.focused = true;
      expect(field.hasError, isFalse);

      field.focused = false;
      expect(field.hasError, isTrue);
      expect(field.errorText, equals('Required'));
    });

    test('hitting enter moves to next field and validates', () {
      final f1 = TextFormField(
        label: 'F1',
        initialValue: '',
        validator: (val) => (val == null || val.isEmpty) ? 'Required' : null,
      );
      final f2 = TextFormField(label: 'F2');
      final form = Form(fields: [f1, f2]);
      final tree = ElementWidget(form);
      final buffer = Buffer.blank(20, 10);
      tree.layout(BoxConstraints.tight(const Size(20, 10)));
      tree.paint(buffer, Offset.zero);

      expect(f1.focused, isTrue);
      expect(f2.focused, isFalse);
      expect(f1.hasError, isFalse);

      form.handleKeyEvent(const KeyEvent('\n', KeyType.enter));

      expect(f1.focused, isFalse);
      expect(f2.focused, isTrue);
      expect(f1.hasError, isTrue);
      expect(form.activeFieldIndex, equals(1));
    });

    test('no validation on initial focus loss if never touched', () {
      final field = TextFormField(
        label: 'Email',
        initialValue: '',
        validator: (val) => (val == null || val.isEmpty) ? 'Required' : null,
      );
      final form = Form(fields: [field]);
      final tree = ElementWidget(form);
      final buffer = Buffer.blank(20, 10);
      tree.layout(BoxConstraints.tight(const Size(20, 10)));
      tree.paint(buffer, Offset.zero);

      expect(field.focused, isTrue);
      expect(field.hasError, isFalse);

      // Simulate the widget book toggling focus to false on initial build before any interaction
      field.focused = false;
      expect(field.hasError, isFalse);
    });

    test(
      'PromptRunner: Tab, click-to-focus, click-to-caret, and trailing Button traversal',
      () {
        final emailNode = FocusNode(id: 'custom_email');
        final email = TextFormField(
          label: 'Email',
          initialValue: 'ab🔥d',
          focusNode: emailNode,
        );
        final lang = SelectFormField<String>(
          label: 'Language',
          options: const [
            SelectOption('Dart', 'dart'),
            SelectOption('Go', 'go'),
          ],
          initialValue: 'dart',
        );
        final agree = ConfirmFormField(label: 'Agree', initialValue: false);
        var submitted = false;
        final form = Form(fields: [email, lang, agree]);

        _runInPrompt(
          Column([
            Expanded(child: form),
            SizedBox(
              height: 1,
              child: Button(text: 'Submit', onPressed: () => submitted = true),
            ),
          ]),
          (tester) async {
            expect(email.focused, isTrue);
            expect(FocusManager.instance.primaryFocus, same(emailNode));
            expect(email.cursorColumn, equals(4));

            await _press(tester, LogicalKey.tab);
            expect(lang.focused, isTrue);
            await _press(tester, LogicalKey.arrowDown);
            expect(lang.value, equals('go'));

            await _press(tester, LogicalKey.tab);
            expect(agree.focused, isTrue);
            await _press(tester, LogicalKey.character(' '));
            expect(agree.value, isTrue);

            await _press(tester, LogicalKey.tab);
            expect(form.focused, isFalse);
            await _press(tester, LogicalKey.enter);
            expect(submitted, isTrue);

            // Click 2nd cell of wide emoji '🔥' -> focuses email and places caret at col 2.
            await _click(tester, 8, 2);
            expect(email.focused, isTrue);
            expect(email.cursorColumn, equals(2));
            await _type(tester, 'c');
            expect(email.value, equals('abc🔥d'));

            await _click(tester, 4, 4);
            expect(lang.focused, isTrue);

            await _click(tester, 1, 1);
            expect(email.focused, isTrue);
            expect(email.cursorColumn, equals(3));
          },
        );

        expect(emailNode.parent, isNull);
        emailNode.dispose();
      },
    );

    test(
      'PromptRunner: unfocused nested FocusScope does not steal primaryFocus from autofocus sibling',
      () {
        final sidebarNode = FocusNode(id: 'sidebar');
        final previewScope = FocusScopeNode(id: 'preview');
        final email = TextFormField(label: 'Email');
        final sidebarKeys = <String>[];

        _runInPrompt(
          Row([
            SizedBox(
              width: 15,
              child: Focus(
                focusNode: sidebarNode,
                autofocus: true,
                onKeyEvent: (ev) =>
                    ev.type == KeyType.character &&
                    (sidebarKeys..add(ev.key)).isNotEmpty,
                child: const Text('Sidebar'),
              ),
            ),
            Expanded(
              child: FocusScope(
                focusNode: previewScope,
                child: Form(fields: [email]),
              ),
            ),
          ]),
          (tester) async {
            expect(FocusManager.instance.primaryFocus, same(sidebarNode));
            expect(email.focused, isFalse);

            await _type(tester, 'xy');
            expect(sidebarKeys, equals(['x', 'y']));
            expect(email.value, isNull);

            previewScope.requestFocus();
            await tester.pump();
            expect(email.focused, isTrue);
            await _type(tester, 'hi');
            expect(email.value, equals('hi'));
          },
        );
      },
    );

    test(
      'PromptRunner: declarative Form preserves caret across rebuilds and syncs conditional field Tab order',
      () {
        var rebuildCount = 0;
        var showMiddle = false;
        var buttonActivated = false;
        late void Function(void Function()) rebuildHost;
        TextFormField? latestFirst, latestMiddle;
        TextAreaFormField? latestBio;

        _runInPrompt(
          StatefulBuilder(
            builder: (context, setHostState) {
              rebuildHost = setHostState;
              latestFirst = TextFormField(
                label: 'First ($rebuildCount)',
                initialValue: 'hello',
                focused: rebuildCount == 0,
              );
              latestMiddle = showMiddle
                  ? TextFormField(label: 'Mid', initialValue: 'm')
                  : null;
              latestBio = TextAreaFormField(
                label: 'Bio',
                initialValue: 'l1\nl2',
                fieldHeight: 2,
              );
              return Column([
                Expanded(
                  child: Form(
                    child: Column([
                      SizedBox(height: 3, child: latestFirst!),
                      if (latestMiddle != null)
                        SizedBox(height: 3, child: latestMiddle!),
                      SizedBox(height: 4, child: latestBio!),
                    ]),
                  ),
                ),
                SizedBox(
                  height: 1,
                  child: Button(
                    text: 'Save',
                    onPressed: () => buttonActivated = true,
                  ),
                ),
              ]);
            },
          ),
          (tester) async {
            tester.sendKey(LogicalKey.arrowLeft);
            await _press(tester, LogicalKey.arrowLeft);
            expect(latestFirst!.cursorColumn, equals(3));

            rebuildHost(() {
              rebuildCount++;
              showMiddle = true;
            });
            await tester.pump();
            expect(latestFirst!.cursorColumn, equals(3));
            await _type(tester, 'X');
            expect(latestFirst!.value, equals('helXlo'));

            await _press(tester, LogicalKey.tab);
            expect(latestMiddle!.focused, isTrue);
            await _press(tester, LogicalKey.tab);
            expect(latestBio!.focused, isTrue);

            tester.sendKey(LogicalKey.arrowUp);
            await _press(tester, LogicalKey.arrowLeft);
            final savedCol = latestBio!.cursorColumn;
            rebuildHost(() => rebuildCount++);
            await tester.pump();
            expect(latestBio!.cursorLine, equals(0));
            expect(latestBio!.cursorColumn, equals(savedCol));

            await _press(tester, LogicalKey.tab);
            await _press(tester, LogicalKey.enter);
            expect(buttonActivated, isTrue);
          },
        );
      },
    );

    test(
      'PromptRunner: wheel scroll, hover, and right-click pass through FormField and TextField to ListView',
      () {
        var lastHovered = -1;
        final f1 = TextFormField(label: 'Field 1', initialValue: 'one');
        _runInPrompt(
          ListView(
            onHover: (idx) => lastHovered = idx ?? -1,
            children: [
              SizedBox(height: 1, child: TextField(initialText: 'standalone')),
              f1,
              for (var i = 3; i <= 6; i++) Text('Row $i'),
            ],
          ),
          (tester) async {
            final listEl =
                find
                        .byType<ListView>()
                        .apply(collectAllElements(tester.rootElement!))
                        .single
                    as ListViewElement;
            tester.mouseMove(5, 1, drag: false);
            await tester.pump();
            expect(lastHovered, equals(0));

            await _click(tester, 5, 2, MouseButton.right);
            expect(f1.focused, isFalse);

            await _click(tester, 5, 1, MouseButton.wheelDown);
            expect(listEl.scrollOffset, equals(1));
            await _click(tester, 5, 2, MouseButton.wheelDown);
            expect(listEl.scrollOffset, equals(2));
            await _click(tester, 5, 2, MouseButton.wheelUp);
            expect(listEl.scrollOffset, equals(1));
          },
          size: const Point(50, 4),
        );
      },
    );

    test(
      'PromptRunner: MultiSelectFormField toggles on Space while Enter advances, calls onSubmit, or bubbles',
      () {
        final name = TextFormField(label: 'Name', initialValue: 'Ada');
        final toppings = MultiSelectFormField<String>(
          label: 'Toppings',
          options: const [
            MultiSelectOption('Cheese', 'cheese'),
            MultiSelectOption('Bacon', 'bacon'),
          ],
        );
        var scopeSawFinalEnter = false;
        _runInPrompt(
          FocusScope(
            autofocus: true,
            onKeyEvent: (ev) =>
                ev.type == KeyType.enter && (scopeSawFinalEnter = true),
            child: Form(fields: [name, toppings]),
          ),
          (tester) async {
            await _press(tester, LogicalKey.enter);
            expect(toppings.focused, isTrue);
            expect(scopeSawFinalEnter, isFalse);

            await _press(tester, LogicalKey.character(' '));
            expect(toppings.value, equals(['cheese']));

            await _press(tester, LogicalKey.enter);
            expect(scopeSawFinalEnter, isTrue);
            expect(toppings.value, equals(['cheese']));
          },
        );

        var submittedCount = 0;
        var outerSawEnter = false;
        _runInPrompt(
          FocusScope(
            autofocus: true,
            onKeyEvent: (ev) =>
                ev.type == KeyType.enter && (outerSawEnter = true),
            child: Form(
              onSubmit: () => submittedCount++,
              fields: [TextFormField(label: 'Code', initialValue: '42')],
            ),
          ),
          (tester) async {
            await _press(tester, LogicalKey.enter);
            expect(submittedCount, equals(1));
            expect(outerSawEnter, isFalse);
          },
        );
      },
    );

    test(
      'PromptRunner & headless Form: non-text field 0 seeding, Up/Down field navigation, and headless onSubmit',
      () {
        var headlessSubmits = 0;
        final headlessForm = Form(
          onSubmit: () => headlessSubmits++,
          fields: [
            TextFormField(label: 'H1', initialValue: 'ok'),
            TextAreaFormField(label: 'H2', initialValue: 'a'),
            ConfirmFormField(label: 'H3', initialValue: true),
          ],
        );
        headlessForm.handleKeyEvent(const KeyEvent('', KeyType.enter));
        expect(headlessForm.activeFieldIndex, equals(1));
        headlessForm.handleKeyEvent(const KeyEvent('', KeyType.enter));
        expect(headlessForm.activeFieldIndex, equals(1));
        headlessForm.activeFieldIndex = 2;
        headlessForm.handleKeyEvent(const KeyEvent('', KeyType.enter));
        expect(headlessSubmits, equals(1));

        final starter = SelectFormField<String>(
          label: 'Starter',
          description: 'Base',
          options: const [SelectOption('Soup', 'soup')],
          initialValue: 'soup',
        );
        final confirm = ConfirmFormField(label: 'Spicy', initialValue: false);
        final note = TextFormField(
          label: 'Coupon',
          validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
        );
        final form = Form(fields: [starter, confirm, note]);
        final sidebarNode = FocusNode(id: 'nav');
        final previewScope = FocusScopeNode(id: 'pane');

        _runInPrompt(
          Row([
            SizedBox(
              width: 10,
              child: Focus(
                focusNode: sidebarNode,
                autofocus: true,
                child: const Text('Nav'),
              ),
            ),
            Expanded(
              child: FocusScope(focusNode: previewScope, child: form),
            ),
          ]),
          (tester) async {
            expect(FocusManager.instance.primaryFocus, same(sidebarNode));
            expect(starter.focused, isFalse);

            previewScope.requestFocus();
            await tester.pump();
            expect(starter.focused, isTrue);

            await _press(tester, LogicalKey.tab);
            expect(confirm.focused, isTrue);
            await _press(tester, LogicalKey.arrowDown);
            expect(note.focused, isTrue);
            await _press(tester, LogicalKey.arrowUp);
            expect(confirm.focused, isTrue);
            expect(form.validate(), isFalse);
            expect(note.errorText, equals('Required'));
          },
        );

        final rootSelect = SelectFormField<String>(
          label: 'Direct',
          options: const [SelectOption('One', '1')],
        );
        _runInPrompt(Form(fields: [rootSelect]), (_) async {
          expect(rootSelect.focused, isTrue);
        });
      },
    );

    test(
      'reset() on required TextFormField with empty initialValue keeps errorText cleared',
      () {
        final nameField = TextFormField(
          label: 'Name',
          initialValue: '',
          validator: (val) => (val == null || val.isEmpty) ? 'Required' : null,
        );
        final form = Form(child: Column([nameField]));

        final tree = ElementWidget(form);
        final buffer = Buffer.blank(40, 10);
        tree.layout(BoxConstraints.tight(const Size(40, 10)));
        tree.paint(buffer, Offset.zero);

        final formState = tree.findState<FormState>()!;
        nameField.focused = true;
        nameField.handleKeyEvent(const KeyEvent('A', .character));
        nameField.handleKeyEvent(const KeyEvent('B', .character));
        nameField.handleKeyEvent(const KeyEvent('C', .character));
        nameField.handleKeyEvent(
          const KeyEvent('z', .character, modifiers: {Modifier.control}),
        );
        expect(nameField.value, equals('AB'));
        expect(formState.validate(), isTrue);

        formState.reset();
        expect(nameField.value, equals(''));
        expect(nameField.cursorColumn, equals(0));
        expect(nameField.hasError, isFalse);
        expect(nameField.errorText, isNull);

        // Undo/redo history from pre-reset edits must not restore old text.
        nameField.handleKeyEvent(
          const KeyEvent('y', .character, modifiers: {Modifier.control}),
        );
        expect(nameField.value, equals(''));
        nameField.handleKeyEvent(
          const KeyEvent('z', .character, modifiers: {Modifier.control}),
        );
        expect(nameField.value, equals(''));
        expect(nameField.hasError, isFalse);

        // Live editing and validation still work after reset.
        nameField.handleKeyEvent(const KeyEvent('B', .character));
        expect(nameField.value, equals('B'));
        expect(nameField.hasError, isFalse);
        nameField.handleKeyEvent(const KeyEvent('', .backspace));
        expect(nameField.value, equals(''));
        expect(nameField.hasError, isTrue);
        expect(nameField.errorText, equals('Required'));
      },
    );

    test(
      'reset() on required TextFormField with null initialValue preserves null and avoids validation',
      () {
        var validatorCalls = 0;
        final emailField = TextFormField(
          label: 'Email',
          validator: (val) {
            validatorCalls++;
            return (val == null || !val.contains('@')) ? 'Invalid' : null;
          },
        );
        final form = Form(child: Column([emailField]));

        final tree = ElementWidget(form);
        final buffer = Buffer.blank(40, 10);
        tree.layout(BoxConstraints.tight(const Size(40, 10)));
        tree.paint(buffer, Offset.zero);
        expect(validatorCalls, equals(0));

        emailField.focused = true;
        emailField.handleKeyEvent(const KeyEvent('x', .character));
        expect(emailField.hasError, isTrue);
        expect(emailField.errorText, equals('Invalid'));

        validatorCalls = 0;
        tree.findState<FormState>()!.reset();
        expect(emailField.value, isNull);
        expect(emailField.cursorColumn, equals(0));
        expect(emailField.hasError, isFalse);
        expect(emailField.errorText, isNull);
        expect(validatorCalls, equals(0));

        // Subsequent rebuilds do not re-trigger validation or overwrite null.
        tree.layout(BoxConstraints.tight(const Size(40, 10)));
        tree.paint(buffer, Offset.zero);
        expect(emailField.value, isNull);
        expect(emailField.hasError, isFalse);
        expect(validatorCalls, equals(0));
      },
    );

    test(
      'reset() on required TextAreaFormField with empty initialValue keeps errorText cleared',
      () {
        final bioField = TextAreaFormField(
          label: 'Bio',
          initialValue: '',
          fieldHeight: 2,
          validator: (val) => (val == null || val.isEmpty) ? 'Required' : null,
        );
        final form = Form(child: Column([bioField]));

        final tree = ElementWidget(form);
        final buffer = Buffer.blank(40, 12);
        tree.layout(BoxConstraints.tight(const Size(40, 12)));
        tree.paint(buffer, Offset.zero);

        final formState = tree.findState<FormState>()!;
        bioField.focused = true;
        bioField.handleKeyEvent(const KeyEvent('A', .character));
        bioField.handleKeyEvent(const KeyEvent('\n', .enter));
        bioField.handleKeyEvent(const KeyEvent('B', .character));
        expect(formState.validate(), isTrue);
        expect(bioField.cursorLine, equals(1));

        formState.reset();
        expect(bioField.value, equals(''));
        expect(bioField.cursorLine, equals(0));
        expect(bioField.cursorColumn, equals(0));
        expect(bioField.hasError, isFalse);
        expect(bioField.errorText, isNull);
      },
    );

    test(
      'PromptRunner: reset() keeps required TextFormField and TextAreaFormField cleared across pump',
      () {
        final nameField = TextFormField(
          label: 'Name',
          initialValue: '',
          focused: true,
          validator: (val) => (val == null || val.isEmpty) ? 'Required' : null,
        );
        final notesField = TextAreaFormField(
          label: 'Notes',
          fieldHeight: 2,
          validator: (val) => (val == null || val.isEmpty) ? 'Required' : null,
        );
        final form = Form(child: Column([nameField, notesField]));

        _runInPrompt(form, (tester) async {
          final formEl =
              find
                      .byType<Form>()
                      .apply(collectAllElements(tester.rootElement!))
                      .single
                  as StatefulElement;
          final formState = formEl.state as FormState;

          await _type(tester, 'Ada');
          await _press(tester, LogicalKey.tab);
          await _type(tester, 'Note');
          expect(formState.validate(), isTrue);

          formState.reset();
          // Synced immediately before next frame pump as well as after pump.
          expect(nameField.value, equals(''));
          expect(nameField.cursorColumn, equals(0));
          expect(notesField.value, isNull);
          expect(notesField.cursorColumn, equals(0));

          await tester.pump();
          expect(nameField.value, equals(''));
          expect(nameField.hasError, isFalse);
          expect(nameField.errorText, isNull);
          expect(notesField.value, isNull);
          expect(notesField.hasError, isFalse);
          expect(notesField.errorText, isNull);

          // Typing after reset still updates value and runs live validation.
          await _type(tester, 'Z');
          expect(notesField.value, equals('Z'));
          expect(notesField.hasError, isFalse);
          await _press(tester, LogicalKey.backspace);
          expect(notesField.value, equals(''));
          expect(notesField.hasError, isTrue);
          expect(notesField.errorText, equals('Required'));
        });
      },
    );
  });
}
