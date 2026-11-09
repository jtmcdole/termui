import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:termui/termui.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui_pty/termui_pty.dart';
import 'package:termui_shared_examples/ktty_probe/ktty_probe.dart';
import 'package:test/test.dart';

final class _TestHostBackend implements BufferedTerminalBackend {
  final StreamController<List<int>> input =
      StreamController<List<int>>.broadcast();
  final StreamController<Point<int>> resizes =
      StreamController<Point<int>>.broadcast();
  final StringBuffer output = StringBuffer();

  @override
  Buffer? buffer;

  Point<int> _size;

  _TestHostBackend({int width = 110, int height = 34})
    : _size = Point<int>(width, height);

  @override
  bool get isWindows => false;

  @override
  Stream<List<int>> get rawInput => input.stream;

  @override
  void write(String data) => output.write(data);

  @override
  Point<int> get size => _size;

  void resize(int width, int height) {
    _size = Point<int>(width, height);
    resizes.add(_size);
  }

  @override
  Stream<Point<int>> watchSize() => resizes.stream;

  @override
  void enableRawMode() {}

  @override
  void disableRawMode() {}

  @override
  void dispose() {
    if (!input.isClosed) input.close();
    if (!resizes.isClosed) resizes.close();
  }
}

String _bufferToText(Buffer buf) {
  final sb = StringBuffer();
  for (var y = 0; y < buf.height; y++) {
    for (var x = 0; x < buf.width; x++) {
      sb.write(buf.getCharacter(x, y));
    }
    sb.writeln();
  }
  return sb.toString();
}

Future<void> _pumpEventQueue([int turns = 8]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('KTTY probe assets', () {
    test('encodeZlibStoredBlocks produces valid RFC 1950 zlib stream', () {
      final raw = Uint8List.fromList(
        List<int>.generate(256, (i) => (i * 7) & 0xFF),
      );
      final compressed = encodeZlibStoredBlocks(raw);
      final inflated = zlib.decode(compressed);
      expect(inflated, equals(raw));
    });

    test(
      'encodeRgbaPng writes valid PNG header, IHDR dimensions, and IEND',
      () {
        final rgba = Uint8List(4 * 3 * 4)..fillRange(0, 48, 200);
        final png = encodeRgbaPng(4, 3, rgba);
        expect(
          png.sublist(0, 8),
          equals([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
        );
        expect(ascii.decode(png.sublist(12, 16)), equals('IHDR'));
        final view = ByteData.sublistView(png);
        expect(view.getUint32(16), equals(4));
        expect(view.getUint32(20), equals(3));
        expect(
          ascii.decode(png.sublist(png.length - 8, png.length - 4)),
          equals('IEND'),
        );
      },
    );

    test('HiDPI visual tiles build crisp 144x96 buffers', () {
      final raw = buildRawRgbaVisualTile();
      final msb = buildMsb32BitVisualTile();
      final png = buildPngVisualTile();
      expect((raw.pixelWidth, raw.pixelHeight), equals((144, 96)));
      expect((msb.pixelWidth, msb.pixelHeight), equals((144, 96)));
      expect((png.pixelWidth, png.pixelHeight, png.format), (144, 96, 100));
    });
  });

  group('KttyReplyInterceptor', () {
    test('reassembles 1-byte chunks across APC, DCS, OSC, DECRQM, and DA1', () {
      final report = KttyProbeReport()..resetForNewProbe();
      final interceptor = KttyReplyInterceptor(report);
      final wireStream =
          '\x1b_Gi=901;OK\x1b\\'
          '\x1b_Gi=902;OK\x1b\\'
          '\x1b_Gi=903;OK\x1b\\'
          '\x1b_Gi=904;OK\x1b\\'
          '\x1b[?11u'
          '\x1bP>|kitty(0.37.0)\x1b\\'
          '\x1b]10;rgb:efef/f1f1/f5f5\x1b\\'
          '\x1b]11;#1e1e2e\x07'
          '\x1b[?2026;2\$y'
          '\x1b[?1016;1\$y'
          '\x1b[?2027;2\$y'
          '\x1b[?2004;1\$y'
          '\x1b[?1004;1\$y'
          '\x1b[?1006;1\$y'
          '\x1b[6;20;10t'
          '\x1b[8;32;100t'
          '\x1b[>1;4000;29c'
          'A'
          '\x1b[?62;22c';

      final passthrough = BytesBuilder();
      for (final byte in utf8.encode(wireStream)) {
        passthrough.add(interceptor.processChunk([byte]));
      }

      expect(report.isComplete, isTrue);
      expect(report.supportedCount, equals(17));
      expect(report.unsupportedCount, equals(0));
      expect(report.xtVersion, equals('kitty(0.37.0)'));
      expect(report.kittyKeyboardFlags, equals(11));
      expect(report.defaultForegroundHex, equals('#EFF1F5'));
      expect(report.defaultBackgroundHex, equals('#1E1E2E'));
      expect(report.cellPixelWidth, equals(10));
      expect(report.cellPixelHeight, equals(20));
      expect(report['xtwinops_18t']?.detail, equals('100x32 cells'));

      // User character 'A' and CSI ? 11 u pass through; DCS/OSC/DECRQM/DA1 are stripped.
      final forwarded = utf8.decode(passthrough.takeBytes());
      expect(forwarded, equals('\x1b[?11uA'));
    });

    test('DA1 sentinel immediately marks unanswered probes as unsupported', () {
      final report = KttyProbeReport()..resetForNewProbe();
      final interceptor = KttyReplyInterceptor(report);

      // Simulate minimal xterm that only answers DECRQM ?2004 and DA1.
      interceptor.processChunk(utf8.encode('\x1b[?2004;2\$y\x1b[?62;c'));

      expect(report.isComplete, isTrue);
      expect(report['da1']?.status, equals(KttyCapabilityStatus.supported));
      expect(
        report['decrqm_2004']?.status,
        equals(KttyCapabilityStatus.supported),
      );
      expect(
        report['apc_query']?.status,
        equals(KttyCapabilityStatus.unsupported),
      );
      expect(
        report['xtversion']?.status,
        equals(KttyCapabilityStatus.unsupported),
      );
      expect(report.pendingCount, equals(0));
    });

    test(
      'translates ?1016 SGR-Pixels coordinates to 1-based cells for InputParser',
      () {
        final report = KttyProbeReport()
          ..resetForNewProbe()
          ..recordCellPixelSize(10, 20)
          ..recordDecrqm(1016, 1);
        final interceptor = KttyReplyInterceptor(report)
          ..sgrPixelsRequested = true;

        final out = interceptor.processChunk(ascii.encode('\x1b[<0;95;45M'));
        expect(ascii.decode(out), equals('\x1b[<0;10;3M'));
        expect(
          report.lastWireMousePacket,
          contains('SGR-Pixels(?1016) btn=0 px=(95,45) -> cell=(10,3)'),
        );

        // 1-based boundary check: pixel 10 (cw=10) is rightmost pixel of col 1; pixel 11 is col 2.
        final edgeCol1 = interceptor.processChunk(
          ascii.encode('\x1b[<0;10;20M'),
        );
        expect(ascii.decode(edgeCol1), equals('\x1b[<0;1;1M'));
        final edgeCol2 = interceptor.processChunk(
          ascii.encode('\x1b[<0;11;21M'),
        );
        expect(ascii.decode(edgeCol2), equals('\x1b[<0;2;2M'));
      },
    );

    test('flushes pending bare ESC when disambiguation timer fires', () {
      final report = KttyProbeReport();
      final interceptor = KttyReplyInterceptor(report);

      expect(interceptor.processChunk(const [0x1B]), isEmpty);
      expect(interceptor.hasPendingBareEsc, isTrue);
      expect(interceptor.flushPendingEsc(), equals(const [0x1B]));
      expect(interceptor.hasPendingBareEsc, isFalse);
    });

    test('records OSC 99 activation and p=close replies into report', () {
      final report = KttyProbeReport()..resetForNewProbe();
      final interceptor = KttyReplyInterceptor(report);
      expect(report.hasOsc99Ack, isFalse);

      expect(
        interceptor.processChunk(ascii.encode('\x1b]99;i=ktty3;\x1b\\')),
        isEmpty,
      );
      expect(report.hasOsc99Ack, isTrue);
      expect(
        report.lastOsc99Ack,
        equals('id=ktty3 activated (OSC 99;i=ktty3;)'),
      );

      interceptor.processChunk(ascii.encode('\x1b]99;i=ktty3:p=close;\x1b\\'));
      expect(
        report.lastOsc99Ack,
        equals('id=ktty3 closed (p=close) (OSC 99;i=ktty3:p=close;)'),
      );
    });
  });

  group('VirtualTerminal end-to-end KTTY probe', () {
    test(
      'runKttyBatchProbe passes all 17 capabilities against VirtualTerminal',
      () async {
        final replies = StreamController<List<int>>.broadcast();
        final vt = VirtualTerminal(
          width: 96,
          height: 28,
          defaultForeground: const Color(210, 220, 235),
          defaultBackground: const Color(16, 20, 28),
          onReply: (reply) {
            final bytes = utf8.encode(reply);
            scheduleMicrotask(() {
              if (!replies.isClosed) replies.add(bytes);
            });
          },
        );

        final report = await runKttyBatchProbe(
          wireInput: replies.stream,
          onWriteWire: vt.writeString,
        );

        expect(report.isComplete, isTrue);
        expect(report.supportedCount, equals(17));
        expect(report.unsupportedCount, equals(0));
        expect(
          report.formatPlainReport(ansiColor: false),
          contains('17/17 supported'),
        );
        expect(report.toJsonMap()['supportedCount'], equals(17));

        await replies.close();
        vt.dispose();
      },
    );

    test(
      'runVirtualTerminalKttyProbe renders dashboard, graphics, OSC actions, and exits cleanly',
      () async {
        final hostBackend = _TestHostBackend(width: 110, height: 34);
        final hostTerminal = term.Terminal(hostBackend);
        Buffer? lastFrame;

        final probeFuture = runVirtualTerminalKttyProbe(
          hostTerminal,
          onFrameRedrawn: (buf) {
            lastFrame = buf;
          },
        );

        await _pumpEventQueue(16);
        expect(lastFrame, isNotNull);
        final initialScreen = _bufferToText(lastFrame!);
        expect(initialScreen, contains('VirtualTerminal Wrapper'));
        expect(initialScreen, contains('KTTY PROBE'));
        expect(initialScreen, contains('17/17 PASS'));

        // Verify U+10EEEE Kitty placeholder cells, SGR 58 underline colors, and OSC 8 URIs
        // all made it across the VirtualTerminal -> TerminalView wire!
        var placeholderCells = 0;
        var hasUnderlineColor = false;
        var hasOsc8Uri = false;
        for (var y = 0; y < lastFrame!.height; y++) {
          for (var x = 0; x < lastFrame!.width; x++) {
            final idx = y * lastFrame!.width + x;
            if ((lastFrame!.attributes[idx * 3 + 2] &
                    Modifier.kittyPlaceholder) !=
                0) {
              placeholderCells++;
            }
            if (lastFrame!.getUnderlineColor(x, y) != 0) {
              hasUnderlineColor = true;
            }
            if (lastFrame!.getUri(x, y) != null) {
              hasOsc8Uri = true;
            }
          }
        }
        expect(placeholderCells, greaterThan(40));
        expect(hasUnderlineColor, isTrue);
        expect(hasOsc8Uri, isTrue);

        // Trigger OSC 99 notification ('n'), OSC 52 clipboard ('c'), OSC 2 title ('t').
        hostBackend.input.add(utf8.encode('nct'));
        await _pumpEventQueue(16);
        final updatedScreen = _bufferToText(lastFrame!);
        expect(
          updatedScreen,
          contains('KTTY Probe #1: OSC 99 chunked notification verified!'),
        );
        expect(updatedScreen, contains('OSC 99 Toast [id=ktty1]'));
        expect(updatedScreen, contains('[Activate (ACK)]'));
        expect(updatedScreen, contains('KTTY-OSC52-Check-#1'));
        expect(updatedScreen, contains('Title: "KTTY Probe [Check #1]"'));

        // Click the [Activate (ACK)] button on the floating OSC 99 toast (col 68, row 7 in 1-based SGR).
        hostBackend.input.add(ascii.encode('\x1b[<0;68;7M\x1b[<0;68;7m'));
        await _pumpEventQueue(16);
        final ackedScreen = _bufferToText(lastFrame!);
        expect(ackedScreen, isNot(contains('OSC 99 Toast [id=ktty1]')));
        expect(ackedScreen, contains('[ACK sent]'));

        // Exit cleanly via 'q'.
        hostBackend.input.add(utf8.encode('q'));
        final finalReport = await probeFuture.timeout(
          const Duration(seconds: 3),
        );
        expect(finalReport.supportedCount, equals(17));
        expect(finalReport.hasOsc99Ack, isTrue);
        expect(
          finalReport.lastOsc99Ack,
          equals('id=ktty1 activated (OSC 99;i=ktty1;)'),
        );

        hostTerminal.dispose();
      },
    );

    test(
      'runVirtualTerminalKttyProbe syncs dynamic cellPixelSizeChanges (R3-HIGH-2) and live k keyboard flag cycle (R3-MED-4)',
      () async {
        final hostBackend = _TestHostBackend(width: 110, height: 34);
        final hostTerminal = term.Terminal(hostBackend);
        final cellPxStream = StreamController<(int, int)>.broadcast();
        addTearDown(cellPxStream.close);

        final probeFuture = runVirtualTerminalKttyProbe(
          hostTerminal,
          cellPixelWidth: 9,
          cellPixelHeight: 18,
          cellPixelSizeChanges: cellPxStream.stream,
        );

        await _pumpEventQueue(16);
        expect(hostBackend.output.toString(), contains('\x1b[=11;1u'));

        // Cycle Kitty keyboard flags via 'k' (11 -> 3 -> 1 -> 0 -> 11) and verify host output sync
        hostBackend.output.clear();
        hostBackend.input.add(utf8.encode('k'));
        await _pumpEventQueue(8);
        expect(hostBackend.output.toString(), contains('\x1b[=3;1u'));

        hostBackend.output.clear();
        hostBackend.input.add(utf8.encode('kk'));
        await _pumpEventQueue(8);
        expect(hostBackend.output.toString(), contains('\x1b[=0;1u'));

        hostBackend.output.clear();
        hostBackend.input.add(utf8.encode('k'));
        await _pumpEventQueue(8);
        expect(hostBackend.output.toString(), contains('\x1b[=11;1u'));

        // Before zoom (9x18): host 1-based (5, 5) -> inner localX=4, localY=2 -> 4*9+1=37, 2*18+1=37
        hostBackend.input.add(ascii.encode('\x1b[<0;5;5M\x1b[<0;5;5m'));
        await _pumpEventQueue(8);

        // Emit updated cell pixel size (zoom 9x18 -> 14x28) and verify end-to-end ?1016 mouse scaling
        cellPxStream.add((14, 28));
        await _pumpEventQueue(4);
        // After zoom (14x28): host 1-based (5, 5) -> inner localX=4, localY=2 -> 4*14+1=57, 2*28+1=57
        hostBackend.input.add(ascii.encode('\x1b[<0;5;5M\x1b[<0;5;5m'));
        await _pumpEventQueue(8);

        hostBackend.input.add(utf8.encode('q'));
        final report = await probeFuture.timeout(const Duration(seconds: 3));
        expect(report.cellPixelWidth, equals(14));
        expect(report.cellPixelHeight, equals(28));
        expect(
          report.lastWireMousePacket,
          contains('px=(57,57) -> cell=(5,3)'),
        );

        hostTerminal.dispose();
      },
    );

    test(
      'KttyDataTileWidget registers KittyImageRegistry.global over lower scoped registry (R3-MED-3) and guards imageId == 0 (R3-LOW-10)',
      () {
        KittyImageRegistry.clear();
        addTearDown(KittyImageRegistry.clear);

        // Fullscreen lower layer with its own scoped KittyImageRegistry
        final lowerScoped = KittyImageRegistry();
        final lowerBuffer = Buffer(20, 10)
          ..registerKittyRegistry(const Rect(0, 0, 20, 10), lowerScoped);

        // Modal overlay containing KttyDataTileWidget with imageId == 0
        final zeroIdData = KittyImageData(
          rgbaPixels: Uint8List.fromList([255, 0, 128, 255]),
          pixelWidth: 1,
          pixelHeight: 1,
          gridCols: 4,
          gridRows: 2,
          imageId: 0,
        );
        final tileEl = KttyDataTileWidget(
          imageData: zeroIdData,
        ).createElement();
        tileEl.layout(BoxConstraints.tight(const Size(4, 2)));
        final upperBuffer = Buffer(20, 10);
        tileEl.paint(upperBuffer, const Offset(2, 2));

        // 1. imageId == 0 must normalize to validId == 1 in both cell fg and global registry
        final cellChar = upperBuffer.getCharacter(2, 2);
        final cellFg = upperBuffer.getForeground(2, 2);
        expect(extractKittyCellImageId(cellChar, cellFg), equals(1));
        expect(KittyImageRegistry.global.lookupImage(1), isNotNull);

        // 2. Compositing upperBuffer above lowerBuffer must resolve KittyImageRegistry.global at (2, 2)
        final target = Buffer(20, 10);
        Compositor().composite(
          target: target,
          layers: [
            LayeredBuffer(buffer: lowerBuffer, x: 0, y: 0, zIndex: 0),
            LayeredBuffer(buffer: upperBuffer, x: 0, y: 0, zIndex: 10),
          ],
        );
        expect(
          identical(
            target.lookupKittyRegistry(2, 2),
            KittyImageRegistry.global,
          ),
          isTrue,
        );
        expect(
          identical(target.lookupKittyRegistry(0, 0), lowerScoped),
          isTrue,
        );
      },
    );
  });
}
