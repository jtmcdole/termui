import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:termui/termui.dart';
import 'package:termui_pty/src/kitty_shm_macos.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:test/test.dart';

final class _FakeRoutedBackend implements RoutedPtyBackend {
  final StreamController<Uint8List> _output =
      StreamController<Uint8List>.broadcast();
  final Completer<int> _exit = Completer<int>();
  final List<String> written = [];

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  void write(Uint8List bytes) => written.add(utf8.decode(bytes));

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}

  @override
  void kill() {
    if (!_exit.isCompleted) _exit.complete(0);
  }

  @override
  Future<void> dispose() async {
    kill();
    await _output.close();
  }
}

Uint8List _minimalPngBytes(int width, int height) {
  final header = BytesBuilder()
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add(const [0x00, 0x00, 0x00, 0x0D]) // IHDR length = 13
    ..add(const [0x49, 0x48, 0x44, 0x52]); // 'IHDR'
  final dims = ByteData(8)
    ..setUint32(0, width)
    ..setUint32(4, height);
  header
    ..add(dims.buffer.asUint8List())
    ..add(const [0x08, 0x06, 0x00, 0x00, 0x00]) // 8-bit RGBA
    ..add(const [0x00, 0x00, 0x00, 0x00]); // CRC placeholder
  return header.toBytes();
}

void main() {
  tearDown(KittyImageRegistry.clear);

  group('VirtualTerminal Kitty Graphics APC', () {
    test(
      'Capability query a=q obeys quiet modes q=0, q=1, q=2 and missing i',
      () {
        final replies = <String>[];
        final terminal = VirtualTerminal(
          width: 10,
          height: 5,
          onReply: replies.add,
        );

        terminal.write(
          utf8.encode(KittyImageData.buildCapabilityQuery(queryId: 42)),
        );
        expect(replies, contains('\x1b_Gi=42;OK\x1b\\'));

        replies.clear();
        terminal.writeString('\x1b_Gi=42,s=1,v=1,a=q,f=24,q=1;AAAA\x1b\\');
        expect(replies, isEmpty);

        terminal.writeString('\x1b_Gi=42,s=1,v=1,a=q,f=24,q=2;AAAA\x1b\\');
        expect(replies, isEmpty);

        // Missing explicit i / I suppresses OK reply even when q=0.
        terminal.writeString('\x1b_Gs=1,v=1,a=q,f=24;AAAA\x1b\\');
        expect(replies, isEmpty);
      },
    );

    test(
      'Scopes images per VirtualTerminal.imageRegistry without touching global registry',
      () {
        final hostImg = KittyImageData(
          imageId: 1,
          pixelWidth: 1,
          pixelHeight: 1,
          rgbaPixels: Uint8List.fromList([9, 8, 7, 255]),
          gridCols: 1,
          gridRows: 1,
        );
        KittyImageRegistry.register(hostImg);

        final childA = VirtualTerminal(width: 6, height: 4);
        final childB = VirtualTerminal(width: 6, height: 4);
        final childPixels = Uint8List.fromList([1, 2, 3, 255]);
        final b64 = base64Encode(childPixels);

        childA.writeString('\x1b_Gi=1,s=1,v=1,a=T,f=32,c=2,r=2;$b64\x1b\\');
        expect(
          childA.imageRegistry.lookupImage(1)?.rgbaPixels,
          equals(childPixels),
        );
        expect(childB.imageRegistry.lookupImage(1), isNull);
        expect(
          KittyImageRegistry.lookup(1)?.rgbaPixels,
          equals(hostImg.rgbaPixels),
        );

        // renderBuffer() and TerminalView.performPaint register scoped imageRegistry on target Buffer.
        final rendered = childA.renderBuffer();
        expect(
          rendered.lookupKittyImage(0, 0, 1)?.rgbaPixels,
          equals(childPixels),
        );

        final hostCanvas = Buffer.blank(12, 8);
        final element =
            TerminalView(terminal: childA, autofocus: false).createElement()
              ..mount(null)
              ..layout(BoxConstraints.tight(const Size(6, 4)))
              ..paint(hostCanvas, const Offset(4, 2));
        addTearDown(element.unmount);

        // Inside TerminalView bounds (4..9, 2..5) resolves childA image; outside resolves host global!
        expect(
          hostCanvas.lookupKittyImage(4, 2, 1)?.rgbaPixels,
          equals(childPixels),
        );
        expect(
          hostCanvas.lookupKittyImage(0, 0, 1)?.rgbaPixels,
          equals(hostImg.rgbaPixels),
        );

        // Lowercase a=d,d=a clears placements on screen while preserving stored image data.
        final replies = <String>[];
        childA.onReply = replies.add;
        childA.writeString('\x1b_Ga=d,d=a,i=1\x1b\\');
        expect(replies, isEmpty);
        expect(childA.buffer.getCharacter(0, 0), equals(' '));
        expect(childA.imageRegistry.lookupImage(1), isNotNull);

        // Uppercase a=d,d=A frees scoped image data without touching host global registry.
        childA.writeString('\x1b_Ga=d,d=A\x1b\\');
        expect(replies, isEmpty);
        expect(childA.imageRegistry.lookupImage(1), isNull);
        expect(
          KittyImageRegistry.lookup(1)?.rgbaPixels,
          equals(hostImg.rgbaPixels),
        );

        // reset() and dispose() clear scoped imageRegistry.
        childB.writeString('\x1b_Gi=7,s=1,v=1,a=t,f=32;$b64\x1b\\');
        expect(childB.imageRegistry.lookupImage(7), isNotNull);
        childB.reset();
        expect(childB.imageRegistry.lookupImage(7), isNull);

        childB.writeString('\x1b_Gi=8,s=1,v=1,a=t,f=32;$b64\x1b\\');
        childB.dispose();
        expect(childB.imageRegistry.lookupImage(8), isNull);
      },
    );

    test(
      'Transmits RGB24 image normalized to format 32 and derives default c/r from pixel size',
      () {
        final replies = <String>[];
        final terminal = VirtualTerminal(
          width: 10,
          height: 5,
          onReply: replies.add,
        );

        // 16x32 RGB24 image -> default gridCols=2, gridRows=2, normalized format=32
        final rgbBytes = Uint8List(16 * 32 * 3);
        rgbBytes.setRange(0, 6, const [255, 0, 0, 0, 255, 0]);
        final b64 = base64Encode(rgbBytes);

        terminal.write(
          utf8.encode('\x1b_Gi=101,s=16,v=32,a=t,f=24;$b64\x1b\\'),
        );
        expect(replies, contains('\x1b_Gi=101;OK\x1b\\'));

        final registered = terminal.imageRegistry.lookupImage(101);
        expect(registered, isNotNull);
        expect(registered!.format, equals(32));
        expect(registered.pixelWidth, equals(16));
        expect(registered.pixelHeight, equals(32));
        expect(registered.gridCols, equals(2));
        expect(registered.gridRows, equals(2));
        expect(
          registered.rgbaPixels.sublist(0, 8),
          equals([255, 0, 0, 255, 0, 255, 0, 255]),
        );
      },
    );

    test(
      'Chunked KittyImageData.toApcSequence + U=1 updates registered 4x2 grid dimensions',
      () {
        final terminal = VirtualTerminal(width: 10, height: 6);
        final src = KittyImageData(
          imageId: 55,
          pixelWidth: 4,
          pixelHeight: 4,
          rgbaPixels: Uint8List.fromList(
            List<int>.generate(64, (i) => i & 0xFF),
          ),
          gridCols: 4,
          gridRows: 2,
        );

        final apcSeq = src.toApcSequence(chunkSize: 16, compress: true);
        terminal.writeString(apcSeq);

        final registered = terminal.imageRegistry.lookupImage(55);
        expect(registered, isNotNull);
        expect(registered!.gridCols, equals(4));
        expect(registered.gridRows, equals(2));
        expect(registered.rgbaPixels, equals(src.rgbaPixels));
      },
    );

    test(
      'Chunked a=T defers placement until m=0 and preserves first-chunk metadata',
      () {
        final replies = <String>[];
        final terminal = VirtualTerminal(
          width: 10,
          height: 5,
          onReply: replies.add,
        );

        final rgba = Uint8List.fromList(List<int>.filled(4 * 4, 200));
        final b64 = base64Encode(rgba);
        final mid = b64.length ~/ 2;

        terminal.writeString(
          '\x1b_Ga=T,i=202,s=2,v=2,f=32,c=3,r=2,m=1;${b64.substring(0, mid)}\x1b\\',
        );
        // Must NOT place or reply on m=1!
        expect(terminal.buffer.getCharacter(0, 0), equals(' '));
        expect(terminal.cursorX, equals(0));
        expect(replies, isEmpty);

        terminal.writeString('\x1b_Gm=0;${b64.substring(mid)}\x1b\\');
        expect(replies, equals(['\x1b_Gi=202;OK\x1b\\']));
        expect(terminal.cursorX, equals(3));
        for (var r = 0; r < 2; r++) {
          for (var c = 0; c < 3; c++) {
            expect(
              terminal.buffer.getCharacter(c, r),
              equals(kittyPlaceholderCell(r, c)),
            );
          }
        }
      },
    );

    test(
      'Supports f=100 PNG IHDR dimension extraction and rejects invalid PNGs',
      () {
        final replies = <String>[];
        final terminal = VirtualTerminal(
          width: 10,
          height: 5,
          onReply: replies.add,
        );

        final png = _minimalPngBytes(24, 32);
        final b64 = base64Encode(png);
        terminal.writeString('\x1b_Gi=301,a=t,f=100;$b64\x1b\\');

        final registered = terminal.imageRegistry.lookupImage(301);
        expect(registered, isNotNull);
        expect(registered!.format, equals(100));
        expect(registered.pixelWidth, equals(24));
        expect(registered.pixelHeight, equals(32));
        expect(registered.gridCols, equals(3));
        expect(registered.gridRows, equals(2));

        replies.clear();
        final badPng = base64Encode(Uint8List.fromList([1, 2, 3, 4]));
        terminal.writeString('\x1b_Gi=302,a=t,f=100,q=1;$badPng\x1b\\');
        expect(terminal.imageRegistry.lookupImage(302), isNull);
        expect(replies, equals(['\x1b_Gi=302;EINVAL:invalid payload\x1b\\']));

        // Reject PNG decompression bomb with oversized IHDR even if s=1,v=1 are small!
        replies.clear();
        final bombPng = base64Encode(_minimalPngBytes(20000, 20000));
        terminal.writeString(
          '\x1b_Gi=303,s=1,v=1,a=t,f=100,q=1;$bombPng\x1b\\',
        );
        expect(terminal.imageRegistry.lookupImage(303), isNull);
        expect(replies, equals(['\x1b_Gi=303;EINVAL:invalid payload\x1b\\']));

        // Reject explicit s=/v= that disagree with valid PNG IHDR dimensions!
        replies.clear();
        terminal.writeString('\x1b_Gi=304,s=8,v=8,a=t,f=100,q=1;$b64\x1b\\');
        expect(terminal.imageRegistry.lookupImage(304), isNull);
        expect(replies, equals(['\x1b_Gi=304;EINVAL:invalid payload\x1b\\']));
      },
    );

    test(
      'Ignores X/Y pixel offsets as cell coords and encodes 32-bit imageId MSB',
      () {
        final terminal = VirtualTerminal(width: 10, height: 5);
        final b64 = base64Encode(Uint8List.fromList([1, 2, 3, 255]));
        const id32 = 0x12345678;

        terminal.writeString('\x1b[2;3H'); // cursor at col=2, row=1
        terminal.writeString(
          '\x1b_Gi=$id32,s=1,v=1,a=T,f=32,c=2,r=1,X=7,Y=9;$b64\x1b\\',
        );

        // Must start at cursor (2, 1), NOT (7, 9), and encode MSB 0x12!
        expect(
          terminal.buffer.getCharacter(2, 1),
          equals(kittyPlaceholderCell(0, 0, imageIdMsb: 0x12)),
        );
        expect(terminal.buffer.getForeground(2, 1), equals(0xFF345678));
        expect(terminal.buffer.getCharacter(7, 4), equals(' '));

        // Direct placement without explicit i= (auto-assigned 0x80000001, MSB = 128)
        // must encode MSB = 128 without clamping and resolve in imageRegistry!
        terminal.writeString('\x1b[4;1H'); // cursor at col=0, row=3
        terminal.writeString('\x1b_Gs=1,v=1,a=T,f=32,c=1,r=1;$b64\x1b\\');
        final autoCell = terminal.buffer.getCharacter(0, 3);
        final parsed = parseKittyPlaceholderCell(autoCell);
        expect(parsed, equals((row: 0, col: 0, imageIdMsb: 0x80)));
        final low24 = terminal.buffer.getForeground(0, 3) & 0xFFFFFF;
        final fullId = ((parsed!.imageIdMsb! & 0xFF) << 24) | low24;
        expect(fullId, equals(0x80000001));
        expect(terminal.imageRegistry.lookupImage(fullId), isNotNull);
      },
    );

    test(
      'Enforces DoS bounds on dimensions, truncated buffers, pending uploads, and zlib bombs',
      () {
        final replies = <String>[];
        final terminal = VirtualTerminal(
          width: 10,
          height: 5,
          onReply: replies.add,
        );

        // 1. Oversized dimensions (> 8192) rejected before allocation.
        final tiny = base64Encode(Uint8List(4));
        terminal.writeString('\x1b_Gi=401,s=9000,v=1,a=t,f=32;$tiny\x1b\\');
        expect(
          replies.last,
          equals('\x1b_Gi=401;EINVAL:invalid payload\x1b\\'),
        );

        // 2. Truncated RGBA32 payload rejected with EINVAL (unless q=2).
        terminal.writeString('\x1b_Gi=402,s=4,v=4,a=t,f=32;$tiny\x1b\\');
        expect(
          replies.last,
          equals('\x1b_Gi=402;EINVAL:invalid payload\x1b\\'),
        );

        replies.clear();
        terminal.writeString('\x1b_Gi=403,s=4,v=4,a=t,f=32,q=2;$tiny\x1b\\');
        expect(replies, isEmpty);

        // 3. Concurrent pending uploads capped at 16 (oldest evicted).
        final validBytes = base64Encode(Uint8List(4));
        for (var id = 500; id < 520; id++) {
          terminal.writeString(
            '\x1b_Gi=$id,s=1,v=1,a=t,f=32,m=1;${validBytes.substring(0, 4)}\x1b\\',
          );
        }
        // Upload 500 was evicted; upload 519 still completes cleanly.
        terminal.writeString(
          '\x1b_Gi=519,m=0;${validBytes.substring(4)}\x1b\\',
        );
        expect(terminal.imageRegistry.lookupImage(519), isNotNull);
        expect(terminal.imageRegistry.lookupImage(500), isNull);

        // 4. Zlib bomb exceeding 16 MiB inflated output aborts immediately with EFBIG.
        replies.clear();
        final bombCompressed = zlib.encode(Uint8List(16 * 1024 * 1024 + 64));
        final bombB64 = base64Encode(bombCompressed);
        terminal.writeString(
          '\x1b_Gi=600,s=2048,v=2048,a=t,f=32,o=z;$bombB64\x1b\\',
        );
        expect(terminal.imageRegistry.lookupImage(600), isNull);
        expect(replies, equals(['\x1b_Gi=600;EFBIG:payload too large\x1b\\']));
      },
    );

    test(
      'imageRegistryRevision increments on upload, overwrite, delete, and reset while bumping version on overwrite',
      () {
        final terminal = VirtualTerminal(width: 10, height: 5);
        expect(terminal.imageRegistryRevision, equals(0));

        // Query alone does not mutate registry revision.
        terminal.writeString('\x1b_Gi=1,s=1,v=1,a=q,f=32;AAAA\x1b\\');
        expect(terminal.imageRegistryRevision, equals(0));

        final px1 = base64Encode(Uint8List.fromList([255, 0, 0, 255]));
        terminal.writeString('\x1b_Gi=7,s=1,v=1,a=t,f=32;$px1\x1b\\');
        final revAfterUpload = terminal.imageRegistryRevision;
        expect(revAfterUpload, greaterThan(0));
        expect(terminal.imageRegistry.lookupImage(7)?.version, equals(0));

        // Overwriting same imageId bumps both imageRegistryRevision and image version.
        final px2 = base64Encode(Uint8List.fromList([0, 255, 0, 255]));
        terminal.writeString('\x1b_Gi=7,s=1,v=1,a=t,f=32;$px2\x1b\\');
        expect(terminal.imageRegistryRevision, greaterThan(revAfterUpload));
        expect(terminal.imageRegistry.lookupImage(7)?.version, equals(1));

        final revBeforeDelete = terminal.imageRegistryRevision;
        terminal.writeString('\x1b_Ga=d,d=I,i=7\x1b\\');
        expect(terminal.imageRegistryRevision, greaterThan(revBeforeDelete));
        expect(terminal.imageRegistry.lookupImage(7), isNull);

        final revBeforeReset = terminal.imageRegistryRevision;
        terminal.reset();
        expect(terminal.imageRegistryRevision, greaterThan(revBeforeReset));
      },
    );

    test(
      'Reassembles chunk-split U+10EEEE combining diacritics across write/writeString boundaries',
      () {
        final terminal = VirtualTerminal(width: 6, height: 3);

        // 1. Split after base U+10EEEE, after row diacritic, and after col diacritic (with 32-bit MSB 0x42 -> 0x065A).
        final full32 = kittyPlaceholderCell(2, 3, imageIdMsb: 0x42);
        final u10eeee = full32.substring(0, 2);
        final rowMark = full32.substring(2, 3);
        final colMark = full32.substring(3, 4);
        final msbMark = full32.substring(4, 5);

        terminal.write(utf8.encode(u10eeee));
        expect(terminal.cursorX, equals(1));
        expect(terminal.cursorY, equals(0));

        terminal.write(utf8.encode(rowMark));
        expect(terminal.cursorX, equals(1));

        terminal.writeString(colMark);
        expect(terminal.cursorX, equals(1));

        terminal.write(utf8.encode(msbMark));
        expect(terminal.cursorX, equals(1));
        expect(terminal.cursorY, equals(0));
        expect(terminal.buffer.getCharacter(0, 0), equals(full32));
        expect(
          Modifier.has(
            terminal.buffer.getModifiers(0, 0),
            Modifier.kittyPlaceholder,
          ),
          isTrue,
        );
        expect(
          parseKittyPlaceholderCell(terminal.buffer.getCharacter(0, 0)),
          equals((row: 2, col: 3, imageIdMsb: 0x42)),
        );

        // 2. CSI Ps b (REP) repeats the merged multi-chunk grapheme cluster.
        terminal.writeString('\x1b[2b');
        expect(terminal.cursorX, equals(3));
        expect(terminal.buffer.getCharacter(1, 0), equals(full32));
        expect(terminal.buffer.getCharacter(2, 0), equals(full32));

        // 3. Split at right margin (width - 1) on the bottom row must merge onto (width - 1, height - 1)
        //    without triggering premature line wrap or scroll.
        terminal.writeString('\x1b[3;6H'); // 1-based row=3, col=6 -> (5, 2)
        terminal.writeString(u10eeee);
        expect(terminal.cursorX, equals(6)); // pending wrap
        expect(terminal.cursorY, equals(2));
        terminal.writeString('$rowMark$colMark$msbMark');
        expect(terminal.cursorX, equals(6)); // still pending wrap, no scroll
        expect(terminal.cursorY, equals(2));
        expect(terminal.buffer.getCharacter(5, 2), equals(full32));
        expect(terminal.scrollback.totalLines, equals(0));

        // 4. Standalone combining mark after CSI cursor move is dropped without shifting columns.
        terminal.writeString('\x1b[2;2H'); // (1, 1)
        terminal.writeString(rowMark);
        expect(terminal.cursorX, equals(1));
        expect(terminal.cursorY, equals(1));
        expect(terminal.buffer.getCharacter(1, 1), equals(' '));

        // 5. Bounded DoS cap (<= 32 UTF-16 code units) drops excess combining marks cleanly.
        terminal.writeString('\x1b[2;1H'); // (0, 1)
        terminal.writeString('A');
        for (var i = 0; i < 40; i++) {
          terminal.writeString('\u{0305}');
        }
        expect(terminal.cursorX, equals(1));
        expect(terminal.buffer.getCharacter(0, 1).length, equals(32));

        // 6. All 297 Kitty placeholder diacritics report graphemeWidth == 0.
        for (final cp in kittyDiacritics) {
          expect(graphemeWidth(String.fromCharCode(cp)), equals(0));
        }

        // 7. Narrow-to-wide promotion when '\uFE0F' arrives in the next chunk.
        terminal.writeString('\x1b[3;1H'); // (0, 2)
        terminal.writeString('\u{2764}');
        expect(terminal.cursorX, equals(1));
        expect(terminal.buffer.getCharacter(0, 2), equals('\u{2764}'));
        terminal.writeString('\u{FE0F}');
        expect(terminal.cursorX, equals(2));
        expect(terminal.buffer.getCharacter(0, 2), equals('\u{2764}\u{FE0F}'));
        expect(terminal.buffer.getCharacter(1, 2), equals(''));

        // 8. Standalone U+00AD / U+FFF9 advance cursorX by 1 without merging.
        terminal.writeString('\x1b[2;1H'); // (0, 1)
        terminal.writeString('X');
        terminal.writeString('\u{00AD}');
        expect(terminal.cursorX, equals(2));
        expect(terminal.buffer.getCharacter(0, 1), equals('X'));
        expect(terminal.buffer.getCharacter(1, 1), equals('\u{00AD}'));
        terminal.writeString('\u{FFF9}');
        expect(terminal.cursorX, equals(3));
        expect(terminal.buffer.getCharacter(2, 1), equals('\u{FFF9}'));

        // 9. Single-chunk combining flood is capped at 32 UTF-16 code units.
        terminal.writeString('\x1b[1;1H');
        terminal.writeString('A${'\u{0305}' * 40}');
        expect(terminal.buffer.getCharacter(0, 0).length, equals(32));
      },
    );

    test(
      'Promotes chunk-split right-margin wide emoji cleanly under !DECAWM, DECAWM+IRM, and repeated resize()',
      () {
        // !DECAWM: blanks (width-1, y) including aux metadata and drops wide promotion.
        final noWrap = VirtualTerminal(width: 4, height: 2);
        noWrap.writeString('\x1b[?7l'); // disable auto-wrap
        noWrap.writeString(
          '\x1b[1;4H\x1b]8;;https://dart.dev\x07\x1b[58:2::1:2:3m\u{2764}',
        );
        noWrap.writeString('\u{FE0F}');
        noWrap.writeString('\x1b]8;;\x07');
        expect(noWrap.buffer.getCharacter(3, 0), equals(' '));
        expect(noWrap.buffer.getUri(3, 0), isNull);
        expect(noWrap.buffer.getUnderlineColor(3, 0), equals(0));
        expect(noWrap.cursorY, equals(0));

        // DECAWM + IRM: blanks (width-1, y), wraps, and inserts 2 cells on next row.
        final irm = VirtualTerminal(width: 4, height: 2);
        irm.writeString('\x1b[4h'); // enable IRM
        irm.writeString('\x1b[2;1HAB');
        irm.writeString(
          '\x1b[1;4H\x1b]8;;https://dart.dev\x07\x1b[58:2::1:2:3m\u{2764}',
        );
        irm.writeString('\u{FE0F}');
        expect(irm.buffer.getCharacter(3, 0), equals(' '));
        expect(irm.buffer.getUri(3, 0), isNull);
        expect(irm.buffer.getUnderlineColor(3, 0), equals(0));
        expect(irm.buffer.getCharacter(0, 1), equals('\u{2764}\u{FE0F}'));
        expect(irm.buffer.getCharacter(1, 1), equals(''));
        expect(irm.buffer.getCharacter(2, 1), equals('A'));
        expect(irm.buffer.getCharacter(3, 1), equals('B'));

        // Repeated terminal.resize() shrinks/grows preserve Kitty lookup and clip bounds.
        final b64 = base64Encode(Uint8List.fromList([1, 2, 3, 255]));
        irm.writeString(
          '\x1b[1;1H\x1b_Gi=77,s=1,v=1,a=T,f=32,c=1,r=1;$b64\x1b\\',
        );
        irm.resize(2, 1);
        irm.resize(6, 3);
        irm.resize(4, 2);
        expect(irm.buffer.lookupKittyImage(0, 0, 77), isNotNull);
        expect(
          identical(irm.buffer.lookupKittyRegistry(3, 1), irm.imageRegistry),
          isTrue,
        );
        expect(
          identical(
            irm.buffer.lookupKittyRegistry(5, 2),
            KittyImageRegistry.global,
          ),
          isTrue,
        );
      },
    );

    test(
      'Bare a=d / d=a and d=i clear placements without freeing image data for subsequent a=p, while d=A / d=I free data',
      () {
        final replies = <String>[];
        final vt = VirtualTerminal(
          width: 10,
          height: 5,
          onReply: replies.add,
          allowLocalKittyMedia: true,
        );
        final pxB64 = base64Encode(Uint8List.fromList([255, 0, 0, 255]));

        // Transmit image 1 and 2 (separate transmit + place flow).
        vt.writeString('\x1b_Gf=32,s=1,v=1,i=1;$pxB64\x1b\\');
        vt.writeString('\x1b_Gf=32,s=1,v=1,i=2;$pxB64\x1b\\');
        expect(vt.imageRegistry.lookupImage(1), isNotNull);
        expect(vt.imageRegistry.lookupImage(2), isNotNull);

        // Bare a=d (defaults to d=a) clears placements but MUST preserve stored data so a=p succeeds.
        replies.clear();
        vt.writeString('\x1b_Ga=d\x1b\\');
        vt.writeString('\x1b[1;1H\x1b_Ga=p,i=1,c=4,r=2,C=1\x1b\\');
        expect(replies, equals(['\x1b_Gi=1;OK\x1b\\']));
        expect(vt.imageRegistry.lookupImage(1)?.gridCols, equals(4));
        expect(vt.imageRegistry.lookupImage(1)?.gridRows, equals(2));
        expect(
          vt.buffer.getCharacter(0, 0),
          equals(kittyPlaceholderCell(0, 0)),
        );
        expect(
          vt.buffer.getCharacter(3, 1),
          equals(kittyPlaceholderCell(1, 3)),
        );

        // Place image 2 on row 3, then d=i,i=1 clears only image 1's cells and keeps image 1 in registry.
        vt.writeString('\x1b[4;1H\x1b_Ga=p,i=2,c=2,r=1,C=1\x1b\\');
        vt.writeString('\x1b_Ga=d,d=i,i=1\x1b\\');
        expect(vt.buffer.getCharacter(0, 0), equals(' '));
        expect(
          vt.buffer.getCharacter(0, 3),
          equals(kittyPlaceholderCell(0, 0)),
        );
        expect(vt.imageRegistry.lookupImage(1), isNotNull);

        // Uppercase d=I,i=2 clears image 2's cells AND frees its stored data.
        vt.writeString('\x1b_Ga=d,d=I,i=2\x1b\\');
        expect(vt.buffer.getCharacter(0, 3), equals(' '));
        expect(vt.imageRegistry.lookupImage(2), isNull);
        expect(vt.imageRegistry.lookupImage(1), isNotNull);

        // 32-bit imageId (> 0xFFFFFF) direct placement + bare U+10EEEE cells clear all columns on d=i.
        const id32 = 0x12000042;
        vt.writeString('\x1b_Gf=32,s=1,v=1,i=$id32,a=t;$pxB64\x1b\\');
        vt.writeString('\x1b[2;1H\x1b_Ga=p,i=$id32,c=3,r=1,C=1\x1b\\');
        vt.writeString('\x1b_Ga=d,d=i,i=$id32\x1b\\');
        expect(vt.buffer.getCharacter(0, 1), equals(' '));
        expect(vt.buffer.getCharacter(1, 1), equals(' '));
        expect(vt.buffer.getCharacter(2, 1), equals(' '));

        // d=A clears images without aborting unrelated in-flight m=1 uploads.
        final mid = pxB64.length ~/ 2;
        vt.writeString(
          '\x1b_Ga=t,i=90,f=32,s=1,v=1,m=1;${pxB64.substring(0, mid)}\x1b\\',
        );
        vt.writeString('\x1b_Ga=d,d=A\x1b\\');
        expect(vt.imageRegistry.lookupImage(1), isNull);
        vt.writeString('\x1b_Gm=0;${pxB64.substring(mid)}\x1b\\');
        expect(vt.imageRegistry.lookupImage(90), isNotNull);
      },
    );

    test(
      'Supports local temp file (t=t) and Linux POSIX shared memory (t=s) with O=/S= slicing, security checks, and unlink',
      () {
        final replies = <String>[];
        final vt = VirtualTerminal(
          width: 10,
          height: 5,
          onReply: replies.add,
          allowLocalKittyMedia: true,
        );
        final rgba = Uint8List.fromList([10, 20, 30, 255]);

        // 1. t=t temp file with S=0 (protocol default -> read to EOF) unlinks after read.
        final tmpPath =
            '${Directory.systemTemp.path}/tty-graphics-protocol-termui-test-$pid.rgba';
        final tmpFile = File(tmpPath)..writeAsBytesSync(rgba);
        addTearDown(() {
          if (tmpFile.existsSync()) tmpFile.deleteSync();
        });
        final tmpB64 = base64Encode(utf8.encode(tmpPath));
        vt.writeString(
          '\x1b_Ga=T,f=32,s=1,v=1,i=81,t=t,S=0,c=2,r=1;$tmpB64\x1b\\',
        );
        expect(replies, contains('\x1b_Gi=81;OK\x1b\\'));
        expect(vt.imageRegistry.lookupImage(81)?.rgbaPixels, equals(rgba));
        expect(tmpFile.existsSync(), isFalse);

        // 2. t=t with O= offset and S= size slices exact bytes.
        replies.clear();
        final padded = Uint8List.fromList([0, 0, ...rgba, 99]);
        final slicePath =
            '${Directory.systemTemp.path}/tty-graphics-protocol-slice-$pid.rgba';
        final sliceFile = File(slicePath)..writeAsBytesSync(padded);
        addTearDown(() {
          if (sliceFile.existsSync()) sliceFile.deleteSync();
        });
        final sliceB64 = base64Encode(utf8.encode(slicePath));
        vt.writeString(
          '\x1b_Ga=t,f=32,s=1,v=1,i=83,t=t,O=2,S=4;$sliceB64\x1b\\',
        );
        expect(replies, contains('\x1b_Gi=83;OK\x1b\\'));
        expect(vt.imageRegistry.lookupImage(83)?.rgbaPixels, equals(rgba));
        expect(sliceFile.existsSync(), isFalse);

        // 3. Missing t=t file returns ENOENT; traversal and intermediate symlink return EINVAL.
        replies.clear();
        final missingPath =
            '${Directory.systemTemp.path}/tty-graphics-protocol-missing-$pid.rgba';
        vt.writeString(
          '\x1b_Ga=t,f=32,s=1,v=1,i=84,t=t;${base64Encode(utf8.encode(missingPath))}\x1b\\',
        );
        expect(replies, contains(startsWith('\x1b_Gi=84;ENOENT:')));

        final traversalPath =
            '${Directory.systemTemp.path}/tty-graphics-protocol/..\\../etc/passwd';
        vt.writeString(
          '\x1b_Ga=t,f=32,s=1,v=1,i=85,t=t;${base64Encode(utf8.encode(traversalPath))}\x1b\\',
        );
        expect(replies, contains(startsWith('\x1b_Gi=85;EINVAL:')));

        if (!Platform.isWindows) {
          final outsideDir = Directory.systemTemp.createTempSync(
            'termui_outside_',
          );
          final outsideSub = Directory('${outsideDir.path}/sub')..createSync();
          final outsideFile = File('${outsideSub.path}/secret.rgba')
            ..writeAsBytesSync(rgba);
          final linkPath =
              '${Directory.systemTemp.path}/tty-graphics-protocol-link-$pid';
          final link = Link(linkPath)..createSync('/etc');
          addTearDown(() {
            if (link.existsSync()) link.deleteSync();
            if (outsideDir.existsSync()) outsideDir.deleteSync(recursive: true);
          });
          // Intermediate symlink pointing outside allowed temp dir must be rejected and NOT deleted.
          final viaLink = '$linkPath/hosts';
          vt.writeString(
            '\x1b_Ga=t,f=32,s=1,v=1,i=86,t=t;${base64Encode(utf8.encode(viaLink))}\x1b\\',
          );
          expect(replies, contains(startsWith('\x1b_Gi=86;EINVAL:')));

          // Direct symlink leaf must also be rejected without deleting target.
          final leafLinkPath =
              '${Directory.systemTemp.path}/tty-graphics-protocol-leaf-$pid.rgba';
          final leafLink = Link(leafLinkPath)..createSync(outsideFile.path);
          addTearDown(() {
            if (leafLink.existsSync()) leafLink.deleteSync();
          });
          vt.writeString(
            '\x1b_Ga=t,f=32,s=1,v=1,i=87,t=t;${base64Encode(utf8.encode(leafLinkPath))}\x1b\\',
          );
          expect(replies, contains(startsWith('\x1b_Gi=87;EINVAL:')));
          expect(outsideFile.existsSync(), isTrue);
        }

        // 4. t=s POSIX shared memory on Linux (/dev/shm/<name>).
        if (Platform.isLinux && Directory('/dev/shm').existsSync()) {
          replies.clear();
          final shmName = '/termui-kitty-test-$pid';
          final shmFile = File('/dev/shm/termui-kitty-test-$pid')
            ..writeAsBytesSync(rgba);
          addTearDown(() {
            if (shmFile.existsSync()) shmFile.deleteSync();
          });
          final shmB64 = base64Encode(utf8.encode(shmName));
          vt.writeString('\x1b_Ga=t,f=32,s=1,v=1,i=82,t=s;$shmB64\x1b\\');
          expect(replies, contains('\x1b_Gi=82;OK\x1b\\'));
          expect(vt.imageRegistry.lookupImage(82)?.rgbaPixels, equals(rgba));
          expect(shmFile.existsSync(), isFalse);
        }
      },
    );

    test(
      'Supports repeated metadata on m= continuation, p= placements, I= image numbers, d=r/R, single-axis c=, 4K PNGs, and unknown a= errors',
      () {
        final replies = <String>[];
        final vt = VirtualTerminal(
          width: 20,
          height: 10,
          cellPixelWidth: 8,
          cellPixelHeight: 16,
          onReply: replies.add,
        );
        final rgba = Uint8List.fromList([11, 22, 33, 255]);
        final b64 = base64Encode(rgba);
        final mid = b64.length ~/ 2;

        // 1. Continuation chunk repeating metadata (f=32,t=d,p=5) must NOT abort upload.
        vt.writeString(
          '\x1b_Ga=t,i=110,p=5,f=32,s=1,v=1,t=d,m=1;${b64.substring(0, mid)}\x1b\\',
        );
        vt.writeString(
          '\x1b_Gi=110,p=5,f=32,t=d,m=0;${b64.substring(mid)}\x1b\\',
        );
        expect(replies, contains('\x1b_Gi=110,p=5;OK\x1b\\'));
        expect(vt.imageRegistry.lookupImage(110)?.rgbaPixels, equals(rgba));

        // 2. Placement ID p= in a=p reply and selective d=I,i=,p= deletion.
        replies.clear();
        vt.writeString('\x1b_Ga=p,i=110,p=1,c=2,r=1,C=1\x1b\\');
        vt.writeString('\x1b_Ga=p,i=110,p=2,c=2,r=1,C=1\x1b\\');
        expect(replies, contains('\x1b_Gi=110,p=1;OK\x1b\\'));
        expect(replies, contains('\x1b_Gi=110,p=2;OK\x1b\\'));
        // Deleting only p=1 must keep image 110 because p=2 still exists.
        vt.writeString('\x1b_Ga=d,d=I,i=110,p=1\x1b\\');
        expect(vt.imageRegistry.lookupImage(110), isNotNull);
        // Deleting p=2 leaves 0 placements -> image 110 is freed.
        vt.writeString('\x1b_Ga=d,d=I,i=110,p=2\x1b\\');
        expect(vt.imageRegistry.lookupImage(110), isNull);

        // 3. I= image number: replies i=<auto>,I=7;OK, supports a=p,I=7 and d=N,I=7.
        replies.clear();
        vt.writeString('\x1b_Ga=t,I=7,f=32,s=1,v=1;$b64\x1b\\');
        expect(replies.single, matches(RegExp(r'^\x1b_Gi=\d+,I=7;OK\x1b\\$')));
        replies.clear();
        vt.writeString('\x1b_Ga=p,I=7,c=2,r=1,C=1\x1b\\');
        expect(replies.single, matches(RegExp(r'^\x1b_Gi=\d+,I=7;OK\x1b\\$')));
        vt.writeString('\x1b_Ga=d,d=N,I=7\x1b\\');
        replies.clear();
        vt.writeString('\x1b_Ga=p,I=7,c=2,r=1,C=1\x1b\\');
        expect(replies, contains('\x1b_GI=7;ENOENT:image not found\x1b\\'));

        // Specifying both i= and I= returns EINVAL.
        replies.clear();
        vt.writeString('\x1b_Ga=t,i=111,I=8,f=32,s=1,v=1;$b64\x1b\\');
        expect(
          replies,
          contains(startsWith('\x1b_Gi=111,I=8;EINVAL:cannot specify both')),
        );

        // 4. Single-axis c= preserves aspect ratio using cell pixel size (8x16).
        final png1000 = base64Encode(_minimalPngBytes(1000, 1000));
        vt.writeString('\x1b_Ga=t,i=120,f=100,c=20;$png1000\x1b\\');
        expect(vt.imageRegistry.lookupImage(120)?.gridCols, equals(20));
        expect(vt.imageRegistry.lookupImage(120)?.gridRows, equals(10));

        // 5. 4K PNG (3840x2160 = 8.3 MP) is accepted under raised 16 MP cap.
        final png4k = base64Encode(_minimalPngBytes(3840, 2160));
        vt.writeString('\x1b_Ga=t,i=121,f=100;$png4k\x1b\\');
        expect(vt.imageRegistry.lookupImage(121)?.pixelWidth, equals(3840));
        expect(vt.imageRegistry.lookupImage(121)?.pixelHeight, equals(2160));

        // 6. d=R range delete removes ids 120..121.
        vt.writeString('\x1b_Ga=d,d=R,x=120,y=121\x1b\\');
        expect(vt.imageRegistry.lookupImage(120), isNull);
        expect(vt.imageRegistry.lookupImage(121), isNull);

        // 7. d=a preserves U=1 virtual placements and their placeholder text cells.
        vt.writeString('\x1b_Ga=T,U=1,i=130,f=32,s=1,v=1,c=2,r=1;$b64\x1b\\');
        vt.writeString(
          '\x1b[1;1H\x1b[38;2;0;0;130m${kittyPlaceholderCell(0, 0)}$kittyPlaceholderChar\x1b[39m',
        );
        vt.writeString('\x1b_Ga=d,d=a\x1b\\');
        expect(vt.imageRegistry.lookupImage(130), isNotNull);
        expect(
          vt.buffer.getCharacter(0, 0),
          equals(kittyPlaceholderCell(0, 0)),
        );

        // 8. Unsupported action replies EINVAL:unsupported action.
        replies.clear();
        vt.writeString('\x1b_Ga=x,i=140;$b64\x1b\\');
        expect(
          replies,
          equals(['\x1b_Gi=140;EINVAL:unsupported action\x1b\\']),
        );
      },
    );

    test(
      'normalizeMacosShmName enforces leading slash, path safety, IPC blocklist, and 30-byte PSHMNAMLEN cap',
      () {
        expect(normalizeMacosShmName('/peng-123-1'), equals('/peng-123-1'));
        expect(normalizeMacosShmName('peng-123-1'), equals('/peng-123-1'));
        expect(normalizeMacosShmName('/icat-ABC123'), equals('/icat-ABC123'));
        expect(normalizeMacosShmName(''), isNull);
        expect(normalizeMacosShmName('/'), isNull);
        expect(normalizeMacosShmName('.'), isNull);
        expect(normalizeMacosShmName('..'), isNull);
        expect(normalizeMacosShmName('/.hidden-shm'), isNull);
        expect(normalizeMacosShmName('/sem.my-lock'), isNull);
        expect(normalizeMacosShmName('/org.chromium.Chromium.abc'), isNull);
        expect(normalizeMacosShmName('/pulse-shm-12345'), isNull);
        expect(normalizeMacosShmName('/org.mozilla.ipc.99'), isNull);
        expect(normalizeMacosShmName('/PostgreSQL.1234'), isNull);
        expect(normalizeMacosShmName('/foo/bar'), isNull);
        expect(normalizeMacosShmName(r'/foo\bar'), isNull);
        expect(normalizeMacosShmName('/foo\x00bar'), isNull);
        expect(normalizeMacosShmName('/${'a' * 29}'), equals('/${'a' * 29}'));
        expect(normalizeMacosShmName('/${'a' * 30}'), isNull);
      },
    );

    test(
      'Local media (t=t/t=s) is disabled by default and preserves files on a=q or read errors',
      () {
        final rgba = Uint8List.fromList([1, 2, 3, 255]);
        final tmpPath =
            '${Directory.systemTemp.path}/tty-graphics-protocol-keep-$pid.rgba';
        final tmpFile = File(tmpPath)..writeAsBytesSync(rgba);
        addTearDown(() {
          if (tmpFile.existsSync()) tmpFile.deleteSync();
        });
        final tmpB64 = base64Encode(utf8.encode(tmpPath));
        final shmB64 = base64Encode(utf8.encode('/termui-disabled-$pid'));

        // 1. Default VirtualTerminal rejects t=t and t=s without unlinking.
        final defaultReplies = <String>[];
        final defaultVt = VirtualTerminal(
          width: 10,
          height: 5,
          onReply: defaultReplies.add,
        );
        defaultVt.writeString('\x1b_Ga=t,f=32,s=1,v=1,i=201,t=t;$tmpB64\x1b\\');
        defaultVt.writeString('\x1b_Ga=t,f=32,s=1,v=1,i=202,t=s;$shmB64\x1b\\');
        expect(
          defaultReplies,
          equals([
            '\x1b_Gi=201;EINVAL:unsupported transmission medium\x1b\\',
            '\x1b_Gi=202;EINVAL:unsupported transmission medium\x1b\\',
          ]),
        );
        expect(tmpFile.existsSync(), isTrue);

        // 2. With allowLocalKittyMedia: true, a=q probe and O= error do NOT unlink.
        final replies = <String>[];
        final vt = VirtualTerminal(
          width: 10,
          height: 5,
          onReply: replies.add,
          allowLocalKittyMedia: true,
        );
        vt.writeString('\x1b_Ga=q,f=32,s=1,v=1,i=203,t=t;$tmpB64\x1b\\');
        expect(replies.last, equals('\x1b_Gi=203;OK\x1b\\'));
        expect(tmpFile.existsSync(), isTrue);

        vt.writeString(
          '\x1b_Ga=t,f=32,s=1,v=1,i=204,t=t,O=999999;$tmpB64\x1b\\',
        );
        expect(replies.last, startsWith('\x1b_Gi=204;EINVAL:'));
        expect(tmpFile.existsSync(), isTrue);

        // 3. UNC (including mixed-slash) and relative paths are rejected with EINVAL.
        for (final badPath in const [
          r'\\host\share\tty-graphics-protocol.rgba',
          '//host/share/tty-graphics-protocol.rgba',
          r'\/host/share/tty-graphics-protocol.rgba',
          r'/\host\share\tty-graphics-protocol.rgba',
          'tty-graphics-protocol-relative.rgba',
        ]) {
          replies.clear();
          final b64 = base64Encode(utf8.encode(badPath));
          vt.writeString('\x1b_Ga=t,f=32,s=1,v=1,i=205,t=t;$b64\x1b\\');
          expect(
            replies.single,
            startsWith('\x1b_Gi=205;EINVAL:'),
            reason: 'Expected EINVAL for $badPath',
          );
        }
      },
    );

    test(
      'Resets stale m=1 uploads on conflicting metadata and preserves chunked I= continuations',
      () {
        final replies = <String>[];
        final vt = VirtualTerminal(width: 10, height: 5, onReply: replies.add);
        final rgba = Uint8List.fromList([7, 8, 9, 255]);
        final b64 = base64Encode(rgba);
        final mid = b64.length ~/ 2;

        // 1. Aborted 2x2 m=1 upload on i=50 is replaced cleanly by a new 1x1 m=1 upload.
        vt.writeString(
          '\x1b_Ga=t,i=50,f=32,s=2,v=2,m=1;${b64.substring(0, mid)}\x1b\\',
        );
        vt.writeString(
          '\x1b_Ga=t,i=50,f=32,s=1,v=1,m=1;${b64.substring(0, mid)}\x1b\\',
        );
        vt.writeString('\x1b_Gi=50,m=0;${b64.substring(mid)}\x1b\\');
        expect(replies, contains('\x1b_Gi=50;OK\x1b\\'));
        expect(vt.imageRegistry.lookupImage(50)?.pixelWidth, equals(1));
        expect(vt.imageRegistry.lookupImage(50)?.rgbaPixels, equals(rgba));

        // 2. Aborted a=q,m=1 on i=51 does NOT hijack a subsequent implicit a=t,m=0 upload.
        replies.clear();
        vt.writeString('\x1b_Ga=q,i=51,f=32,s=1,v=1,m=1;AAAA\x1b\\');
        vt.writeString('\x1b_Gi=51,f=32,s=1,v=1,m=0;$b64\x1b\\');
        expect(replies, contains('\x1b_Gi=51;OK\x1b\\'));
        expect(vt.imageRegistry.lookupImage(51)?.rgbaPixels, equals(rgba));

        // 3. Chunked I=7 upload repeating f=32,t=d on m=0 completes cleanly.
        replies.clear();
        vt.writeString(
          '\x1b_Ga=t,I=7,f=32,s=1,v=1,t=d,m=1;${b64.substring(0, mid)}\x1b\\',
        );
        vt.writeString('\x1b_GI=7,f=32,t=d,m=0;${b64.substring(mid)}\x1b\\');
        expect(replies.single, matches(RegExp(r'^\x1b_Gi=\d+,I=7;OK\x1b\\$')));
      },
    );

    test(
      'Tracks selective placementId clearing, multi-placement sizing, mixed U=1/direct d=a, and 32-bit continuation cells',
      () {
        final vt = VirtualTerminal(width: 10, height: 6);
        final b64 = base64Encode(Uint8List.fromList([50, 60, 70, 255]));

        // 1. Two placements (p=1 at row 0 with c=4,r=2; p=2 at row 3 with c=2,r=1).
        vt.writeString('\x1b_Ga=t,i=160,f=32,s=1,v=1,c=4,r=2;$b64\x1b\\');
        vt.writeString('\x1b[1;1H\x1b_Ga=p,i=160,p=1,c=4,r=2,C=1\x1b\\');
        vt.writeString('\x1b[4;1H\x1b_Ga=p,i=160,p=2,c=2,r=1,C=1\x1b\\');
        // Second placement must not shrink the stored image's gridCols/gridRows.
        expect(vt.imageRegistry.lookupImage(160)?.gridCols, equals(4));
        expect(vt.imageRegistry.lookupImage(160)?.gridRows, equals(2));

        // Deleting only p=1 clears row 0..1 while keeping p=2 on row 3.
        vt.writeString('\x1b_Ga=d,d=i,i=160,p=1\x1b\\');
        expect(vt.buffer.getCharacter(0, 0), equals(' '));
        expect(vt.buffer.getCharacter(3, 1), equals(' '));
        expect(
          vt.buffer.getCharacter(0, 3),
          equals(kittyPlaceholderCell(0, 0)),
        );
        expect(
          vt.buffer.getCharacter(1, 3),
          equals(kittyPlaceholderCell(0, 1)),
        );

        // 2. Mixed U=1 (p=1 with SGR 58) and direct (p=0 default + p=1) on the same imageId:
        // d=a clears both direct placements without wiping U=1 cells.
        vt.writeString(
          '\x1b_Ga=T,U=1,i=161,p=1,f=32,s=1,v=1,c=2,r=1;$b64\x1b\\',
        );
        vt.writeString(
          '\x1b[1;1H\x1b[38;2;0;0;161;58;2;0;0;1m'
          '${kittyPlaceholderCell(0, 0)}$kittyPlaceholderChar\x1b[39;59m',
        );
        vt.writeString('\x1b[2;1H\x1b_Ga=p,i=161,c=2,r=1,C=1\x1b\\');
        vt.writeString('\x1b[3;1H\x1b_Ga=p,i=161,p=1,c=2,r=1,C=1\x1b\\');
        vt.writeString('\x1b_Ga=d,d=a\x1b\\');
        expect(
          vt.buffer.getCharacter(0, 0),
          equals(kittyPlaceholderCell(0, 0)),
        );
        expect(vt.buffer.getCharacter(0, 1), equals(' '));
        expect(vt.buffer.getCharacter(1, 1), equals(' '));
        expect(vt.buffer.getCharacter(0, 2), equals(' '));
        expect(vt.buffer.getCharacter(1, 2), equals(' '));

        // 3. Direct 32-bit U+10EEEE row with 1-diacritic and bare continuations clears all 3 cols on d=i.
        const id32 = 0x120000A5;
        vt.writeString('\x1b_Ga=t,i=$id32,f=32,s=1,v=1;$b64\x1b\\');
        vt.writeString(
          '\x1b[5;1H\x1b[38;2;0;0;165m'
          '${kittyPlaceholderCell(0, 0, imageIdMsb: 0x12)}'
          '$kittyPlaceholderChar\u0305'
          '$kittyPlaceholderChar\x1b[39m',
        );
        vt.writeString('\x1b_Ga=d,d=i,i=$id32\x1b\\');
        expect(vt.buffer.getCharacter(0, 4), equals(' '));
        expect(vt.buffer.getCharacter(1, 4), equals(' '));
        expect(vt.buffer.getCharacter(2, 4), equals(' '));
      },
    );

    test(
      'Hardens POSIX local media: non-blocking FIFO rejection, nested openat walk, post-validation unlink, shm IPC blocklist, and allowLocalKittyShm opt-out',
      () {
        final rgba = Uint8List.fromList([11, 22, 33, 255]);
        final replies = <String>[];
        final vt = VirtualTerminal(
          width: 10,
          height: 5,
          onReply: replies.add,
          allowLocalKittyMedia: true,
        );

        // 1. Nested subdirectory inside systemTemp succeeds via openat walk & unlinks.
        final subDir = Directory.systemTemp.createTempSync('kitty-sub-$pid-');
        addTearDown(() {
          if (subDir.existsSync()) subDir.deleteSync(recursive: true);
        });
        final nestedFile = File(
          '${subDir.path}/tty-graphics-protocol-nested-$pid.rgba',
        )..writeAsBytesSync(rgba);
        vt.writeString(
          '\x1b_Ga=t,f=32,s=1,v=1,i=210,t=t;'
          '${base64Encode(utf8.encode(nestedFile.path))}\x1b\\',
        );
        expect(replies.last, equals('\x1b_Gi=210;OK\x1b\\'));
        expect(vt.imageRegistry.lookupImage(210)?.rgbaPixels, equals(rgba));
        expect(nestedFile.existsSync(), isFalse);

        // 2. Invalid payload (e.g. non-PNG bytes with f=100) must NOT unlink the file.
        final badPngFile = File(
          '${subDir.path}/tty-graphics-protocol-badpng-$pid.png',
        )..writeAsBytesSync(const [1, 2, 3, 4, 5, 6, 7, 8]);
        replies.clear();
        vt.writeString(
          '\x1b_Ga=t,f=100,i=211,t=t;'
          '${base64Encode(utf8.encode(badPngFile.path))}\x1b\\',
        );
        expect(replies.single, startsWith('\x1b_Gi=211;EINVAL:'));
        expect(badPngFile.existsSync(), isTrue);

        // 3. allowLocalKittyShm: false permits t=t while rejecting t=s.
        final tOnlyReplies = <String>[];
        final tOnlyVt = VirtualTerminal(
          width: 10,
          height: 5,
          onReply: tOnlyReplies.add,
          allowLocalKittyMedia: true,
          allowLocalKittyShm: false,
        );
        final tOnlyFile = File(
          '${subDir.path}/tty-graphics-protocol-tonly-$pid.rgba',
        )..writeAsBytesSync(rgba);
        tOnlyVt.writeString(
          '\x1b_Ga=t,f=32,s=1,v=1,i=212,t=t;'
          '${base64Encode(utf8.encode(tOnlyFile.path))}\x1b\\',
        );
        tOnlyVt.writeString(
          '\x1b_Ga=t,f=32,s=1,v=1,i=213,t=s;'
          '${base64Encode(utf8.encode('/icat-blocked-$pid'))}\x1b\\',
        );
        expect(
          tOnlyReplies,
          equals([
            '\x1b_Gi=212;OK\x1b\\',
            '\x1b_Gi=213;EINVAL:unsupported transmission medium\x1b\\',
          ]),
        );

        // 4. POSIX FIFO (named pipe) inside temp root is rejected immediately (no hang) and preserved.
        if (Platform.isLinux || Platform.isMacOS) {
          final fifoPath =
              '${subDir.path}/tty-graphics-protocol-fifo-$pid.rgba';
          final mkfifo = Process.runSync('mkfifo', [fifoPath]);
          if (mkfifo.exitCode == 0) {
            replies.clear();
            vt.writeString(
              '\x1b_Ga=t,f=32,s=1,v=1,i=214,t=t;'
              '${base64Encode(utf8.encode(fifoPath))}\x1b\\',
            );
            expect(replies.single, startsWith('\x1b_Gi=214;EINVAL:'));
            expect(
              FileSystemEntity.typeSync(fifoPath, followLinks: false),
              isNot(FileSystemEntityType.notFound),
            );
          }
        }

        // 5. Linux /dev/shm blocks system/browser IPC objects without reading or unlinking them,
        // while still accepting legitimate Kitty clients like kitten icat (/icat-*).
        if (Platform.isLinux && Directory('/dev/shm').existsSync()) {
          final blockedShm = File('/dev/shm/pulse-shm-termui-test-$pid')
            ..writeAsBytesSync(rgba);
          final hiddenShm = File('/dev/shm/.org.chromium.termui-test-$pid')
            ..writeAsBytesSync(rgba);
          final icatShm = File('/dev/shm/icat-termui-test-$pid')
            ..writeAsBytesSync(rgba);
          addTearDown(() {
            for (final f in [blockedShm, hiddenShm, icatShm]) {
              if (f.existsSync()) f.deleteSync();
            }
          });

          replies.clear();
          vt.writeString(
            '\x1b_Ga=t,f=32,s=1,v=1,i=215,t=s;'
            '${base64Encode(utf8.encode('/pulse-shm-termui-test-$pid'))}\x1b\\',
          );
          vt.writeString(
            '\x1b_Ga=t,f=32,s=1,v=1,i=216,t=s;'
            '${base64Encode(utf8.encode('/.org.chromium.termui-test-$pid'))}\x1b\\',
          );
          vt.writeString(
            '\x1b_Ga=t,f=32,s=1,v=1,i=217,t=s;'
            '${base64Encode(utf8.encode('/icat-termui-test-$pid'))}\x1b\\',
          );
          expect(replies[0], startsWith('\x1b_Gi=215;EINVAL:'));
          expect(replies[1], startsWith('\x1b_Gi=216;EINVAL:'));
          expect(replies[2], equals('\x1b_Gi=217;OK\x1b\\'));
          expect(blockedShm.existsSync(), isTrue);
          expect(hiddenShm.existsSync(), isTrue);
          expect(icatShm.existsSync(), isFalse);
          expect(vt.imageRegistry.lookupImage(217)?.rgbaPixels, equals(rgba));
        }
      },
    );

    test(
      'Supports live runtime updates to allowLocalKittyMedia and allowLocalKittyShm on VirtualTerminal and PtyRouter',
      () async {
        final tempFile = File(
          '${Directory.systemTemp.path}/tty-graphics-protocol-live-toggle-$pid.rgba',
        )..writeAsBytesSync(const [1, 2, 3, 4]);
        addTearDown(() {
          if (tempFile.existsSync()) tempFile.deleteSync();
        });
        final tmpB64 = base64Encode(utf8.encode(tempFile.path));

        final replies = <String>[];
        final vt = VirtualTerminal(
          width: 40,
          height: 10,
          allowLocalKittyMedia: true,
          allowLocalKittyShm: false,
          onReply: replies.add,
        );
        expect(vt.allowLocalKittyMedia, isTrue);
        expect(vt.allowLocalKittyShm, isFalse);

        // Enabled -> a=q,t=t succeeds.
        vt.writeString('\x1b_Ga=q,f=32,s=1,v=1,i=301,t=t;$tmpB64\x1b\\');
        expect(replies, equals(['\x1b_Gi=301;OK\x1b\\']));

        // Live toggle off -> subsequent a=q,t=t is immediately rejected.
        replies.clear();
        vt.allowLocalKittyMedia = false;
        expect(vt.allowLocalKittyMedia, isFalse);
        vt.writeString('\x1b_Ga=q,f=32,s=1,v=1,i=302,t=t;$tmpB64\x1b\\');
        expect(
          replies,
          equals(['\x1b_Gi=302;EINVAL:unsupported transmission medium\x1b\\']),
        );

        // Live toggle back on -> succeeds again.
        replies.clear();
        vt.allowLocalKittyMedia = true;
        vt.allowLocalKittyShm = true;
        expect(vt.allowLocalKittyShm, isTrue);
        vt.writeString('\x1b_Ga=q,f=32,s=1,v=1,i=303,t=t;$tmpB64\x1b\\');
        expect(replies, equals(['\x1b_Gi=303;OK\x1b\\']));

        // PtyRouter forwards independent allowLocalKittyMedia and allowLocalKittyShm.
        final router = PtyRouter();
        addTearDown(router.dispose);
        final backend = _FakeRoutedBackend();
        addTearDown(backend.dispose);
        final session = router.createSession(
          backend: backend,
          allowLocalKittyMedia: true,
          allowLocalKittyShm: false,
        );
        expect(session.terminal.allowLocalKittyMedia, isTrue);
        expect(session.terminal.allowLocalKittyShm, isFalse);
      },
    );
  });
}
