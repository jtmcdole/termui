import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'tracer.dart';
import 'tracer_sink.dart';

/// A [TracerSink] that spawns a background Isolate to perform zero-jank JSON serialization and disk writes.
class IsolateSink implements TracerSink {
  /// The path where the trace file will be written.
  final String path;

  /// The base epoch timestamp in microseconds for the trace.
  final int baseEpochUs;
  late final SendPort _serializerPort;
  late final Isolate _serializerIsolate;
  bool _initialized = false;
  final Completer<void> _initCompleter = Completer<void>();

  /// Creates a new [IsolateSink] writing to [path].
  IsolateSink(this.path, this.baseEpochUs) {
    _start();
  }

  Future<void> _start() async {
    final receivePort = ReceivePort();
    _serializerIsolate = await Isolate.spawn(
      _serializerEntryPoint,
      _SerializerConfig(receivePort.sendPort, path, baseEpochUs),
    );
    _serializerPort = await receivePort.first as SendPort;
    _initialized = true;
    _initCompleter.complete();
  }

  @override
  void add(List<int> buffer, List<String> newStrings) {
    if (!_initialized) {
      _initCompleter.future.then((_) {
        _sendData(buffer, newStrings);
      });
    } else {
      _sendData(buffer, newStrings);
    }
  }

  void _sendData(List<int> buffer, List<String> newStrings) {
    if (newStrings.isNotEmpty) {
      _serializerPort.send(_StringTableSync(newStrings));
    }
    if (buffer.isNotEmpty) {
      _serializerPort.send(
        TransferableTypedData.fromList([buffer as TypedData]),
      );
    }
  }

  @override
  Future<void> close() async {
    if (!_initialized) {
      await _initCompleter.future;
    }
    final exitPort = ReceivePort();
    _serializerPort.send(_TerminateSignal(exitPort.sendPort));
    await exitPort.first;
    _serializerIsolate.kill();
  }
}

// Internal configurations & message passing schemas
class _SerializerConfig {
  final SendPort replyPort;
  final String filePath;
  final int baseEpochUs;
  _SerializerConfig(this.replyPort, this.filePath, this.baseEpochUs);
}

class _StringTableSync {
  final List<String> newStrings;
  _StringTableSync(this.newStrings);
}

class _TerminateSignal {
  final SendPort replyPort;
  _TerminateSignal(this.replyPort);
}

/// Entrypoint for the helper Isolate that processes and serializes events.
void _serializerEntryPoint(_SerializerConfig config) {
  final receivePort = ReceivePort();
  config.replyPort.send(receivePort.sendPort);

  final file = File(config.filePath);
  if (!file.parent.existsSync()) {
    file.parent.createSync(recursive: true);
  }
  final ios = file.openWrite(mode: FileMode.write);

  // Write Perfetto / Chrome Trace JSON Header
  ios.write('[\n');
  bool isFirst = true;

  final List<String> stringTable = ['Unknown'];

  receivePort.listen((message) async {
    if (message is _StringTableSync) {
      stringTable.addAll(message.newStrings);
    } else if (message is TransferableTypedData) {
      final buffer = message.materialize().asInt64List();
      final numEvents = buffer.length ~/ 2;

      for (int i = 0; i < numEvents; i++) {
        final word0 = buffer[i * 2];
        final ts = buffer[i * 2 + 1];

        final phaseVal = word0 & 0xFF;
        final isolateId = (word0 >> 8) & 0xFFFFFF;
        final stringId = (word0 >> 32) & 0xFFFFFFFF;

        final name = (stringId < stringTable.length)
            ? stringTable[stringId]
            : 'Unknown';
        final ph = (phaseVal == Phase.begin)
            ? 'B'
            : (phaseVal == Phase.end ? 'E' : 'i');

        final realTs = config.baseEpochUs + ts;

        if (!isFirst) {
          ios.write(',\n');
        } else {
          isFirst = false;
        }

        ios.write(
          '  {"name": "$name", "cat": "TUI", "ph": "$ph", "ts": $realTs, "pid": 1, "tid": $isolateId}',
        );
      }
    } else if (message is _TerminateSignal) {
      ios.write('\n]\n');
      await ios.flush();
      await ios.close();
      message.replyPort.send(null);
    }
  });
}
