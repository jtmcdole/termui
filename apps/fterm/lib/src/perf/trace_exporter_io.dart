import 'dart:io';

import 'package:clock/clock.dart';
import 'package:path/path.dart' as p;

import 'trace_exporter.dart'
    show TraceExportResult, formatTraceTimestamp, normalizeTraceBasePath;

/// Exports `<base>.trace.json` and `<base>.summary.json` to the local
/// filesystem, creating missing parent directories automatically.
Future<TraceExportResult> exportTraceBundle({
  required String basePath,
  required String traceJson,
  required String summaryJson,
  required int eventCount,
}) async {
  final normalized = normalizeTraceBasePath(basePath);
  final resolvedBase = normalized.isEmpty
      ? defaultTraceOutputBase()
      : normalized;
  final traceFile = File('$resolvedBase.trace.json');
  final summaryFile = File('$resolvedBase.summary.json');

  await traceFile.parent.create(recursive: true);
  await traceFile.writeAsString(traceJson, flush: true);
  await summaryFile.writeAsString(summaryJson, flush: true);
  _printSavedTraceLocation(
    summaryPath: summaryFile.path,
    tracePath: traceFile.path,
  );

  return TraceExportResult(
    tracePath: traceFile.path,
    summaryPath: summaryFile.path,
    eventCount: eventCount,
  );
}

void _printSavedTraceLocation({
  required String summaryPath,
  required String tracePath,
}) {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return;
  try {
    stdout.writeln('fterm: trace summary saved to $summaryPath');
    stdout.writeln('fterm: trace events saved to $tracePath');
  } on IOException {
    // Detached GUI hosts without an attached console may reject stdout writes.
  }
}

/// Samples current native process RSS in bytes via [ProcessInfo.currentRss].
int? sampleProcessRssBytes() {
  try {
    return ProcessInfo.currentRss;
  } on Object {
    return null;
  }
}

/// Builds a timestamped local temp output base path under
/// `<systemTemp>/fterm_traces/fterm_trace_<timestamp>`.
String defaultTraceOutputBase() {
  final stamp = formatTraceTimestamp(clock.now());
  return p.join(
    Directory.systemTemp.path,
    'fterm_traces',
    'fterm_trace_$stamp',
  );
}
