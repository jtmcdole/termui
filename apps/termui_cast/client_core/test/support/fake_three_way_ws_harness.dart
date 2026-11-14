import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:stream_channel/stream_channel.dart';
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_cast_server/termui_cast_server.dart';
import 'package:termui_caster_cli/termui_caster_cli.dart';

/// Deterministic fake [PtySession] that redraws a box border and `[cols x rows]`
/// label whenever started or resized.
final class SizeReactiveFakePtySession implements PtySession {
  /// Session display banner drawn inside the top-left of the box.
  final String banner;

  /// Whether DECSET SGR mouse tracking (`1000` + `1006`) is emitted on redraw.
  final bool enableMouseTracking;

  final StreamController<Uint8List> _output =
      StreamController<Uint8List>.broadcast();
  final Completer<int> _exitCode = Completer<int>();

  /// Recorded raw input payloads written by remote clients.
  final List<Uint8List> writtenInputs = [];

  /// Recorded `(cols, rows)` resize requests applied to this PTY.
  final List<(int cols, int rows)> resizeHistory = [];

  int _cols;
  int _rows;

  /// Creates a size-reactive fake PTY starting at `([initialCols], [initialRows])`.
  SizeReactiveFakePtySession({
    required this.banner,
    int initialCols = 80,
    int initialRows = 24,
    this.enableMouseTracking = false,
  }) : _cols = initialCols,
       _rows = initialRows;

  /// Current PTY width in columns.
  int get cols => _cols;

  /// Current PTY height in rows.
  int get rows => _rows;

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  /// Emits the full bordered ANSI screen for the current `([cols], [rows])`.
  void emitScreen() {
    if (_output.isClosed) return;
    final w = max(4, _cols);
    final h = max(4, _rows);
    final sb = StringBuffer()..write('\x1b[2J\x1b[H');
    if (enableMouseTracking) {
      sb.write('\x1b[?1000h\x1b[?1006h');
    }
    final innerW = max(0, w - 2);
    sb.write('\x1b[1;1H\x1b[38;2;110;200;255m┌${'─' * innerW}┐');
    for (var row = 2; row < h; row++) {
      sb
        ..write('\x1b[$row;1H│')
        ..write('\x1b[$row;${w}H│');
    }
    sb.write('\x1b[$h;1H└${'─' * innerW}┘\x1b[0m');

    if (h >= 3 && innerW >= 2) {
      final clippedBanner = banner.length > innerW - 1
          ? banner.substring(0, innerW - 1)
          : banner;
      sb.write('\x1b[2;3H\x1b[1;38;2;255;220;120m$clippedBanner\x1b[0m');
    }
    if (h >= 4 && innerW >= 2) {
      final sizeLabel = 'PTY [$w x $h]';
      final clippedSize = sizeLabel.length > innerW - 1
          ? sizeLabel.substring(0, innerW - 1)
          : sizeLabel;
      sb.write('\x1b[3;3H\x1b[38;2;150;240;180m$clippedSize\x1b[0m');
    }
    if (h >= 5 && innerW >= 4) {
      sb.write('\x1b[4;3H> ');
    }
    _output.add(Uint8List.fromList(utf8.encode('$sb')));
  }

  /// Writes arbitrary UTF-8 [ansi] output from the fake child process.
  void emitRawAnsi(String ansi) {
    if (!_output.isClosed) {
      _output.add(Uint8List.fromList(utf8.encode(ansi)));
    }
  }

  @override
  void writeBytes(Uint8List data) {
    writtenInputs.add(Uint8List.fromList(data));
  }

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {
    resizeHistory.add((cols, rows));
    if (cols == _cols && rows == _rows) return;
    _cols = cols;
    _rows = rows;
    emitScreen();
  }

  /// Completes [exitCode] with [code] and closes [output].
  Future<void> finish([int code = 0]) async {
    if (!_output.isClosed) {
      await _output.close();
    }
    if (!_exitCode.isCompleted) {
      _exitCode.complete(code);
    }
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    unawaited(finish(-1));
    return true;
  }
}

/// Active caster handle inside [FakeThreeWayWsHarness].
final class HarnessCasterHandle {
  /// Session identifier registered on the relay server.
  final SessionId sessionId;

  /// Fake PTY backing [service].
  final SizeReactiveFakePtySession pty;

  /// Running caster service streaming frames over an in-memory channel.
  final CasterService service;

  final void Function() _dropTransport;

  HarnessCasterHandle({
    required this.sessionId,
    required this.pty,
    required this.service,
    required void Function() dropTransport,
  }) : _dropTransport = dropTransport;

  /// Simulates an unexpected WebSocket disconnect of the current caster pipe.
  void dropConnection() => _dropTransport();
}

/// Active viewer handle inside [FakeThreeWayWsHarness].
final class HarnessViewerHandle {
  /// Client WebSocket transport over an in-memory channel.
  final WsClientTransport transport;

  /// Client repository bound to [transport].
  final CastClientRepository repository;

  HarnessViewerHandle({required this.transport, required this.repository});

  /// Disposes [repository].
  Future<void> dispose() => repository.dispose();
}

/// In-memory three-way WebSocket harness (`CasterService` <-> `WsRelayHandler` <-> `WsClientTransport`).
final class FakeThreeWayWsHarness {
  /// Shared bearer token used across the faked caster and client channels.
  final String token;

  /// Stateless relay session registry.
  final SessionRegistry registry;

  /// Relay binary channel handler.
  late final WsRelayHandler relayHandler;

  final List<HarnessCasterHandle> _casters = [];
  final List<HarnessViewerHandle> _viewers = [];

  /// Creates an in-memory three-way relay harness.
  FakeThreeWayWsHarness({this.token = 'fake-ws-secret'})
    : registry = SessionRegistry() {
    relayHandler = WsRelayHandler(
      registry: registry,
      authenticator: TokenAuthenticator(casterToken: token, clientToken: token),
    );
  }

  /// Spawns and connects a faked caster session to [relayHandler].
  Future<HarnessCasterHandle> startCaster({
    required String id,
    required String title,
    String? banner,
    int initialCols = 80,
    int initialRows = 23,
    bool enableMouseTracking = false,
    Duration initialBackoff = const Duration(seconds: 5),
  }) async {
    final sessionId = SessionId(id);
    final pty = SizeReactiveFakePtySession(
      banner: banner ?? title,
      initialCols: initialCols,
      initialRows: initialRows,
      enableMouseTracking: enableMouseTracking,
    );
    void Function()? dropActive;
    final service = CasterService(
      config: CasterConfig(
        token: token,
        sessionId: sessionId,
        title: title,
        initialCols: initialCols,
        initialRows: initialRows,
        command: const ['fake-shell'],
      ),
      pty: pty,
      baseReconnectDelay: initialBackoff,
      channelOpener: () async {
        final casterIn = StreamController<Uint8List>();
        final casterOut = StreamController<Uint8List>.broadcast();
        final serverIn = StreamController<Uint8List>();
        final serverOut = StreamController<Uint8List>.broadcast();
        final c2s = casterOut.stream.listen(
          (b) {
            if (!serverIn.isClosed) serverIn.add(b);
          },
          onDone: () {
            if (!serverIn.isClosed) unawaited(serverIn.close());
          },
        );
        final s2c = serverOut.stream.listen(
          (b) {
            if (!casterIn.isClosed) casterIn.add(b);
          },
          onDone: () {
            if (!casterIn.isClosed) unawaited(casterIn.close());
          },
        );
        dropActive = () {
          unawaited(c2s.cancel());
          unawaited(s2c.cancel());
          if (!casterIn.isClosed) unawaited(casterIn.close());
          if (!serverIn.isClosed) unawaited(serverIn.close());
        };
        relayHandler.attachCasterChannel(
          StreamChannel<Uint8List>(serverIn.stream, serverOut.sink),
        );
        return StreamChannel<Uint8List>(casterIn.stream, casterOut.sink);
      },
    );
    await service.start();
    pty.emitScreen();

    final handle = HarnessCasterHandle(
      sessionId: sessionId,
      pty: pty,
      service: service,
      dropTransport: () {
        final drop = dropActive;
        dropActive = null;
        drop?.call();
      },
    );
    _casters.add(handle);
    return handle;
  }

  /// Opens a fresh binary client channel attached to [relayHandler].
  Future<StreamChannel<Uint8List>> openClientChannel() async {
    final pipe = StreamChannelController<Uint8List>();
    relayHandler.attachClientChannel(pipe.foreign);
    return pipe.local;
  }

  /// Connects a faked viewer client to [relayHandler].
  Future<HarnessViewerHandle> connectViewer({
    String? clientToken,
    bool autoConnect = true,
  }) async {
    final transport = WsClientTransport(
      token: clientToken ?? token,
      channelFactory: openClientChannel,
    );
    final repository = CastClientRepository(transport: transport);
    if (autoConnect) {
      await repository.connect();
    }

    final viewer = HarnessViewerHandle(
      transport: transport,
      repository: repository,
    );
    _viewers.add(viewer);
    return viewer;
  }

  /// Disposes all viewers, casters, and the relay registry.
  Future<void> dispose() async {
    for (final viewer in [..._viewers]) {
      await viewer.dispose();
    }
    _viewers.clear();
    for (final caster in [..._casters]) {
      await caster.service.stop(killPty: true);
    }
    _casters.clear();
    await registry.close();
  }
}
