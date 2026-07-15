import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

Future<Uint8List> compressBytesImpl(Uint8List data) async {
  final blob = web.Blob([data.toJS].toJS);
  final response = web.Response(blob);

  final compressionStream = CompressionStream('gzip');
  final compressedStream = response.body!.pipeThrough(compressionStream);

  final compressedResponse = web.Response(compressedStream);
  final arrayBuffer = await compressedResponse.arrayBuffer().toDart;
  return arrayBuffer.toDart.asUint8List();
}

Future<Uint8List> compressStringImpl(String data) async {
  final bytes = utf8.encode(data);
  return await compressBytesImpl(Uint8List.fromList(bytes));
}

@JS('CompressionStream')
extension type CompressionStream._(JSObject _)
    implements web.ReadableWritablePair, JSObject {
  external factory CompressionStream(String format);
}
