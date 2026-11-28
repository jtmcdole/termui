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

import '../bin/ktty_probe.dart' as ktty_cli;

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
      expect(report.supportedCount, equals(18));
      expect(report.coreUnsupportedCount, equals(8));
      expect(report.optionalDisabledCount, equals(2));
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

    test(
      'reassembles 1-byte chunks for 14t, 16t, DECRQM ?2031, CSI ?997n, OSC 22, OSC 99 p=?, and extended APC replies',
      () {
        final report = KttyProbeReport()..resetForNewProbe();
        final interceptor = KttyReplyInterceptor(report);
        final wireStream =
            '\x1b_Gi=905;OK\x1b\\'
            '\x1b_Gi=906,p=7;OK\x1b\\'
            '\x1b_Gi=42,I=907;OK\x1b\\'
            '\x1b_Gi=908;EINVAL:UNSUPPORTED medium\x1b\\'
            '\x1b_Gi=909;OK\x1b\\'
            '\x1b[4;540;900t'
            '\x1b[6;20;10t'
            '\x1b[?2031;2\$y'
            '\x1b[?997;2n'
            '\x1b]22;1,1,0\x1b\\'
            '\x1b]99;i=ktty-probe:p=?;a=report:c=1:p=title,body,close,?\x1b\\'
            '\x1b[?62;22c';

        final passthrough = BytesBuilder();
        for (final byte in utf8.encode(wireStream)) {
          passthrough.add(interceptor.processChunk([byte]));
        }

        expect(passthrough.takeBytes(), isEmpty);
        expect(report.isComplete, isTrue);
        expect(
          report['apc_chunked']?.status,
          equals(KttyCapabilityStatus.supported),
        );
        expect(report['apc_chunked']?.detail, equals('OK (i=905)'));
        expect(
          report['apc_place_persist']?.status,
          equals(KttyCapabilityStatus.supported),
        );
        expect(report['apc_place_persist']?.detail, equals('OK (i=906,p=7)'));
        expect(
          report['apc_image_num']?.status,
          equals(KttyCapabilityStatus.supported),
        );
        expect(report['apc_image_num']?.detail, equals('OK (i=42,I=907)'));
        expect(
          report['apc_temp_file']?.status,
          equals(KttyCapabilityStatus.optionalDisabled),
        );
        expect(
          report['apc_shm']?.status,
          equals(KttyCapabilityStatus.supported),
        );
        expect(report.viewportPixelWidth, equals(900));
        expect(report.viewportPixelHeight, equals(540));
        expect(report['xtwinops_14t']?.detail, equals('900x540px'));
        expect(report['xtwinops_16t']?.detail, equals('10x20px'));
        expect(
          report['decrqm_2031']?.status,
          equals(KttyCapabilityStatus.supported),
        );
        expect(report.colorScheme, equals('light'));
        expect(
          report['csi_996_scheme']?.status,
          equals(KttyCapabilityStatus.supported),
        );
        expect(
          report['osc_22_pointer']?.status,
          equals(KttyCapabilityStatus.supported),
        );
        expect(
          report['osc_99_query']?.status,
          equals(KttyCapabilityStatus.supported),
        );
        expect(report.hasOsc99Ack, isFalse);

        // Verify I=907 without i= and unknown CSI ?997;3n mode handling.
        final reportNoId = KttyProbeReport()..resetForNewProbe();
        final interceptorNoId = KttyReplyInterceptor(reportNoId);
        for (final byte in utf8.encode('\x1b_GI=907;OK\x1b\\\x1b[?997;3n')) {
          interceptorNoId.processChunk([byte]);
        }
        expect(
          reportNoId['apc_image_num']?.status,
          equals(KttyCapabilityStatus.supported),
        );
        expect(reportNoId['apc_image_num']?.detail, equals('OK (I=907)'));
        expect(
          reportNoId['csi_996_scheme']?.status,
          equals(KttyCapabilityStatus.unsupported),
        );
      },
    );
  });

  group('VirtualTerminal end-to-end KTTY probe', () {
    test(
      'runKttyBatchProbe passes all 26 core capabilities and cleans up temporary probe images',
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
        expect(report.coreSupportedCount, equals(26));
        expect(report.coreTotalCount, equals(26));
        expect(report.coreUnsupportedCount, equals(0));
        expect(report.optionalDisabledCount, equals(2));
        expect(
          report.formatPlainReport(ansiColor: false),
          contains('26/26 core supported'),
        );
        expect(report.toJsonMap()['coreSupported'], equals(26));
        // Temporary probes (905, 906, I=907) must be cleaned up before DA1.
        expect(
          vt.imageRegistry.registeredImageIds.toSet(),
          equals({kttyProbeRgbaId, kttyProbeZlibId, kttyProbePngId}),
        );

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
        expect(initialScreen, contains('Scheme:dark'));
        expect(initialScreen, contains('Ptr:default'));
        expect(initialScreen, contains('KTTY PROBE'));
        expect(initialScreen, contains('26/26 PASS'));

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
        expect(finalReport.coreSupportedCount, equals(26));
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

        // Cycle Kitty keyboard flags via 'k' (11 -> 31 -> 15 -> 3 -> 1 -> 0 -> 11) and verify host output sync
        hostBackend.output.clear();
        hostBackend.input.add(utf8.encode('k'));
        await _pumpEventQueue(8);
        expect(hostBackend.output.toString(), contains('\x1b[=31;1u'));

        hostBackend.output.clear();
        hostBackend.input.add(utf8.encode('kkkk'));
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

    test(
      'runKttyBatchProbe completes cleanly on timeout and stopHandle without double-completing',
      () async {
        final silentInput = StreamController<List<int>>.broadcast();
        addTearDown(silentInput.close);

        final timedOut = await runKttyBatchProbe(
          wireInput: silentInput.stream,
          onWriteWire: (_) {},
          timeout: const Duration(milliseconds: 25),
        );
        expect(timedOut.isComplete, isTrue);
        expect(timedOut.coreUnsupportedCount, equals(26));
        expect(timedOut.optionalDisabledCount, equals(2));
        expect(timedOut['da1']?.detail, equals('Timed out waiting for DA1'));

        final stopHandle = KttyProbeStopHandle();
        final abortFuture = runKttyBatchProbe(
          wireInput: silentInput.stream,
          onWriteWire: (_) => scheduleMicrotask(stopHandle.stop),
          timeout: const Duration(seconds: 5),
          stopHandle: stopHandle,
        );
        final aborted = await abortFuture;
        expect(aborted.isComplete, isTrue);
        expect(aborted['da1']?.detail, equals('Aborted before DA1'));
      },
    );
  });

  group('bin/ktty_probe.dart CLI flags', () {
    Future<({int exitCode, String stdout, String stderr})> runCli(
      List<String> args,
    ) async {
      final out = StringBuffer();
      final err = StringBuffer();
      final code = await ktty_cli.runKttyProbeCli(
        args,
        stdoutSink: out,
        stderrSink: err,
        stdinHasTerminal: false,
        stdoutSupportsAnsi: false,
      );
      return (exitCode: code, stdout: out.toString(), stderr: err.toString());
    }

    test('--help prints usage without requiring a local-media flag', () async {
      final result = await runCli(const ['--help']);
      expect(result.exitCode, equals(0));
      expect(result.stdout, contains('--strict'));
      expect(result.stdout, contains('--tmux-passthrough'));
      expect(result.stdout, isNot(contains('--local-media')));
    });

    test(
      'rejects unknown flags, invalid --timeout-ms, and conflicting modes with exit 64',
      () async {
        final badFlag = await runCli(const ['--does-not-exist']);
        expect(badFlag.exitCode, equals(64));

        final badTimeout = await runCli(const [
          '--self-test',
          '--timeout-ms',
          'abc',
        ]);
        expect(badTimeout.exitCode, equals(64));

        final conflict = await runCli(const ['--self-test', '--report']);
        expect(conflict.exitCode, equals(64));
      },
    );

    test(
      '--self-test --json --strict automatically probes t=t without unlinking and cleans up',
      () async {
        final result = await runCli(const [
          '--self-test',
          '--json',
          '--strict',
        ]);
        expect(result.exitCode, equals(0), reason: result.stderr);
        expect(result.stderr, isNot(contains('unexpectedly unlinked')));
        final decoded = jsonDecode(result.stdout) as Map<String, Object?>;
        expect(decoded['coreSupported'], equals(26));
        expect(decoded['coreUnsupported'], equals(0));
        final caps = (decoded['capabilities'] as List<Object?>)
            .cast<Map<String, Object?>>();
        final tempCap = caps.firstWhere((c) => c['id'] == 'apc_temp_file');
        expect(tempCap['status'], equals('supported'));
        if (Platform.isWindows) {
          final shmCap = caps.firstWhere((c) => c['id'] == 'apc_shm');
          expect(shmCap['status'], equals('optionalDisabled'));
          expect(shmCap['detail'], equals('Unavailable on this platform'));
        }
      },
    );

    test('--self-test --tmux-passthrough --strict exits 0', () async {
      final result = await runCli(const [
        '--self-test',
        '--tmux-passthrough',
        '--strict',
      ]);
      expect(result.exitCode, equals(0), reason: result.stderr);
    });

    test('--report without a TTY on stdin exits 2', () async {
      final result = await runCli(const ['--report']);
      expect(result.exitCode, equals(2));
      expect(result.stderr, contains('--self-test'));
    });
  });
}
