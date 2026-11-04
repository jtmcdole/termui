import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:test/test.dart';

String _lineText(ScrollbackLine line) {
  final out = StringBuffer();
  for (final ch in line.characters) {
    if (ch.isNotEmpty) out.write(ch);
  }
  return out.toString();
}

void main() {
  group('ScrollbackBuffer', () {
    test('evicts oldest lines in O(1) once maxLines capacity is reached', () {
      final ring = ScrollbackBuffer(maxLines: 3);
      for (var i = 0; i < 5; i++) {
        ring.push(
          ScrollbackLine(
            width: 10,
            characters: ['L', '$i'],
            attributes: .fromList([0, 0, 0, 0, 0, 0]),
          ),
        );
      }

      expect(ring.clearSeq, equals(0));
      expect(ring.oldestLine, equals(2));
      expect(ring.totalLines, equals(5));
      expect(ring.retainedLines, equals(3));
      expect(ring.length, equals(3));
      expect(ring[0], isNull);
      expect(ring[1], isNull);
      expect(_lineText(ring[2]!), equals('L2'));
      expect(_lineText(ring[3]!), equals('L3'));
      expect(_lineText(ring[4]!), equals('L4'));
      expect(ring[5], isNull);

      final sliced = ring.slice(0, 4);
      expect([
        for (final line in sliced) _lineText(line),
      ], equals(['L2', 'L3']));
    });

    test(
      'handles 64-bit integer overflow in slice(1, 0x7FFFFFFFFFFFFFFF) and validates attribute length',
      () {
        final ring = ScrollbackBuffer(maxLines: 5);
        for (var i = 0; i < 4; i++) {
          ring.push(
            ScrollbackLine(
              width: 8,
              characters: ['R', '$i'],
              attributes: .fromList([0, 0, 0, 0, 0, 0]),
            ),
          );
        }

        final sliced = ring.slice(1, 0x7FFFFFFFFFFFFFFF);
        expect([
          for (final line in sliced) _lineText(line),
        ], equals(['R1', 'R2', 'R3']));
        expect(ring.slice(-0x8000000000000000, 10), isEmpty);
        expect(ring.slice(0, 0), isEmpty);

        expect(
          () => ScrollbackLine(
            width: 4,
            characters: const ['A', 'B'],
            attributes: .fromList([0, 0, 0]),
          ),
          throwsA(isA<AssertionError>()),
        );
      },
    );

    test(
      'retains zero lines when maxLines is zero and increments clearSeq on clear',
      () {
        final disabled = ScrollbackBuffer(maxLines: 0);
        disabled.push(
          ScrollbackLine(
            width: 4,
            characters: const ['A'],
            attributes: .fromList([0, 0, 0]),
          ),
        );
        expect(disabled.oldestLine, equals(1));
        expect(disabled.totalLines, equals(1));
        expect(disabled.retainedLines, equals(0));
        expect(disabled.isEmpty, isTrue);

        final active = ScrollbackBuffer(maxLines: 4);
        active.push(
          ScrollbackLine(
            width: 4,
            characters: const ['X'],
            attributes: .fromList([0, 0, 0]),
          ),
        );
        active.clear();
        expect(active.clearSeq, equals(1));
        expect(active.oldestLine, equals(0));
        expect(active.totalLines, equals(0));
        expect(active.retainedLines, equals(0));
      },
    );

    test(
      'fromBufferRow trims trailing default blanks while preserving styled spaces and wide graphemes',
      () {
        final buf = Buffer.blank(6, 2, defaultBlend: false);
        // Row 0: completely blank -> empty characters & attributes.
        final blankLine = ScrollbackLine.fromBufferRow(
          buf,
          0,
          isWrapped: false,
        );
        expect(blankLine.width, equals(6));
        expect(blankLine.characters, isEmpty);
        expect(blankLine.attributes, isEmpty);

        // Row 1: wide emoji at 0..1, space with non-zero bg at col 3, default blanks at 4..5.
        buf.setAttributes(0, 1, char: '🚀', fg: 1, bg: 0, modifiers: 0);
        buf.setAttributes(1, 1, char: '', fg: 1, bg: 0, modifiers: 0);
        buf.setAttributes(3, 1, char: ' ', fg: 0, bg: 0xFF112233, modifiers: 0);
        final styledLine = ScrollbackLine.fromBufferRow(
          buf,
          1,
          isWrapped: true,
        );
        expect(styledLine.isWrapped, isTrue);
        expect(styledLine.characters, equals(['🚀', '', ' ', ' ']));
        expect(styledLine.attributes.length, equals(12));
        expect(styledLine.attributes[10], equals(0xFF112233));
      },
    );
  });

  group('VirtualTerminal scrollback integration', () {
    test(
      'evicts primary rows on indexDown and SU while ignoring DL/altScreen/non-top DECSTBM',
      () {
        final vt = VirtualTerminal(width: 8, height: 3, maxScrollbackLines: 10);
        vt.writeString('ROW0\r\nROW1\r\nROW2\r\nROW3');
        expect(vt.scrollback.length, equals(1));
        expect(_lineText(vt.scrollback[0]!), equals('ROW0'));

        // CSI 1 S (SU) scrolls top row into scrollback.
        vt.writeString('\x1b[S');
        expect(vt.scrollback.length, equals(2));
        expect(_lineText(vt.scrollback[1]!), equals('ROW1'));

        // CSI 1 M (DL) deletes top row without pushing to scrollback.
        vt.writeString('\x1b[1;1H\x1b[M');
        expect(vt.scrollback.length, equals(2));

        // Non-top DECSTBM (rows 2..3) must not evict row 0 into scrollback.
        vt.writeString('\x1b[2;3r\x1b[3;1H\r\n\r\n');
        expect(vt.scrollback.length, equals(2));
        vt.writeString('\x1b[r');

        // Alternate screen (?1049h) scrolling must not touch primary scrollback.
        vt.writeString(
          '\x1b[?1049hALT0\r\nALT1\r\nALT2\r\nALT3\r\n\x1b[?1049l',
        );
        expect(vt.scrollback.length, equals(2));
      },
    );

    test(
      'evicts top row when DECSTBM starts at row 1 with a bottom status line',
      () {
        final vt = VirtualTerminal(width: 8, height: 4, maxScrollbackLines: 10);
        vt.writeString('TOP\r\nMID\r\nBOT\r\nSTATUS');
        vt.writeString('\x1b[1;3r\x1b[3;1H\r\nNEW');
        expect(vt.scrollback.length, equals(1));
        expect(_lineText(vt.scrollback[0]!), equals('TOP'));
      },
    );

    test(
      'preserves wide graphemes, styled spaces, and soft-wrap isWrapped flags',
      () {
        final vt = VirtualTerminal(width: 5, height: 2, maxScrollbackLines: 10);
        vt.writeString('1234567\r\nNEXT');
        expect(vt.scrollback.length, equals(1));
        expect(vt.scrollback[0]!.isWrapped, isFalse);

        vt.writeString('\r\nLAST');
        expect(vt.scrollback.length, equals(2));
        expect(vt.scrollback[1]!.isWrapped, isTrue);
        expect(_lineText(vt.scrollback[1]!), equals('67'));

        vt.writeString('\r\n🚀\r\nAFTER\r\nDONE');
        final emojiLine = vt.scrollback[vt.scrollback.totalLines - 1]!;
        expect(emojiLine.characters, equals(['🚀', '']));
      },
    );

    test(
      'CSI 3 J clears only primary scrollback and bumps clearSeq; RIS clears both',
      () {
        final vt = VirtualTerminal(width: 6, height: 2, maxScrollbackLines: 10);
        vt.writeString('ONE\r\nTWO\r\nTHREE');
        expect(vt.scrollback.length, equals(1));
        expect(vt.scrollback.clearSeq, equals(0));

        // CSI 3 J inside ?1049h altScreen preserves primary scrollback.
        vt.writeString('\x1b[?1049h\x1b[3J\x1b[?1049l');
        expect(vt.scrollback.length, equals(1));
        expect(vt.scrollback.clearSeq, equals(0));

        vt.writeString('\x1b[3J');
        expect(vt.scrollback.length, equals(0));
        expect(vt.scrollback.clearSeq, equals(1));
        expect(vt.buffer.getCharacter(0, 0), equals('T'));

        vt.writeString('\r\nFOUR\x1bc');
        expect(vt.scrollback.length, equals(0));
        expect(vt.scrollback.clearSeq, equals(2));
        expect(vt.buffer.getCharacter(0, 0), equals(' '));
      },
    );

    test(
      'height shrink on primary or inside ?1049h altScreen evicts overflow and preserves prompt',
      () {
        final vt = VirtualTerminal(width: 6, height: 4, maxScrollbackLines: 10);
        vt.writeString('L0\r\nL1\r\nL2\r\nPROMPT');
        expect(vt.cursorY, equals(3));

        // Shrink height 4 -> 3 on primary screen.
        vt.resize(6, 3);
        expect(vt.scrollback.length, equals(1));
        expect(_lineText(vt.scrollback[0]!), equals('L0'));
        expect(vt.cursorY, equals(2));

        // Enter ?1049h, shrink height 3 -> 2, then exit ?1049l.
        vt.writeString('\x1b[?1049hALT_UI');
        vt.resize(6, 2);
        expect(vt.scrollback.length, equals(2));
        expect(_lineText(vt.scrollback[1]!), equals('L1'));

        vt.writeString('\x1b[?1049l');
        expect(vt.cursorY, equals(1));
        expect(vt.buffer.getCharacter(0, 0), equals('L'));
        expect(vt.buffer.getCharacter(1, 0), equals('2'));
        expect(vt.buffer.getCharacter(0, 1), equals('P'));
        expect(vt.buffer.getCharacter(5, 1), equals('T'));
      },
    );

    test(
      'height shrink preserves non-blank status rows below cursorY by evicting top rows and shifting cursorY up',
      () {
        final vt = VirtualTerminal(
          width: 10,
          height: 4,
          maxScrollbackLines: 10,
        );
        // Inline TUI layout: row 0 = history, row 1 = top border,
        // row 2 = "> input" (where cursorY rests), row 3 = "no images" footer.
        vt.writeString('HIST0\r\n╭────────╮\r\n> hello\r\nno images\x1b[3;8H');
        expect(vt.cursorY, equals(2));
        expect(vt.cursorX, equals(7));

        // Shrinking height 4 -> 3 (e.g. showing docked top bar) must evict HIST0
        // and shift cursorY 2 -> 1 so "no images" stays 1 row below "> hello".
        vt.resize(10, 3);
        expect(vt.scrollback.length, equals(1));
        expect(_lineText(vt.scrollback[0]!), equals('HIST0'));
        expect(vt.cursorY, equals(1));
        expect(vt.cursorX, equals(7));
        expect(vt.buffer.getCharacter(0, 1), equals('>'));
        expect(vt.buffer.getCharacter(2, 1), equals('h'));
        expect(vt.buffer.getCharacter(0, 2), equals('n'));
        expect(vt.buffer.getCharacter(3, 2), equals('i'));

        // Styled blank row below cursor (cursorY == 1) counts as visible content,
        // evicts row 0 ('╭────────╮'), and shifts DECSC saved cursor with it;
        // shrinking again at cursorY == 0 caps eviction at cursorY.
        vt.writeString('\x1b[3;1H\x1b[44m          \x1b[0m\x1b[2;8H\x1b7');
        expect(vt.cursorY, equals(1));
        vt.resize(10, 2);
        expect(vt.cursorY, equals(0));
        expect(vt.scrollback.length, equals(2));
        expect(vt.buffer.getBackground(0, 1), isNot(equals(0)));
        vt.writeString('\x1b8');
        expect(vt.cursorY, equals(0));

        vt.resize(10, 1);
        expect(vt.cursorY, equals(0));
        expect(vt.scrollback.length, equals(2));

        // Height shrink inside ?1049h alt-screen keeps primary footer below saved cursor.
        final altVt = VirtualTerminal(
          width: 10,
          height: 4,
          maxScrollbackLines: 10,
        );
        altVt.writeString('H0\r\nH1\r\n> in\r\nfooter\x1b[3;3H\x1b[?1049h');
        altVt.resize(10, 3);
        altVt.writeString('\x1b[?1049l');
        expect(altVt.scrollback.length, equals(1));
        expect(altVt.cursorY, equals(1));
        expect(altVt.buffer.getCharacter(0, 1), equals('>'));
        expect(altVt.buffer.getCharacter(0, 2), equals('f'));
      },
    );

    test(
      'isRowWrapped reports live wraps including row 0 seam and clears broken seams on CSI 0/1/2 K',
      () {
        final vt = VirtualTerminal(width: 5, height: 4, maxScrollbackLines: 10);
        vt.writeString('AAAAABBBBBCCCCCDD');
        expect(vt.isRowWrapped(-1), isFalse);
        expect(vt.isRowWrapped(0), isFalse);
        expect(vt.isRowWrapped(1), isTrue);
        expect(vt.isRowWrapped(2), isTrue);
        expect(vt.isRowWrapped(3), isTrue);
        expect(vt.isRowWrapped(4), isFalse);

        // LF (\n) across row 1 preserves existing wrap flag; altScreen reports false.
        vt.writeString('\x1b[1;1H\n');
        expect(vt.isRowWrapped(1), isTrue);
        vt.writeString('\x1b[?1049h');
        expect(vt.isRowWrapped(1), isFalse);
        vt.writeString('\x1b[?1049l');
        expect(vt.isRowWrapped(1), isTrue);

        // CSI 0 K at col 2 of row 0 clears row 1 seam; CSI 1 K at col 1 of row 2 clears row 2 seam.
        vt.writeString('\x1b[1;3H\x1b[0K');
        expect(vt.isRowWrapped(1), isFalse);
        expect(vt.isRowWrapped(2), isTrue);
        vt.writeString('\x1b[3;2H\x1b[1K');
        expect(vt.isRowWrapped(2), isFalse);
        expect(vt.isRowWrapped(3), isTrue);

        // CSI 2 K on row 2 clears both row 2 and row 3 seams.
        vt.writeString('\x1b[2;1HBBBBBCCCCCDD\x1b[3;3H\x1b[2K');
        expect(vt.isRowWrapped(2), isFalse);
        expect(vt.isRowWrapped(3), isFalse);

        // Scrolling wrapped row 1 ('BBBBB') up to row 0 keeps row 0 wrapped from scrollback.
        vt.writeString('\x1b[1;1H1234567\r\nX\r\nY\r\nZ');
        expect(vt.buffer.getCharacter(0, 0), equals('6'));
        expect(vt.isRowWrapped(0), isTrue);
      },
    );
  });
}
