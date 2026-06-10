import 'package:file/file.dart';
import 'package:file/local.dart';
import 'tracer_sink.dart';
import 'isolate_sink.dart';
import 'fs_sink.dart';

/// Returns an IsolateSink if the filesystem is LocalFileSystem, falling back to FileSystemSink.
TracerSink getTracerSink(FileSystem fs, String path, int baseEpochUs) {
  if (fs is LocalFileSystem) {
    return IsolateSink(path, baseEpochUs);
  } else {
    return FileSystemSink(fs, path, baseEpochUs);
  }
}
