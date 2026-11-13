import 'dart:typed_data';

/// Returns `null` on platforms without `dart:io` filesystem access.
Future<Uint8List> Function(String path)? createDefaultApcFileReader() => null;
