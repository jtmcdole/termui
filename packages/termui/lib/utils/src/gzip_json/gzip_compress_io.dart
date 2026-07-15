import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// Compresses a string into a GZip compressed byte array.
Future<Uint8List> compressString(String input) async {
  return Isolate.run(() => _compressStringSync(input));
}

/// Compresses a byte array into a GZip compressed byte array.
Future<Uint8List> compressBytes(Uint8List input) async {
  return Isolate.run(() => _compressBytesSync(input));
}

/// Decompresses a GZip compressed byte array into a string.
Future<String> decompressString(Uint8List input) async {
  return Isolate.run(() => _decompressStringSync(input));
}

/// Decompresses a GZip compressed byte array into a byte array.
Future<Uint8List> decompressBytes(Uint8List input) async {
  return Isolate.run(() => _decompressBytesSync(input));
}

Uint8List _compressStringSync(String input) {
  final bytes = utf8.encode(input);
  return Uint8List.fromList(gzip.encode(bytes));
}

Uint8List _compressBytesSync(Uint8List input) {
  return Uint8List.fromList(gzip.encode(input));
}

String _decompressStringSync(Uint8List input) {
  final decompressed = gzip.decode(input);
  return utf8.decode(decompressed);
}

Uint8List _decompressBytesSync(Uint8List input) {
  return Uint8List.fromList(gzip.decode(input));
}
