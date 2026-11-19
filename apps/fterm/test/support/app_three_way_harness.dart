import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_cast_server/termui_cast_server.dart';
import 'package:termui_caster_cli/termui_caster_cli.dart';

/// Minimal size-reactive fake [PtySession] for Flutter widget integration tests.
final class AppFakePtySession implements PtySession {
  /// Session label emitted on screen updates.
  final String label;

  final StreamController<Uint8List> _output =
      StreamController<Uint8List>.broadcast();
  final Completer<int> _exitCode = Completer<int>();

  /// Raw UTF-8 inputs received from remote Flutter clients.
  final List<Uint8List> writtenInputs = [];

  int _cols;
  int _rows;

  /// Creates a minimal size-reactive fake PTY.
  AppFakePtySession({
    required this.label,
    int initialCols = 80,
    int initialRows = 23,
  }) : _cols = initialCols,
       _rows = initialRows;

  /// Current PTY column width.
  int get cols => _cols;

  /// Current PTY row height.
  int get rows => _rows;

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  /// Emits a compact ANSI line describing [label] and current dimensions.
  void emitScreen() {
    if (_output.isClosed) return;
    _output.add(
      Uint8List.fromList(utf8.encode('\x1b[2J\x1b[H$label [$_cols x $_rows]')),
    );
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

  /// Most recent pixel width passed to [resize].
  int lastPixelWidth = 0;

  /// Most recent pixel height passed to [resize].
  int lastPixelHeight = 0;

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {
    lastPixelWidth = pixelWidth;
    lastPixelHeight = pixelHeight;
    if (cols == _cols && rows == _rows) return;
    _cols = cols;
    _rows = rows;
    emitScreen();
  }

  /// Completes [exitCode] cleanly with [code] and closes [output].
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
    if (!_output.isClosed) unawaited(_output.close());
    if (!_exitCode.isCompleted) _exitCode.complete(-1);
    return true;
  }
}

/// Three-way fake-WebSocket harness (`CasterService` <-> `WsRelayHandler` <-> `FtermApp`).
final class AppThreeWayWsHarness {
  /// Bearer token shared by casters and Flutter viewer channels.
  final String token;

  /// Stateless relay session registry.
  final SessionRegistry registry = SessionRegistry();

  /// Relay binary WebSocket channel handler.
  late final WsRelayHandler relayHandler;

  final List<CasterService> _casters = [];
  final Map<String, void Function()> _dropBySession = {};
  final Map<String, CasterService> _serviceBySession = {};

  /// Creates an in-memory three-way relay harness for Flutter widget tests.
  AppThreeWayWsHarness({this.token = 'app-test-secret'}) {
    relayHandler = WsRelayHandler(
      registry: registry,
      authenticator: TokenAuthenticator(casterToken: token, clientToken: token),
    );
  }

  /// Returns the running [CasterService] for [id], if started.
  CasterService? serviceOf(String id) => _serviceBySession[id];

  /// Drops the current caster WebSocket channel for [id] without killing its PTY.
  void dropCasterConnection(String id) => _dropBySession[id]?.call();

  /// Starts a faked caster session and returns its [AppFakePtySession].
  Future<AppFakePtySession> startCaster({
    required String id,
    required String title,
    int initialCols = 80,
    int initialRows = 23,
    Directory? uploadDirectory,
    Duration initialBackoff = const Duration(seconds: 5),
  }) async {
    final pty = AppFakePtySession(
      label: title,
      initialCols: initialCols,
      initialRows: initialRows,
    );
    StreamChannelController<Uint8List>? activePipe;
    final service = CasterService(
      config: CasterConfig(
        token: token,
        sessionId: SessionId(id),
        title: title,
        initialCols: initialCols,
        initialRows: initialRows,
        uploadDirPath: uploadDirectory?.path,
        command: const ['fake-pty'],
      ),
      pty: pty,
      frameCoalesceInterval: const Duration(milliseconds: 5),
      baseReconnectDelay: initialBackoff,
      channelOpener: () async {
        final pipe = StreamChannelController<Uint8List>();
        activePipe = pipe;
        relayHandler.attachCasterChannel(pipe.foreign);
        return pipe.local;
      },
    );
    await service.start();
    pty.emitScreen();
    _casters.add(service);
    _serviceBySession[id] = service;
    _dropBySession[id] = () {
      final pipe = activePipe;
      activePipe = null;
      if (pipe != null) {
        unawaited(pipe.foreign.sink.close());
      }
    };
    return pty;
  }

  /// Channel factory injected into `FtermApp(channelFactory: harness.openClientChannel)`.
  Future<StreamChannel<Uint8List>> openClientChannel() async {
    final pipe = StreamChannelController<Uint8List>();
    relayHandler.attachClientChannel(pipe.foreign);
    return pipe.local;
  }

  /// Disposes all casters and closes the relay handler and registry.
  Future<void> dispose() async {
    for (final caster in [..._casters]) {
      await caster.stop(killPty: true);
    }
    _casters.clear();
    await relayHandler.close();
    await registry.close();
  }
}

/// Pumps both real async (`GlyphAtlasGenerator` `toImage` + stream timers) and Flutter frames.
Future<void> settleCastApp(WidgetTester tester, {int cycles = 6}) async {
  for (var i = 0; i < cycles; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// Pumps real async work and Flutter frames until [condition] returns `true`
/// or wall-clock [timeout] elapses.
///
/// Returns `true` if [condition] became `true` before [timeout].
Future<bool> settleCastAppUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  Duration step = const Duration(milliseconds: 20),
}) async {
  final deadline = Stopwatch()..start();
  while (!condition() && deadline.elapsed < timeout) {
    await tester.runAsync(() async {
      await Future<void>.delayed(step);
    });
    await tester.pump(step);
  }
  return condition();
}
