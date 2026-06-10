import 'package:file/file.dart';
import 'tracer_sink.dart';
import 'fs_sink.dart';

/// Returns a FileSystemSink for platforms where Isolates are unsupported (web).
TracerSink getTracerSink(FileSystem fs, String path, int baseEpochUs) {
  return FileSystemSink(fs, path, baseEpochUs);
}
