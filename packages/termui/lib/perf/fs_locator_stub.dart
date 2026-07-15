import 'package:file/file.dart';
import 'package:file/memory.dart';

final _fs = MemoryFileSystem();

/// Returns a MemoryFileSystem for platforms where local disk is unsupported (web).
FileSystem getPlatformFileSystem() => _fs;
