import 'dart:typed_data';

import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:test/test.dart';

String _rowText(Buffer buffer, int row) {
  final out = StringBuffer();
  for (var x = 0; x < buffer.width; x++) {
    final ch = buffer.getCharacter(x, row);
    if (ch.isNotEmpty) out.write(ch);
  }
  return out.toString();
}

void main() {
  group('ScrollbackLine GlyphCellList storage', () {
    test(
      'preserves List<String> constructor compatibility and wraps into GlyphCellList',
      () {
        const family = '👨‍👩‍👧';
        final attrs = Uint32List.fromList([
          0xFFFF0000,
          0,
          Modifier.bold,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0xFF001122,
          0,
        ]);
        final line = ScrollbackLine(
          width: 8,
          characters: ['A', family, '', '🚀'],
          attributes: attrs,
          isWrapped: true,
        );

        expect(line.width, equals(8));
        expect(line.isWrapped, isTrue);
        expect(line.characters, equals(['A', family, '', '🚀']));
        expect(line.glyphCellList, isA<GlyphCellList>());
        expect(line.glyphCellList.hasClusters, isTrue);
        expect(line.glyphCodes[0], equals(0x41));
        expect(
          line.glyphCodes[1] & GlyphCellList.clusterFlag,
          equals(GlyphCellList.clusterFlag),
        );
        expect(line.glyphCodes[2], equals(GlyphCellList.wideContinuationCode));
        expect(line.glyphCodes[3], equals(0x1F680));
        expect(() => line.glyphCodes[0] = 0x42, throwsUnsupportedError);

        // Empty list reuses empty GlyphCellList cleanly.
        final emptyLine = ScrollbackLine(
          width: 4,
          characters: const [],
          attributes: Uint32List(0),
        );
        expect(emptyLine.characters, isEmpty);
        expect(emptyLine.glyphCodes, isEmpty);

        // Passing an existing GlyphCellList wraps directly without re-encoding.
        final existing = GlyphCellList.filled(2)
          ..[0] = 'Z'
          ..[1] = family;
        final wrapped = ScrollbackLine(
          width: 4,
          characters: existing,
          attributes: Uint32List(6),
        );
        expect(identical(wrapped.glyphCellList, existing), isTrue);
      },
    );

    test('fromGlyphCells adopts GlyphCellList with zero extra allocation', () {
      const vs16 = '⏭️';
      final cells = GlyphCellList.filled(3)
        ..[0] = 'X'
        ..[1] = vs16
        ..[2] = '';
      final attrs = Uint32List(9);
      final ul = Uint32List.fromList([0, 0xFF112233, 0]);
      final uris = <String?>[null, 'https://example.dev', null];

      final line = ScrollbackLine.fromGlyphCells(
        width: 10,
        glyphCells: cells,
        attributes: attrs,
        underlineColors: ul,
        uris: uris,
        isWrapped: true,
      );

      expect(identical(line.glyphCellList, cells), isTrue);
      expect(identical(line.glyphCodes, cells.codesView), isTrue);
      expect(line.characters, equals(['X', vs16, '']));
      expect(line.underlineColors, equals(ul));
      expect(line.uris, equals(uris));
      expect(line.isWrapped, isTrue);

      expect(
        () => ScrollbackLine.fromGlyphCells(
          width: 4,
          glyphCells: cells,
          attributes: Uint32List(3),
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test(
      'fromBufferRow trims default spaces via glyphCodes and preserves clusters and aux slices',
      () {
        const family = '👨‍👩‍👧';
        final buf = Buffer.blank(8, 2, defaultBlend: false);
        buf.setAttributes(
          0,
          0,
          char: family,
          fg: 0xFFFFFFFF,
          bg: 0,
          modifiers: 0,
          underlineColor: 0xFF445566,
          uri: 'https://cluster.dev',
        );
        buf.setAttributes(3, 0, char: ' ', fg: 0, bg: 0xFF223344, modifiers: 0);

        final line = ScrollbackLine.fromBufferRow(buf, 0, isWrapped: false);
        expect(line.glyphCellList.length, equals(4));
        expect(line.characters, equals([family, '', ' ', ' ']));
        expect(
          line.glyphCodes[0] & GlyphCellList.clusterFlag,
          equals(GlyphCellList.clusterFlag),
        );
        expect(line.glyphCodes[1], equals(GlyphCellList.wideContinuationCode));
        expect(line.glyphCodes[2], equals(GlyphCellList.spaceCode));
        expect(line.glyphCodes[3], equals(GlyphCellList.spaceCode));
        expect(line.underlineColors?[0], equals(0xFF445566));
        expect(line.uris?[0], equals('https://cluster.dev'));

        final blank = ScrollbackLine.fromBufferRow(buf, 1, isWrapped: true);
        expect(blank.glyphCellList, isEmpty);
        expect(blank.glyphCodes, isEmpty);
        expect(blank.attributes, isEmpty);
        expect(blank.isWrapped, isTrue);
      },
    );
  });

  group('Scrollback eviction and continuous ZWJ compaction', () {
    test(
      'evicts scrolled rows into GlyphCellList-backed scrollback ring with wide clusters',
      () {
        final vt = VirtualTerminal(width: 10, height: 2, maxScrollbackLines: 3);
        vt.writeString(
          'L0 👨‍👩‍👧\r\nL1 中\r\nL2 ⏭️\r\nL3 👩🏽‍💻\r\nL4 END\r\nL5 LIVE',
        );

        expect(vt.scrollback.totalLines, equals(4));
        expect(vt.scrollback.retainedLines, equals(3));
        expect(vt.scrollback[0], isNull);

        final line1 = vt.scrollback[1]!;
        expect(line1.characters, equals(['L', '1', ' ', '中', '']));
        expect(line1.glyphCodes[3], equals(0x4E2D));
        expect(line1.glyphCodes[4], equals(GlyphCellList.wideContinuationCode));

        final line2 = vt.scrollback[2]!;
        expect(line2.characters, equals(['L', '2', ' ', '⏭️', '']));
        expect(
          line2.glyphCodes[3] & GlyphCellList.clusterFlag,
          equals(GlyphCellList.clusterFlag),
        );

        final line3 = vt.scrollback[3]!;
        expect(line3.characters, equals(['L', '3', ' ', '👩🏽‍💻', '']));
        vt.dispose();
      },
    );

    test(
      'continuous scrolling of 5,000 unique ZWJ emoji lines without clear() compacts cluster table',
      () {
        final vt = VirtualTerminal(width: 12, height: 4, maxScrollbackLines: 8);
        const totalLines = 5000;
        // Generate unique multi-codepoint ZWJ+combining clusters so each line
        // interns a distinct cluster entry in the primary buffer.
        String clusterFor(int i) {
          final mark1 = String.fromCharCode(0x0300 + (i % 64));
          final mark2 = String.fromCharCode(0x0300 + ((i ~/ 64) % 64));
          final mark3 = String.fromCharCode(0x0300 + ((i ~/ 4096) % 16));
          return '👨‍👩‍👧$mark1$mark2$mark3';
        }

        for (var i = 0; i < totalLines; i++) {
          final prefix = i == 0 ? '' : '\r\n';
          vt.writeString('$prefix${clusterFor(i)} $i');
        }

        final cells = vt.buffer.glyphCellList;
        expect(cells.hasClusters, isTrue);

        // Verify the 4 visible rows hold exact last 4 lines and compacted IDs.
        for (var row = 0; row < 4; row++) {
          final lineNum = totalLines - 4 + row;
          final expectedCluster = clusterFor(lineNum);
          expect(vt.buffer.getCharacter(0, row), equals(expectedCluster));
          expect(vt.buffer.getCharacter(1, row), equals(''));
          final code = vt.buffer.glyphCodes[row * vt.width];
          expect(
            code & GlyphCellList.clusterFlag,
            equals(GlyphCellList.clusterFlag),
          );
          expect(
            code & GlyphCellList.payloadMask,
            lessThan(GlyphCellList.compactionMinEntries),
          );
          expect(
            _rowText(vt.buffer, row),
            startsWith('$expectedCluster $lineNum'),
          );
        }

        // Scrolling plain ASCII lines off-screen eventually drops all live
        // clusters without ever calling clear(), triggering full compaction.
        for (var i = 0; i < 4; i++) {
          vt.writeString('\r\nPLAIN $i');
        }
        // Trigger compaction check if table grew past threshold; write one more
        // batch if still below threshold, or verify live clusters are zero.
        for (var row = 0; row < 4; row++) {
          for (var col = 0; col < vt.width; col++) {
            expect(
              vt.buffer.glyphCodes[row * vt.width + col] &
                  GlyphCellList.clusterFlag,
              equals(0),
            );
          }
        }
        vt.dispose();
      },
    );
  });

  group('Cross-buffer cluster remapping in renderBuffer and TerminalView', () {
    test(
      'remaps foreign cluster IDs across scrollback and live rows in renderBuffer and TerminalView',
      () {
        const family = '👨‍👩‍👧';
        const technologist = '👩🏽‍💻';
        const vs16 = '⏭️';
        const flag = '🏳️‍🌈';

        final vt = VirtualTerminal(width: 8, height: 3, maxScrollbackLines: 10);
        vt.writeString('$family A\r\n$vs16 B\r\n$technologist C\r\nSHORT');
        vt.scrollViewport(1);

        // Pre-populate target buffer with different clusters so IDs collide.
        final target = Buffer.blank(8, 3, defaultBlend: false)
          ..writeString(0, 0, '$flag$technologist$family', const Style())
          ..writeString(0, 1, 'XXXXXXXX', const Style())
          ..writeString(0, 2, 'YYYYYYYY', const Style());
        expect(target.glyphCodes[0] & GlyphCellList.payloadMask, equals(0));

        vt.renderBuffer(target);
        // Row 0 is scrollback line '$family A' (length 4 -> tail 4..7 blanked).
        expect(target.getCharacter(0, 0), equals(family));
        expect(target.getCharacter(1, 0), equals(''));
        expect(target.getCharacter(3, 0), equals('A'));
        expect(target.glyphCodes[4], equals(GlyphCellList.spaceCode));
        expect(target.glyphCodes[7], equals(GlyphCellList.spaceCode));

        // Row 1 & 2 are live rows '$vs16 B' and '$technologist C'.
        expect(target.getCharacter(0, 1), equals(vs16));
        expect(target.getCharacter(3, 1), equals('B'));
        expect(target.getCharacter(0, 2), equals(technologist));
        expect(target.getCharacter(3, 2), equals('C'));

        // Paint opaque TerminalView into a buffer with colliding cluster IDs.
        final canvas = Buffer.blank(8, 3, defaultBlend: false)
          ..writeString(0, 0, '$flag$vs16', const Style())
          ..writeString(0, 1, 'ZZZZZZZZ', const Style());
        final element =
            TerminalView(terminal: vt, autofocus: false).createElement()
              ..mount(null)
              ..layout(BoxConstraints.tight(const Size(8, 3)))
              ..paint(canvas, Offset.zero);
        addTearDown(element.unmount);

        expect(canvas.getCharacter(0, 0), equals(family));
        expect(canvas.getCharacter(3, 0), equals('A'));
        expect(canvas.glyphCodes[5], equals(GlyphCellList.spaceCode));
        expect(canvas.getCharacter(0, 1), equals(vs16));
        expect(canvas.getCharacter(0, 2), equals(technologist));

        // Simulate missing/evicted scrollback entry -> blanks row cleanly.
        vt.scrollback.clear();
        vt.renderBuffer(target);
        expect(target.glyphCodes[0], equals(GlyphCellList.spaceCode));
        expect(target.glyphCodes[3], equals(GlyphCellList.spaceCode));

        element.paint(canvas, Offset.zero);
        expect(canvas.glyphCodes[0], equals(GlyphCellList.spaceCode));
        expect(canvas.glyphCodes[3], equals(GlyphCellList.spaceCode));

        vt.dispose();
      },
    );

    test(
      'transparent TerminalView and renderBuffer remap clusters and preserve backdrop',
      () {
        const family = '👨‍👩‍👧';
        const technologist = '👩🏽‍💻';
        const flag = '🏳️‍🌈';

        final vt = VirtualTerminal(
          width: 8,
          height: 2,
          maxScrollbackLines: 10,
          transparentBackground: true,
        );
        vt.writeString('$family A\r\n$technologist B\r\nLIVE');
        vt.scrollViewport(1);

        // Transparent renderBuffer sets Modifier.transparent on blank tail.
        final rendered = vt.renderBuffer();
        expect(rendered.getCharacter(0, 0), equals(family));
        expect(rendered.getCharacter(3, 0), equals('A'));
        expect(
          rendered.getModifiers(5, 0) & Modifier.transparent,
          equals(Modifier.transparent),
        );

        // Transparent TerminalView remaps foreign clusters over non-empty backdrop.
        final canvas = Buffer.blank(8, 2, defaultBlend: false)
          ..fillAttributes(char: '.', fg: 0xFFAAAAAA, bg: 0xFF102030)
          ..setCharacter(7, 0, flag);
        final element =
            TerminalView(terminal: vt, autofocus: false).createElement()
              ..mount(null)
              ..layout(BoxConstraints.tight(const Size(8, 2)))
              ..paint(canvas, Offset.zero);
        addTearDown(element.unmount);

        expect(canvas.getCharacter(0, 0), equals(family));
        expect(canvas.getCharacter(1, 0), equals(''));
        expect(canvas.getCharacter(2, 0), equals('.'));
        expect(canvas.getCharacter(3, 0), equals('A'));
        expect(canvas.getCharacter(7, 0), equals(flag));
        expect(canvas.getCharacter(0, 1), equals(technologist));
        expect(canvas.getCharacter(3, 1), equals('B'));
        expect(canvas.getCharacter(5, 1), equals('.'));

        vt.dispose();
      },
    );
  });

  group('Wide CJK split clearing and ED/EL blanking', () {
    test(
      'ASCII run overwrite heals split wide CJK boundaries on both left and right edges',
      () {
        final vt = VirtualTerminal(width: 8, height: 2);
        // Columns: [0..1]='中', [2..3]='文', [4..5]='漢', [6..7]='字'
        vt.writeString('中文漢字');
        expect(vt.buffer.glyphCodes[0], equals(0x4E2D));
        expect(
          vt.buffer.glyphCodes[1],
          equals(GlyphCellList.wideContinuationCode),
        );
        expect(vt.buffer.glyphCodes[4], equals(0x6F22));
        expect(
          vt.buffer.glyphCodes[5],
          equals(GlyphCellList.wideContinuationCode),
        );

        // Overwrite cols 1..4 with 'ABCD': splits '中' (left) and '漢' (right).
        vt.writeString('\x1b[1;2HABCD');
        expect(vt.buffer.glyphCodes[0], equals(GlyphCellList.spaceCode));
        expect(vt.buffer.glyphCodes[1], equals(0x41));
        expect(vt.buffer.glyphCodes[2], equals(0x42));
        expect(vt.buffer.glyphCodes[3], equals(0x43));
        expect(vt.buffer.glyphCodes[4], equals(0x44));
        expect(vt.buffer.glyphCodes[5], equals(GlyphCellList.spaceCode));
        expect(vt.buffer.glyphCodes[6], equals(0x5B57));
        expect(
          vt.buffer.glyphCodes[7],
          equals(GlyphCellList.wideContinuationCode),
        );
        vt.dispose();
      },
    );

    test(
      'EL (CSI 0/1/2 K), ECH, DCH, ICH, and resize heal split wide CJK glyphs',
      () {
        final vt = VirtualTerminal(width: 8, height: 2);

        // EL 0 starting at trailing half (col 1) of '中' clears col 0 too.
        vt.writeString('中文漢字\x1b[1;2H\x1b[0K');
        for (var x = 0; x < 8; x++) {
          expect(vt.buffer.glyphCodes[x], equals(GlyphCellList.spaceCode));
        }

        // EL 1 ending at leading half (col 4) of '漢' clears col 5 too.
        vt.writeString('\x1b[1;1H中文漢字\x1b[1;5H\x1b[1K');
        for (var x = 0; x < 6; x++) {
          expect(vt.buffer.glyphCodes[x], equals(GlyphCellList.spaceCode));
        }
        expect(vt.buffer.glyphCodes[6], equals(0x5B57));
        expect(
          vt.buffer.glyphCodes[7],
          equals(GlyphCellList.wideContinuationCode),
        );

        // EL 2 clears the entire line cleanly.
        vt.writeString('\x1b[2K');
        for (var x = 0; x < 8; x++) {
          expect(vt.buffer.glyphCodes[x], equals(GlyphCellList.spaceCode));
        }

        // DCH (CSI 1 P) on trailing half of '中' heals col 0 and shifts left.
        vt.writeString('\x1b[1;1H中文漢字\x1b[1;2H\x1b[1P');
        expect(vt.buffer.glyphCodes[0], equals(GlyphCellList.spaceCode));
        expect(vt.buffer.glyphCodes[1], equals(0x6587));
        expect(
          vt.buffer.glyphCodes[2],
          equals(GlyphCellList.wideContinuationCode),
        );

        // DCH (CSI 1 P) deleting leading half of '漢' heals orphaned continuation.
        vt.writeString('\x1b[1;1H中文漢字\x1b[1;5H\x1b[1P');
        expect(vt.buffer.glyphCodes[4], equals(GlyphCellList.spaceCode));
        expect(vt.buffer.glyphCodes[5], equals(0x5B57));

        // ICH (CSI 1 @) on trailing half of '中' clears '中' and heals right edge '字'.
        vt.writeString('\x1b[1;1H中文漢字\x1b[1;2H\x1b[1@');
        expect(vt.buffer.glyphCodes[0], equals(GlyphCellList.spaceCode));
        expect(vt.buffer.glyphCodes[1], equals(GlyphCellList.spaceCode));
        expect(vt.buffer.glyphCodes[7], equals(GlyphCellList.spaceCode));

        // Horizontal shrink splits '文' at col 2 -> healed to space on right edge.
        vt.writeString('\x1b[1;1H中文漢字');
        vt.resize(3, 2);
        expect(vt.buffer.glyphCodes[0], equals(0x4E2D));
        expect(
          vt.buffer.glyphCodes[1],
          equals(GlyphCellList.wideContinuationCode),
        );
        expect(vt.buffer.glyphCodes[2], equals(GlyphCellList.spaceCode));

        vt.dispose();
      },
    );

    test(
      'ED 0/1/2 blanking clears cells via fillCodeRange, respects BCE background, and resets clusters',
      () {
        const family = '👨‍👩‍👧';
        final vt = VirtualTerminal(width: 6, height: 3);
        vt.writeString(
          '$family 11\r\n'
          '222222\r\n'
          '333333',
        );
        expect(vt.buffer.glyphCellList.hasClusters, isTrue);

        // Set green background (BCE) and run ED 0 from (row 1, col 2).
        vt.writeString('\x1b[48;2;10;20;30m\x1b[2;3H\x1b[0J');
        expect(vt.buffer.getCharacter(0, 0), equals(family));
        expect(vt.buffer.getCharacter(0, 1), equals('2'));
        expect(vt.buffer.getCharacter(1, 1), equals('2'));
        expect(
          vt.buffer.glyphCodes[1 * 6 + 2],
          equals(GlyphCellList.spaceCode),
        );
        expect(
          vt.buffer.getBackground(2, 1),
          equals(const Color(10, 20, 30).argb),
        );
        expect(
          vt.buffer.glyphCodes[2 * 6 + 0],
          equals(GlyphCellList.spaceCode),
        );
        expect(
          vt.buffer.getBackground(5, 2),
          equals(const Color(10, 20, 30).argb),
        );

        // Reset SGR and run ED 1 up to (row 1, col 1).
        vt.writeString('\x1b[0m\x1b[2;2H\x1b[1J');
        for (var i = 0; i < 8; i++) {
          expect(vt.buffer.glyphCodes[i], equals(GlyphCellList.spaceCode));
          expect(vt.buffer.attributes[i * 3 + 1], equals(0));
        }

        // Write a cluster again and run ED 2 -> O(1) cluster table reset.
        vt.writeString('\x1b[1;1H$family\x1b[2J');
        expect(vt.buffer.glyphCellList.hasClusters, isFalse);
        for (var i = 0; i < vt.width * vt.height; i++) {
          expect(vt.buffer.glyphCodes[i], equals(GlyphCellList.spaceCode));
        }

        // RIS full reset also clears clusters via _fillRowsWithEraseAttributes.
        vt.writeString('$family\x1bc');
        expect(vt.buffer.glyphCellList.hasClusters, isFalse);
        vt.dispose();
      },
    );
  });

  group('ASCII run fast-path semantics', () {
    test(
      'handles auto-wrap, non-auto-wrap clamping, combining follow-up, REP, and transparent spaces',
      () {
        // 1. Multi-line wrapping ASCII run + follow-up combining mark + REP.
        final vt = VirtualTerminal(width: 4, height: 3, maxScrollbackLines: 5);
        vt.writeString('ABCDEFGH');
        expect(_rowText(vt.buffer, 0), equals('ABCD'));
        expect(_rowText(vt.buffer, 1), equals('EFGH'));
        expect(vt.isRowWrapped(0), isFalse);
        expect(vt.isRowWrapped(1), isTrue);
        expect(vt.cursorX, equals(4)); // pending wrap
        expect(vt.cursorY, equals(1));

        // Combining acute accent in next chunk merges onto 'H' at (3, 1).
        vt.writeString('\u0301');
        expect(vt.buffer.getCharacter(3, 1), equals('H\u0301'));

        // REP (CSI 2 b) after ASCII run repeats last ASCII char.
        vt.writeString('\x1b[3;1HXY\x1b[2b');
        expect(_rowText(vt.buffer, 2), equals('XYYY'));

        // 2. Non-auto-wrap (DECAWM off) overflows clamp at right margin.
        vt.writeString('\x1b[?7l\x1b[1;3H12345');
        expect(_rowText(vt.buffer, 0), equals('AB15'));
        expect(vt.cursorX, equals(3));

        // Single-column overflow at width - 1 keeps last char only.
        vt.writeString('PQ');
        expect(vt.buffer.getCharacter(3, 0), equals('Q'));
        expect(vt.cursorX, equals(3));

        // 3. Transparent background marks only space cells as transparent.
        final transparentVt = VirtualTerminal(
          width: 6,
          height: 2,
          transparentBackground: true,
        );
        transparentVt.writeString('A B ');
        expect(transparentVt.buffer.glyphCodes[0], equals(0x41));
        expect(
          transparentVt.buffer.getModifiers(0, 0) & Modifier.transparent,
          equals(0),
        );
        expect(
          transparentVt.buffer.glyphCodes[1],
          equals(GlyphCellList.spaceCode),
        );
        expect(
          transparentVt.buffer.getModifiers(1, 0) & Modifier.transparent,
          equals(Modifier.transparent),
        );
        expect(transparentVt.buffer.glyphCodes[2], equals(0x42));
        expect(
          transparentVt.buffer.getModifiers(2, 0) & Modifier.transparent,
          equals(0),
        );
        expect(
          transparentVt.buffer.getModifiers(3, 0) & Modifier.transparent,
          equals(Modifier.transparent),
        );

        // 4. Shrink height eviction uses glyphCodes in _rowHasVisibleContent.
        final shrinkVt = VirtualTerminal(
          width: 6,
          height: 4,
          maxScrollbackLines: 5,
        );
        shrinkVt.writeString('R0\r\nR1\r\n> \r\nFOOT\x1b[3;3H');
        shrinkVt.resize(6, 3);
        expect(shrinkVt.scrollback.retainedLines, equals(1));
        expect(shrinkVt.scrollback[0]!.characters, equals(['R', '0']));
        expect(_rowText(shrinkVt.buffer, 2), startsWith('FOOT'));

        vt.dispose();
        transparentVt.dispose();
        shrinkVt.dispose();
      },
    );
  });
}
