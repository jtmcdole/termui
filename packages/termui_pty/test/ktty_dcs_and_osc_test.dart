import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:test/test.dart';

String _hexEncode(String input) {
  final sb = StringBuffer();
  for (final b in utf8.encode(input)) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

String _hexDecode(String hex) {
  final bytes = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return utf8.decode(bytes);
}

final class _FakeRoutedPtyBackend implements RoutedPtyBackend {
  final StreamController<Uint8List> _controller = StreamController<Uint8List>();
  final Completer<int> _exitCompleter = Completer<int>();
  final List<Uint8List> written = [];

  @override
  Stream<Uint8List> get output => _controller.stream;

  @override
  Future<int> get exitCode => _exitCompleter.future;

  @override
  void write(Uint8List bytes) => written.add(Uint8List.fromList(bytes));

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}

  @override
  void kill() {
    if (!_exitCompleter.isCompleted) _exitCompleter.complete(0);
  }

  @override
  Future<void> dispose() async {
    kill();
    if (!_controller.isClosed) await _controller.close();
  }
}

void main() {
  group('DCS XTGETTCAP', () {
    test('replies with hex-encoded values for all 13 supported caps', () {
      final replies = <String>[];
      final vt = VirtualTerminal(onReply: replies.add);

      const supportedCaps = [
        'TN',
        'name',
        'RGB',
        'Tc',
        'Smulx',
        'Setulc',
        'Sync',
        'Su',
        'colors',
        'Co',
        'setrgbf',
        'setrgbb',
        'Ms',
      ];
      final query = supportedCaps.map(_hexEncode).join(';');
      vt.writeString('\x1bP+q$query\x1b\\');

      expect(replies, hasLength(supportedCaps.length));
      for (var i = 0; i < supportedCaps.length; i++) {
        final expectedHexName = _hexEncode(supportedCaps[i]);
        final reply = replies[i];
        expect(reply, startsWith('\x1bP1+r$expectedHexName='));
        expect(reply, endsWith('\x1b\\'));
        final eqIdx = reply.indexOf('=');
        final hexVal = reply.substring(eqIdx + 1, reply.length - 2);
        expect(hexVal, isNotEmpty);
        expect(hexVal.length.isEven, isTrue);
        final decoded = _hexDecode(hexVal);
        expect(decoded, isNotEmpty);
      }

      // Spot-check key decoded terminfo values.
      final byCap = <String, String>{};
      for (final reply in replies) {
        final inner = reply.substring(5, reply.length - 2);
        final eq = inner.indexOf('=');
        byCap[_hexDecode(inner.substring(0, eq))] = _hexDecode(
          inner.substring(eq + 1),
        );
      }
      expect(byCap['TN'], equals('xterm-256color'));
      expect(byCap['name'], equals('xterm-256color'));
      expect(byCap['RGB'], equals('8/8/8'));
      expect(byCap['colors'], equals('256'));
      expect(byCap['Co'], equals('256'));
      expect(byCap['Smulx'], contains('4:'));
      expect(byCap['Setulc'], contains('58:2:'));
      expect(byCap['Ms'], contains('52;'));
    });

    test('replies 0+r for unknown caps and invalid hex, preserving casing', () {
      final replies = <String>[];
      final vt = VirtualTerminal(onReply: replies.add);

      final unknownHex = _hexEncode('nope_cap');
      vt.writeString('\x1bP+q544E;$unknownHex;ZZZ;123\x1b\\');

      expect(replies, hasLength(4));
      expect(replies[0], startsWith('\x1bP1+r544E='));
      expect(replies[1], equals('\x1bP0+r$unknownHex\x1b\\'));
      // Invalid hex tokens must never be reflected in replies.
      expect(replies[2], equals('\x1bP0+r\x1b\\'));
      expect(replies[3], equals('\x1bP0+r\x1b\\'));
    });

    test(
      'B1 security: never reflects control chars from invalid XTGETTCAP token',
      () {
        final replies = <String>[];
        final vt = VirtualTerminal(onReply: replies.add);

        vt.writeString('\x1bP+q\x15id\r\x1b\\');
        expect(replies, equals(['\x1bP0+r\x1b\\']));
        expect(replies.single.contains('id'), isFalse);
        expect(replies.single.contains('\x15'), isFalse);
        expect(replies.single.contains('\r'), isFalse);
      },
    );

    test('caps XTGETTCAP bursts at 64 queries and ignores empty +q', () {
      final replies = <String>[];
      final vt = VirtualTerminal(onReply: replies.add);

      vt.writeString('\x1bP+q\x1b\\');
      expect(replies, isEmpty);

      final burst = List<String>.filled(70, _hexEncode('RGB')).join(';');
      vt.writeString('\x1bP+q$burst\x1b\\');
      expect(replies, hasLength(64));
    });
  });

  group('DCS DECRQSS', () {
    test('reports active SGR state and round-trips complex attributes', () {
      final replies = <String>[];
      final vt = VirtualTerminal(onReply: replies.add);

      // Default SGR
      vt.writeString('\x1bP\$qm\x1b\\');
      expect(replies.removeLast(), equals('\x1bP1\$r0m\x1b\\'));

      // Complex SGR: bold, italic, curly underline, overline, truecolor fg,
      // 256-color bg, truecolor underline color.
      vt.writeString(
        '\x1b[1;3;4:3;53;38;2;12;34;56;48;5;200;58;2;255;0;128m\x1bP\$qm\x1b\\',
      );
      final sgrReply = replies.removeLast();
      expect(sgrReply, startsWith('\x1bP1\$r0;'));
      expect(sgrReply, endsWith('m\x1b\\'));

      final sgrBody = sgrReply.substring(5, sgrReply.length - 2);
      final vt2 = VirtualTerminal();
      vt2.writeString('\x1b[${sgrBody}A');
      vt.writeString('A');

      expect(
        vt2.buffer.cellsEqual(0, 0, vt.buffer, 0, 0),
        isTrue,
        reason: 'DECRQSS SGR reply ($sgrBody) must round-trip cell attributes',
      );
    });

    test('reports DECSCUSR cursor shape and DECSTBM scroll region', () {
      final replies = <String>[];
      final vt = VirtualTerminal(width: 80, height: 24, onReply: replies.add);

      vt.writeString('\x1bP\$q q\x1b\\\x1bP\$qr\x1b\\');
      expect(replies, equals(['\x1bP1\$r0 q\x1b\\', '\x1bP1\$r1;24r\x1b\\']));
      replies.clear();

      vt.writeString('\x1b[5 q\x1b[3;10r\x1bP\$q q\x1b\\\x1bP\$qr\x1b\\');
      expect(replies, equals(['\x1bP1\$r5 q\x1b\\', '\x1bP1\$r3;10r\x1b\\']));
    });

    test('replies 0\$r for unknown DECRQSS queries', () {
      final replies = <String>[];
      final vt = VirtualTerminal(onReply: replies.add);

      vt.writeString('\x1bP\$qz\x1b\\\x1bP\$q\x1b\\');
      expect(replies, equals(['\x1bP0\$r\x1b\\', '\x1bP0\$r\x1b\\']));
    });
  });

  group('Color Stack (OSC 30001/30101 and CSI # P/Q)', () {
    test('pushes and pops OSC 4/10/11/12 overrides across OSC and CSI', () {
      final replies = <String>[];
      var notifications = 0;
      final vt = VirtualTerminal(onReply: replies.add)
        ..addListener(() => notifications++);

      // Set initial overrides.
      vt.writeString(
        '\x1b]4;1;#112233\x1b\\'
        '\x1b]10;#aabbcc\x1b\\'
        '\x1b]11;#010203\x1b\\'
        '\x1b]12;#445566\x1b\\',
      );
      // Push via OSC 30001.
      vt.writeString('\x1b]30001;\x1b\\');
      // Overwrite colors.
      vt.writeString(
        '\x1b]4;1;#ff0000\x1b\\'
        '\x1b]10;#00ff00\x1b\\'
        '\x1b]11;#0000ff\x1b\\'
        '\x1b]12;#ffffff\x1b\\',
      );
      // Push second level via CSI # P.
      vt.writeString('\x1b[#P');
      // Reset all overrides.
      vt.writeString(
        '\x1b]104\x1b\\\x1b]110\x1b\\\x1b]111\x1b\\\x1b]112\x1b\\',
      );

      final beforePop = notifications;
      // Pop second level via OSC 30101.
      vt.writeString('\x1b]30101;\x1b\\');
      expect(notifications, greaterThan(beforePop));

      vt.writeString(
        '\x1b]4;1;?\x1b\\\x1b]10;?\x1b\\\x1b]11;?\x1b\\\x1b]12;?\x1b\\',
      );
      expect(
        replies,
        equals([
          '\x1b]4;1;rgb:ffff/0000/0000\x1b\\',
          '\x1b]10;rgb:0000/ffff/0000\x1b\\',
          '\x1b]11;rgb:0000/0000/ffff\x1b\\',
          '\x1b]12;rgb:ffff/ffff/ffff\x1b\\',
        ]),
      );
      replies.clear();

      // Pop first level via CSI # Q.
      vt.writeString('\x1b[#Q');
      vt.writeString(
        '\x1b]4;1;?\x1b\\\x1b]10;?\x1b\\\x1b]11;?\x1b\\\x1b]12;?\x1b\\',
      );
      expect(
        replies,
        equals([
          '\x1b]4;1;rgb:1111/2222/3333\x1b\\',
          '\x1b]10;rgb:aaaa/bbbb/cccc\x1b\\',
          '\x1b]11;rgb:0101/0202/0303\x1b\\',
          '\x1b]12;rgb:4444/5555/6666\x1b\\',
        ]),
      );
    });

    test('bounds depth to 10 (evicting oldest) and clears on reset/RIS', () {
      final replies = <String>[];
      final vt = VirtualTerminal(onReply: replies.add);

      // Push 12 distinct states (0..11); oldest 2 (0, 1) must be evicted.
      for (var i = 0; i < 12; i++) {
        final hex = i.toRadixString(16).padLeft(2, '0');
        vt.writeString('\x1b]10;#$hex$hex$hex\x1b\\\x1b]30001;\x1b\\');
      }
      vt.writeString('\x1b]10;#fefefe\x1b\\');

      final popped = <String>[];
      for (var i = 0; i < 11; i++) {
        vt.writeString('\x1b]30101;\x1b\\\x1b]10;?\x1b\\');
        popped.add(replies.removeLast());
      }
      // First 10 pops restore states 11 down to 2; 11th pop is a no-op (stays 2).
      expect(popped[0], equals('\x1b]10;rgb:0b0b/0b0b/0b0b\x1b\\'));
      expect(popped[9], equals('\x1b]10;rgb:0202/0202/0202\x1b\\'));
      expect(popped[10], equals('\x1b]10;rgb:0202/0202/0202\x1b\\'));

      // Push then RIS (\x1bc) must clear the stack.
      vt.writeString(
        '\x1b]10;#123456\x1b\\\x1b]30001;\x1b\\\x1bc\x1b]30101;\x1b\\',
      );
      vt.writeString('\x1b]10;?\x1b\\');
      expect(replies.removeLast(), equals('\x1b]10;rgb:ffff/ffff/ffff\x1b\\'));

      // Push then reset() must also clear the stack.
      vt.writeString('\x1b]10;#654321\x1b\\\x1b[#P');
      vt.reset();
      vt.writeString('\x1b[#Q\x1b]10;?\x1b\\');
      expect(replies.removeLast(), equals('\x1b]10;rgb:ffff/ffff/ffff\x1b\\'));
    });
  });

  group('OSC 66 Kitty Text Sizing', () {
    test('packs anchor and continuation cells and advances CPR cursor', () {
      final replies = <String>[];
      final vt = VirtualTerminal(width: 80, height: 10, onReply: replies.add);

      // Official Kitty CPR detection probe: w=2 then s=2.
      vt.writeString(
        '\r\x1b[6n'
        '\x1b]66;w=2; \x1b\\\x1b[6n'
        '\x1b]66;s=2; \x1b\\\x1b[6n',
      );
      expect(replies, equals(['\x1b[1;1R', '\x1b[1;3R', '\x1b[1;5R']));

      final w2Anchor = KittyTextSizing(vt.buffer.getTextSizing(0, 0));
      expect(w2Anchor.isAnchor, isTrue);
      expect(w2Anchor.scale, equals(1));
      expect(w2Anchor.explicitWidth, equals(2));
      expect(w2Anchor.boxCols, equals(2));
      expect(w2Anchor.boxRows, equals(1));

      final w2Cont = KittyTextSizing(vt.buffer.getTextSizing(1, 0));
      expect(w2Cont.isContinuation, isTrue);
      expect(w2Cont.originDx, equals(1));
      expect(w2Cont.originDy, equals(0));

      final s2Anchor = KittyTextSizing(vt.buffer.getTextSizing(2, 0));
      expect(s2Anchor.isAnchor, isTrue);
      expect(s2Anchor.scale, equals(2));
      expect(s2Anchor.explicitWidth, equals(0));
      expect(s2Anchor.boxCols, equals(2));
      expect(s2Anchor.boxRows, equals(2));

      final s2Corner = KittyTextSizing(vt.buffer.getTextSizing(3, 1));
      expect(s2Corner.isContinuation, isTrue);
      expect(s2Corner.originDx, equals(1));
      expect(s2Corner.originDy, equals(1));
    });

    test(
      'supports fractional sizing, alignment, and max s=7,w=7 (originDx=48)',
      () {
        final vt = VirtualTerminal(width: 60, height: 12);

        // Fractional scaling + alignment.
        vt.writeString('\x1b]66;s=2:w=3:n=1:d=2:v=2:h=1;Hi\x1b\\');
        expect(vt.cursorX, equals(6));
        expect(vt.buffer.getCharacter(0, 0), equals('Hi'));
        final fracTs = KittyTextSizing(vt.buffer.getTextSizing(0, 0));
        expect(fracTs.scale, equals(2));
        expect(fracTs.explicitWidth, equals(3));
        expect(fracTs.numerator, equals(1));
        expect(fracTs.denominator, equals(2));
        expect(fracTs.fraction, closeTo(0.5, 1e-9));
        expect(fracTs.vAlign, equals(2));
        expect(fracTs.hAlign, equals(1));

        // Max box: s=7, w=7 -> 49 columns x 7 rows (originDx up to 48, originDy up to 6).
        vt.writeString('\x1b[4;1H\x1b]66;s=7:w=7;BIG\x1b\\');
        expect(vt.cursorX, equals(49));
        expect(vt.buffer.getCharacter(0, 3), equals('BIG'));
        final maxCorner = KittyTextSizing(vt.buffer.getTextSizing(48, 9));
        expect(maxCorner.isContinuation, isTrue);
        expect(maxCorner.originDx, equals(48));
        expect(maxCorner.originDy, equals(6));
        expect(maxCorner.boxCols, equals(49));
        expect(maxCorner.boxRows, equals(7));
      },
    );

    test('rejects invalid OSC 66 parameter ranges without moving cursor', () {
      final vt = VirtualTerminal(width: 40, height: 6);
      vt.writeString(
        '\x1b]66;s=0;A\x1b\\'
        '\x1b]66;s=8;A\x1b\\'
        '\x1b]66;w=8;A\x1b\\'
        '\x1b]66;s=2:n=2:d=2;A\x1b\\'
        '\x1b]66;s=2:n=3:d=2;A\x1b\\'
        '\x1b]66;s=2:n=1:d=0;A\x1b\\'
        '\x1b]66;v=3;A\x1b\\'
        '\x1b]66;h=3;A\x1b\\'
        '\x1b]66;no_semicolon\x1b\\',
      );
      expect(vt.cursorX, equals(0));
      expect(vt.cursorY, equals(0));
      expect(vt.buffer.hasTextSizing, isFalse);
    });

    test('wraps cleanly at right margin and handles wide graphemes', () {
      final vt = VirtualTerminal(width: 5, height: 6);
      // s=2 -> each ASCII char is 2x2: A at (0,0), B at (2,0), C wraps to (0,2).
      vt.writeString('\x1b]66;s=2;ABC\x1b\\');
      expect(vt.buffer.getCharacter(0, 0), equals('A'));
      expect(vt.buffer.getCharacter(2, 0), equals('B'));
      expect(vt.buffer.getCharacter(0, 2), equals('C'));
      expect(vt.cursorX, equals(2));
      expect(vt.cursorY, equals(2));

      // Wide CJK grapheme with s=2, w=0 -> 4x2 box.
      final vtWide = VirtualTerminal(width: 20, height: 6);
      vtWide.writeString('\x1b]66;s=2;漢\x1b\\');
      expect(vtWide.cursorX, equals(4));
      final ts = KittyTextSizing(vtWide.buffer.getTextSizing(3, 1));
      expect(ts.isContinuation, isTrue);
      expect(ts.originDx, equals(3));
      expect(ts.originDy, equals(1));
      expect(ts.boxCols, equals(4));
    });

    test('clears orphaned continuations on overwrite, erase, and resize', () {
      final vt = VirtualTerminal(width: 20, height: 6);
      vt.writeString('\x1b]66;s=2;Hi\x1b\\');

      // Overwrite continuation cell (1, 1) of 'H' with normal ASCII 'x'.
      vt.writeString('\x1b[2;2Hx');
      expect(vt.buffer.getCharacter(1, 1), equals('x'));
      expect(vt.buffer.getTextSizing(0, 0), equals(KittyTextSizing.none));
      expect(vt.buffer.getTextSizing(1, 0), equals(KittyTextSizing.none));
      expect(vt.buffer.getTextSizing(0, 1), equals(KittyTextSizing.none));
      expect(vt.buffer.getTextSizing(1, 1), equals(KittyTextSizing.none));
      expect(vt.buffer.getCharacter(0, 0), equals(' '));

      // Neighboring 'i' at (2,0)..(3,1) must remain intact.
      expect(vt.buffer.getCharacter(2, 0), equals('i'));
      expect(
        KittyTextSizing(vt.buffer.getTextSizing(3, 1)).isContinuation,
        isTrue,
      );

      // Erase in line on row 0 starting at col 2 clears 'i' + its row 1 continuations.
      vt.writeString('\x1b[1;3H\x1b[K');
      expect(vt.buffer.getTextSizing(2, 0), equals(KittyTextSizing.none));
      expect(vt.buffer.getTextSizing(3, 1), equals(KittyTextSizing.none));

      // Shrinking terminal width heals a clipped OSC 66 box cleanly.
      vt.writeString('\x1b[1;1H\x1b]66;s=2:w=4;Clip\x1b\\');
      expect(
        KittyTextSizing(vt.buffer.getTextSizing(7, 1)).originDx,
        equals(7),
      );
      vt.resize(5, 6);
      expect(vt.buffer.getTextSizing(0, 0), equals(KittyTextSizing.none));
      expect(vt.buffer.getTextSizing(4, 1), equals(KittyTextSizing.none));
    });

    test(
      'retains OSC 66 sizing across ScrollbackLine, renderBuffer, and TerminalView',
      () {
        final vt = VirtualTerminal(
          width: 12,
          height: 4,
          maxScrollbackLines: 20,
        );

        // Row 0..1: scaled headline; Row 2: plain text; push 3 lines into scrollback.
        vt.writeString(
          '\x1b]66;s=2;A\x1b\\\r\n\r\nplain\r\nline3\r\nline4\r\nline5\r\nline6',
        );

        // Row 0, row 1, and row 2 ('plain') were evicted to scrollback.
        expect(vt.scrollback.retainedLines, equals(3));
        final sbAnchorRow = vt.scrollback[0]!;
        final sbContRow = vt.scrollback[1]!;
        final sbPlainRow = vt.scrollback[2]!;

        // Standard line allocates zero textSizing memory.
        expect(sbPlainRow.textSizing, isNull);
        // Scaled lines retain anchor and continuation sizing without trimming spaces.
        expect(sbAnchorRow.textSizing, isNotNull);
        expect(sbContRow.textSizing, isNotNull);
        expect(KittyTextSizing(sbAnchorRow.textSizing![0]).isAnchor, isTrue);
        expect(KittyTextSizing(sbContRow.textSizing![1]).originDx, equals(1));
        expect(KittyTextSizing(sbContRow.textSizing![1]).originDy, equals(1));

        // Scroll back into history and verify renderBuffer + TerminalView preserve sizing.
        vt.viewportOffset = vt.scrollback.retainedLines;
        final rendered = vt.renderBuffer();
        expect(KittyTextSizing(rendered.getTextSizing(0, 0)).isAnchor, isTrue);
        expect(
          KittyTextSizing(rendered.getTextSizing(1, 1)).originDx,
          equals(1),
        );
        expect(
          KittyTextSizing(rendered.getTextSizing(1, 1)).originDy,
          equals(1),
        );

        // Verify TerminalView paints scrollback textSizing (opaque).
        final view = TerminalView(terminal: vt);
        final root = view.createElement();
        root.mount(null);
        root.layout(const BoxConstraints(maxWidth: 12, maxHeight: 4));
        final paintBuf = Buffer.blank(12, 4);
        root.paint(paintBuf, Offset.zero);
        expect(KittyTextSizing(paintBuf.getTextSizing(0, 0)).isAnchor, isTrue);
        expect(
          KittyTextSizing(paintBuf.getTextSizing(1, 1)).originDx,
          equals(1),
        );
        root.unmount();

        // Verify transparent TerminalView also paints scrollback textSizing.
        final tv = VirtualTerminal(
          width: 12,
          height: 4,
          maxScrollbackLines: 20,
          transparentBackground: true,
        );
        tv.writeString('\x1b]66;s=2;B\x1b\\\r\n\r\n2\r\n3\r\n4\r\n5\r\n6');
        tv.viewportOffset = tv.scrollback.retainedLines;
        final tView = TerminalView(terminal: tv);
        final tRoot = tView.createElement();
        tRoot.mount(null);
        tRoot.layout(const BoxConstraints(maxWidth: 12, maxHeight: 4));
        final tPaintBuf = Buffer.blank(12, 4);
        tPaintBuf.fillRect(const Rect(0, 0, 12, 4), char: 'Z');
        tRoot.paint(tPaintBuf, Offset.zero);
        expect(KittyTextSizing(tPaintBuf.getTextSizing(0, 0)).isAnchor, isTrue);
        expect(tPaintBuf.getCharacter(0, 0), equals('B'));
        // PR #502 H1: transparent OSC 66 continuation cells must retain
        // textSizing metadata and overwrite underlying glyphs.
        expect(
          KittyTextSizing(tPaintBuf.getTextSizing(1, 0)).isContinuation,
          isTrue,
        );
        expect(
          KittyTextSizing(tPaintBuf.getTextSizing(0, 1)).isContinuation,
          isTrue,
        );
        expect(
          KittyTextSizing(tPaintBuf.getTextSizing(1, 1)).isContinuation,
          isTrue,
        );
        expect(tPaintBuf.getCharacter(1, 1), equals(' '));
        tRoot.unmount();

        // Live transparent TerminalView + space OSC 66 also retains continuation metadata.
        final tvLive = VirtualTerminal(
          width: 8,
          height: 4,
          transparentBackground: true,
        );
        tvLive.writeString('\x1b]66;s=2; \x1b\\');
        final liveView = TerminalView(terminal: tvLive);
        final liveRoot = liveView.createElement();
        liveRoot.mount(null);
        liveRoot.layout(const BoxConstraints(maxWidth: 8, maxHeight: 4));
        final liveBuf = Buffer.blank(8, 4);
        liveBuf.fillRect(const Rect(0, 0, 8, 4), char: 'Q');
        liveRoot.paint(liveBuf, Offset.zero);
        expect(KittyTextSizing(liveBuf.getTextSizing(0, 0)).isAnchor, isTrue);
        expect(
          KittyTextSizing(liveBuf.getTextSizing(1, 1)).isContinuation,
          isTrue,
        );
        expect(liveBuf.getCharacter(1, 1), equals(' '));
        liveRoot.unmount();
      },
    );
  });

  group('OSC 5522 Kitty Clipboard', () {
    const plainMimeB64 = 'dGV4dC9wbGFpbg=='; // text/plain
    final utf8MimeB64 = base64Encode(utf8.encode('text/plain;charset=utf-8'));
    final pngMimeB64 = base64Encode(utf8.encode('image/png'));

    test('handles single-shot write for clipboard and primary selections', () {
      final replies = <String>[];
      final writes = <(String, String)>[];
      final vt = VirtualTerminal(onReply: replies.add)
        ..onClipboardWrite = (sel, text) => writes.add((sel, text));

      final helloB64 = base64Encode(utf8.encode('Hello Kitty'));
      vt.writeString(
        '\x1b]5522;type=write:mime=$plainMimeB64;$helloB64\x1b\\'
        '\x1b]5522;type=write:loc=primary:mime=$utf8MimeB64;$helloB64\x1b\\',
      );

      expect(writes, equals([('c', 'Hello Kitty'), ('p', 'Hello Kitty')]));
      expect(
        replies,
        equals([
          '\x1b]5522;type=write:status=DONE\x1b\\',
          '\x1b]5522;type=write:status=DONE\x1b\\',
        ]),
      );
    });

    test(
      'buffers chunked type=write/wdata across UTF-8 boundaries and ignores other mimes',
      () {
        final replies = <String>[];
        final writes = <(String, String)>[];
        final vt = VirtualTerminal(onReply: replies.add)
          ..onClipboardWrite = (sel, text) => writes.add((sel, text));

        // Split a 4-byte UTF-8 emoji ('🚀') across two base64 chunks.
        final fullBytes = utf8.encode('Hi 🚀!');
        final part1 = base64Encode(fullBytes.sublist(0, 5));
        final part2 = base64Encode(fullBytes.sublist(5));

        vt.writeString(
          '\x1b]5522;type=write:loc=clipboard:id=req1;\x1b\\'
          '\x1b]5522;type=wdata:mime=$pngMimeB64;iVBORw==\x1b\\'
          '\x1b]5522;type=wdata:mime=$plainMimeB64;$part1\x1b\\'
          '\x1b]5522;type=wdata;$part2\x1b\\'
          '\x1b]5522;type=wdata;\x1b\\',
        );

        expect(writes, equals([('c', 'Hi 🚀!')]));
        expect(
          replies,
          equals(['\x1b]5522;type=write:status=DONE:id=req1\x1b\\']),
        );
      },
    );

    test('replies DONE even without onClipboardWrite callback', () {
      final replies = <String>[];
      final vt = VirtualTerminal(onReply: replies.add);

      vt.writeString(
        '\x1b]5522;type=write:mime=$plainMimeB64;${base64Encode(utf8.encode('ok'))}\x1b\\',
      );
      expect(replies, equals(['\x1b]5522;type=write:status=DONE\x1b\\']));
    });

    test(
      'rejects invalid/unsupported mime, bad base64, and >64 KiB payloads with EINVAL',
      () {
        final replies = <String>[];
        final writes = <(String, String)>[];
        final vt = VirtualTerminal(onReply: replies.add)
          ..onClipboardWrite = (sel, text) => writes.add((sel, text));

        // Raw non-base64 mime, unsupported mime, invalid base64, orphan wdata.
        vt.writeString(
          '\x1b]5522;type=write:mime=text/plain;aGk=\x1b\\'
          '\x1b]5522;type=write:mime=$pngMimeB64;aGk=\x1b\\'
          '\x1b]5522;type=write:mime=$plainMimeB64;!!!invalid\x1b\\'
          '\x1b]5522;type=wdata;\x1b\\',
        );
        expect(writes, isEmpty);
        expect(
          replies,
          equals(
            List<String>.filled(4, '\x1b]5522;type=write:status=EINVAL\x1b\\'),
          ),
        );
        replies.clear();

        // Chunked payload exceeding 64 KiB cap (65537 bytes).
        final chunk32k = base64Encode(List<int>.filled(32768, 0x41));
        final extra1 = base64Encode(const [0x42]);
        vt.writeString(
          '\x1b]5522;type=write;\x1b\\'
          '\x1b]5522;type=wdata:mime=$plainMimeB64;$chunk32k\x1b\\'
          '\x1b]5522;type=wdata;$chunk32k\x1b\\'
          '\x1b]5522;type=wdata;$extra1\x1b\\'
          '\x1b]5522;type=wdata;\x1b\\',
        );
        expect(writes, isEmpty);
        expect(replies, equals(['\x1b]5522;type=write:status=EINVAL\x1b\\']));
      },
    );

    test('blocks type=read with EPERM and invokes onClipboardReadBlocked', () {
      final replies = <String>[];
      final blocked = <String>[];
      final vt = VirtualTerminal(onReply: replies.add)
        ..onClipboardReadBlocked = blocked.add;

      vt.writeString(
        '\x1b]5522;type=read;\x1b\\'
        '\x1b]5522;type=read:loc=primary:id=r2;\x1b\\',
      );

      expect(blocked, equals(['c', 'p']));
      expect(
        replies,
        equals([
          '\x1b]5522;type=read:status=EPERM\x1b\\',
          '\x1b]5522;type=read:status=EPERM:id=r2\x1b\\',
        ]),
      );
    });
  });

  group('Kitty Registry Sync, Scroll Shift & PtyRouter Options', () {
    test(
      'syncs activeAltScreen and viewportScrollOffset on KittyImageRegistry',
      () {
        final vt = VirtualTerminal(
          width: 20,
          height: 4,
          maxScrollbackLines: 20,
        );
        expect(vt.imageRegistry.activeAltScreen, isFalse);
        expect(vt.imageRegistry.viewportScrollOffset, equals(0));

        vt.writeString('1\r\n2\r\n3\r\n4\r\n5\r\n6');
        vt.scrollViewport(2);
        expect(vt.imageRegistry.viewportScrollOffset, equals(2));

        // Entering alt screen sets activeAltScreen=true and scroll offset=0.
        vt.writeString('\x1b[?1049h');
        expect(vt.imageRegistry.activeAltScreen, isTrue);
        expect(vt.imageRegistry.viewportScrollOffset, equals(0));

        vt.imageRegistry.registerPlacement(
          const KittyPlacement(
            imageId: 7,
            placementId: 1,
            isAltScreen: true,
            gridCol: 0,
            gridRow: 0,
            cols: 2,
            rows: 2,
          ),
        );
        // Exiting alt screen clears alt placements and restores primary scroll offset.
        vt.writeString('\x1b[?1049l');
        expect(vt.imageRegistry.activeAltScreen, isFalse);
        expect(vt.imageRegistry.viewportScrollOffset, equals(2));
        expect(vt.imageRegistry.lookupPlacement(7, 1), isNull);

        vt.resetViewport();
        expect(vt.imageRegistry.viewportScrollOffset, equals(0));
      },
    );

    test(
      'shifts direct non-virtual placements on scroll and evicts past scrollback',
      () {
        final vt = VirtualTerminal(width: 20, height: 4, maxScrollbackLines: 2);
        vt.imageRegistry.registerPlacement(
          const KittyPlacement(
            imageId: 10,
            placementId: 1,
            isVirtual: false,
            isAltScreen: false,
            gridCol: 1,
            gridRow: 2,
            cols: 3,
            rows: 2,
          ),
        );
        vt.imageRegistry.registerPlacement(
          const KittyPlacement(
            imageId: 11,
            placementId: 1,
            isVirtual: true,
            isAltScreen: false,
            gridCol: 1,
            gridRow: 2,
            cols: 3,
            rows: 2,
          ),
        );

        // Scroll up 3 lines: direct placement shifts from row 2 to -1 (still in scrollback).
        vt.writeString('\x1b[3S');
        expect(vt.imageRegistry.lookupPlacement(10, 1)?.gridRow, equals(-1));
        // Virtual placement does not shift.
        expect(vt.imageRegistry.lookupPlacement(11, 1)?.gridRow, equals(2));

        // Scroll up 3 more lines: direct placement shifts to -4 (bottom -2 <= -maxLines=-2) -> evicted.
        vt.writeString('\x1b[3S');
        expect(vt.imageRegistry.lookupPlacement(10, 1), isNull);
      },
    );

    test(
      'forwards allowLocalKittyMedia and allowLocalKittyFiles from PtyRouter',
      () async {
        final router = PtyRouter();
        final backendDefault = _FakeRoutedPtyBackend();
        final backendOptIn = _FakeRoutedPtyBackend();

        final defaultSession = router.createSession(
          id: 'default',
          backend: backendDefault,
        );
        expect(defaultSession.terminal.allowLocalKittyMedia, isFalse);
        expect(defaultSession.terminal.allowLocalKittyFiles, isFalse);

        final optInSession = router.createSession(
          id: 'optin',
          backend: backendOptIn,
          allowLocalKittyMedia: true,
          allowLocalKittyFiles: true,
        );
        expect(optInSession.terminal.allowLocalKittyMedia, isTrue);
        expect(optInSession.terminal.allowLocalKittyFiles, isTrue);

        await router.dispose();
      },
    );

    test(
      'M5: clamps OSC 66 to DECSTBM, cleans scroll/CSI L/M orphans, and wide edges',
      () {
        // DECSTBM clamp: rows 2..3 (0-based 1..2), protect row 4 (index 3).
        final vt = VirtualTerminal(width: 10, height: 5);
        vt.writeString('\x1b[4;1HKEEP\x1b[2;3r\x1b[2;1H\x1b]66;s=3;X\x1b\\');
        expect(vt.buffer.getCharacter(0, 3), equals('K'));
        expect(vt.buffer.getTextSizing(0, 3), equals(KittyTextSizing.none));
        expect(KittyTextSizing(vt.buffer.getTextSizing(0, 1)).isAnchor, isTrue);
        expect(
          KittyTextSizing(vt.buffer.getTextSizing(0, 2)).isContinuation,
          isTrue,
        );

        // CSI L (insert line) clears OSC 66 box clipped off bottom of scroll region.
        final vtIns = VirtualTerminal(width: 10, height: 4);
        vtIns.writeString('\x1b[3;1H\x1b]66;s=2;A\x1b\\\x1b[1;1H\x1b[L');
        expect(vtIns.buffer.getTextSizing(0, 3), equals(KittyTextSizing.none));
        expect(vtIns.buffer.getCharacter(0, 3), equals(' '));

        // CSI M (delete line) clears OSC 66 box straddling deleted top row.
        final vtDel = VirtualTerminal(width: 10, height: 4);
        vtDel.writeString('\x1b[1;1H\x1b]66;s=2;B\x1b\\\x1b[1;1H\x1b[M');
        expect(vtDel.buffer.getTextSizing(0, 0), equals(KittyTextSizing.none));
        expect(vtDel.buffer.getCharacter(0, 0), equals(' '));

        // Right-edge wide grapheme pad clears overlapping OSC 66 box cleanly.
        final vtPad = VirtualTerminal(width: 4, height: 4);
        vtPad.writeString('\x1b[1;3H\x1b]66;s=2;Z\x1b\\\x1b[1;4H漢');
        expect(vtPad.buffer.getTextSizing(2, 0), equals(KittyTextSizing.none));
        expect(vtPad.buffer.getTextSizing(3, 0), equals(KittyTextSizing.none));
        expect(vtPad.buffer.getTextSizing(2, 1), equals(KittyTextSizing.none));
        expect(vtPad.buffer.getTextSizing(3, 1), equals(KittyTextSizing.none));

        // Promoting a narrow cell to wide via VS16 clears overlapping OSC 66 box.
        final vtPromo = VirtualTerminal(width: 6, height: 4);
        vtPromo.writeString(
          '\x1b[1;2H\x1b]66;s=2;Q\x1b\\\x1b[1;1H\u2764\uFE0F',
        );
        expect(
          vtPromo.buffer.getTextSizing(1, 0),
          equals(KittyTextSizing.none),
        );
        expect(
          vtPromo.buffer.getTextSizing(2, 1),
          equals(KittyTextSizing.none),
        );
      },
    );

    test(
      'M7 & m9: deduplicates multi-MIME OSC 5522 writes and clears pending on DECSTR',
      () {
        final replies = <String>[];
        final writes = <(String, String)>[];
        final vt = VirtualTerminal(onReply: replies.add)
          ..onClipboardWrite = (sel, text) => writes.add((sel, text));

        final utf8Mime = base64Encode(utf8.encode('text/plain;charset=utf-8'));
        const plainMime = 'dGV4dC9wbGFpbg==';
        final helloB64 = base64Encode(utf8.encode('hello'));

        vt.writeString(
          '\x1b]5522;type=write;\x1b\\'
          '\x1b]5522;type=wdata:mime=$utf8Mime;$helloB64\x1b\\'
          '\x1b]5522;type=wdata:mime=$plainMime;$helloB64\x1b\\'
          '\x1b]5522;type=wdata;\x1b\\',
        );
        expect(writes, equals([('c', 'hello')]));
        expect(replies, equals(['\x1b]5522;type=write:status=DONE\x1b\\']));
        replies.clear();

        // DECSTR (\x1b[!p) clears pending OSC 5522 write.
        vt.writeString(
          '\x1b]5522;type=write;\x1b\\'
          '\x1b]5522;type=wdata:mime=$plainMime;$helloB64\x1b\\'
          '\x1b[!p'
          '\x1b]5522;type=wdata;\x1b\\',
        );
        expect(writes, hasLength(1));
        expect(replies, equals(['\x1b]5522;type=write:status=EINVAL\x1b\\']));
      },
    );

    test(
      'm9: scroll-down evicts past-bottom placements and CSI 3 J purges scrollback placements',
      () {
        final vt = VirtualTerminal(
          width: 20,
          height: 4,
          maxScrollbackLines: 10,
        );
        // Direct placement at row 3 with relative child -> scrolled down off bottom.
        vt.imageRegistry.registerPlacement(
          const KittyPlacement(
            imageId: 20,
            placementId: 1,
            gridCol: 0,
            gridRow: 3,
            cols: 2,
            rows: 1,
          ),
        );
        vt.imageRegistry.registerPlacement(
          const KittyPlacement(
            imageId: 21,
            placementId: 1,
            parentImageId: 20,
            parentPlacementId: 1,
            cols: 1,
            rows: 1,
          ),
        );
        vt.writeString('\x1b[1T');
        expect(vt.imageRegistry.lookupPlacement(20, 1), isNull);
        expect(vt.imageRegistry.lookupPlacement(21, 1), isNull);

        // Placement fully in scrollback (gridRow + rows <= 0) purged on CSI 3 J;
        // on-screen placement preserved.
        vt.imageRegistry.registerPlacement(
          const KittyPlacement(
            imageId: 30,
            placementId: 1,
            gridCol: 0,
            gridRow: -2,
            cols: 2,
            rows: 2,
          ),
        );
        vt.imageRegistry.registerPlacement(
          const KittyPlacement(
            imageId: 31,
            placementId: 1,
            gridCol: 0,
            gridRow: 1,
            cols: 2,
            rows: 1,
          ),
        );
        vt.writeString('\x1b[3J');
        expect(vt.imageRegistry.lookupPlacement(30, 1), isNull);
        expect(vt.imageRegistry.lookupPlacement(31, 1), isNotNull);
      },
    );

    test(
      'm10 & Nit 12: grapheme-safe OSC 66 truncation and full-row max height wrap',
      () {
        // m10: ZWJ emoji sequence crossing the 64 UTF-16 code unit cap must not split a cluster.
        const familyEmoji =
            '\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}'; // 8 UTF-16 units
        final longText = '${'a' * 60}$familyEmoji';
        final vtTrunc = VirtualTerminal(width: 20, height: 4);
        vtTrunc.writeString('\x1b]66;w=2;$longText\x1b\\');
        expect(vtTrunc.buffer.getCharacter(0, 0), equals('a' * 60));

        // Nit 12: s=3 glyph at col 0 followed by s=1 glyphs wraps down 3 rows, not 1.
        final vtWrap = VirtualTerminal(width: 5, height: 8);
        vtWrap.writeString('\x1b]66;s=3;H\x1b\\\x1b]66;s=1;abc\x1b\\');
        // H occupies cols 0..2, rows 0..2; 'a' at (3,0), 'b' at (4,0), 'c' wraps to (0,3).
        expect(vtWrap.buffer.getCharacter(0, 0), equals('H'));
        expect(vtWrap.buffer.getCharacter(0, 3), equals('c'));
        expect(
          KittyTextSizing(vtWrap.buffer.getTextSizing(0, 2)).originDy,
          equals(2),
        );
      },
    );
  });
}
