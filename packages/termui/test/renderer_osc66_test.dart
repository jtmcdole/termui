import 'package:termui/termui.dart';
import 'package:test/test.dart';

/// Writes a Kitty Text Sizing (`OSC 66`) block (anchor + continuation cells)
/// into [buf] at ([x], [y]).
void _writeOsc66Box(
  Buffer buf,
  int x,
  int y,
  String char, {
  required int scale,
  int explicitWidth = 0,
  int numerator = 0,
  int denominator = 0,
  int vAlign = 0,
  int hAlign = 0,
  int fg = 0,
  int bg = 0,
  int modifiers = Modifier.none,
  String? uri,
}) {
  final baseWidth = explicitWidth > 0
      ? explicitWidth
      : (isWideGrapheme(char) ? 2 : 1);
  final cols = scale * baseWidth;
  final rows = scale;
  for (var dy = 0; dy < rows; dy++) {
    for (var dx = 0; dx < cols; dx++) {
      final bx = x + dx;
      final by = y + dy;
      if (bx >= buf.width || by >= buf.height) continue;
      final isCont = dx != 0 || dy != 0;
      buf.setCell(bx, by, isCont ? ' ' : char, fg, bg, modifiers, blend: false);
      if (uri != null) {
        buf.setUri(bx, by, uri);
      }
      buf.setTextSizing(
        bx,
        by,
        KittyTextSizing.pack(
          scale: scale,
          explicitWidth: explicitWidth,
          numerator: numerator,
          denominator: denominator,
          vAlign: vAlign,
          hAlign: hAlign,
          isContinuation: isCont,
          originDx: dx,
          originDy: dy,
        ).bits,
      );
    }
  }
}

void main() {
  group('Renderer OSC 66 text sizing serialization', () {
    test(
      'emits OSC 66 for s=2 anchor, skips continuations without overwriting footprint',
      () {
        final renderer = Renderer(4, 2);
        final back = Buffer.blank(4, 2);
        _writeOsc66Box(back, 0, 0, 'H', scale: 2);
        back
          ..setCell(2, 0, 'X', 0, 0, Modifier.none, blend: false)
          ..setCell(3, 0, 'x', 0, 0, Modifier.none, blend: false)
          ..setCell(2, 1, 'Y', 0, 0, Modifier.none, blend: false)
          ..setCell(3, 1, 'y', 0, 0, Modifier.none, blend: false);

        final out = StringBuffer();
        renderer.render(back, out);

        // First frame clears screen, writes OSC 66 'H' at (0,0) which advances
        // cursor by 2 directly to col 2 for 'Xx', skips continuations at
        // (1,0), (0,1), (1,1), and jumps directly to (2,1) for 'Yy'.
        expect(
          out.toString(),
          equals('\x1b[2J\x1b[H\x1b[1;1H\x1b]66;s=2;H\x1b\\Xx\x1b[2;3HYy'),
        );

        // Front buffer records anchor and all continuation metadata.
        expect(renderer.frontBuffer.hasTextSizing, isTrue);
        expect(
          KittyTextSizing(renderer.frontBuffer.getTextSizing(0, 0)).isAnchor,
          isTrue,
        );
        expect(
          KittyTextSizing(
            renderer.frontBuffer.getTextSizing(1, 0),
          ).isContinuation,
          isTrue,
        );
        expect(
          KittyTextSizing(
            renderer.frontBuffer.getTextSizing(0, 1),
          ).isContinuation,
          isTrue,
        );
        expect(
          KittyTextSizing(
            renderer.frontBuffer.getTextSizing(1, 1),
          ).isContinuation,
          isTrue,
        );
        expect(
          renderer.frontBuffer.getTextSizing(2, 0),
          equals(KittyTextSizing.none),
        );
      },
    );

    test(
      'emits consecutive styled OSC 66 headline anchors without redundant CUP or spaces',
      () {
        final renderer = Renderer(6, 2);
        final back = Buffer.blank(6, 2);
        const fg = 0xFF00FF88;
        _writeOsc66Box(
          back,
          0,
          0,
          'H',
          scale: 2,
          fg: fg,
          modifiers: Modifier.bold,
        );
        _writeOsc66Box(
          back,
          2,
          0,
          'I',
          scale: 2,
          fg: fg,
          modifiers: Modifier.bold,
        );
        back
          ..setCell(4, 0, '!', 0, 0, Modifier.none, blend: false)
          ..setCell(5, 0, '.', 0, 0, Modifier.none, blend: false)
          ..setCell(4, 1, 'a', 0, 0, Modifier.none, blend: false)
          ..setCell(5, 1, 'b', 0, 0, Modifier.none, blend: false);

        final out = StringBuffer();
        renderer.render(back, out);

        expect(
          out.toString(),
          equals(
            '\x1b[2J\x1b[H'
            '\x1b[1;1H\x1b[38;2;0;255;136;1m'
            '\x1b]66;s=2;H\x1b\\'
            '\x1b]66;s=2;I\x1b\\'
            '\x1b[0m!.'
            '\x1b[2;5Hab',
          ),
        );
      },
    );

    test(
      'emits exact fractional, alignment, explicit width, and wide-grapheme metadata',
      () {
        final renderer = Renderer(10, 2);
        final back = Buffer.blank(10, 2);

        // Fractional s=1, n=1, d=2, v=1, h=2 at (0, 0).
        _writeOsc66Box(
          back,
          0,
          0,
          'f',
          scale: 1,
          numerator: 1,
          denominator: 2,
          vAlign: 1,
          hAlign: 2,
        );

        // Explicit width w=2, s=2, n=3, d=4, v=2, h=1 at (1, 0) -> cols 1..4.
        _writeOsc66Box(
          back,
          1,
          0,
          'W',
          scale: 2,
          explicitWidth: 2,
          numerator: 3,
          denominator: 4,
          vAlign: 2,
          hAlign: 1,
        );

        // Wide grapheme with explicitWidth == 0, s=2 at (5, 0) -> cols 5..8.
        _writeOsc66Box(back, 5, 0, '漢', scale: 2);

        // Normal cell at (9, 0) and (0, 1) and (9, 1).
        back
          ..setCell(9, 0, 'Z', 0, 0, Modifier.none, blend: false)
          ..setCell(0, 1, 'L', 0, 0, Modifier.none, blend: false)
          ..setCell(9, 1, 'R', 0, 0, Modifier.none, blend: false);

        final out = StringBuffer();
        renderer.render(back, out);

        expect(
          out.toString(),
          equals(
            '\x1b[2J\x1b[H'
            '\x1b[1;1H'
            '\x1b]66;s=1:n=1:d=2:v=1:h=2;f\x1b\\'
            '\x1b]66;s=2:w=2:n=3:d=4:v=2:h=1;W\x1b\\'
            '\x1b]66;s=2;漢\x1b\\'
            'Z'
            '\x1b[2;1HL'
            '\x1b[2;10HR',
          ),
        );
      },
    );

    test(
      'omits invalid fractions and sanitizes control characters in OSC 66 payload',
      () {
        final renderer = Renderer(4, 1);
        final back = Buffer.blank(4, 1);

        // Invalid fraction (n=0, d=4) must omit n=/d=.
        back
          ..setCell(0, 0, 'A', 0, 0, Modifier.none, blend: false)
          ..setTextSizing(
            0,
            0,
            KittyTextSizing.pack(scale: 1, numerator: 0, denominator: 4).bits,
          );
        // Invalid fraction (n=3, d=2 where d <= n) must omit n=/d=.
        back
          ..setCell(1, 0, 'B', 0, 0, Modifier.none, blend: false)
          ..setTextSizing(
            1,
            0,
            KittyTextSizing.pack(scale: 1, numerator: 3, denominator: 2).bits,
          );
        // Control char payload gets sanitized to a safe space so framing holds.
        back
          ..setCell(2, 0, '\x1b', 0, 0, Modifier.none, blend: false)
          ..setTextSizing(2, 0, KittyTextSizing.pack(scale: 1).bits);
        back.setCell(3, 0, 'C', 0, 0, Modifier.none, blend: false);

        final out = StringBuffer();
        renderer.render(back, out);

        expect(
          out.toString(),
          equals(
            '\x1b[2J\x1b[H'
            '\x1b[1;1H'
            '\x1b]66;s=1;A\x1b\\'
            '\x1b]66;s=1;B\x1b\\'
            '\x1b]66;s=1; \x1b\\'
            'C',
          ),
        );
      },
    );

    test(
      'diffing: unchanged frame emits empty diff, textSizing-only change re-emits, clearing overwrites cleanly',
      () {
        final renderer = Renderer(4, 2);
        final back = Buffer.blank(4, 2);
        _writeOsc66Box(back, 0, 0, 'H', scale: 2);
        back
          ..setCell(2, 0, 'A', 0, 0, Modifier.none, blend: false)
          ..setCell(3, 0, 'B', 0, 0, Modifier.none, blend: false)
          ..setCell(2, 1, 'C', 0, 0, Modifier.none, blend: false)
          ..setCell(3, 1, 'D', 0, 0, Modifier.none, blend: false);

        // Frame 1: initial render.
        final f1 = StringBuffer();
        renderer.render(back, f1);
        expect(f1.toString(), contains('\x1b]66;s=2;H\x1b\\'));

        // Frame 2: identical buffer emits empty diff.
        final f2 = StringBuffer();
        renderer.render(back, f2);
        expect(f2.toString(), isEmpty);

        // Frame 3: change ONLY KittyTextSizing metadata (same glyph 'H').
        _writeOsc66Box(
          back,
          0,
          0,
          'H',
          scale: 2,
          numerator: 1,
          denominator: 2,
          vAlign: 2,
        );
        final f3 = StringBuffer();
        renderer.render(back, f3);
        expect(
          f3.toString(),
          equals('\x1b[1;1H\x1b]66;s=2:n=1:d=2:v=2;H\x1b\\'),
        );

        // Frame 4: unchanged again -> empty diff.
        final f4 = StringBuffer();
        renderer.render(back, f4);
        expect(f4.toString(), isEmpty);

        // Frame 5: clear OSC 66 region back to plain text (ts == 0).
        back
          ..clearRect(const Rect(0, 0, 2, 2))
          ..setCell(0, 0, 'p', 0, 0, Modifier.none, blend: false)
          ..setCell(1, 0, 'q', 0, 0, Modifier.none, blend: false)
          ..setCell(0, 1, 'r', 0, 0, Modifier.none, blend: false)
          ..setCell(1, 1, 's', 0, 0, Modifier.none, blend: false);
        final f5 = StringBuffer();
        renderer.render(back, f5);
        expect(f5.toString(), equals('\x1b[1;1Hpq\x1b[2;1Hrs'));
        expect(
          renderer.frontBuffer.getTextSizing(0, 0),
          equals(KittyTextSizing.none),
        );
        expect(
          renderer.frontBuffer.getTextSizing(1, 0),
          equals(KittyTextSizing.none),
        );
        expect(
          renderer.frontBuffer.getTextSizing(0, 1),
          equals(KittyTextSizing.none),
        );
        expect(
          renderer.frontBuffer.getTextSizing(1, 1),
          equals(KittyTextSizing.none),
        );

        // Frame 6: unchanged plain text -> empty diff.
        final f6 = StringBuffer();
        renderer.render(back, f6);
        expect(f6.toString(), isEmpty);
      },
    );

    test(
      'clearing to a fresh buffer without hasTextSizing overwrites all scaled footprint cells',
      () {
        final renderer = Renderer(4, 2);
        final scaled = Buffer.blank(4, 2);
        _writeOsc66Box(scaled, 0, 0, 'H', scale: 2);

        renderer.render(scaled, StringBuffer());

        // Brand-new blank buffer has hasTextSizing == false, same space glyph
        // at continuation cells (1,0), (0,1), (1,1).
        final plain = Buffer.blank(4, 2);
        expect(plain.hasTextSizing, isFalse);

        final diff = StringBuffer();
        renderer.render(plain, diff);

        // All 4 cells of the former 2x2 footprint must be overwritten with
        // plain spaces so no stale scaled cells remain.
        expect(diff.toString(), equals('\x1b[1;1H  \x1b[2;1H  '));
        expect(
          renderer.frontBuffer.getTextSizing(0, 0),
          equals(KittyTextSizing.none),
        );
        expect(
          renderer.frontBuffer.getTextSizing(1, 1),
          equals(KittyTextSizing.none),
        );

        final next = StringBuffer();
        renderer.render(plain, next);
        expect(next.toString(), isEmpty);
      },
    );

    test(
      'handles partial-row continuation updates, shrinking scale, and overlapping normal cells accurately',
      () {
        final renderer = Renderer(5, 3);
        final back = Buffer.blank(5, 3);
        _writeOsc66Box(back, 0, 0, 'A', scale: 3);
        back.setCell(4, 1, 'k', 0, 0, Modifier.none, blend: false);
        renderer.render(back, StringBuffer());

        // Shrink s=3 (3x3) at (0,0) to s=2 (2x2), freeing col 2 and row 2.
        back.clearRect(const Rect(0, 0, 3, 3));
        _writeOsc66Box(back, 0, 0, 'A', scale: 2);
        final shrinkOut = StringBuffer();
        renderer.render(back, shrinkOut);
        expect(
          shrinkOut.toString(),
          equals(
            '\x1b[1;1H\x1b]66;s=2;A\x1b\\ '
            '\x1b[2;3H '
            '\x1b[3;1H   ',
          ),
        );

        // Partial-row update: modify a continuation cell on row 1 AND a normal
        // cell after it without changing the anchor at (0, 0).
        back
          ..setCell(1, 1, ' ', 0xFFFF0000, 0, Modifier.none, blend: false)
          ..setTextSizing(
            1,
            1,
            KittyTextSizing.pack(
              scale: 2,
              isContinuation: true,
              originDx: 1,
              originDy: 1,
            ).bits,
          )
          ..setCell(2, 1, 'Z', 0, 0, Modifier.none, blend: false);
        final partialOut = StringBuffer();
        renderer.render(back, partialOut);
        // Continuation cell (1,1) is synced silently; cursor jumps directly to (2,1).
        expect(partialOut.toString(), equals('\x1b[2;3HZ'));

        // Overlapping normal cell inside an anchor's horizontal footprint
        // repositions cursor explicitly from rx + advance back to rx + 1.
        final overlapRenderer = Renderer(4, 2);
        final overlapBuf = Buffer.blank(4, 2);
        _writeOsc66Box(overlapBuf, 0, 0, 'M', scale: 2);
        overlapBuf.setCell(1, 0, 'X', 0, 0, Modifier.none, blend: false);
        overlapBuf.setTextSizing(1, 0, KittyTextSizing.none);
        final overlapOut = StringBuffer();
        overlapRenderer.render(overlapBuf, overlapOut);
        expect(
          overlapOut.toString(),
          contains('\x1b[1;1H\x1b]66;s=2;M\x1b\\\x1b[1;2HX'),
        );
      },
    );

    test(
      'inline mode tracks relative cursor position across OSC 66 anchors and continuations',
      () {
        final renderer = Renderer(4, 2, mode: RenderingMode.inline);
        final back = Buffer.blank(4, 2);
        _writeOsc66Box(back, 0, 0, 'H', scale: 2);
        back
          ..setCell(2, 0, 'A', 0, 0, Modifier.none, blend: false)
          ..setCell(3, 0, 'B', 0, 0, Modifier.none, blend: false)
          ..setCell(2, 1, 'C', 0, 0, Modifier.none, blend: false)
          ..setCell(3, 1, 'D', 0, 0, Modifier.none, blend: false);

        final f1 = StringBuffer();
        renderer.render(back, f1);
        expect(
          f1.toString(),
          equals(
            '\n\r'
            '\x1b]66;s=2;H\x1b\\AB'
            '\n\r\x1b[2CCD'
            '\n\r',
          ),
        );

        // Diff frame: change only (3, 1) -> 'E'.
        back.setCell(3, 1, 'E', 0, 0, Modifier.none, blend: false);
        final f2 = StringBuffer();
        renderer.render(back, f2);
        expect(f2.toString(), equals('\x1b[2F\n\r\x1b[3CE\n\r'));
      },
    );

    test('combines OSC 8 hyperlink with OSC 66 anchor cleanly', () {
      final renderer = Renderer(4, 2);
      final back = Buffer.blank(4, 2);
      _writeOsc66Box(back, 0, 0, 'L', scale: 2, uri: 'https://example.com');
      back
        ..setCell(2, 0, 'x', 0, 0, Modifier.none, blend: false)
        ..setCell(3, 0, 'y', 0, 0, Modifier.none, blend: false);

      final out = StringBuffer();
      renderer.render(back, out);

      expect(
        out.toString(),
        contains(
          '\x1b[1;1H\x1b]8;;https://example.com\x1b\\'
          '\x1b]66;s=2;L\x1b\\'
          '\x1b]8;;\x1b\\xy',
        ),
      );
    });

    test(
      'standard buffers without text sizing emit identical output and never allocate _textSizing',
      () {
        final renderer = Renderer(5, 2);
        final back = Buffer.blank(5, 2);
        back
          ..writeString(0, 0, 'HELLO', Style.empty)
          ..writeString(0, 1, 'WORLD', Style.empty);

        final f1 = StringBuffer();
        renderer.render(back, f1);
        expect(
          f1.toString(),
          equals('\x1b[2J\x1b[H\x1b[1;1HHELLO\x1b[2;1HWORLD'),
        );
        expect(back.hasTextSizing, isFalse);
        expect(renderer.frontBuffer.hasTextSizing, isFalse);

        final f2 = StringBuffer();
        renderer.render(back, f2);
        expect(f2.toString(), isEmpty);

        back.writeString(2, 0, 'X', Style.empty);
        final f3 = StringBuffer();
        renderer.render(back, f3);
        expect(f3.toString(), equals('\x1b[1;3HX'));
        expect(renderer.frontBuffer.hasTextSizing, isFalse);
      },
    );
  });
}
