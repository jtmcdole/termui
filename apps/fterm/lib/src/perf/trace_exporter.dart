import 'trace_exporter_stub.dart'
    if (dart.library.js_interop) 'trace_exporter_web.dart'
    if (dart.library.io) 'trace_exporter_io.dart'
    as impl;

/// Result returned after exporting a recorded Chrome Trace and summary bundle.
final class TraceExportResult {
  /// Destination file path or browser download filename for `.trace.json`.
  final String tracePath;

  /// Destination file path or browser download filename for `.summary.json`.
  final String summaryPath;

  /// Total number of Chrome Trace events written to [tracePath].
  final int eventCount;

  /// Creates an immutable trace export result.
  const TraceExportResult({
    required this.tracePath,
    required this.summaryPath,
    required this.eventCount,
  });

  /// Encodes this export result as a JSON-compatible map.
  Map<String, Object?> toJson() => <String, Object?>{
    'tracePath': tracePath,
    'summaryPath': summaryPath,
    'eventCount': eventCount,
  };

  @override
  String toString() =>
      'TraceExportResult(tracePath: $tracePath, summaryPath: $summaryPath, '
      'eventCount: $eventCount)';
}

/// Point-in-time process memory sample captured during trace recording.
final class TraceMemorySample {
  /// Resident set size in bytes, or `null` when unavailable (e.g. Web).
  final int? rssBytes;

  /// Creates an immutable memory sample.
  const TraceMemorySample({this.rssBytes});
}

/// Removes a trailing `.trace.json` or `.summary.json` suffix from [basePath]
/// so exporters always append canonical bundle suffixes without duplication.
String normalizeTraceBasePath(String basePath) {
  final trimmed = basePath.trim();
  if (trimmed.endsWith('.trace.json')) {
    return trimmed.substring(0, trimmed.length - '.trace.json'.length);
  }
  if (trimmed.endsWith('.summary.json')) {
    return trimmed.substring(0, trimmed.length - '.summary.json'.length);
  }
  return trimmed;
}

/// Formats a UTC [timestamp] as a compact filename-safe stamp (`YYYYMMDDTHHMMSSZ`).
String formatTraceTimestamp(DateTime timestamp) {
  final utc = timestamp.toUtc();
  final y = utc.year.toString().padLeft(4, '0');
  final mo = utc.month.toString().padLeft(2, '0');
  final d = utc.day.toString().padLeft(2, '0');
  final h = utc.hour.toString().padLeft(2, '0');
  final mi = utc.minute.toString().padLeft(2, '0');
  final s = utc.second.toString().padLeft(2, '0');
  return '$y$mo${d}T$h$mi${s}Z';
}

/// Exports `<base>.trace.json` and `<base>.summary.json` using the active
/// platform implementation (`dart:io` filesystem or browser Blob downloads).
Future<TraceExportResult> exportTraceBundle({
  required String basePath,
  required String traceJson,
  required String summaryJson,
  required int eventCount,
}) => impl.exportTraceBundle(
  basePath: basePath,
  traceJson: traceJson,
  summaryJson: summaryJson,
  eventCount: eventCount,
);

/// Samples current process resident memory (RSS) in bytes, or `null` when the
/// current platform does not expose process memory statistics.
int? sampleProcessRssBytes() => impl.sampleProcessRssBytes();

/// Returns a [TraceMemorySample] snapshot from [sampleProcessRssBytes].
TraceMemorySample sampleProcessMemory() =>
    TraceMemorySample(rssBytes: sampleProcessRssBytes());

/// Returns a platform-appropriate timestamped base path (without suffix) for
/// saving a trace bundle.
String defaultTraceOutputBase() => impl.defaultTraceOutputBase();
