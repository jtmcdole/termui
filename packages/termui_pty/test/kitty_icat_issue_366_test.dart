import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:test/test.dart';

Uint8List _minimalPngBytes(int width, int height) {
  final header = BytesBuilder()
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add(const [0x00, 0x00, 0x00, 0x0D])
    ..add(const [0x49, 0x48, 0x44, 0x52]);
  final dims = ByteData(8)
    ..setUint32(0, width)
    ..setUint32(4, height);
  header
    ..add(dims.buffer.asUint8List())
    ..add(const [0x08, 0x06, 0x00, 0x00, 0x00])
    ..add(const [0x00, 0x00, 0x00, 0x00]);
  return header.toBytes();
}

({Uint8List rgb, String unpaddedB64}) _buildUnpaddedCompressedRgbStream(
  int width,
  int height,
) {
  final rgb = Uint8List(width * height * 3);
  for (var seed = 0; seed < 256; seed++) {
    for (var i = 0; i < rgb.length; i++) {
      rgb[i] = (i * 17 + seed * 31) & 0xFF;
    }
    final compressed = zlib.encode(rgb);
    if (compressed.length % 3 != 0) {
      final padded = base64Encode(compressed);
      final unpadded = padded.replaceAll('=', '');
      assert(unpadded.length % 4 != 0);
      return (rgb: rgb, unpaddedB64: unpadded);
    }
  }
  throw StateError('Failed to generate compressed payload with len % 3 != 0');
}

void main() {
  tearDown(KittyImageRegistry.clear);

  group('Issue #366 kitten icat and multi-row Kitty image regressions', () {
    test(
      'DetectSupport capability queries accept direct (t=d) including unpadded base64 and reject t=t, t=s, t=f',
      () {
        final replies = <String>[];
        final terminal = VirtualTerminal(
          width: 20,
          height: 6,
          onReply: replies.add,
        );

        // Exact probe patterns emitted by kitty/kittens/icat/detect.go (unpadded base64).
        final tempPathB64 = base64Encode(
          utf8.encode('/tmp/icat-probe'),
        ).replaceAll('=', '');
        final shmNameB64 = base64Encode(
          utf8.encode('/icat-shm-probe'),
        ).replaceAll('=', '');
        final filePathB64 = base64Encode(
          utf8.encode('/tmp/img.raw'),
        ).replaceAll('=', '');
        final unpaddedDirectB64 = base64Encode(const [
          1,
          2,
          3,
          4,
        ]).replaceAll('=', ''); // length == 6 (% 4 != 0)

        terminal.writeString('\x1b_Ga=q,t=d,f=24,s=1,v=1,S=3,i=1;MTIz\x1b\\');
        terminal.writeString(
          '\x1b_Ga=q,t=d,f=24,s=1,v=1,i=11;$unpaddedDirectB64\x1b\\',
        );
        terminal.writeString(
          '\x1b_Ga=q,t=t,f=24,s=1,v=1,S=3,i=2;$tempPathB64\x1b\\',
        );
        terminal.writeString(
          '\x1b_Ga=q,t=s,f=24,s=1,v=1,S=3,i=3;$shmNameB64\x1b\\',
        );
        terminal.writeString(
          '\x1b_Ga=q,t=f,f=24,s=1,v=1,S=3,i=4;$filePathB64\x1b\\',
        );

        expect(replies, contains('\x1b_Gi=1;OK\x1b\\'));
        expect(replies, contains('\x1b_Gi=11;OK\x1b\\'));
        expect(replies, isNot(contains('\x1b_Gi=2;OK\x1b\\')));
        expect(replies, isNot(contains('\x1b_Gi=3;OK\x1b\\')));
        expect(replies, isNot(contains('\x1b_Gi=4;OK\x1b\\')));
        expect(replies, contains(startsWith('\x1b_Gi=2;EINVAL:')));
        expect(replies, contains(startsWith('\x1b_Gi=3;EINVAL:')));
        expect(replies, contains(startsWith('\x1b_Gi=4;EINVAL:')));
        expect(terminal.imageRegistry.registeredImageIds, isEmpty);

        // Non-direct t=s transmit must also be rejected rather than reading filename bytes as pixels.
        replies.clear();
        terminal.writeString(
          '\x1b_Ga=T,t=s,s=1,v=1,f=24,i=5,q=1;$shmNameB64\x1b\\',
        );
        expect(terminal.imageRegistry.lookupImage(5), isNull);
        expect(terminal.buffer.getCharacter(0, 0), equals(' '));
        expect(replies, contains(startsWith('\x1b_Gi=5;EINVAL:')));
      },
    );

    test(
      'kitten icat --transfer-mode=stream unpadded RawStdEncoding + o=z + f=24 decodes, sizes by cellPixelWidth/Height, and scrolls at bottom row',
      () {
        final terminal = VirtualTerminal(
          width: 10,
          height: 5,
          cellPixelWidth: 10,
          cellPixelHeight: 20,
          maxScrollbackLines: 50,
        );
        terminal.writeString('cmd1\r\ncmd2\r\ncmd3\r\ncmd4\r\n');
        expect(terminal.cursorY, equals(4));

        final payload = _buildUnpaddedCompressedRgbStream(40, 60);
        expect(payload.unpaddedB64.length % 4, isNot(0));
        final mid = payload.unpaddedB64.length ~/ 2;

        terminal.writeString(
          '\r\x1b_Ga=T,q=2,f=24,o=z,m=1,s=40,v=60;${payload.unpaddedB64.substring(0, mid)}\x1b\\',
        );
        terminal.writeString(
          '\x1b_Ga=T,q=2;${payload.unpaddedB64.substring(mid)}\x1b\\\r\n❯ ',
        );

        final registered = terminal.imageRegistry.lookupImage(0x80000001);
        expect(registered, isNotNull);
        expect(registered!.gridCols, equals(4));
        expect(registered.gridRows, equals(3));

        for (var r = 0; r < 3; r++) {
          for (var c = 0; c < 4; c++) {
            expect(
              terminal.buffer.getCharacter(c, 1 + r),
              equals(kittyPlaceholderCell(r, c, imageIdMsb: 0x80)),
              reason: 'expected image tile ($r, $c) on screen row ${1 + r}',
            );
          }
        }
        expect(terminal.buffer.getCharacter(0, 4), equals('❯'));
        expect(terminal.buffer.getCharacter(1, 4), equals(' '));
        expect(terminal.cursorY, equals(4));
        expect(terminal.cursorX, equals(2));
      },
    );

    test(
      'Multi-row f=100 PNG at bottom row and mid-screen preserves all rows after trailing newline and zsh ED 0',
      () {
        final pngB64 = base64Encode(
          _minimalPngBytes(24, 64),
        ); // 3 cols x 4 rows

        // Bottom-of-screen prompt placement must scroll room for all 4 rows.
        final bottomVt = VirtualTerminal(
          width: 10,
          height: 5,
          maxScrollbackLines: 20,
        );
        bottomVt.writeString('line1\r\nline2\r\nline3\r\nline4\r\n');
        expect(bottomVt.cursorY, equals(4));

        bottomVt.writeString('\x1b_Ga=T,f=100;$pngB64\x1b\\\r\n\$ ');
        for (var r = 0; r < 4; r++) {
          for (var c = 0; c < 3; c++) {
            expect(
              bottomVt.buffer.getCharacter(c, r),
              equals(kittyPlaceholderCell(r, c, imageIdMsb: 0x80)),
              reason: 'bottom-row PNG must retain tile row $r at y=$r',
            );
          }
        }
        expect(bottomVt.buffer.getCharacter(0, 4), equals('\$'));
        expect(bottomVt.cursorY, equals(4));

        // Mid-screen placement must advance cursorY to the last image row so \r\n\x1b[J does not wipe rows 1..3.
        final midVt = VirtualTerminal(width: 10, height: 8);
        midVt.writeString('top\r\n');
        expect(midVt.cursorY, equals(1));

        midVt.writeString('\x1b_Ga=T,f=100,c=3,r=4;$pngB64\x1b\\\r\n\x1b[J❯ ');
        for (var r = 0; r < 4; r++) {
          for (var c = 0; c < 3; c++) {
            expect(
              midVt.buffer.getCharacter(c, 1 + r),
              equals(kittyPlaceholderCell(r, c, imageIdMsb: 0x80)),
              reason: 'mid-screen PNG must retain tile row $r at y=${1 + r}',
            );
          }
        }
        expect(midVt.buffer.getCharacter(0, 5), equals('❯'));
        expect(midVt.cursorY, equals(5));
      },
    );

    test(
      'Aborted anonymous m=1 upload does not corrupt a subsequent anonymous a=T upload',
      () {
        final terminal = VirtualTerminal(width: 8, height: 4);
        terminal.writeString('\x1b_Ga=T,q=2,f=24,s=4,v=4,m=1;AAAA\x1b\\');

        final rgbaB64 = base64Encode(Uint8List.fromList([10, 20, 30, 255]));
        terminal.writeString(
          '\x1b_Ga=T,q=2,f=32,s=1,v=1,c=2,r=2;$rgbaB64\x1b\\',
        );

        final validIds = [
          for (final id in terminal.imageRegistry.registeredImageIds)
            if (terminal.imageRegistry.lookupImage(id) case final data?
                when data.pixelWidth == 1 && data.gridCols == 2)
              id,
        ];
        expect(validIds, hasLength(1));
        final imageId = validIds.single;
        final msb = (imageId >> 24) & 0xFF;
        for (var r = 0; r < 2; r++) {
          for (var c = 0; c < 2; c++) {
            final cell = terminal.buffer.getCharacter(c, r);
            expect(cell, equals(kittyPlaceholderCell(r, c, imageIdMsb: msb)));
            expect(
              extractKittyCellImageId(
                cell,
                terminal.buffer.getForeground(c, r),
              ),
              equals(imageId),
            );
          }
        }
      },
    );

    test(
      'U=1 Unicode placeholders preserve 8-bit SGR 38;5;<id> imageId regardless of emitIndexedColors',
      () {
        for (final emitIndexed in const [false, true]) {
          final vt = VirtualTerminal(
            width: 6,
            height: 3,
            emitIndexedColors: emitIndexed,
          );
          final pxB64 = base64Encode(Uint8List.fromList([200, 100, 50, 255]));
          vt.writeString(
            '\x1b_Ga=t,U=1,i=42,s=1,v=1,f=32,c=2,r=1;$pxB64\x1b\\',
          );
          vt.writeString(
            '\x1b[38;5;42m${kittyPlaceholderCell(0, 0)}${kittyPlaceholderCell(0, 1)}\x1b[39m',
          );

          final ch0 = vt.buffer.getCharacter(0, 0);
          final fg0 = vt.buffer.getForeground(0, 0);
          expect(
            extractKittyCellImageId(ch0, fg0),
            equals(42),
            reason:
                'emitIndexedColors=$emitIndexed corrupted SGR 38;5;42 imageId',
          );
          expect(vt.buffer.lookupKittyImage(0, 0, 42), isNotNull);
        }
      },
    );

    test(
      'DECSTBM scroll-region placement (2..4) scrolls inside region without disturbing header or status bar',
      () {
        final vt = VirtualTerminal(
          width: 10,
          height: 5,
          maxScrollbackLines: 20,
        );
        vt.writeString('HEADER');
        vt.writeString('\x1b[2;1HOLDROW');
        vt.writeString('\x1b[5;1HSTATUS');
        vt.writeString('\x1b[2;4r\x1b[3;1H');

        final pxB64 = base64Encode(Uint8List.fromList([255, 0, 0, 255]));
        vt.writeString('\x1b_Ga=T,q=2,i=7,f=32,s=1,v=1,c=3,r=3;$pxB64\x1b\\');

        expect(vt.buffer.getCharacter(0, 0), equals('H'));
        expect(vt.buffer.getCharacter(5, 0), equals('R'));
        expect(vt.buffer.getCharacter(0, 4), equals('S'));
        expect(vt.buffer.getCharacter(5, 4), equals('S'));
        expect(vt.scrollback.totalLines, equals(0));

        for (var r = 0; r < 3; r++) {
          for (var c = 0; c < 3; c++) {
            expect(
              vt.buffer.getCharacter(c, 1 + r),
              equals(kittyPlaceholderCell(r, c)),
              reason: 'DECSTBM scroll should align tile row $r to y=${1 + r}',
            );
          }
        }
        expect(vt.cursorX, equals(3));
        expect(vt.cursorY, equals(3));
      },
    );

    test(
      'Alternate-screen bottom-row placement scrolls alt buffer with scrollback.totalLines == 0',
      () {
        final vt = VirtualTerminal(
          width: 10,
          height: 5,
          maxScrollbackLines: 20,
        );
        vt.writeString('PRIMARY\r\n');
        vt.writeString('\x1b[?1049h\x1b[5;1H');
        expect(vt.isUsingAlternateScreen, isTrue);

        final pxB64 = base64Encode(Uint8List.fromList([0, 255, 0, 255]));
        vt.writeString('\x1b_Ga=T,q=2,i=9,f=32,s=1,v=1,c=4,r=3;$pxB64\x1b\\');

        expect(vt.scrollback.totalLines, equals(0));
        for (var r = 0; r < 3; r++) {
          for (var c = 0; c < 4; c++) {
            expect(
              vt.buffer.getCharacter(c, 2 + r),
              equals(kittyPlaceholderCell(r, c)),
            );
          }
        }
        expect(vt.cursorX, equals(4));
        expect(vt.cursorY, equals(4));

        vt.writeString('\x1b[?1049l');
        expect(vt.buffer.getCharacter(0, 0), equals('P'));
      },
    );

    test(
      'Taller-than-viewport (rows > height) placement evicts top rows into scrollback and keeps bottom rows',
      () {
        final vt = VirtualTerminal(width: 8, height: 4, maxScrollbackLines: 20);
        final pxB64 = base64Encode(Uint8List.fromList([0, 0, 255, 255]));
        vt.writeString('\x1b_Ga=T,q=2,i=15,f=32,s=1,v=1,c=3,r=6;$pxB64\x1b\\');

        expect(vt.scrollback.totalLines, equals(2));
        for (var evictedRow = 0; evictedRow < 2; evictedRow++) {
          final sbLine = vt.scrollback[evictedRow];
          expect(sbLine, isNotNull);
          for (var c = 0; c < 3; c++) {
            expect(
              sbLine!.characters[c],
              equals(kittyPlaceholderCell(evictedRow, c)),
            );
          }
        }
        for (var y = 0; y < 4; y++) {
          for (var c = 0; c < 3; c++) {
            expect(
              vt.buffer.getCharacter(c, y),
              equals(kittyPlaceholderCell(y + 2, c)),
            );
          }
        }
        expect(vt.cursorY, equals(3));
        expect(vt.cursorX, equals(3));
      },
    );

    test(
      'C=1 static-cursor bottom-row placement clips without scrolling or moving cursor',
      () {
        final vt = VirtualTerminal(width: 8, height: 4, maxScrollbackLines: 20);
        vt.writeString('TOP\x1b[3;3H');
        expect(vt.cursorX, equals(2));
        expect(vt.cursorY, equals(2));

        final pxB64 = base64Encode(Uint8List.fromList([12, 34, 56, 255]));
        vt.writeString(
          '\x1b_Ga=T,q=2,i=21,f=32,s=1,v=1,c=3,r=4,C=1;$pxB64\x1b\\',
        );

        expect(vt.scrollback.totalLines, equals(0));
        expect(vt.buffer.getCharacter(0, 0), equals('T'));
        expect(vt.buffer.getCharacter(1, 0), equals('O'));
        expect(vt.buffer.getCharacter(2, 0), equals('P'));
        for (var r = 0; r < 2; r++) {
          for (var c = 0; c < 3; c++) {
            expect(
              vt.buffer.getCharacter(2 + c, 2 + r),
              equals(kittyPlaceholderCell(r, c)),
            );
          }
        }
        expect(vt.cursorX, equals(2));
        expect(vt.cursorY, equals(2));
      },
    );

    test(
      'Pending-wrap entry wraps before placing image under DECAWM and clips under !DECAWM',
      () {
        final vt = VirtualTerminal(width: 6, height: 3);
        final pxB64 = base64Encode(Uint8List.fromList([20, 40, 60, 255]));

        // Fill row 0 exactly so DECAWM enters pending-wrap (cursorX == width).
        vt.writeString('\x1b[1;1H123456');
        expect(vt.cursorX, equals(6));
        expect(vt.cursorY, equals(0));

        vt.writeString('\x1b_Ga=T,q=2,i=31,f=32,s=1,v=1,c=2,r=1;$pxB64\x1b\\');
        expect(
          vt.buffer.getCharacter(0, 1),
          equals(kittyPlaceholderCell(0, 0)),
        );
        expect(
          vt.buffer.getCharacter(1, 1),
          equals(kittyPlaceholderCell(0, 1)),
        );
        expect(vt.cursorX, equals(2));
        expect(vt.cursorY, equals(1));

        // Placing right to the margin enters pending-wrap again for the next image.
        vt.writeString('\x1b_Ga=T,q=2,i=32,f=32,s=1,v=1,c=4,r=1;$pxB64\x1b\\');
        expect(vt.cursorX, equals(6));
        vt.writeString('\x1b_Ga=T,q=2,i=33,f=32,s=1,v=1,c=2,r=1;$pxB64\x1b\\');
        expect(
          vt.buffer.getCharacter(0, 2),
          equals(kittyPlaceholderCell(0, 0)),
        );
        expect(vt.cursorX, equals(2));
        expect(vt.cursorY, equals(2));

        // With DECAWM disabled (?7l), reaching right margin keeps placement on row 0.
        vt.writeString('\x1b[?7l\x1b[1;1HABCDEF');
        expect(vt.cursorX, equals(5));
        expect(vt.cursorY, equals(0));
        vt.writeString('\x1b_Ga=T,q=2,i=34,f=32,s=1,v=1,c=2,r=1;$pxB64\x1b\\');
        expect(
          vt.buffer.getCharacter(5, 0),
          equals(kittyPlaceholderCell(0, 0)),
        );
        expect(vt.cursorX, equals(5));
        expect(vt.cursorY, equals(0));
      },
    );

    test(
      'a=q query validates format, zlib o=z payload, invalid base64, and >16 MiB zlib bomb',
      () {
        final replies = <String>[];
        final vt = VirtualTerminal(width: 8, height: 3, onReply: replies.add);

        vt.writeString('\x1b_Ga=q,t=d,f=999,s=1,v=1,i=41;AAAA\x1b\\');
        expect(replies, contains('\x1b_Gi=41;EINVAL:unsupported format\x1b\\'));

        final validZlibB64 = base64Encode(zlib.encode(const [1, 2, 3, 4]));
        vt.writeString(
          '\x1b_Ga=q,t=d,f=32,o=z,s=1,v=1,i=42;$validZlibB64\x1b\\',
        );
        expect(replies, contains('\x1b_Gi=42;OK\x1b\\'));

        vt.writeString('\x1b_Ga=q,t=d,f=24,s=1,v=1,i=43;***\x1b\\');
        vt.writeString('\x1b_Ga=q,t=d,f=24,s=1,v=1,i=44;A\x1b\\');
        expect(replies, contains('\x1b_Gi=43;EINVAL:invalid payload\x1b\\'));
        expect(replies, contains('\x1b_Gi=44;EINVAL:invalid payload\x1b\\'));

        final bombZlibB64 = base64Encode(
          zlib.encode(Uint8List(17 * 1024 * 1024)),
        );
        vt.writeString(
          '\x1b_Ga=q,t=d,f=32,o=z,s=1,v=1,i=45;$bombZlibB64\x1b\\',
        );
        expect(replies, contains('\x1b_Gi=45;EFBIG:payload too large\x1b\\'));
        expect(vt.imageRegistry.registeredImageIds, isEmpty);
      },
    );

    test(
      'Aborted anonymous m=1 uploads evict cleanly without EFBIG, bare a=T does not hijack explicit i=, and single-chunk i=11 preserves i=10 continuation',
      () {
        final replies = <String>[];
        final vt = VirtualTerminal(width: 10, height: 4, onReply: replies.add);

        // Two aborted 15 MiB anonymous m=1 uploads interleaved with explicit i=1
        // must evict unreachable anonymous bytes so a subsequent >2 MiB upload does not EFBIG.
        // Each APC frame stays under AnsiParser's 1.4 MB single-frame cap.
        final chunk1M = 'A' * (1024 * 1024);
        final pxB64 = base64Encode(Uint8List.fromList([11, 22, 33, 255]));
        for (var attempt = 0; attempt < 2; attempt++) {
          vt.writeString('\x1b_Ga=T,f=32,s=1,v=1,m=1;$chunk1M\x1b\\');
          for (var i = 1; i < 15; i++) {
            vt.writeString('\x1b_Gm=1;$chunk1M\x1b\\');
          }
          if (attempt == 0) {
            vt.writeString('\x1b_Ga=t,i=1,f=32,s=1,v=1;$pxB64\x1b\\');
          }
        }

        final bigRgba = Uint8List(
          1024 * 1024 * 2,
        ); // 2 MiB raw -> ~2.67 MiB b64
        final bigB64 = base64Encode(bigRgba);
        const chunkCap = 1024 * 1024;
        for (var off = 0; off < bigB64.length; off += chunkCap) {
          final end = (off + chunkCap < bigB64.length)
              ? off + chunkCap
              : bigB64.length;
          final more = end < bigB64.length ? 1 : 0;
          final ctrl = off == 0
              ? 'a=t,i=2,f=32,s=1024,v=512,m=$more'
              : 'm=$more';
          vt.writeString('\x1b_G$ctrl;${bigB64.substring(off, end)}\x1b\\');
        }
        expect(replies, contains('\x1b_Gi=2;OK\x1b\\'));
        expect(vt.imageRegistry.lookupImage(2), isNotNull);

        // Active explicit i=10 upload must survive bare anonymous a=T and single-chunk i=11.
        replies.clear();
        final fullRgba = Uint8List.fromList([10, 20, 30, 255]);
        final b64 = base64Encode(fullRgba);
        final mid = b64.length ~/ 2;
        vt.writeString(
          '\x1b_Ga=t,i=10,f=32,s=1,v=1,m=1;${b64.substring(0, mid)}\x1b\\',
        );
        // Bare anonymous a=T (no i=, no metadata) must NOT hijack i=10.
        vt.writeString('\x1b_Ga=T;$pxB64\x1b\\');
        expect(vt.imageRegistry.lookupImage(10), isNull);

        // Single-chunk i=11 mid-stream must NOT wipe _lastActiveUploadId (10).
        vt.writeString('\x1b_Ga=t,i=11,f=32,s=1,v=1;$pxB64\x1b\\');
        expect(replies, contains('\x1b_Gi=11;OK\x1b\\'));

        // Trailing m=0 without i= still completes i=10!
        vt.writeString('\x1b_Gm=0;${b64.substring(mid)}\x1b\\');
        expect(replies, contains('\x1b_Gi=10;OK\x1b\\'));
        expect(vt.imageRegistry.lookupImage(10)?.rgbaPixels, equals(fullRgba));
      },
    );

    test(
      'Chunked a=q o=z succeeds without touching imageRegistry, I=42 replies I=42 without bumping auto IDs, and o=x replies EINVAL:unsupported compression',
      () {
        final replies = <String>[];
        final vt = VirtualTerminal(width: 8, height: 3, onReply: replies.add);

        // Chunked a=q with o=z split across m=1 -> m=0 (omitting a= on final chunk).
        final validZlibB64 = base64Encode(zlib.encode(const [5, 6, 7, 8]));
        final mid = validZlibB64.length ~/ 2;
        vt.writeString(
          '\x1b_Ga=q,t=d,f=32,o=z,s=1,v=1,i=50,m=1;${validZlibB64.substring(0, mid)}\x1b\\',
        );
        expect(replies, isEmpty);
        vt.writeString('\x1b_Gm=0;${validZlibB64.substring(mid)}\x1b\\');
        expect(replies, equals(['\x1b_Gi=50;OK\x1b\\']));
        expect(vt.imageRegistry.registeredImageIds, isEmpty);

        // Chunked a=q with unsupported compression drains m=0 and replies EINVAL.
        replies.clear();
        vt.writeString('\x1b_Ga=q,t=d,f=32,o=x,i=51,m=1;AAAA\x1b\\');
        expect(replies, isEmpty);
        vt.writeString('\x1b_Gm=0;BBBB\x1b\\');
        expect(
          replies,
          equals(['\x1b_Gi=51;EINVAL:unsupported compression\x1b\\']),
        );

        // Chunked a=q exceeding 16 MiB base64 replies EFBIG on m=0.
        replies.clear();
        final chunk1M = 'A' * (1024 * 1024);
        vt.writeString('\x1b_Ga=q,t=d,f=32,i=52,m=1;$chunk1M\x1b\\');
        for (var i = 1; i < 16; i++) {
          vt.writeString('\x1b_Gm=1;$chunk1M\x1b\\');
        }
        vt.writeString('\x1b_Gm=0;$chunk1M\x1b\\');
        expect(replies, equals(['\x1b_Gi=52;EFBIG:payload too large\x1b\\']));

        // I= image-number query replies I=42 and does NOT consume _nextAutoId.
        replies.clear();
        vt.writeString('\x1b_Ga=q,t=d,f=24,s=1,v=1,I=42;AAAA\x1b\\');
        expect(replies, equals(['\x1b_GI=42;OK\x1b\\']));

        final pxB64 = base64Encode(Uint8List.fromList([1, 2, 3, 255]));
        vt.writeString('\x1b_Ga=t,f=32,s=1,v=1;$pxB64\x1b\\');
        expect(vt.imageRegistry.lookupImage(0x80000001), isNotNull);

        // Single-chunk a=q and chunked a=t reject unsupported compression o=x.
        replies.clear();
        vt.writeString('\x1b_Ga=q,t=d,f=32,o=x,i=53;AAAA\x1b\\');
        expect(
          replies,
          equals(['\x1b_Gi=53;EINVAL:unsupported compression\x1b\\']),
        );

        replies.clear();
        vt.writeString('\x1b_Ga=t,f=32,o=x,s=1,v=1,i=54,m=1;AAAA\x1b\\');
        expect(replies, isEmpty);
        vt.writeString('\x1b_Gm=0;BBBB\x1b\\');
        expect(
          replies,
          equals(['\x1b_Gi=54;EINVAL:unsupported compression\x1b\\']),
        );
        expect(vt.imageRegistry.lookupImage(54), isNull);
      },
    );

    test(
      'DECSTBM clamps placements above _scrollTop at _scrollBottom, avoids scrolling below _scrollBottom, and C=1 at pending wrap stays on current row',
      () {
        final pxB64 = base64Encode(Uint8List.fromList([90, 80, 70, 255]));

        // 1. cursorY < _scrollTop (y=0) with CSI 2;4r must scroll within rows 1..3
        //    and keep footer row 4 untouched with 0 scrollback lines.
        final topVt = VirtualTerminal(
          width: 8,
          height: 5,
          maxScrollbackLines: 20,
        );
        topVt.writeString('\x1b[5;1HFOOTER');
        topVt.writeString('\x1b[2;4r\x1b[1;1H');
        topVt.writeString(
          '\x1b_Ga=T,q=2,i=61,f=32,s=1,v=1,c=2,r=5;$pxB64\x1b\\',
        );
        expect(topVt.scrollback.totalLines, equals(0));
        expect(topVt.buffer.getCharacter(0, 4), equals('F'));
        expect(topVt.buffer.getCharacter(5, 4), equals('R'));
        expect(
          topVt.buffer.getCharacter(0, 0),
          equals(kittyPlaceholderCell(0, 0)),
        );
        expect(
          topVt.buffer.getCharacter(0, 3),
          equals(kittyPlaceholderCell(4, 0)),
        );
        expect(topVt.cursorY, equals(3));

        // 2. cursorY > _scrollBottom (CSI 2;3r, start y=3 on height 5) writes rows 3..4
        //    and stops at height - 1 without scrolling or touching header/region.
        final belowVt = VirtualTerminal(
          width: 8,
          height: 5,
          maxScrollbackLines: 20,
        );
        belowVt.writeString('HEADER');
        belowVt.writeString('\x1b[2;3r\x1b[4;1H');
        belowVt.writeString(
          '\x1b_Ga=T,q=2,i=62,f=32,s=1,v=1,c=2,r=4;$pxB64\x1b\\',
        );
        expect(belowVt.scrollback.totalLines, equals(0));
        expect(belowVt.buffer.getCharacter(0, 0), equals('H'));
        expect(
          belowVt.buffer.getCharacter(0, 3),
          equals(kittyPlaceholderCell(0, 0)),
        );
        expect(
          belowVt.buffer.getCharacter(0, 4),
          equals(kittyPlaceholderCell(1, 0)),
        );
        expect(belowVt.cursorY, equals(4));

        // 3. C=1 when cursorX == width (pending wrap) writes at width-1 on current row
        //    without wrapping or scrolling.
        final wrapVt = VirtualTerminal(
          width: 4,
          height: 2,
          maxScrollbackLines: 10,
        );
        wrapVt.writeString('\x1b[2;1H1234');
        expect(wrapVt.cursorX, equals(4));
        expect(wrapVt.cursorY, equals(1));
        wrapVt.writeString(
          '\x1b_Ga=T,q=2,i=63,f=32,s=1,v=1,c=2,r=2,C=1;$pxB64\x1b\\',
        );
        expect(wrapVt.scrollback.totalLines, equals(0));
        expect(wrapVt.buffer.getCharacter(0, 1), equals('1'));
        expect(
          wrapVt.buffer.getCharacter(3, 1),
          equals(kittyPlaceholderCell(0, 0)),
        );
        expect(wrapVt.cursorX, equals(4));
        expect(wrapVt.cursorY, equals(1));
      },
    );

    test(
      'OSC 10 foreground override does not leak onto bare U+10EEEE placeholder cells without SGR 38',
      () {
        final vt = VirtualTerminal(width: 6, height: 2);
        vt.writeString('\x1b]10;#112233\x07');
        vt.writeString('A${kittyPlaceholderCell(0, 0)}B');

        expect(vt.buffer.getCharacter(0, 0), equals('A'));
        expect(vt.buffer.getForeground(0, 0), equals(0xFF112233));

        final placeholder = vt.buffer.getCharacter(1, 0);
        expect(placeholder, equals(kittyPlaceholderCell(0, 0)));
        expect(vt.buffer.getForeground(1, 0), equals(0));
        expect(
          Modifier.has(vt.buffer.getModifiers(1, 0), Modifier.kittyPlaceholder),
          isTrue,
        );

        expect(vt.buffer.getCharacter(2, 0), equals('B'));
        expect(vt.buffer.getForeground(2, 0), equals(0xFF112233));
      },
    );

    test(
      'Implicit a=t omitting a= after aborted a=q,m=1 or a=T,m=1 registers cleanly without query hijack or placement, and mismatched I= queries do not collide',
      () {
        final replies = <String>[];
        final vt = VirtualTerminal(width: 8, height: 3, onReply: replies.add);
        final pxB64 = base64Encode(Uint8List.fromList([7, 8, 9, 255]));

        // 1. Implicit a=t (no a= key, with or without i=) after aborted a=q,m=1
        //    must register instead of being swallowed as query.
        vt.writeString('\x1b_Ga=q,t=d,f=32,i=70,m=1;AAAA\x1b\\');
        vt.writeString('\x1b_Gi=71,f=32,s=1,v=1;$pxB64\x1b\\');
        expect(replies, contains('\x1b_Gi=71;OK\x1b\\'));
        expect(vt.imageRegistry.lookupImage(71), isNotNull);

        vt.writeString('\x1b_Ga=q,t=d,f=32,m=1;AAAA\x1b\\');
        vt.writeString('\x1b_Gf=32,s=1,v=1;$pxB64\x1b\\');
        expect(vt.imageRegistry.registeredImageIds, hasLength(2));
        expect(vt.imageRegistry.lookupImage(0x80000002), isNotNull);

        // 2. Implicit a=t (no a= key, with or without i=) after aborted a=T,m=1
        //    must register without painting at cursor.
        replies.clear();
        vt.writeString('\x1b_Ga=T,f=32,s=1,v=1,m=1;AAAA\x1b\\');
        vt.writeString('\x1b_Gi=72,f=32,s=1,v=1;$pxB64\x1b\\');
        expect(replies, contains('\x1b_Gi=72;OK\x1b\\'));
        expect(vt.imageRegistry.lookupImage(72), isNotNull);
        expect(vt.buffer.getCharacter(0, 0), equals(' '));
        expect(vt.cursorX, equals(0));

        vt.writeString('\x1b_Ga=T,f=32,s=1,v=1,m=1;AAAA\x1b\\');
        vt.writeString('\x1b_Gf=32,s=1,v=1;$pxB64\x1b\\');
        expect(vt.imageRegistry.registeredImageIds, hasLength(4));
        expect(vt.imageRegistry.lookupImage(0x80000005), isNotNull);
        expect(vt.buffer.getCharacter(0, 0), equals(' '));
        expect(vt.cursorX, equals(0));

        // 3. Mismatched I= query after a=q,I=42,m=1 or anonymous a=q,m=1 must reply for I=99 cleanly.
        replies.clear();
        vt.writeString('\x1b_Ga=q,t=d,f=32,I=42,m=1;AAAA\x1b\\');
        vt.writeString('\x1b_Ga=q,I=99;AAAA\x1b\\');
        expect(replies, equals(['\x1b_GI=99;OK\x1b\\']));

        replies.clear();
        vt.writeString('\x1b_Ga=q,t=d,f=32,m=1;AAAA\x1b\\');
        vt.writeString('\x1b_Ga=q,I=99;AAAA\x1b\\');
        expect(replies, equals(['\x1b_GI=99;OK\x1b\\']));
      },
    );

    test(
      'Chunked tmux/U=1 kitten icat uploads with explicit i= on chunk 0 and repeated a= without i= continue a=T/a=t/a=q, emit OK replies, and isolate cross-action or new-metadata frames',
      () {
        final replies = <String>[];
        final vt = VirtualTerminal(
          width: 20,
          height: 6,
          cellPixelWidth: 10,
          cellPixelHeight: 20,
          onReply: replies.add,
        );

        // 1. Multi-chunk PNG (f=100, U=1) matching kitten icat inside tmux:
        //    chunk 0 carries explicit 32-bit i=, subsequent chunks repeat a=T,q=2,m=1
        //    and final chunk omits both i= and m= (a=T,q=2).
        const pngId = 0x6B3E9780; // MSB=0x6B, R=62, G=151, B=128
        final pngBytes = _minimalPngBytes(40, 40);
        final pngB64 = base64Encode(pngBytes);
        final third = pngB64.length ~/ 3;

        vt.writeString(
          '\x1b_Ga=T,q=2,f=100,m=1,U=1,s=40,v=40,c=4,r=2,i=$pngId;'
          '${pngB64.substring(0, third)}\x1b\\',
        );
        expect(vt.imageRegistry.lookupImage(pngId), isNull);

        vt.writeString(
          '\x1b_Ga=T,q=2,m=1;${pngB64.substring(third, third * 2)}\x1b\\',
        );
        expect(vt.imageRegistry.lookupImage(pngId), isNull);

        vt.writeString('\x1b_Ga=T,q=2;${pngB64.substring(third * 2)}\x1b\\');

        final registeredPng = vt.imageRegistry.lookupImage(pngId);
        expect(registeredPng, isNotNull);
        expect(registeredPng!.format, equals(KittyImageData.formatPng));
        expect(registeredPng.pixelWidth, equals(40));
        expect(registeredPng.pixelHeight, equals(40));
        expect(registeredPng.gridCols, equals(4));
        expect(registeredPng.gridRows, equals(2));
        expect(registeredPng.rgbaPixels, equals(pngBytes));
        expect(replies, isEmpty);
        // U=1 virtual upload must not write direct cells at cursor.
        expect(vt.buffer.getCharacter(0, 0), equals(' '));
        expect(vt.cursorX, equals(0));

        // Emit U+10EEEE placeholders with 24-bit RGB fg and tmux's incremental BS rewrites.
        final cell00 = kittyPlaceholderCell(0, 0, imageIdMsb: 0x6B);
        final cell01 = kittyPlaceholderCell(0, 1, imageIdMsb: 0x6B);
        vt.writeString(
          '\x1b[38;2;62;151;128m'
          '$kittyPlaceholderChar\x08'
          '${cell00.substring(0, 3)}\x08'
          '${cell00.substring(0, 4)}\x08'
          '$cell00'
          '$cell01\x1b[39m',
        );
        expect(vt.buffer.getCharacter(0, 0), equals(cell00));
        expect(vt.buffer.getCharacter(1, 0), equals(cell01));
        expect(
          extractKittyCellImageId(
            vt.buffer.getCharacter(0, 0),
            vt.buffer.getForeground(0, 0),
          ),
          equals(pngId),
        );
        expect(vt.buffer.lookupKittyImage(0, 0, pngId), equals(registeredPng));
        expect(vt.buffer.lookupKittyImage(1, 0, pngId), equals(registeredPng));

        // 2. Multi-chunk zlib RGB24 (f=24, o=z, U=1) wrapped in DCS tmux passthrough
        //    with explicit i= on chunk 0 and repeated a=T,q=2 on continuations.
        const rgbId = 0x3442C2B2;
        final rgbPayload = _buildUnpaddedCompressedRgbStream(20, 20);
        final mid = rgbPayload.unpaddedB64.length ~/ 2;
        vt.writeString(
          '\x1bPtmux;\x1b\x1b_Ga=T,q=2,f=24,o=z,m=1,U=1,s=20,v=20,c=2,r=1,i=$rgbId;'
          '${rgbPayload.unpaddedB64.substring(0, mid)}\x1b\x1b\\\x1b\\',
        );
        vt.writeString(
          '\x1bPtmux;\x1b\x1b_Ga=T,q=2;'
          '${rgbPayload.unpaddedB64.substring(mid)}\x1b\x1b\\\x1b\\',
        );

        final registeredRgb = vt.imageRegistry.lookupImage(rgbId);
        expect(registeredRgb, isNotNull);
        expect(registeredRgb!.pixelWidth, equals(20));
        expect(registeredRgb.pixelHeight, equals(20));
        expect(registeredRgb.gridCols, equals(2));
        expect(registeredRgb.gridRows, equals(1));
        expect(replies, isEmpty);

        // 3. Explicit-ID a=t (q=0) repeating a=t without i= registers and emits OK.
        final transmitPx = Uint8List.fromList([11, 22, 33, 255]);
        final transmitB64 = base64Encode(transmitPx);
        final tMid = transmitB64.length ~/ 2;
        vt.writeString(
          '\x1b_Ga=t,i=801,f=32,s=1,v=1,m=1;${transmitB64.substring(0, tMid)}\x1b\\',
        );
        expect(replies, isEmpty);
        expect(vt.imageRegistry.lookupImage(801), isNull);
        vt.writeString('\x1b_Ga=t,m=0;${transmitB64.substring(tMid)}\x1b\\');
        expect(replies, equals(['\x1b_Gi=801;OK\x1b\\']));
        expect(
          vt.imageRegistry.lookupImage(801)?.rgbaPixels,
          equals(transmitPx),
        );

        // 4. Explicit-ID a=q (q=0) repeating a=q without i= emits OK without registering.
        replies.clear();
        final queryB64 = base64Encode(zlib.encode(const [9, 8, 7, 6]));
        final qMid = queryB64.length ~/ 2;
        vt.writeString(
          '\x1b_Ga=q,t=d,f=32,o=z,s=1,v=1,i=802,m=1;${queryB64.substring(0, qMid)}\x1b\\',
        );
        expect(replies, isEmpty);
        vt.writeString('\x1b_Ga=q,m=0;${queryB64.substring(qMid)}\x1b\\');
        expect(replies, equals(['\x1b_Gi=802;OK\x1b\\']));
        expect(vt.imageRegistry.lookupImage(802), isNull);

        // 5. Explicit-ID a=T,m=1 (q=0) resists bare cross-action a=t and new-metadata a=T.
        replies.clear();
        final isoPx = Uint8List.fromList([44, 55, 66, 255]);
        final isoB64 = base64Encode(isoPx);
        final isoMid = isoB64.length ~/ 2;
        final otherPx = Uint8List.fromList([99, 88, 77, 255]);
        final otherB64 = base64Encode(otherPx);

        vt.writeString(
          '\x1b_Ga=T,i=803,f=32,s=1,v=1,U=1,m=1;${isoB64.substring(0, isoMid)}\x1b\\',
        );
        // Bare cross-action a=t (no i=, no metadata) must not hijack open a=T i=803.
        vt.writeString('\x1b_Ga=t;$otherB64\x1b\\');
        expect(vt.imageRegistry.lookupImage(803), isNull);
        expect(replies, isEmpty);

        // Single-chunk new-metadata a=T must not hijack or overwrite _lastActiveUploadId.
        vt.writeString('\x1b_Ga=T,f=32,s=1,v=1,U=1;$otherB64\x1b\\');
        expect(vt.imageRegistry.lookupImage(803), isNull);
        expect(replies, isEmpty);

        // Final repeated a=T without i= completes i=803 and emits OK.
        vt.writeString('\x1b_Ga=T;${isoB64.substring(isoMid)}\x1b\\');
        expect(replies, equals(['\x1b_Gi=803;OK\x1b\\']));
        expect(vt.imageRegistry.lookupImage(803)?.rgbaPixels, equals(isoPx));
      },
    );
  });
}
