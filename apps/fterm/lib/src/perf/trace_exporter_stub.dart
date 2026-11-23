import 'package:clock/clock.dart';

import 'trace_exporter.dart'
    show TraceExportResult, formatTraceTimestamp, normalizeTraceBasePath;

/// Pure-Dart no-op trace exporter for headless non-IO, non-Web targets.
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
  return TraceExportResult(
    tracePath: '$resolvedBase.trace.json',
    summaryPath: '$resolvedBase.summary.json',
    eventCount: eventCount,
  );
}

/// Returns `null` on targets without native process memory introspection.
int? sampleProcessRssBytes() => null;

/// Builds a timestamped stub base name without filesystem paths.
String defaultTraceOutputBase() =>
    'fterm_trace_${formatTraceTimestamp(clock.now())}';
