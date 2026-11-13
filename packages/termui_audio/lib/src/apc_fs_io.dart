import 'dart:io';
import 'dart:typed_data';

/// Returns a `dart:io` file-byte reader for local APC audio loading.
Future<Uint8List> Function(String path)? createDefaultApcFileReader() =>
    (path) => File(path).readAsBytes();
