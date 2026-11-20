import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:termui_flutter/termui_flutter.dart' show ShaderBackendKind;

import '../workspace/fterm_workspace_controller.dart';

/// Immutable snapshot of recent Flutter frame-timing metrics displayed in
/// [FtermPerfHud].
final class PerfHudMetrics {
  /// Empty initial snapshot before any [ui.FrameTiming] samples arrive.
  static const PerfHudMetrics empty = PerfHudMetrics(
    fps: 0.0,
    avgBuildMs: 0.0,
    p95BuildMs: 0.0,
    avgRasterMs: 0.0,
    p95RasterMs: 0.0,
    avgTotalMs: 0.0,
    p95TotalMs: 0.0,
    sampleCount: 0,
  );

  /// Estimated rendered frames per second over the active rolling window.
  final double fps;

  /// Mean UI thread build duration in milliseconds.
  final double avgBuildMs;

  /// 95th-percentile UI thread build duration in milliseconds.
  final double p95BuildMs;

  /// Mean raster/GPU thread duration in milliseconds.
  final double avgRasterMs;

  /// 95th-percentile raster/GPU thread duration in milliseconds.
  final double p95RasterMs;

  /// Mean total frame span in milliseconds.
  final double avgTotalMs;

  /// 95th-percentile total frame span in milliseconds.
  final double p95TotalMs;

  /// Number of frame samples included in this snapshot.
  final int sampleCount;

  /// Creates an immutable frame-timing snapshot.
  const PerfHudMetrics({
    required this.fps,
    required this.avgBuildMs,
    required this.p95BuildMs,
    required this.avgRasterMs,
    required this.p95RasterMs,
    required this.avgTotalMs,
    required this.p95TotalMs,
    required this.sampleCount,
  });
}

/// Rolling-window accumulator computing FPS and avg/p95 UI & GPU frame times
/// from Flutter [ui.FrameTiming] callbacks.
final class PerfHudTracker {
  /// Maximum number of recent frame samples retained in memory.
  final int maxSamples;

  final ListQueue<_FrameSample> _samples = ListQueue<_FrameSample>();

  /// Creates a frame-timing tracker retaining at most [maxSamples] frames.
  PerfHudTracker({this.maxSamples = 60});

  /// Number of frame samples currently stored in the rolling window.
  int get sampleCount => _samples.length;

  /// Records a batch of [timings] delivered by `SchedulerBinding`.
  void recordTimings(List<ui.FrameTiming> timings) {
    for (final timing in timings) {
      recordRawSample(
        vsyncTimestampUs: timing.timestampInMicroseconds(
          ui.FramePhase.vsyncStart,
        ),
        buildUs: timing.buildDuration.inMicroseconds,
        rasterUs: timing.rasterDuration.inMicroseconds,
        totalUs: timing.totalSpan.inMicroseconds,
      );
    }
  }

  /// Records a single microsecond frame sample (also used directly in unit
  /// tests).
  void recordRawSample({
    required int vsyncTimestampUs,
    required int buildUs,
    required int rasterUs,
    required int totalUs,
  }) {
    if (_samples.length >= maxSamples && _samples.isNotEmpty) {
      _samples.removeFirst();
    }
    _samples.addLast(
      _FrameSample(
        vsyncTimestampUs: vsyncTimestampUs,
        buildMs: math.max(0, buildUs) / 1000.0,
        rasterMs: math.max(0, rasterUs) / 1000.0,
        totalMs: math.max(0, totalUs) / 1000.0,
      ),
    );
  }

  /// Clears all retained frame samples.
  void clear() => _samples.clear();

  /// Computes aggregate FPS and avg/p95 build, raster, and total durations.
  PerfHudMetrics computeMetrics() {
    final count = _samples.length;
    if (count == 0) return PerfHudMetrics.empty;

    final builds = <double>[];
    final rasters = <double>[];
    final totals = <double>[];
    var buildSum = 0.0;
    var rasterSum = 0.0;
    var totalSum = 0.0;

    for (final sample in _samples) {
      builds.add(sample.buildMs);
      rasters.add(sample.rasterMs);
      totals.add(sample.totalMs);
      buildSum += sample.buildMs;
      rasterSum += sample.rasterMs;
      totalSum += sample.totalMs;
    }

    final avgTotal = totalSum / count;
    return PerfHudMetrics(
      fps: _estimateFps(avgTotal),
      avgBuildMs: buildSum / count,
      p95BuildMs: _percentile95(builds),
      avgRasterMs: rasterSum / count,
      p95RasterMs: _percentile95(rasters),
      avgTotalMs: avgTotal,
      p95TotalMs: _percentile95(totals),
      sampleCount: count,
    );
  }

  double _estimateFps(double avgTotalMs) {
    if (_samples.length >= 2) {
      final spanUs =
          _samples.last.vsyncTimestampUs - _samples.first.vsyncTimestampUs;
      if (spanUs > 0) {
        return ((_samples.length - 1) * 1e6 / spanUs).clamp(0.0, 999.0);
      }
    }
    if (avgTotalMs <= 0.0) return 0.0;
    return (1000.0 / avgTotalMs).clamp(0.0, 999.0);
  }

  static double _percentile95(List<double> values) {
    if (values.isEmpty) return 0.0;
    values.sort();
    final idx = ((values.length - 1) * 0.95).ceil().clamp(0, values.length - 1);
    return values[idx];
  }
}

final class _FrameSample {
  final int vsyncTimestampUs;
  final double buildMs;
  final double rasterMs;
  final double totalMs;

  const _FrameSample({
    required this.vsyncTimestampUs,
    required this.buildMs,
    required this.rasterMs,
    required this.totalMs,
  });
}

/// Lightweight, non-interactive in-app FPS and frame-timing HUD overlay.
///
/// Only mounts when [FtermWorkspaceController.showPerfHud] is enabled so there
/// is zero `FrameTiming` callback or repaint overhead while hidden.
final class FtermPerfHud extends StatefulWidget {
  /// Workspace inspected for active shader backend and pass count.
  final FtermWorkspaceController workspace;

  /// Minimum interval between HUD text refreshes so the HUD itself does not
  /// induce high-frequency repaints.
  final Duration refreshInterval;

  /// Optional external tracker injected by unit/widget tests.
  final PerfHudTracker? tracker;

  /// Creates an in-app performance HUD widget.
  const FtermPerfHud({
    super.key,
    required this.workspace,
    this.refreshInterval = const Duration(milliseconds: 250),
    this.tracker,
  });

  @override
  State<FtermPerfHud> createState() => _FtermPerfHudState();
}

final class _FtermPerfHudState extends State<FtermPerfHud> {
  late final PerfHudTracker _tracker = widget.tracker ?? PerfHudTracker();
  final ValueNotifier<PerfHudMetrics> _metricsNotifier =
      ValueNotifier<PerfHudMetrics>(PerfHudMetrics.empty);
  DateTime? _lastPublishTime;

  @override
  void initState() {
    super.initState();
    if (_tracker.sampleCount > 0) {
      _metricsNotifier.value = _tracker.computeMetrics();
    }
    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    _metricsNotifier.dispose();
    super.dispose();
  }

  void _onFrameTimings(List<ui.FrameTiming> timings) {
    if (!mounted || timings.isEmpty) return;
    _tracker.recordTimings(timings);
    final now = clock.now();
    final last = _lastPublishTime;
    if (last != null && now.difference(last) < widget.refreshInterval) {
      return;
    }
    _lastPublishTime = now;
    _metricsNotifier.value = _tracker.computeMetrics();
  }

  static Color _statusColor(PerfHudMetrics metrics) {
    if (metrics.sampleCount == 0) return const Color(0xFF9EA7B3);
    if (metrics.fps >= 55.0 && metrics.p95TotalMs <= 20.0) {
      return const Color(0xFF3FB950);
    }
    if (metrics.fps >= 30.0 && metrics.p95TotalMs <= 36.0) {
      return const Color(0xFFD29922);
    }
    return const Color(0xFFF85149);
  }

  int _activeShaderCount() {
    final cfg = widget.workspace.activeShaderConfig;
    if (!cfg.enabled) return 0;
    return cfg.backgroundPasses.length + cfg.foregroundPasses.length;
  }

  @override
  Widget build(BuildContext context) {
    final backendKind = widget.workspace.shaderController.backendKind;
    final shaderCount = _activeShaderCount();
    final backendLabel = switch (backendKind) {
      ShaderBackendKind.flutterGpu => 'flutterGpu',
      ShaderBackendKind.webGl2 => 'webGl2',
      ShaderBackendKind.disabled => 'disabled',
    };
    final shaderSuffix = shaderCount == 1 ? 'shader' : 'shaders';

    return IgnorePointer(
      child: RepaintBoundary(
        child: ValueListenableBuilder<PerfHudMetrics>(
          valueListenable: _metricsNotifier,
          builder: (_, metrics, _) {
            final accent = _statusColor(metrics);
            final fpsText = metrics.sampleCount == 0
                ? '--.- FPS'
                : '${metrics.fps.toStringAsFixed(1)} FPS';
            final uiText =
                'UI  ${metrics.avgBuildMs.toStringAsFixed(1)}ms '
                '(p95 ${metrics.p95BuildMs.toStringAsFixed(1)}ms)';
            final gpuText =
                'GPU ${metrics.avgRasterMs.toStringAsFixed(1)}ms '
                '(p95 ${metrics.p95RasterMs.toStringAsFixed(1)}ms)';

            return Container(
              key: const ValueKey('fterm-perf-hud'),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xCC0D1117),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: accent.withValues(alpha: 0.6)),
              ),
              child: DefaultTextStyle(
                style: const TextStyle(
                  fontFamily: 'Cascadia Mono',
                  fontSize: 11,
                  height: 1.3,
                  color: Color(0xFFE6EDF3),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          fpsText,
                          key: const ValueKey('fterm-perf-hud-fps'),
                          style: TextStyle(
                            color: accent,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '$backendLabel • $shaderCount $shaderSuffix',
                          style: const TextStyle(
                            color: Color(0xFF9EA7B3),
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(uiText, key: const ValueKey('fterm-perf-hud-ui')),
                    Text(gpuText, key: const ValueKey('fterm-perf-hud-gpu')),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
