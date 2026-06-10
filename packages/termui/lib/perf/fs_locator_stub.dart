import 'package:file/file.dart';
import 'package:file/memory.dart';

/// Returns a MemoryFileSystem for platforms where local disk is unsupported (web).
FileSystem getPlatformFileSystem() => MemoryFileSystem();
