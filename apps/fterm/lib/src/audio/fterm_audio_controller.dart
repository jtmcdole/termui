import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show VoidCallback, kIsWeb;
import 'package:termui_audio_flutter/termui_audio_flutter.dart';
import 'package:termui_pty/termui_pty.dart';

/// Factory creating a [TermuiAudioEngine] when audio output is activated.
typedef AudioEngineFactory = TermuiAudioEngine Function();

/// Scoped `(scopeKey, id)` key isolating audio clips, buses, and streams per session or pane.
typedef ScopedAudioId = ({String scopeKey, int id});

final class _PendingClipLoad {
  double volume;
  double pan;
  Duration startOffset;
  bool? paused;
  double? speed;
  bool preservePitch = false;
  double? fadeVolumeTarget;
  Duration? fadeVolumeDuration;
  double? fadeSpeedTarget;
  Duration? fadeSpeedDuration;
  Duration? scheduleStopDuration;

  _PendingClipLoad({
    required this.volume,
    required this.pan,
    required this.startOffset,
  });
}

final class _ScopedAudioStream {
  final ScopedAudioId id;
  final int maxBufferSize;
  final bool releaseConsumed;
  final Duration bufferingTimeNeeds;
  final int sampleRate;
  final int channels;
  AudioBuffer? buffer;
  bool opening = true;
  bool ended = false;
  bool broken = false;
  bool disposed = false;
  int nextExpectedSeq = 0;
  int queuedBytes = 0;
  int totalStreamedBytes = 0;
  final List<Uint8List> earlyChunks = [];
  final Set<ScopedAudioId> activeClipIds = {};
  bool pendingEnd = false;
  int? pendingEndSeq;
  final Completer<AudioBuffer?> readyCompleter = Completer<AudioBuffer?>();

  _ScopedAudioStream({
    required this.id,
    required this.maxBufferSize,
    required this.releaseConsumed,
    required this.bufferingTimeNeeds,
    required this.sampleRate,
    required this.channels,
  });
}

/// WebAudio + SoLoud audio controller handling lazy first-gesture initialization,
/// stereo-panned `BEL` chimes, and terminal `ESC _ A` audio playback.
final class FtermAudioController {
  static const double _bellFrequencyHz = 880.0;
  static const Duration _bellDuration = Duration(milliseconds: 90);
  static const Duration _bellCooldown = Duration(milliseconds: 75);
  static const Duration _toneCooldown = Duration(milliseconds: 25);
  static const Duration _maxToneDuration = Duration(seconds: 10);
  static const double _minToneFrequencyHz = 20.0;
  static const double _maxToneFrequencyHz = 20000.0;
  static const int _maxCachedTones = 32;
  static const int _maxCachedClips = 16;
  static const int _maxActiveOneShotVoices = 16;
  static const int _maxActiveClipVoices = 8;
  static const int _maxBusesPerScope = 4;
  static const int _maxStreamsPerScope = 4;
  static const int _maxStreamBytes = 16 * 1024 * 1024;
  static const int _maxStreamBufferBytes = 128 * 1024 * 1024;
  static const int _maxInitAttempts = 3;
  static const Duration _initRetryCooldown = Duration(seconds: 2);

  final AudioEngineFactory _engineFactory;
  final Clock? _clockOverride;
  final bool _requireUserGesture;
  final VoidCallback? _onStateChanged;

  TermuiAudioEngine? _engine;
  Future<bool>? _initFuture;
  bool _initialized = false;
  bool _disposed = false;
  bool _engineDisposed = false;
  bool _hasUserGesture = false;
  bool _muted;
  double _volume;
  int _initAttempts = 0;
  DateTime? _lastInitFailureAt;
  DateTime? _lastBellAt;
  DateTime? _lastToneEventAt;

  final LinkedHashMap<(WaveForm, int), AudioBuffer> _toneBuffers =
      LinkedHashMap<(WaveForm, int), AudioBuffer>();
  final LinkedHashMap<ScopedAudioId, AudioBuffer> _clipBuffers =
      LinkedHashMap<ScopedAudioId, AudioBuffer>();
  final Map<ScopedAudioId, List<AudioVoice>> _activeClipVoices = {};
  final Map<ScopedAudioId, _PendingClipLoad> _pendingClipLoads = {};
  final LinkedHashMap<AudioVoice, ScopedAudioId> _clipVoiceOrder =
      LinkedHashMap<AudioVoice, ScopedAudioId>.identity();
  final LinkedHashSet<AudioVoice> _activeOneShotVoices =
      LinkedHashSet<AudioVoice>.identity();
  final Map<AudioVoice, String> _oneShotVoiceScopes =
      Map<AudioVoice, String>.identity();
  final Map<AudioVoice, double> _voiceBaseVolumes =
      Map<AudioVoice, double>.identity();
  final Map<AudioVoice, (double speed, bool preservePitch)> _voiceSpeedStates =
      Map<AudioVoice, (double speed, bool preservePitch)>.identity();
  final LinkedHashMap<ScopedAudioId, AudioBus> _scopedBuses =
      LinkedHashMap<ScopedAudioId, AudioBus>();
  final Map<ScopedAudioId, Object> _pendingBusCreates = {};
  final LinkedHashMap<ScopedAudioId, _ScopedAudioStream> _scopedStreams =
      LinkedHashMap<ScopedAudioId, _ScopedAudioStream>();

  /// Creates an audio controller backed lazily by [_engineFactory].
  FtermAudioController({
    AudioEngineFactory? engineFactory,
    Clock? clock,
    bool initialMuted = false,
    double initialVolume = 0.7,
    bool? requireUserGesture,
    this._onStateChanged,
  }) : _engineFactory = engineFactory ?? FlutterAudioEngine.new,
       _clockOverride = clock,
       _muted = initialMuted,
       _volume = initialVolume.clamp(0.0, 1.0).toDouble(),
       _requireUserGesture = requireUserGesture ?? true {
    if (!_requireUserGesture) {
      _hasUserGesture = true;
    }
  }

  Clock get _clock => _clockOverride ?? clock;

  /// Whether audio output is muted.
  bool get muted => _muted;

  /// Output master volume scalar in `[0.0, 1.0]`.
  double get volume => _volume;

  /// Whether a first user gesture (`pointerdown` / `keydown`) has occurred.
  bool get hasUserGesture => _hasUserGesture;

  /// Whether the underlying [TermuiAudioEngine] has initialized successfully.
  bool get isInitialized => _initialized;

  /// Whether a key/pointer gesture should attempt audio engine initialization.
  bool get needsGestureUnlock =>
      !_disposed &&
      !_initialized &&
      _initFuture == null &&
      (!_hasUserGesture || (!_muted && _volume > 0 && _canAttemptInit()));

  /// Marks that a user gesture has occurred and warms up the audio engine when
  /// unmuted. Safe to call repeatedly across key and pointer handlers.
  Future<void> notifyUserGesture() {
    if (_disposed) return Future<void>.value();
    if (!_hasUserGesture) {
      _hasUserGesture = true;
    }
    if (_initialized || _muted || _volume <= 0) {
      return Future<void>.value();
    }
    return _ensureInitialized();
  }

  /// Updates mute state and adjusts currently playing voices immediately.
  void setMuted(bool nextMuted) {
    if (_disposed || _muted == nextMuted) return;
    _muted = nextMuted;
    _refreshPlayingVoiceVolumes();
    _onStateChanged?.call();
    if (!_muted && _hasUserGesture && _volume > 0) {
      unawaited(_ensureInitialized());
    }
  }

  /// Updates master volume scalar in `[0.0, 1.0]`.
  void setVolume(double nextVolume) {
    if (_disposed) return;
    final clamped = nextVolume.clamp(0.0, 1.0).toDouble();
    if (_volume == clamped) return;
    _volume = clamped;
    _refreshPlayingVoiceVolumes();
    _onStateChanged?.call();
  }

  /// Plays a stereo-panned `BEL` sine chime (`pan` in `[-1.0, 1.0]`).
  Future<void> playBell({double pan = 0.0}) async {
    if (!_canEmitAudio()) return;
    final now = _clock.now();
    final last = _lastBellAt;
    if (last != null && now.difference(last) < _bellCooldown) {
      return;
    }
    _lastBellAt = now;
    if (!await _ensureInitialized()) return;
    if (_disposed || _muted || _volume <= 0) return;

    final buffer = await _loadToneBuffer(WaveForm.sin, _bellFrequencyHz);
    if (buffer == null || _disposed) return;
    _startTimedTone(
      buffer: buffer,
      baseVolume: 0.35,
      pan: pan,
      duration: _bellDuration,
    );
  }

  /// Stops active playback, cancels pending loads, and frees cached buffers and buses for [scopeKey].
  void disposeScope(String scopeKey) {
    if (_disposed) return;
    _pendingClipLoads.removeWhere((id, _) => id.scopeKey == scopeKey);
    _pendingBusCreates.removeWhere((id, _) => id.scopeKey == scopeKey);
    _stopScopeVoices(scopeKey);
    final engine = _engine;
    final keysToRemove = [
      for (final key in _clipBuffers.keys)
        if (key.scopeKey == scopeKey) key,
    ];
    for (final key in keysToRemove) {
      final buffer = _clipBuffers.remove(key);
      if (engine != null && buffer != null) {
        _disposeBufferQuietly(engine, buffer);
      }
    }
    _destroyScopeBuses(engine, scopeKey);
    _disposeScopeStreams(engine, scopeKey);
  }

  /// Captures the active 256-sample output waveform when initialized, unmuted,
  /// and at positive master volume; otherwise returns `null`.
  Float32List? captureActiveWaveform() {
    final engine = _engine;
    if (_disposed ||
        !_initialized ||
        engine == null ||
        _muted ||
        _volume <= 0) {
      return null;
    }
    try {
      return engine.getWaveform();
    } on Object {
      return null;
    }
  }

  /// Plays or stops audio described by a decoded `ESC _ A` [TerminalAudioEvent].
  Future<void> handleAudioEvent(
    TerminalAudioEvent event, {
    String scopeKey = 'default',
    double fallbackPan = 0.0,
  }) async {
    if (_disposed) return;
    switch (event) {
      case TerminalStopAudioEvent(:final clipId):
        if (clipId == null) {
          _pendingClipLoads.removeWhere((id, _) => id.scopeKey == scopeKey);
          _stopScopeVoices(scopeKey);
        } else {
          final scopedId = (scopeKey: scopeKey, id: clipId);
          _pendingClipLoads.remove(scopedId);
          _stopClips(scopedId);
        }
      case TerminalUpdateAudioEvent():
        _updateClipEvent(scopeKey, event);
      case TerminalBusAudioEvent():
        await _handleBusEvent(event, scopeKey: scopeKey);
      case TerminalStreamAudioEvent():
        await _handleStreamEvent(event, scopeKey: scopeKey);
      case TerminalToneAudioEvent():
        await _playToneEvent(
          event,
          scopeKey: scopeKey,
          fallbackPan: fallbackPan,
        );
      case TerminalClipAudioEvent():
        await _playClipEvent(
          event,
          scopeKey: scopeKey,
          fallbackPan: fallbackPan,
        );
      case TerminalWaveformQueryAudioEvent():
        break;
    }
  }

  static double? _clampOptionalFinite(
    double? value, {
    required double min,
    required double max,
  }) => (value != null && value.isFinite)
      ? value.clamp(min, max).toDouble()
      : null;

  static void _tryVoiceOp(void Function() op) {
    try {
      op();
    } on Object {
      // Voice may already have finished cleanly.
    }
  }

  void _updateClipEvent(String scopeKey, TerminalUpdateAudioEvent event) {
    if (_disposed) return;
    final scopedId = (scopeKey: scopeKey, id: event.clipId);
    final pending = _pendingClipLoads[scopedId];
    if (pending != null) {
      _applyPendingUpdate(pending, event);
    }

    final engine = _engine;
    final voices = _activeClipVoices[scopedId];
    if (engine == null || !_initialized || voices == null) return;
    for (final voice in voices) {
      _applyVoiceUpdate(engine, voice, event);
    }
  }

  static ({double target, Duration duration})? _resolveFadePair(
    double? rawTarget,
    Duration? duration, {
    required bool isSpeed,
  }) {
    if (rawTarget == null || duration == null || duration.isNegative) {
      return null;
    }
    final clamped = isSpeed
        ? _clampOptionalPositiveSpeed(rawTarget)
        : _clampOptionalFinite(rawTarget, min: 0.0, max: 1.0);
    if (clamped == null) return null;
    return (target: clamped, duration: duration);
  }

  void _applyPendingUpdate(
    _PendingClipLoad pending,
    TerminalUpdateAudioEvent event,
  ) {
    if (_clampOptionalFinite(event.volume, min: 0.0, max: 1.0) case final v?) {
      pending.volume = v;
      pending.fadeVolumeTarget = null;
      pending.fadeVolumeDuration = null;
    }
    if (_clampOptionalFinite(event.pan, min: -1.0, max: 1.0) case final p?) {
      pending.pan = p;
    }
    if (event.seekPosition case final seek? when !seek.isNegative) {
      pending.startOffset = seek;
    }
    if (event.paused case final paused?) {
      pending.paused = paused;
    }
    if (_clampOptionalPositiveSpeed(event.speed) case final sp?) {
      pending.speed = sp;
      pending.fadeSpeedTarget = null;
      pending.fadeSpeedDuration = null;
    }
    if (event.preservePitch case final pp?) {
      pending.preservePitch = pp;
    }
    if (_resolveFadePair(
          event.fadeVolumeTarget,
          event.fadeVolumeDuration,
          isSpeed: false,
        )
        case final fv?) {
      pending.fadeVolumeTarget = fv.target;
      pending.fadeVolumeDuration = fv.duration;
    }
    if (_resolveFadePair(
          event.fadeSpeedTarget,
          event.fadeSpeedDuration,
          isSpeed: true,
        )
        case final fs?) {
      pending.fadeSpeedTarget = fs.target;
      pending.fadeSpeedDuration = fs.duration;
    }
    if (event.scheduleStopDuration case final stopDur?
        when !stopDur.isNegative) {
      pending.scheduleStopDuration = stopDur;
    }
  }

  static double? _clampOptionalPositiveSpeed(double? value) {
    if (value == null || !value.isFinite || value <= 0) return null;
    return value.clamp(0.125, 8.0).toDouble();
  }

  void _applyVoiceUpdate(
    TermuiAudioEngine engine,
    AudioVoice voice,
    TerminalUpdateAudioEvent event,
  ) {
    if (_clampOptionalFinite(event.volume, min: 0.0, max: 1.0) case final v?) {
      _voiceBaseVolumes[voice] = v;
      _tryVoiceOp(() => engine.setVoiceVolume(voice, _effectiveVolume(v)));
    }
    if (_clampOptionalFinite(event.pan, min: -1.0, max: 1.0) case final p?) {
      _tryVoiceOp(() => engine.setVoicePan(voice, p));
    }
    if (event.seekPosition case final seek? when !seek.isNegative) {
      _tryVoiceOp(() => engine.seek(voice, seek));
    }
    if (event.speed != null || event.preservePitch != null) {
      final prev = _voiceSpeedStates[voice];
      final speed = _clampOptionalPositiveSpeed(event.speed) ?? prev?.$1 ?? 1.0;
      final preservePitch = event.preservePitch ?? prev?.$2 ?? false;
      _voiceSpeedStates[voice] = (speed, preservePitch);
      _tryVoiceOp(
        () => engine.setRelativePlaySpeed(
          voice,
          speed,
          preservePitch: preservePitch,
        ),
      );
    }
    if (event.paused case final paused?) {
      _tryVoiceOp(() => engine.setPaused(voice, paused));
    }
    _applyVoiceFadesAndStop(engine, voice, event);
  }

  void _applyVoiceFadesAndStop(
    TermuiAudioEngine engine,
    AudioVoice voice,
    TerminalUpdateAudioEvent event,
  ) {
    if (_resolveFadePair(
          event.fadeVolumeTarget,
          event.fadeVolumeDuration,
          isSpeed: false,
        )
        case final fv?) {
      _voiceBaseVolumes[voice] = fv.target;
      _tryVoiceOp(
        () =>
            engine.fadeVolume(voice, _effectiveVolume(fv.target), fv.duration),
      );
    }
    if (_resolveFadePair(
          event.fadeSpeedTarget,
          event.fadeSpeedDuration,
          isSpeed: true,
        )
        case final fs?) {
      _tryVoiceOp(
        () => engine.fadeRelativePlaySpeed(voice, fs.target, fs.duration),
      );
    }
    if (event.scheduleStopDuration case final stopDur?
        when !stopDur.isNegative) {
      _tryVoiceOp(() => engine.scheduleStop(voice, stopDur));
    }
  }

  AudioBus? _resolveBus(String scopeKey, int? busId) {
    if (busId == null) return null;
    return _scopedBuses[(scopeKey: scopeKey, id: busId)];
  }

  Future<void> _handleBusEvent(
    TerminalBusAudioEvent event, {
    required String scopeKey,
  }) async {
    final scopedId = (scopeKey: scopeKey, id: event.busId);
    if (event.op == 'destroy') {
      _pendingBusCreates.remove(scopedId);
      final removed = _scopedBuses.remove(scopedId);
      final engine = _engine;
      if (removed != null && engine != null) {
        _destroyBusQuietly(engine, removed);
      }
      return;
    }
    if (event.op == 'create') {
      await _handleBusCreate(scopedId);
      return;
    }
    if (!_initialized && _pendingBusCreates.containsKey(scopedId)) {
      await _ensureInitialized();
    }
    final engine = _engine;
    final bus = _scopedBuses[scopedId];
    if (_disposed || !_initialized || engine == null || bus == null) return;
    _applyBusOp(engine, bus, event);
  }

  Future<void> _handleBusCreate(ScopedAudioId scopedId) async {
    if (!_canEmitAudio()) return;
    if (!_initialized) {
      final token = Object();
      _pendingBusCreates[scopedId] = token;
      final ok = await _ensureInitialized();
      final stillPending = identical(_pendingBusCreates[scopedId], token);
      if (stillPending) {
        _pendingBusCreates.remove(scopedId);
      }
      if (!ok || _disposed || _muted || _volume <= 0 || !stillPending) return;
    }
    final engine = _engine;
    if (engine == null || !_initialized) return;
    final existing = _scopedBuses.remove(scopedId);
    if (existing != null) {
      _destroyBusQuietly(engine, existing);
    }
    _evictExcessScopeBuses(engine, scopedId.scopeKey);
    try {
      _scopedBuses[scopedId] = engine.createBus();
    } on Object {
      // Degrade cleanly if native SoLoud bus allocation fails.
    }
  }

  void _evictExcessScopeBuses(TermuiAudioEngine engine, String scopeKey) {
    final scopeKeys = [
      for (final key in _scopedBuses.keys)
        if (key.scopeKey == scopeKey) key,
    ];
    var count = scopeKeys.length;
    var index = 0;
    while (count >= _maxBusesPerScope && index < scopeKeys.length) {
      final evicted = _scopedBuses.remove(scopeKeys[index++]);
      if (evicted != null) {
        _destroyBusQuietly(engine, evicted);
      }
      count--;
    }
  }

  void _applyBusOp(
    TermuiAudioEngine engine,
    AudioBus bus,
    TerminalBusAudioEvent event,
  ) {
    if (event.op == 'vol') {
      if (_clampOptionalFinite(event.value, min: 0.0, max: 1.0)
          case final vol?) {
        _tryVoiceOp(() => bus.setVolume(vol));
      }
      return;
    }
    final fid = event.filterId;
    if (fid == null || fid < 0 || fid >= FilterType.values.length) return;
    if (event.op == 'attach') {
      _tryVoiceOp(() => engine.attachFilterToBus(bus, fid));
      return;
    }
    _applyBusFilterParamOp(engine, bus, event, fid);
  }

  void _applyBusFilterParamOp(
    TermuiAudioEngine engine,
    AudioBus bus,
    TerminalBusAudioEvent event,
    int filterId,
  ) {
    final pid = event.paramId;
    final val = event.value;
    if (pid == null || pid < 0 || val == null || !val.isFinite) return;
    if (event.op == 'param') {
      _tryVoiceOp(() => engine.setFilterParameter(bus, filterId, pid, val));
    } else if (event.op == 'fade') {
      final dur = event.duration;
      if (dur != null && !dur.isNegative) {
        _tryVoiceOp(
          () => engine.fadeFilterParameter(bus, filterId, pid, val, dur),
        );
      }
    }
  }

  Future<void> _handleStreamEvent(
    TerminalStreamAudioEvent event, {
    required String scopeKey,
  }) async {
    final scopedId = (scopeKey: scopeKey, id: event.streamId);
    switch (event.op) {
      case 'open':
        await _handleStreamOpen(scopedId, event);
      case 'chunk':
        _handleStreamChunk(scopedId, event);
      case 'end':
        _handleStreamEnd(scopedId, event);
    }
  }

  Future<void> _handleStreamOpen(
    ScopedAudioId scopedId,
    TerminalStreamAudioEvent event,
  ) async {
    if (!_canEmitAudio()) return;
    final existing = _scopedStreams.remove(scopedId);
    if (existing != null) {
      _disposeStreamEntry(_engine, existing);
    }
    _evictExcessScopeStreams(_engine, scopedId.scopeKey);
    final rawMax = event.maxBufferSize ?? (4 * 1024 * 1024);
    final stream = _ScopedAudioStream(
      id: scopedId,
      maxBufferSize: rawMax.clamp(1, _maxStreamBufferBytes),
      releaseConsumed: event.releaseConsumed ?? false,
      bufferingTimeNeeds:
          event.bufferingTimeNeeds ?? const Duration(milliseconds: 500),
      sampleRate: (event.sampleRate ?? 48000).clamp(1, 384000),
      channels: (event.channels ?? 2) == 1 ? 1 : 2,
    );
    _scopedStreams[scopedId] = stream;
    await _openStreamBuffer(scopedId, stream);
  }

  Future<void> _openStreamBuffer(
    ScopedAudioId scopedId,
    _ScopedAudioStream stream,
  ) async {
    final ok = await _ensureInitialized();
    final engine = _engine;
    if (!ok ||
        engine == null ||
        _disposed ||
        stream.disposed ||
        _muted ||
        _volume <= 0 ||
        !identical(_scopedStreams[scopedId], stream)) {
      _abortStreamOpen(scopedId, stream);
      return;
    }
    final AudioBuffer buffer;
    try {
      buffer = await engine.createBufferStream(
        maxBufferSize: stream.maxBufferSize,
        releaseConsumed: stream.releaseConsumed,
        bufferingTimeNeeds: stream.bufferingTimeNeeds,
        sampleRate: stream.sampleRate,
        channels: stream.channels,
      );
    } on Object {
      _abortStreamOpen(scopedId, stream);
      return;
    }
    if (_disposed ||
        !identical(_engine, engine) ||
        stream.disposed ||
        !identical(_scopedStreams[scopedId], stream)) {
      _disposeBufferQuietly(engine, buffer);
      _completeStreamReady(stream, null);
      return;
    }
    stream.buffer = buffer;
    stream.opening = false;
    _drainEarlyStreamChunks(engine, stream);
    if (stream.pendingEnd) {
      _finalizePendingEnd(engine, stream);
    }
    _completeStreamReady(stream, buffer);
  }

  void _abortStreamOpen(ScopedAudioId scopedId, _ScopedAudioStream stream) {
    if (identical(_scopedStreams[scopedId], stream)) {
      _scopedStreams.remove(scopedId);
    }
    stream.disposed = true;
    stream.earlyChunks.clear();
    stream.queuedBytes = 0;
    _completeStreamReady(stream, null);
  }

  void _completeStreamReady(_ScopedAudioStream stream, AudioBuffer? buffer) {
    if (!stream.readyCompleter.isCompleted) {
      stream.readyCompleter.complete(buffer);
    }
  }

  void _drainEarlyStreamChunks(
    TermuiAudioEngine engine,
    _ScopedAudioStream stream,
  ) {
    final buffer = stream.buffer;
    if (buffer == null) return;
    for (final chunk in stream.earlyChunks) {
      _tryVoiceOp(() => engine.addStreamData(buffer, chunk));
      stream.totalStreamedBytes += chunk.length;
    }
    stream.earlyChunks.clear();
    stream.queuedBytes = 0;
  }

  void _finalizePendingEnd(
    TermuiAudioEngine engine,
    _ScopedAudioStream stream,
  ) {
    if (stream.pendingEndSeq != null &&
        stream.pendingEndSeq != stream.nextExpectedSeq) {
      stream.broken = true;
    }
    _endStreamBuffer(engine, stream);
  }

  void _handleStreamChunk(
    ScopedAudioId scopedId,
    TerminalStreamAudioEvent event,
  ) {
    final stream = _scopedStreams[scopedId];
    final seq = event.seq;
    final bytes = event.chunkBytes;
    if (stream == null ||
        stream.disposed ||
        stream.ended ||
        stream.broken ||
        seq == null ||
        bytes == null ||
        bytes.isEmpty) {
      return;
    }
    if (seq != stream.nextExpectedSeq) {
      _markStreamBrokenAndEnd(stream);
      return;
    }
    if (stream.opening) {
      _enqueueEarlyStreamChunk(stream, seq, bytes);
      return;
    }
    final engine = _engine;
    final buffer = stream.buffer;
    if (engine == null || buffer == null) return;
    if (!stream.releaseConsumed &&
        stream.totalStreamedBytes + bytes.length > _maxStreamBytes) {
      _markStreamBrokenAndEnd(stream);
      return;
    }
    stream.nextExpectedSeq = seq + 1;
    _tryVoiceOp(() => engine.addStreamData(buffer, bytes));
    stream.totalStreamedBytes += bytes.length;
  }

  void _enqueueEarlyStreamChunk(
    _ScopedAudioStream stream,
    int seq,
    Uint8List bytes,
  ) {
    final nextQueued = stream.queuedBytes + bytes.length;
    if (nextQueued > _maxStreamBytes) {
      stream.broken = true;
      stream.pendingEnd = true;
      return;
    }
    stream.nextExpectedSeq = seq + 1;
    stream.queuedBytes = nextQueued;
    stream.earlyChunks.add(bytes);
  }

  void _markStreamBrokenAndEnd(_ScopedAudioStream stream) {
    stream.broken = true;
    if (stream.opening) {
      stream.pendingEnd = true;
      return;
    }
    final engine = _engine;
    if (engine != null) {
      _endStreamBuffer(engine, stream);
    }
  }

  void _handleStreamEnd(
    ScopedAudioId scopedId,
    TerminalStreamAudioEvent event,
  ) {
    final stream = _scopedStreams[scopedId];
    if (stream == null || stream.disposed || stream.ended) return;
    if (stream.opening) {
      stream.pendingEnd = true;
      stream.pendingEndSeq = event.seq;
      return;
    }
    if (event.seq != null && event.seq != stream.nextExpectedSeq) {
      stream.broken = true;
    }
    final engine = _engine;
    if (engine != null) {
      _endStreamBuffer(engine, stream);
    }
  }

  void _endStreamBuffer(TermuiAudioEngine engine, _ScopedAudioStream stream) {
    if (stream.ended) return;
    stream.ended = true;
    final buffer = stream.buffer;
    if (buffer != null) {
      _tryVoiceOp(() => engine.setStreamEnded(buffer));
    }
  }

  void _evictExcessScopeStreams(TermuiAudioEngine? engine, String scopeKey) {
    final scopeKeys = [
      for (final key in _scopedStreams.keys)
        if (key.scopeKey == scopeKey) key,
    ];
    var count = scopeKeys.length;
    var index = 0;
    while (count >= _maxStreamsPerScope && index < scopeKeys.length) {
      final evicted = _scopedStreams.remove(scopeKeys[index++]);
      if (evicted != null) {
        _disposeStreamEntry(engine, evicted);
      }
      count--;
    }
  }

  void _disposeStreamEntry(
    TermuiAudioEngine? engine,
    _ScopedAudioStream stream,
  ) {
    stream.disposed = true;
    stream.earlyChunks.clear();
    stream.queuedBytes = 0;
    _completeStreamReady(stream, null);
    for (final clipId in [...stream.activeClipIds]) {
      _stopClips(clipId);
    }
    stream.activeClipIds.clear();
    final buffer = stream.buffer;
    stream.buffer = null;
    if (engine != null && buffer != null) {
      _disposeBufferQuietly(engine, buffer);
    }
  }

  void _disposeScopeStreams(TermuiAudioEngine? engine, String scopeKey) {
    final keys = [
      for (final key in _scopedStreams.keys)
        if (key.scopeKey == scopeKey) key,
    ];
    for (final key in keys) {
      final stream = _scopedStreams.remove(key);
      if (stream != null) {
        _disposeStreamEntry(engine, stream);
      }
    }
  }

  Future<void> _playToneEvent(
    TerminalToneAudioEvent event, {
    required String scopeKey,
    required double fallbackPan,
  }) async {
    if (!_canEmitAudio() || !event.frequencyHz.isFinite) return;
    final now = _clock.now();
    final last = _lastToneEventAt;
    if (last != null && now.difference(last) < _toneCooldown) {
      return;
    }
    _lastToneEventAt = now;
    if (!await _ensureInitialized()) return;
    if (_disposed || _muted || _volume <= 0) return;

    final clampedFreq = event.frequencyHz
        .clamp(_minToneFrequencyHz, _maxToneFrequencyHz)
        .toDouble();
    final clampedMicros = event.duration.inMicroseconds.clamp(
      0,
      _maxToneDuration.inMicroseconds,
    );
    final shape = mapWaveform(event.waveform);
    final buffer = await _loadToneBuffer(shape, clampedFreq);
    if (buffer == null || _disposed) return;
    final pan = event.pan != 0.0 ? event.pan : fallbackPan;
    _startTimedTone(
      buffer: buffer,
      baseVolume: event.volume,
      pan: pan,
      duration: Duration(microseconds: clampedMicros),
      scopeKey: scopeKey,
      bus: _resolveBus(scopeKey, event.busId),
    );
  }

  Future<void> _playClipEvent(
    TerminalClipAudioEvent event, {
    required String scopeKey,
    required double fallbackPan,
  }) async {
    if (!_canEmitAudio()) return;
    final scopedId = (scopeKey: scopeKey, id: event.clipId);
    final pending = _PendingClipLoad(
      volume: _clampFinite(event.volume, min: 0.0, max: 1.0),
      pan: _clampFinite(
        event.pan != 0.0 ? event.pan : fallbackPan,
        min: -1.0,
        max: 1.0,
      ),
      startOffset: event.startOffset.isNegative
          ? Duration.zero
          : event.startOffset,
    );
    _pendingClipLoads[scopedId] = pending;
    try {
      if (!await _ensureInitialized()) return;
      if (_disposed ||
          _muted ||
          _volume <= 0 ||
          !identical(_pendingClipLoads[scopedId], pending)) {
        return;
      }
      final buffer = event.streamId != null
          ? await _resolveStreamClipBuffer(scopedId, event.streamId!, pending)
          : await _loadClipBuffer(scopedId, event, pending);
      final engine = _engine;
      if (buffer == null ||
          engine == null ||
          _disposed ||
          !identical(_pendingClipLoads[scopedId], pending)) {
        return;
      }

      _evictExcessClipVoices(engine);

      final voice = _startPendingClipVoice(
        engine,
        buffer,
        event.loop,
        pending,
        bus: _resolveBus(scopeKey, event.busId),
      );
      _clipVoiceOrder[voice] = scopedId;
      _activeClipVoices.putIfAbsent(scopedId, () => []).add(voice);
      unawaited(
        voice.completed.whenComplete(() {
          _voiceBaseVolumes.remove(voice);
          _voiceSpeedStates.remove(voice);
          _clipVoiceOrder.remove(voice);
          _removeClipVoiceEntry(scopedId, voice);
        }),
      );
    } finally {
      if (identical(_pendingClipLoads[scopedId], pending)) {
        _pendingClipLoads.remove(scopedId);
      }
    }
  }

  AudioVoice _startPendingClipVoice(
    TermuiAudioEngine engine,
    AudioBuffer buffer,
    bool loop,
    _PendingClipLoad pending, {
    AudioBus? bus,
  }) {
    final pan = _clampFinite(pending.pan, min: -1.0, max: 1.0);
    final baseVolume = _clampFinite(pending.volume, min: 0.0, max: 1.0);
    final voice = engine.play(buffer, loop: loop, bus: bus, paused: true);
    engine.setVoicePan(voice, pan);
    engine.setVoiceVolume(voice, _effectiveVolume(baseVolume));
    _voiceBaseVolumes[voice] = baseVolume;
    if (pending.startOffset > Duration.zero) {
      _tryVoiceOp(() => engine.seek(voice, pending.startOffset));
    }
    if (pending.speed != null || pending.preservePitch) {
      final sp = pending.speed ?? 1.0;
      _voiceSpeedStates[voice] = (sp, pending.preservePitch);
      _tryVoiceOp(
        () => engine.setRelativePlaySpeed(
          voice,
          sp,
          preservePitch: pending.preservePitch,
        ),
      );
    }
    if (pending.paused != true) {
      engine.setPaused(voice, false);
    }
    if (pending.fadeVolumeTarget case final targetVol?) {
      final dur = pending.fadeVolumeDuration ?? Duration.zero;
      _voiceBaseVolumes[voice] = targetVol;
      _tryVoiceOp(
        () => engine.fadeVolume(voice, _effectiveVolume(targetVol), dur),
      );
    }
    if (pending.fadeSpeedTarget case final targetSpeed?) {
      final dur = pending.fadeSpeedDuration ?? Duration.zero;
      _tryVoiceOp(() => engine.fadeRelativePlaySpeed(voice, targetSpeed, dur));
    }
    if (pending.scheduleStopDuration case final stopDur?) {
      _tryVoiceOp(() => engine.scheduleStop(voice, stopDur));
    }
    return voice;
  }

  void _evictExcessClipVoices(TermuiAudioEngine engine) {
    while (_clipVoiceOrder.length >= _maxActiveClipVoices) {
      final oldest = _clipVoiceOrder.keys.first;
      final oldestScopedId = _clipVoiceOrder.remove(oldest);
      if (oldestScopedId != null) {
        _removeClipVoiceEntry(oldestScopedId, oldest);
      }
      _voiceBaseVolumes.remove(oldest);
      _voiceSpeedStates.remove(oldest);
      _stopVoiceQuietly(engine, oldest);
    }
  }

  void _removeClipVoiceEntry(ScopedAudioId scopedId, AudioVoice voice) {
    final list = _activeClipVoices[scopedId];
    if (list == null) return;
    list.remove(voice);
    if (list.isEmpty) {
      _activeClipVoices.remove(scopedId);
      for (final stream in _scopedStreams.values) {
        stream.activeClipIds.remove(scopedId);
      }
    }
  }

  void _startTimedTone({
    required AudioBuffer buffer,
    required double baseVolume,
    required double pan,
    required Duration duration,
    String? scopeKey,
    AudioBus? bus,
  }) {
    final engine = _engine;
    if (engine == null) return;
    while (_activeOneShotVoices.length >= _maxActiveOneShotVoices) {
      final oldest = _activeOneShotVoices.first;
      _activeOneShotVoices.remove(oldest);
      _oneShotVoiceScopes.remove(oldest);
      _voiceBaseVolumes.remove(oldest);
      _voiceSpeedStates.remove(oldest);
      _stopVoiceQuietly(engine, oldest);
    }
    final clampedPan = _clampFinite(pan, min: -1.0, max: 1.0);
    final clampedBase = _clampFinite(baseVolume, min: 0.0, max: 1.0);
    final voice = engine.play(buffer, bus: bus, paused: true);
    engine.setVoicePan(voice, clampedPan);
    engine.setVoiceVolume(voice, _effectiveVolume(clampedBase));
    engine.setPaused(voice, false);
    engine.fadeVolume(voice, 0.0, duration);
    engine.scheduleStop(voice, duration);
    _activeOneShotVoices.add(voice);
    if (scopeKey != null) {
      _oneShotVoiceScopes[voice] = scopeKey;
    }
    _voiceBaseVolumes[voice] = clampedBase;
    unawaited(
      voice.completed.whenComplete(() {
        _activeOneShotVoices.remove(voice);
        _oneShotVoiceScopes.remove(voice);
        _voiceBaseVolumes.remove(voice);
        _voiceSpeedStates.remove(voice);
      }),
    );
  }

  void _stopScopeVoices(String scopeKey) {
    final engine = _engine;
    if (engine == null) return;
    final matchingIds = [
      for (final id in _activeClipVoices.keys)
        if (id.scopeKey == scopeKey) id,
    ];
    for (final id in matchingIds) {
      _stopClips(id);
    }
    final matchingOneShots = [
      for (final entry in _oneShotVoiceScopes.entries)
        if (entry.value == scopeKey) entry.key,
    ];
    for (final voice in matchingOneShots) {
      _oneShotVoiceScopes.remove(voice);
      _activeOneShotVoices.remove(voice);
      _voiceBaseVolumes.remove(voice);
      _voiceSpeedStates.remove(voice);
      _stopVoiceQuietly(engine, voice);
    }
  }

  void _stopClips(ScopedAudioId scopedId) {
    final engine = _engine;
    if (engine == null) return;
    final targetVoices = _activeClipVoices.remove(scopedId);
    if (targetVoices == null) return;
    for (final voice in targetVoices) {
      _clipVoiceOrder.remove(voice);
      _voiceBaseVolumes.remove(voice);
      _voiceSpeedStates.remove(voice);
      _stopVoiceQuietly(engine, voice);
    }
  }

  static double _clampFinite(
    double value, {
    required double min,
    required double max,
  }) => value.isFinite ? value.clamp(min, max).toDouble() : 0.0;

  static void _stopVoiceQuietly(TermuiAudioEngine engine, AudioVoice voice) {
    try {
      engine.stop(voice);
    } on Object {
      // Voice may already have finished cleanly.
    }
  }

  static void _disposeBufferQuietly(
    TermuiAudioEngine engine,
    AudioBuffer buffer,
  ) {
    unawaited(engine.disposeBuffer(buffer).catchError((Object _) {}));
  }

  static void _destroyBusQuietly(TermuiAudioEngine engine, AudioBus bus) {
    try {
      engine.destroyBus(bus);
    } on Object {
      // Bus or engine may already be torn down.
    }
  }

  void _destroyScopeBuses(TermuiAudioEngine? engine, String scopeKey) {
    final busKeys = [
      for (final key in _scopedBuses.keys)
        if (key.scopeKey == scopeKey) key,
    ];
    for (final key in busKeys) {
      final bus = _scopedBuses.remove(key);
      if (engine != null && bus != null) {
        _destroyBusQuietly(engine, bus);
      }
    }
  }

  bool _canEmitAudio() =>
      !_disposed &&
      !_muted &&
      _volume > 0 &&
      (_hasUserGesture || !_requireUserGesture);

  double _effectiveVolume(double baseVolume) =>
      _muted ? 0.0 : (baseVolume * _volume).clamp(0.0, 1.0).toDouble();

  void _refreshPlayingVoiceVolumes() {
    final engine = _engine;
    if (engine == null || !_initialized) return;
    for (final MapEntry(key: voice, value: base) in _voiceBaseVolumes.entries) {
      try {
        engine.setVoiceVolume(voice, _effectiveVolume(base));
      } on Object {
        // Voice may already have finished cleanly.
      }
    }
  }

  Future<bool> _ensureInitialized() async {
    if (_disposed) return false;
    if (_initialized) return true;
    final pending = _initFuture;
    if (pending != null) return pending;
    if (!_canAttemptInit()) return false;

    final future = _runInit();
    _initFuture = future;
    final ok = await future;
    if (identical(_initFuture, future) && !ok) {
      // Allow bounded retries if Web SoLoud WASM was still loading.
      _initFuture = null;
    }
    return ok;
  }

  bool _canAttemptInit() {
    if (_initAttempts >= _maxInitAttempts) return false;
    final lastFailure = _lastInitFailureAt;
    if (_initAttempts >= 2 && lastFailure != null) {
      return _clock.now().difference(lastFailure) >= _initRetryCooldown;
    }
    return true;
  }

  Future<bool> _runInit() async {
    _initAttempts += 1;
    try {
      final engine = _engine ??= _engineFactory();
      await engine.init(enableVisualization: false);
      if (_disposed) {
        if (identical(_engine, engine)) {
          _engine = null;
        }
        await _disposeEngineOnce(engine);
        return false;
      }
      _initialized = true;
      _initAttempts = 0;
      _lastInitFailureAt = null;
      return true;
    } on Object {
      // Degrade cleanly when audio device or WASM runtime is unavailable.
      if (_initAttempts >= 2) {
        _lastInitFailureAt = _clock.now();
      }
      return false;
    }
  }

  Future<AudioBuffer?> _loadToneBuffer(
    WaveForm shape,
    double frequencyHz,
  ) async {
    final engine = _engine;
    if (engine == null || !_initialized) return null;
    final roundedFreq = frequencyHz
        .clamp(_minToneFrequencyHz, _maxToneFrequencyHz)
        .round();
    final key = (shape, roundedFreq);
    final existing = _toneBuffers.remove(key);
    if (existing != null) {
      _toneBuffers[key] = existing;
      return existing;
    }
    try {
      final buffer = await engine.loadWaveform(
        shape,
        roundedFreq.toDouble(),
        usePcmFallback: kIsWeb,
      );
      if (_disposed || !identical(_engine, engine)) {
        _disposeBufferQuietly(engine, buffer);
        return null;
      }
      final raced = _toneBuffers.remove(key);
      if (raced != null) {
        _toneBuffers[key] = raced;
        _disposeBufferQuietly(engine, buffer);
        return raced;
      }
      _toneBuffers[key] = buffer;
      if (_toneBuffers.length > _maxCachedTones) {
        final oldestKey = _toneBuffers.keys.first;
        final oldest = _toneBuffers.remove(oldestKey);
        if (oldest != null) {
          _disposeBufferQuietly(engine, oldest);
        }
      }
      return buffer;
    } on Object {
      return null;
    }
  }

  Future<AudioBuffer?> _resolveStreamClipBuffer(
    ScopedAudioId scopedId,
    int streamId,
    _PendingClipLoad pending,
  ) async {
    final engine = _engine;
    final stream = _scopedStreams[(scopeKey: scopedId.scopeKey, id: streamId)];
    if (engine == null || !_initialized || stream == null || stream.disposed) {
      return null;
    }
    final buffer = stream.buffer ?? await stream.readyCompleter.future;
    if (buffer == null ||
        _disposed ||
        stream.disposed ||
        !identical(_engine, engine) ||
        !identical(_pendingClipLoads[scopedId], pending)) {
      return null;
    }
    _stopClips(scopedId);
    stream.activeClipIds.add(scopedId);
    return buffer;
  }

  Future<AudioBuffer?> _loadClipBuffer(
    ScopedAudioId scopedId,
    TerminalClipAudioEvent event,
    _PendingClipLoad pending,
  ) async {
    final engine = _engine;
    if (engine == null || !_initialized) return null;
    _stopClips(scopedId);
    final existing = _clipBuffers.remove(scopedId);
    if (existing != null) {
      _disposeBufferQuietly(engine, existing);
    }
    try {
      final buffer = await engine.loadMem(
        'fterm-clip-${scopedId.scopeKey}-${scopedId.id}.${event.format}',
        event.bytes,
      );
      if (_disposed ||
          !identical(_engine, engine) ||
          !identical(_pendingClipLoads[scopedId], pending)) {
        _disposeBufferQuietly(engine, buffer);
        return null;
      }
      _stopClips(scopedId);
      final raced = _clipBuffers.remove(scopedId);
      if (raced != null) {
        _disposeBufferQuietly(engine, raced);
      }
      _clipBuffers[scopedId] = buffer;
      if (_clipBuffers.length > _maxCachedClips) {
        final oldestId = _clipBuffers.keys.first;
        _stopClips(oldestId);
        final oldest = _clipBuffers.remove(oldestId);
        if (oldest != null) {
          _disposeBufferQuietly(engine, oldest);
        }
      }
      return buffer;
    } on Object {
      return null;
    }
  }

  /// Maps an APC `w=` waveform string to `termui_audio`'s [WaveForm].
  static WaveForm mapWaveform(String raw) => switch (raw.trim().toLowerCase()) {
    'square' => WaveForm.square,
    'saw' || 'sawtooth' => WaveForm.saw,
    'triangle' => WaveForm.triangle,
    'bounce' => WaveForm.bounce,
    'jaws' => WaveForm.jaws,
    'humps' => WaveForm.humps,
    'fsquare' => WaveForm.fsquare,
    'fsaw' => WaveForm.fsaw,
    _ => WaveForm.sin,
  };

  /// Stops active playback and frees all cached audio buffers and engine state.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _pendingClipLoads.clear();
    _pendingBusCreates.clear();
    final engine = _engine;
    _engine = null;
    _initialized = false;
    if (engine == null) {
      _voiceBaseVolumes.clear();
      _voiceSpeedStates.clear();
      _scopedBuses.clear();
      _disposeAllStreamsWithoutEngine();
      return;
    }

    _stopAllVoices(engine);
    _destroyAllBuses(engine);
    await _disposeCachedBuffers(engine);
    await _disposeEngineOnce(engine);
  }

  void _disposeAllStreamsWithoutEngine() {
    final streams = _scopedStreams.values.toList();
    _scopedStreams.clear();
    for (final stream in streams) {
      stream.disposed = true;
      stream.earlyChunks.clear();
      stream.activeClipIds.clear();
      stream.queuedBytes = 0;
      stream.buffer = null;
      _completeStreamReady(stream, null);
    }
  }

  void _destroyAllBuses(TermuiAudioEngine engine) {
    final buses = _scopedBuses.values.toList();
    _scopedBuses.clear();
    for (final bus in buses) {
      _destroyBusQuietly(engine, bus);
    }
  }

  Future<void> _disposeEngineOnce(TermuiAudioEngine engine) async {
    if (_engineDisposed) return;
    _engineDisposed = true;
    try {
      await engine.dispose();
    } on Object {
      // Ignore teardown engine errors.
    }
  }

  void _stopAllVoices(TermuiAudioEngine engine) {
    final allVoices = <AudioVoice>[
      ..._activeOneShotVoices,
      for (final group in _activeClipVoices.values) ...group,
    ];
    _activeOneShotVoices.clear();
    _oneShotVoiceScopes.clear();
    _activeClipVoices.clear();
    _clipVoiceOrder.clear();
    for (final voice in allVoices) {
      _voiceBaseVolumes.remove(voice);
      _voiceSpeedStates.remove(voice);
      _stopVoiceQuietly(engine, voice);
    }
  }

  Future<void> _disposeCachedBuffers(TermuiAudioEngine engine) async {
    final streams = _scopedStreams.values.toList();
    _scopedStreams.clear();
    final buffers = <AudioBuffer>[
      ..._toneBuffers.values,
      ..._clipBuffers.values,
      for (final stream in streams)
        if (stream.buffer != null) stream.buffer!,
    ];
    for (final stream in streams) {
      stream.disposed = true;
      stream.earlyChunks.clear();
      stream.activeClipIds.clear();
      stream.queuedBytes = 0;
      stream.buffer = null;
      _completeStreamReady(stream, null);
    }
    _toneBuffers.clear();
    _clipBuffers.clear();
    for (final buffer in buffers) {
      try {
        await engine.disposeBuffer(buffer);
      } on Object {
        // Ignore teardown buffer errors.
      }
    }
  }
}
