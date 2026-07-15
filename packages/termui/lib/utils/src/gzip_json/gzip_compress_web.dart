import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

/// Compresses a string into a GZip compressed byte array.
Future<Uint8List> compressString(String input) async {
  final bytes = utf8.encode(input);
  return await compressBytes(Uint8List.fromList(bytes));
}

/// Compresses a byte array into a GZip compressed byte array.
Future<Uint8List> compressBytes(Uint8List input) async {
  final blob = web.Blob([input.toJS].toJS);
  final response = web.Response(blob);

  final compressionStream = CompressionStream('gzip');
  final compressedStream = response.body!.pipeThrough(compressionStream);

  final compressedResponse = web.Response(compressedStream);
  final arrayBuffer = await compressedResponse.arrayBuffer().toDart;
  return arrayBuffer.toDart.asUint8List();
}

/// Decompresses a GZip compressed byte array into a string.
Future<String> decompressString(Uint8List input) async {
  final decompressedBytes = await decompressBytes(input);
  return utf8.decode(decompressedBytes);
}

/// Decompresses a GZip compressed byte array into a byte array.
Future<Uint8List> decompressBytes(Uint8List input) async {
  final blob = web.Blob([input.toJS].toJS);
  final response = web.Response(blob);

  final decompressionStream = DecompressionStream('gzip');
  final decompressedStream = response.body!.pipeThrough(decompressionStream);

  final decompressedResponse = web.Response(decompressedStream);
  final arrayBuffer = await decompressedResponse.arrayBuffer().toDart;
  return arrayBuffer.toDart.asUint8List();
}

/// JS Interop extension for CompressionStream
@JS('CompressionStream')
extension type CompressionStream._(JSObject _)
    implements web.ReadableWritablePair, JSObject {
  /// Create a new CompressionStream with the given format (e.g. 'gzip')
  external factory CompressionStream(String format);
}

/// JS Interop extension for DecompressionStream
@JS('DecompressionStream')
extension type DecompressionStream._(JSObject _)
    implements web.ReadableWritablePair, JSObject {
  /// Create a new DecompressionStream with the given format (e.g. 'gzip')
  external factory DecompressionStream(String format);
}
