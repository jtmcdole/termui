import 'dart:convert';

import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    FocusManager.instance.setPrimaryFocus(null);
  });

  group('VirtualTerminal text and wide graphemes', () {
    test('processes ANSI sequences into Buffer', () {
      final terminal = VirtualTerminal(width: 10, height: 5);
      terminal.write('\x1b[1;1H\x1b[31mHello'.codeUnits);

      final buffer = terminal.buffer;
      expect(buffer.characters.join(), startsWith('Hello'));
      expect(buffer.getForeground(0, 0), equals(const Color(170, 0, 0).argb));
    });

    test('handles multi-byte wide graphemes and UTF-8 sequences', () {
      final terminal = VirtualTerminal(width: 10, height: 5);
      terminal.write(utf8.encode('\x1b[1;1H🍎'));

      expect(terminal.buffer.getCharacter(0, 0), equals('🍎'));
      expect(terminal.buffer.getCharacter(1, 0), equals(''));
      expect(terminal.buffer.getCharacter(2, 0), equals(' '));
    });

    test(
      'writeString and write(utf8.encode) both render non-ASCII Latin-1 chars like © without U+FFFD',
      () {
        final fromString = VirtualTerminal(width: 10, height: 1);
        fromString.writeString('© 2026');
        expect(fromString.buffer.getCharacter(0, 0), equals('©'));
        expect(fromString.buffer.getCharacter(0, 0), isNot(equals('\uFFFD')));
        expect(
          [
            for (var x = 0; x < 6; x++) fromString.buffer.getCharacter(x, 0),
          ].join(),
          equals('© 2026'),
        );

        final fromUtf8 = VirtualTerminal(width: 10, height: 1);
        fromUtf8.write(utf8.encode('© 2026'));
        expect(fromUtf8.buffer.getCharacter(0, 0), equals('©'));
        expect(fromUtf8.buffer.getCharacter(0, 0), isNot(equals('\uFFFD')));
        expect(
          [
            for (var x = 0; x < 6; x++) fromUtf8.buffer.getCharacter(x, 0),
          ].join(),
          equals('© 2026'),
        );
      },
    );

    test('handles horizontal tab stops (\\t)', () {
      final terminal = VirtualTerminal(width: 20, height: 5);
      terminal.write(utf8.encode('A\tB\tC'));
      expect(terminal.buffer.getCharacter(0, 0), equals('A'));
      expect(terminal.buffer.getCharacter(8, 0), equals('B'));
      expect(terminal.buffer.getCharacter(16, 0), equals('C'));

      terminal.write(utf8.encode('\tZ'));
      expect(terminal.buffer.getCharacter(19, 0), equals('Z'));
    });

    test('overwriting colored cells after SGR 0 clears stale fg and bg', () {
      final terminal = VirtualTerminal(width: 10, height: 3);
      terminal.write(utf8.encode('\x1b[1;31;44mHELLO\r\x1b[0mworld'));

      for (var x = 0; x < 5; x++) {
        expect(terminal.buffer.getCharacter(x, 0), equals('world'[x]));
        expect(terminal.buffer.getForeground(x, 0), equals(0));
        expect(terminal.buffer.getBackground(x, 0), equals(0));
        expect(terminal.buffer.getModifiers(x, 0), equals(Modifier.none));
      }

      // Wide grapheme overwrite after SGR reset clears both leading and trailing cells.
      terminal.write(utf8.encode('\r\x1b[31;44mAB\r\x1b[m🍎'));
      expect(terminal.buffer.getCharacter(0, 0), equals('🍎'));
      expect(terminal.buffer.getForeground(0, 0), equals(0));
      expect(terminal.buffer.getBackground(0, 0), equals(0));
      expect(terminal.buffer.getCharacter(1, 0), equals(''));
      expect(terminal.buffer.getForeground(1, 0), equals(0));
      expect(terminal.buffer.getBackground(1, 0), equals(0));
    });

    test(
      'splitting a wide emoji in an opaque TerminalView preserves Modifier.none',
      () {
        final terminal = VirtualTerminal(width: 4, height: 1);
        terminal.write(utf8.encode('🍎\rA'));

        expect(terminal.buffer.getModifiers(0, 0), equals(Modifier.none));
        expect(terminal.buffer.getModifiers(1, 0), equals(Modifier.none));

        final canvas = Buffer.blank(4, 1)
          ..fillAttributes(char: '#', fg: 0xFF00FF00, bg: 0xFF004400);
        final element =
            TerminalView(terminal: terminal, autofocus: false).createElement()
              ..mount(null)
              ..layout(BoxConstraints.tight(const Size(4, 1)))
              ..paint(canvas, Offset.zero);
        addTearDown(element.unmount);

        // Cell (1, 0) was the split right half of '🍎'; it must overwrite '#'
        // and stay opaque (Modifier.none) rather than leaking Modifier.transparent.
        expect(canvas.getCharacter(0, 0), equals('A'));
        expect(canvas.getCharacter(1, 0), equals(' '));
        expect(canvas.getForeground(1, 0), equals(0));
        expect(canvas.getBackground(1, 0), equals(0));
        expect(canvas.getModifiers(1, 0), equals(Modifier.none));
      },
    );
  });

  group('VirtualTerminal SGR 39 and 49 defaults', () {
    test(
      'SGR 39 resets foreground while preserving background and modifiers',
      () {
        final terminal = VirtualTerminal(width: 6, height: 1);
        terminal.write(utf8.encode('\x1b[1;31;44mA\x1b[39mB'));

        final blue = const Color(0, 0, 170).argb;
        expect(terminal.buffer.getForeground(1, 0), equals(0));
        expect(terminal.buffer.getBackground(1, 0), equals(blue));
        expect(terminal.buffer.getModifiers(1, 0), equals(Modifier.bold));
      },
    );

    test(
      'SGR 49 resets background while preserving foreground and modifiers',
      () {
        final terminal = VirtualTerminal(width: 6, height: 1);
        terminal.write(utf8.encode('\x1b[1;31;44mA\x1b[49mB'));

        final red = const Color(170, 0, 0).argb;
        expect(terminal.buffer.getForeground(1, 0), equals(red));
        expect(terminal.buffer.getBackground(1, 0), equals(0));
        expect(terminal.buffer.getModifiers(1, 0), equals(Modifier.bold));
      },
    );
  });

  group('VirtualTerminal erases, scroll BCE, resize, and overflow safety', () {
    test('CSI 0J, 1J, 2J, and 3J honor BCE and preserve active screen on 3J', () {
      final terminal = VirtualTerminal(width: 4, height: 3);
      final red = const Color(170, 0, 0).argb;
      final green = const Color(0, 170, 0).argb;

      // Fill screen with red fg/bg, then erase below from (1, 1) with green bg (BCE).
      terminal.write(utf8.encode('\x1b[31;41mAAAA\r\nBBBB\r\nCCCC'));
      terminal.write(utf8.encode('\x1b[2;2H\x1b[42m\x1b[0J'));

      expect(terminal.buffer.getCharacter(0, 1), equals('B'));
      expect(terminal.buffer.getBackground(0, 1), equals(red));
      expect(terminal.buffer.getCharacter(1, 1), equals(' '));
      expect(terminal.buffer.getForeground(1, 1), equals(0));
      expect(terminal.buffer.getBackground(1, 1), equals(green));
      expect(terminal.buffer.getBackground(3, 2), equals(green));

      // Erase above from (2, 1) with default bg.
      terminal.write(utf8.encode('\x1b[49m\x1b[2;3H\x1b[1J'));
      expect(terminal.buffer.getBackground(0, 0), equals(0));
      expect(terminal.buffer.getBackground(2, 1), equals(0));
      expect(terminal.buffer.getBackground(3, 1), equals(green));

      // CSI 3J (erase scrollback) must not wipe the active display.
      terminal.write(utf8.encode('\x1b[1;1H\x1b[31mZ\x1b[3J'));
      expect(terminal.buffer.getCharacter(0, 0), equals('Z'));
      expect(terminal.buffer.getForeground(0, 0), equals(red));

      // CSI 2J wipes the active display and resets colors.
      terminal.write(utf8.encode('\x1b[0m\x1b[2J'));
      for (var y = 0; y < 3; y++) {
        for (var x = 0; x < 4; x++) {
          expect(terminal.buffer.getCharacter(x, y), equals(' '));
          expect(terminal.buffer.getForeground(x, y), equals(0));
          expect(terminal.buffer.getBackground(x, y), equals(0));
        }
      }
    });

    test('CSI 0K, 1K, 2K handle BCE, transparentBackground, and pending wrap', () {
      final opaque = VirtualTerminal(width: 4, height: 2);
      final blue = const Color(0, 0, 170).argb;

      // Write all 4 columns on row 0 so cursorX == 4 (pending wrap), then CSI 0K.
      opaque.write(utf8.encode('\x1b[31;44mABCD'));
      expect(opaque.cursorX, equals(4));
      opaque.write(utf8.encode('\x1b[0m\x1b[0K'));
      expect(opaque.cursorX, equals(3));
      expect(opaque.buffer.getCharacter(2, 0), equals('C'));
      expect(opaque.buffer.getCharacter(3, 0), equals(' '));
      expect(opaque.buffer.getForeground(3, 0), equals(0));
      expect(opaque.buffer.getBackground(3, 0), equals(0));

      // CSI 1K and CSI 2K with BCE.
      opaque.write(utf8.encode('\x1b[1;2H\x1b[44m\x1b[1K'));
      expect(opaque.buffer.getCharacter(0, 0), equals(' '));
      expect(opaque.buffer.getBackground(0, 0), equals(blue));
      expect(opaque.buffer.getCharacter(1, 0), equals(' '));
      expect(opaque.buffer.getBackground(1, 0), equals(blue));
      expect(opaque.buffer.getCharacter(2, 0), equals('C'));

      opaque.write(utf8.encode('\x1b[0m\x1b[2K'));
      for (var x = 0; x < 4; x++) {
        expect(opaque.buffer.getBackground(x, 0), equals(0));
      }

      // Transparent terminal erases to Modifier.transparent when bg is default,
      // and opaque Modifier.none when an explicit non-black BCE bg is active.
      final transparent = VirtualTerminal(
        width: 4,
        height: 1,
        transparentBackground: true,
      );
      transparent.write(utf8.encode('\x1b[44m\x1b[2K'));
      expect(transparent.buffer.getBackground(0, 0), equals(blue));
      expect(transparent.buffer.getModifiers(0, 0), equals(Modifier.none));

      transparent.write(utf8.encode('\x1b[49m\x1b[2K'));
      expect(transparent.buffer.getBackground(0, 0), equals(0));
      expect(
        transparent.buffer.getModifiers(0, 0),
        equals(Modifier.transparent),
      );
    });

    test('scrollUp preserves opaque cells and applies BCE background', () {
      final terminal = VirtualTerminal(width: 4, height: 2);
      final blue = const Color(0, 0, 170).argb;

      terminal.write(utf8.encode('ROW1\r\nROW2\x1b[44m\r\n'));

      expect(terminal.buffer.getCharacter(0, 0), equals('R'));
      expect(terminal.buffer.getCharacter(3, 0), equals('2'));
      for (var x = 0; x < 4; x++) {
        expect(terminal.buffer.getCharacter(x, 1), equals(' '));
        expect(terminal.buffer.getBackground(x, 1), equals(blue));
        expect(terminal.buffer.getModifiers(x, 1), equals(Modifier.none));
      }
    });

    test(
      'resize preserves opaque blank cells and guards non-positive sizes',
      () {
        final terminal = VirtualTerminal(width: 4, height: 2);
        terminal.write(utf8.encode('Hi'));
        terminal.resize(6, 3);

        expect(terminal.buffer.getModifiers(5, 2), equals(Modifier.none));

        expect(() => terminal.resize(0, 0), returnsNormally);
        expect(terminal.width, greaterThanOrEqualTo(1));
        expect(terminal.height, greaterThanOrEqualTo(1));
        expect(terminal.cursorX, inInclusiveRange(0, terminal.width - 1));
        expect(terminal.cursorY, inInclusiveRange(0, terminal.height - 1));
      },
    );

    test('clamps 64-bit overflowing CSI parameters safely', () {
      final terminal = VirtualTerminal(width: 6, height: 3);
      terminal.write(utf8.encode('ABCDEF'));
      // 20-digit parameter previously overflowed 64-bit signed int negative.
      terminal.write(utf8.encode('\x1b[9223372036854775808B\x1b[J'));
      expect(terminal.cursorY, equals(2));
      expect(terminal.cursorX, equals(5));

      terminal.csi('B', [-9223372036854775808]);
      expect(terminal.cursorY, equals(2));
    });
  });

  group('VirtualTerminal resets, DECSC/DECRC, CHA/VPA/ECH, and CSI guards', () {
    test(
      'CHA (G), VPA (d), and ECH (X) handle BCE, wide splits, and pending wrap',
      () {
        final terminal = VirtualTerminal(width: 6, height: 3);
        final blue = const Color(0, 0, 170).argb;

        // Fill row 0 so cursorX == 6 (pending wrap), then VPA to row 2 (1-indexed).
        terminal.write(utf8.encode('ABCDEF\x1b[2d'));
        expect(terminal.cursorX, equals(5));
        expect(terminal.cursorY, equals(1));

        // CHA to col 2 (1-indexed), write wide emoji at cols 1..2, then CHA col 1
        // and ECH 2 chars with blue BCE background (splitting '🍎' cleanly).
        terminal.write(
          utf8.encode('\x1b[1;1H\x1b[2G🍎Z\x1b[1G\x1b[44m\x1b[2X'),
        );
        expect(terminal.cursorX, equals(0));
        expect(terminal.buffer.getCharacter(0, 0), equals(' '));
        expect(terminal.buffer.getBackground(0, 0), equals(blue));
        expect(terminal.buffer.getCharacter(1, 0), equals(' '));
        expect(terminal.buffer.getBackground(1, 0), equals(blue));
        // Split right half of '🍎' at col 2 must be reset to ' ' instead of ''.
        expect(terminal.buffer.getCharacter(2, 0), equals(' '));
        expect(terminal.buffer.getCharacter(3, 0), equals('Z'));

        // Pending-wrap ECH clamps cursorX to width - 1 and erases the last cell,
        // and huge ECH counts do not overflow 64-bit signed arithmetic.
        terminal.write(utf8.encode('\x1b[0m\x1b[1;1H123456'));
        expect(terminal.cursorX, equals(6));
        terminal.write(utf8.encode('\x1b[99999999999999999999X'));
        expect(terminal.cursorX, equals(5));
        expect(terminal.buffer.getCharacter(4, 0), equals('5'));
        expect(terminal.buffer.getCharacter(5, 0), equals(' '));
      },
    );

    test(
      'private and intermediate CSI sequences do not leak into standard SGR',
      () {
        final terminal = VirtualTerminal(width: 6, height: 2);

        // DECSET / DECRST mouse tracking modes.
        terminal.write(utf8.encode('\x1b[?1002;1006h'));
        expect(terminal.mouseTrackingEnabled, isTrue);
        expect(terminal.sgrMouseMode, isTrue);
        terminal.write(utf8.encode('\x1b[?1002;1006l'));
        expect(terminal.mouseTrackingEnabled, isFalse);
        expect(terminal.sgrMouseMode, isFalse);

        // modifyOtherKeys (\x1b[>4;2m), XTQMODKEYS (\x1b[?4m), and DECSCUSR (\x1b[2 q)
        // must not apply SGR 4 (underline) or SGR 2 (dim).
        terminal.write(utf8.encode('\x1b[>4;2m\x1b[?4m\x1b[2 qA'));
        expect(terminal.buffer.getCharacter(0, 0), equals('A'));
        expect(terminal.buffer.getModifiers(0, 0), equals(Modifier.none));
      },
    );

    test(
      'DECSC (ESC 7) and DECRC (ESC 8) save and restore style and pending wrap',
      () {
        final terminal = VirtualTerminal(width: 4, height: 2);
        final red = const Color(170, 0, 0).argb;

        // Save cursor in pending-wrap state (cursorX == 4) with red bold style.
        terminal.write(utf8.encode('\x1b[1;31mABCD\x1b7'));
        expect(terminal.cursorX, equals(4));

        // Move elsewhere and reset SGR, then restore and print 'Z' (wraps to row 1 col 0).
        terminal.write(utf8.encode('\x1b[2;2H\x1b[0mX\x1b8Z'));
        expect(terminal.buffer.getCharacter(0, 1), equals('Z'));
        expect(terminal.buffer.getForeground(0, 1), equals(red));
        expect(terminal.buffer.getModifiers(0, 1), equals(Modifier.bold));
      },
    );

    test(
      'RIS (ESC c), DECSTR (CSI ! p), and reset() clear stale state and partial streams',
      () {
        final terminal = VirtualTerminal(width: 6, height: 2);
        var notifications = 0;
        terminal.addListener(() => notifications++);

        // DECSTR (soft reset) resets SGR, saved cursor, mouse modes, and pending wrap
        // without erasing existing screen text.
        terminal.write(
          utf8.encode('\x1b[?1000;1006h\x1b[1;31;44mABCDEF\x1b7\x1b[!p'),
        );
        expect(terminal.mouseTrackingEnabled, isFalse);
        expect(terminal.sgrMouseMode, isFalse);
        expect(terminal.cursorX, equals(5));
        expect(terminal.buffer.getCharacter(0, 0), equals('A'));
        terminal.write(utf8.encode('\rX'));
        expect(terminal.buffer.getForeground(0, 0), equals(0));
        expect(terminal.buffer.getBackground(0, 0), equals(0));
        expect(terminal.buffer.getModifiers(0, 0), equals(Modifier.none));

        // RIS (ESC c) mid-chunk resets screen and prints trailing text cleanly at (0, 0).
        terminal.write(utf8.encode('\x1b[31;44mDIRTY\x1bcClean'));
        expect(terminal.buffer.getCharacter(0, 0), equals('C'));
        expect(terminal.buffer.getCharacter(4, 0), equals('n'));
        expect(terminal.buffer.getForeground(0, 0), equals(0));
        expect(terminal.buffer.getBackground(0, 0), equals(0));

        // reset() recovers from mid-OSC, mid-CSI, and split multi-byte UTF-8 bytes.
        terminal.write(utf8.encode('\x1b]0;unterminated title'));
        final beforeReset = notifications;
        terminal.reset();
        expect(notifications, equals(beforeReset + 1));
        terminal.write(utf8.encode('Ok'));
        expect(terminal.buffer.getCharacter(0, 0), equals('O'));
        expect(terminal.buffer.getCharacter(1, 0), equals('k'));

        terminal.write(utf8.encode('\x1b[31'));
        terminal.reset();
        terminal.write(utf8.encode('Hi'));
        expect(terminal.buffer.getCharacter(0, 0), equals('H'));
        expect(terminal.buffer.getForeground(0, 0), equals(0));

        // First 2 bytes of 4-byte UTF-8 '🍎' ([0xF0, 0x9F, 0x8D, 0x8E]), then reset().
        terminal.write(const [0xF0, 0x9F]);
        terminal.reset();
        terminal.write(utf8.encode('Plain'));
        expect(terminal.buffer.getCharacter(0, 0), equals('P'));
        expect(terminal.buffer.getCharacter(1, 0), equals('l'));
      },
    );
  });

  group('VirtualTerminal TUI modes: alt screen, DECTCEM, DECSTBM, and DECAWM', () {
    test(
      'switches primary and alternate screens (?1049, ?1047, ?47) with independent saved cursors, resize, and resets',
      () {
        final terminal = VirtualTerminal(width: 8, height: 3);
        final red = const Color(170, 0, 0).argb;

        expect(terminal.isUsingAlternateScreen, isFalse);

        // Save primary cursor at (2, 0) with red style, then print more text to (6, 0).
        terminal.write(utf8.encode('\x1b[31mHI\x1b7\x1b[0m_PRI'));
        expect(terminal.cursorX, equals(6));

        // Enter ?1049h: saves primary cursor (6, 0), switches to blank alt screen at (0, 0).
        terminal.write(utf8.encode('\x1b[?1049h'));
        expect(terminal.isUsingAlternateScreen, isTrue);
        expect(terminal.cursorX, equals(0));
        expect(terminal.cursorY, equals(0));
        expect(terminal.buffer.getCharacter(0, 0), equals(' '));

        // DECSC/DECRC, ?1048h/?1048l, DECSTR, and redundant ?1049h inside alt screen
        // must not clobber primary saved cursor or wipe active alt buffer.
        terminal.write(utf8.encode('ALT\x1b[?1048h_MORE\x1b[?1048l'));
        expect(terminal.cursorX, equals(3));
        terminal.write(utf8.encode('\x1b[!p\x1b[?1049h'));
        expect(terminal.buffer.getCharacter(0, 0), equals('A'));

        // Resize while in alt screen resizes both primary and alt buffers and heals clipped wide chars.
        terminal.write(utf8.encode('\x1b[2;5H🚀'));
        terminal.resize(5, 4);
        expect(terminal.buffer.width, equals(5));
        expect(terminal.buffer.height, equals(4));
        expect(terminal.buffer.getCharacter(4, 1), equals(' '));

        // Exit ?1049l: restores primary buffer ("HI_PRI") and clamps restored cursor (6 -> 4).
        terminal.write(utf8.encode('\x1b[?1049l'));
        expect(terminal.isUsingAlternateScreen, isFalse);
        expect(terminal.buffer.width, equals(5));
        expect(terminal.buffer.getCharacter(0, 0), equals('H'));
        expect(terminal.buffer.getForeground(0, 0), equals(red));
        expect(terminal.buffer.getCharacter(4, 0), equals('R'));
        expect(terminal.cursorX, equals(4));

        // ?47h / ?47l and ?1047h / ?1047l switch buffers without saving/restoring cursor,
        // and RIS (ESC c) inside alt screen returns to cleared primary screen.
        terminal.write(utf8.encode('\x1b[2;3H\x1b[?47hTUI\x1b[?47l'));
        expect(terminal.isUsingAlternateScreen, isFalse);
        expect(terminal.buffer.getCharacter(0, 0), equals('H'));

        terminal.write(utf8.encode('\x1b[?1047hALT2\x1bc'));
        expect(terminal.isUsingAlternateScreen, isFalse);
        expect(terminal.buffer.getCharacter(0, 0), equals(' '));

        // Transparent terminal keeps Modifier.transparent on alternate screen too,
        // and inverted DECSTBM on a 1-row terminal is rejected without homing cursor.
        final transparent = VirtualTerminal(
          width: 4,
          height: 1,
          transparentBackground: true,
        );
        transparent.write(utf8.encode('\x1b[?1049hAB\x1b[4;2r'));
        expect(transparent.cursorX, equals(2));
        expect(
          transparent.buffer.getModifiers(3, 0),
          equals(Modifier.transparent),
        );
      },
    );

    test(
      'tracks DECTCEM (?25h / ?25l) cursorVisible and restores visibility on DECSTR, RIS, and reset()',
      () {
        final terminal = VirtualTerminal(width: 6, height: 2);
        expect(terminal.cursorVisible, isTrue);

        terminal.write(utf8.encode('\x1b[?25l'));
        expect(terminal.cursorVisible, isFalse);

        terminal.write(utf8.encode('\x1b[?25h'));
        expect(terminal.cursorVisible, isTrue);

        terminal.write(utf8.encode('\x1b[?25l\x1b[!p'));
        expect(terminal.cursorVisible, isTrue);

        terminal.write(utf8.encode('\x1b[?25l\x1bc'));
        expect(terminal.cursorVisible, isTrue);

        terminal.write(utf8.encode('\x1b[?25l'));
        terminal.reset();
        expect(terminal.cursorVisible, isTrue);
      },
    );

    test(
      'supports DECSTBM (CSI r), RI (ESC M), IND/NEL, IL/DL (CSI L/M), SU/SD (CSI S/T), and ICH/DCH (CSI @/P)',
      () {
        final terminal = VirtualTerminal(width: 6, height: 5);
        final green = const Color(0, 170, 0).argb;

        // Paint 5 rows (TOP, R1, R2, R3, BOT) and pin rows 1..3 via DECSTBM (\x1b[2;4r).
        terminal.write(
          utf8.encode('TOP---\r\nR1----\r\nR2----\r\nR3----\r\nBOT---'),
        );
        terminal.write(utf8.encode('\x1b[2;4r'));
        expect(terminal.cursorX, equals(0));
        expect(terminal.cursorY, equals(0));

        // Invalid margin (\x1b[4;2r or \x1b[1;1r) is ignored without moving cursor.
        terminal.write(utf8.encode('\x1b[4;1H\x1b[4;2r\x1b[1;1r'));
        expect(terminal.cursorY, equals(3));

        // LF at bottom of scroll region (row 3) scrolls only rows 1..3 with BCE; TOP and BOT stay pinned!
        terminal.write(utf8.encode('\x1b[42m\n\x1b[0m'));
        expect(terminal.buffer.getCharacter(0, 0), equals('T'));
        expect(terminal.buffer.getCharacter(1, 1), equals('2'));
        expect(terminal.buffer.getCharacter(1, 2), equals('3'));
        expect(terminal.buffer.getCharacter(0, 3), equals(' '));
        expect(terminal.buffer.getBackground(0, 3), equals(green));
        expect(terminal.buffer.getCharacter(0, 4), equals('B'));

        // RI (ESC M) at top of scroll region (row 1) shifts rows 1..3 down while preserving TOP and BOT.
        terminal.write(utf8.encode('\x1b[2;1H\x1bMNEW1'));
        expect(terminal.buffer.getCharacter(0, 0), equals('T'));
        expect(terminal.buffer.getCharacter(0, 1), equals('N'));
        expect(terminal.buffer.getCharacter(1, 2), equals('2'));
        expect(terminal.buffer.getCharacter(1, 3), equals('3'));
        expect(terminal.buffer.getCharacter(0, 4), equals('B'));

        // IL (CSI L) and DL (CSI M) are ignored outside scroll region and shift within scroll region.
        terminal.write(utf8.encode('\x1b[1;1H\x1b[L\x1b[M'));
        expect(terminal.buffer.getCharacter(0, 0), equals('T'));
        terminal.write(utf8.encode('\x1b[3;1H\x1b[LINS\x1b[M'));
        expect(terminal.buffer.getCharacter(1, 2), equals('2'));

        // SU (CSI S), SD (CSI T), IND (ESC D), NEL (ESC E), CNL (CSI E), CPL (CSI F), HPA (`), SCOSC/SCORC (s/u).
        terminal.write(
          utf8.encode('\x1b[S\x1b[T\x1b[2;3H\x1b[s\x1bE\x1bD\x1b[u'),
        );
        expect(terminal.cursorX, equals(2));
        expect(terminal.cursorY, equals(1));
        terminal.write(utf8.encode('\x1b[1E\x1b[1F\x1b[4`'));
        expect(terminal.cursorX, equals(3));
        expect(terminal.cursorY, equals(1));
        // RI (ESC M) below scrollTop steps cursorY up without scrolling.
        terminal.write(utf8.encode('\x1b[3;2H\x1bM'));
        expect(terminal.cursorY, equals(1));
        terminal.write(utf8.encode('\x1b[1C'));
        expect(terminal.cursorX, equals(2));

        // Reset scroll margins (\x1b[r), then test ICH (CSI @) and DCH (CSI P) with wide-grapheme healing.
        terminal.write(utf8.encode('\x1b[r\x1b[2JABCDEF\x1b[1;3H\x1b[2@12'));
        final row0AfterIch = [
          for (var x = 0; x < 6; x++) terminal.buffer.getCharacter(x, 0),
        ].join();
        expect(row0AfterIch, equals('AB12CD'));

        terminal.write(utf8.encode('\x1b[1;3H\x1b[2P'));
        final row0AfterDch = [
          for (var x = 0; x < 6; x++) terminal.buffer.getCharacter(x, 0),
        ].join();
        expect(row0AfterDch, equals('ABCD  '));

        // ICH shifts a wide emoji intact when it fits, then heals the orphaned
        // leading half when a second ICH pushes its trailing cell off the right edge.
        terminal.write(utf8.encode('\x1b[2;4H🚀\x1b[2;1H\x1b[1@'));
        expect(terminal.buffer.getCharacter(4, 1), equals('🚀'));
        expect(terminal.buffer.getCharacter(5, 1), equals(''));
        terminal.write(utf8.encode('\x1b[2;1H\x1b[1@'));
        expect(terminal.buffer.getCharacter(5, 1), equals(' '));
        // ICH and DCH starting directly on a wide emoji's trailing cell heal the leading half.
        terminal.write(utf8.encode('\x1b[2;2H🚀Z\x1b[2;3H\x1b[1@'));
        expect(terminal.buffer.getCharacter(1, 1), equals(' '));
        terminal.write(utf8.encode('\x1b[2;2H🚀Z\x1b[2;3H\x1b[1P'));
        expect(terminal.buffer.getCharacter(1, 1), equals(' '));
        expect(terminal.buffer.getCharacter(2, 1), equals('Z'));
        // DCH splitting the leading half of a wide emoji heals the trailing half.
        terminal.write(utf8.encode('\x1b[2;2H🚀Z\x1b[2;2H\x1b[1P'));
        expect(terminal.buffer.getCharacter(1, 1), equals(' '));
        expect(terminal.buffer.getCharacter(2, 1), equals('Z'));
      },
    );

    test(
      'handles DECAWM (?7h / ?7l), clears pending wrap on cursor moves and controls, and wraps wide graphemes at right margin',
      () {
        final terminal = VirtualTerminal(width: 4, height: 3);
        expect(terminal.autoWrapMode, isTrue);

        // Pending wrap after 4 chars on row 1, then CSI A (Cursor Up) must clear pending wrap
        // and print at (3, 0) instead of wrapping back down to row 1!
        terminal.write(utf8.encode('\x1b[2;1HABCD'));
        expect(terminal.cursorX, equals(4));
        terminal.write(utf8.encode('\x1b[1AX'));
        expect(terminal.cursorX, equals(4));
        expect(terminal.cursorY, equals(0));
        expect(terminal.buffer.getCharacter(3, 0), equals('X'));
        expect(terminal.buffer.getCharacter(0, 1), equals('A'));

        // CUB (CSI D) and BS (\b) from pending wrap step left from width - 1 (col 3 -> col 2).
        terminal.write(utf8.encode('\x1b[2;1HABCD\x1b[1DY'));
        expect(terminal.buffer.getCharacter(2, 1), equals('Y'));
        terminal.write(utf8.encode('\x1b[2;1HABCD\bZ'));
        expect(terminal.buffer.getCharacter(2, 1), equals('Z'));

        // Raw LF (\n without \r) from pending wrap moves down once to (3, 2) without double-wrapping.
        terminal.write(utf8.encode('\x1b[2;1HABCD\nW'));
        expect(terminal.buffer.getCharacter(3, 2), equals('W'));

        // Wide grapheme at col width - 1 wraps cleanly to col 0 of next row when autoWrapMode is true.
        terminal.write(utf8.encode('\x1b[2J\x1b[1;4H🚀'));
        expect(terminal.buffer.getCharacter(3, 0), equals(' '));
        expect(terminal.buffer.getCharacter(0, 1), equals('🚀'));
        expect(terminal.buffer.getCharacter(1, 1), equals(''));

        // DECAWM off (\x1b[?7l) clamps at right margin and overwrites last column in place without wrapping.
        terminal.write(utf8.encode('\x1b[2J\x1b[1;1H\x1b[?7lABCDEF'));
        expect(terminal.autoWrapMode, isFalse);
        expect(terminal.cursorX, equals(3));
        expect(terminal.cursorY, equals(0));
        expect(terminal.buffer.getCharacter(0, 0), equals('A'));
        expect(terminal.buffer.getCharacter(2, 0), equals('C'));
        expect(terminal.buffer.getCharacter(3, 0), equals('F'));
        expect(terminal.buffer.getCharacter(0, 1), equals(' '));

        // Wide grapheme at right margin with DECAWM off writes space in last column without wrapping.
        terminal.write(utf8.encode('🚀'));
        expect(terminal.cursorY, equals(0));
        expect(terminal.buffer.getCharacter(3, 0), equals(' '));
        expect(terminal.buffer.getCharacter(0, 1), equals(' '));
      },
    );

    test(
      'supports extended SGR (256-color, truecolor, modifiers, bright palette), transparentBackground, codeUnits, OSC, and dispose',
      () {
        final terminal = VirtualTerminal(
          width: 8,
          height: 2,
          transparentBackground: true,
          defaultForeground: const Color(0x11, 0x22, 0x33),
        );
        var notified = 0;
        void listener() => notified++;
        terminal.addListener(listener);

        // Transparent space + defaultForeground + 256-color (basic, cube, grayscale) + 24-bit RGB + modifiers + bright palette.
        terminal.write(
          utf8.encode(
            '\x1b]0;title\x07 '
            '\x1b[38;5;2;48;5;196;2;3;4;5;7;8;9mA'
            '\x1b[22;23;24;25;27;28;29;38;5;240;48;2;10;20;30mB'
            '\x1b[38;2;40;50;60;91;104mC',
          ),
        );
        expect(
          terminal.buffer.getModifiers(0, 0) & Modifier.transparent,
          isNot(0),
        );
        expect(terminal.buffer.getForeground(0, 0), equals(0xFF112233));
        expect(terminal.buffer.getCharacter(1, 0), equals('A'));
        expect(
          terminal.buffer.getModifiers(1, 0),
          equals(
            Modifier.dim |
                Modifier.italic |
                Modifier.underlineSingle |
                Modifier.blink |
                Modifier.reverse |
                Modifier.hidden |
                Modifier.crossedOut,
          ),
        );
        expect(terminal.buffer.getModifiers(2, 0), equals(Modifier.none));
        expect(terminal.buffer.getBackground(2, 0), equals(0xFF0A141E));
        expect(terminal.buffer.getCharacter(3, 0), equals('C'));
        expect(
          terminal.buffer.getForeground(3, 0),
          equals(const Color(255, 85, 85).argb),
        );
        expect(
          terminal.buffer.getBackground(3, 0),
          equals(const Color(85, 85, 255).argb),
        );

        // Truncated or unknown extended SGR sequences consume sub-params without resetting active bold/fg.
        terminal.write(
          utf8.encode(
            '\x1b[2;1H\x1b[1;31m\x1b[38;2;10;0m\x1b[38;5m\x1b[38;9mD',
          ),
        );
        expect(terminal.buffer.getModifiers(0, 1), equals(Modifier.bold));
        expect(
          terminal.buffer.getForeground(0, 1),
          equals(const Color(170, 0, 0).argb),
        );

        // Decoded string via writeString and dispose() cleanup.
        terminal.writeString('🚀');
        expect(terminal.buffer.getCharacter(1, 1), equals('🚀'));
        expect(notified, equals(3));

        terminal.removeListener(listener);
        terminal.dispose();
      },
    );

    test(
      'tracks DECSET 2004 bracketed paste mode and resets on RIS/DECSTR',
      () {
        final terminal = VirtualTerminal(width: 20, height: 5);
        expect(terminal.bracketedPasteMode, isFalse);

        terminal.write(utf8.encode('\x1b[?2004h'));
        expect(terminal.bracketedPasteMode, isTrue);

        terminal.write(utf8.encode('\x1b[?2004l'));
        expect(terminal.bracketedPasteMode, isFalse);

        terminal.write(utf8.encode('\x1b[?2004h\x1b[!p'));
        expect(terminal.bracketedPasteMode, isFalse);

        terminal.write(utf8.encode('\x1b[?2004h'));
        terminal.reset();
        expect(terminal.bracketedPasteMode, isFalse);
      },
    );

    test(
      'decodes OSC 52 clipboard writes and reports blocked OSC 52 read queries',
      () {
        final terminal = VirtualTerminal(width: 20, height: 5);
        final writes = <(String, String)>[];
        final blockedReads = <String>[];
        terminal.onClipboardWrite = (selection, text) {
          writes.add((selection, text));
        };
        terminal.onClipboardReadBlocked = blockedReads.add;

        final b64Hello = base64.encode(utf8.encode('hello tmux 🚀'));
        terminal.write(utf8.encode('\x1b]52;c;$b64Hello\x07'));
        expect(writes, equals([('c', 'hello tmux 🚀')]));

        // Empty selection target defaults to 'c', and whitespace in base64 is stripped.
        final b64Split =
            '${b64Hello.substring(0, 4)}\n${b64Hello.substring(4)}';
        terminal.write(utf8.encode('\x1b]52;;$b64Split\x1b\\'));
        expect(
          writes,
          equals([('c', 'hello tmux 🚀'), ('c', 'hello tmux 🚀')]),
        );

        // Read queries ('?') are blocked and reported to onClipboardReadBlocked.
        terminal.write(utf8.encode('\x1b]52;c;?\x07'));
        terminal.write(utf8.encode('\x1b]52;p; ? \x1b\\'));
        expect(blockedReads, equals(['c', 'p']));
        expect(writes, hasLength(2));

        // Malformed base64 or unrelated OSC commands are ignored safely.
        terminal.write(utf8.encode('\x1b]52;c;!!!not-base64!!!\x07'));
        terminal.write(utf8.encode('\x1b]0;window title\x07'));
        expect(writes, hasLength(2));
        expect(blockedReads, hasLength(2));

        // Unpadded base64 OSC 52 payload ('aGk' -> 'hi') is accepted.
        terminal.write(utf8.encode('\x1b]52;c;aGk\x07'));
        expect(writes.last, equals(('c', 'hi')));

        // tmux DCS passthrough (\x1bPtmux;\x1b\x1b]52;...) dispatches OSC 52
        // without printing literal "tmux;" into the terminal screen buffer.
        terminal.write(
          utf8.encode('\x1bPtmux;\x1b\x1b]52;c;$b64Hello\x07\x1b\\'),
        );
        terminal.write(
          utf8.encode('\x1bPtmux;\x1b\x1b]52;p;$b64Hello\x1b\x1b\\\x1b\\'),
        );
        expect(writes.sublist(writes.length - 2), [
          ('c', 'hello tmux 🚀'),
          ('p', 'hello tmux 🚀'),
        ]);
        expect(terminal.cursorX, equals(0));
        expect(terminal.cursorY, equals(0));
        expect(terminal.buffer.getCharacter(0, 0), equals(' '));
      },
    );

    test('handles OSC CAN/SUB aborts, >1.4M OSC overflow, and 1 MiB OSC 52 bounds', () {
      final terminal = VirtualTerminal(width: 20, height: 5);
      final writes = <(String, String)>[];
      terminal.onClipboardWrite = (selection, text) {
        writes.add((selection, text));
      };

      // CAN (0x18) and SUB (0x1A) abort OSC without dispatching and resume ground text.
      terminal.write(utf8.encode('\x1b]52;c;aGk=\x18OK'));
      terminal.write(utf8.encode('\x1b]52;c;aGk=\x1a!'));
      expect(writes, isEmpty);
      expect(terminal.buffer.getCharacter(0, 0), equals('O'));
      expect(terminal.buffer.getCharacter(1, 0), equals('K'));
      expect(terminal.buffer.getCharacter(2, 0), equals('!'));

      // > 96 KiB up to exact 1 MiB (1,048,576 bytes) OSC 52 write succeeds.
      final oneMiBText = 'A' * 1048576;
      final oneMiBB64 = base64.encode(utf8.encode(oneMiBText));
      terminal.write(utf8.encode('\x1b]52;c;$oneMiBB64\x07'));
      expect(writes, hasLength(1));
      expect(writes.single.$2.length, equals(1048576));

      // > 1 MiB decoded bytes (1,048,577 bytes, base64 len 1,398,104 <= 1.4M) is rejected.
      writes.clear();
      final overOneMiBB64 = base64.encode(List<int>.filled(1048577, 0x41));
      terminal.write(utf8.encode('\x1b]52;c;$overOneMiBB64\x07'));
      expect(writes, isEmpty);

      // Malformed UTF-8 bytes whose U+FFFD expansion exceeds 1 MiB UTF-8 is rejected.
      final malformedExpansionB64 = base64.encode(
        List<int>.filled(500000, 0xFF),
      );
      terminal.write(utf8.encode('\x1b]52;c;$malformedExpansionB64\x07'));
      expect(writes, isEmpty);

      // > 1.4M OSC sequence overflows safely without crash or dispatch, then recovers.
      final giantOsc = '\x1b]52;c;${'A' * 1450000}\x07After';
      terminal.write(utf8.encode(giantOsc));
      expect(writes, isEmpty);
      expect(terminal.buffer.getCharacter(3, 0), equals('A'));
      expect(terminal.buffer.getCharacter(7, 0), equals('r'));

      terminal.write(utf8.encode('\x1b]52;c;aGk=\x07'));
      expect(writes, equals([('c', 'hi')]));
    });

    test(
      'ignores DEL (0x7F) and C1 control code units in ground state without polluting Buffer',
      () {
        final terminal = VirtualTerminal(width: 4, height: 2);
        terminal.write(utf8.encode('A\x7fB'));
        terminal.printText('\x80\x85\x9b\x9fC');

        expect(terminal.buffer.getCharacter(0, 0), equals('A'));
        expect(terminal.buffer.getCharacter(1, 0), equals('B'));
        expect(terminal.buffer.getCharacter(2, 0), equals('C'));
        expect(terminal.cursorX, equals(3));

        // DEL at pending-wrap margin must not wrap to next row.
        terminal.write(utf8.encode('D\x7f'));
        expect(terminal.cursorX, equals(4));
        expect(terminal.cursorY, equals(0));
      },
    );

    test(
      'consumes SGR 58/59 underline color without corrupting foreground, background, or modifiers',
      () {
        const banner = "Love Jetski CLI? We're hiring SWEs!";
        final terminal = VirtualTerminal(width: 40, height: 2);
        final payload = StringBuffer();
        final expectedFg = <int>[];
        for (var i = 0; i < banner.length; i++) {
          final r = (66 + (242 - 66) * i / (banner.length - 1)).round();
          final g = (133 + (82 - 133) * i / (banner.length - 1)).round();
          final b = (244 + (90 - 244) * i / (banner.length - 1)).round();
          expectedFg.add(Color(r, g, b).argb);
          payload.write('\x1b[4;38;2;$r;$g;$b;58;2;$r;$g;${b}m${banner[i]}');
        }
        payload.write('\x1b[59;24;39m\r\n\x1b[38;5;196;58;5;103mX\x1b[0m');
        terminal.write(utf8.encode('$payload'));

        for (var i = 0; i < banner.length; i++) {
          expect(
            terminal.buffer.getCharacter(i, 0),
            equals(banner[i]),
            reason: 'char at column $i',
          );
          expect(
            terminal.buffer.getForeground(i, 0),
            equals(expectedFg[i]),
            reason: 'foreground at column $i (${banner[i]})',
          );
          expect(
            terminal.buffer.getBackground(i, 0),
            equals(0),
            reason: 'background at column $i (${banner[i]})',
          );
          expect(
            terminal.buffer.getModifiers(i, 0),
            equals(Modifier.underlineSingle),
            reason: 'modifiers at column $i (${banner[i]})',
          );
        }

        // SGR 58;5;103 must not leak 5 (blink) or 103 (bright yellow bg).
        expect(terminal.buffer.getCharacter(0, 1), equals('X'));
        expect(
          terminal.buffer.getForeground(0, 1),
          equals(const Color(255, 0, 0).argb),
        );
        expect(terminal.buffer.getBackground(0, 1), equals(0));
        expect(terminal.buffer.getModifiers(0, 1), equals(Modifier.none));

        // Truncated/unknown semicolon 58 forms must not leak modifiers or swallow tail codes.
        terminal.write(
          utf8.encode(
            '\x1b[0;58m\x1b[58;5m\x1b[58;2;4m\x1b[58;2;10;31m\x1b[58;9;31mY',
          ),
        );
        expect(terminal.buffer.getCharacter(1, 1), equals('Y'));
        expect(
          terminal.buffer.getForeground(1, 1),
          equals(const Color(170, 0, 0).argb),
        );
        expect(terminal.buffer.getModifiers(1, 1), equals(Modifier.none));
      },
    );

    test(
      'parses ITU-T T.416 colon-delimited SGR subparameters for extended colors and styled underlines',
      () {
        final terminal = VirtualTerminal(width: 12, height: 2);

        // 4:3 (curly underline), 38:2::r:g:b::tol:cs (tolerance form),
        // 48:2:r:g:b (4-part RGB), and 58:2::r:g:b (underline RGB ignored cleanly).
        terminal.write(
          utf8.encode(
            '\x1b[4:3;38:2::66:133:244::50:0;48:2:10:20:30;58:2::92:103:100mA',
          ),
        );
        expect(
          terminal.buffer.getForeground(0, 0),
          equals(const Color(66, 133, 244).argb),
        );
        expect(
          terminal.buffer.getBackground(0, 0),
          equals(const Color(10, 20, 30).argb),
        );
        expect(
          terminal.buffer.getModifiers(0, 0),
          equals(Modifier.underlineCurly),
        );

        // 38:5:n, 48:5:n, 58:5:n, and 4:0 (underline off).
        terminal.write(utf8.encode('\x1b[38:5:196;48:5:46;58:5:103;4:0mB'));
        expect(
          terminal.buffer.getForeground(1, 0),
          equals(const Color(255, 0, 0).argb),
        );
        expect(
          terminal.buffer.getBackground(1, 0),
          equals(const Color(0, 255, 0).argb),
        );
        expect(terminal.buffer.getModifiers(1, 0), equals(Modifier.none));

        // Non-SGR and DEC private CSI with colons are ignored without flipping modes or erasing.
        terminal.write(
          utf8.encode(
            '\x1b[0m\x1b[>4:2m\x1b[?1049:1h\x1b[?25:0l\x1b[2:0J'
            '\x1b[1;4:1;38;2;12;34;56;58:2::97:107:100mC',
          ),
        );
        expect(terminal.isUsingAlternateScreen, isFalse);
        expect(terminal.cursorVisible, isTrue);
        expect(terminal.buffer.getCharacter(0, 0), equals('A'));
        expect(
          terminal.buffer.getForeground(2, 0),
          equals(const Color(12, 34, 56).argb),
        );
        expect(terminal.buffer.getBackground(2, 0), equals(0));
        expect(
          terminal.buffer.getModifiers(2, 0),
          equals(Modifier.bold | Modifier.underlineSingle),
        );

        // Mixed `;`/`:` lookahead boundaries, trailing `;` reset, negative subparam,
        // out-of-range `4:6`, trailing-colon `4:`, and short colon colors.
        terminal.write(utf8.encode('\x1b[0;38;2;10;20;4:3mD'));
        expect(terminal.buffer.getForeground(3, 0), equals(0));
        expect(
          terminal.buffer.getModifiers(3, 0),
          equals(Modifier.underlineCurly),
        );

        terminal.write(utf8.encode('\x1b[0;38;2:10:20:30;4;31;42mE'));
        expect(
          terminal.buffer.getForeground(4, 0),
          equals(const Color(170, 0, 0).argb),
        );
        expect(
          terminal.buffer.getBackground(4, 0),
          equals(const Color(0, 170, 0).argb),
        );
        expect(
          terminal.buffer.getModifiers(4, 0),
          equals(Modifier.underlineSingle),
        );

        terminal.write(utf8.encode('\x1b[4:3;mF'));
        expect(terminal.buffer.getModifiers(5, 0), equals(Modifier.none));

        terminal.csi(
          'm',
          [4],
          subparams: [
            [-1],
          ],
        );
        expect(terminal.buffer.getModifiers(5, 0), equals(Modifier.none));
        terminal.write(
          utf8.encode(
            'G\x1b[4m\x1b[4:6mH\x1b[4:m\x1b[1:2;4:6;38:2:10:20;38:5;38:9:10;32mI',
          ),
        );
        expect(terminal.buffer.getModifiers(6, 0), equals(Modifier.none));
        expect(
          terminal.buffer.getModifiers(7, 0),
          equals(Modifier.underlineSingle),
        );
        expect(terminal.buffer.getModifiers(8, 0), equals(Modifier.none));
        expect(
          terminal.buffer.getForeground(8, 0),
          equals(const Color(0, 170, 0).argb),
        );
      },
    );

    test(
      'handles CBT (CSI Z) and CHT (CSI I) without prompt-selection wrap corruption',
      () {
        final terminal = VirtualTerminal(width: 191, height: 3);
        const prompt =
            '> /tmp/termui_cast_uploads_AMSNOH/cast-1793982141855523/assign-rfc-number.yml ';
        final border = '─' * 191;

        terminal.write(
          utf8.encode(
            '\x1b[1;1H$border\x1b[2;1H$prompt\x1b[3;1H$border'
            '\x1b[1;73H\x1b[48;2;138;180;248m${'─' * 119}\x1b[0m\x1b[2;79H'
            '\x1bM\x1b[Z${'─' * 119}\r\n$prompt'
            '\x1b[Z\x1b[48;2;138;180;248mr.ym\x1b[0ml\b\b\b\b\b',
          ),
        );

        for (var x = 72; x < 78; x++) {
          expect(terminal.buffer.getCharacter(x, 0), equals('─'));
          expect(terminal.buffer.getBackground(x, 0), equals(0));
        }
        expect(
          [
            for (var x = 0; x < 5; x++) terminal.buffer.getCharacter(x, 1),
          ].join(),
          equals('> /tm'),
        );
        expect(
          [
            for (var x = 72; x < 77; x++) terminal.buffer.getCharacter(x, 1),
          ].join(),
          equals('r.yml'),
        );
        expect(terminal.buffer.getCharacter(78, 1), equals(' '));
        expect((terminal.cursorX, terminal.cursorY), equals((72, 1)));
        expect(terminal.buffer.getCharacter(0, 2), equals('─'));

        terminal.write(utf8.encode('\x1b[2J\x1b[1;1H\x1b[3IX\x1b[3ZY'));
        expect(terminal.buffer.getCharacter(24, 0), equals('X'));
        expect(terminal.buffer.getCharacter(8, 0), equals('Y'));
      },
    );

    test(
      'handles REP (CSI b) repeat preceding graphic character and clears on reset',
      () {
        final terminal = VirtualTerminal(width: 8, height: 1);
        terminal.write(utf8.encode('\x1b[3bY\x1b[4b\x1b[!p\x1b[2b'));
        expect(
          [
            for (var x = 0; x < 6; x++) terminal.buffer.getCharacter(x, 0),
          ].join(),
          equals('YYYYY '),
        );
        expect(terminal.cursorX, equals(5));
      },
    );

    test(
      'resets cursorX on IL/DL, guards multi-param CSI T and CSI u, and supports HPR/VPR (CSI a/e)',
      () {
        final terminal = VirtualTerminal(width: 8, height: 4);
        terminal.write(utf8.encode('R0_TEXT\r\nR1_TEXT\r\nR2_TEXT\r\nR3_TEXT'));

        // IL (CSI L) and DL (CSI M) inside scroll region reset cursorX to 0.
        terminal.write(utf8.encode('\x1b[2;5H\x1b[L'));
        expect((terminal.cursorX, terminal.cursorY), equals((0, 1)));
        terminal.write(utf8.encode('\x1b[2;6H\x1b[M'));
        expect((terminal.cursorX, terminal.cursorY), equals((0, 1)));

        // Outside scroll region, IL/DL are ignored and preserve cursorX.
        terminal.write(utf8.encode('\x1b[2;4r\x1b[1;5H\x1b[L\x1b[M'));
        expect((terminal.cursorX, terminal.cursorY), equals((4, 0)));
        terminal.write(utf8.encode('\x1b[r'));

        // 5-param xterm mouse highlight initiate (CSI Ps;Ps;Ps;Ps;Ps T) must not scroll down.
        expect(terminal.buffer.getCharacter(0, 0), equals('R'));
        terminal.write(utf8.encode('\x1b[1;1;1;1;1T'));
        expect(terminal.buffer.getCharacter(0, 0), equals('R'));

        // Parameterized CSI 1 u and private CSI > 1 u must not restore saved cursor.
        terminal.write(utf8.encode('\x1b[1;2H\x1b[s\x1b[3;6H\x1b[1u\x1b[>1u'));
        expect((terminal.cursorX, terminal.cursorY), equals((5, 2)));
        terminal.write(utf8.encode('\x1b[u'));
        expect((terminal.cursorX, terminal.cursorY), equals((1, 0)));

        // HPR (CSI a) and VPR (CSI e) advance cursorX and cursorY with bounds clamping.
        terminal.write(utf8.encode('\x1b[1;1H\x1b[3a\x1b[2e'));
        expect((terminal.cursorX, terminal.cursorY), equals((3, 2)));
        terminal.write(utf8.encode('\x1b[99a\x1b[99e'));
        expect((terminal.cursorX, terminal.cursorY), equals((7, 3)));
      },
    );

    test(
      'supports SGR 6 (rapid blink), SGR 21 (double underline), and DECSED/DECSEL (CSI ? J / CSI ? K)',
      () {
        final terminal = VirtualTerminal(width: 6, height: 2);
        terminal.write(utf8.encode('\x1b[6;21mA\x1b[25mB\x1b[24mC'));
        expect(
          terminal.buffer.getModifiers(0, 0),
          equals(Modifier.blink | Modifier.underlineDouble),
        );
        expect(
          terminal.buffer.getModifiers(1, 0),
          equals(Modifier.underlineDouble),
        );
        expect(terminal.buffer.getModifiers(2, 0), equals(Modifier.none));

        // DECSEL (CSI ? K) and DECSED (CSI ? J) erase line and display spans.
        terminal.write(utf8.encode('\x1b[1;1HABCDEF\r\nUVWXYZ'));
        terminal.write(utf8.encode('\x1b[1;4H\x1b[?K'));
        expect(
          [
            for (var x = 0; x < 6; x++) terminal.buffer.getCharacter(x, 0),
          ].join(),
          equals('ABC   '),
        );
        terminal.write(utf8.encode('\x1b[?2J'));
        expect(terminal.buffer.getCharacter(0, 0), equals(' '));
        expect(terminal.buffer.getCharacter(0, 1), equals(' '));
      },
    );

    test(
      'supports ANSI IRM insert/replace mode (CSI 4 h / CSI 4 l) for single-width and wide graphemes',
      () {
        final terminal = VirtualTerminal(width: 8, height: 2);
        expect(terminal.insertMode, isFalse);

        terminal.write(utf8.encode('abcdef\x1b[1;1H\x1b[4hXY\x1b[4lZ'));
        expect(terminal.insertMode, isFalse);
        expect(
          [
            for (var x = 0; x < 8; x++) terminal.buffer.getCharacter(x, 0),
          ].join(),
          equals('XYZbcdef'),
        );

        // Wide grapheme insertion shifts row by 2 cells, and RIS / DECSTR reset insertMode.
        terminal.write(utf8.encode('\x1b[2;1H123456\x1b[2;2H\x1b[4h🚀'));
        expect(terminal.insertMode, isTrue);
        expect(terminal.buffer.getCharacter(0, 1), equals('1'));
        expect(terminal.buffer.getCharacter(1, 1), equals('🚀'));
        expect(terminal.buffer.getCharacter(3, 1), equals('2'));
        expect(terminal.buffer.getCharacter(7, 1), equals('6'));

        terminal.write(utf8.encode('\x1b[!p'));
        expect(terminal.insertMode, isFalse);
        terminal.write(utf8.encode('\x1b[4h\x1bc'));
        expect(terminal.insertMode, isFalse);
      },
    );

    test(
      'clamps CUU/CUD/CNL/CPL at DECSTBM margins and supports DECOM (?6h / ?6l) origin mode',
      () {
        final terminal = VirtualTerminal(width: 8, height: 6);
        expect(terminal.originMode, isFalse);

        // Set scroll region rows 3..4 (0-indexed 2..3).
        terminal.write(utf8.encode('\x1b[3;4r'));
        expect((terminal.cursorX, terminal.cursorY), equals((0, 0)));

        // Starting inside scroll region (row 2), CUU/CPL stop at _scrollTop (2) and CUD/CNL stop at _scrollBottom (3).
        terminal.write(utf8.encode('\x1b[3;3H\x1b[5A'));
        expect((terminal.cursorX, terminal.cursorY), equals((2, 2)));
        terminal.write(utf8.encode('\x1b[5B'));
        expect((terminal.cursorX, terminal.cursorY), equals((2, 3)));
        terminal.write(utf8.encode('\x1b[5F'));
        expect((terminal.cursorX, terminal.cursorY), equals((0, 2)));
        terminal.write(utf8.encode('\x1b[5E'));
        expect((terminal.cursorX, terminal.cursorY), equals((0, 3)));

        // Starting outside scroll region, CUU from above (row 1) reaches 0 and CUD from below (row 4) reaches height - 1 (5).
        terminal.write(utf8.encode('\x1b[2;1H\x1b[5A'));
        expect(terminal.cursorY, equals(0));
        terminal.write(utf8.encode('\x1b[5;1H\x1b[5B'));
        expect(terminal.cursorY, equals(5));

        // DECOM (?6h) homes cursor to (0, _scrollTop) and offsets/clamps CUP, HVP, VPA, and DECSTBM.
        terminal.write(utf8.encode('\x1b[?6h'));
        expect(terminal.originMode, isTrue);
        expect((terminal.cursorX, terminal.cursorY), equals((0, 2)));

        terminal.write(utf8.encode('\x1b[2;4H'));
        expect((terminal.cursorX, terminal.cursorY), equals((3, 3)));
        terminal.write(utf8.encode('\x1b[99;99f'));
        expect((terminal.cursorX, terminal.cursorY), equals((7, 3)));
        terminal.write(utf8.encode('\x1b[1d'));
        expect(terminal.cursorY, equals(2));
        terminal.write(utf8.encode('\x1b[99d'));
        expect(terminal.cursorY, equals(3));

        // DECSC / DECRC saves and restores originMode, and ?6l homes to (0, 0).
        terminal.write(utf8.encode('\x1b7\x1b[?6l'));
        expect(terminal.originMode, isFalse);
        expect((terminal.cursorX, terminal.cursorY), equals((0, 0)));
        terminal.write(utf8.encode('\x1b8'));
        expect(terminal.originMode, isTrue);
        expect((terminal.cursorX, terminal.cursorY), equals((7, 3)));

        // Changing DECSTBM while DECOM is active homes to new _scrollTop.
        terminal.write(utf8.encode('\x1b[2;5r'));
        expect((terminal.cursorX, terminal.cursorY), equals((0, 1)));

        // DECRC under DECOM clamps saved cursorY into narrowed _scrollTop.._scrollBottom.
        terminal.write(utf8.encode('\x1b7\x1b[3;4r\x1b8'));
        expect(terminal.originMode, isTrue);
        expect(terminal.cursorY, equals(2));

        terminal.write(utf8.encode('\x1b[!p'));
        expect(terminal.originMode, isFalse);
      },
    );

    test(
      'supports DEC Special Graphics line drawing via ESC ( 0 / ESC ) 0 and SO/SI (0x0E/0x0F)',
      () {
        final terminal = VirtualTerminal(width: 12, height: 2);

        // G0 DEC Special Graphics (\x1b(0) translates l, q, k, x, m, j and restores ASCII on \x1b(B.
        terminal.write(utf8.encode('\x1b(0lqqk\x1b(Blqqk'));
        expect(
          [
            for (var x = 0; x < 8; x++) terminal.buffer.getCharacter(x, 0),
          ].join(),
          equals('┌──┐lqqk'),
        );

        // G1 DEC Special Graphics (\x1b)0) activated by SO (\x0e) and deactivated by SI (\x0f).
        terminal.write(utf8.encode('\r\n\x1b)0\x0emjntuvwx`a~\x0fx'));
        expect(
          [
            for (var x = 0; x < 12; x++) terminal.buffer.getCharacter(x, 1),
          ].join(),
          equals('└┘┼├┤┴┬│◆▒·x'),
        );

        // DECSC / DECRC saves and restores charset state, and DECSTR / RIS reset to ASCII.
        terminal.write(
          utf8.encode('\x1b[1;1H\x1b(0\x1b7\x1b(Bq\x1b8\x1b[1;2Hq\x1b[!pq'),
        );
        expect(terminal.buffer.getCharacter(0, 0), equals('q'));
        expect(terminal.buffer.getCharacter(1, 0), equals('─'));
        expect(terminal.buffer.getCharacter(2, 0), equals('q'));

        // 0x5F (_) maps to blank under ESC ( 0, and REP (\x1b[b) does not re-translate prior ASCII.
        terminal.write(utf8.encode('\x1b[1;1H\x1b(0_\x1b(Bq\x1b(0\x1b[2b'));
        expect(
          [
            for (var x = 0; x < 4; x++) terminal.buffer.getCharacter(x, 0),
          ].join(),
          equals(' qqq'),
        );
      },
    );

    test(
      'tracks DECSET 2026 synchronizedOutput and DECSET 2027 graphemeClusterMode and resets on RIS/DECSTR',
      () {
        final terminal = VirtualTerminal(width: 8, height: 2);
        expect(terminal.synchronizedOutput, isFalse);
        expect(terminal.graphemeClusterMode, isFalse);

        terminal.write(utf8.encode('\x1b[?2026;2027h'));
        expect(terminal.synchronizedOutput, isTrue);
        expect(terminal.graphemeClusterMode, isTrue);

        terminal.write(utf8.encode('\x1b[?2026l'));
        expect(terminal.synchronizedOutput, isFalse);
        expect(terminal.graphemeClusterMode, isTrue);

        terminal.write(utf8.encode('\x1b[?2026h\x1b[!p'));
        expect(terminal.synchronizedOutput, isFalse);
        expect(terminal.graphemeClusterMode, isFalse);

        terminal.write(utf8.encode('\x1b[?2026;2027h\x1bc'));
        expect(terminal.synchronizedOutput, isFalse);
        expect(terminal.graphemeClusterMode, isFalse);

        terminal.write(utf8.encode('\x1b[?2026h'));
        expect(terminal.synchronizedOutput, isTrue);
        terminal.synchronizedOutput = false;
        expect(terminal.synchronizedOutput, isFalse);
      },
    );

    test(
      'emits onReply responses for DSR (5n), CPR (6n/?6n), DA1, DA2, DECRQM, and XTWINOPS (18t)',
      () {
        final replies = <String>[];
        final terminal = VirtualTerminal(
          width: 80,
          height: 24,
          onReply: replies.add,
        );

        // DSR 5n, CPR 6n, DECXCPR ?6n (including clamping at right-margin pending wrap).
        terminal.write(
          utf8.encode('\x1b[5n\x1b[3;10H\x1b[6n\x1b[?6n\x1b[1;80HZ\x1b[6n'),
        );
        expect(
          replies,
          equals(['\x1b[0n', '\x1b[3;10R', '\x1b[?3;10;1R', '\x1b[1;80R']),
        );

        // CPR in DECOM (?6h) reports row relative to _scrollTop.
        replies.clear();
        terminal.write(
          utf8.encode('\x1b[5;20r\x1b[?6h\x1b[2;4H\x1b[6n\x1b[?6n'),
        );
        expect(replies, equals(['\x1b[2;4R', '\x1b[?2;4;1R']));
        terminal.write(utf8.encode('\x1b[?6l\x1b[r'));

        // DA1 (CSI c / CSI 0 c), DA2 (CSI > c / CSI > 0 c), and XTWINOPS 18t.
        replies.clear();
        terminal.write(utf8.encode('\x1b[c\x1b[0c\x1b[>c\x1b[>0c\x1b[18t'));
        expect(
          replies,
          equals([
            '\x1b[?62;22c',
            '\x1b[?62;22c',
            '\x1b[>1;10;0c',
            '\x1b[>1;10;0c',
            '\x1b[8;24;80t',
          ]),
        );

        // DECRQM for DEC private modes (?2026$p, ?2027$p, ?9999$p) and ANSI mode (4$p, 99$p).
        replies.clear();
        terminal.write(
          utf8.encode(
            '\x1b[?2026\$p\x1b[?2026h\x1b[?2026\$p\x1b[?2027\$p\x1b[?9999\$p'
            '\x1b[4\$p\x1b[4h\x1b[4\$p\x1b[99\$p',
          ),
        );
        expect(
          replies,
          equals([
            '\x1b[?2026;2\$y',
            '\x1b[?2026;1\$y',
            '\x1b[?2027;2\$y',
            '\x1b[?9999;0\$y',
            '\x1b[4;2\$y',
            '\x1b[4;1\$y',
            '\x1b[99;0\$y',
          ]),
        );
      },
    );

    test(
      'supports custom tab stops via HTS (ESC H), TBC (CSI 0/3 g), and DECST8C (CSI ? 5 W)',
      () {
        final terminal = VirtualTerminal(width: 24, height: 2);

        // Clear all tab stops (CSI 3 g), set custom stops at cols 3 and 10 (ESC H).
        terminal.write(utf8.encode('\x1b[3g\x1b[1;4H\x1bH\x1b[1;11H\x1bH'));
        terminal.write(utf8.encode('\r\t'));
        expect(terminal.cursorX, equals(3));
        terminal.write(utf8.encode('\t'));
        expect(terminal.cursorX, equals(10));
        terminal.write(utf8.encode('\t'));
        expect(terminal.cursorX, equals(23));

        // CBT (CSI Z) and CHT (CSI I) step through custom tab stops.
        terminal.write(utf8.encode('\x1b[2Z'));
        expect(terminal.cursorX, equals(3));
        terminal.write(utf8.encode('\x1b[1I'));
        expect(terminal.cursorX, equals(10));

        // TBC (CSI 0 g / CSI g) clears only the tab stop at cursorX (10).
        terminal.write(utf8.encode('\x1b[0g\r\t\t'));
        expect(terminal.cursorX, equals(23));

        // DECSTR (CSI ! p) preserves custom tab stops, while RIS (ESC c) and DECST8C (CSI ? 5 W) restore 8-column stops.
        terminal.write(utf8.encode('\x1b[!p\r\t'));
        expect(terminal.cursorX, equals(3));
        terminal.write(utf8.encode('\x1bc\r\t'));
        expect(terminal.cursorX, equals(8));
        terminal.write(utf8.encode('\x1b[3g\x1b[?5W\r\t'));
        expect(terminal.cursorX, equals(8));
        terminal.write(utf8.encode('\t'));
        expect(terminal.cursorX, equals(16));
      },
    );

    test(
      'tracks independent mouse modes (?9/?1000/?1002/?1003), focus reporting (?1004), and DECSCUSR (CSI Ps SP q)',
      () {
        final replies = <String>[];
        final terminal = VirtualTerminal(
          width: 8,
          height: 2,
          onReply: replies.add,
        );

        // Enabling ?1000h and ?1003h then disabling ?1003l keeps mouseTrackingEnabled true until ?1000l.
        terminal.write(utf8.encode('\x1b[?1000h\x1b[?1003h\x1b[?1003l'));
        expect(terminal.mouseTrackingEnabled, isTrue);
        terminal.write(utf8.encode('\x1b[?1000\$p\x1b[?1003\$p'));
        expect(replies, equals(['\x1b[?1000;1\$y', '\x1b[?1003;2\$y']));
        terminal.write(utf8.encode('\x1b[?1000l'));
        expect(terminal.mouseTrackingEnabled, isFalse);

        // ?9h X10 mouse mode is also tracked in bitmask, and setting mouseTrackingEnabled = true preserves active bits.
        terminal.write(utf8.encode('\x1b[?9h\x1b[?1003h'));
        terminal.mouseTrackingEnabled = true;
        expect(terminal.mouseTrackingEnabled, isTrue);
        replies.clear();
        terminal.write(utf8.encode('\x1b[?1003\$p'));
        expect(replies, equals(['\x1b[?1003;1\$y']));

        // DECSET 1004 focus reporting and InputEncoder.encodeFocus.
        expect(terminal.focusReportingEnabled, isFalse);
        terminal.write(utf8.encode('\x1b[?1004h'));
        expect(terminal.focusReportingEnabled, isTrue);
        replies.clear();
        terminal.write(utf8.encode('\x1b[?1004\$p'));
        expect(replies, equals(['\x1b[?1004;1\$y']));
        terminal.write(utf8.encode('\x1b[?1004l'));
        expect(terminal.focusReportingEnabled, isFalse);
        expect(InputEncoder.encodeFocus(focused: true), equals('\x1b[I'));
        expect(InputEncoder.encodeFocus(focused: false), equals('\x1b[O'));

        // DECSCUSR (CSI Ps SP q) updates cursorShape and resets on DECSTR / RIS.
        expect(terminal.cursorShape, equals(TerminalCursorShape.defaultShape));
        terminal.write(utf8.encode('\x1b[5 q'));
        expect(terminal.cursorShape, equals(TerminalCursorShape.blinkingBar));
        terminal.write(utf8.encode('\x1b[2 q'));
        expect(terminal.cursorShape, equals(TerminalCursorShape.steadyBlock));
        terminal.write(utf8.encode('\x1b[ q'));
        expect(terminal.cursorShape, equals(TerminalCursorShape.defaultShape));
        terminal.write(utf8.encode('\x1b[6 q\x1b[!p'));
        expect(terminal.cursorShape, equals(TerminalCursorShape.defaultShape));
        expect(terminal.mouseTrackingEnabled, isFalse);
      },
    );
  });
}
