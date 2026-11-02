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
  SendPort? _serializerPort;
  Isolate? _serializerIsolate;
  bool _initialized = false;
  bool _failed = false;
  bool _closing = false;
  bool _closed = false;
  final Completer<void> _initCompleter = Completer<void>();
  final List<void Function()> _pendingSends = [];

  /// Creates a new [IsolateSink] writing to [path].
  IsolateSink(this.path, this.baseEpochUs) {
    _start();
  }

  Future<void> _start() async {
    final receivePort = ReceivePort();
    final errorPort = ReceivePort();
    final exitPort = ReceivePort();

    void closeInitPorts() {
      receivePort.close();
      errorPort.close();
      exitPort.close();
    }

    void failInit([Object? _]) {
      _failed = true;
      _pendingSends.clear();
      if (!_initCompleter.isCompleted) {
        _initCompleter.complete();
      }
      closeInitPorts();
    }

    errorPort.listen(failInit);
    exitPort.listen(failInit);

    try {
      _serializerIsolate = await Isolate.spawn(
        _serializerEntryPoint,
        _SerializerConfig(receivePort.sendPort, path, baseEpochUs),
        onError: errorPort.sendPort,
        onExit: exitPort.sendPort,
      );
    } catch (_) {
      failInit();
      return;
    }

    receivePort.listen((message) {
      if (message is SendPort) {
        _completeInitSuccess(message);
        closeInitPorts();
      } else {
        failInit();
      }
    });
  }

  void _completeInitSuccess(SendPort port) {
    _serializerPort = port;
    _initialized = true;
    for (final pending in _pendingSends) {
      pending();
    }
    _pendingSends.clear();
    if (!_initCompleter.isCompleted) {
      _initCompleter.complete();
    }
  }

  @override
  void add(
    List<int> buffer,
    List<String> newStrings, [
    Map<int, Map<String, String>> metadata = const {},
  ]) {
    if (_closed || _failed) return;
    if (!_initialized) {
      final bufferCopy = Int64List.fromList(buffer);
      final stringsCopy = [...newStrings];
      final metadataCopy = {...metadata};
      _pendingSends.add(() {
        _sendData(bufferCopy, stringsCopy, metadataCopy);
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
    final port = _serializerPort;
    if (port == null || _failed || _closed) return;

    if (newStrings.isNotEmpty) {
      port.send(_StringTableSync(newStrings));
    }
    if (buffer.isNotEmpty) {
      final metadataBytes = _encodeMetadata(metadata);
      final TypedData typedBuffer = buffer is TypedData
          ? buffer as TypedData
          : Int64List.fromList(buffer);
      port.send(
        _TraceData(
          TransferableTypedData.fromList([typedBuffer]),
          metadataBytes,
        ),
      );
    }
  }

  static Uint8List? _encodeMetadata(Map<int, Map<String, String>> metadata) {
    if (metadata.isEmpty) return null;
    final builder = BytesBuilder(copy: false);
    for (final entry in metadata.entries) {
      final bytes = utf8.encode(jsonEncode(entry.value));
      final header = ByteData(8)
        ..setInt32(0, entry.key, Endian.host)
        ..setInt32(4, bytes.length, Endian.host);
      builder.add(header.buffer.asUint8List());
      builder.add(bytes);
    }
    return builder.toBytes();
  }

  @override
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    if (!_initialized && !_failed) {
      await _initCompleter.future;
    }
    _closed = true;

    final port = _serializerPort;
    final isolate = _serializerIsolate;
    if (_failed || port == null || isolate == null) {
      isolate?.kill();
      return;
    }

    final replyPort = ReceivePort();
    final onExitPort = ReceivePort();
    final done = Completer<void>();
    void finish([Object? _]) {
      if (!done.isCompleted) done.complete();
    }

    replyPort.listen(finish);
    onExitPort.listen(finish);
    isolate.addOnExitListener(onExitPort.sendPort);
    port.send(_TerminateSignal(replyPort.sendPort));

    try {
      await done.future;
    } finally {
      replyPort.close();
      onExitPort.close();
      isolate.kill();
    }
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

IOSink? _openTraceSink(String filePath) {
  try {
    final file = File(filePath);
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    // Eagerly verify writability before signaling successful initialization.
    final raf = file.openSync(mode: FileMode.write);
    raf.closeSync();
    final ios = file.openWrite(mode: FileMode.write);
    ios.done.ignore();
    return ios;
  } catch (_) {
    return null;
  }
}

Map<int, String> _decodeMetadata(Uint8List? metadataBytes) {
  if (metadataBytes == null) return const {};
  final metadata = <int, String>{};
  var offset = 0;
  final byteData = ByteData.sublistView(metadataBytes);
  while (offset < metadataBytes.length) {
    final idx = byteData.getInt32(offset, Endian.host);
    final len = byteData.getInt32(offset + 4, Endian.host);
    offset += 8;
    final strBytes = Uint8List.sublistView(metadataBytes, offset, offset + len);
    metadata[idx] = utf8.decode(strBytes);
    offset += len;
  }
  return metadata;
}

bool _writeTraceBatch({
  required IOSink ios,
  required Int64List bufferList,
  required Map<int, String> metadata,
  required List<String> stringTable,
  required int baseEpochUs,
  required bool isFirst,
}) {
  var first = isFirst;
  final numEvents = bufferList.length ~/ 2;
  for (var i = 0; i < numEvents; i++) {
    final word0 = bufferList[i * 2];
    final ts = bufferList[i * 2 + 1];

    final phaseVal = word0 & 0xFF;
    final isolateId = (word0 >> 8) & 0xFFFFFF;
    final stringId = (word0 >> 32) & 0xFFFFFFFF;

    final name = stringId < stringTable.length
        ? stringTable[stringId]
        : 'Unknown';
    final ph = _phaseSymbol(phaseVal);
    final realTs = baseEpochUs + ts;

    if (!first) {
      ios.write(',\n');
    } else {
      first = false;
    }

    final meta = metadata[i];
    final metaStr = meta != null ? ', "args": $meta' : '';
    final escapedName = jsonEncode(name);
    ios.write(
      '  {"name": $escapedName, "cat": "TUI", "ph": "$ph", "ts": $realTs, "pid": 1, "tid": $isolateId$metaStr}',
    );
  }
  return first;
}

String _phaseSymbol(int phaseVal) => switch (phaseVal) {
  Phase.begin => 'B',
  Phase.end => 'E',
  _ => 'i',
};

/// Entrypoint for the helper Isolate that processes and serializes events.
void _serializerEntryPoint(_SerializerConfig config) {
  final ios = _openTraceSink(config.filePath);
  if (ios == null) {
    config.replyPort.send(null);
    return;
  }

  final receivePort = ReceivePort();
  config.replyPort.send(receivePort.sendPort);

  // Write Perfetto / Chrome Trace JSON Header
  ios.write('[\n');
  var isFirst = true;
  final stringTable = <String>['Unknown'];

  receivePort.listen((message) async {
    switch (message) {
      case _StringTableSync(:final newStrings):
        stringTable.addAll(newStrings);
      case _TraceData(:final buffer, :final metadataBytes):
        final bufferList = buffer.materialize().asInt64List();
        final metadata = _decodeMetadata(metadataBytes);
        isFirst = _writeTraceBatch(
          ios: ios,
          bufferList: bufferList,
          metadata: metadata,
          stringTable: stringTable,
          baseEpochUs: config.baseEpochUs,
          isFirst: isFirst,
        );
      case _TerminateSignal(:final replyPort):
        try {
          ios.write('\n]\n');
          await ios.flush();
          await ios.close();
        } catch (_) {
          // Ignore flush/close I/O errors during shutdown.
        } finally {
          replyPort.send(null);
          receivePort.close();
        }
    }
  });
}
