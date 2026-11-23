import 'dart:developer' as developer;

import 'package:termui/perf/tracer.dart';

/// Percentile timing summary (in microseconds) for a single instrumented phase.
final class PerfPhaseStats {
  /// Number of recorded samples in this phase.
  final int count;

  /// Shortest observed duration in microseconds.
  final int minUs;

  /// Arithmetic mean duration in microseconds.
  final double avgUs;

  /// 50th-percentile (median) duration in microseconds.
  final int p50Us;

  /// 95th-percentile duration in microseconds.
  final int p95Us;

  /// 99th-percentile duration in microseconds.
  final int p99Us;

  /// Longest observed duration in microseconds.
  final int maxUs;

  /// Creates an immutable timing summary for one trace phase.
  const PerfPhaseStats({
    required this.count,
    required this.minUs,
    required this.avgUs,
    required this.p50Us,
    required this.p95Us,
    required this.p99Us,
    required this.maxUs,
  });

  /// Empty statistics snapshot for a phase with zero samples.
  static const PerfPhaseStats empty = PerfPhaseStats(
    count: 0,
    minUs: 0,
    avgUs: 0.0,
    p50Us: 0,
    p95Us: 0,
    p99Us: 0,
    maxUs: 0,
  );

  /// Computes percentile statistics from raw microsecond [samples].
  factory PerfPhaseStats.fromSamples(List<int> samples) {
    if (samples.isEmpty) return empty;
    final sorted = List<int>.of(samples)..sort();
    var sum = 0;
    for (final value in sorted) {
      sum += value;
    }
    int pct(double fraction) {
      final idx = ((sorted.length - 1) * fraction).ceil().clamp(
        0,
        sorted.length - 1,
      );
      return sorted[idx];
    }

    return PerfPhaseStats(
      count: sorted.length,
      minUs: sorted.first,
      avgUs: double.parse((sum / sorted.length).toStringAsFixed(1)),
      p50Us: pct(0.50),
      p95Us: pct(0.95),
      p99Us: pct(0.99),
      maxUs: sorted.last,
    );
  }

  /// Decodes a [PerfPhaseStats] instance from a JSON map.
  factory PerfPhaseStats.fromJson(Map<String, Object?> json) => PerfPhaseStats(
    count: _readInt(json['count']),
    minUs: _readInt(json['minUs']),
    avgUs: _readDouble(json['avgUs']),
    p50Us: _readInt(json['p50Us']),
    p95Us: _readInt(json['p95Us']),
    p99Us: _readInt(json['p99Us']),
    maxUs: _readInt(json['maxUs']),
  );

  /// Encodes this timing summary to a JSON-compatible map.
  Map<String, Object?> toJson() => <String, Object?>{
    'count': count,
    'minUs': minUs,
    'avgUs': avgUs,
    'p50Us': p50Us,
    'p95Us': p95Us,
    'p99Us': p99Us,
    'maxUs': maxUs,
  };
}

/// Aggregated summary returned when [ShaderPerfTrace.stop] finishes a session.
final class PerfTraceSummary {
  /// Per-phase duration statistics keyed by span name.
  final Map<String, PerfPhaseStats> phases;

  /// Latest counter snapshots keyed by counter name.
  final Map<String, Map<String, num>> lastCounters;

  /// Cumulative integer counter increments keyed by counter name.
  final Map<String, int> totals;

  /// Creates an immutable trace summary.
  const PerfTraceSummary({
    required this.phases,
    required this.lastCounters,
    required this.totals,
  });

  /// Decodes a [PerfTraceSummary] from a JSON map.
  factory PerfTraceSummary.fromJson(Map<String, Object?> json) =>
      PerfTraceSummary(
        phases: _parsePhases(json['phases']),
        lastCounters: _parseCounters(json['lastCounters']),
        totals: _parseTotals(json['totals']),
      );

  static Map<String, PerfPhaseStats> _parsePhases(Object? raw) {
    if (raw is! Map<Object?, Object?>) return const <String, PerfPhaseStats>{};
    return <String, PerfPhaseStats>{
      for (final MapEntry(:key, :value) in raw.entries)
        if (key is String && value is Map<Object?, Object?>)
          key: PerfPhaseStats.fromJson(_asStringKeyMap(value)),
    };
  }

  static Map<String, Map<String, num>> _parseCounters(Object? raw) {
    if (raw is! Map<Object?, Object?>) {
      return const <String, Map<String, num>>{};
    }
    return <String, Map<String, num>>{
      for (final MapEntry(:key, :value) in raw.entries)
        if (key is String && value is Map<Object?, Object?>)
          key: _parseNumMap(value),
    };
  }

  static Map<String, num> _parseNumMap(Map<Object?, Object?> raw) =>
      <String, num>{
        for (final MapEntry(:key, :value) in raw.entries)
          if (key is String && value is num) key: value,
      };

  static Map<String, int> _parseTotals(Object? raw) {
    if (raw is! Map<Object?, Object?>) return const <String, int>{};
    return <String, int>{
      for (final MapEntry(:key, :value) in raw.entries)
        if (key is String && value is num) key: value.toInt(),
    };
  }

  /// Encodes this trace summary to a JSON-compatible map.
  Map<String, Object?> toJson() => <String, Object?>{
    'phases': <String, Object?>{
      for (final entry in phases.entries) entry.key: entry.value.toJson(),
    },
    'lastCounters': <String, Object?>{
      for (final entry in lastCounters.entries)
        entry.key: Map<String, num>.of(entry.value),
    },
    'totals': Map<String, int>.of(totals),
  };
}

/// Low-overhead dual-sink tracer for GPU shader and terminal rendering phases.
///
/// Works identically across `--debug`, `--profile`, `--release`, and Web builds.
/// When [isEnabled] is `false`, all methods return immediately with zero heap
/// allocations. When active, spans and counters aggregate percentiles in memory,
/// forward Chrome Trace events to [Tracer] (if `Tracer.isEnabled`), and
/// optionally mirror synchronous spans into `dart:developer` [developer.Timeline]
/// on non-product builds.
abstract final class ShaderPerfTrace {
  static const bool _isProductBuild = bool.fromEnvironment('dart.vm.product');
  static const int _maxSamplesPerPhase = 20000;

  static bool _enabled = false;
  static bool _mirrorToTimeline = false;
  static final Stopwatch _clock = Stopwatch();
  static final Map<String, List<int>> _samples = <String, List<int>>{};
  static final Map<String, Map<String, num>> _lastCounters =
      <String, Map<String, num>>{};
  static final Map<String, int> _totals = <String, int>{};
  static final Map<String, int> _stringIds = <String, int>{};

  /// Whether trace recording is currently active.
  static bool get isEnabled => _enabled;

  /// Begins a new trace session, clearing prior aggregated samples.
  static void start({bool mirrorToTimeline = true}) {
    _samples.clear();
    _lastCounters.clear();
    _totals.clear();
    _clock
      ..reset()
      ..start();
    _mirrorToTimeline = mirrorToTimeline && !_isProductBuild;
    _enabled = true;
  }

  /// Ends the active trace session and returns aggregated percentile statistics.
  static PerfTraceSummary stop() {
    _enabled = false;
    _mirrorToTimeline = false;
    _clock.stop();
    final summary = PerfTraceSummary(
      phases: <String, PerfPhaseStats>{
        for (final entry in _samples.entries)
          entry.key: PerfPhaseStats.fromSamples(entry.value),
      },
      lastCounters: <String, Map<String, num>>{
        for (final entry in _lastCounters.entries)
          entry.key: Map<String, num>.of(entry.value),
      },
      totals: Map<String, int>.of(_totals),
    );
    _samples.clear();
    _lastCounters.clear();
    _totals.clear();
    return summary;
  }

  /// Marks the start of a synchronous span named [name] and returns its start
  /// timestamp in microseconds (`0` when tracing is disabled).
  ///
  /// Do not pair [beginSpan]/[endSpan] across `await` boundaries; use a local
  /// [Stopwatch] with [recordDurationUs] for asynchronous pipelines.
  @pragma('vm:prefer-inline')
  static int beginSpan(String name, {Map<String, String>? args}) {
    if (!_enabled) return 0;
    if (Tracer.isEnabled) {
      Tracer.record(
        _stringIdFor(name),
        Phase.begin,
        TraceCategory.gpu,
        metadata: args,
      );
    }
    if (_mirrorToTimeline) {
      developer.Timeline.startSync(name, arguments: args);
    }
    return _clock.elapsedMicroseconds;
  }

  /// Marks the end of a synchronous span started at [startUs] by [beginSpan].
  @pragma('vm:prefer-inline')
  static void endSpan(String name, int startUs) {
    if (!_enabled) return;
    final elapsedUs = _clock.elapsedMicroseconds - startUs;
    if (_mirrorToTimeline) {
      developer.Timeline.finishSync();
    }
    if (Tracer.isEnabled) {
      Tracer.record(_stringIdFor(name), Phase.end, TraceCategory.gpu);
    }
    _appendSample(name, elapsedUs);
  }

  /// Records a standalone microsecond duration (safe across async boundaries or
  /// GPU completion callbacks).
  @pragma('vm:prefer-inline')
  static void recordDurationUs(String name, int durationUs) {
    if (!_enabled) return;
    _appendSample(name, durationUs);
    if (Tracer.isEnabled) {
      Tracer.recordCounter(_stringIdFor(name), TraceCategory.gpu, <String, num>{
        'durationUs': durationUs < 0 ? 0 : durationUs,
      });
    }
  }

  /// Records a numeric counter snapshot (`ph: "C"` in Chrome Trace JSON).
  @pragma('vm:prefer-inline')
  static void recordCounter(String name, Map<String, num> values) {
    if (!_enabled) return;
    _lastCounters[name] = Map<String, num>.of(values);
    if (Tracer.isEnabled) {
      Tracer.recordCounter(_stringIdFor(name), TraceCategory.gpu, values);
    }
  }

  /// Increments a cumulative integer counter (e.g., `staticHit` / `staticMiss`).
  @pragma('vm:prefer-inline')
  static void incrementCounter(String name, [int delta = 1]) {
    if (!_enabled) return;
    _totals[name] = (_totals[name] ?? 0) + delta;
  }

  static void _appendSample(String name, int durationUs) {
    final list = _samples.putIfAbsent(name, () => <int>[]);
    if (list.length < _maxSamplesPerPhase) {
      list.add(durationUs < 0 ? 0 : durationUs);
    }
  }

  static int _stringIdFor(String name) =>
      _stringIds.putIfAbsent(name, () => Tracer.registerString(name));
}

int _readInt(Object? value) => value is num ? value.toInt() : 0;

double _readDouble(Object? value) => value is num ? value.toDouble() : 0.0;

Map<String, Object?> _asStringKeyMap(Map<Object?, Object?> source) =>
    <String, Object?>{
      for (final entry in source.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
