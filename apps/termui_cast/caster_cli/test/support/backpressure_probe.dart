import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:isolate' as isolate;
import 'dart:typed_data';

import 'package:stream_channel/stream_channel.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_caster_cli/termui_caster_cli.dart';

const String probeJsonPrefix = 'PROBE_JSON:';

final class _VmHeapProbe {
  final WebSocket _socket;
  final StreamIterator<Object?> _messages;
  final String _isolateId;
  int _nextId = 0;

  _VmHeapProbe._(this._socket, this._isolateId)
    : _messages = StreamIterator<Object?>(_socket);

  static Future<_VmHeapProbe> connect() async {
    final info = await Service.getInfo();
    final wsUri = info.serverWebSocketUri;
    if (wsUri == null) {
      throw StateError(
        'VM service is not enabled; pass --enable-vm-service=0.',
      );
    }
    final isolateId = Service.getIsolateId(isolate.Isolate.current);
    if (isolateId == null) {
      throw StateError('Unable to resolve current isolate ID.');
    }
    final socket = await WebSocket.connect(wsUri.toString());
    return _VmHeapProbe._(socket, isolateId);
  }

  Future<int> liveHeapBytesAfterGc() async {
    final id = '${++_nextId}';
    _socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': 'getAllocationProfile',
        'params': {'isolateId': _isolateId, 'gc': true},
      }),
    );
    if (!await _messages.moveNext()) {
      throw StateError('VM service WebSocket closed before replying.');
    }
    final raw = _messages.current;
    if (raw is! String) {
      throw StateError('Unexpected non-string VM service frame: $raw');
    }
    final decoded = jsonDecode(raw) as Map<String, Object?>;
    final result = decoded['result'] as Map<String, Object?>;
    final memoryUsage = result['memoryUsage'] as Map<String, Object?>;
    return memoryUsage['heapUsage'] as int;
  }

  Future<void> close() async {
    await _messages.cancel();
    await _socket.close();
  }
}

final class _SyntheticFloodPty implements PtySession {
  static final Uint8List _chunk = Uint8List.fromList(
    ('y\r\n' * 1024).codeUnits,
  );

  final StreamController<Uint8List> _controller = StreamController<Uint8List>(
    sync: true,
  );
  final Completer<int> _exitCode = Completer<int>();
  bool _stopped = false;
  bool _ackPending = false;

  void start() => _scheduleNextChunk();

  void _scheduleNextChunk() {
    if (_stopped || _ackPending || _controller.isClosed) return;
    _ackPending = true;
    Timer.run(() {
      if (_stopped || _controller.isClosed) return;
      Timer.run(_pump);
    });
  }

  void _pump() {
    _ackPending = false;
    if (_stopped || _controller.isClosed) return;
    if (!_controller.isPaused) {
      _controller.add(_chunk);
    }
    _scheduleNextChunk();
  }

  @override
  Stream<Uint8List> get output => _controller.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  void writeBytes(Uint8List data) {}

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}

  @override
  bool kill([ProcessSignal signal = .sigterm]) {
    _stopped = true;
    if (!_controller.isClosed) unawaited(_controller.close());
    if (!_exitCode.isCompleted) _exitCode.complete(0);
    return true;
  }
}

StreamChannel<Uint8List> _openLoopbackViewerChannel({
  required void Function(CastMessage frame) onOutboundFrame,
}) {
  final ctrl = StreamChannelController<Uint8List>();
  ctrl.foreign.stream.listen((raw) {
    final frame = BufferFrameCodec.decode(raw);
    switch (frame) {
      case AuthFrame():
        ctrl.foreign.sink.add(
          BufferFrameCodec.encode(const AuthAcceptedFrame(role: .caster)),
        );
      case RegisterSessionFrame(:final sessionId):
        ctrl.foreign.sink.add(
          BufferFrameCodec.encode(
            SubscriberCountFrame(sessionId: sessionId, subscriberCount: 1),
          ),
        );
        ctrl.foreign.sink.add(
          BufferFrameCodec.encode(RequestKeyframeFrame(sessionId: sessionId)),
        );
      case _:
        onOutboundFrame(frame);
    }
  });
  return ctrl.local;
}

PtySession _startFloodPty({required bool synthetic}) {
  if (synthetic) {
    return _SyntheticFloodPty()..start();
  }
  return Pty2Session.start(
    '/bin/sh',
    const [
      '-c',
      r'(exec </dev/null >/dev/null 2>&1; sleep 8; kill -TERM $$) & exec yes',
    ],
    initialCols: 160,
    initialRows: 50,
  );
}

Future<int> _countTimerTicksDuringFlood(Future<int> ptyExit) async {
  var timerTicks = 0;
  final sw = Stopwatch()..start();
  final done = Completer<void>();
  final timer = Timer.periodic(const Duration(milliseconds: 25), (_) {
    timerTicks++;
    if (sw.elapsedMilliseconds >= 450 && !done.isCompleted) {
      done.complete();
    }
  });
  await Future.any<void>([done.future, ptyExit.then((_) {})]);
  timer.cancel();
  return timerTicks;
}

Future<void> main(List<String> args) async {
  final synthetic = args.contains('--synthetic');
  final heapProbe = await _VmHeapProbe.connect();
  final warmedUp = Completer<void>();
  var emittedFrames = 0;

  final pty = _startFloodPty(synthetic: synthetic);
  final service = CasterService(
    config: CasterConfig(
      sessionId: const SessionId('flood-pty'),
      title: 'yes-flood',
      initialCols: 160,
      initialRows: 50,
      maxScrollbackLines: 200,
      command: const ['yes'],
    ),
    pty: pty,
    frameCoalesceInterval: const Duration(milliseconds: 16),
    channelOpener: () async => _openLoopbackViewerChannel(
      onOutboundFrame: (frame) {
        emittedFrames++;
        if (frame is BufferDeltaFrame && !warmedUp.isCompleted) {
          warmedUp.complete();
        }
      },
    ),
  );

  await service.start();
  await warmedUp.future.timeout(const Duration(seconds: 5));
  await Future<void>.delayed(const Duration(milliseconds: 300));

  final baselineHeapBytes = await heapProbe.liveHeapBytesAfterGc();
  final timerTicks = await _countTimerTicksDuringFlood(pty.exitCode);
  final endHeapBytes = await heapProbe.liveHeapBytesAfterGc();

  await heapProbe.close();
  await service.stop(killPty: true);

  stdout.writeln(
    '$probeJsonPrefix${jsonEncode({'timerTicks': timerTicks, 'emittedFrames': emittedFrames, 'baselineHeapBytes': baselineHeapBytes, 'endHeapBytes': endHeapBytes, 'heapDeltaBytes': endHeapBytes - baselineHeapBytes})}',
  );
  exit(0);
}
