import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:termui_flutter/termui_flutter.dart'
    show ShaderBackendDiagnostics, ShaderBackendKind;

import '../perf/fterm_trace_recorder.dart';
import '../perf/trace_exporter.dart';
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

/// Lightweight, mostly click-through in-app FPS and frame-timing HUD overlay
/// with an interactive `[REC]` / `[STOP]` trace toggle button.
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

  /// Optional RSS sampler override for unit/widget tests.
  final int? Function()? sampleRssBytes;

  /// Creates an in-app performance HUD widget.
  const FtermPerfHud({
    super.key,
    required this.workspace,
    this.refreshInterval = const Duration(milliseconds: 250),
    this.tracker,
    this.sampleRssBytes,
  });

  @override
  State<FtermPerfHud> createState() => _FtermPerfHudState();
}

final class _FtermPerfHudState extends State<FtermPerfHud> {
  late final PerfHudTracker _tracker = widget.tracker ?? PerfHudTracker();
  final ValueNotifier<PerfHudMetrics> _metricsNotifier =
      ValueNotifier<PerfHudMetrics>(PerfHudMetrics.empty);
  late Listenable _hudListenable;
  DateTime? _lastPublishTime;

  @override
  void initState() {
    super.initState();
    _hudListenable = Listenable.merge(<Listenable>[
      _metricsNotifier,
      widget.workspace.chromeNotifier,
    ]);
    if (_tracker.sampleCount > 0) {
      _metricsNotifier.value = _tracker.computeMetrics();
    }
    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
  }

  @override
  void didUpdateWidget(FtermPerfHud oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.workspace, widget.workspace)) {
      _hudListenable = Listenable.merge(<Listenable>[
        _metricsNotifier,
        widget.workspace.chromeNotifier,
      ]);
    }
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
    final fullPaneCount = cfg.enabled
        ? cfg.backgroundPasses.length + cfg.foregroundPasses.length
        : 0;
    final focusedRegions =
        widget.workspace.focusedPane?.displayBuffer.shaderRegions.length ?? 0;
    return fullPaneCount + focusedRegions;
  }

  String? _buildDiagnosticsLine(ShaderBackendDiagnostics? diag) {
    final int? rssBytes = (widget.sampleRssBytes ?? sampleProcessRssBytes)();
    final parts = <String>[
      if (diag != null) ...[
        'in-flight ${diag.inFlightFrames}/${diag.maxFramesInFlight}',
        'tex ${diag.backingTextureCount}',
        'skip ${diag.backpressureSkips}',
      ],
      if (rssBytes != null && rssBytes > 0)
        'RSS ${(rssBytes / (1024 * 1024)).toStringAsFixed(0)} MB',
    ];
    return parts.isEmpty ? null : parts.join(' • ');
  }

  ({String text, bool hasActiveCap}) _buildGpuAndCapInfo(
    ShaderBackendDiagnostics? diag,
  ) {
    final ws = widget.workspace;
    final gpuName = ws.activeGpuAdapterName ?? diag?.gpuRenderer;
    final vramLabel = _formatVram(ws.activeGpuVramMb);
    final cap = _resolveFpsCapHint(ws);
    final parts = <String>[
      if (gpuName != null)
        vramLabel != null ? '$gpuName ($vramLabel)' : gpuName,
      if (ws.gpuDriverRestartRequired) 'restart pending',
      cap.label,
    ];
    return (text: parts.join(' • '), hasActiveCap: cap.isCapped);
  }

  static String? _formatVram(int? vramMb) {
    if (vramMb == null || vramMb <= 0) return null;
    if (vramMb >= 1024) {
      final gb = vramMb / 1024.0;
      return '${gb.toStringAsFixed(gb >= 10 ? 0 : 1)} GB';
    }
    return '$vramMb MB';
  }

  static ({String label, bool isCapped}) _resolveFpsCapHint(
    FtermWorkspaceController ws,
  ) {
    final userCap = ws.maxShaderFps;
    final watchdogCap = ws.focusedPane?.gpuFrameWatchdog.throttledPresetMaxFps
        ?.round();
    if (watchdogCap != null &&
        watchdogCap > 0 &&
        (userCap == null || watchdogCap <= userCap)) {
      return (label: 'cap $watchdogCap FPS (watchdog)', isCapped: true);
    }
    if (userCap != null && userCap > 0) {
      return (label: 'cap $userCap FPS', isCapped: true);
    }
    return (label: 'uncapped', isCapped: false);
  }

  static String? _traceStatusLabel(FtermTraceRecorder recorder) {
    if (recorder.isRecording) return 'REC ${recorder.recordedFrameCount}f';
    if (recorder.lastError != null) return 'Trace error';
    final lastExport = recorder.lastExport;
    if (lastExport == null) return null;
    return 'Saved ${lastExport.summaryPath}';
  }

  Widget _buildTraceStatusWidget({
    required String statusText,
    required Color statusColor,
    required bool hasExport,
  }) {
    if (!hasExport) {
      return IgnorePointer(
        child: Text(
          statusText,
          key: const ValueKey('fterm-perf-hud-trace-status'),
          style: TextStyle(color: statusColor, fontSize: 10),
        ),
      );
    }
    return GestureDetector(
      key: const ValueKey('fterm-perf-hud-trace-open'),
      onTap: () => unawaited(widget.workspace.revealLastTraceExport()),
      child: Text(
        statusText,
        key: const ValueKey('fterm-perf-hud-trace-status'),
        style: TextStyle(
          color: statusColor,
          fontSize: 10,
          decoration: TextDecoration.underline,
          decorationColor: statusColor,
        ),
      ),
    );
  }

  Widget _buildTraceControlsRow() => ListenableBuilder(
    listenable: widget.workspace.traceRecorder,
    builder: (_, _) {
      final recorder = widget.workspace.traceRecorder;
      final recording = recorder.isRecording;
      final hasExport = !recording && recorder.lastExport != null;
      final statusText = _traceStatusLabel(recorder);
      final statusColor = recording
          ? const Color(0xFFF85149)
          : hasExport
          ? const Color(0xFF58A6FF)
          : const Color(0xFF9EA7B3);
      final chipBg = recording
          ? const Color(0xFFDA3633)
          : const Color(0xFF21262D);
      final chipBorder = recording
          ? const Color(0xFFF85149)
          : const Color(0xFF30363D);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (statusText != null) ...[
            _buildTraceStatusWidget(
              statusText: statusText,
              statusColor: statusColor,
              hasExport: hasExport,
            ),
            const SizedBox(width: 6),
          ],
          GestureDetector(
            key: const ValueKey('fterm-perf-hud-trace-toggle'),
            onTap: () => unawaited(widget.workspace.toggleTraceRecording()),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: chipBg,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: chipBorder),
              ),
              child: Text(
                recording ? 'STOP' : 'REC',
                style: const TextStyle(
                  color: Color(0xFFE6EDF3),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final backendKind = widget.workspace.shaderController.backendKind;
    final backendLabel = switch (backendKind) {
      ShaderBackendKind.flutterGpu => 'flutterGpu',
      ShaderBackendKind.webGl2 => 'webGl2',
      ShaderBackendKind.disabled => 'disabled',
    };

    return RepaintBoundary(
      child: ListenableBuilder(
        listenable: _hudListenable,
        builder: (_, _) {
          final metrics = _metricsNotifier.value;
          final shaderCount = _activeShaderCount();
          final shaderSuffix = shaderCount == 1 ? 'shader' : 'shaders';
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
          final diag = widget.workspace.readShaderBackendDiagnostics();
          final diagLine = _buildDiagnosticsLine(diag);
          final gpuInfo = _buildGpuAndCapInfo(diag);

          return Stack(
            key: const ValueKey('fterm-perf-hud'),
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xCC0D1117),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: accent.withValues(alpha: 0.6)),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
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
                      IgnorePointer(
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
                            Text(
                              uiText,
                              key: const ValueKey('fterm-perf-hud-ui'),
                            ),
                            Text(
                              gpuText,
                              key: const ValueKey('fterm-perf-hud-gpu'),
                            ),
                            Text(
                              gpuInfo.text,
                              key: const ValueKey('fterm-perf-hud-gpu-info'),
                              style: TextStyle(
                                color: gpuInfo.hasActiveCap
                                    ? const Color(0xFFD29922)
                                    : const Color(0xFF9EA7B3),
                                fontSize: 10,
                              ),
                            ),
                            if (diagLine != null)
                              Text(
                                diagLine,
                                key: const ValueKey(
                                  'fterm-perf-hud-diagnostics',
                                ),
                                style: const TextStyle(
                                  color: Color(0xFF9EA7B3),
                                  fontSize: 10,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      _buildTraceControlsRow(),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
