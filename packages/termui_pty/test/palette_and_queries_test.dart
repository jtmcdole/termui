import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:test/test.dart';

void main() {
  group('VirtualTerminal indexed palette & appearance queries', () {
    test(
      'emitIndexedColors preserves Color.ansi slots while leaving truecolor exact',
      () {
        final indexed = VirtualTerminal(
          width: 20,
          height: 4,
          emitIndexedColors: true,
        );
        indexed.writeString(
          '\x1b[34mA\x1b[38;5;18mB\x1b[38;2;0;0;170mC\x1b[0m',
        );

        final fgA = indexed.buffer.getForeground(0, 0);
        final fgB = indexed.buffer.getForeground(1, 0);
        final fgC = indexed.buffer.getForeground(2, 0);

        expect(fgA.isAnsiIndexed, isTrue);
        expect(fgA.ansiIndex, equals(4));
        expect(fgB.isAnsiIndexed, isTrue);
        expect(fgB.ansiIndex, equals(18));
        expect(fgC.isAnsiIndexed, isFalse);
        expect(fgC, equals(0xFF0000AA));

        // Backward-compatibility default: emitIndexedColors is false.
        final legacy = VirtualTerminal(width: 10, height: 2);
        legacy.writeString('\x1b[34mA\x1b[0m');
        final legacyA = legacy.buffer.getForeground(0, 0);
        expect(legacyA.isAnsiIndexed, isFalse);
        expect(legacyA, equals(0xFF0000AA));
      },
    );

    test(
      'OSC 4 chained set/query and OSC 104 reset affect active style immediately',
      () {
        final replies = <String>[];
        final vt = VirtualTerminal(
          width: 10,
          height: 2,
          emitIndexedColors: true,
          theme: TerminalColorTheme.solarizedDark,
          onReply: replies.add,
        );

        // Query theme slot 4 before override.
        vt.writeString('\x1b]4;4;?\x07');
        expect(replies, hasLength(1));
        expect(replies.single, equals('\x1b]4;4;rgb:2626/8b8b/d2d2\x1b\\'));
        replies.clear();

        // Set active SGR 34 BEFORE OSC 4 override.
        vt.writeString('\x1b[34mA');
        expect(vt.buffer.getForeground(0, 0), equals(const Color.ansi(4)));

        // Mutate slot 4 and 12 via chained OSC 4 without re-sending SGR 34.
        vt.writeString('\x1b]4;4;rgb:ff/00/80;12;#112233\x1b\\B');
        expect(vt.buffer.getForeground(1, 0), equals(0xFFFF0080));

        // Chained query returns overridden values.
        vt.writeString('\x1b]4;4;?;12;?\x1b\\');
        expect(
          replies,
          equals(<String>[
            '\x1b]4;4;rgb:ffff/0000/8080\x1b\\',
            '\x1b]4;12;rgb:1111/2222/3333\x1b\\',
          ]),
        );
        replies.clear();

        // Reset slot 4 via OSC 104 without re-sending SGR 34 -> back to indexed slot 4.
        vt.writeString('\x1b]104;4\x07C');
        expect(vt.buffer.getForeground(2, 0), equals(const Color.ansi(4)));

        // Reset remaining overrides via empty OSC 104.
        vt.writeString('\x1b]104\x07\x1b]4;12;?\x07');
        expect(replies.single, equals('\x1b]4;12;rgb:8383/9494/9696\x1b\\'));
      },
    );

    test(
      'OSC 4 overrides SGR 58;5;n underlineColor and notifies listeners on mutations only',
      () {
        var notifications = 0;
        final replies = <String>[];
        final vt = VirtualTerminal(
          width: 10,
          height: 2,
          emitIndexedColors: true,
          theme: TerminalColorTheme.termuiDark,
          onReply: replies.add,
        )..addListener(() => notifications++);

        // Pure queries do not mark the terminal dirty.
        vt.writeString('\x1b]4;4;?\x07\x1b]10;?\x07');
        expect(replies, hasLength(2));
        expect(notifications, equals(0));

        // Mutating OSC 4 marks dirty and overrides indexed SGR 58;5;4 underlineColor
        // on both narrow and wide graphemes.
        vt.writeString('\x1b]4;4;#ff33aa\x07');
        expect(notifications, equals(1));

        vt.writeString('\x1b[4;58;5;4mA漢');
        expect(vt.buffer.getUnderlineColor(0, 0), equals(0xFFFF33AA));
        expect(vt.buffer.getUnderlineColor(1, 0), equals(0xFFFF33AA));

        // Resetting slot 4 via OSC 104 marks dirty and restores indexed Color.ansi(4).
        final beforeReset = notifications;
        vt.writeString('\x1b]104;4\x07');
        expect(notifications, equals(beforeReset + 1));

        vt.writeString('B');
        expect(
          vt.buffer.getUnderlineColor(3, 0),
          equals(const Color.ansi(4).argb),
        );

        // OSC 10/11/12 set and 110/111/112 reset notify listeners when mutating state.
        final beforeDyn = notifications;
        vt.writeString('\x1b]10;#112233\x07');
        expect(notifications, equals(beforeDyn + 1));
        vt.writeString('\x1b]110\x07');
        expect(notifications, equals(beforeDyn + 2));
        // Redundant OSC 110 when already null does not notify again.
        vt.writeString('\x1b]110\x07');
        expect(notifications, equals(beforeDyn + 2));
      },
    );

    test(
      'OSC 10/11/12 set, query, and 110/111/112 reset work with theme defaults',
      () {
        final replies = <String>[];
        final vt = VirtualTerminal(
          width: 10,
          height: 2,
          theme: TerminalColorTheme.solarizedLight,
          onReply: replies.add,
        );

        vt.writeString('\x1b]10;?\x07\x1b]11;?\x07\x1b]12;?\x07');
        expect(
          replies,
          equals(<String>[
            '\x1b]10;rgb:6565/7b7b/8383\x1b\\',
            '\x1b]11;rgb:fdfd/f6f6/e3e3\x1b\\',
            '\x1b]12;rgb:5858/6e6e/7575\x1b\\',
          ]),
        );
        replies.clear();

        // Override dynamic fg/bg/cursor colors, verify subsequent default cell print picks them up.
        vt.writeString(
          '\x1b]10;#123456\x07\x1b]11;#abcdef\x07\x1b]12;#445566\x07X',
        );
        expect(vt.buffer.getForeground(0, 0), equals(0xFF123456));
        expect(vt.buffer.getBackground(0, 0), equals(0xFFABCDEF));

        vt.writeString('\x1b]10;?\x07\x1b]11;?\x07\x1b]12;?\x07');
        expect(
          replies,
          equals(<String>[
            '\x1b]10;rgb:1212/3434/5656\x1b\\',
            '\x1b]11;rgb:abab/cdcd/efef\x1b\\',
            '\x1b]12;rgb:4444/5555/6666\x1b\\',
          ]),
        );
        replies.clear();

        // Reset dynamic colors via OSC 110/111/112.
        vt.writeString('\x1b]110\x07\x1b]111\x07\x1b]112\x07');
        vt.writeString('\x1b]10;?\x07\x1b]11;?\x07\x1b]12;?\x07');
        expect(
          replies,
          equals(<String>[
            '\x1b]10;rgb:6565/7b7b/8383\x1b\\',
            '\x1b]11;rgb:fdfd/f6f6/e3e3\x1b\\',
            '\x1b]12;rgb:5858/6e6e/7575\x1b\\',
          ]),
        );
      },
    );

    test(
      'CSI ? 996 n, DECRQM 2031, DECSET 2031 notifications, and RIS reset',
      () {
        final replies = <String>[];
        final vt = VirtualTerminal(
          width: 10,
          height: 2,
          theme: TerminalColorTheme.termuiDark,
          onReply: replies.add,
        );

        // Dark query and DECRQM 2031 initially reset (Pm = 2).
        vt.writeString('\x1b[?996n\x1b[?2031\$p');
        expect(replies, equals(<String>['\x1b[?997;1n', '\x1b[?2031;2\$y']));
        replies.clear();

        // Enable mode 2031 and switch to light -> unsolicited ?997;2n.
        vt.writeString('\x1b[?2031h\x1b[?2031\$p');
        expect(replies.single, equals('\x1b[?2031;1\$y'));
        replies.clear();

        vt.setColorScheme(TerminalBrightness.light);
        expect(replies.single, equals('\x1b[?997;2n'));
        replies.clear();

        vt.writeString('\x1b[?996n');
        expect(replies.single, equals('\x1b[?997;2n'));
        replies.clear();

        // RIS clears OSC overrides and disables mode 2031 reporting.
        vt.writeString('\x1b]4;1;#ff0000\x07\x1b]10;#222222\x07');
        vt.writeString('\x1bc');
        vt.setColorScheme(TerminalBrightness.dark);
        expect(replies, isEmpty);

        vt.writeString('\x1b[?2031\$p\x1b]4;1;?\x07\x1b]10;?\x07');
        expect(
          replies,
          equals(<String>[
            '\x1b[?2031;2\$y',
            '\x1b]4;1;rgb:e0e0/6c6c/7575\x1b\\',
            '\x1b]10;rgb:e6e6/eded/f3f3\x1b\\',
          ]),
        );
      },
    );
  });
}
