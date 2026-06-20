import 'package:file/file.dart';
import 'tracer_sink.dart';
import 'fs_sink.dart';

/// Creates the appropriate TracerSink depending on the environment and filesystem type.
TracerSink createTracerSink(FileSystem fs, String path, int baseEpochUs) {
  return FileSystemSink(fs, path, baseEpochUs);
}
