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
                Modifier.underline |
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

        // Non-byte UTF-16 code units (> 0xFF) and dispose() cleanup.
        terminal.write('🚀'.codeUnits);
        expect(terminal.buffer.getCharacter(1, 1), equals('🚀'));
        expect(notified, equals(3));

        terminal.removeListener(listener);
        terminal.dispose();
      },
    );
  });
}
