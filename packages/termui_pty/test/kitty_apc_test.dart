import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:test/test.dart';

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

        // Child delete-all (a=d,d=a) never wipes host global registry and never emits OK.
        final replies = <String>[];
        childA.onReply = replies.add;
        childA.writeString('\x1b_Ga=d,d=a,i=1\x1b\\');
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

        // 1. Oversized dimensions (> 4096) rejected before allocation.
        final tiny = base64Encode(Uint8List(4));
        terminal.writeString('\x1b_Gi=401,s=5000,v=1,a=t,f=32;$tiny\x1b\\');
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
        terminal.writeString('\x1b_Ga=d,d=i,i=7\x1b\\');
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
  });
}
