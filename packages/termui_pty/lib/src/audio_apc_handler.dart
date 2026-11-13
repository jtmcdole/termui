import 'dart:convert';
import 'dart:typed_data';

/// Terminal audio playback or synthesis event decoded from `ESC _ A ... ST`.
sealed class TerminalAudioEvent {
  /// Creates a terminal audio event.
  const TerminalAudioEvent();
}

/// Synthetic waveform tone request decoded from `ESC _ A a=tone,... ST`.
final class TerminalToneAudioEvent extends TerminalAudioEvent {
  /// Waveform name (`'sine'`, `'square'`, `'saw'`, `'triangle'`, etc.).
  final String waveform;

  /// Tone frequency in Hertz (`> 0`).
  final double frequencyHz;

  /// Tone duration.
  final Duration duration;

  /// Playback volume clamped to `0.0 .. 1.0`.
  final double volume;

  /// Stereo pan clamped to `-1.0 .. 1.0`.
  final double pan;

  /// Optional positive 31-bit mixing bus identifier (`1 .. 0x7FFFFFFF`).
  final int? busId;

  /// Creates a synthetic tone audio event.
  const TerminalToneAudioEvent({
    required this.waveform,
    required this.frequencyHz,
    required this.duration,
    this.volume = 0.8,
    this.pan = 0.0,
    this.busId,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalToneAudioEvent &&
          other.waveform == waveform &&
          other.frequencyHz == frequencyHz &&
          other.duration == duration &&
          other.volume == volume &&
          other.pan == pan &&
          other.busId == busId;

  @override
  int get hashCode =>
      Object.hash(waveform, frequencyHz, duration, volume, pan, busId);
}

/// Decoded in-memory audio clip playback event from `ESC _ A a=clip,... ST`.
final class TerminalClipAudioEvent extends TerminalAudioEvent {
  /// Positive 32-bit clip identifier.
  final int clipId;

  /// Audio container format (`'wav'`, `'ogg'`, or `'mp3'`).
  final String format;

  /// Decoded audio container bytes (`<= 2 MiB`).
  final Uint8List bytes;

  /// Playback volume clamped to `0.0 .. 1.0`.
  final double volume;

  /// Stereo pan clamped to `-1.0 .. 1.0`.
  final double pan;

  /// Whether clip playback should loop until stopped.
  final bool loop;

  /// Initial playback start offset (`playSprite` start position).
  final Duration startOffset;

  /// Optional positive 31-bit mixing bus identifier (`1 .. 0x7FFFFFFF`).
  final int? busId;

  /// Creates an audio clip playback event.
  const TerminalClipAudioEvent({
    required this.clipId,
    required this.format,
    required this.bytes,
    this.volume = 1.0,
    this.pan = 0.0,
    this.loop = false,
    this.startOffset = Duration.zero,
    this.busId,
  });
}

/// Mixing bus lifecycle or DSP filter command decoded from `ESC _ A a=bus,... ST`.
final class TerminalBusAudioEvent extends TerminalAudioEvent {
  /// Bus operation (`'create'`, `'destroy'`, `'vol'`, `'attach'`, `'param'`, or `'fade'`).
  final String op;

  /// Positive 31-bit wire bus identifier (`1 .. 0x7FFFFFFF`).
  final int busId;

  /// Optional DSP filter type index (`0 .. 11`) for `'attach'`, `'param'`, and `'fade'`.
  final int? filterId;

  /// Optional filter parameter index (`0 .. 66`) for `'param'` and `'fade'`.
  final int? paramId;

  /// Optional bus volume (`0.0 .. 1.0`) for `'vol'`, or filter parameter value for `'param'` / `'fade'`.
  final double? value;

  /// Optional fade duration (`>= Duration.zero`) for `'fade'`.
  final Duration? duration;

  /// Creates a mixing bus or filter audio event.
  const TerminalBusAudioEvent({
    required this.op,
    required this.busId,
    this.filterId,
    this.paramId,
    this.value,
    this.duration,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalBusAudioEvent &&
          other.op == op &&
          other.busId == busId &&
          other.filterId == filterId &&
          other.paramId == paramId &&
          other.value == value &&
          other.duration == duration;

  @override
  int get hashCode =>
      Object.hash(op, busId, filterId, paramId, value, duration);
}

/// Audio stop request decoded from `ESC _ A a=stop,... ST`.
final class TerminalStopAudioEvent extends TerminalAudioEvent {
  /// Target clip identifier to stop, or `null` to stop all active clips.
  final int? clipId;

  /// Creates an audio stop event.
  const TerminalStopAudioEvent({this.clipId});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalStopAudioEvent && other.clipId == clipId;

  @override
  int get hashCode => clipId.hashCode;
}

/// Live voice parameter and transport update decoded from `ESC _ A a=update,... ST`.
final class TerminalUpdateAudioEvent extends TerminalAudioEvent {
  /// Positive 31-bit wire clip identifier (`1 .. 0x7FFFFFFF`).
  final int clipId;

  /// Optional updated playback volume clamped to `0.0 .. 1.0`.
  final double? volume;

  /// Optional updated stereo pan clamped to `-1.0 .. 1.0`.
  final double? pan;

  /// Optional seek target position (`>= Duration.zero`).
  final Duration? seekPosition;

  /// Optional pause state (`true` pauses, `false` resumes).
  final bool? paused;

  /// Optional relative playback speed multiplier clamped to `0.125 .. 8.0`.
  final double? speed;

  /// Optional pitch-preservation flag for speed changes.
  final bool? preservePitch;

  /// Optional volume fade target (`0.0 .. 1.0`), paired with [fadeVolumeDuration].
  final double? fadeVolumeTarget;

  /// Optional volume fade duration, paired with [fadeVolumeTarget].
  final Duration? fadeVolumeDuration;

  /// Optional speed fade target (`0.125 .. 8.0`), paired with [fadeSpeedDuration].
  final double? fadeSpeedTarget;

  /// Optional speed fade duration, paired with [fadeSpeedTarget].
  final Duration? fadeSpeedDuration;

  /// Optional scheduled stop delay (`>= Duration.zero`).
  final Duration? scheduleStopDuration;

  /// Creates an audio voice update event.
  const TerminalUpdateAudioEvent({
    required this.clipId,
    this.volume,
    this.pan,
    this.seekPosition,
    this.paused,
    this.speed,
    this.preservePitch,
    this.fadeVolumeTarget,
    this.fadeVolumeDuration,
    this.fadeSpeedTarget,
    this.fadeSpeedDuration,
    this.scheduleStopDuration,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalUpdateAudioEvent &&
          other.clipId == clipId &&
          other.volume == volume &&
          other.pan == pan &&
          other.seekPosition == seekPosition &&
          other.paused == paused &&
          other.speed == speed &&
          other.preservePitch == preservePitch &&
          other.fadeVolumeTarget == fadeVolumeTarget &&
          other.fadeVolumeDuration == fadeVolumeDuration &&
          other.fadeSpeedTarget == fadeSpeedTarget &&
          other.fadeSpeedDuration == fadeSpeedDuration &&
          other.scheduleStopDuration == scheduleStopDuration;

  @override
  int get hashCode => Object.hashAll([
    clipId,
    volume,
    pan,
    seekPosition,
    paused,
    speed,
    preservePitch,
    fadeVolumeTarget,
    fadeVolumeDuration,
    fadeSpeedTarget,
    fadeSpeedDuration,
    scheduleStopDuration,
  ]);
}

final class _PendingAudioUpload {
  final int clipId;
  final String format;
  double volume;
  double pan;
  final bool loop;
  final Duration startOffset;
  final int? busId;
  Duration? seekPosition;
  bool? paused;
  double? speed;
  bool? preservePitch;
  double? fadeVolumeTarget;
  Duration? fadeVolumeDuration;
  double? fadeSpeedTarget;
  Duration? fadeSpeedDuration;
  Duration? scheduleStopDuration;
  final StringBuffer base64Data = StringBuffer();
  int charCount = 0;
  bool overflowed = false;

  _PendingAudioUpload({
    required this.clipId,
    required this.format,
    required this.volume,
    required this.pan,
    required this.loop,
    required this.startOffset,
    this.busId,
  });

  bool get hasDeferredTransportUpdate =>
      seekPosition != null ||
      paused != null ||
      speed != null ||
      preservePitch != null ||
      fadeVolumeTarget != null ||
      fadeSpeedTarget != null ||
      scheduleStopDuration != null;
}

/// Pure-Dart parser for chunked `ESC _ A <k=v,...>;<base64> ST` audio commands.
final class AudioApcHandler {
  /// Maximum decoded audio clip size allowed per upload (`2 MiB`).
  static const int maxClipBytes = 2 * 1024 * 1024;

  /// Maximum concurrent in-flight chunked clip uploads.
  static const int maxConcurrentUploads = 8;

  static const int _maxBase64PerUpload = ((maxClipBytes + 2) ~/ 3) * 4;
  static const int _maxTotalPendingBase64 =
      _maxBase64PerUpload * maxConcurrentUploads;

  static const Set<String> _validFormats = {'wav', 'ogg', 'mp3'};
  static const Set<String> _validWaveforms = {
    'sine',
    'square',
    'saw',
    'triangle',
    'bounce',
    'jaws',
    'humps',
    'fsquare',
    'fsaw',
  };
  static final RegExp _whitespaceRegex = RegExp(r'\s+');

  /// Callback invoked whenever a complete audio event is decoded.
  final void Function(TerminalAudioEvent event)? onAudioEvent;

  final Map<int, _PendingAudioUpload> _pendingUploads = {};
  int _totalPendingBase64 = 0;
  int? _lastActiveUploadId;
  int _nextAutoId = 0x80000001;

  /// Creates an [AudioApcHandler] dispatching decoded events to [onAudioEvent].
  AudioApcHandler({this.onAudioEvent});

  /// Number of currently active incomplete chunked uploads.
  int get pendingUploadCount => _pendingUploads.length;

  /// Discards all pending incomplete chunked uploads.
  void reset() {
    _pendingUploads.clear();
    _totalPendingBase64 = 0;
    _lastActiveUploadId = null;
  }

  /// Parses an APC payload beginning with `A` or `_A`.
  void handleApc(String payload) {
    if (!payload.startsWith('A') && !payload.startsWith('_A')) return;
    final clean = payload.startsWith('_A') ? payload.substring(1) : payload;
    final semiIdx = clean.indexOf(';');
    final controlPart = semiIdx >= 0
        ? clean.substring(1, semiIdx)
        : clean.substring(1);
    final dataPart = semiIdx >= 0 ? clean.substring(semiIdx + 1) : '';
    final control = _parseControlPart(controlPart);

    final action = control['a'];
    if (action == null) {
      final pending = _resolveActiveContinuation(control);
      if (pending != null) {
        _processClipChunk(pending, control, dataPart);
      }
      return;
    }

    switch (action) {
      case 'tone':
        _handleTone(control);
      case 'clip':
        _handleNewClip(control, dataPart);
      case 'update':
        _handleUpdate(control);
      case 'stop':
        _handleStop(control);
      case 'bus':
        _handleBus(control);
    }
  }

  static Map<String, String> _parseControlPart(String control) {
    final map = <String, String>{};
    if (control.isEmpty) return map;
    for (final pair in control.split(',')) {
      final eq = pair.indexOf('=');
      if (eq > 0) {
        map[pair.substring(0, eq).trim()] = pair.substring(eq + 1).trim();
      }
    }
    return map;
  }

  /// Parses an explicit positive 31-bit wire clip ID (`1 .. 0x7FFFFFFF`).
  ///
  /// Returns `null` when [raw] is omitted (`null`), or `-1` when [raw] was
  /// explicitly supplied but malformed or out of range.
  static int? _parseExplicitClipId(String? raw) {
    if (raw == null) return null;
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed <= 0 || parsed > 0x7FFFFFFF) return -1;
    return parsed;
  }

  static double? _parseOptionalBoundedDouble(
    String? raw, {
    required double min,
    required double max,
  }) {
    if (raw == null || raw.isEmpty) return null;
    final parsed = double.tryParse(raw);
    if (parsed == null || !parsed.isFinite) return null;
    return parsed.clamp(min, max).toDouble();
  }

  static double _parseBoundedDouble(
    String? raw, {
    required double min,
    required double max,
    required double fallback,
  }) => _parseOptionalBoundedDouble(raw, min: min, max: max) ?? fallback;

  static String? _normalizeWaveform(String? raw) {
    final lower = (raw ?? 'sine').trim().toLowerCase();
    final canonical = lower == 'sin' ? 'sine' : lower;
    return _validWaveforms.contains(canonical) ? canonical : null;
  }

  void _handleTone(Map<String, String> control) {
    final waveform = _normalizeWaveform(control['w']);
    final freq = double.tryParse(control['f'] ?? '');
    final durationMs = double.tryParse(control['d'] ?? '');
    final busId = _parseExplicitClipId(control['b']);
    if (waveform == null ||
        freq == null ||
        !freq.isFinite ||
        freq <= 0 ||
        durationMs == null ||
        !durationMs.isFinite ||
        durationMs < 0 ||
        (busId != null && busId < 0)) {
      return;
    }
    final clampedFreq = freq.clamp(20.0, 20000.0).toDouble();
    final clampedDurationMs = durationMs.clamp(0.0, 10000.0).toDouble();
    final volume = _parseBoundedDouble(
      control['v'],
      min: 0.0,
      max: 1.0,
      fallback: 0.8,
    );
    final pan = _parseBoundedDouble(
      control['p'],
      min: -1.0,
      max: 1.0,
      fallback: 0.0,
    );
    onAudioEvent?.call(
      TerminalToneAudioEvent(
        waveform: waveform,
        frequencyHz: clampedFreq,
        duration: Duration(microseconds: (clampedDurationMs * 1000.0).round()),
        volume: volume,
        pan: pan,
        busId: busId,
      ),
    );
  }

  static int? _parseOptionalBoundedInt(
    String? raw, {
    required int min,
    required int max,
  }) {
    if (raw == null || raw.isEmpty) return null;
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed < min || parsed > max) return null;
    return parsed;
  }

  static double? _parseOptionalFiniteDouble(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final parsed = double.tryParse(raw);
    return (parsed != null && parsed.isFinite) ? parsed : null;
  }

  void _handleBus(Map<String, String> control) {
    final op = control['op']?.trim().toLowerCase();
    final busId = _parseExplicitClipId(control['b']);
    if (op == null || busId == null || busId <= 0) return;
    switch (op) {
      case 'create' || 'destroy':
        onAudioEvent?.call(TerminalBusAudioEvent(op: op, busId: busId));
      case 'vol':
        final value = _parseOptionalBoundedDouble(
          control['v'],
          min: 0.0,
          max: 1.0,
        );
        if (value == null) return;
        onAudioEvent?.call(
          TerminalBusAudioEvent(op: op, busId: busId, value: value),
        );
      case 'attach':
        final filterId = _parseOptionalBoundedInt(
          control['ft'],
          min: 0,
          max: 11,
        );
        if (filterId == null) return;
        onAudioEvent?.call(
          TerminalBusAudioEvent(op: op, busId: busId, filterId: filterId),
        );
      case 'param' || 'fade':
        final filterId = _parseOptionalBoundedInt(
          control['ft'],
          min: 0,
          max: 11,
        );
        final paramId = _parseOptionalBoundedInt(
          control['pm'],
          min: 0,
          max: 66,
        );
        final value = _parseOptionalFiniteDouble(control['v']);
        final duration = op == 'fade'
            ? _parseOptionalDurationMs(control['d'])
            : null;
        if (filterId == null ||
            paramId == null ||
            value == null ||
            (op == 'fade' && duration == null)) {
          return;
        }
        onAudioEvent?.call(
          TerminalBusAudioEvent(
            op: op,
            busId: busId,
            filterId: filterId,
            paramId: paramId,
            value: value,
            duration: duration,
          ),
        );
    }
  }

  static Duration? _parseOptionalDurationMs(
    String? raw, {
    double maxMs = 86400000.0,
  }) {
    if (raw == null || raw.isEmpty) return null;
    final parsed = double.tryParse(raw);
    if (parsed == null || !parsed.isFinite || parsed < 0) return null;
    final clamped = parsed > maxMs ? maxMs : parsed;
    return Duration(microseconds: (clamped * 1000.0).round());
  }

  static bool? _parseOptionalBoolFlag(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return switch (raw.trim().toLowerCase()) {
      '1' || 'true' => true,
      '0' || 'false' => false,
      _ => null,
    };
  }

  static double? _parseOptionalSpeed(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final parsed = double.tryParse(raw);
    if (parsed == null || !parsed.isFinite || parsed <= 0) return null;
    return parsed.clamp(0.125, 8.0).toDouble();
  }

  static ({double target, Duration duration})? _parseFadePair(
    String? raw, {
    required double minVal,
    required double maxVal,
    bool requirePositive = false,
  }) {
    if (raw == null || raw.isEmpty) return null;
    final sep = raw.indexOf(':');
    if (sep <= 0 || sep >= raw.length - 1 || raw.indexOf(':', sep + 1) >= 0) {
      return null;
    }
    final targetStr = raw.substring(0, sep);
    final durStr = raw.substring(sep + 1);
    final target = requirePositive
        ? _parseOptionalSpeed(targetStr)
        : _parseOptionalBoundedDouble(targetStr, min: minVal, max: maxVal);
    final duration = _parseOptionalDurationMs(durStr);
    if (target == null || duration == null) return null;
    return (target: target, duration: duration);
  }

  static void _applyPendingUploadUpdate(
    _PendingAudioUpload pending, {
    required double? volume,
    required double? pan,
    required Duration? seekPosition,
    required bool? paused,
    required double? speed,
    required bool? preservePitch,
    required ({double target, Duration duration})? fadeVol,
    required ({double target, Duration duration})? fadeSpeed,
    required Duration? scheduleStopDuration,
  }) {
    if (volume != null) {
      pending.volume = volume;
      pending.fadeVolumeTarget = null;
      pending.fadeVolumeDuration = null;
    }
    pending.pan = pan ?? pending.pan;
    pending.seekPosition = seekPosition ?? pending.seekPosition;
    pending.paused = paused ?? pending.paused;
    if (speed != null) {
      pending.speed = speed;
      pending.fadeSpeedTarget = null;
      pending.fadeSpeedDuration = null;
    }
    pending.preservePitch = preservePitch ?? pending.preservePitch;
    if (fadeVol != null) {
      pending.fadeVolumeTarget = fadeVol.target;
      pending.fadeVolumeDuration = fadeVol.duration;
    }
    if (fadeSpeed != null) {
      pending.fadeSpeedTarget = fadeSpeed.target;
      pending.fadeSpeedDuration = fadeSpeed.duration;
    }
    pending.scheduleStopDuration =
        scheduleStopDuration ?? pending.scheduleStopDuration;
  }

  void _handleUpdate(Map<String, String> control) {
    final clipId = _parseExplicitClipId(control['i']);
    if (clipId == null || clipId <= 0) return;
    final volume = _parseOptionalBoundedDouble(
      control['v'],
      min: 0.0,
      max: 1.0,
    );
    final pan = _parseOptionalBoundedDouble(control['p'], min: -1.0, max: 1.0);
    final seekPosition = _parseOptionalDurationMs(control['s']);
    final paused = _parseOptionalBoolFlag(control['pa']);
    final speed = _parseOptionalSpeed(control['sp']);
    final preservePitch = _parseOptionalBoolFlag(control['pp']);
    final fadeVol = _parseFadePair(control['fv'], minVal: 0.0, maxVal: 1.0);
    final fadeSpeed = _parseFadePair(
      control['fs'],
      minVal: 0.125,
      maxVal: 8.0,
      requirePositive: true,
    );
    final scheduleStopDuration = _parseOptionalDurationMs(control['st']);

    final hasAny =
        volume != null ||
        pan != null ||
        seekPosition != null ||
        paused != null ||
        speed != null ||
        preservePitch != null ||
        fadeVol != null ||
        fadeSpeed != null ||
        scheduleStopDuration != null;
    if (!hasAny) return;

    final pending = _pendingUploads[clipId];
    if (pending != null) {
      _applyPendingUploadUpdate(
        pending,
        volume: volume,
        pan: pan,
        seekPosition: seekPosition,
        paused: paused,
        speed: speed,
        preservePitch: preservePitch,
        fadeVol: fadeVol,
        fadeSpeed: fadeSpeed,
        scheduleStopDuration: scheduleStopDuration,
      );
      return;
    }

    onAudioEvent?.call(
      TerminalUpdateAudioEvent(
        clipId: clipId,
        volume: volume,
        pan: pan,
        seekPosition: seekPosition,
        paused: paused,
        speed: speed,
        preservePitch: preservePitch,
        fadeVolumeTarget: fadeVol?.target,
        fadeVolumeDuration: fadeVol?.duration,
        fadeSpeedTarget: fadeSpeed?.target,
        fadeSpeedDuration: fadeSpeed?.duration,
        scheduleStopDuration: scheduleStopDuration,
      ),
    );
  }

  void _handleStop(Map<String, String> control) {
    final clipId = _parseExplicitClipId(control['i']);
    if (clipId != null && clipId < 0) return;
    onAudioEvent?.call(TerminalStopAudioEvent(clipId: clipId));
  }

  int _allocateAutoId() {
    final id = _nextAutoId & 0xFFFFFFFF;
    _nextAutoId = ((_nextAutoId + 1) & 0x7FFFFFFF) | 0x80000000;
    return id == 0 ? 0x80000001 : id;
  }

  _PendingAudioUpload? _resolveActiveContinuation(Map<String, String> control) {
    final explicitId = _parseExplicitClipId(control['i']);
    if (explicitId != null) {
      return explicitId > 0 ? _pendingUploads[explicitId] : null;
    }
    final lastId = _lastActiveUploadId;
    return lastId != null ? _pendingUploads[lastId] : null;
  }

  void _removePendingUpload(int clipId) {
    if (_lastActiveUploadId == clipId) {
      _lastActiveUploadId = null;
    }
    final removed = _pendingUploads.remove(clipId);
    if (removed != null) {
      _totalPendingBase64 -= removed.charCount;
    }
  }

  void _evictOldestUploadIfNeeded() {
    while (_pendingUploads.length >= maxConcurrentUploads) {
      final oldestKey = _pendingUploads.keys.first;
      _removePendingUpload(oldestKey);
    }
  }

  void _handleNewClip(Map<String, String> control, String dataPart) {
    final rawFmt = (control['fmt'] ?? control['c'] ?? control['f'] ?? 'wav')
        .trim()
        .toLowerCase();
    final explicitId = _parseExplicitClipId(control['i']);
    final busId = _parseExplicitClipId(control['b']);
    if ((explicitId != null && explicitId < 0) ||
        (busId != null && busId < 0)) {
      return;
    }
    final clipId = explicitId ?? _allocateAutoId();
    _removePendingUpload(clipId);
    if (!_validFormats.contains(rawFmt)) return;
    _evictOldestUploadIfNeeded();

    final loopRaw = (control['l'] ?? '0').trim().toLowerCase();
    final startOffset = _parseOptionalDurationMs(control['s']) ?? Duration.zero;
    final pending = _PendingAudioUpload(
      clipId: clipId,
      format: rawFmt,
      volume: _parseBoundedDouble(
        control['v'],
        min: 0.0,
        max: 1.0,
        fallback: 1.0,
      ),
      pan: _parseBoundedDouble(
        control['p'],
        min: -1.0,
        max: 1.0,
        fallback: 0.0,
      ),
      loop: loopRaw == '1' || loopRaw == 'true',
      startOffset: startOffset,
      busId: busId,
    );
    _pendingUploads[clipId] = pending;
    _processClipChunk(pending, control, dataPart);
  }

  void _processClipChunk(
    _PendingAudioUpload pending,
    Map<String, String> control,
    String dataPart,
  ) {
    _lastActiveUploadId = pending.clipId;
    _appendChunk(pending, dataPart);

    final isMore = (int.tryParse(control['m'] ?? '0') ?? 0) == 1;
    if (isMore) return;

    _removePendingUpload(pending.clipId);
    if (pending.overflowed) return;
    final decoded = _decodeBase64Bounded(pending.base64Data.toString());
    if (decoded == null) return;
    onAudioEvent?.call(
      TerminalClipAudioEvent(
        clipId: pending.clipId,
        format: pending.format,
        bytes: decoded,
        volume: pending.volume,
        pan: pending.pan,
        loop: pending.loop,
        startOffset: pending.startOffset,
        busId: pending.busId,
      ),
    );
    if (pending.hasDeferredTransportUpdate) {
      onAudioEvent?.call(
        TerminalUpdateAudioEvent(
          clipId: pending.clipId,
          seekPosition: pending.seekPosition,
          paused: pending.paused,
          speed: pending.speed,
          preservePitch: pending.preservePitch,
          fadeVolumeTarget: pending.fadeVolumeTarget,
          fadeVolumeDuration: pending.fadeVolumeDuration,
          fadeSpeedTarget: pending.fadeSpeedTarget,
          fadeSpeedDuration: pending.fadeSpeedDuration,
          scheduleStopDuration: pending.scheduleStopDuration,
        ),
      );
    }
  }

  void _appendChunk(_PendingAudioUpload pending, String dataPart) {
    if (pending.overflowed || dataPart.isEmpty) return;
    final clean = dataPart.replaceAll(_whitespaceRegex, '');
    if (clean.isEmpty) return;
    final nextChars = pending.charCount + clean.length;
    final nextTotal = _totalPendingBase64 + clean.length;
    if (nextChars > _maxBase64PerUpload || nextTotal > _maxTotalPendingBase64) {
      _totalPendingBase64 -= pending.charCount;
      pending.charCount = 0;
      pending.base64Data.clear();
      pending.overflowed = true;
      return;
    }
    pending.base64Data.write(clean);
    pending.charCount = nextChars;
    _totalPendingBase64 = nextTotal;
  }

  static Uint8List? _decodeBase64Bounded(String raw) {
    if (raw.isEmpty || raw.length > _maxBase64PerUpload) return null;
    try {
      final decoded = base64Decode(raw);
      if (decoded.isEmpty || decoded.length > maxClipBytes) return null;
      return decoded;
    } on Object {
      return null;
    }
  }
}
