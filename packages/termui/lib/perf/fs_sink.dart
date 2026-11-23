import 'dart:convert';
import 'dart:async';
import 'package:file/file.dart';
import 'tracer.dart';
import 'tracer_sink.dart';

/// A [TracerSink] that writes directly and asynchronously to a [FileSystem] file.
class FileSystemSink implements TracerSink {
  /// The file system to use for writing the trace file.
  final FileSystem fs;

  /// The path where the trace file will be written.
  final String path;

  /// The base epoch timestamp in microseconds for the trace.
  final int baseEpochUs;
  late final File _file;
  late final IOSink _sink;
  bool _isFirst = true;
  final List<String> _stringTable = ['Unknown'];

  /// Creates a new [FileSystemSink] writing to [path] on [fs].
  FileSystemSink(this.fs, this.path, this.baseEpochUs) {
    _file = fs.file(path);
    if (!_file.parent.existsSync()) {
      _file.parent.createSync(recursive: true);
    }
    _sink = _file.openWrite();
    _sink.write('[\n');
  }

  @override
  void add(
    List<int> buffer,
    List<String> newStrings, [
    Map<int, Map<String, String>> metadata = const {},
  ]) {
    _stringTable.addAll(newStrings);

    final chunk = StringBuffer();
    final numEvents = buffer.length ~/ 2;
    for (int i = 0; i < numEvents; i++) {
      final word0 = buffer[i * 2];
      final ts = buffer[i * 2 + 1];

      final phaseVal = Tracer.unpackPhase(word0);
      final isolateId = Tracer.unpackIsolateId(word0);
      final stringId = Tracer.unpackStringId(word0);

      final name = (stringId < _stringTable.length)
          ? _stringTable[stringId]
          : 'Unknown';
      final ph = switch (phaseVal) {
        Phase.begin => 'B',
        Phase.end => 'E',
        Phase.counter => 'C',
        _ => 'i',
      };

      final realTs = baseEpochUs + ts;

      if (!_isFirst) {
        chunk.write(',\n');
      } else {
        _isFirst = false;
      }

      final eventMeta = metadata[i];
      final metaStr = eventMeta != null
          ? ', "args": ${_encodeEventArgs(eventMeta, phaseVal)}'
          : '';
      final escapedName = jsonEncode(name);
      chunk.write(
        '  {"name": $escapedName, "cat": "TUI", "ph": "$ph", "ts": $realTs, "pid": 1, "tid": $isolateId$metaStr}',
      );
    }
    if (chunk.isNotEmpty) {
      _sink.write(chunk.toString());
    }
  }

  static String _encodeEventArgs(Map<String, String> raw, int phaseVal) {
    if (phaseVal != Phase.counter) {
      return jsonEncode(raw);
    }
    final numeric = <String, Object>{
      for (final entry in raw.entries)
        entry.key: _parseFiniteCounterValue(entry.value),
    };
    return jsonEncode(numeric);
  }

  static Object _parseFiniteCounterValue(String raw) {
    final parsed = num.tryParse(raw);
    return (parsed != null && parsed.isFinite) ? parsed : raw;
  }

  @override
  Future<void> close() async {
    _sink.write('\n]\n');
    await _sink.flush();
    await _sink.close();
  }
}
