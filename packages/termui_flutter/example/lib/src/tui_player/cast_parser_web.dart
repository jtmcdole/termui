@JS()
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

@JS('DecompressionStream')
extension type DecompressionStream._(JSObject _) implements JSObject {
  external DecompressionStream(String format);
}

extension on web.ReadableStream {
  @JS('pipeThrough')
  external web.ReadableStream pipeThroughGzip(DecompressionStream stream);
}

Future<String> decompressCast(Uint8List bytes, String filename) async {
  final jsBytes = bytes.toJS;
  final responseInitial = web.Response(jsBytes);
  var stream = responseInitial.body;
  if (stream == null) throw StateError('No body in Response');

  bool isGzip = false;
  if (bytes case [0x1f, 0x8b, ...]) {
    isGzip = true;
  } else if (filename.endsWith('.gz')) {
    isGzip = true;
  }

  if (isGzip) {
    final decompressionStream = DecompressionStream('gzip');
    stream = stream.pipeThroughGzip(decompressionStream);
  }

  final responseFinal = web.Response(stream);
  final jsString = await responseFinal.text().toDart;
  return jsString.toDart;
}
