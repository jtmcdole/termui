import 'dart:typed_data';

/// Compresses a string into a GZip compressed byte array.
Future<Uint8List> compressString(String input) async {
  throw UnsupportedError('Cannot compress on this platform');
}

/// Compresses a byte array into a GZip compressed byte array.
Future<Uint8List> compressBytes(Uint8List input) async {
  throw UnsupportedError('Cannot compress on this platform');
}

/// Decompresses a GZip compressed byte array into a string.
Future<String> decompressString(Uint8List input) async {
  throw UnsupportedError('Cannot decompress on this platform');
}

/// Decompresses a GZip compressed byte array into a byte array.
Future<Uint8List> decompressBytes(Uint8List input) async {
  throw UnsupportedError('Cannot decompress on this platform');
}
