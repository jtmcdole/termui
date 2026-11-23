import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/perf/fterm_trace_recorder.dart';
import 'package:fterm/src/perf/trace_exporter.dart';
import 'package:fterm/src/perf/trace_exporter_stub.dart' as stub_exporter;
import 'package:path/path.dart' as p;
import 'package:termui/perf/tracer.dart';
import 'package:termui_flutter/termui_flutter.dart'
    show
        DiagnosableShaderBackend,
        PerfPhaseStats,
        PerfTraceSummary,
        ShaderBackendDiagnostics,
        ShaderPerfTrace;

import '../tool/compare_traces.dart';

final class _FakeDiagnosableBackend implements DiagnosableShaderBackend {
  ShaderBackendDiagnostics current = const ShaderBackendDiagnostics();

  @override
  ShaderBackendDiagnostics readDiagnostics() => current;
}

void main() {
  tearDown(() async {
    if (ShaderPerfTrace.isEnabled) {
      ShaderPerfTrace.stop();
    }
    if (Tracer.isEnabled) {
      await Tracer.stop();
    }
  });

  group('trace_exporter', () {
    test('normalizes .trace.json and .summary.json suffixes', () {
      expect(normalizeTraceBasePath('/tmp/run.trace.json'), equals('/tmp/run'));
      expect(
        normalizeTraceBasePath('/tmp/run.summary.json'),
        equals('/tmp/run'),
      );
      expect(normalizeTraceBasePath('  /tmp/run  '), equals('/tmp/run'));
    });

    test('exports trace and summary JSON files on dart:io', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'fterm_trace_exporter_test_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final baseWithSuffix = p.join(
        tempDir.path,
        'nested',
        'session.trace.json',
      );
      final result = await exportTraceBundle(
        basePath: baseWithSuffix,
        traceJson: '[{"name":"span","ph":"B"}]\n',
        summaryJson: '{"environment":{"platform":"windows"}}\n',
        eventCount: 1,
      );

      expect(result.tracePath, endsWith('session.trace.json'));
      expect(result.summaryPath, endsWith('session.summary.json'));
      expect(result.eventCount, equals(1));
      expect(
        await File(result.tracePath).readAsString(),
        equals('[{"name":"span","ph":"B"}]\n'),
      );
      expect(
        await File(result.summaryPath).readAsString(),
        equals('{"environment":{"platform":"windows"}}\n'),
      );
      expect(result.toJson()['eventCount'], equals(1));
      expect(result.toString(), contains('eventCount: 1'));

      final rss = sampleProcessRssBytes();
      expect(rss, isNotNull);
      expect(rss!, greaterThan(0));
      expect(sampleProcessMemory().rssBytes, greaterThan(0));
      expect(defaultTraceOutputBase(), contains('fterm_trace_'));
    });

    test(
      'stub exporter returns normalized paths without touching disk',
      () async {
        final result = await stub_exporter.exportTraceBundle(
          basePath: 'capture.summary.json',
          traceJson: '[]\n',
          summaryJson: '{}\n',
          eventCount: 0,
        );
        expect(result.tracePath, equals('capture.trace.json'));
        expect(result.summaryPath, equals('capture.summary.json'));
        expect(result.eventCount, equals(0));
        expect(stub_exporter.sampleProcessRssBytes(), isNull);
        expect(
          stub_exporter.defaultTraceOutputBase(),
          startsWith('fterm_trace_'),
        );
      },
    );
  });

  group('FtermTraceRecorder', () {
    test('records frame timings, diagnostics, RSS, ShaderPerfTrace phases, and exports valid JSON', () async {
      final backend = _FakeDiagnosableBackend()
        ..current = const ShaderBackendDiagnostics(
          inFlightFrames: 1,
          maxFramesInFlight: 2,
          backpressureSkips: 0,
          backingTextureCount: 3,
          surfaceCount: 1,
          staticCacheHits: 10,
          staticCacheMisses: 2,
          lastGpuCompletionUs: 420,
        );
      final rssSequence = <int>[100 * 1024 * 1024, 140 * 1024 * 1024];
      var rssIndex = 0;

      ui.TimingsCallback? registeredCallback;
      var registerCalls = 0;
      var unregisterCalls = 0;
      String? capturedTraceJson;
      String? capturedSummaryJson;
      String? capturedBasePath;

      final recorder = FtermTraceRecorder(
        sampleRssBytes: () {
          final value =
              rssSequence[rssIndex < rssSequence.length
                  ? rssIndex
                  : rssSequence.length - 1];
          rssIndex++;
          return value;
        },
        diagnosableBackend: backend,
        readMetadata: () => const TraceSessionMetadata(
          platform: 'windows',
          buildMode: 'release',
          backendKind: 'flutterGpu',
          viewportPhysicalWidth: 1920,
          viewportPhysicalHeight: 1080,
          devicePixelRatio: 1.5,
          activeShaders: <String>['crt', 'bloom'],
        ),
        exporter:
            ({
              required basePath,
              required traceJson,
              required summaryJson,
              required eventCount,
            }) async {
              capturedBasePath = basePath;
              capturedTraceJson = traceJson;
              capturedSummaryJson = summaryJson;
              return TraceExportResult(
                tracePath: '$basePath.trace.json',
                summaryPath: '$basePath.summary.json',
                eventCount: eventCount,
              );
            },
        registerTimingsCallback: (cb) {
          registerCalls++;
          registeredCallback = cb;
        },
        unregisterTimingsCallback: (cb) {
          expect(cb, same(registeredCallback));
          unregisterCalls++;
          registeredCallback = null;
        },
        sampleInterval: const Duration(seconds: 10),
      );
      addTearDown(recorder.dispose);

      var notifications = 0;
      recorder.addListener(() => notifications++);

      expect(recorder.isRecording, isFalse);
      expect(
        await recorder.start(
          outputBasePath: 'test_capture',
          mirrorToTimeline: false,
        ),
        isTrue,
      );
      expect(recorder.isRecording, isTrue);
      expect(registerCalls, equals(1));
      expect(registeredCallback, isNotNull);
      expect(notifications, equals(1));

      // Inject synthetic FrameTiming through the registered callback.
      registeredCallback!(<ui.FrameTiming>[
        ui.FrameTiming(
          vsyncStart: 1000000,
          buildStart: 1000100,
          buildFinish: 1001100,
          rasterStart: 1001200,
          rasterFinish: 1004200,
          rasterFinishWallTime: 1004200,
        ),
      ]);
      // Inject deterministic microsecond samples.
      recorder.recordFrameTimingUs(
        buildUs: 1500,
        rasterUs: 3500,
        totalUs: 5000,
        vsyncTimestampUs: 1016667,
      );
      recorder.recordFrameTimingUs(
        buildUs: 2000,
        rasterUs: 4000,
        totalUs: 6000,
        vsyncTimestampUs: 1033334,
      );

      // Record ShaderPerfTrace spans & counters while active.
      final spanToken = ShaderPerfTrace.beginSpan('FlutterGpu.submit');
      ShaderPerfTrace.endSpan('FlutterGpu.submit', spanToken);
      ShaderPerfTrace.recordDurationUs('FlutterGpu.gpuCompletion', 850);
      ShaderPerfTrace.incrementCounter('staticHit', 7);

      // Escalate backend diagnostics before stop so final sample captures peaks.
      backend.current = const ShaderBackendDiagnostics(
        inFlightFrames: 2,
        maxFramesInFlight: 2,
        backpressureSkips: 3,
        backingTextureCount: 6,
        surfaceCount: 2,
        staticCacheHits: 17,
        staticCacheMisses: 2,
        lastGpuCompletionUs: 910,
      );

      final export = await recorder.stop();
      expect(export, isNotNull);
      expect(recorder.isRecording, isFalse);
      expect(recorder.lastExport, same(export));
      expect(recorder.lastError, isNull);
      expect(recorder.recordedFrameCount, equals(3));
      expect(unregisterCalls, equals(1));
      expect(notifications, equals(2));
      expect(capturedBasePath, equals('test_capture'));

      // Verify .summary.json structure and values.
      final summary = jsonDecode(capturedSummaryJson!) as Map<String, Object?>;
      final env = summary['environment'] as Map<String, Object?>;
      expect(env['platform'], equals('windows'));
      expect(env['buildMode'], equals('release'));
      expect(env['backendKind'], equals('flutterGpu'));
      expect(env['viewportPhysicalWidth'], equals(1920));
      expect(env['viewportPhysicalHeight'], equals(1080));
      expect(env['devicePixelRatio'], equals(1.5));
      expect(env['activeShaders'], equals(<String>['crt', 'bloom']));
      expect(env['frameCount'], equals(3));
      expect(env['fps'], closeTo(60.0, 0.2));

      final mem = summary['memory'] as Map<String, Object?>;
      expect(mem['rssStartBytes'], equals(100 * 1024 * 1024));
      expect(mem['rssPeakBytes'], equals(140 * 1024 * 1024));
      expect(mem['rssEndBytes'], equals(140 * 1024 * 1024));
      expect(mem['rssDeltaBytes'], equals(40 * 1024 * 1024));

      final gpu = summary['gpu'] as Map<String, Object?>;
      expect(gpu['peakBackingTextures'], equals(6));
      expect(gpu['peakInFlightFrames'], equals(2));
      expect(gpu['backpressureSkips'], equals(3));
      expect(gpu['lastGpuCompletionUs'], equals(910));

      final timings = summary['frameTimings'] as Map<String, Object?>;
      final buildStats = PerfPhaseStats.fromJson(
        timings['build'] as Map<String, Object?>,
      );
      final rasterStats = PerfPhaseStats.fromJson(
        timings['raster'] as Map<String, Object?>,
      );
      expect(buildStats.count, equals(3));
      expect(buildStats.minUs, equals(1000));
      expect(buildStats.maxUs, equals(2000));
      expect(rasterStats.minUs, equals(3000));
      expect(rasterStats.maxUs, equals(4000));

      final phasesSummary = PerfTraceSummary.fromJson(
        summary['phases'] as Map<String, Object?>,
      );
      expect(phasesSummary.phases['FlutterGpu.submit']?.count, equals(1));
      expect(
        phasesSummary.phases['FlutterGpu.gpuCompletion']?.maxUs,
        equals(850),
      );
      expect(phasesSummary.totals['staticHit'], equals(7));
      expect(
        phasesSummary.lastCounters['gpu.diagnostics']?['backingTextureCount'],
        equals(6),
      );

      // Verify .trace.json is valid Chrome Trace Event JSON with counters.
      final traceEvents = <Map<String, Object?>>[
        for (final item in jsonDecode(capturedTraceJson!) as List<Object?>)
          item as Map<String, Object?>,
      ];
      expect(traceEvents.length, equals(export!.eventCount));
      expect(
        traceEvents.any((e) => e['name'] == 'process.memory' && e['ph'] == 'C'),
        isTrue,
      );
      expect(
        traceEvents.any(
          (e) => e['name'] == 'gpu.diagnostics' && e['ph'] == 'C',
        ),
        isTrue,
      );
      expect(
        traceEvents.any(
          (e) => e['name'] == 'FlutterGpu.submit' && e['ph'] == 'B',
        ),
        isTrue,
      );
    });

    test('supports timed auto-stop and periodic telemetry sampling', () async {
      var rssSamples = 0;
      final rssValues = <int>[
        50 * 1024 * 1024,
        80 * 1024 * 1024,
        65 * 1024 * 1024,
      ];
      final autoStopCompleter = Completer<TraceExportResult?>();
      var unregistered = false;

      final recorder = FtermTraceRecorder(
        sampleRssBytes: () {
          final idx = rssSamples < rssValues.length
              ? rssSamples
              : rssValues.length - 1;
          rssSamples++;
          return rssValues[idx];
        },
        readDiagnostics: () => const ShaderBackendDiagnostics(
          backingTextureCount: 3,
          inFlightFrames: 1,
        ),
        exporter:
            ({
              required basePath,
              required traceJson,
              required summaryJson,
              required eventCount,
            }) async => TraceExportResult(
              tracePath: '$basePath.trace.json',
              summaryPath: '$basePath.summary.json',
              eventCount: eventCount,
            ),
        registerTimingsCallback: (_) {},
        unregisterTimingsCallback: (_) => unregistered = true,
        sampleInterval: const Duration(milliseconds: 20),
      );
      addTearDown(recorder.dispose);

      await recorder.start(
        outputBasePath: 'timed_capture',
        duration: const Duration(milliseconds: 65),
        onAutoStop: autoStopCompleter.complete,
        mirrorToTimeline: false,
      );

      final result = await autoStopCompleter.future.timeout(
        const Duration(seconds: 2),
      );
      expect(result, isNotNull);
      expect(recorder.isRecording, isFalse);
      expect(unregistered, isTrue);
      expect(rssSamples, greaterThanOrEqualTo(3));
      expect(recorder.rssStartBytes, equals(50 * 1024 * 1024));
      expect(recorder.rssPeakBytes, equals(80 * 1024 * 1024));
      expect(recorder.rssEndBytes, equals(65 * 1024 * 1024));
    });

    test(
      'handles double-start, double-stop, and exporter failures safely',
      () async {
        var shouldThrow = false;
        var registerCount = 0;
        var unregisterCount = 0;

        final recorder = FtermTraceRecorder(
          sampleRssBytes: () => null,
          exporter:
              ({
                required basePath,
                required traceJson,
                required summaryJson,
                required eventCount,
              }) async {
                if (shouldThrow) {
                  throw StateError('disk full');
                }
                return TraceExportResult(
                  tracePath: '$basePath.trace.json',
                  summaryPath: '$basePath.summary.json',
                  eventCount: eventCount,
                );
              },
          registerTimingsCallback: (_) => registerCount++,
          unregisterTimingsCallback: (_) => unregisterCount++,
        );
        addTearDown(recorder.dispose);

        expect(await recorder.stop(), isNull);
        final originalCategories = Set<TraceCategory>.of(
          Tracer.activeCategories,
        );
        // Concurrent start calls in the same microtask window only start once.
        final results = await Future.wait<bool>(<Future<bool>>[
          recorder.start(mirrorToTimeline: false),
          recorder.start(mirrorToTimeline: false),
        ]);
        expect(results, equals(<bool>[true, false]));
        // Second start while active is a safe no-op.
        expect(await recorder.start(mirrorToTimeline: false), isFalse);
        expect(registerCount, equals(1));

        expect(await recorder.stop(), isNotNull);
        expect(Tracer.activeCategories, equals(originalCategories));
        // Second stop while idle is a safe no-op.
        expect(await recorder.stop(), isNull);
        expect(unregisterCount, equals(1));

        // Exporter failure records lastError and cleans up state.
        shouldThrow = true;
        expect(await recorder.start(mirrorToTimeline: false), isTrue);
        expect(await recorder.stop(), isNull);
        expect(recorder.isRecording, isFalse);
        expect(recorder.lastError, isA<StateError>());
        expect(unregisterCount, equals(2));
      },
    );

    test(
      'dispose while recording cleans up timers, callbacks, and global tracers',
      () async {
        var unregisterCount = 0;
        final recorder = FtermTraceRecorder(
          sampleRssBytes: () => null,
          registerTimingsCallback: (_) {},
          unregisterTimingsCallback: (_) => unregisterCount++,
        );

        expect(
          await recorder.start(
            duration: const Duration(seconds: 5),
            mirrorToTimeline: false,
          ),
          isTrue,
        );
        expect(ShaderPerfTrace.isEnabled, isTrue);
        expect(Tracer.isEnabled, isTrue);

        recorder.dispose();
        // Allow unawaited Tracer.stop() microtask to complete.
        await Future<void>.delayed(Duration.zero);

        expect(unregisterCount, equals(1));
        expect(ShaderPerfTrace.isEnabled, isFalse);
        expect(Tracer.isEnabled, isFalse);
        expect(await recorder.start(mirrorToTimeline: false), isFalse);
      },
    );
  });

  group('compare_traces', () {
    test('formats side-by-side Web vs Windows Release Markdown comparison', () {
      final webEntry = TraceComparisonEntry.fromJson(<String, Object?>{
        'environment': <String, Object?>{
          'platform': 'web',
          'buildMode': 'release',
          'backendKind': 'webGl2',
          'viewportPhysicalWidth': 1920,
          'viewportPhysicalHeight': 1080,
          'devicePixelRatio': 2.0,
          'activeShaders': <String>['crt'],
          'recordedDurationMs': 5000,
          'frameCount': 300,
          'fps': 60.0,
        },
        'memory': <String, Object?>{
          'rssStartBytes': null,
          'rssPeakBytes': null,
          'rssEndBytes': null,
          'rssDeltaBytes': null,
        },
        'gpu': <String, Object?>{
          'peakBackingTextures': 2,
          'peakInFlightFrames': 1,
          'backpressureSkips': 0,
          'lastGpuCompletionUs': 450,
        },
        'frameTimings': <String, Object?>{
          'build': <String, Object?>{
            'count': 300,
            'minUs': 500,
            'avgUs': 1200.0,
            'p50Us': 1100,
            'p95Us': 2100,
            'p99Us': 2800,
            'maxUs': 3200,
          },
          'raster': <String, Object?>{
            'count': 300,
            'minUs': 800,
            'avgUs': 2400.0,
            'p50Us': 2300,
            'p95Us': 3600,
            'p99Us': 4100,
            'maxUs': 4500,
          },
          'total': <String, Object?>{
            'count': 300,
            'minUs': 1500,
            'avgUs': 3600.0,
            'p50Us': 3400,
            'p95Us': 5700,
            'p99Us': 6900,
            'maxUs': 7700,
          },
        },
        'phases': <String, Object?>{
          'phases': <String, Object?>{
            'WebGl2.drawPass': <String, Object?>{
              'count': 300,
              'minUs': 300,
              'avgUs': 600.0,
              'p50Us': 580,
              'p95Us': 900,
              'p99Us': 1100,
              'maxUs': 1300,
            },
            'ShaderHost.paint': <String, Object?>{
              'count': 300,
              'minUs': 100,
              'avgUs': 250.0,
              'p50Us': 240,
              'p95Us': 400,
              'p99Us': 500,
              'maxUs': 600,
            },
          },
          'lastCounters': const <String, Object?>{},
          'totals': const <String, Object?>{},
        },
      }, label: 'Web Release');

      final windowsEntry = TraceComparisonEntry.fromJson(<String, Object?>{
        'environment': <String, Object?>{
          'platform': 'windows',
          'buildMode': 'release',
          'backendKind': 'flutterGpu',
          'viewportPhysicalWidth': 2560,
          'viewportPhysicalHeight': 1440,
          'devicePixelRatio': 1.25,
          'activeShaders': <String>['crt', 'bloom'],
          'recordedDurationMs': 5000,
          'frameCount': 120,
          'fps': 24.0,
        },
        'memory': <String, Object?>{
          'rssStartBytes': 150 * 1024 * 1024,
          'rssPeakBytes': 520 * 1024 * 1024,
          'rssEndBytes': 490 * 1024 * 1024,
          'rssDeltaBytes': 340 * 1024 * 1024,
        },
        'gpu': <String, Object?>{
          'peakBackingTextures': 9,
          'peakInFlightFrames': 2,
          'backpressureSkips': 14,
          'lastGpuCompletionUs': 18400,
        },
        'frameTimings': <String, Object?>{
          'build': <String, Object?>{
            'count': 120,
            'minUs': 1000,
            'avgUs': 4500.0,
            'p50Us': 4200,
            'p95Us': 9800,
            'p99Us': 12000,
            'maxUs': 15000,
          },
          'raster': <String, Object?>{
            'count': 120,
            'minUs': 8000,
            'avgUs': 21500.0,
            'p50Us': 20000,
            'p95Us': 34000,
            'p99Us': 39000,
            'maxUs': 42000,
          },
          'total': <String, Object?>{
            'count': 120,
            'minUs': 9000,
            'avgUs': 26000.0,
            'p50Us': 24200,
            'p95Us': 43800,
            'p99Us': 51000,
            'maxUs': 57000,
          },
        },
        'phases': <String, Object?>{
          'phases': <String, Object?>{
            'FlutterGpu.renderDirect': <String, Object?>{
              'count': 120,
              'minUs': 5000,
              'avgUs': 14200.0,
              'p50Us': 13800,
              'p95Us': 24500,
              'p99Us': 28000,
              'maxUs': 31000,
            },
            'ShaderHost.paint': <String, Object?>{
              'count': 120,
              'minUs': 900,
              'avgUs': 1900.0,
              'p50Us': 1800,
              'p95Us': 3200,
              'p99Us': 4000,
              'maxUs': 4500,
            },
          },
          'lastCounters': const <String, Object?>{},
          'totals': const <String, Object?>{},
        },
      }, label: 'Windows Release');

      final markdown = formatComparisonMarkdown(<TraceComparisonEntry>[
        webEntry,
        windowsEntry,
      ]);

      expect(markdown, contains('| Metric | Web Release | Windows Release |'));
      expect(
        markdown,
        contains(
          '| Environment | web / release / webGl2 | windows / release / flutterGpu |',
        ),
      );
      expect(markdown, contains('| FPS | 60.0 | 24.0 |'));
      expect(
        markdown,
        contains('| UI avg / p95 | 1.20 ms / 2.10 ms | 4.50 ms / 9.80 ms |'),
      );
      expect(
        markdown,
        contains('| GPU avg / p95 | 2.40 ms / 3.60 ms | 21.50 ms / 34.00 ms |'),
      );
      expect(markdown, contains('| RSS Start | n/a | 150.0 MiB |'));
      expect(markdown, contains('| RSS Peak | n/a | 520.0 MiB |'));
      expect(markdown, contains('| RSS End | n/a | 490.0 MiB |'));
      expect(markdown, contains('| RSS Delta | n/a | +340.0 MiB |'));
      expect(markdown, contains('| Peak Backing Textures | 2 | 9 |'));
      expect(markdown, contains('| Backpressure Skips | 0 | 14 |'));

      // Verify bottleneck phases are sorted descending by max avg latency.
      final directIdx = markdown.indexOf('`FlutterGpu.renderDirect`');
      final hostPaintIdx = markdown.indexOf('`ShaderHost.paint`');
      final webGlIdx = markdown.indexOf('`WebGl2.drawPass`');
      expect(directIdx, greaterThan(0));
      expect(hostPaintIdx, greaterThan(directIdx));
      expect(webGlIdx, greaterThan(hostPaintIdx));
    });

    test(
      'loads real exported .summary.json produced by FtermTraceRecorder',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'fterm_compare_traces_test_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final recorder = FtermTraceRecorder(
          sampleRssBytes: () => 64 * 1024 * 1024,
          readDiagnostics: () => const ShaderBackendDiagnostics(
            backingTextureCount: 3,
            inFlightFrames: 1,
            backpressureSkips: 1,
            lastGpuCompletionUs: 500,
          ),
          readMetadata: () => const TraceSessionMetadata(
            platform: 'windows',
            buildMode: 'profile',
            backendKind: 'flutterGpu',
            viewportPhysicalWidth: 1280,
            viewportPhysicalHeight: 720,
          ),
          registerTimingsCallback: (_) {},
          unregisterTimingsCallback: (_) {},
        );
        addTearDown(recorder.dispose);

        await recorder.start(
          outputBasePath: p.join(tempDir.path, 'win_profile'),
          mirrorToTimeline: false,
        );
        recorder.recordFrameTimingUs(
          buildUs: 800,
          rasterUs: 1600,
          totalUs: 2400,
        );
        ShaderPerfTrace.recordDurationUs('FlutterGpu.bgPasses', 450);
        final result = await recorder.stop();
        expect(result, isNotNull);

        final loaded = TraceComparisonEntry.fromFile(File(result!.summaryPath));
        expect(loaded.label, equals('win_profile'));
        expect(loaded.platform, equals('windows'));
        expect(loaded.peakBackingTextures, equals(3));
        expect(loaded.backpressureSkips, equals(1));
        expect(loaded.phases['FlutterGpu.bgPasses']?.avgUs, equals(450.0));

        final md = formatComparisonMarkdown(<TraceComparisonEntry>[loaded]);
        expect(md, contains('win_profile'));
        expect(md, contains('`FlutterGpu.bgPasses`'));
      },
    );
  });
}
