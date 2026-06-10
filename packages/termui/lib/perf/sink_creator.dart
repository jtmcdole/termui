import 'package:file/file.dart';
import 'tracer_sink.dart';
import 'sink_creator_stub.dart' if (dart.library.io) 'sink_creator_io.dart';

/// Creates the appropriate TracerSink depending on the environment and filesystem type.
TracerSink createTracerSink(FileSystem fs, String path, int baseEpochUs) {
  return getTracerSink(fs, path, baseEpochUs);
}
