import 'dart:convert';
import 'dart:async';
import 'package:file/file.dart';
import '../utils/gzip_json.dart';
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
  final StringBuffer _buffer = StringBuffer();
  bool _isFirst = true;
  final List<String> _stringTable = ['Unknown'];

  /// Creates a new [FileSystemSink] writing to [path] on [fs].
  FileSystemSink(this.fs, this.path, this.baseEpochUs) {
    _file = fs.file(path);
    if (!_file.parent.existsSync()) {
      _file.parent.createSync(recursive: true);
    }
    _buffer.write('[\n');
  }

  @override
  void add(
    List<int> buffer,
    List<String> newStrings, [
    Map<int, Map<String, String>> metadata = const {},
  ]) {
    _stringTable.addAll(newStrings);

    final numEvents = buffer.length ~/ 2;
    for (int i = 0; i < numEvents; i++) {
      final word0 = buffer[i * 2];
      final ts = buffer[i * 2 + 1];

      final phaseVal = word0 & 0xFF;
      final isolateId = (word0 >> 8) & 0xFFFFFF;
      final stringId = (word0 >> 32) & 0xFFFFFFFF;

      final name = (stringId < _stringTable.length)
          ? _stringTable[stringId]
          : 'Unknown';
      final ph = (phaseVal == Phase.begin)
          ? 'B'
          : (phaseVal == Phase.end ? 'E' : 'i');

      final realTs = baseEpochUs + ts;

      if (!_isFirst) {
        _buffer.write(',\n');
      } else {
        _isFirst = false;
      }

      final metaStr = metadata.containsKey(i)
          ? ', "args": ${jsonEncode(metadata[i])}'
          : '';
      final escapedName = jsonEncode(name);
      _buffer.write(
        '  {"name": $escapedName, "cat": "TUI", "ph": "$ph", "ts": $realTs, "pid": 1, "tid": $isolateId$metaStr}',
      );
    }
  }

  @override
  Future<void> close() async {
    _buffer.write('\n]\n');
    final bytes = utf8.encode(_buffer.toString());
    final compressed = await compressBytes(bytes);
    _file.writeAsBytesSync(compressed);
  }
}
