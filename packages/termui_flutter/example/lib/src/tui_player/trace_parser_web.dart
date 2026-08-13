@JS()
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'package:web/web.dart' as web;
import 'dart:convert';
import 'package:termui/trace/trace_logger.dart';
import 'package:termui/trace/models/trace_models.dart';

import 'package:termui/utils/gzip_json.dart';

@JS()
extension type JSTraceEvent._(JSObject _) implements JSObject {
  external String? get name;
  external String? get ph;
  external String? get cat;
  external num? get ts;
  external num? get dur;
  external num? get tid;
  external JSAny? get args;
  external JSAny? get metadata;
}

@JS('TextDecoder')
extension type TextDecoder._(JSObject _) implements JSObject {
  external TextDecoder(String encoding);
  external String decode(JSAny? buffer);
}

final watch = Stopwatch();
Future<List<TraceEvent>> parseTraceEvents(
  Uint8List bytes,
  String filename,
) async {
  watch
    ..reset()
    ..start();

  // 1. Decompress if needed
  if (filename.endsWith('.gz')) {
    bytes = await decompressBytes(bytes);
  }

  // 2. Parse JSON natively off the main thread!
  TraceLogger.info(
    'trace',
    'Waiting for native JS response.json() pipeline...',
  );

  final jsBytes = bytes.toJS;
  final responseFinal = web.Response(jsBytes);
  final jsAny = await responseFinal.json().toDart;
  TraceLogger.info('trace', 'Native JSON parsed in ${watch.elapsed}');

  // 4. Resolve the JSArray
  JSArray jsArray;
  if (jsAny.isA<JSArray>()) {
    jsArray = jsAny as JSArray;
  } else {
    final jsObj = jsAny as JSObject;
    final traceEventsProp = jsObj.getProperty('traceEvents'.toJS);
    if (traceEventsProp != null && traceEventsProp.isA<JSArray>()) {
      jsArray = traceEventsProp as JSArray;
    } else {
      throw StateError(
        'Trace JSON has no top-level array or traceEvents property',
      );
    }
  }

  final events = <TraceEvent>[];
  final list = jsArray.toDart;
  final total = list.length;
  TraceLogger.info(
    'trace',
    'Mapping $total JS objects to TraceEvent in chunks...',
  );

  // 5. Chunk map to avoid blocking the Dart event loop
  for (int i = 0; i < total; i++) {
    final item = list[i] as JSTraceEvent?;
    if (item != null) {
      final argsAny = item.args ?? item.metadata;
      final Map<String, String> parsedArgs = {};
      if (argsAny != null) {
        final dartArgs = argsAny.dartify();
        if (dartArgs is Map) {
          dartArgs.forEach((k, v) {
            parsedArgs['$k'] = jsonEncode(v);
          });
        }
      }

      events.add(
        TraceEvent(
          name: item.name ?? 'Unknown',
          phase: item.ph ?? 'i',
          category: item.cat ?? 'TUI',
          timestamp: item.ts?.toInt() ?? 0,
          dur: item.dur?.toInt(),
          tid: item.tid?.toInt() ?? 0,
          args: parsedArgs,
        ),
      );
    }

    // Yield to the event loop every 5000 items to keep UI at 60fps
    if (i % 5000 == 0) {
      await Future.delayed(Duration.zero);
    }
  }

  watch.stop();
  TraceLogger.info('trace', 'Total parse payload time: ${watch.elapsed}');
  return events;
}
