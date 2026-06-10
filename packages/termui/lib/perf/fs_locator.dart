import 'package:file/file.dart';
import 'fs_locator_stub.dart' if (dart.library.io) 'fs_locator_io.dart';

/// Returns the default platform filesystem.
FileSystem getDefaultFileSystem() => getPlatformFileSystem();
