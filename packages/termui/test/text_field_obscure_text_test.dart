import 'dart:math';

import 'package:file/memory.dart';
import 'package:termui/termui.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

String _rowText(Buffer buf, [int y = 0]) => [
  for (var x = 0; x < buf.width; x++) buf.getCharacter(x, y),
].join().trimRight();

class _ToggleObscureField extends StatefulWidget {
  final TextEditingController controller;
  final void Function(void Function() toggle) onMount;

  const _ToggleObscureField({required this.controller, required this.onMount});

  @override
  State<_ToggleObscureField> createState() => _ToggleObscureFieldState();
}

class _ToggleObscureFieldState extends State<_ToggleObscureField> {
  bool obscure = true;

  @override
  void initState() {
    super.initState();
    widget.onMount(_toggle);
  }

  void _toggle() {
    if (mounted) {
      setState(() {
        obscure = !obscure;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 24,
      height: 1,
      child: TextField(
        controller: widget.controller,
        focused: true,
        obscureText: obscure,
        placeholder: 'Enter PIN',
      ),
    );
  }
}

void main() {
  group('Issue #149: Tracer sensitive data redaction and TextField obscureText', () {
    setUp(() {
      FocusManager.instance.setPrimaryFocus(null);
    });

    tearDown(() async {
      await Tracer.stop();
      Tracer.activeCategories = {...TraceCategory.values};
    });

    test(
      'Tracer redacts typed characters and records grapheme length when obscureText is false',
      () {
        final tester = TerminalTester(size: const Point(40, 6));
        tester.run(() async {
          final memoryFs = MemoryFileSystem();
          await Tracer.initialize();
          await Tracer.start('/trace.json', fs: memoryFs);

          const secret = 's3cr3t-token';
          final controller = TextEditingController();
          final sceneManager = SceneManager(
            tester.terminal,
            renderingMode: .alternateScreen,
          );
          final runner = PromptRunner<void>(
            terminal: tester.terminal,
            widget: SizedBox(
              width: 24,
              height: 1,
              child: TextField(controller: controller, focused: true),
            ),
            alternateScreen: false,
            mode: .managed,
            onFramePainted: (_) => sceneManager.render(),
          );
          final layer = SceneLayer(renderer: runner, sizing: .fullscreen);
          sceneManager.layers.add(layer);
          sceneManager.focusedLayer = layer;

          try {
            await tester.runPrompt(runner, () async {
              try {
                await tester.pump();
                tester.sendString(secret);
                // Append a 2-code-unit decomposed grapheme ('e\u0301') to verify
                // paintTraceMetadata counts grapheme clusters (13), not UTF-16 (14).
                sceneManager.handleKeyEvent(
                  const KeyEvent('e\u0301', .character),
                );
                await tester.pump();
                await Tracer.stop();

                expect(controller.value.text, equals('${secret}e\u0301'));
                final traceJson = memoryFs
                    .file('/trace.json')
                    .readAsStringSync();

                expect(traceJson, isNot(contains(secret)));
                expect(traceJson, isNot(contains('"text":')));
                expect(traceJson, isNot(contains('"key":"S"')));
                expect(traceJson, contains('"key":"Character"'));
                expect(traceJson, contains('"length":"13"'));
              } finally {
                runner.dispose();
              }
            });
          } finally {
            sceneManager.dispose();
          }
        });
      },
    );

    test(
      'Tracer omits paint metadata when obscureText is true and redacts bracketed paste with trailing CRLF',
      () {
        final tester = TerminalTester(size: const Point(40, 6));
        tester.run(() async {
          final memoryFs = MemoryFileSystem();
          await Tracer.initialize();
          await Tracer.start('/trace_obscure.json', fs: memoryFs);

          const pastedSecret = 'MyS3cret!';
          var completed = false;
          final controller = TextEditingController();
          final sceneManager = SceneManager(
            tester.terminal,
            renderingMode: .alternateScreen,
          );
          final runner = PromptRunner<void>(
            terminal: tester.terminal,
            widget: SizedBox(
              width: 24,
              height: 1,
              child: TextField(
                controller: controller,
                focused: true,
                obscureText: true,
                placeholder: 'Password',
              ),
            ),
            alternateScreen: false,
            mode: .managed,
            onComplete: () {
              completed = true;
            },
            onFramePainted: (_) => sceneManager.render(),
          );
          final layer = SceneLayer(renderer: runner, sizing: .fullscreen);
          sceneManager.layers.add(layer);
          sceneManager.focusedLayer = layer;

          try {
            await tester.runPrompt(runner, () async {
              try {
                await tester.pump();
                expect(_rowText(runner.currentBuffer!), equals('Password'));

                // Bracketed paste with trailing CRLF should mask only the 9 secret
                // graphemes, ignore CRLF without auto-submitting, and never wedge Ctrl+W.
                tester.sendString('\x1b[200~$pastedSecret\r\n\x1b[201~');
                await tester.pump();
                await Tracer.stop();

                expect(completed, isFalse);
                expect(controller.value.text, equals(pastedSecret));
                expect(_rowText(runner.currentBuffer!), equals('*********'));

                final traceJson = memoryFs
                    .file('/trace_obscure.json')
                    .readAsStringSync();
                expect(traceJson, isNot(contains(pastedSecret)));
                expect(traceJson, isNot(contains('"text":')));
                expect(traceJson, isNot(contains('"length":')));
                expect(traceJson, contains('"key":"Character"'));

                tester.sendKey(.character('w'), control: true);
                await tester.pump();
                expect(controller.value.text, isEmpty);
                expect(_rowText(runner.currentBuffer!), equals('Password'));
              } finally {
                runner.dispose();
              }
            });
          } finally {
            sceneManager.dispose();
          }
        });
      },
    );

    test(
      'Tracer redacts plain and shifted characters while keeping shortcuts intact in SceneManager and PromptRunner',
      () async {
        final memoryFs = MemoryFileSystem();
        await Tracer.initialize();
        await Tracer.start('/trace_shortcut.json', fs: memoryFs);

        final mockTerminal = MockTerminalBackend();
        addTearDown(mockTerminal.dispose);
        final term = Terminal(mockTerminal);
        addTearDown(term.dispose);
        final sceneManager = SceneManager(
          term,
          renderingMode: .alternateScreen,
        );
        addTearDown(sceneManager.dispose);
        final runner = PromptRunner<void>(
          terminal: term,
          widget: SizedBox(width: 10, height: 1, child: TextField()),
          alternateScreen: false,
          mode: .managed,
        );
        addTearDown(runner.dispose);

        sceneManager.handleKeyEvent(const KeyEvent('a', .character));
        sceneManager.handleKeyEvent(
          const KeyEvent('S', .character, modifiers: {.shift}),
        );
        sceneManager.handleKeyEvent(
          const KeyEvent('w', .character, modifiers: {.control}),
        );
        runner.handleKeyEvent(
          const KeyEvent('@', .character, modifiers: {.shift}),
        );
        runner.handleKeyEvent(
          const KeyEvent('z', .character, modifiers: {.alt}),
        );
        runner.handleKeyEvent(
          const KeyEvent('k', .character, modifiers: {.meta}),
        );
        runner.handleKeyEvent(const KeyEvent('enter', .enter));

        await Tracer.stop();
        final traceContent = memoryFs
            .file('/trace_shortcut.json')
            .readAsStringSync();

        expect(traceContent, contains('"key":"Character"'));
        expect(traceContent, contains('"key":"Control+W"'));
        expect(traceContent, contains('"key":"Alt+Z"'));
        expect(traceContent, contains('"key":"Meta+K"'));
        expect(traceContent, contains('"key":"Enter"'));
        expect(traceContent, isNot(contains('"key":"A"')));
        expect(traceContent, isNot(contains('Shift+S')));
        expect(traceContent, isNot(contains('Shift+@')));
      },
    );

    test(
      'TextField obscureText validates multiline, embedded newlines, and obscuringCharacter',
      () {
        expect(
          () => TextField(obscureText: true, multiline: true),
          throwsArgumentError,
        );
        expect(
          () => TextField(obscureText: true, initialText: 'line1\nline2'),
          throwsArgumentError,
        );
        expect(
          () => TextField(obscureText: true, value: 'line1\rline2'),
          throwsArgumentError,
        );
        expect(
          () => TextField(
            obscureText: true,
            controller: TextEditingController(text: 'secret\n'),
          ),
          throwsArgumentError,
        );
        final field = TextField(obscureText: true, initialText: 'secret');
        expect(() => field.value = 'next\nsecret', throwsArgumentError);

        // Direct multi-char character key event strips embedded newlines on
        // single-line fields, while multiline fields split pasted CRLF cleanly.
        field.handleKeyEvent(const KeyEvent('\r\n', .character));
        expect(field.value, equals('secret'));
        field.handleKeyEvent(const KeyEvent('1\r\n2', .character));
        expect(field.value, equals('secret12'));

        final multilineField = TextField(multiline: true, initialText: 'top');
        multilineField.handleKeyEvent(const KeyEvent('\r\n', .character));
        multilineField.handleKeyEvent(const KeyEvent('bottom', .character));
        expect(multilineField.value, equals('top\nbottom'));

        for (final invalidMask in [
          '',
          '**',
          '\n',
          '\r',
          '\r\n',
          '🔒',
          '\u200B',
          '\x1b',
        ]) {
          expect(
            () => TextField(obscureText: true, obscuringCharacter: invalidMask),
            throwsArgumentError,
            reason: 'Expected ArgumentError for mask "$invalidMask"',
          );
        }
      },
    );

    test(
      'TextField masks multi-byte and ZWJ graphemes as single columns and repaints on obscureText toggle',
      () {
        final tester = TerminalTester(size: const Point(30, 4));
        tester.run(() async {
          late void Function() toggleObscure;
          final controller = TextEditingController();
          final runner = PromptRunner<void>(
            terminal: tester.terminal,
            widget: _ToggleObscureField(
              controller: controller,
              onMount: (fn) => toggleObscure = fn,
            ),
            alternateScreen: false,
          );

          await tester.runPrompt(runner, () async {
            try {
              await tester.pump();
              expect(_rowText(runner.currentBuffer!), equals('Enter PIN'));

              // Wide ZWJ emojis still mask as 1-column '*' cells per grapheme.
              controller.text = 'p🔑👨‍👩‍👧‍👦!';
              await tester.pump();
              expect(_rowText(runner.currentBuffer!), equals('****'));

              // Toggle obscureText true -> false -> true on multi-byte graphemes.
              controller.text = 'p•éñ!';
              await tester.pump();
              expect(_rowText(runner.currentBuffer!), equals('*****'));

              toggleObscure();
              await tester.pump();
              expect(_rowText(runner.currentBuffer!), equals('p•éñ!'));

              toggleObscure();
              await tester.pump();
              expect(_rowText(runner.currentBuffer!), equals('*****'));
            } finally {
              runner.dispose();
            }
          });
        });
      },
    );

    test('TextField custom obscuringCharacter renders as configured', () {
      final tester = TerminalTester(size: const Point(30, 4));
      tester.run(() async {
        final controller = TextEditingController(text: 'secret');
        final runner = PromptRunner<void>(
          terminal: tester.terminal,
          widget: SizedBox(
            width: 20,
            height: 1,
            child: TextField(
              controller: controller,
              focused: false,
              obscureText: true,
              obscuringCharacter: '-',
            ),
          ),
          alternateScreen: false,
        );

        await tester.runPrompt(runner, () async {
          try {
            await tester.pump();
            expect(_rowText(runner.currentBuffer!), equals('------'));
          } finally {
            runner.dispose();
          }
        });
      });
    });

    test(
      'TextField word navigation and deletion span full secret from mid-phrase and boundary offsets',
      () {
        final tester = TerminalTester(size: const Point(30, 4));
        tester.run(() async {
          final controller = TextEditingController(
            text: 'secret password phrase',
          );
          final runner = PromptRunner<void>(
            terminal: tester.terminal,
            widget: SizedBox(
              width: 30,
              height: 1,
              child: TextField(
                controller: controller,
                focused: true,
                obscureText: true,
              ),
            ),
            alternateScreen: false,
          );

          await tester.runPrompt(runner, () async {
            try {
              await tester.pump();

              // Move to middle of 'password' (offset 10) and verify Ctrl+Left/Right
              // do not stop at interior spaces.
              controller.value = const TextEditingValue(
                text: 'secret password phrase',
                selection: .collapsed(offset: 10, column: 10),
              );
              await tester.pump();

              tester.sendKey(.arrowLeft, control: true);
              await tester.pump();
              expect(controller.value.selection.baseOffset, equals(0));

              tester.sendKey(.arrowRight, control: true);
              await tester.pump();
              expect(controller.value.selection.baseOffset, equals(22));

              // Mid-phrase Ctrl+W deletes all characters from 0..10 across space.
              controller.value = const TextEditingValue(
                text: 'secret password phrase',
                selection: .collapsed(offset: 10, column: 10),
              );
              await tester.pump();
              tester.sendKey(.character('w'), control: true);
              await tester.pump();
              expect(controller.value.text, equals('sword phrase'));
              expect(controller.value.selection.baseOffset, equals(0));

              // Mid-phrase Ctrl+D deletes from cursor (4) to end across space.
              controller.value = const TextEditingValue(
                text: 'sword phrase',
                selection: .collapsed(offset: 4, column: 4),
              );
              await tester.pump();
              tester.sendKey(.character('d'), control: true);
              await tester.pump();
              expect(controller.value.text, equals('swor'));

              // Ctrl+W from end clears remaining secret.
              tester.sendKey(.end);
              tester.sendKey(.character('w'), control: true);
              await tester.pump();
              expect(controller.value.text, isEmpty);
            } finally {
              runner.dispose();
            }
          });
        });
      },
    );
  });
}
