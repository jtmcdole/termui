import 'dart:typed_data';

import 'api/audio_types.dart';

/// Returns `null` on platforms without `dart:io` filesystem access.
Future<Uint8List> Function(String path)? createDefaultApcFileReader() => null;

/// Returns `null` on platforms without `dart:io` network access.
Future<Uint8List> Function(String url, {LoadProgressCallback? onProgress})?
createDefaultApcUrlReader({
  Duration connectTimeout = const Duration(seconds: 10),
  Duration totalTimeout = const Duration(seconds: 30),
}) => null;
