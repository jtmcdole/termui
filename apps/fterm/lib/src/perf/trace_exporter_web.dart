import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:clock/clock.dart';
import 'package:web/web.dart' as web;

import 'trace_exporter.dart'
    show TraceExportResult, formatTraceTimestamp, normalizeTraceBasePath;

/// Triggers browser Blob downloads for `<base>.summary.json` and
/// `<base>.trace.json`.
Future<TraceExportResult> exportTraceBundle({
  required String basePath,
  required String traceJson,
  required String summaryJson,
  required int eventCount,
}) async {
  final normalized = _extractWebBaseName(normalizeTraceBasePath(basePath));
  final resolvedBase = normalized.isEmpty
      ? defaultTraceOutputBase()
      : normalized;
  final summaryName = '$resolvedBase.summary.json';
  final traceName = '$resolvedBase.trace.json';

  _triggerJsonDownload(summaryName, summaryJson);
  await Future<void>.delayed(const Duration(milliseconds: 150));
  _triggerJsonDownload(traceName, traceJson);

  return TraceExportResult(
    tracePath: traceName,
    summaryPath: summaryName,
    eventCount: eventCount,
  );
}

/// Always returns `null` on Web because browsers do not expose process RSS.
int? sampleProcessRssBytes() => null;

/// Builds a timestamped browser download filename stem without extension.
String defaultTraceOutputBase() =>
    'fterm_trace_${formatTraceTimestamp(clock.now())}';

String _extractWebBaseName(String path) {
  if (path.isEmpty) return '';
  final lastSlash = path.lastIndexOf('/');
  final lastBackslash = path.lastIndexOf(r'\');
  final splitIndex = lastSlash > lastBackslash ? lastSlash : lastBackslash;
  return splitIndex < 0 ? path : path.substring(splitIndex + 1);
}

void _triggerJsonDownload(String filename, String jsonPayload) {
  final jsBytes = utf8.encode(jsonPayload).toJS;
  final blobParts = <JSAny>[jsBytes].toJS;
  final blob = web.Blob(
    blobParts,
    web.BlobPropertyBag(type: 'application/json'),
  );
  final url = web.URL.createObjectURL(blob);

  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename
    ..style.display = 'none';

  web.document.body?.appendChild(anchor);
  try {
    anchor.click();
  } finally {
    anchor.remove();
    Timer(const Duration(seconds: 10), () => web.URL.revokeObjectURL(url));
  }
}
