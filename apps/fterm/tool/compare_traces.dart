import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// Percentile latency metrics (in microseconds) parsed from a `.summary.json`
/// phase or frame-timing object.
final class TracePhaseMetric {
  /// Number of recorded samples.
  final int count;

  /// Shortest observed duration in microseconds.
  final int minUs;

  /// Arithmetic mean duration in microseconds.
  final double avgUs;

  /// 50th-percentile duration in microseconds.
  final int p50Us;

  /// 95th-percentile duration in microseconds.
  final int p95Us;

  /// 99th-percentile duration in microseconds.
  final int p99Us;

  /// Longest observed duration in microseconds.
  final int maxUs;

  /// Creates an immutable phase latency record.
  const TracePhaseMetric({
    required this.count,
    required this.minUs,
    required this.avgUs,
    required this.p50Us,
    required this.p95Us,
    required this.p99Us,
    required this.maxUs,
  });

  /// Empty latency metrics for missing sections.
  static const TracePhaseMetric empty = TracePhaseMetric(
    count: 0,
    minUs: 0,
    avgUs: 0.0,
    p50Us: 0,
    p95Us: 0,
    p99Us: 0,
    maxUs: 0,
  );

  /// Parses a [TracePhaseMetric] from a decoded JSON map.
  factory TracePhaseMetric.fromJson(Map<String, Object?> json) =>
      TracePhaseMetric(
        count: _readInt(json['count']),
        minUs: _readInt(json['minUs']),
        avgUs: _readDouble(json['avgUs']),
        p50Us: _readInt(json['p50Us']),
        p95Us: _readInt(json['p95Us']),
        p99Us: _readInt(json['p99Us']),
        maxUs: _readInt(json['maxUs']),
      );
}

/// Normalized summary entry compared side by side by [formatComparisonMarkdown].
final class TraceComparisonEntry {
  /// Column header label displayed in the Markdown table.
  final String label;

  /// Platform name (e.g. `web`, `windows`, `macos`, `linux`).
  final String platform;

  /// Flutter build mode (`debug`, `profile`, or `release`).
  final String buildMode;

  /// Active GPU shader backend (`flutterGpu`, `webGl2`, `disabled`).
  final String backendKind;

  /// Viewport physical width in pixels.
  final int viewportPhysicalWidth;

  /// Viewport physical height in pixels.
  final int viewportPhysicalHeight;

  /// Device pixel ratio.
  final double devicePixelRatio;

  /// Active shader identifiers.
  final List<String> activeShaders;

  /// Recorded session wall-clock duration in milliseconds.
  final int recordedDurationMs;

  /// Total frames observed during the trace session.
  final int frameCount;

  /// Effective frames per second.
  final double fps;

  /// Process RSS in bytes at session start (`null` on Web).
  final int? rssStartBytes;

  /// Peak process RSS in bytes (`null` on Web).
  final int? rssPeakBytes;

  /// Process RSS in bytes at session end (`null` on Web).
  final int? rssEndBytes;

  /// Process RSS delta (`end - start`) in bytes (`null` on Web).
  final int? rssDeltaBytes;

  /// Peak backing texture count reported by GPU diagnostics.
  final int peakBackingTextures;

  /// Peak in-flight GPU frame count reported by GPU diagnostics.
  final int peakInFlightFrames;

  /// Cumulative backpressure frame skips observed during the session.
  final int backpressureSkips;

  /// Most recent GPU completion latency in microseconds.
  final int lastGpuCompletionUs;

  /// UI thread build frame timings.
  final TracePhaseMetric buildTiming;

  /// GPU/raster thread frame timings.
  final TracePhaseMetric rasterTiming;

  /// End-to-end total frame timings.
  final TracePhaseMetric totalTiming;

  /// Per-phase instrumented latency summaries keyed by phase name.
  final Map<String, TracePhaseMetric> phases;

  /// Creates an immutable trace comparison entry.
  const TraceComparisonEntry({
    required this.label,
    required this.platform,
    required this.buildMode,
    required this.backendKind,
    required this.viewportPhysicalWidth,
    required this.viewportPhysicalHeight,
    required this.devicePixelRatio,
    required this.activeShaders,
    required this.recordedDurationMs,
    required this.frameCount,
    required this.fps,
    required this.rssStartBytes,
    required this.rssPeakBytes,
    required this.rssEndBytes,
    required this.rssDeltaBytes,
    required this.peakBackingTextures,
    required this.peakInFlightFrames,
    required this.backpressureSkips,
    required this.lastGpuCompletionUs,
    required this.buildTiming,
    required this.rasterTiming,
    required this.totalTiming,
    required this.phases,
  });

  /// Parses a [TraceComparisonEntry] from a decoded `.summary.json` map.
  factory TraceComparisonEntry.fromJson(
    Map<String, Object?> json, {
    String? label,
  }) {
    final env = _asStringMap(json['environment']);
    final mem = _asStringMap(json['memory']);
    final gpu = _asStringMap(json['gpu']);
    final timings = _asStringMap(json['frameTimings']);

    final platform = _readString(env['platform'], fallback: 'unknown');
    final buildMode = _readString(env['buildMode'], fallback: 'unknown');
    final backendKind = _readString(env['backendKind'], fallback: 'unknown');
    final resolvedLabel = (label != null && label.trim().isNotEmpty)
        ? label.trim()
        : '$platform-$buildMode ($backendKind)';

    return TraceComparisonEntry(
      label: resolvedLabel,
      platform: platform,
      buildMode: buildMode,
      backendKind: backendKind,
      viewportPhysicalWidth: _readInt(env['viewportPhysicalWidth']),
      viewportPhysicalHeight: _readInt(env['viewportPhysicalHeight']),
      devicePixelRatio: _readDouble(env['devicePixelRatio'], fallback: 1.0),
      activeShaders: _readStringList(env['activeShaders']),
      recordedDurationMs: _readInt(env['recordedDurationMs']),
      frameCount: _readInt(env['frameCount']),
      fps: _readDouble(env['fps']),
      rssStartBytes: _readNullableInt(mem['rssStartBytes']),
      rssPeakBytes: _readNullableInt(mem['rssPeakBytes']),
      rssEndBytes: _readNullableInt(mem['rssEndBytes']),
      rssDeltaBytes: _readNullableInt(mem['rssDeltaBytes']),
      peakBackingTextures: _readInt(gpu['peakBackingTextures']),
      peakInFlightFrames: _readInt(gpu['peakInFlightFrames']),
      backpressureSkips: _readInt(gpu['backpressureSkips']),
      lastGpuCompletionUs: _readInt(gpu['lastGpuCompletionUs']),
      buildTiming: TracePhaseMetric.fromJson(_asStringMap(timings['build'])),
      rasterTiming: TracePhaseMetric.fromJson(_asStringMap(timings['raster'])),
      totalTiming: TracePhaseMetric.fromJson(_asStringMap(timings['total'])),
      phases: _parsePhaseMetrics(json['phases']),
    );
  }

  /// Reads and parses a `.summary.json` [file] from disk.
  factory TraceComparisonEntry.fromFile(File file, {String? label}) {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<Object?, Object?>) {
      throw FormatException(
        'Expected JSON object in trace summary: ${file.path}',
      );
    }
    return TraceComparisonEntry.fromJson(
      _asStringMap(decoded),
      label: label ?? _labelFromFilePath(file.path),
    );
  }
}

/// Formats a side-by-side Markdown comparison report for [entries].
String formatComparisonMarkdown(
  List<TraceComparisonEntry> entries, {
  int topPhaseCount = 15,
}) {
  if (entries.isEmpty) {
    return 'No trace summaries provided.\n';
  }

  final out = StringBuffer()
    ..writeln('## Trace Comparison')
    ..writeln();
  _writeOverviewTable(out, entries);
  _writeBottleneckPhasesTable(out, entries, topPhaseCount: topPhaseCount);
  return out.toString();
}

/// CLI entrypoint comparing one or more `.summary.json` trace files.
void main(List<String> args) {
  if (args.isEmpty || args.contains('--help') || args.contains('-h')) {
    stderr.writeln(
      'Usage: dart run apps/fterm/tool/compare_traces.dart '
      '<a.summary.json> <b.summary.json> [...]',
    );
    if (args.isEmpty) {
      exitCode = 64;
    }
    return;
  }

  final entries = <TraceComparisonEntry>[];
  for (final arg in args) {
    final file = File(arg);
    if (!file.existsSync()) {
      stderr.writeln('Error: file not found: $arg');
      exitCode = 1;
      return;
    }
    try {
      entries.add(TraceComparisonEntry.fromFile(file));
    } on Object catch (error) {
      stderr.writeln('Error parsing $arg: $error');
      exitCode = 1;
      return;
    }
  }

  stdout.write(formatComparisonMarkdown(entries));
}

void _writeOverviewTable(StringBuffer out, List<TraceComparisonEntry> entries) {
  _writeMarkdownRow(out, <String>[
    'Metric',
    for (final entry in entries) entry.label,
  ]);
  _writeMarkdownRow(out, <String>[
    '---',
    for (var i = 0; i < entries.length; i++) '---',
  ]);

  final rows = <(String, String Function(TraceComparisonEntry))>[
    ('Environment', (e) => '${e.platform} / ${e.buildMode} / ${e.backendKind}'),
    (
      'Viewport',
      (e) =>
          '${e.viewportPhysicalWidth}x${e.viewportPhysicalHeight} '
          '@ ${e.devicePixelRatio.toStringAsFixed(2)}x',
    ),
    (
      'Shaders',
      (e) => e.activeShaders.isEmpty ? 'none' : e.activeShaders.join(', '),
    ),
    (
      'Duration / Frames',
      (e) => '${e.recordedDurationMs} ms (${e.frameCount})',
    ),
    ('FPS', (e) => e.fps.toStringAsFixed(1)),
    ('UI avg / p95', (e) => _formatAvgP95Ms(e.buildTiming)),
    ('GPU avg / p95', (e) => _formatAvgP95Ms(e.rasterTiming)),
    ('Total avg / p95', (e) => _formatAvgP95Ms(e.totalTiming)),
    ('RSS Start', (e) => _formatMiB(e.rssStartBytes)),
    ('RSS Peak', (e) => _formatMiB(e.rssPeakBytes)),
    ('RSS End', (e) => _formatMiB(e.rssEndBytes)),
    ('RSS Delta', (e) => _formatSignedMiB(e.rssDeltaBytes)),
    ('Peak Backing Textures', (e) => '${e.peakBackingTextures}'),
    ('Peak In-Flight Frames', (e) => '${e.peakInFlightFrames}'),
    ('Backpressure Skips', (e) => '${e.backpressureSkips}'),
    ('Last GPU Completion', (e) => _formatUsAsMs(e.lastGpuCompletionUs)),
  ];

  for (final (metricName, formatter) in rows) {
    _writeMarkdownRow(out, <String>[
      metricName,
      for (final entry in entries) formatter(entry),
    ]);
  }
}

void _writeBottleneckPhasesTable(
  StringBuffer out,
  List<TraceComparisonEntry> entries, {
  required int topPhaseCount,
}) {
  final ranked = _rankPhasesByMaxAvg(entries);
  if (ranked.isEmpty) return;

  final limit = topPhaseCount <= 0
      ? ranked.length
      : math.min(topPhaseCount, ranked.length);

  out
    ..writeln()
    ..writeln('### Top Bottleneck Phases (sorted by max avg latency)')
    ..writeln();
  _writeMarkdownRow(out, <String>[
    'Phase',
    for (final entry in entries) '${entry.label} (avg / p95 / max)',
  ]);
  _writeMarkdownRow(out, <String>[
    '---',
    for (var i = 0; i < entries.length; i++) '---',
  ]);

  for (var i = 0; i < limit; i++) {
    final phaseName = ranked[i].$1;
    _writeMarkdownRow(out, <String>[
      '`$phaseName`',
      for (final entry in entries) _formatPhaseCell(entry.phases[phaseName]),
    ]);
  }
}

List<(String, double)> _rankPhasesByMaxAvg(List<TraceComparisonEntry> entries) {
  final maxAvgByPhase = <String, double>{};
  for (final entry in entries) {
    for (final MapEntry(:key, :value) in entry.phases.entries) {
      final previous = maxAvgByPhase[key];
      if (previous == null || value.avgUs > previous) {
        maxAvgByPhase[key] = value.avgUs;
      }
    }
  }
  final ranked = <(String, double)>[
    for (final MapEntry(:key, :value) in maxAvgByPhase.entries) (key, value),
  ];
  ranked.sort((a, b) {
    final byLatency = b.$2.compareTo(a.$2);
    return byLatency != 0 ? byLatency : a.$1.compareTo(b.$1);
  });
  return ranked;
}

void _writeMarkdownRow(StringBuffer out, List<String> cells) {
  out.write('| ');
  for (var i = 0; i < cells.length; i++) {
    if (i > 0) out.write(' | ');
    out.write(cells[i].replaceAll('|', r'\|'));
  }
  out.writeln(' |');
}

String _formatAvgP95Ms(TracePhaseMetric metric) {
  if (metric.count == 0) return 'n/a';
  final avgMs = (metric.avgUs / 1000.0).toStringAsFixed(2);
  final p95Ms = (metric.p95Us / 1000.0).toStringAsFixed(2);
  return '$avgMs ms / $p95Ms ms';
}

String _formatPhaseCell(TracePhaseMetric? metric) {
  if (metric == null || metric.count == 0) return '-';
  final avgMs = (metric.avgUs / 1000.0).toStringAsFixed(2);
  final p95Ms = (metric.p95Us / 1000.0).toStringAsFixed(2);
  final maxMs = (metric.maxUs / 1000.0).toStringAsFixed(2);
  return '$avgMs / $p95Ms / $maxMs ms (n=${metric.count})';
}

String _formatUsAsMs(int us) {
  if (us <= 0) return '0.00 ms';
  return '${(us / 1000.0).toStringAsFixed(2)} ms';
}

String _formatMiB(int? bytes) {
  if (bytes == null) return 'n/a';
  return '${(bytes / (1024.0 * 1024.0)).toStringAsFixed(1)} MiB';
}

String _formatSignedMiB(int? bytes) {
  if (bytes == null) return 'n/a';
  final mib = bytes / (1024.0 * 1024.0);
  final sign = mib > 0 ? '+' : '';
  return '$sign${mib.toStringAsFixed(1)} MiB';
}

String _labelFromFilePath(String path) {
  final lastSlash = path.lastIndexOf('/');
  final lastBackslash = path.lastIndexOf(r'\');
  final splitIndex = math.max(lastSlash, lastBackslash);
  final fileName = splitIndex < 0 ? path : path.substring(splitIndex + 1);
  if (fileName.endsWith('.summary.json')) {
    return fileName.substring(0, fileName.length - '.summary.json'.length);
  }
  return fileName;
}

Map<String, TracePhaseMetric> _parsePhaseMetrics(Object? raw) {
  final container = _asStringMap(raw);
  if (container.isEmpty) return const <String, TracePhaseMetric>{};
  final nestedPhases = container['phases'];
  final phaseSource = nestedPhases is Map<Object?, Object?>
      ? _asStringMap(nestedPhases)
      : container;
  return <String, TracePhaseMetric>{
    for (final MapEntry(:key, :value) in phaseSource.entries)
      if (value is Map<Object?, Object?> && _looksLikePhaseMetric(value))
        key: TracePhaseMetric.fromJson(_asStringMap(value)),
  };
}

bool _looksLikePhaseMetric(Map<Object?, Object?> map) =>
    map.containsKey('count') || map.containsKey('avgUs');

Map<String, Object?> _asStringMap(Object? raw) {
  if (raw is! Map<Object?, Object?>) return const <String, Object?>{};
  return <String, Object?>{
    for (final MapEntry(:key, :value) in raw.entries)
      if (key is String) key: value,
  };
}

int _readInt(Object? raw) => raw is num ? raw.toInt() : 0;

int? _readNullableInt(Object? raw) => raw is num ? raw.toInt() : null;

double _readDouble(Object? raw, {double fallback = 0.0}) =>
    raw is num ? raw.toDouble() : fallback;

String _readString(Object? raw, {required String fallback}) {
  if (raw is String && raw.trim().isNotEmpty) {
    return raw.trim();
  }
  return fallback;
}

List<String> _readStringList(Object? raw) {
  if (raw is! List<Object?>) return const <String>[];
  return <String>[
    for (final item in raw)
      if (item is String && item.trim().isNotEmpty) item.trim(),
  ];
}
