@JS()
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

import 'package:termui/utils/gzip_json.dart';

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
    return await decompressString(bytes);
  } else {
    final responseFinal = web.Response(stream);
    final jsString = await responseFinal.text().toDart;
    return jsString.toDart;
  }
}
