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
}
