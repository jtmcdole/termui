import 'dart:convert';
import 'package:test/test.dart';
import 'package:file/memory.dart';
import 'package:termui/perf/fs_sink.dart';
import 'package:termui/perf/tracer.dart';

void main() {
  test('FileSystemSink writes uncompressed JSON to file', () async {
    final fs = MemoryFileSystem();
    final path = 'test_trace.json';

    // Create the sink
    final sink = FileSystemSink(fs, path, 0);

    // Add a dummy event
    // Word 0: (stringId << 32) | (isolateId << 8) | phase
    // Let's say stringId=1, isolateId=1, phase=Phase.begin
    final word0 = (1 << 32) | (1 << 8) | Phase.begin;
    final word1 = 1000; // ts

    sink.add([word0, word1], ['TestEvent']);
    await sink.close();

    // The file should contain plain JSON, not gzip
    final bytes = fs.file(path).readAsBytesSync();

    // Attempt to parse as JSON. If it's compressed, this will throw a FormatException
    final content = utf8.decode(bytes);

    // Should be valid JSON array
    expect(() => jsonDecode(content), returnsNormally);
  });
}
