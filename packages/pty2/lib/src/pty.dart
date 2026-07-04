import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:pty2/pty.dart';
import 'package:pty2/src/pty_core.dart';

abstract class BasePseudoTerminal implements PseudoTerminal {
  BasePseudoTerminal(this._core);

  late final PtyCore _core;

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
  void resize(int width, int height) {
    _core.resize(width, height);
  }
}

/// An isolate based PseudoTerminal implementation. Performs better than
/// PollingPseudoTerminal and requires less resource. However this prevents
/// flutter hot reload from working. Ideal for release builds. The underlying
/// PtyCore must be blocking.
class BlockingPseudoTerminal extends BasePseudoTerminal {
  BlockingPseudoTerminal(super._core, this._syncProcessed);

  late SendPort _sendPort;
  final bool _syncProcessed;
  late final StreamController<String> _outStreamController;

  late final Future<int> _exitCodeFuture;

  @override
  void init() {
    _outStreamController = StreamController<String>();
    out = _outStreamController.stream;

    final exitPort = ReceivePort();
    Isolate.spawn(
      _waitForExitCode,
      _IsolateArgs(exitPort.sendPort, _core.worker, _syncProcessed),
    );
    _exitCodeFuture = exitPort.first.then((value) {
      exitPort.close();
      _core.kill();
      return value as int;
    });

    final receivePort = ReceivePort();
    var first = true;
    receivePort.listen((msg) {
      if (msg == null) {
        receivePort.close();
        _outStreamController.close();
        return;
      }
      if (first) {
        _sendPort = msg as SendPort;
        first = false;
        return;
      }

      switch (msg) {
        case String _:
          _outStreamController.sink.add(msg);

          break;
        case Uint8List _:
          _outStreamController.sink.add(utf8.decode(msg, allowMalformed: true));
          break;
        default:
        // print('wtf happened here? ${(type: msg.runtimeType, msg: msg)}');
      }
    });
    Isolate.spawn(
      _readUntilExit,
      _IsolateArgs(receivePort.sendPort, _core.worker, _syncProcessed),
    );
  }

  @override
  Future<int> get exitCode => _exitCodeFuture;

  @override
  late Stream<String> out;

  @override
  void ackProcessed() {
    if (_syncProcessed) {
      _sendPort.send(true);
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
      loopController.sink.add(message);
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
  }
  await loopController.close();
  ctx.sendPort.send(null);
}
