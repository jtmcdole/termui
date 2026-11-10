import 'dart:convert';

import 'package:termui/terminal/event.dart' as ev;
import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

void main() {
  group('Kitty Keyboard Protocol in VirtualTerminal & InputEncoder', () {
    test(
      'VirtualTerminal manages per-screen bounded stacks, replace push, and underflow pop',
      () {
        final replies = <String>[];
        final terminal = VirtualTerminal(
          width: 80,
          height: 24,
          onReply: replies.add,
        );

        // Query initial flags (CSI ? u)
        terminal.write(utf8.encode('\x1b[?u'));
        expect(replies, equals(['\x1b[?0u']));
        replies.clear();

        // Push >8u then >1u MUST replace (== 1), NOT bitwise-OR!
        terminal.writeString('\x1b[>8u');
        expect(terminal.kittyKeyboardFlags, equals(8));
        terminal.writeString('\x1b[>1u');
        expect(terminal.kittyKeyboardFlags, equals(1));

        terminal.writeString('\x1b[?u');
        expect(replies, equals(['\x1b[?1u']));
        replies.clear();

        // Pop <1u restores 8
        terminal.writeString('\x1b[<1u');
        expect(terminal.kittyKeyboardFlags, equals(8));

        // Underflow <5u clears stack and resets flags to 0
        terminal.writeString('\x1b[<5u');
        expect(terminal.kittyKeyboardFlags, equals(0));

        // Set flags modes: 1 (replace), 2 (OR), 3 (clear), masked to 5 bits (0x1F)
        terminal.writeString('\x1b[=2;1u');
        expect(terminal.kittyKeyboardFlags, equals(2));
        terminal.writeString('\x1b[=4;2u');
        expect(terminal.kittyKeyboardFlags, equals(6));
        terminal.writeString('\x1b[=2;3u');
        expect(terminal.kittyKeyboardFlags, equals(4));

        // Primary vs Alternate screen (?1049h / ?1049l) stack & flags isolation
        terminal.writeString('\x1b[?1049h');
        expect(terminal.isUsingAlternateScreen, isTrue);
        expect(terminal.kittyKeyboardFlags, equals(0));

        terminal.writeString('\x1b[>3u\x1b[>9u');
        expect(terminal.kittyKeyboardFlags, equals(9));

        // Exiting alternate screen restores primary screen's flags (4)
        terminal.writeString('\x1b[?1049l');
        expect(terminal.isUsingAlternateScreen, isFalse);
        expect(terminal.kittyKeyboardFlags, equals(4));

        // Stack depth capped at 16 (evicts oldest)
        terminal.reset();
        expect(terminal.kittyKeyboardFlags, equals(0));
        for (var i = 1; i <= 20; i++) {
          terminal.writeString('\x1b[>${i & 0x1F}u');
        }
        terminal.writeString('\x1b[<16u');
        expect(terminal.kittyKeyboardFlags, equals(4));
        terminal.writeString('\x1b[<1u');
        expect(terminal.kittyKeyboardFlags, equals(0));
      },
    );

    test(
      'Encodes functional keys using official Kitty CSI letter/tilde/u sequences',
      () {
        const up = ev.KeyEvent('up', ev.KeyType.up);
        const ctrlUp = ev.KeyEvent(
          'up',
          ev.KeyType.up,
          modifiers: {ev.Modifier.control},
        );
        const home = ev.KeyEvent('home', ev.KeyType.home);
        const shiftHome = ev.KeyEvent(
          'home',
          ev.KeyType.home,
          modifiers: {ev.Modifier.shift},
        );
        const del = ev.KeyEvent('delete', ev.KeyType.delete);
        const ctrlDel = ev.KeyEvent(
          'delete',
          ev.KeyType.delete,
          modifiers: {ev.Modifier.control},
        );
        const f1 = ev.KeyEvent('f1', ev.KeyType.f1);
        const f3 = ev.KeyEvent('f3', ev.KeyType.f3);
        const enter = ev.KeyEvent('enter', ev.KeyType.enter);
        const shiftEnter = ev.KeyEvent(
          'enter',
          ev.KeyType.enter,
          modifiers: {ev.Modifier.shift},
        );
        const esc = ev.KeyEvent('escape', ev.KeyType.escape);

        // Under flag 1 (disambiguate):
        // Arrows & Home/End stay legacy CSI/SS3 when unmodified, CSI 1;mod ch when modified!
        expect(
          InputEncoder.encode(up, kittyKeyboardFlags: 1),
          equals('\x1b[A'),
        );
        expect(
          InputEncoder.encode(
            up,
            kittyKeyboardFlags: 1,
            applicationCursorKeys: true,
          ),
          equals('\x1bOA'),
        );
        expect(
          InputEncoder.encode(ctrlUp, kittyKeyboardFlags: 1),
          equals('\x1b[1;5A'),
        );
        expect(
          InputEncoder.encode(home, kittyKeyboardFlags: 1),
          equals('\x1b[H'),
        );
        expect(
          InputEncoder.encode(shiftHome, kittyKeyboardFlags: 1),
          equals('\x1b[1;2H'),
        );

        // Delete & tilde functional keys
        expect(
          InputEncoder.encode(del, kittyKeyboardFlags: 1),
          equals('\x1b[3~'),
        );
        expect(
          InputEncoder.encode(ctrlDel, kittyKeyboardFlags: 1),
          equals('\x1b[3;5~'),
        );

        // F1 & F3 disambiguated vs legacy flags=0
        expect(
          InputEncoder.encode(f1, kittyKeyboardFlags: 0),
          equals('\x1bOP'),
        );
        expect(
          InputEncoder.encode(f1, kittyKeyboardFlags: 1),
          equals('\x1b[P'),
        );
        expect(
          InputEncoder.encode(f3, kittyKeyboardFlags: 0),
          equals('\x1bOR'),
        );
        expect(
          InputEncoder.encode(f3, kittyKeyboardFlags: 1),
          equals('\x1b[13~'),
        );

        // Enter stays \r when unmodified under flag 1; Shift+Enter and Escape use CSI u!
        expect(InputEncoder.encode(enter, kittyKeyboardFlags: 1), equals('\r'));
        expect(
          InputEncoder.encode(shiftEnter, kittyKeyboardFlags: 1),
          equals('\x1b[13;2u'),
        );
        expect(
          InputEncoder.encode(esc, kittyKeyboardFlags: 1),
          equals('\x1b[27u'),
        );
        // Under flag 8 (reportAll), unmodified Enter uses CSI 13 u
        expect(
          InputEncoder.encode(enter, kittyKeyboardFlags: 8),
          equals('\x1b[13u'),
        );
      },
    );

    test(
      'Encodes printable keys, flag 2 release/repeat, and flag 4/5 alternate codepoints',
      () {
        const keyA = ev.KeyEvent('a', ev.KeyType.character);
        const keyARepeat = ev.KeyEvent(
          'a',
          ev.KeyType.character,
          eventType: ev.KeyEventType.repeat,
        );
        const keyARelease = ev.KeyEvent(
          'a',
          ev.KeyType.character,
          eventType: ev.KeyEventType.release,
        );

        // Release is dropped whenever flag 2 is NOT set (including flags == 0 and flags == 1)!
        expect(
          InputEncoder.encode(keyARelease, kittyKeyboardFlags: 0),
          isEmpty,
        );
        expect(
          InputEncoder.encode(keyARelease, kittyKeyboardFlags: 1),
          isEmpty,
        );

        // Under flag 2 (reportEvents without reportAll): plain 'a' press MUST stay 'a'!
        expect(InputEncoder.encode(keyA, kittyKeyboardFlags: 2), equals('a'));
        expect(
          InputEncoder.encode(keyARepeat, kittyKeyboardFlags: 2),
          equals('\x1b[97;1:2u'),
        );
        expect(
          InputEncoder.encode(keyARelease, kittyKeyboardFlags: 2),
          equals('\x1b[97;1:3u'),
        );

        // Shift+A ('A') under flag 1 stays plain 'A'
        const shiftA = ev.KeyEvent(
          'A',
          ev.KeyType.character,
          modifiers: {ev.Modifier.shift},
        );
        expect(InputEncoder.encode(shiftA, kittyKeyboardFlags: 1), equals('A'));

        // Ctrl+Shift+A under flag 5 (disambiguate | reportAlternates) emits 97:65;6u!
        const ctrlShiftA = ev.KeyEvent(
          'A',
          ev.KeyType.character,
          modifiers: {ev.Modifier.control, ev.Modifier.shift},
        );
        expect(
          InputEncoder.encode(ctrlShiftA, kittyKeyboardFlags: 5),
          equals('\x1b[97:65;6u'),
        );

        // Shift+A under flag 13 (1 | 4 | 8 = reportAll + reportAlternates) emits 97:65;2u
        expect(
          InputEncoder.encode(shiftA, kittyKeyboardFlags: 13),
          equals('\x1b[97:65;2u'),
        );

        // Alternate base layout codepoint (e.g. Cyrillic 'ф' = 1092 on physical 'a' = 97)
        const layoutCtrl = ev.KeyEvent(
          'ф',
          ev.KeyType.character,
          modifiers: {ev.Modifier.control},
          baseLayoutCodepoint: 97,
        );
        expect(
          InputEncoder.encode(layoutCtrl, kittyKeyboardFlags: 5),
          equals('\x1b[1092::97;5u'),
        );

        // C0 control character (`\x0f` with or without Modifier.control) and
        // unshifted CapsLock uppercase ('O' with Modifier.control) normalize to
        // base codepoint 111 ('o') in KTTY and raw 0x0f in legacy mode!
        for (final ctrlO in const [
          ev.KeyEvent('\x0f', ev.KeyType.character, modifiers: {.control}),
          ev.KeyEvent('\x0f', ev.KeyType.character),
          ev.KeyEvent('O', ev.KeyType.character, modifiers: {.control}),
        ]) {
          expect(
            InputEncoder.encode(ctrlO, kittyKeyboardFlags: 1),
            equals('\x1b[111;5u'),
          );
          expect(
            InputEncoder.encode(ctrlO, kittyKeyboardFlags: 0),
            equals('\x0f'),
          );
        }
        expect(
          InputEncoder.encode(
            const ev.KeyEvent(
              'O',
              ev.KeyType.character,
              modifiers: {.control},
              eventType: .release,
            ),
            kittyKeyboardFlags: 3,
          ),
          equals('\x1b[111;5:3u'),
        );
        // Control+Shift with lowercase 'o' or C0 '\x0f' and null shiftedCodepoint
        // synthesizes shifted 'O' (79) when alternate keys (flag 4) are requested.
        for (final ctrlShiftO in const [
          ev.KeyEvent('o', ev.KeyType.character, modifiers: {.control, .shift}),
          ev.KeyEvent(
            '\x0f',
            ev.KeyType.character,
            modifiers: {.control, .shift},
          ),
        ]) {
          expect(
            InputEncoder.encode(ctrlShiftO, kittyKeyboardFlags: 5),
            equals('\x1b[111:79;6u'),
          );
        }
        expect(
          [
            for (final ch in const ['\x00', '\x1c', '\x1d', '\x1e', '\x1f'])
              InputEncoder.encode(
                ev.KeyEvent(
                  ch,
                  ev.KeyType.character,
                  modifiers: const {.control},
                ),
                kittyKeyboardFlags: 1,
              ),
          ],
          equals(const [
            '\x1b[32;5u',
            '\x1b[92;5u',
            '\x1b[93;5u',
            '\x1b[94;5u',
            '\x1b[95;5u',
          ]),
        );
        // Raw '\t', '\n', '\r', and '\x1b' character payloads remain untouched.
        expect(
          InputEncoder.encode(
            const ev.KeyEvent('\t', ev.KeyType.character),
            kittyKeyboardFlags: 0,
          ),
          equals('\t'),
        );
      },
    );

    test(
      'TerminalView.wantsKeyReleaseEvents routes key release when flag 2 is enabled',
      () {
        debugShowTouchesEnabled = false;
        FocusManager.instance.setPrimaryFocus(null);
        final tester = TerminalTester();
        final vt = VirtualTerminal(width: 20, height: 5);
        final inputs = <String>[];
        final view = TerminalView(terminal: vt, onInput: inputs.add);

        expect(view.wantsKeyReleaseEvents, isFalse);

        tester.run(() async {
          final runner = PromptRunner<Object?>(
            terminal: tester.terminal,
            alternateScreen: false,
            widget: SizedBox.expand(child: view),
          );
          final runFuture = runner.run();
          await tester.pump(const Duration(milliseconds: 30));

          // Release ignored while flag 2 is off
          tester.sendString('\x1b[97;1:3u');
          await tester.pump(const Duration(milliseconds: 20));
          expect(inputs, isEmpty);

          // Enable flag 3 (disambiguate | reportEvents) on child terminal
          vt.writeString('\x1b[>3u');
          expect(view.wantsKeyReleaseEvents, isTrue);
          await tester.pump(const Duration(milliseconds: 20));

          tester.sendString('\x1b[97;1:3u');
          await tester.pump(const Duration(milliseconds: 20));
          expect(inputs, equals(['\x1b[97;1:3u']));

          runner.abort();
          await runFuture.catchError((_) => null);
        });
        vt.dispose();
      },
    );

    test(
      'Unfocused TerminalView does not steal key or release events from focused pane',
      () {
        debugShowTouchesEnabled = false;
        FocusManager.instance.setPrimaryFocus(null);
        final tester = TerminalTester();
        final vt1 = VirtualTerminal(width: 20, height: 5)
          ..writeString('\x1b[>3u');
        final vt2 = VirtualTerminal(width: 20, height: 5)
          ..writeString('\x1b[>3u');
        final inputs1 = <String>[];
        final inputs2 = <String>[];
        final fn1 = FocusNode(id: 'pane1');
        final fn2 = FocusNode(id: 'pane2');

        tester.run(() async {
          final runner = PromptRunner<Object?>(
            terminal: tester.terminal,
            alternateScreen: false,
            widget: Row([
              TerminalView(
                terminal: vt1,
                focusNode: fn1,
                autofocus: false,
                onInput: inputs1.add,
              ),
              TerminalView(
                terminal: vt2,
                focusNode: fn2,
                autofocus: true,
                onInput: inputs2.add,
              ),
            ]),
          );
          final runFuture = runner.run();
          await tester.pump(const Duration(milliseconds: 30));

          tester.sendString('x');
          tester.sendString('\x1b[120;1:3u');
          await tester.pump(const Duration(milliseconds: 20));

          expect(inputs1, isEmpty);
          expect(inputs2, equals(['x', '\x1b[120;1:3u']));

          runner.abort();
          await runFuture.catchError((_) => null);
        });
        fn1.dispose();
        fn2.dispose();
        vt1.dispose();
        vt2.dispose();
      },
    );
  });
}
