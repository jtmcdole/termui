import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/scheduler.dart';

/// Callback invoked when [GpuFrameWatchdog] quarantines an offending custom CLI
/// shader ID on a terminal pane.
typedef ShaderQuarantinedCallback = void Function(
  String shaderId,
  String reason,
);

/// Built-in predicate checking whether [shaderId] is a host built-in preset
/// that must never be quarantined as a custom CLI shader.
typedef BuiltinShaderPredicate = bool Function(String shaderId);

/// Best-effort per-pane GPU frame watchdog protecting hosts from runaway or
/// hanging untrusted custom CLI GLSL shaders.
///
/// Tracks per-shader frame timings (from WebGL2 `EXT_disjoint_timer_query_webgl2`
/// or Desktop `CommandBuffer.submit(completionCallback: ...)` / Flutter
/// `FrameTiming.rasterDuration`), command-buffer completion timeouts, and
/// `webglcontextlost` events.
///
/// When tripped, quarantines **only** the offending custom CLI shader ID(s) on
/// this pane while preserving built-in presets, per-cell transforms, and the
/// active direct GPU pipeline state without oscillating between direct and
/// fallback modes.
final class GpuFrameWatchdog {
  /// Default per-frame duration threshold (`33 ms` = `< 30 FPS`).
  static const Duration defaultSlowFrameThreshold = Duration(milliseconds: 33);

  /// Default number of consecutive slow frames required to trip quarantine.
  static const int defaultConsecutiveSlowFrameLimit = 3;

  /// Default GPU command-buffer completion deadline before tripping quarantine.
  static const Duration defaultCompletionTimeout = Duration(seconds: 2);

  /// Default per-shader warmup frame count (`0` for deterministic unit tests).
  static const int defaultWarmupFrameCount = 0;

  /// Recommended per-shader warmup frame count for live interactive hosts
  /// (`24` frames in debug builds for pipeline compilation and JIT warmup,
  /// `10` frames in release/profile builds).
  static int get recommendedWarmupFrameCount => kDebugMode ? 24 : 10;

  /// Adaptive FPS ceiling applied to active built-in region presets after
  /// sustained slow frames (without quarantining built-in presets).
  static const double defaultThrottledPresetFps = 30.0;

  /// Consecutive fast frames (`<= slowFrameThreshold ~/ 2`) required before
  /// lifting adaptive preset FPS throttling.
  static const int defaultPresetRecoveryFrames = 10;

  static const Duration _recentRasterTelemetryWindow = Duration(
    milliseconds: 500,
  );

  /// Frame duration above which a frame counts as slow.
  final Duration slowFrameThreshold;

  /// Number of consecutive slow frames required before quarantining.
  final int consecutiveSlowFrameLimit;

  /// Maximum wait for a submitted GPU command buffer completion callback.
  final Duration completionTimeout;

  /// Number of initial measured frames skipped per newly activated shader to
  /// avoid false quarantine during GPU pipeline compilation or debug warmup.
  final int warmupFrameCount;

  /// Optional predicate identifying built-in host presets exempt from quarantine.
  final BuiltinShaderPredicate? isBuiltinPreset;

  /// Optional notification callback invoked once whenever a custom CLI shader
  /// ID is quarantined on this pane.
  ShaderQuarantinedCallback? onShaderQuarantined;

  final Map<String, Set<String>> _activeCustomShadersBySource =
      <String, Set<String>>{};
  final Set<String> _activeCustomShaderIds = <String>{};
  final Set<String> _quarantinedShaderIds = <String>{};
  final Map<String, int> _consecutiveSlowFrames = <String, int>{};
  final Map<String, int> _warmupFramesRemaining = <String, int>{};
  final Map<String, Duration> _lastFrameDurations = <String, Duration>{};
  final Map<int, _PendingGpuSubmission> _pendingSubmissions =
      <int, _PendingGpuSubmission>{};

  Timer? _sweepTimer;
  int _nextSubmissionToken = 1;
  bool _timingsAttached = false;
  bool _disposed = false;
  Duration? _lastRasterDuration;
  DateTime? _lastRasterAt;
  bool _hasActiveBuiltinPresets = false;
  int _presetSlowStreak = 0;
  int _presetFastStreak = 0;
  bool _presetsThrottled = false;

  /// Creates a [GpuFrameWatchdog].
  GpuFrameWatchdog({
    this.slowFrameThreshold = defaultSlowFrameThreshold,
    this.consecutiveSlowFrameLimit = defaultConsecutiveSlowFrameLimit,
    this.completionTimeout = defaultCompletionTimeout,
    int warmupFrameCount = defaultWarmupFrameCount,
    this.isBuiltinPreset,
    this.onShaderQuarantined,
  }) : warmupFrameCount = warmupFrameCount < 0 ? 0 : warmupFrameCount;

  /// Unmodifiable view of custom CLI shader IDs currently quarantined on this pane.
  Set<String> get quarantinedShaderIds =>
      Set<String>.unmodifiable(_quarantinedShaderIds);

  /// Unmodifiable view of custom CLI shader IDs currently active on this pane.
  Set<String> get activeCustomShaderIds =>
      Set<String>.unmodifiable(_activeCustomShaderIds);

  /// Whether [shaderId] has been quarantined on this pane.
  bool isQuarantined(String shaderId) =>
      _quarantinedShaderIds.contains(shaderId);

  /// Whether [shaderId] is currently tracked as an active custom CLI shader.
  bool isActiveCustomShader(String shaderId) =>
      _activeCustomShaderIds.contains(shaderId);

  /// Returns the most recently recorded GPU duration for [shaderId], if any.
  Duration? lastFrameDurationFor(String shaderId) =>
      _lastFrameDurations[shaderId];

  /// Returns the current consecutive slow-frame streak for [shaderId].
  int consecutiveSlowFramesFor(String shaderId) =>
      _consecutiveSlowFrames[shaderId] ?? 0;

  /// Returns the remaining warmup grace frames for [shaderId].
  int warmupFramesRemainingFor(String shaderId) =>
      _warmupFramesRemaining[shaderId] ?? 0;

  /// Resets the per-shader warmup grace window for [shaderId], or for all
  /// currently active custom shaders when [shaderId] is omitted.
  void resetWarmup([String? shaderId]) {
    if (_disposed || warmupFrameCount <= 0) return;
    if (shaderId == null) {
      for (final id in _activeCustomShaderIds) {
        _warmupFramesRemaining[id] = warmupFrameCount;
      }
      return;
    }
    if (_activeCustomShaderIds.contains(shaderId)) {
      _warmupFramesRemaining[shaderId] = warmupFrameCount;
    }
  }

  /// Number of in-flight GPU command submissions currently tracked for timeout.
  int get pendingSubmissionCount => _pendingSubmissions.length;

  /// Whether [handleFrameTimings] is currently attached to [SchedulerBinding].
  bool get isFrameTimingsAttached => _timingsAttached;

  /// Whether at least one built-in preset region is active on this pane.
  bool get hasActiveBuiltinPresets => _hasActiveBuiltinPresets;

  /// Adaptive ambient FPS ceiling when built-in presets sustain slow frames, or
  /// `null` when running unthrottled.
  double? get throttledPresetMaxFps =>
      _presetsThrottled ? defaultThrottledPresetFps : null;

  /// Whether this watchdog has been disposed.
  bool get isDisposed => _disposed;

  /// Updates whether built-in preset regions are currently active on this pane.
  ///
  /// When cleared (`false`), any adaptive preset FPS throttling resets cleanly.
  void setActiveBuiltinPresets(bool active) {
    if (_disposed) return;
    _hasActiveBuiltinPresets = active;
    if (!active) {
      _presetSlowStreak = 0;
      _presetFastStreak = 0;
      _presetsThrottled = false;
    }
  }

  /// Updates the set of custom shader IDs actively executing on this pane for
  /// [source] (defaulting to `'cli'`).
  ///
  /// Distinct sources (for example `'cli'` for `CliShaderRegistry` and `'host'`
  /// for `TerminalShaderHost`) are tracked independently and merged into
  /// [activeCustomShaderIds], so updates from one source never clobber another.
  /// Built-in presets (where [isBuiltinPreset] returns `true`) are ignored and
  /// never tracked or quarantined.
  void setActiveCustomShaders(
    Iterable<String> customShaderIds, {
    String source = 'cli',
  }) {
    if (_disposed) return;
    final nextForSource = <String>{
      for (final id in customShaderIds)
        if (!_isExempt(id)) id,
    };
    if (nextForSource.isEmpty) {
      _activeCustomShadersBySource.remove(source);
    } else {
      _activeCustomShadersBySource[source] = nextForSource;
    }
    _recomputeActiveCustomShaders();
  }

  void _recomputeActiveCustomShaders() {
    final union = <String>{
      for (final ids in _activeCustomShadersBySource.values) ...ids,
    };
    if (warmupFrameCount > 0) {
      for (final id in union) {
        if (!_activeCustomShaderIds.contains(id)) {
          _warmupFramesRemaining[id] = warmupFrameCount;
        }
      }
    }
    _activeCustomShaderIds
      ..clear()
      ..addAll(union);
    _consecutiveSlowFrames.removeWhere((id, _) => !union.contains(id));
    _warmupFramesRemaining.removeWhere((id, _) => !union.contains(id));
  }

  /// Attaches [handleFrameTimings] to [SchedulerBinding.instance] so Desktop
  /// Flutter raster timings feed this watchdog automatically.
  void attachFrameTimingsCallback() {
    if (_disposed || _timingsAttached) return;
    _timingsAttached = true;
    SchedulerBinding.instance.addTimingsCallback(handleFrameTimings);
  }

  /// Detaches [handleFrameTimings] from [SchedulerBinding.instance].
  void detachFrameTimingsCallback() {
    if (!_timingsAttached) return;
    _timingsAttached = false;
    SchedulerBinding.instance.removeTimingsCallback(handleFrameTimings);
  }

  /// [TimingsCallback] handler recording each frame's `rasterDuration` against
  /// active custom CLI shaders and built-in preset throttling on this pane.
  void handleFrameTimings(List<FrameTiming> timings) {
    if (_disposed || timings.isEmpty) return;
    final now = clock.now();
    for (final timing in timings) {
      final raster = timing.rasterDuration;
      _lastRasterDuration = raster;
      _lastRasterAt = now;
      if (_activeCustomShaderIds.isNotEmpty) {
        recordFrameTiming(raster);
      }
      if (_hasActiveBuiltinPresets) {
        recordPresetFrameDuration(raster);
      }
    }
  }

  /// Records a single frame [duration] for active built-in region presets.
  ///
  /// Built-in presets are never quarantined; instead, sustained slow frames
  /// (`> slowFrameThreshold` for [consecutiveSlowFrameLimit] frames) throttle
  /// [throttledPresetMaxFps] down to [defaultThrottledPresetFps] until
  /// [defaultPresetRecoveryFrames] consecutive fast frames recover.
  void recordPresetFrameDuration(Duration duration) {
    if (_disposed || !_hasActiveBuiltinPresets) return;
    if (duration > slowFrameThreshold) {
      _presetFastStreak = 0;
      _presetSlowStreak++;
      if (_presetSlowStreak >= consecutiveSlowFrameLimit) {
        _presetsThrottled = true;
      }
      return;
    }
    _presetSlowStreak = 0;
    if (!_presetsThrottled) {
      _presetFastStreak = 0;
      return;
    }
    if (duration <= slowFrameThreshold ~/ 2) {
      _presetFastStreak++;
      if (_presetFastStreak >= defaultPresetRecoveryFrames) {
        _presetsThrottled = false;
        _presetFastStreak = 0;
      }
    } else {
      _presetFastStreak = 0;
    }
  }

  /// Records a single measured GPU/raster [duration] for [shaderId].
  ///
  /// Built-in presets and non-active shaders are ignored. Trips quarantine
  /// after [consecutiveSlowFrameLimit] consecutive frames exceeding
  /// [slowFrameThreshold].
  void recordShaderFrameDuration(String shaderId, Duration duration) {
    if (_disposed ||
        _isExempt(shaderId) ||
        !_activeCustomShaderIds.contains(shaderId) ||
        _quarantinedShaderIds.contains(shaderId)) {
      return;
    }
    _lastFrameDurations[shaderId] = duration;
    final warmupRemaining = _warmupFramesRemaining[shaderId] ?? 0;
    if (warmupRemaining > 0) {
      _warmupFramesRemaining[shaderId] = warmupRemaining - 1;
      _consecutiveSlowFrames[shaderId] = 0;
      return;
    }
    if (duration <= slowFrameThreshold) {
      _consecutiveSlowFrames[shaderId] = 0;
      return;
    }
    final streak = (_consecutiveSlowFrames[shaderId] ?? 0) + 1;
    _consecutiveSlowFrames[shaderId] = streak;
    if (streak >= consecutiveSlowFrameLimit) {
      quarantineShader(
        shaderId,
        'Sustained GPU frame time exceeded '
        '${slowFrameThreshold.inMilliseconds}ms '
        '(${duration.inMilliseconds}ms for $streak consecutive frames).',
      );
    }
  }

  /// Records a frame-wide GPU [duration] against [customShaderIds] (or all
  /// currently [activeCustomShaderIds] when omitted).
  void recordFrameTiming(
    Duration duration, {
    Iterable<String>? customShaderIds,
  }) {
    if (_disposed) return;
    final targets = _resolveTargetIds(customShaderIds);
    for (final id in targets) {
      recordShaderFrameDuration(id, duration);
    }
  }

  /// Records a WebGL2 `EXT_disjoint_timer_query_webgl2` elapsed-time sample.
  ///
  /// When [disjoint] is `true`, the GPU clock discontinuity invalidates the
  /// sample and it is ignored per the WebGL2 timer-query specification.
  void recordWebGlTimerQueryResult(
    int elapsedNanoseconds, {
    Iterable<String>? customShaderIds,
    bool disjoint = false,
  }) {
    if (_disposed || disjoint || elapsedNanoseconds < 0) return;
    final duration = Duration(microseconds: elapsedNanoseconds ~/ 1000);
    recordFrameTiming(duration, customShaderIds: customShaderIds);
  }

  /// Begins tracking a GPU `CommandBuffer.submit(completionCallback: ...)`
  /// submission containing [customShaderIds] and records its completion deadline.
  ///
  /// Uses a single shared periodic sweep timer while submissions are pending
  /// instead of allocating one `Timer` per frame. Returns `0` if no active
  /// non-exempt custom shader IDs are present.
  int beginCommandSubmission(Iterable<String> customShaderIds) {
    if (_disposed) return 0;
    final targets = <String>[
      for (final id in customShaderIds)
        if (!_isExempt(id) &&
            !_quarantinedShaderIds.contains(id) &&
            _activeCustomShaderIds.contains(id))
          id,
    ];
    if (targets.isEmpty) return 0;

    final token = _nextSubmissionToken++;
    _pendingSubmissions[token] = _PendingGpuSubmission(
      shaderIds: targets,
      deadline: clock.now().add(completionTimeout),
    );
    _ensureSweepTimer();
    return token;
  }

  /// Completes a previously tracked command submission [token].
  ///
  /// If [success] is `false`, immediately quarantines the associated custom
  /// CLI shader IDs. Otherwise feeds [gpuDuration] into the sustained slow-frame
  /// detector when supplied, discounting UI-thread wall-clock stalls when recent
  /// Flutter raster telemetry confirms healthy GPU execution.
  void completeCommandSubmission(
    int token, {
    required bool success,
    Duration? gpuDuration,
  }) {
    final pending = _pendingSubmissions.remove(token);
    if (pending == null) return;
    _stopSweepTimerIfIdle();
    if (_disposed) return;

    if (!success) {
      for (final id in pending.shaderIds) {
        quarantineShader(
          id,
          'GPU command buffer completion callback reported failure.',
        );
      }
      return;
    }
    if (gpuDuration != null) {
      final effective = _resolveEffectiveCommandDuration(gpuDuration);
      recordFrameTiming(effective, customShaderIds: pending.shaderIds);
    }
  }

  /// Reports a `webglcontextlost` event on the WebGL2 `OffscreenCanvas`,
  /// immediately quarantining active custom CLI shader IDs on this pane while
  /// leaving built-in presets and transforms intact.
  void reportWebGlContextLost({Iterable<String>? customShaderIds}) {
    if (_disposed) return;
    final targets = _resolveTargetIds(customShaderIds);
    for (final id in targets) {
      quarantineShader(
        id,
        'WebGL2 context was lost while executing custom CLI shader.',
      );
    }
  }

  /// Quarantines a single custom CLI [shaderId] with a human-readable [reason].
  ///
  /// Built-in presets are exempt and ignored. Already-quarantined IDs do not
  /// re-fire [onShaderQuarantined].
  void quarantineShader(String shaderId, String reason) {
    if (_disposed || _isExempt(shaderId)) return;
    if (!_quarantinedShaderIds.add(shaderId)) return;
    _consecutiveSlowFrames.remove(shaderId);
    onShaderQuarantined?.call(shaderId, reason);
  }

  /// Lifts quarantine for [shaderId], or for all shaders when [shaderId] is `null`.
  void clearQuarantine([String? shaderId]) {
    if (shaderId == null) {
      _quarantinedShaderIds.clear();
      _consecutiveSlowFrames.clear();
      resetWarmup();
      return;
    }
    _quarantinedShaderIds.remove(shaderId);
    _consecutiveSlowFrames.remove(shaderId);
    resetWarmup(shaderId);
  }

  /// Cancels pending submission timers and clears active tracking and
  /// quarantined state (e.g. on pane reset or `ESC c` RIS).
  void reset() {
    _cancelPendingSubmissions();
    _activeCustomShadersBySource.clear();
    _activeCustomShaderIds.clear();
    _quarantinedShaderIds.clear();
    _consecutiveSlowFrames.clear();
    _warmupFramesRemaining.clear();
    _lastFrameDurations.clear();
    _lastRasterDuration = null;
    _lastRasterAt = null;
    _hasActiveBuiltinPresets = false;
    _presetSlowStreak = 0;
    _presetFastStreak = 0;
    _presetsThrottled = false;
  }

  /// Detaches frame timings and cancels all pending timers permanently.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    detachFrameTimingsCallback();
    _cancelPendingSubmissions();
    _activeCustomShadersBySource.clear();
    _activeCustomShaderIds.clear();
    _consecutiveSlowFrames.clear();
    _warmupFramesRemaining.clear();
    _lastFrameDurations.clear();
    _lastRasterDuration = null;
    _lastRasterAt = null;
    _hasActiveBuiltinPresets = false;
    _presetSlowStreak = 0;
    _presetFastStreak = 0;
    _presetsThrottled = false;
  }

  Duration _resolveEffectiveCommandDuration(Duration measured) {
    if (measured <= slowFrameThreshold || !_isRecentRasterFast()) {
      return measured;
    }
    return _lastRasterDuration!;
  }

  bool _isRecentRasterFast() {
    if (!_timingsAttached) return false;
    final raster = _lastRasterDuration;
    final at = _lastRasterAt;
    if (raster == null || at == null) return false;
    if (clock.now().difference(at) > _recentRasterTelemetryWindow) return false;
    return raster <= slowFrameThreshold;
  }

  void _ensureSweepTimer() {
    if (_sweepTimer != null || _disposed || _pendingSubmissions.isEmpty) return;
    final intervalMs = completionTimeout.inMilliseconds.clamp(10, 250);
    _sweepTimer = Timer.periodic(
      Duration(milliseconds: intervalMs),
      (_) => _sweepExpiredSubmissions(),
    );
  }

  void _stopSweepTimerIfIdle() {
    if (_pendingSubmissions.isNotEmpty) return;
    _sweepTimer?.cancel();
    _sweepTimer = null;
  }

  void _sweepExpiredSubmissions() {
    if (_disposed || _pendingSubmissions.isEmpty) {
      _stopSweepTimerIfIdle();
      return;
    }
    final now = clock.now();
    final expiredTokens = <int>[
      for (final entry in _pendingSubmissions.entries)
        if (!now.isBefore(entry.value.deadline)) entry.key,
    ];
    for (final token in expiredTokens) {
      final pending = _pendingSubmissions.remove(token);
      if (pending == null) continue;
      for (final id in pending.shaderIds) {
        quarantineShader(
          id,
          'GPU command buffer completion timed out after '
          '${completionTimeout.inMilliseconds}ms.',
        );
      }
    }
    _stopSweepTimerIfIdle();
  }

  void _cancelPendingSubmissions() {
    _sweepTimer?.cancel();
    _sweepTimer = null;
    _pendingSubmissions.clear();
  }

  bool _isExempt(String shaderId) =>
      shaderId.isEmpty || (isBuiltinPreset?.call(shaderId) ?? false);

  List<String> _resolveTargetIds(Iterable<String>? customShaderIds) {
    final source = customShaderIds ?? _activeCustomShaderIds;
    return <String>[
      for (final id in source)
        if (!_isExempt(id) &&
            !_quarantinedShaderIds.contains(id) &&
            _activeCustomShaderIds.contains(id))
          id,
    ];
  }
}

final class _PendingGpuSubmission {
  final List<String> shaderIds;
  final DateTime deadline;

  const _PendingGpuSubmission({
    required this.shaderIds,
    required this.deadline,
  });
}
