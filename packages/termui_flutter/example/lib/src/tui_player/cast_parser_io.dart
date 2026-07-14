import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';

String _decompressTask(Uint8List bytes) {
  try {
    if (bytes case [0x1f, 0x8b, ...]) {
      final decompressed = GZipDecoder().decodeBytes(bytes);
      return utf8.decode(decompressed, allowMalformed: true);
    } else {
      return utf8.decode(bytes, allowMalformed: true);
    }
  } catch (e) {
    return utf8.decode(bytes, allowMalformed: true);
  }
}

Future<String> decompressCast(Uint8List bytes, String filename) async {
  return await compute(_decompressTask, bytes);
}
