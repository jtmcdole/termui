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
}
