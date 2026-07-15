import 'dart:typed_data';
import 'gzip_compress_stub.dart'
    if (dart.library.js_interop) 'gzip_compress_web.dart'
    if (dart.library.io) 'gzip_compress_io.dart';

Future<Uint8List> compressBytes(Uint8List data) async =>
    await compressBytesImpl(data);
Future<Uint8List> compressString(String data) async =>
    await compressStringImpl(data);
