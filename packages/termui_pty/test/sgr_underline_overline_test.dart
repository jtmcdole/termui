import 'dart:convert';
import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:test/test.dart';

void main() {
  group('VirtualTerminal SGR underline styles, overline, and underline color', () {
    test('parses SGR 4:0..5, 21, 24, 53, 55, 58, and 59 into Buffer', () {
      final vt = VirtualTerminal(width: 20, height: 2);

      // Curly underline (4:3), custom underline color (58:2::255:64:128), overline (53)
      vt.write(utf8.encode('\x1b[4:3;58:2::255:64:128;53mA'));
      // Double underline via SGR 21, semicolon underline color (58;2;0;200;100), overline off (55)
      vt.write(utf8.encode('\x1b[21;58;2;0;200;100;55mB'));
      // Reset underline color (59) and underline off (24)
      vt.write(utf8.encode('\x1b[59;24mC'));

      final modA = vt.buffer.getModifiers(0, 0);
      expect(Modifier.getUnderlineStyle(modA), UnderlineStyle.curly);
      expect(Modifier.has(modA, Modifier.overline), isTrue);
      expect(vt.buffer.getUnderlineColor(0, 0), const Color(255, 64, 128).argb);

      final modB = vt.buffer.getModifiers(1, 0);
      expect(Modifier.getUnderlineStyle(modB), UnderlineStyle.doubleLine);
      expect(Modifier.has(modB, Modifier.overline), isFalse);
      expect(vt.buffer.getUnderlineColor(1, 0), const Color(0, 200, 100).argb);

      final modC = vt.buffer.getModifiers(2, 0);
      expect(Modifier.getUnderlineStyle(modC), UnderlineStyle.none);
      expect(vt.buffer.getUnderlineColor(2, 0), 0);

      // OSC 8 hyperlink open and close
      vt.write(
        utf8.encode(
          '\x1b]8;;https://github.com/jtmcdole/termui\x1b\\D\x1b]8;;\x1b\\E',
        ),
      );
      expect(
        vt.buffer.getUri(3, 0),
        equals('https://github.com/jtmcdole/termui'),
      );
      expect(vt.buffer.getUri(4, 0), isNull);
    });

    test(
      'TerminalView preserves underlineColor and OSC 8 uri and VirtualTerminal clears/shifts them on erase and scroll',
      () {
        final vt = VirtualTerminal(width: 12, height: 3);
        vt.writeString(
          '\x1b[4:3;58:2::10:20:30m\x1b]8;;https://example.dev\x1b\\LINK\x1b]8;;\x1b\\\x1b[0m',
        );

        // Paint via TerminalView into an outer Buffer.
        final target = Buffer.blank(16, 5);
        final focus = FocusNode(id: 'tv');
        addTearDown(focus.dispose);
        final el = TerminalView(terminal: vt, focusNode: focus).createElement()
          ..mount(null);
        el.layout(const BoxConstraints(maxWidth: 12, maxHeight: 3));
        el.paint(target, const Offset(2, 1));

        expect(
          target.getUnderlineColor(2, 1),
          equals(const Color(10, 20, 30).argb),
        );
        expect(target.getUri(2, 1), equals('https://example.dev'));
        expect(target.getUri(6, 1), isNull);

        // Scroll up by 1 line (CSI S) shifts link from row 0 would evict, so place on row 1 first:
        vt.writeString(
          '\r\n\x1b[4:1;58:2::99:88:77m\x1b]8;;https://row1.dev\x1b\\ROW1\x1b]8;;\x1b\\\x1b[0m',
        );
        expect(vt.buffer.getUri(0, 1), equals('https://row1.dev'));
        vt.writeString('\x1b[1S'); // Scroll up 1 row
        expect(vt.buffer.getUri(0, 0), equals('https://row1.dev'));
        expect(
          vt.buffer.getUnderlineColor(0, 0),
          equals(const Color(99, 88, 77).argb),
        );
        // Newly exposed bottom row & shifted-from row have no ghost URI.
        expect(vt.buffer.getUri(0, 1), isNull);
        expect(vt.buffer.getUnderlineColor(0, 1), equals(0));
        expect(vt.buffer.getUri(0, 2), isNull);

        // Erase in line (CSI 2K) clears URI and underlineColor.
        vt.writeString('\x1b[1;1H\x1b[2K');
        expect(vt.buffer.getUri(0, 0), isNull);
        expect(vt.buffer.getUnderlineColor(0, 0), equals(0));

        // ICH (CSI 2@) shifts aux attributes right and clears newly inserted cells.
        vt.writeString(
          '\x1b[1;1H\x1b[4:3;58:2::44:55:66m\x1b]8;;https://ich.dev\x1b\\ABCD\x1b]8;;\x1b\\\x1b[0m',
        );
        vt.writeString(
          '\x1b[1;2H\x1b[2@',
        ); // Insert 2 blanks at col 1 (0-based)
        expect(vt.buffer.getCharacter(0, 0), equals('A'));
        expect(vt.buffer.getUri(0, 0), equals('https://ich.dev'));
        expect(vt.buffer.getUri(1, 0), isNull);
        expect(vt.buffer.getUnderlineColor(1, 0), equals(0));
        expect(vt.buffer.getUri(2, 0), isNull);
        expect(vt.buffer.getCharacter(3, 0), equals('B'));
        expect(vt.buffer.getUri(3, 0), equals('https://ich.dev'));
        expect(
          vt.buffer.getUnderlineColor(3, 0),
          equals(const Color(44, 55, 66).argb),
        );

        // DCH (CSI 2P) shifts aux attributes left and clears trailing cells.
        vt.writeString('\x1b[1;2H\x1b[2P');
        expect(vt.buffer.getCharacter(1, 0), equals('B'));
        expect(vt.buffer.getUri(1, 0), equals('https://ich.dev'));
        expect(vt.buffer.getUri(4, 0), isNull);
        expect(vt.buffer.getUnderlineColor(4, 0), equals(0));

        // Scroll down (CSI 1T) shifts row 0 -> row 1 and clears row 0 aux attributes.
        vt.writeString('\x1b[1T');
        expect(vt.buffer.getUri(0, 0), isNull);
        expect(vt.buffer.getUnderlineColor(0, 0), equals(0));
        expect(vt.buffer.getUri(0, 1), equals('https://ich.dev'));
        expect(
          vt.buffer.getUnderlineColor(0, 1),
          equals(const Color(44, 55, 66).argb),
        );

        // Erase in display (CSI 2J) and RIS (\x1bc) clear all aux attributes.
        vt.writeString('\x1b[2J');
        expect(vt.buffer.getUri(0, 1), isNull);
        expect(vt.buffer.getUnderlineColor(0, 1), equals(0));
        vt.writeString('\x1b]8;;https://ris.dev\x1b\\Z\x1bc');
        expect(vt.buffer.getUri(0, 0), isNull);
      },
    );
  });
}
