import 'dart:convert';
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
  void add(
    List<int> buffer,
    List<String> newStrings, [
    Map<int, Map<String, String>> metadata = const {},
  ]) {
    if (!_initialized) {
      _initCompleter.future.then((_) {
        _sendData(buffer, newStrings, metadata);
      });
    } else {
      _sendData(buffer, newStrings, metadata);
    }
  }

  void _sendData(
    List<int> buffer,
    List<String> newStrings,
    Map<int, Map<String, String>> metadata,
  ) {
    if (newStrings.isNotEmpty) {
      _serializerPort.send(_StringTableSync(newStrings));
    }
    if (buffer.isNotEmpty) {
      Uint8List? metadataBytes;
      if (metadata.isNotEmpty) {
        final builder = BytesBuilder(copy: false);
        for (final entry in metadata.entries) {
          final jsonStr = jsonEncode(entry.value);
          final bytes = utf8.encode(jsonStr);
          final header = ByteData(8);
          header.setInt32(0, entry.key, Endian.host);
          header.setInt32(4, bytes.length, Endian.host);
          builder.add(header.buffer.asUint8List());
          builder.add(bytes);
        }
        metadataBytes = builder.toBytes();
      }

      _serializerPort.send(
        _TraceData(
          TransferableTypedData.fromList([buffer as TypedData]),
          metadataBytes,
        ),
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

class _TraceData {
  final TransferableTypedData buffer;
  final Uint8List? metadataBytes;
  _TraceData(this.buffer, this.metadataBytes);
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
    } else if (message is _TraceData) {
      final byteBuffer = message.buffer.materialize();
      final buffer = byteBuffer.asInt64List();
      final numEvents = buffer.length ~/ 2;

      Map<int, String> metadata = {};
      final metaBytes = message.metadataBytes;
      if (metaBytes != null) {
        var offset = 0;
        final byteData = ByteData.sublistView(metaBytes);
        while (offset < metaBytes.length) {
          final idx = byteData.getInt32(offset, Endian.host);
          final len = byteData.getInt32(offset + 4, Endian.host);
          offset += 8;
          final strBytes = Uint8List.sublistView(
            metaBytes,
            offset,
            offset + len,
          );
          metadata[idx] = utf8.decode(strBytes);
          offset += len;
        }
      }

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

        final meta = metadata[i];
        final metaStr = meta != null ? ', "args": $meta' : '';
        final escapedName = jsonEncode(name);
        ios.write(
          '  {"name": $escapedName, "cat": "TUI", "ph": "$ph", "ts": $realTs, "pid": 1, "tid": $isolateId$metaStr}',
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
