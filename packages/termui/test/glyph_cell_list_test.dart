import 'package:termui/termui.dart';
import 'package:test/test.dart';

final class _NoOpEffect extends TerminalEffect {
  const _NoOpEffect();

  @override
  void applyEffect(Buffer target, Rect bounds) {}
}

void main() {
  group('GlyphCellList encoding and round-trip', () {
    test('encodes and decodes empty continuation, space, ASCII, and BMP', () {
      final list = GlyphCellList.filled(6);
      expect(list.codesView, hasLength(6));
      expect(identical(list.codesView, list.codesView), isTrue);
      expect(list.hasClusters, isFalse);
      expect(list[0], ' ');
      expect(list.codesView[0], GlyphCellList.spaceCode);

      list[0] = '';
      list[1] = 'A';
      list[2] = '\x01';
      list[3] = '\x7F';
      list[4] = '─';
      list[5] = '中';

      expect(list.hasClusters, isFalse);
      expect(list.codesView[0], GlyphCellList.wideContinuationCode);
      expect(list.codesView[1], 0x41);
      expect(list.codesView[2], 0x01);
      expect(list.codesView[3], 0x7F);
      expect(list.codesView[4], 0x2500);
      expect(list.codesView[5], 0x4E2D);

      expect(list[0], '');
      expect(list[1], 'A');
      expect(identical(list[1], list.decodeCode(0x41)), isTrue);
      expect(list[2], '\x01');
      expect(list[3], '\x7F');
      expect(list[4], '─');
      expect(list[5], '中');
    });

    test(
      'interns NUL and unpaired surrogates distinctly from empty string',
      () {
        final list = GlyphCellList.filled(5);
        final highSurrogate = String.fromCharCode(0xD800);
        final lowSurrogate = String.fromCharCode(0xDFFF);
        final reversedPair = '$lowSurrogate$highSurrogate';

        list[0] = '';
        list[1] = '\x00';
        list[2] = highSurrogate;
        list[3] = lowSurrogate;
        list[4] = reversedPair;

        expect(list.hasClusters, isTrue);
        expect(list.codesView[0], GlyphCellList.wideContinuationCode);
        for (var i = 1; i < 5; i++) {
          expect(
            list.codesView[i] & GlyphCellList.clusterFlag,
            GlyphCellList.clusterFlag,
          );
        }

        expect(list[0], '');
        expect(list[1], '\x00');
        expect(list[2], highSurrogate);
        expect(list[3], lowSurrogate);
        expect(list[4], reversedPair);
      },
    );

    test(
      'packs valid SMP scalars unboxed and interns ZWJ, VS16, and Kitty cells',
      () {
        final list = GlyphCellList.filled(6);
        const rocket = '🚀';
        const family = '👨‍👩‍👧';
        const vs16 = '⏭️';
        const combining = 'e\u0301';
        final kitty = kittyPlaceholderCell(1, 2, imageIdMsb: 0x2A);

        list[0] = rocket;
        list[1] = kittyPlaceholderChar;
        list[2] = family;
        list[3] = vs16;
        list[4] = combining;
        list[5] = kitty;

        expect(list.codesView[0], 0x1F680);
        expect(list.codesView[1], kittyPlaceholderCodePoint);
        expect(
          list.codesView[2] & GlyphCellList.clusterFlag,
          GlyphCellList.clusterFlag,
        );
        expect(
          list.codesView[3] & GlyphCellList.clusterFlag,
          GlyphCellList.clusterFlag,
        );
        expect(
          list.codesView[4] & GlyphCellList.clusterFlag,
          GlyphCellList.clusterFlag,
        );
        expect(
          list.codesView[5] & GlyphCellList.clusterFlag,
          GlyphCellList.clusterFlag,
        );

        expect(list.encodeGrapheme(family), list.codesView[2]);
        expect(list[0], rocket);
        expect(list[1], kittyPlaceholderChar);
        expect(list[2], family);
        expect(list[3], vs16);
        expect(list[4], combining);
        expect(list[5], kitty);
      },
    );

    test('enforces immutability and argument validation', () {
      final list = GlyphCellList.filled(4, fillCode: 0x42);
      expect(list.join(), 'BBBB');
      expect(() => list.length = 2, throwsUnsupportedError);
      expect(() => list.codesView[0] = 0x41, throwsUnsupportedError);
      expect(
        () => list.codesView.fillRange(0, 2, 0x41),
        throwsUnsupportedError,
      );
      expect(() => GlyphCellList.filled(-1), throwsRangeError);
      expect(
        () => GlyphCellList.filled(2, fillCode: GlyphCellList.clusterFlag),
        throwsArgumentError,
      );
      expect(() => list.fillRange(0, 2), throwsArgumentError);

      final zeroList = GlyphCellList.filled(
        3,
        fillCode: GlyphCellList.wideContinuationCode,
      );
      expect(zeroList.codesView, [0, 0, 0]);
    });
  });

  group('GlyphCellList block operations and cluster remapping', () {
    test('remaps foreign cluster IDs across setRange and copyCellsFrom', () {
      const family = '👨‍👩‍👧';
      const vs16 = '⏭️';
      const technologist = '👩🏽‍💻';

      final src = GlyphCellList.filled(5);
      src[0] = family;
      src[1] = '';
      src[2] = vs16;
      src[3] = 'X';
      src[4] = '\x00';

      final dst = GlyphCellList.filled(6);
      dst[0] = technologist;
      dst[1] = family;
      dst[2] = 'Z';

      expect(src.codesView[0] & GlyphCellList.payloadMask, 0);
      expect(dst.codesView[0] & GlyphCellList.payloadMask, 0);
      expect(dst.codesView[1] & GlyphCellList.payloadMask, 1);

      dst.copyCellsFrom(src, 1, 0, 5);
      expect(dst[0], technologist);
      expect(dst[1], family);
      expect(dst[2], '');
      expect(dst[3], vs16);
      expect(dst[4], 'X');
      expect(dst[5], '\x00');

      final dstViaSetRange = GlyphCellList.filled(6);
      dstViaSetRange[0] = technologist;
      dstViaSetRange.setRange(1, 6, src, 0);
      expect(dstViaSetRange[0], technologist);
      expect(dstViaSetRange[1], family);
      expect(dstViaSetRange[2], '');
      expect(dstViaSetRange[3], vs16);
      expect(dstViaSetRange[4], 'X');
      expect(dstViaSetRange[5], '\x00');
    });

    test('handles overlapping self-copies and scalar-only copies', () {
      const family = '👨‍👩‍👧';
      const vs16 = '⏭️';

      final list = GlyphCellList.filled(5);
      list[0] = family;
      list[1] = vs16;
      list[2] = 'A';
      list[3] = 'B';
      list[4] = 'C';

      // Forward overlapping copy: [0..3) -> [1..4)
      list.copyCellsFrom(list, 1, 0, 3);
      expect(list.toList(), [family, family, vs16, 'A', 'C']);

      // Backward overlapping copy: [1..4) -> [0..3)
      list.copyCellsFrom(list, 0, 1, 3);
      expect(list.toList(), [family, vs16, 'A', 'A', 'C']);

      // Zero-count and scalar-only source overwrite
      list.copyCellsFrom(list, 0, 0, 0);
      final scalarSrc = GlyphCellList.filled(2, fillCode: 0x5A);
      list.copyCellsFrom(scalarSrc, 0, 0, 2);
      expect(list.toList(), ['Z', 'Z', 'A', 'A', 'C']);
    });

    test('supports setRange with List<String> and lazy Iterable<String>', () {
      final list = GlyphCellList.filled(4);
      list.setRange(0, 2, ['👨‍👩‍👧', '🚀', 'X'], 1);
      expect(list[0], '🚀');
      expect(list[1], 'X');

      final lazy = Iterable<String>.generate(3, (i) => 'c$i\u0301');
      list.setRange(1, 4, lazy, 0);
      expect(list[1], 'c0\u0301');
      expect(list[2], 'c1\u0301');
      expect(list[3], 'c2\u0301');

      expect(() => list.setRange(0, 3, ['onlyOne']), throwsStateError);
      expect(
        () => list.setRange(0, 3, Iterable<String>.generate(1, (i) => 'a')),
        throwsStateError,
      );
      expect(() => list.copyCellsFrom(list, 0, 0, -1), throwsRangeError);
    });

    test(
      'compacts dead clusters after >1024 unique clusters overwritten by fillCodeRange',
      () {
        const total = 1200;
        final list = GlyphCellList.filled(total);
        for (var i = 0; i < total; i++) {
          list[i] = 'x${String.fromCharCode(0x0300 + (i % 40))}$i';
        }
        expect(list.hasClusters, isTrue);

        // Overwrite all cells via two partial fillCodeRange calls (no clear()).
        list.fillCodeRange(0, 600, GlyphCellList.spaceCode);
        expect(list.hasClusters, isTrue);
        list.fillCodeRange(600, total, GlyphCellList.spaceCode);

        expect(list.hasClusters, isFalse);
        expect(list[0], ' ');
        expect(list[total - 1], ' ');
      },
    );

    test(
      'compacts partial dead clusters while preserving live clusters and reindexing IDs',
      () {
        const total = 1300;
        final list = GlyphCellList.filled(total);
        final expectedLive = <String>[];
        for (var i = 0; i < total; i++) {
          final cluster = 'k$i\u0301';
          list[i] = cluster;
          if (i >= 1200) expectedLive.add(cluster);
        }

        // Overwrite first 1200 cells, leaving 100 live clusters (< 1300 / 2).
        list.fillCodeRange(0, 1200, GlyphCellList.spaceCode);
        expect(list.hasClusters, isTrue);
        for (var i = 0; i < 100; i++) {
          final code = list.codesView[1200 + i];
          expect(code & GlyphCellList.clusterFlag, GlyphCellList.clusterFlag);
          expect(code & GlyphCellList.payloadMask, lessThan(100));
          expect(list[1200 + i], expectedLive[i]);
        }

        // Full-range non-cluster fill clears cluster table in O(1).
        list.fillRange(0, total, ' ');
        expect(list.hasClusters, isFalse);
      },
    );

    test(
      'compacts when clusters are repeatedly overwritten with new clusters via setCodeAt',
      () {
        final list = GlyphCellList.filled(8);
        for (var i = 0; i < 1200; i++) {
          list[i % 8] = 'w$i\u0301';
        }
        expect(list.hasClusters, isTrue);
        for (var j = 0; j < 8; j++) {
          final code = list.codesView[j];
          expect(
            code & GlyphCellList.payloadMask,
            lessThan(GlyphCellList.compactionMinEntries),
          );
          expect(list[j], 'w${1192 + ((j - 1192) % 8 + 8) % 8}\u0301');
        }
      },
    );
  });

  group('Buffer, Compositor, Viewport, and Renderer integration', () {
    test(
      'Buffer clear, resize, writeString, and ANSI round-trip preserve clusters',
      () {
        final buf = Buffer(8, 2);
        buf.writeString(0, 0, 'A\x00B', const Style());
        expect(buf.getCharacter(0, 0), 'A');
        expect(buf.getCharacter(1, 0), '\x00');
        expect(buf.getCharacter(2, 0), 'B');
        expect(
          buf.glyphCodes[1] & GlyphCellList.clusterFlag,
          GlyphCellList.clusterFlag,
        );

        buf.writeString(0, 1, '👨‍👩‍👧Z', const Style());
        expect(buf.getCharacter(0, 1), '👨‍👩‍👧');
        expect(buf.getCharacter(1, 1), '');
        expect(buf.getCharacter(2, 1), 'Z');

        // Resize shrinks height to drop row 1 cluster, then clears cleanly.
        buf.resize(4, 1);
        expect(buf.getCharacter(1, 0), '\x00');
        expect(buf.glyphCellList.hasClusters, isTrue);

        buf.clear();
        expect(buf.glyphCellList.hasClusters, isFalse);

        // ANSI serialization skips wide continuations and preserves clusters.
        final wideBuf = Buffer.blank(6, 1);
        wideBuf.writeString(0, 0, '中👨‍👩‍👧', const Style());
        final ansi = wideBuf.toAnsiString();
        final reparsed = BufferAnsiSerialization.fromAnsi(
          ansi,
          width: 6,
          height: 1,
        );
        expect(reparsed.getCharacter(0, 0), '中');
        expect(reparsed.getCharacter(1, 0), '');
        expect(reparsed.getCharacter(2, 0), '👨‍👩‍👧');
        expect(reparsed.getCharacter(3, 0), '');
      },
    );

    test(
      'Compositor preserves and remaps clusters across layers and effect buffers',
      () {
        final bottom = Buffer(6, 1);
        bottom.writeString(0, 0, '👨‍👩‍👧', const Style());
        bottom.addEffect(
          RegisteredEffect(const _NoOpEffect(), const Rect(0, 0, 6, 1), 0, 0),
        );

        final top = Buffer(6, 1);
        top.writeString(2, 0, '⏭️', const Style());

        final target = Buffer(6, 1);
        // Pre-populate a different cluster in target so cluster IDs differ.
        target.setCharacter(5, 0, '👩🏽‍💻');

        final compositor = Compositor();
        compositor.composite(
          target: target,
          layers: [
            LayeredBuffer(buffer: bottom, x: 0, y: 0, zIndex: 0),
            LayeredBuffer(buffer: top, x: 0, y: 0, zIndex: 1),
          ],
        );

        expect(target.getCharacter(0, 0), '👨‍👩‍👧');
        expect(target.getCharacter(1, 0), '');
        expect(target.getCharacter(2, 0), '⏭️');
        expect(target.getCharacter(3, 0), '');
      },
    );

    test('Viewport throws UnsupportedError for flat glyph access', () {
      final parent = Buffer(10, 5);
      final vp = Viewport(parent, const Rect(1, 1, 4, 2));
      expect(() => vp.glyphCodes, throwsUnsupportedError);
      expect(() => vp.glyphCellList, throwsUnsupportedError);
      expect(() => vp.characters, throwsUnsupportedError);
      expect(() => vp.characters = <String>[], throwsUnsupportedError);
    });

    test('Renderer diffs scalar and cluster cells accurately across mismatched IDs', () {
      final renderer = Renderer(6, 2);
      final back = Buffer(6, 2);

      // First render primes frontBuffer with '👨‍👩‍👧' at cluster ID 0.
      back.writeString(0, 0, '┌─┐', const Style());
      back.writeString(0, 1, '👨‍👩‍👧', const Style());
      final firstOut = StringBuffer();
      renderer.render(back, firstOut);
      expect(firstOut.isNotEmpty, isTrue);

      // Create a fresh back buffer where '👩🏽‍💻' takes cluster ID 0 and '👨‍👩‍👧' takes ID 1.
      final back2 = Buffer(6, 2);
      back2.writeString(0, 0, '┌─┐', const Style());
      back2.writeString(3, 0, '👩🏽‍💻', const Style());
      back2.writeString(0, 1, '👨‍👩‍👧', const Style());

      final diffOut = StringBuffer();
      renderer.render(back2, diffOut);
      final diffStr = diffOut.toString();
      // Only '👩🏽‍💻' at (3, 0) changed; '👨‍👩‍👧' at (0, 1) must NOT re-emit despite different ID.
      expect(diffStr, contains('👩🏽‍💻'));
      expect(diffStr, isNot(contains('👨‍👩‍👧')));
      expect(diffStr, isNot(contains('┌')));

      // Now overwrite (3, 0) with a DIFFERENT cluster sharing local ID 0 in a new buffer.
      final back3 = Buffer(6, 2);
      back3.writeString(0, 0, '┌─┐', const Style());
      back3.writeString(3, 0, '⏭️', const Style());
      back3.writeString(0, 1, '👨‍👩‍👧', const Style());
      final diffOut2 = StringBuffer();
      renderer.render(back3, diffOut2);
      expect(diffOut2.toString(), contains('⏭️'));
      expect(diffOut2.toString(), isNot(contains('👨‍👩‍👧')));

      // Switching back to scalar at (3, 0) detects scalar vs cluster difference.
      back3.writeString(3, 0, 'A ', const Style());
      final diffOut3 = StringBuffer();
      renderer.render(back3, diffOut3);
      expect(diffOut3.toString(), contains('A'));
    });
  });
}
