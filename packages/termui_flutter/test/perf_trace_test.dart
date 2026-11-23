import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:termui/perf/memory_sink.dart';
import 'package:termui/perf/tracer.dart';
import 'package:termui_flutter/termui_flutter.dart';

void main() {
  tearDown(() async {
    if (ShaderPerfTrace.isEnabled) {
      ShaderPerfTrace.stop();
    }
    if (Tracer.isEnabled) {
      await Tracer.stop();
    }
  });

  group('PerfPhaseStats', () {
    test('computes accurate percentiles and round-trips JSON', () {
      final samples = <int>[for (var i = 1; i <= 100; i++) i * 10];
      final stats = PerfPhaseStats.fromSamples(samples);
      expect(stats.count, equals(100));
      expect(stats.minUs, equals(10));
      expect(stats.maxUs, equals(1000));
      expect(stats.avgUs, equals(505.0));
      expect(stats.p50Us, equals(510));
      expect(stats.p95Us, equals(960));
      expect(stats.p99Us, equals(1000));

      final decoded = PerfPhaseStats.fromJson(stats.toJson());
      expect(decoded.count, equals(stats.count));
      expect(decoded.minUs, equals(stats.minUs));
      expect(decoded.avgUs, equals(stats.avgUs));
      expect(decoded.p50Us, equals(stats.p50Us));
      expect(decoded.p95Us, equals(stats.p95Us));
      expect(decoded.p99Us, equals(stats.p99Us));
      expect(decoded.maxUs, equals(stats.maxUs));
    });

    test('returns empty stats for empty sample list', () {
      final stats = PerfPhaseStats.fromSamples(const <int>[]);
      expect(stats.count, equals(0));
      expect(stats.avgUs, equals(0.0));
      expect(stats.maxUs, equals(0));
    });
  });

  group('ShaderPerfTrace', () {
    test(
      'disabled fast path records zero spans, counters, or Tracer events',
      () async {
        late MemoryTracerSink memSink;
        Tracer.activeCategories = {...TraceCategory.values};
        await Tracer.startWithSink((baseEpochUs) {
          memSink = MemoryTracerSink(baseEpochUs: baseEpochUs);
          return memSink;
        });

        expect(ShaderPerfTrace.isEnabled, isFalse);
        final token = ShaderPerfTrace.beginSpan('disabledSpan');
        expect(token, equals(0));
        ShaderPerfTrace.endSpan('disabledSpan', token);
        ShaderPerfTrace.recordDurationUs('disabledAsync', 250);
        ShaderPerfTrace.recordCounter('disabledCounter', const <String, num>{
          'v': 1,
        });
        ShaderPerfTrace.incrementCounter('disabledTotal');

        await Tracer.stop();
        expect(memSink.eventCount, equals(0));
        final summary = ShaderPerfTrace.stop();
        expect(summary.phases, isEmpty);
        expect(summary.lastCounters, isEmpty);
        expect(summary.totals, isEmpty);
      },
    );

    test(
      'records spans, async durations, counters, and valid Chrome Trace JSON',
      () async {
        late MemoryTracerSink memSink;
        Tracer.activeCategories = {...TraceCategory.values};
        await Tracer.startWithSink((baseEpochUs) {
          memSink = MemoryTracerSink(baseEpochUs: baseEpochUs);
          return memSink;
        });
        ShaderPerfTrace.start(mirrorToTimeline: false);
        expect(ShaderPerfTrace.isEnabled, isTrue);

        final startUs = ShaderPerfTrace.beginSpan(
          'FlutterGpu.bgPasses',
          args: const <String, String>{'passes': '1'},
        );
        ShaderPerfTrace.endSpan('FlutterGpu.bgPasses', startUs);
        ShaderPerfTrace.recordDurationUs('FlutterGpu.gpuCompletion', 120);
        ShaderPerfTrace.recordDurationUs('FlutterGpu.gpuCompletion', 360);
        ShaderPerfTrace.recordCounter('gpu.diagnostics', const <String, num>{
          'inFlight': 1,
          'backingTextures': 3,
        });
        ShaderPerfTrace.incrementCounter('staticHit', 5);

        final summary = ShaderPerfTrace.stop();
        await Tracer.stop();

        expect(ShaderPerfTrace.isEnabled, isFalse);
        expect(summary.phases['FlutterGpu.bgPasses']?.count, equals(1));
        expect(summary.phases['FlutterGpu.gpuCompletion']?.count, equals(2));
        expect(summary.phases['FlutterGpu.gpuCompletion']?.minUs, equals(120));
        expect(summary.phases['FlutterGpu.gpuCompletion']?.maxUs, equals(360));
        expect(
          summary.lastCounters['gpu.diagnostics']?['backingTextures'],
          equals(3),
        );
        expect(summary.totals['staticHit'], equals(5));

        // Verify summary JSON round-trip.
        final roundTrip = PerfTraceSummary.fromJson(
          jsonDecode(jsonEncode(summary.toJson())) as Map<String, Object?>,
        );
        expect(
          roundTrip.phases['FlutterGpu.gpuCompletion']?.avgUs,
          equals(240.0),
        );
        expect(roundTrip.totals['staticHit'], equals(5));
        expect(
          roundTrip.lastCounters['gpu.diagnostics']?['inFlight'],
          equals(1),
        );

        // Verify MemoryTracerSink produced valid Chrome Trace Event JSON.
        final traceEvents = [
          for (final e in jsonDecode(memSink.toTraceJson()) as List<Object?>)
            e as Map<String, Object?>,
        ];
        expect(traceEvents, hasLength(5));
        expect(traceEvents[0]['ph'], equals('B'));
        expect(traceEvents[1]['ph'], equals('E'));
        expect(traceEvents[2]['ph'], equals('C'));
        expect(traceEvents[4]['name'], equals('gpu.diagnostics'));
        final diagArgs = traceEvents[4]['args'] as Map<String, Object?>;
        expect(diagArgs['backingTextures'], equals(3));
      },
    );
  });

  group('ShaderBackendDiagnostics', () {
    test('defaults all diagnostic fields to zero', () {
      const diag = ShaderBackendDiagnostics();
      expect(diag.inFlightFrames, equals(0));
      expect(diag.maxFramesInFlight, equals(0));
      expect(diag.backpressureSkips, equals(0));
      expect(diag.backingTextureCount, equals(0));
      expect(diag.surfaceCount, equals(0));
      expect(diag.staticCacheHits, equals(0));
      expect(diag.staticCacheMisses, equals(0));
      expect(diag.lastGpuCompletionUs, equals(0));
    });
  });
}
