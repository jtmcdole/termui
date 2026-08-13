import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:archive/archive.dart';
import 'package:termui/trace/models/trace_models.dart';

typedef _ParseArgs = ({Uint8List bytes, String filename});

List<TraceEvent> _parseWorker(_ParseArgs args) {
  final bytes = args.bytes;
  final filename = args.filename;

  final decompressed = filename.endsWith('.gz')
      ? GZipDecoder().decodeBytes(bytes)
      : bytes;

  final content = utf8.decode(decompressed);
  final jsonList = jsonDecode(content);

  final list = jsonList is Map
      ? jsonList['traceEvents'] as List
      : jsonList as List;
  return [for (final e in list) TraceEvent.fromJson(e as Map<String, dynamic>)];
}

Future<List<TraceEvent>> parseTraceEvents(
  Uint8List bytes,
  String filename,
) async {
  return await compute(_parseWorker, (bytes: bytes, filename: filename));
}
