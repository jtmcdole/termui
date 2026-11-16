import 'dart:typed_data';

/// Stub for platforms without `dart:io`; local filesystem probing is unsupported.
Future<Uint8List?> readOggXiphFileBytes(String path) async => null;
