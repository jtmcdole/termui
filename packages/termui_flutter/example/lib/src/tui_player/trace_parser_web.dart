@JS()
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'package:web/web.dart' as web;
import 'package:termui/trace/trace_logger.dart';
import 'package:termui/trace/models/trace_models.dart';

@JS('DecompressionStream')
extension type DecompressionStream._(JSObject _) implements JSObject {
  external DecompressionStream(String format);
}

@JS('TextDecoder')
extension type TextDecoder._(JSObject _) implements JSObject {
  external TextDecoder(String encoding);
  external String decode(JSAny? buffer);
}

extension on web.ReadableStream {
  @JS('pipeThrough')
  external web.ReadableStream pipeThroughGzip(DecompressionStream stream);
}

final watch = Stopwatch();
Future<List<TraceEvent>> parseTraceEvents(
  Uint8List bytes,
  String filename,
) async {
  watch
    ..reset()
    ..start();

  // 1. Create a stream from compressed array buffer
  final jsBytes = bytes.toJS;
  final responseInitial = web.Response(jsBytes);
  var stream = responseInitial.body;
  if (stream == null) throw StateError('No body in Response');

  // 2. Pipe it through gzip DecompressionStream if needed
  if (filename.endsWith('.gz')) {
    final decompressionStream = DecompressionStream('gzip');
    stream = stream.pipeThroughGzip(decompressionStream);
  }

  // 3. Parse JSON natively off the main thread!
  TraceLogger.info(
    'trace',
    'Waiting for native JS response.json() pipeline...',
  );
  final responseFinal = web.Response(stream);
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
    final item = list[i];
    if (item != null) {
      final dartObj = item.dartify();
      if (dartObj is Map) {
        final map = dartObj.cast<String, dynamic>();
        events.add(TraceEvent.fromJson(map));
      }
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
