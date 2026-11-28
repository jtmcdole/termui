// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:pty2/pty2.dart';
import 'package:pty2/src/pty_core.dart';

abstract base class BasePseudoTerminal implements PseudoTerminal {
  BasePseudoTerminal(this._core);

  final PtyCore _core;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    return _core.kill(signal);
  }

  // int get pid {
  //   return _core.pid;
  // }

  @override
  void write(String input) {
    final data = utf8.encode(input);
    _core.write(data);
  }

  @override
  void resize(
    int width,
    int height, {
    int pixelWidth = 0,
    int pixelHeight = 0,
  }) {
    _core.resize(
      width,
      height,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
    );
  }
}

@pragma('vm:never-inline')
void _keepAlive(Object? o) {}

/// An isolate-based [PseudoTerminal] implementation backed by a blocking
/// [PtyCore].
///
/// Spawns separate background isolates for reading output, writing input, and
/// waiting on process exit so blocking OS I/O never stalls the caller's
/// isolate.
final class BlockingPseudoTerminal extends BasePseudoTerminal {
  BlockingPseudoTerminal(super._core, this._syncProcessed);

  late SendPort _sendPort;
  SendPort? _writerSendPort;
  final List<Uint8List> _pendingWrites = <Uint8List>[];
  final bool _syncProcessed;
  late final StreamController<String> _outStreamController;
  bool _initialized = false;
  bool _hasSendPort = false;
  bool _pendingAck = false;
  bool _outCancelled = false;
  bool _writerClosed = false;

  late final Future<int> _exitCodeFuture;

  void _onWriterReady(SendPort sendPort) {
    if (_writerClosed) {
      _pendingWrites.clear();
      sendPort.send(null);
      return;
    }
    _writerSendPort = sendPort;
    for (final chunk in _pendingWrites) {
      sendPort.send(TransferableTypedData.fromList([chunk]));
    }
    _pendingWrites.clear();
  }

  void _closeWriter() {
    if (_writerClosed) return;
    _writerClosed = true;
    _pendingWrites.clear();
    final port = _writerSendPort;
    _writerSendPort = null;
    port?.send(null);
  }

  @override
  void write(String input) {
    if (_writerClosed || input.isEmpty) return;
    final data = utf8.encode(input);
    final port = _writerSendPort;
    if (port != null) {
      port.send(TransferableTypedData.fromList([data]));
    } else {
      _pendingWrites.add(data);
    }
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    _closeWriter();
    return super.kill(signal);
  }

  void _spawnWriterIsolate() {
    final writer = _core.takeWriter();
    final writerReadyPort = ReceivePort();
    final writerExitPort = ReceivePort();
    writerReadyPort.listen((msg) {
      writerReadyPort.close();
      _onWriterReady(msg as SendPort);
    });
    writerExitPort.listen((_) {
      writerReadyPort.close();
      writerExitPort.close();
      _closeWriter();
      _keepAlive(_core);
    });
    unawaited(
      Isolate.spawn(
        _writeUntilClosed,
        _WriterIsolateArgs(writerReadyPort.sendPort, writer),
        onExit: writerExitPort.sendPort,
      ).then<void>(
        (_) {},
        onError: (Object _) {
          writerReadyPort.close();
          writerExitPort.close();
          writer.free();
          _closeWriter();
        },
      ),
    );
  }

  void _spawnExitIsolate() {
    final exitPort = ReceivePort();
    unawaited(
      Isolate.spawn(
        _waitForExitCode,
        _IsolateArgs(exitPort.sendPort, _core.worker, _syncProcessed),
      ),
    );
    _exitCodeFuture = exitPort.first.then((value) {
      exitPort.close();
      _closeWriter();
      _keepAlive(_core);
      return value as int;
    });
  }

  void _spawnReaderIsolate() {
    final receivePort = ReceivePort();
    var first = true;
    receivePort.listen((msg) {
      if (msg == null) {
        receivePort.close();
        _closeWriter();
        _core.onReaderClosed();
        _outStreamController.close();
        _keepAlive(_core);
        return;
      }
      if (first) {
        _sendPort = msg as SendPort;
        _hasSendPort = true;
        first = false;
        if (_pendingAck || _outCancelled) {
          _pendingAck = false;
          ackProcessed();
        }
        return;
      }
      if (_outCancelled) {
        // Subscription was cancelled; keep draining the reader isolate to EOF
        // so its ReceivePort closes cleanly instead of idling forever.
        ackProcessed();
        return;
      }
      switch (msg) {
        case String _:
          _outStreamController.sink.add(msg);
        case Uint8List _:
          _outStreamController.sink.add(utf8.decode(msg, allowMalformed: true));
        default:
          break;
      }
    });
    unawaited(
      Isolate.spawn(
        _readUntilExit,
        _IsolateArgs(receivePort.sendPort, _core.worker, _syncProcessed),
      ),
    );
  }

  @override
  void init() {
    if (_initialized) {
      throw StateError('BlockingPseudoTerminal has already been initialized.');
    }
    _initialized = true;
    _outStreamController = StreamController<String>(
      onCancel: () {
        _outCancelled = true;
        ackProcessed();
      },
    );
    _spawnWriterIsolate();
    _spawnExitIsolate();
    _spawnReaderIsolate();
  }

  @override
  Future<int> get exitCode => _exitCodeFuture;

  @override
  Stream<String> get out => _outStreamController.stream;

  @override
  void ackProcessed() {
    if (_syncProcessed) {
      if (_hasSendPort) {
        _sendPort.send(true);
      } else {
        _pendingAck = true;
      }
    }
  }
}

/// Argument to a isolate entry point, with a sendPort and a custom value.
/// Reduces the effort to establish bi-directional communication between isolate
/// and main thread in many cases.
class _IsolateArgs<T> {
  _IsolateArgs(this.sendPort, this.arg, this.syncProcessed);

  final SendPort sendPort;
  final T arg;
  final bool syncProcessed;
}

class _WriterIsolateArgs {
  _WriterIsolateArgs(this.sendPort, this.writer);

  final SendPort sendPort;
  final PtyCoreWriter writer;
}

void _writeUntilClosed(_WriterIsolateArgs ctx) {
  final rp = ReceivePort();
  ctx.sendPort.send(rp.sendPort);

  var closed = false;
  void shutdown() {
    if (closed) return;
    closed = true;
    rp.close();
    ctx.writer.free();
  }

  rp.listen((message) {
    if (closed) return;
    if (message == null) {
      shutdown();
      return;
    }
    if (message is! TransferableTypedData) return;
    try {
      final bytes = message.materialize().asUint8List();
      if (ctx.writer.write(bytes) == PtyWriteStatus.closed) {
        shutdown();
      }
    } on Object {
      shutdown();
      rethrow;
    }
  });
}

void _waitForExitCode(_IsolateArgs<PtyCoreWorker> ctx) async {
  final exitCode = ctx.arg.exitCodeBlocking();
  ctx.sendPort.send(exitCode);
}

void _readUntilExit(_IsolateArgs<PtyCoreWorker> ctx) async {
  final rp = ReceivePort();
  ctx.sendPort.send(rp.sendPort);

  // set [sync] to true because PtyCore.read() is blocking and prevents the
  // event loop from working.
  final input = StreamController<List<int>>(sync: true);

  final utf8corrupt = Utf8Codec(allowMalformed: true);
  input.stream.transform(utf8corrupt.decoder).listen(ctx.sendPort.send);

  final loopController = StreamController<bool>();

  if (ctx.syncProcessed) {
    rp.listen((message) {
      if (message is bool) {
        loopController.sink.add(message);
      }
    });
  }
  loopController.sink.add(true); //enable the first iteration

  try {
    await for (final _ in loopController.stream) {
      final data = ctx.arg.read();

      if (data == null) {
        await input.close();
        break;
      }

      input.sink.add(data);

      // when we don't sync with the data processing then just schedule the next loop
      // iteration
      // Otherwise the loop will continue when the processing of the data is
      // finished (signaled via [PseudoTerminal.ackProcessed])
      if (!ctx.syncProcessed) {
        loopController.sink.add(true);
      }
    }
  } finally {
    ctx.arg.free();
    rp.close();
    await loopController.close();
    ctx.sendPort.send(null);
  }
}
