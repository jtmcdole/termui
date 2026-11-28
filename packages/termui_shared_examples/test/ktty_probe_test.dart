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
      final animFrames = buildAnimatedVisualTileFrames();
      expect((raw.pixelWidth, raw.pixelHeight), equals((144, 96)));
      expect((msb.pixelWidth, msb.pixelHeight), equals((144, 96)));
      expect((png.pixelWidth, png.pixelHeight, png.format), (144, 96, 100));
      expect(animFrames, hasLength(2));
      expect(animFrames[0].imageId, equals(kttyVisualAnimatedImageId));
      expect(animFrames[1].imageId, equals(kttyVisualAnimatedImageId));
      expect(animFrames[0].version, isNot(equals(animFrames[1].version)));
      final animApc = buildAnimatedTileApcCommands(animFrames[1]);
      expect(animApc, contains('a=f,i=$kttyVisualAnimatedImageId,s='));
      expect(animApc, isNot(contains('a=f,i=$kttyVisualAnimatedImageId,r=2')));
      expect(animApc, contains('a=a,i=$kttyVisualAnimatedImageId'));
      final probeApc = buildKittyApcProbeCommands();
      expect(probeApc, contains('i=$kttyProbeAnimId,a=f,s=2,v=2,f=32,z=40'));
      expect(
        probeApc,
        isNot(contains('i=$kttyProbeAnimId,a=f,s=2,v=2,f=32,r=2')),
      );
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
      expect(report.coreUnsupportedCount, equals(18));
      expect(report.optionalDisabledCount, equals(7));
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

    test(
      'parses XTGETTCAP, DECRQSS, OSC 66 CPR, OSC 30001/30101, OSC 5522, crop/anim APC, and optional Shader/Audio/t=f replies',
      () {
        final report = KttyProbeReport()..resetForNewProbe();
        final interceptor = KttyReplyInterceptor(report);
        final wireStream =
            '\x1b_Gi=$kttyProbeCropLayerId,p=$kttyProbeCropPlacementId;OK\x1b\\'
            '\x1b_Gi=$kttyProbeAnimId,r=2;OK\x1b\\'
            '\x1b_Gi=$kttyProbeAnimId;OK\x1b\\'
            '\x1b_Gi=$kttyProbeAnimId;OK\x1b\\'
            '\x1b_Gi=$kttyProbeFileId;OK\x1b\\'
            '\x1b_Sa=caps,backend=impeller,glsl=1,xform=1,region=1,max_slots=16,max_regions=8\x1b\\'
            '\x1b_Aa=waver,q=999;AAAA\x1b\\' // mismatched q= must be ignored
            '\x1b_Aa=waver,q=$kttyProbeAudioWaveRequestId;${base64Encode(Uint8List(16))}\x1b\\'
            '\x1bP1+r524742=382f382f38\x1b\\'
            '\x1bP1+r53796e63=31\x1b\\'
            '\x1bP0+r466f6f\x1b\\'
            '\x1bP1\$r0;1m\x1b\\'
            '\x1bP1\$r2 q\x1b\\'
            '\x1b]4;255;rgb:eeee/eeee/eeee\x1b\\'
            '\x1b]4;255;rgb:0101/fefe/0202\x1b\\'
            '\x1b]4;255;rgb:eeee/eeee/eeee\x1b\\'
            '\x1b[1;1R'
            '\x1b[1;3R'
            '\x1b]5522;type=write:status=EINVAL:id=unrelated\x1b\\' // mismatched id= ignored
            '\x1b]5522;type=write:status=DONE:id=$kttyProbeOsc5522Id\x1b\\'
            // Interrupted control string followed immediately by ESC [ DA1 must preserve 0x1B!
            '\x1b]999;unterminated\x1b[?62;22c'
            // After DA1, CSI 1;2 R (Shift+F3) must pass through untouched!
            '\x1b[1;2R';

        final passthrough = BytesBuilder();
        for (final byte in utf8.encode(wireStream)) {
          passthrough.add(interceptor.processChunk([byte]));
        }

        expect(utf8.decode(passthrough.takeBytes()), equals('\x1b[1;2R'));
        expect(
          report['apc_crop_layer']?.status,
          equals(KttyCapabilityStatus.supported),
        );
        expect(
          report['apc_animation']?.status,
          equals(KttyCapabilityStatus.supported),
        );
        expect(
          report['apc_animation']?.detail,
          equals('OK (i=$kttyProbeAnimId, a=f/a/c)'),
        );
        expect(
          report['apc_file_medium']?.status,
          equals(KttyCapabilityStatus.supported),
        );
        expect(
          report['termui_shader_apc']?.status,
          equals(KttyCapabilityStatus.supported),
        );
        expect(
          report['termui_shader_apc']?.detail,
          contains('backend=impeller'),
        );
        expect(
          report['termui_audio_apc']?.status,
          equals(KttyCapabilityStatus.supported),
        );
        expect(report['termui_audio_apc']?.detail, contains('4 f32 samples'));
        expect(
          report['xtgettcap']?.status,
          equals(KttyCapabilityStatus.supported),
        );
        expect(report.xtgettcapCapabilities['RGB'], equals('8/8/8'));
        expect(report.xtgettcapCapabilities['Sync'], equals('1'));
        expect(report.xtgettcapUnsupported, contains('Foo'));
        expect(
          report['decrqss']?.status,
          equals(KttyCapabilityStatus.supported),
        );
        expect(report['decrqss']?.detail, contains('SGR=0;1m'));
        expect(report['decrqss']?.detail, contains('DECSCUSR=2 q'));
        expect(
          report['osc_30001_colors']?.status,
          equals(KttyCapabilityStatus.supported),
        );
        expect(
          report['osc_66_sizing']?.status,
          equals(KttyCapabilityStatus.supported),
        );
        expect(
          report['osc_5522_clip']?.status,
          equals(KttyCapabilityStatus.supported),
        );
      },
    );

    test(
      'flags unsupported replies for OSC 66 zero delta, OSC 30001 non-restore, OSC 5522 EINVAL, DECRQSS 0\$r, and animation error',
      () {
        final report = KttyProbeReport()..resetForNewProbe();
        final interceptor = KttyReplyInterceptor(report);
        final wireStream =
            '\x1b_Gi=$kttyProbeAnimId,r=2;OK\x1b\\'
            '\x1b_Gi=$kttyProbeAnimId;EINVAL:unsupported\x1b\\'
            '\x1b_Sa=caps,backend=none,glsl=0,xform=0,region=0\x1b\\'
            '\x1bP0+r524742\x1b\\'
            '\x1bP0\$r\x1b\\'
            '\x1b]4;255;rgb:eeee/eeee/eeee\x1b\\'
            '\x1b]4;255;rgb:0101/fefe/0202\x1b\\'
            '\x1b]4;255;rgb:0101/fefe/0202\x1b\\'
            '\x1b[5;1R'
            '\x1b[5;1R'
            '\x1b]5522;type=write:status=EINVAL:id=$kttyProbeOsc5522Id\x1b\\'
            '\x1b[?62;22c';

        interceptor.processChunk(utf8.encode(wireStream));

        expect(
          report['apc_animation']?.status,
          equals(KttyCapabilityStatus.unsupported),
        );
        expect(
          report['termui_shader_apc']?.status,
          equals(KttyCapabilityStatus.optionalDisabled),
        );
        expect(
          report['xtgettcap']?.status,
          equals(KttyCapabilityStatus.unsupported),
        );
        expect(
          report['decrqss']?.status,
          equals(KttyCapabilityStatus.unsupported),
        );
        expect(
          report['osc_30001_colors']?.status,
          equals(KttyCapabilityStatus.unsupported),
        );
        expect(
          report['osc_66_sizing']?.status,
          equals(KttyCapabilityStatus.unsupported),
        );
        expect(
          report['osc_5522_clip']?.status,
          equals(KttyCapabilityStatus.unsupported),
        );
      },
    );
  });

  group('KttyProbeReport diffAgainstBaseline & diagnostics', () {
    test(
      'detects PASS -> MISS regressions, improvements, and unchanged counts',
      () {
        final baseline = KttyProbeReport()
          ..resetForNewProbe()
          ..recordXtVersion('kitty(0.39.0)')
          ..recordXtgettcapReply('RGB', value: '8/8/8', supported: true)
          ..recordApcReply(kttyProbeFileId, 'OK')
          ..recordCursorPositionReport(1, 1)
          ..recordCursorPositionReport(1, 3)
          ..recordDa1Sentinel('62;22');

        final current = KttyProbeReport()
          ..resetForNewProbe()
          ..recordXtVersion('kitty(0.39.0)')
          ..recordDecrqssReply(valid: true, body: '0m')
          ..recordCursorPositionReport(1, 1)
          ..recordCursorPositionReport(1, 1) // regressed OSC 66
          ..recordDa1Sentinel('62;22'); // apc_file_medium -> optionalDisabled

        final baselineMap = baseline.toJsonMap();
        final diff = current.diffAgainstBaseline(baselineMap);

        expect(diff.hasRegressions, isTrue);
        expect(
          diff.regressions,
          containsAll(['xtgettcap', 'osc_66_sizing', 'apc_file_medium']),
        );
        expect(diff.improvements, equals(['decrqss']));
        expect(diff.unchangedCount, greaterThan(20));
        expect(
          diff.formatPlainSummary(ansiColor: false),
          contains('REGRESSION (PASS -> MISS): osc_66_sizing'),
        );
        expect(
          () => current.diffAgainstBaseline(const {'notCaps': 1}),
          throwsFormatException,
        );
      },
    );

    test(
      'buildDiagnosticSummary combines TERM, COLORTERM, XTGETTCAP, and tmux hints',
      () {
        final unhealthy = KttyProbeReport()
          ..resetForNewProbe()
          ..multiplexerDiagnostics = const KttyMultiplexerDiagnostics(
            multiplexer: 'tmux',
            allowPassthrough: 'off',
            hasTrueColor: false,
            hints: [kttyTmuxPassthroughHint],
          )
          ..recordDa1Sentinel('62;22');

        final hints = unhealthy.buildDiagnosticHints(
          environment: const {'TERM': 'dumb'},
        );
        expect(hints.any((h) => h.contains('TERM=xterm-256color')), isTrue);
        expect(hints.any((h) => h.contains('COLORTERM=truecolor')), isTrue);
        expect(hints.any((h) => h.contains('XTGETTCAP')), isTrue);
        expect(hints.any((h) => h.contains('allow-passthrough')), isTrue);

        final summary = unhealthy.buildDiagnosticSummary(
          environment: const {'TERM': 'dumb', 'TERM_PROGRAM': 'tmux'},
        );
        expect(summary, contains('KTTY Doctor / Environment Diagnostics'));
        expect(summary, contains('TERM         : dumb'));
        expect(summary, contains('Multiplexer  : tmux'));

        final healthy = KttyProbeReport()
          ..resetForNewProbe()
          ..recordXtVersion('termui')
          ..recordXtgettcapReply('RGB', value: '8/8/8', supported: true)
          ..recordXtgettcapReply('Smulx', value: '1', supported: true)
          ..recordXtgettcapReply('Setulc', value: '1', supported: true)
          ..recordXtgettcapReply('Sync', value: '1', supported: true)
          ..recordDecrqm(2026, 2)
          ..recordCursorPositionReport(1, 1)
          ..recordCursorPositionReport(1, 3)
          ..recordDa1Sentinel('62;22');

        final healthySummary = healthy.buildDiagnosticSummary(
          environment: const {'TERM': 'xterm-kitty', 'COLORTERM': 'truecolor'},
        );
        expect(healthySummary, contains('look healthy'));
      },
    );
  });

  group('VirtualTerminal end-to-end KTTY probe', () {
    test(
      'runKttyBatchProbe passes all 36 core capabilities and cleans up temporary probe images, placements, and animations',
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
        expect(report.coreSupportedCount, equals(36));
        expect(report.coreTotalCount, equals(36));
        expect(report.coreUnsupportedCount, equals(0));
        expect(report['decrqm_2048']?.detail, contains('48t: 96x28'));
        expect(
          report['csi_xtpushcolors']?.status,
          equals(KttyCapabilityStatus.supported),
        );
        expect(
          report['apc_rel_place']?.status,
          equals(KttyCapabilityStatus.supported),
        );
        expect(
          report['osc_5522_clip']?.status,
          equals(KttyCapabilityStatus.supported),
        );
        expect(
          report['osc_5522_read']?.status,
          equals(KttyCapabilityStatus.optionalDisabled),
        );
        expect(report['osc_5522_read']?.detail, contains('EPERM'));
        expect(
          report['osc_52_read']?.status,
          equals(KttyCapabilityStatus.optionalDisabled),
        );
        expect(
          report['termui_shader_apc']?.status,
          equals(KttyCapabilityStatus.supported),
        );
        expect(report.optionalDisabledCount, equals(6));
        expect(
          report.formatPlainReport(ansiColor: false),
          contains('36/36 core supported'),
        );
        expect(report.toJsonMap()['coreSupported'], equals(36));
        // Temporary probes (905, 906, I=907, 911 crop/layer, 912 animation, 915/916 relative) must be cleaned up before DA1.
        expect(
          vt.imageRegistry.registeredImageIds.toSet(),
          equals({kttyProbeRgbaId, kttyProbeZlibId, kttyProbePngId}),
        );
        expect(vt.imageRegistry.allPlacements, isEmpty);
        expect(vt.imageRegistry.lookupAnimation(kttyProbeAnimId), isNull);

        await replies.close();
        vt.dispose();
      },
    );

    test(
      'runKttyBatchProbe reflects clipboard read/write host policies live (EPERM vs allowed)',
      () async {
        final replies = StreamController<List<int>>.broadcast();
        final vt = VirtualTerminal(
          width: 80,
          height: 24,
          allowClipboardWrite: false,
          allowClipboardRead: true,
          onClipboardRead: (_) => 'live-clip',
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

        expect(
          report['osc_5522_clip']?.status,
          equals(KttyCapabilityStatus.optionalDisabled),
        );
        expect(report['osc_5522_clip']?.detail, contains('EPERM'));
        expect(
          report['osc_5522_read']?.status,
          equals(KttyCapabilityStatus.supported),
        );
        expect(report['osc_5522_read']?.detail, contains('allowed'));
        expect(
          report['osc_52_read']?.status,
          equals(KttyCapabilityStatus.supported),
        );
        expect(report.osc52ClipboardReply, equals('live-clip'));
        expect(report.coreUnsupportedCount, equals(0));

        await replies.close();
        vt.dispose();
      },
    );

    test(
      'runKttyBatchProbe receives async onClipboardRead replies before DA1 completes',
      () async {
        final replies = StreamController<List<int>>.broadcast();
        final vt = VirtualTerminal(
          width: 80,
          height: 24,
          allowClipboardRead: true,
          onClipboardRead: (_) => Future<String?>.microtask(() => 'async-clip'),
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
        expect(
          report['osc_5522_read']?.status,
          equals(KttyCapabilityStatus.supported),
        );
        expect(
          report['osc_52_read']?.status,
          equals(KttyCapabilityStatus.supported),
        );
        expect(report.osc52ClipboardReply, equals('async-clip'));
        expect(report.coreUnsupportedCount, equals(0));

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
        expect(initialScreen, contains('36/36 PASS'));

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
        expect(finalReport.coreSupportedCount, equals(36));
        expect(
          finalReport['osc_5522_clip']?.status,
          equals(KttyCapabilityStatus.supported),
        );
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
        expect(timedOut.coreUnsupportedCount, equals(36));
        expect(timedOut.optionalDisabledCount, equals(7));
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
      List<String> args, {
      Map<String, String>? environment,
      Future<KttyProbeReport> Function(KttyProbeOptions options)? probeOverride,
    }) async {
      final out = StringBuffer();
      final err = StringBuffer();
      final code = await ktty_cli.runKttyProbeCli(
        args,
        stdoutSink: out,
        stderrSink: err,
        stdinHasTerminal: false,
        stdoutSupportsAnsi: false,
        environment: environment,
        probeOverride: probeOverride,
      );
      return (exitCode: code, stdout: out.toString(), stderr: err.toString());
    }

    test('--help prints usage without removed flags', () async {
      final result = await runCli(const ['--help']);
      expect(result.exitCode, equals(0));
      expect(result.stdout, contains('--strict'));
      expect(result.stdout, contains('--diagnose'));
      expect(result.stdout, contains('--compare'));
      expect(result.stdout, contains('--tmux-passthrough'));
      expect(result.stdout, isNot(contains('--local-media')));
      expect(result.stdout, isNot(contains('--virtual')));
      expect(result.stdout, isNot(contains('--probe-clipboard')));
    });

    test(
      'rejects unknown/removed flags, invalid --timeout-ms, and conflicting modes with exit 64',
      () async {
        final badFlag = await runCli(const ['--does-not-exist']);
        expect(badFlag.exitCode, equals(64));

        final removedVirtual = await runCli(const ['--virtual']);
        expect(removedVirtual.exitCode, equals(64));

        final removedClipboard = await runCli(const ['--probe-clipboard']);
        expect(removedClipboard.exitCode, equals(64));

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
      '--self-test --json --strict automatically probes t=t and t=f without unlinking and cleans up',
      () async {
        final result = await runCli(const [
          '--self-test',
          '--json',
          '--strict',
        ]);
        expect(result.exitCode, equals(0), reason: result.stderr);
        expect(result.stderr, isNot(contains('unexpectedly unlinked')));
        final decoded = jsonDecode(result.stdout) as Map<String, Object?>;
        expect(decoded['coreSupported'], equals(36));
        expect(decoded['coreUnsupported'], equals(0));
        final caps = (decoded['capabilities'] as List<Object?>)
            .cast<Map<String, Object?>>();
        final tempCap = caps.firstWhere((c) => c['id'] == 'apc_temp_file');
        final fileCap = caps.firstWhere((c) => c['id'] == 'apc_file_medium');
        expect(tempCap['status'], equals('supported'));
        expect(fileCap['status'], equals('supported'));
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

    test(
      '--self-test --diagnose appends doctor block in plain and JSON modes',
      () async {
        final plain = await runCli(
          const ['--self-test', '--strict', '--diagnose'],
          environment: const {'TERM': 'xterm-kitty', 'COLORTERM': 'truecolor'},
        );
        expect(plain.exitCode, equals(0), reason: plain.stderr);
        expect(plain.stdout, contains('KTTY Doctor / Environment Diagnostics'));
        expect(plain.stdout, contains('TERM         : xterm-kitty'));
        expect(plain.stdout, contains('XTGETTCAP    : RGB'));

        final jsonRes = await runCli(
          const ['--self-test', '--json', '--diagnose'],
          environment: const {'TERM': 'dumb'},
        );
        expect(jsonRes.exitCode, equals(0), reason: jsonRes.stderr);
        final decoded = jsonDecode(jsonRes.stdout) as Map<String, Object?>;
        final diag = decoded['diagnostics'] as Map<String, Object?>;
        expect(diag['term'], equals('dumb'));
        expect((diag['hints'] as List<Object?>), isNotEmpty);
      },
    );

    test(
      '--compare exits 0 when unchanged, 1 on PASS -> MISS regression, and 64 on missing baseline',
      () async {
        final tempDir = Directory.systemTemp.createTempSync(
          'ktty-compare-test-',
        );
        addTearDown(() => tempDir.deleteSync(recursive: true));
        final baselineFile = File('${tempDir.path}/baseline.json');

        final baseRes = await runCli(const ['--self-test', '--json']);
        expect(baseRes.exitCode, equals(0));
        baselineFile.writeAsStringSync(baseRes.stdout);

        final passRes = await runCli([
          '--self-test',
          '--compare',
          baselineFile.path,
        ]);
        expect(passRes.exitCode, equals(0), reason: passRes.stderr);
        expect(passRes.stdout, contains('0 regressions'));

        final regressedReport = KttyProbeReport()
          ..resetForNewProbe()
          ..recordDa1Sentinel('62;22');
        final failRes = await runCli([
          '--report',
          '--compare',
          baselineFile.path,
          '--json',
        ], probeOverride: (_) async => regressedReport);
        expect(failRes.exitCode, equals(1));
        final failJson = jsonDecode(failRes.stdout) as Map<String, Object?>;
        final comparison = failJson['comparison'] as Map<String, Object?>;
        expect(comparison['hasRegressions'], isTrue);
        expect(
          (comparison['regressions'] as List<Object?>),
          contains('osc_66_sizing'),
        );

        final missingRes = await runCli([
          '--self-test',
          '--compare',
          '${tempDir.path}/does_not_exist.json',
        ]);
        expect(missingRes.exitCode, equals(64));
        expect(missingRes.stderr, contains('Baseline file not found'));

        // Optional capability regression (supported -> optionalDisabled) also exits 1.
        final optRegressedReport = KttyProbeReport()
          ..resetForNewProbe(options: const KttyProbeOptions())
          ..finalizePending('No local media');
        final optRegress = await runCli([
          '--self-test',
          '--compare',
          baselineFile.path,
          '--json',
        ], probeOverride: (_) async => optRegressedReport);
        expect(optRegress.exitCode, equals(1));
        final optRegressJson =
            jsonDecode(optRegress.stdout) as Map<String, Object?>;
        final optComp = optRegressJson['comparison'] as Map<String, Object?>;
        expect(
          (optComp['regressions'] as List<Object?>),
          contains('apc_file_medium'),
        );

        // Malformed JSON and missing "capabilities" exit 64.
        final brokenFile = File('${tempDir.path}/broken.json')
          ..writeAsStringSync('{broken');
        final brokenRes = await runCli([
          '--self-test',
          '--compare',
          brokenFile.path,
        ]);
        expect(brokenRes.exitCode, equals(64));

        final missingCapsFile = File('${tempDir.path}/no_caps.json')
          ..writeAsStringSync('{"coreSupported": 33}');
        final noCapsRes = await runCli([
          '--self-test',
          '--compare',
          missingCapsFile.path,
        ]);
        expect(noCapsRes.exitCode, equals(64));
        expect(noCapsRes.stderr, contains('capabilities'));

        // --compare and --diagnose require --report or --self-test.
        final compareNoMode = await runCli(['--compare', baselineFile.path]);
        expect(compareNoMode.exitCode, equals(64));
        expect(compareNoMode.stderr, contains('--report or --self-test'));

        final diagnoseNoMode = await runCli(const ['--diagnose']);
        expect(diagnoseNoMode.exitCode, equals(64));
        expect(diagnoseNoMode.stderr, contains('--report or --self-test'));
      },
    );

    test('--report without a TTY on stdin exits 2', () async {
      final result = await runCli(const ['--report']);
      expect(result.exitCode, equals(2));
      expect(result.stderr, contains('--self-test'));
    });

    test(
      'PR #504 M1: apc_animation stays pending until all 3 replies (a=f, a=a, a=c) arrive and fails on partial replies',
      () {
        final report = KttyProbeReport()..resetForNewProbe();
        // Only frame reply (a=f) arrives; a=a and a=c replies never arrive before DA1.
        report.recordApcReply(kttyProbeAnimId, 'OK', frameNumber: 2);
        expect(
          report['apc_animation']!.status,
          equals(KttyCapabilityStatus.pending),
        );

        report.finalizePending('No reply before DA1');
        expect(
          report['apc_animation']!.status,
          equals(KttyCapabilityStatus.unsupported),
        );
      },
    );

    test(
      'buildWireProbeSequence always probes OSC 5522 write/read, OSC 52 read, CSI #P/Q, relative placement, and DECSET 2048',
      () {
        final wire = KttyProbeReport.buildWireProbeSequence();
        expect(wire, contains('\x1b]5522;type=write:id=ktty-probe;'));
        expect(wire, contains('\x1b]5522;type=read:id=ktty-probe-read;'));
        expect(wire, contains('\x1b]52;c;?\x1b\\'));
        expect(wire, contains('\x1b[#P'));
        expect(wire, contains('\x1b[#Q'));
        expect(wire, contains('\x1b[?2048\$p'));
        expect(wire, contains('\x1b[?2048h\x1b[?2048l'));
        expect(
          wire,
          contains('P=$kttyProbeRelParentId,Q=$kttyProbeRelParentPlacementId'),
        );

        final report = KttyProbeReport()..resetForNewProbe();
        report.recordOsc5522Reply(
          type: 'read',
          status: 'ENOSYS',
          id: kttyProbeOsc5522ReadId,
        );
        expect(
          report['osc_5522_read']!.status,
          equals(KttyCapabilityStatus.optionalDisabled),
        );
        expect(
          report['osc_5522_read']!.detail,
          equals('type=read:status=ENOSYS'),
        );
      },
    );
  });
}
