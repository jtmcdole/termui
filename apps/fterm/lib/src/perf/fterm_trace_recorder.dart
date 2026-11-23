import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:termui/perf/memory_sink.dart';
import 'package:termui/perf/tracer.dart';
import 'package:termui_flutter/termui_flutter.dart'
    show
        DiagnosableShaderBackend,
        PerfPhaseStats,
        PerfTraceSummary,
        ShaderBackendDiagnostics,
        ShaderPerfTrace;

import 'trace_exporter.dart';

/// Function signature for exporting a completed trace bundle.
typedef TraceBundleExporter = Future<TraceExportResult> Function({
  required String basePath,
  required String traceJson,
  required String summaryJson,
  required int eventCount,
});

/// Callback invoked when a timed trace session finishes automatically.
typedef TraceAutoStopCallback = FutureOr<void> Function(
  TraceExportResult? result,
);

/// Immutable environment metadata captured for a recorded trace session.
final class TraceSessionMetadata {
  /// Target platform label (e.g. `windows`, `macos`, `linux`, `web`).
  final String platform;

  /// Flutter compilation mode (`debug`, `profile`, or `release`).
  final String buildMode;

  /// Active GPU shader backend identifier (`flutterGpu`, `webGl2`, `disabled`).
  final String backendKind;

  /// Active viewport physical width in device pixels.
  final int viewportPhysicalWidth;

  /// Active viewport physical height in device pixels.
  final int viewportPhysicalHeight;

  /// Active device pixel ratio (`physical / logical`).
  final double devicePixelRatio;

  /// Ordered identifiers of active background, foreground, and region shaders.
  final List<String> activeShaders;

  /// Optional GPU adapter / renderer description active during this session.
  final String? gpuAdapter;

  /// Creates immutable environment metadata for a trace summary.
  const TraceSessionMetadata({
    required this.platform,
    required this.buildMode,
    this.backendKind = 'unknown',
    this.viewportPhysicalWidth = 0,
    this.viewportPhysicalHeight = 0,
    this.devicePixelRatio = 1.0,
    this.activeShaders = const <String>[],
    this.gpuAdapter,
  });

  /// Captures default platform, build mode, and viewport metrics from Flutter.
  factory TraceSessionMetadata.fromPlatform({
    String backendKind = 'unknown',
    List<String> activeShaders = const <String>[],
    String? gpuAdapter,
  }) {
    final view = _primaryFlutterView();
    final physicalSize = view?.physicalSize ?? ui.Size.zero;
    final dpr = view?.devicePixelRatio ?? 1.0;
    return TraceSessionMetadata(
      platform: kIsWeb ? 'web' : defaultTargetPlatform.name,
      buildMode: _currentBuildMode(),
      backendKind: backendKind,
      viewportPhysicalWidth: physicalSize.width.round(),
      viewportPhysicalHeight: physicalSize.height.round(),
      devicePixelRatio: dpr,
      activeShaders: List<String>.unmodifiable(activeShaders),
      gpuAdapter: gpuAdapter,
    );
  }

  static ui.FlutterView? _primaryFlutterView() {
    try {
      final views = ui.PlatformDispatcher.instance.views;
      return views.isEmpty ? null : views.first;
    } on Object {
      return null;
    }
  }

  static String _currentBuildMode() {
    if (kReleaseMode) return 'release';
    if (kProfileMode) return 'profile';
    return 'debug';
  }
}

/// Cross-platform performance trace recorder for `fterm`.
///
/// Orchestrates `Tracer` (`MemoryTracerSink`), [ShaderPerfTrace], Flutter
/// [ui.FrameTiming] callbacks, and periodic RSS + [DiagnosableShaderBackend]
/// sampling, exporting paired `.trace.json` and `.summary.json` files on stop.
final class FtermTraceRecorder extends ChangeNotifier {
  static const JsonEncoder _prettyJson = JsonEncoder.withIndent('  ');
  static final int _frameTimingCounterId = Tracer.registerString(
    'frame.timing',
  );

  final int? Function() _sampleRssBytes;
  final ShaderBackendDiagnostics? Function()? _readDiagnostics;
  final TraceSessionMetadata Function() _readMetadata;
  final TraceBundleExporter _exporter;
  final void Function(ui.TimingsCallback callback) _registerTimingsCallback;
  final void Function(ui.TimingsCallback callback) _unregisterTimingsCallback;

  /// Interval between periodic RSS and GPU diagnostics telemetry samples.
  final Duration sampleInterval;

  /// Maximum number of Chrome Trace events buffered in memory per session.
  final int maxTraceEvents;

  /// Maximum number of frame timing samples retained for percentile summaries.
  final int maxFrameSamples;

  final Stopwatch _sessionStopwatch = Stopwatch();
  final List<int> _buildUsSamples = <int>[];
  final List<int> _rasterUsSamples = <int>[];
  final List<int> _totalUsSamples = <int>[];
  late final ui.TimingsCallback _timingsCallback = _onFrameTimings;

  MemoryTracerSink? _activeSink;
  Timer? _sampleTimer;
  Timer? _autoStopTimer;
  String? _outputBasePath;

  bool _isRecording = false;
  bool _isStarting = false;
  bool _isStopping = false;
  bool _timingsRegistered = false;
  bool _disposed = false;
  Set<TraceCategory>? _previousTracerCategories;

  int _recordedFrameCount = 0;
  int? _firstFrameVsyncUs;
  int? _lastFrameVsyncUs;

  int? _rssStartBytes;
  int? _rssPeakBytes;
  int? _rssEndBytes;

  int _peakBackingTextures = 0;
  int _peakInFlightFrames = 0;
  int _backpressureSkips = 0;
  int _lastGpuCompletionUs = 0;

  TraceExportResult? _lastExport;
  Object? _lastError;

  /// Creates a trace recorder with optional injectable seams for unit tests.
  FtermTraceRecorder({
    int? Function()? sampleRssBytes,
    ShaderBackendDiagnostics? Function()? readDiagnostics,
    DiagnosableShaderBackend? diagnosableBackend,
    TraceSessionMetadata Function()? readMetadata,
    TraceBundleExporter? exporter,
    void Function(ui.TimingsCallback callback)? registerTimingsCallback,
    void Function(ui.TimingsCallback callback)? unregisterTimingsCallback,
    this.sampleInterval = const Duration(milliseconds: 250),
    this.maxTraceEvents = 250000,
    this.maxFrameSamples = 20000,
  }) : _sampleRssBytes = sampleRssBytes ?? sampleProcessRssBytes,
       _readDiagnostics =
           readDiagnostics ?? diagnosableBackend?.readDiagnostics,
       _readMetadata = readMetadata ?? TraceSessionMetadata.fromPlatform,
       _exporter = exporter ?? exportTraceBundle,
       _registerTimingsCallback =
           registerTimingsCallback ?? _defaultRegisterTimingsCallback,
       _unregisterTimingsCallback =
           unregisterTimingsCallback ?? _defaultUnregisterTimingsCallback;

  /// Whether a recording session is currently active.
  bool get isRecording => _isRecording;

  /// Export result produced by the most recent completed session, if any.
  TraceExportResult? get lastExport => _lastExport;

  /// Last error encountered while exporting or auto-stopping a trace session.
  Object? get lastError => _lastError;

  /// Total number of Flutter frame timings captured in the active or latest
  /// session.
  int get recordedFrameCount => _recordedFrameCount;

  /// Process RSS in bytes sampled at session start (`null` if unavailable).
  int? get rssStartBytes => _rssStartBytes;

  /// Peak process RSS in bytes observed during the session (`null` if
  /// unavailable).
  int? get rssPeakBytes => _rssPeakBytes;

  /// Most recent process RSS in bytes observed during the session (`null` if
  /// unavailable).
  int? get rssEndBytes => _rssEndBytes;

  /// Peak GPU backing texture count observed via diagnostics sampling.
  int get peakBackingTextures => _peakBackingTextures;

  /// Peak in-flight GPU frame count observed via diagnostics sampling.
  int get peakInFlightFrames => _peakInFlightFrames;

  /// High-water cumulative GPU backpressure skip count observed during recording.
  int get backpressureSkips => _backpressureSkips;

  /// Starts a new trace recording session.
  ///
  /// Returns `false` if already recording, stopping, or disposed. When
  /// [duration] is provided, stops automatically after [duration] elapses and
  /// invokes [onAutoStop] with the resulting [TraceExportResult].
  Future<bool> start({
    String? outputBasePath,
    Duration? duration,
    TraceAutoStopCallback? onAutoStop,
    bool mirrorToTimeline = true,
  }) async {
    if (_disposed || _isRecording || _isStarting || _isStopping) return false;
    _isStarting = true;
    try {
      _resetSessionState();
      _outputBasePath = outputBasePath;
      _lastError = null;

      if (Tracer.isEnabled) {
        await Tracer.stop();
      }
      _previousTracerCategories = Set<TraceCategory>.of(
        Tracer.activeCategories,
      );
      Tracer.activeCategories = <TraceCategory>{
        ...Tracer.activeCategories,
        TraceCategory.gpu,
        TraceCategory.paint,
      };

      MemoryTracerSink? createdSink;
      await Tracer.startWithSink((baseEpochUs) {
        createdSink = MemoryTracerSink(
          baseEpochUs: baseEpochUs,
          maxEvents: maxTraceEvents,
        );
        return createdSink!;
      });
      if (_disposed) {
        if (Tracer.isEnabled) {
          await Tracer.stop();
        }
        _restoreTracerCategories();
        return false;
      }

      _activeSink = createdSink;
      ShaderPerfTrace.start(mirrorToTimeline: mirrorToTimeline);
      _registerTimingsCallback(_timingsCallback);
      _timingsRegistered = true;

      _sessionStopwatch
        ..reset()
        ..start();
      _isRecording = true;

      _sampleTelemetryNow();
      _sampleTimer = Timer.periodic(sampleInterval, (_) {
        if (_isRecording) {
          _sampleTelemetryNow();
        }
      });
      if (duration != null) {
        final effectiveDelay = duration.isNegative ? Duration.zero : duration;
        _autoStopTimer = Timer(effectiveDelay, () {
          unawaited(_handleAutoStop(onAutoStop));
        });
      }

      _notifyListenersSafely();
      return true;
    } finally {
      _isStarting = false;
    }
  }

  /// Records a Flutter [ui.FrameTiming] callback entry into the active session.
  void recordFrameTiming(ui.FrameTiming timing) {
    if (!_isRecording) return;
    recordFrameTimingUs(
      buildUs: timing.buildDuration.inMicroseconds,
      rasterUs: timing.rasterDuration.inMicroseconds,
      totalUs: timing.totalSpan.inMicroseconds,
      vsyncTimestampUs: timing.timestampInMicroseconds(
        ui.FramePhase.vsyncStart,
      ),
    );
  }

  /// Records a deterministic microsecond frame timing sample into the active
  /// session.
  void recordFrameTimingUs({
    required int buildUs,
    required int rasterUs,
    required int totalUs,
    int? vsyncTimestampUs,
  }) {
    if (!_isRecording) return;
    final safeBuildUs = math.max(0, buildUs);
    final safeRasterUs = math.max(0, rasterUs);
    final safeTotalUs = math.max(0, totalUs);

    _recordedFrameCount++;
    if (_buildUsSamples.length < maxFrameSamples) {
      _buildUsSamples.add(safeBuildUs);
      _rasterUsSamples.add(safeRasterUs);
      _totalUsSamples.add(safeTotalUs);
    }
    if (vsyncTimestampUs != null) {
      _firstFrameVsyncUs ??= vsyncTimestampUs;
      _lastFrameVsyncUs = vsyncTimestampUs;
    }
    if (Tracer.isEnabled) {
      Tracer.recordCounter(
        _frameTimingCounterId,
        TraceCategory.paint,
        <String, num>{
          'buildUs': safeBuildUs,
          'rasterUs': safeRasterUs,
          'totalUs': safeTotalUs,
        },
      );
    }
  }

  /// Stops the active recording session, flushes buffers, and exports both
  /// `.trace.json` and `.summary.json`.
  ///
  /// Returns `null` if no recording is active or if exporting fails (in which
  /// case [lastError] holds the failure).
  Future<TraceExportResult?> stop() async {
    if (!_isRecording || _isStopping) return null;

    _isStopping = true;
    _isRecording = false;
    _cancelTimers();
    _unregisterTimingsIfNeeded();

    try {
      _sampleTelemetryNow();
      _sessionStopwatch.stop();

      final shaderSummary = ShaderPerfTrace.stop();
      await Tracer.stop();

      final sink = _activeSink;
      _activeSink = null;
      final traceJson = sink?.toTraceJson() ?? '[]\n';
      final eventCount = sink?.eventCount ?? 0;

      final summaryPayload = _buildSummaryMap(shaderSummary);
      final summaryJson = '${_prettyJson.convert(summaryPayload)}\n';
      final basePath = _resolveOutputBasePath();

      final result = await _exporter(
        basePath: basePath,
        traceJson: traceJson,
        summaryJson: summaryJson,
        eventCount: eventCount,
      );
      _lastExport = result;
      _lastError = null;
      return result;
    } on Object catch (error) {
      _lastError = error;
      return null;
    } finally {
      _restoreTracerCategories();
      _isStopping = false;
      _notifyListenersSafely();
    }
  }

  void _restoreTracerCategories() {
    final previous = _previousTracerCategories;
    if (previous == null) return;
    _previousTracerCategories = null;
    Tracer.activeCategories = previous;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelTimers();
    _unregisterTimingsIfNeeded();
    if (_isRecording) {
      _isRecording = false;
      _sessionStopwatch.stop();
      if (ShaderPerfTrace.isEnabled) {
        ShaderPerfTrace.stop();
      }
      if (Tracer.isEnabled) {
        unawaited(Tracer.stop());
      }
      _activeSink = null;
    }
    _restoreTracerCategories();
    super.dispose();
  }

  void _onFrameTimings(List<ui.FrameTiming> timings) {
    if (!_isRecording || timings.isEmpty) return;
    for (final timing in timings) {
      recordFrameTiming(timing);
    }
  }

  Future<void> _handleAutoStop(TraceAutoStopCallback? onAutoStop) async {
    if (_disposed || !_isRecording) return;
    final result = await stop();
    if (_disposed || onAutoStop == null) return;
    try {
      await onAutoStop(result);
    } on Object catch (error) {
      _lastError = error;
      _notifyListenersSafely();
    }
  }

  void _sampleTelemetryNow() {
    _sampleMemoryTelemetry();
    _sampleDiagnosticsTelemetry();
  }

  void _sampleMemoryTelemetry() {
    final rss = _sampleRssBytes();
    if (rss == null) return;
    _rssStartBytes ??= rss;
    _rssPeakBytes = _rssPeakBytes == null ? rss : math.max(_rssPeakBytes!, rss);
    _rssEndBytes = rss;
    ShaderPerfTrace.recordCounter('process.memory', <String, num>{
      'rssBytes': rss,
    });
  }

  void _sampleDiagnosticsTelemetry() {
    final reader = _readDiagnostics;
    if (reader == null) return;
    final diag = reader();
    if (diag == null) return;

    _peakBackingTextures = math.max(
      _peakBackingTextures,
      diag.backingTextureCount,
    );
    _peakInFlightFrames = math.max(_peakInFlightFrames, diag.inFlightFrames);
    _backpressureSkips = math.max(_backpressureSkips, diag.backpressureSkips);
    if (diag.lastGpuCompletionUs > 0) {
      _lastGpuCompletionUs = diag.lastGpuCompletionUs;
    }

    ShaderPerfTrace.recordCounter('gpu.diagnostics', <String, num>{
      'inFlightFrames': diag.inFlightFrames,
      'maxFramesInFlight': diag.maxFramesInFlight,
      'backpressureSkips': diag.backpressureSkips,
      'backingTextureCount': diag.backingTextureCount,
      'surfaceCount': diag.surfaceCount,
      'staticCacheHits': diag.staticCacheHits,
      'staticCacheMisses': diag.staticCacheMisses,
      'lastGpuCompletionUs': diag.lastGpuCompletionUs,
    });
  }

  Map<String, Object?> _buildSummaryMap(PerfTraceSummary shaderSummary) {
    final metadata = _readMetadata();
    final buildStats = PerfPhaseStats.fromSamples(_buildUsSamples);
    final rasterStats = PerfPhaseStats.fromSamples(_rasterUsSamples);
    final totalStats = PerfPhaseStats.fromSamples(_totalUsSamples);
    final recordedDurationMs = _sessionStopwatch.elapsedMilliseconds;
    final fps = _computeFps(
      elapsedUs: _sessionStopwatch.elapsedMicroseconds,
      avgTotalUs: totalStats.avgUs,
    );
    final rssDeltaBytes = (_rssStartBytes != null && _rssEndBytes != null)
        ? _rssEndBytes! - _rssStartBytes!
        : null;

    return <String, Object?>{
      'environment': <String, Object?>{
        'platform': metadata.platform,
        'buildMode': metadata.buildMode,
        'backendKind': metadata.backendKind,
        'gpuAdapter': ?metadata.gpuAdapter,
        'viewportPhysicalWidth': metadata.viewportPhysicalWidth,
        'viewportPhysicalHeight': metadata.viewportPhysicalHeight,
        'devicePixelRatio': metadata.devicePixelRatio,
        'activeShaders': metadata.activeShaders,
        'recordedDurationMs': recordedDurationMs,
        'frameCount': _recordedFrameCount,
        'fps': fps,
      },
      'memory': <String, Object?>{
        'rssStartBytes': _rssStartBytes,
        'rssPeakBytes': _rssPeakBytes,
        'rssEndBytes': _rssEndBytes,
        'rssDeltaBytes': rssDeltaBytes,
      },
      'gpu': <String, Object?>{
        'peakBackingTextures': _peakBackingTextures,
        'peakInFlightFrames': _peakInFlightFrames,
        'backpressureSkips': _backpressureSkips,
        'lastGpuCompletionUs': _lastGpuCompletionUs,
      },
      'frameTimings': <String, Object?>{
        'build': buildStats.toJson(),
        'raster': rasterStats.toJson(),
        'total': totalStats.toJson(),
      },
      'phases': shaderSummary.toJson(),
    };
  }

  double _computeFps({required int elapsedUs, required double avgTotalUs}) {
    if (_recordedFrameCount == 0) return 0.0;
    final rawFps = _estimateRawFps(
      elapsedUs: elapsedUs,
      avgTotalUs: avgTotalUs,
    );
    return double.parse(rawFps.clamp(0.0, 999.0).toStringAsFixed(1));
  }

  double _estimateRawFps({required int elapsedUs, required double avgTotalUs}) {
    final firstVsync = _firstFrameVsyncUs;
    final lastVsync = _lastFrameVsyncUs;
    if (_recordedFrameCount >= 2 &&
        firstVsync != null &&
        lastVsync != null &&
        lastVsync > firstVsync) {
      return (_recordedFrameCount - 1) * 1e6 / (lastVsync - firstVsync);
    }
    if (elapsedUs >= 100000) {
      return _recordedFrameCount * 1e6 / elapsedUs;
    }
    if (avgTotalUs > 0.0) {
      return 1e6 / avgTotalUs;
    }
    return elapsedUs > 0 ? _recordedFrameCount * 1e6 / elapsedUs : 0.0;
  }

  String _resolveOutputBasePath() {
    final configured = _outputBasePath?.trim();
    if (configured != null && configured.isNotEmpty) {
      return configured;
    }
    return defaultTraceOutputBase();
  }

  void _resetSessionState() {
    _buildUsSamples.clear();
    _rasterUsSamples.clear();
    _totalUsSamples.clear();
    _recordedFrameCount = 0;
    _firstFrameVsyncUs = null;
    _lastFrameVsyncUs = null;
    _rssStartBytes = null;
    _rssPeakBytes = null;
    _rssEndBytes = null;
    _peakBackingTextures = 0;
    _peakInFlightFrames = 0;
    _backpressureSkips = 0;
    _lastGpuCompletionUs = 0;
  }

  void _cancelTimers() {
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _autoStopTimer?.cancel();
    _autoStopTimer = null;
  }

  void _unregisterTimingsIfNeeded() {
    if (!_timingsRegistered) return;
    _timingsRegistered = false;
    _unregisterTimingsCallback(_timingsCallback);
  }

  void _notifyListenersSafely() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  static void _defaultRegisterTimingsCallback(ui.TimingsCallback callback) {
    SchedulerBinding.instance.addTimingsCallback(callback);
  }

  static void _defaultUnregisterTimingsCallback(ui.TimingsCallback callback) {
    SchedulerBinding.instance.removeTimingsCallback(callback);
  }
}
