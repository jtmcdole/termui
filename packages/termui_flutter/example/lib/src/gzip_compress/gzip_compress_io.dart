import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:archive/archive.dart';

Future<Uint8List> compressBytesImpl(Uint8List data) async {
  return await compute((Uint8List bytes) {
    return Uint8List.fromList(GZipEncoder().encode(bytes));
  }, data);
}

Future<Uint8List> compressStringImpl(String data) async {
  return await compute((String str) {
    final bytes = utf8.encode(str);
    return Uint8List.fromList(GZipEncoder().encode(bytes));
  }, data);
}
