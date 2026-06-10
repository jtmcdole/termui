import 'package:file/file.dart';
import 'package:file/local.dart';

/// Returns a LocalFileSystem for standard VM/OS platform executions.
FileSystem getPlatformFileSystem() => const LocalFileSystem();
