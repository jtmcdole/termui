import 'dart:async';
import 'dart:convert';
import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/workspace/fterm_pane_controller.dart';
import 'package:fterm/src/workspace/local_host_driver_io.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_cast_server/termui_cast_server.dart';
import 'package:termui_caster_cli/termui_caster_cli.dart';
import 'package:termui_flutter/termui_flutter.dart';
import 'package:termui_pty/termui_pty.dart';

final class _FakeRoutedPtyBackend implements RoutedPtyBackend {
  final StreamController<Uint8List> _output =
      StreamController<Uint8List>.broadcast();
  final Completer<int> _exitCode = Completer<int>();

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  void emitText(String text) {
    if (!_output.isClosed) {
      _output.add(Uint8List.fromList(utf8.encode(text)));
    }
  }

  @override
  void write(Uint8List bytes) {}

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}

  @override
  void kill() {
    if (!_exitCode.isCompleted) _exitCode.complete(0);
  }

  @override
  Future<void> dispose() async {
    kill();
    if (!_output.isClosed) await _output.close();
  }
}

final class _CastKittyRig {
  final SessionId sessionId;
  final _FakeRoutedPtyBackend backend = _FakeRoutedPtyBackend();
  late final PtyRouter router;
  late final PtyRouterSession routerSession;
  late final TerminalPort localPort;
  late final SessionRegistry registry;
  late final WsRelayHandler relayHandler;
  late final CasterService caster;
  late final WsClientTransport transport;
  late final CastClientRepository repo;
  RemoteTerminalPort? _remotePort;
  late final FtermPaneController localPane;
  FtermPaneController? _remotePane;
  final List<String> casterLogs = [];

  RemoteTerminalPort get remotePort => _remotePort!;
  FtermPaneController get remotePane => _remotePane!;

  _CastKittyRig._({required this.sessionId});

  static Future<_CastKittyRig> start({
    required String id,
    int cols = 60,
    int rows = 20,
    bool connectRemote = true,
  }) async {
    final rig = _CastKittyRig._(sessionId: SessionId(id));
    rig.router = PtyRouter();
    rig.routerSession = rig.router.createSession(
      id: id,
      backend: rig.backend,
      initialCols: cols,
      initialRows: rows,
    );
    rig.localPort = rig.routerSession.openPort(
      initialCols: cols,
      initialRows: rows,
    );
    rig.registry = SessionRegistry();
    rig.relayHandler = WsRelayHandler(
      registry: rig.registry,
      authenticator: TokenAuthenticator(
        casterToken: 'secret',
        clientToken: 'secret',
      ),
    );
    rig.caster = CasterService.fromRouterSession(
      config: CasterConfig(
        token: 'secret',
        sessionId: rig.sessionId,
        title: 'local-zsh',
        initialCols: cols,
        initialRows: rows,
        command: const ['zsh'],
      ),
      session: rig.routerSession,
      frameCoalesceInterval: const Duration(milliseconds: 5),
      onLog: rig.casterLogs.add,
      channelOpener: () async {
        final pipe = StreamChannelController<Uint8List>();
        rig.relayHandler.attachCasterChannel(pipe.foreign);
        return pipe.local;
      },
    );
    await rig.caster.start();

    rig.transport = WsClientTransport(
      token: 'secret',
      channelFactory: () async {
        final pipe = StreamChannelController<Uint8List>();
        rig.relayHandler.attachClientChannel(pipe.foreign);
        return pipe.local;
      },
    );
    rig.repo = CastClientRepository(
      transport: rig.transport,
      enableReconnect: false,
    );

    final resolver = TerminalColorResolver(
      theme: tui.TerminalColorTheme.termuiDark,
      settings: const TerminalThemeSettings(),
    );
    rig.localPane = FtermPaneController(
      paneId: 'local-$id',
      port: rig.localPort,
      colorResolver: resolver,
    )..setFocused(true);

    if (connectRemote) {
      await rig.connectRemote(cols: cols, rows: rows, resolver: resolver);
    }
    return rig;
  }

  Future<void> connectRemote({
    int cols = 60,
    int rows = 20,
    TerminalColorResolver? resolver,
  }) async {
    await repo.connect();
    final port = repo.openTerminalPort(
      sessionId,
      initialCols: cols,
      initialRows: rows,
    );
    _remotePort = port;
    _remotePane = FtermPaneController(
      paneId: 'remote-${sessionId.value}',
      port: port,
      colorResolver:
          resolver ??
          TerminalColorResolver(
            theme: tui.TerminalColorTheme.termuiDark,
            settings: const TerminalThemeSettings(),
          ),
      remoteSessionId: sessionId,
    )..setFocused(true);
  }

  Future<void> dispose() async {
    await _remotePane?.dispose();
    await _remotePort?.dispose();
    await localPane.dispose();
    await repo.dispose();
    await transport.close();
    await caster.stop(killPty: true);
    await registry.close();
    await localPort.dispose();
    await router.dispose();
  }
}

Future<T> _runRealAsync<T>(WidgetTester tester, Future<T> Function() fn) async {
  late T result;
  await tester.runAsync(() async {
    result = await Zone.root.run(fn);
  });
  return result;
}

String _encodeKittyChunkedTransmit({
  required String headerParams,
  required List<int> payloadBytes,
}) {
  final encoded = base64Encode(payloadBytes);
  if (encoded.length <= 4096) {
    return '\x1b_G$headerParams;$encoded\x1b\\';
  }
  final out = StringBuffer();
  for (var offset = 0; offset < encoded.length; offset += 4096) {
    final end = (offset + 4096).clamp(0, encoded.length);
    final more = end < encoded.length ? 1 : 0;
    final chunk = encoded.substring(offset, end);
    if (offset == 0) {
      out.write('\x1b_G$headerParams,m=$more;$chunk\x1b\\');
    } else {
      out.write('\x1b_Gm=$more;$chunk\x1b\\');
    }
  }
  return '$out';
}

String _buildSolidRgbZlibIcat({
  required int pixelWidth,
  required int pixelHeight,
  required int r,
  required int g,
  required int b,
  required int gridCols,
  required int gridRows,
  int? imageId,
}) {
  final rgb = Uint8List(pixelWidth * pixelHeight * 3);
  for (var i = 0; i < rgb.length; i += 3) {
    rgb[i] = r;
    rgb[i + 1] = g;
    rgb[i + 2] = b;
  }
  final compressed = ZLibEncoder(level: 1).convert(rgb);
  final idParam = imageId == null ? '' : 'i=$imageId,';
  return _encodeKittyChunkedTransmit(
    headerParams:
        '${idParam}a=T,f=24,o=z,s=$pixelWidth,v=$pixelHeight,c=$gridCols,r=$gridRows,q=2',
    payloadBytes: compressed,
  );
}

String _buildNoisyRgbZlibIcat({
  required int pixelWidth,
  required int pixelHeight,
  required int gridCols,
  required int gridRows,
}) {
  final rgb = _generateNoisyBytes(pixelWidth * pixelHeight * 3, stride: 3);
  final compressed = ZLibEncoder(level: 1).convert(rgb);
  return _encodeKittyChunkedTransmit(
    headerParams:
        'a=T,f=24,o=z,s=$pixelWidth,v=$pixelHeight,c=$gridCols,r=$gridRows,q=2',
    payloadBytes: compressed,
  );
}

Uint8List _generateNoisyBytes(int length, {required int stride}) {
  final bytes = Uint8List(length);
  var state = 0x9E3779B9;
  for (var i = 0; i < length; i++) {
    if (stride == 4 && (i & 3) == 3) {
      bytes[i] = 255;
      continue;
    }
    state = (state * 1664525 + 1013904223) & 0xFFFFFFFF;
    bytes[i] = (state >> 16) & 0xFF;
  }
  return bytes;
}

Future<Uint8List> _createNoisyPng(int width, int height) async {
  final rgba = _generateNoisyBytes(width * height * 4, stride: 4);
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  final img = await completer.future;
  try {
    final bd = await img.toByteData(format: ui.ImageByteFormat.png);
    return bd!.buffer.asUint8List();
  } finally {
    img.dispose();
  }
}

Future<void> _mountRemoteSurface(
  WidgetTester tester,
  _CastKittyRig rig,
  GlyphAtlasController atlas,
) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: 600,
        height: 400,
        child: TerminalSurface(
          atlasController: atlas,
          bufferProvider: rig.remotePane.readDisplayBuffer,
          bufferListenable: rig.remotePane.bufferListenable,
          cursorPositionProvider: rig.remotePane.readCursorPosition,
        ),
      ),
    ),
  );
  await _pumpAndWaitAsync(tester, cycles: 8);
}

Future<void> _pumpAndWaitAsync(WidgetTester tester, {int cycles = 12}) async {
  for (var i = 0; i < cycles; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _waitUntilCondition(
  WidgetTester tester,
  bool Function() predicate,
) async {
  for (var i = 0; i < 120 && !predicate(); i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump(const Duration(milliseconds: 20));
  }
}

bool _hasAllKittyImagesRegistered(tui.Buffer buf, int minCells) {
  final cells = _collectKittyCells(buf);
  if (cells.length < minCells) return false;
  for (final cell in cells) {
    if (buf.lookupKittyImage(cell.cellX, cell.cellY, cell.imageId) == null) {
      return false;
    }
  }
  return true;
}

Future<int> _countMatchingPixels(
  WidgetTester tester, {
  required int r,
  required int g,
  required int b,
}) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.descendant(
      of: find.byType(TerminalSurface),
      matching: find.byType(RepaintBoundary),
    ),
  );
  late Uint8List rgba;
  await tester.runAsync(() async {
    final img = await boundary.toImage(pixelRatio: 1.0);
    try {
      final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      rgba = bd!.buffer.asUint8List();
    } finally {
      img.dispose();
    }
  });
  var matches = 0;
  for (var i = 0; i < rgba.length; i += 4) {
    final dr = (rgba[i] - r).abs();
    final dg = (rgba[i + 1] - g).abs();
    final db = (rgba[i + 2] - b).abs();
    if (dr <= 15 && dg <= 15 && db <= 15 && rgba[i + 3] > 200) {
      matches++;
    }
  }
  return matches;
}

List<({int cellX, int cellY, int imageId})> _collectKittyCells(tui.Buffer buf) {
  final cells = <({int cellX, int cellY, int imageId})>[];
  for (var y = 0; y < buf.height; y++) {
    for (var x = 0; x < buf.width; x++) {
      final mods = buf.getModifiers(x, y);
      if (!tui.Modifier.has(mods, tui.Modifier.kittyPlaceholder)) continue;
      final ch = buf.getCharacter(x, y);
      final id = tui.extractKittyCellImageId(ch, buf.getForeground(x, y));
      cells.add((cellX: x, cellY: y, imageId: id));
    }
  }
  return cells;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    tui.FocusManager.instance.setPrimaryFocus(null);
  });

  group('Issue #381 Kitty images over fterm cast', () {
    testWidgets(
      'casts two 1200x900 f=24 o=z kitten icat images instead of rendering blank placeholder rows',
      (tester) async {
        final rig = await _runRealAsync(
          tester,
          () => _CastKittyRig.start(id: 'repro-1200x900'),
        );
        final atlas = GlyphAtlasController(
          fontSize: 14.0,
          fontFamily: 'Roboto Mono',
        );
        await tester.runAsync(atlas.ensureInitialized);
        addTearDown(() async {
          atlas.dispose();
          await _runRealAsync(tester, rig.dispose);
        });
        await _mountRemoteSurface(tester, rig, atlas);

        // 1. Send 1200x900 f=24,o=z (~9 KB compressed -> 4.32 MB inflated RGBA) with i=77.
        await _runRealAsync(tester, () async {
          rig.backend.emitText(
            _buildSolidRgbZlibIcat(
              pixelWidth: 1200,
              pixelHeight: 900,
              r: 20,
              g: 220,
              b: 40,
              gridCols: 12,
              gridRows: 5,
              imageId: 77,
            ),
          );
        });
        await _waitUntilCondition(
          tester,
          () => _hasAllKittyImagesRegistered(rig.remotePane.displayBuffer, 60),
        );
        await _pumpAndWaitAsync(tester, cycles: 2);

        // Local pane displays the image cleanly.
        final localCells1 = _collectKittyCells(rig.localPane.displayBuffer);
        expect(localCells1, hasLength(60));
        expect(
          rig.localPane.displayBuffer.lookupKittyImage(
            localCells1.first.cellX,
            localCells1.first.cellY,
            localCells1.first.imageId,
          ),
          isNotNull,
        );

        // Remote pane received the 60 U+10EEEE cells and must also display green pixels.
        final remoteCells1 = _collectKittyCells(rig.remotePane.displayBuffer);
        expect(remoteCells1, hasLength(60));
        expect(
          rig.remotePane.displayBuffer.lookupKittyImage(
            remoteCells1.first.cellX,
            remoteCells1.first.cellY,
            remoteCells1.first.imageId,
          ),
          isNotNull,
          reason: 'Remote image missing (${rig.casterLogs})',
        );
        expect(
          await _countMatchingPixels(tester, r: 20, g: 220, b: 40),
          greaterThan(50),
        );

        // 2. Send a second 1200x900 image; remote must render it rather than adding more blank lines.
        await _runRealAsync(tester, () async {
          rig.backend.emitText(
            '\r\n${_buildSolidRgbZlibIcat(pixelWidth: 1200, pixelHeight: 900, r: 30, g: 80, b: 240, gridCols: 12, gridRows: 5)}',
          );
        });
        await _waitUntilCondition(
          tester,
          () => _hasAllKittyImagesRegistered(rig.remotePane.displayBuffer, 120),
        );
        await _pumpAndWaitAsync(tester, cycles: 2);

        final remoteCells2 = _collectKittyCells(rig.remotePane.displayBuffer);
        expect(remoteCells2, hasLength(120));
        expect(
          rig.remotePane.displayBuffer.lookupKittyImage(
            remoteCells2.last.cellX,
            remoteCells2.last.cellY,
            remoteCells2.last.imageId,
          ),
          isNotNull,
        );
        expect(
          await _countMatchingPixels(tester, r: 30, g: 80, b: 240),
          greaterThan(50),
        );

        // 3. ABA delete + re-upload of >4 MiB i=77 (same dims, version=0) in one coalesce window
        // must replace the remote green image with yellow rather than silently keeping stale pixels.
        await _runRealAsync(tester, () async {
          rig.backend.emitText(
            '\x1b_Ga=d,d=I,i=77,q=2\x1b\\'
            '\r\n${_buildSolidRgbZlibIcat(pixelWidth: 1200, pixelHeight: 900, r: 240, g: 220, b: 20, gridCols: 12, gridRows: 5, imageId: 77)}',
          );
        });
        await _waitUntilCondition(tester, () {
          final img = rig.remotePane.displayBuffer.lookupKittyImage(0, 0, 77);
          return img != null &&
              img.rgbaPixels.isNotEmpty &&
              img.rgbaPixels[0] == 240 &&
              _hasAllKittyImagesRegistered(rig.remotePane.displayBuffer, 120);
        });
        await _pumpAndWaitAsync(tester, cycles: 2);
        expect(
          await _countMatchingPixels(tester, r: 240, g: 220, b: 20),
          greaterThan(50),
        );
      },
    );

    testWidgets(
      'casts high-entropy 1600x1200 f=24 o=z image (>4 MiB even when compressed) within 4.19 MP limit',
      (tester) async {
        final rig = await _runRealAsync(
          tester,
          () => _CastKittyRig.start(id: 'repro-1600x1200-noisy'),
        );
        final atlas = GlyphAtlasController(
          fontSize: 14.0,
          fontFamily: 'Roboto Mono',
        );
        await tester.runAsync(atlas.ensureInitialized);
        addTearDown(() async {
          atlas.dispose();
          await _runRealAsync(tester, rig.dispose);
        });
        await _mountRemoteSurface(tester, rig, atlas);

        await _runRealAsync(tester, () async {
          rig.backend.emitText(
            _buildNoisyRgbZlibIcat(
              pixelWidth: 1600,
              pixelHeight: 1200,
              gridCols: 10,
              gridRows: 4,
            ),
          );
        });
        await _waitUntilCondition(
          tester,
          () => _hasAllKittyImagesRegistered(rig.remotePane.displayBuffer, 40),
        );
        await _pumpAndWaitAsync(tester, cycles: 2);

        final localCells = _collectKittyCells(rig.localPane.displayBuffer);
        expect(localCells, hasLength(40));
        expect(
          rig.localPane.displayBuffer.lookupKittyImage(
            localCells.first.cellX,
            localCells.first.cellY,
            localCells.first.imageId,
          ),
          isNotNull,
        );

        final remoteCells = _collectKittyCells(rig.remotePane.displayBuffer);
        expect(remoteCells, hasLength(40));
        expect(
          rig.remotePane.displayBuffer.lookupKittyImage(
            remoteCells.first.cellX,
            remoteCells.first.cellY,
            remoteCells.first.imageId,
          ),
          isNotNull,
          reason: 'Remote noisy 1600x1200 image missing (${rig.casterLogs})',
        );
      },
    );

    testWidgets(
      'casts >4 MiB f=100 PNG image within 4.19 MP limit instead of leaving blank placeholder cells',
      (tester) async {
        final rig = await _runRealAsync(
          tester,
          () => _CastKittyRig.start(id: 'repro-large-png'),
        );
        final atlas = GlyphAtlasController(
          fontSize: 14.0,
          fontFamily: 'Roboto Mono',
        );
        await tester.runAsync(atlas.ensureInitialized);
        addTearDown(() async {
          atlas.dispose();
          await _runRealAsync(tester, rig.dispose);
        });
        await _mountRemoteSurface(tester, rig, atlas);

        late Uint8List pngBytes;
        await tester.runAsync(() async {
          pngBytes = await _createNoisyPng(1500, 1000);
        });
        expect(pngBytes.length, greaterThan(BufferFrameCodec.maxFrameBytes));

        await _runRealAsync(tester, () async {
          rig.backend.emitText(
            _encodeKittyChunkedTransmit(
              headerParams: 'a=T,f=100,s=1500,v=1000,c=8,r=4,q=2',
              payloadBytes: pngBytes,
            ),
          );
        });
        await _waitUntilCondition(
          tester,
          () => _hasAllKittyImagesRegistered(rig.remotePane.displayBuffer, 32),
        );
        await _pumpAndWaitAsync(tester, cycles: 2);

        final localCells = _collectKittyCells(rig.localPane.displayBuffer);
        expect(localCells, hasLength(32));
        expect(
          rig.localPane.displayBuffer.lookupKittyImage(
            localCells.first.cellX,
            localCells.first.cellY,
            localCells.first.imageId,
          ),
          isNotNull,
        );

        final remoteCells = _collectKittyCells(rig.remotePane.displayBuffer);
        expect(remoteCells, hasLength(32));
        expect(
          rig.remotePane.displayBuffer.lookupKittyImage(
            remoteCells.first.cellX,
            remoteCells.first.cellY,
            remoteCells.first.imageId,
          ),
          isNotNull,
          reason: 'Remote >4 MiB PNG missing (${rig.casterLogs})',
        );
      },
    );

    testWidgets(
      'late-joining remote tab receives pre-existing 1200x900 Kitty image via keyframe + KittyImageChunkFrames and renders green pixels on TerminalSurface',
      (tester) async {
        final rig = await _runRealAsync(
          tester,
          () => _CastKittyRig.start(
            id: 'repro-late-1200x900',
            connectRemote: false,
          ),
        );
        final atlas = GlyphAtlasController(
          fontSize: 14.0,
          fontFamily: 'Roboto Mono',
        );
        await tester.runAsync(atlas.ensureInitialized);
        addTearDown(() async {
          atlas.dispose();
          await _runRealAsync(tester, rig.dispose);
        });

        // Emit 1200x900 image locally BEFORE any remote viewer connects.
        await _runRealAsync(tester, () async {
          rig.backend.emitText(
            _buildSolidRgbZlibIcat(
              pixelWidth: 1200,
              pixelHeight: 900,
              r: 20,
              g: 220,
              b: 40,
              gridCols: 12,
              gridRows: 5,
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 40));
          await rig.connectRemote();
        });
        await _mountRemoteSurface(tester, rig, atlas);
        await _waitUntilCondition(
          tester,
          () => _hasAllKittyImagesRegistered(rig.remotePane.displayBuffer, 60),
        );
        await _pumpAndWaitAsync(tester, cycles: 2);

        final remoteCells = _collectKittyCells(rig.remotePane.displayBuffer);
        expect(remoteCells, hasLength(60));
        expect(
          rig.remotePane.displayBuffer.lookupKittyImage(
            remoteCells.first.cellX,
            remoteCells.first.cellY,
            remoteCells.first.imageId,
          ),
          isNotNull,
        );
        expect(
          await _countMatchingPixels(tester, r: 20, g: 220, b: 40),
          greaterThan(50),
        );
      },
    );

    test('IoLocalHostDriver.logShareDiagnostic logs caster skips/errors to stderr outside FLUTTER_TEST', () {
      final logged = StringBuffer();
      IoLocalHostDriver.logShareDiagnostic(
        'Skipping Kitty image id=1 (99 wire bytes)',
        environment: const {},
        sink: logged,
      );
      IoLocalHostDriver.logShareDiagnostic(
        'Server error (internal): boom',
        environment: const {},
        sink: logged,
      );
      IoLocalHostDriver.logShareDiagnostic(
        'Outbound frame queue overflow (64 frames, 1024 bytes)',
        environment: const {},
        sink: logged,
      );
      IoLocalHostDriver.logShareDiagnostic(
        'File upload error: bad sha256',
        environment: const {},
        sink: logged,
      );
      IoLocalHostDriver.logShareDiagnostic(
        'Aborted stalled file upload after idle timeout',
        environment: const {},
        sink: logged,
      );
      IoLocalHostDriver.logShareDiagnostic(
        'Registered session "s" on ws://127.0.0.1',
        environment: const {},
        sink: logged,
      );
      IoLocalHostDriver.logShareDiagnostic(
        'Skipping Kitty image id=2 (suppressed in test)',
        environment: const {'FLUTTER_TEST': 'true'},
        sink: logged,
      );
      expect('$logged', contains('[fterm cast] Skipping Kitty image id=1'));
      expect('$logged', contains('[fterm cast] Server error (internal): boom'));
      expect('$logged', contains('[fterm cast] Outbound frame queue overflow'));
      expect('$logged', contains('[fterm cast] File upload error: bad sha256'));
      expect('$logged', contains('[fterm cast] Aborted stalled file upload'));
      expect('$logged', isNot(contains('Registered session')));
      expect('$logged', isNot(contains('suppressed in test')));
    });
  });
}
