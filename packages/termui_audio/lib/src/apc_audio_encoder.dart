import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:clock/clock.dart';

import 'apc_fs_stub.dart' if (dart.library.io) 'apc_fs_io.dart';
import 'api/audio_engine.dart';
import 'api/audio_types.dart';
import 'utils/audio_dsp_utils.dart';

/// Encodes audio playback commands into chunked `ESC _ A <k=v,...>;<base64> ST`
/// APC escape sequences safe for PTY transport across native and Web targets.
abstract final class ApcAudioEncoder {
  /// Maximum decoded byte length permitted for an APC audio clip (`2 MiB`).
  static const int maxClipBytes = 2 * 1024 * 1024;

  /// Base64 payload characters per emitted chunk (`4096` chars per APC frame).
  static const int chunkBase64Chars = 4096;

  /// Wire audio container formats accepted by [encodeClip].
  static const Set<String> supportedFormats = {'wav', 'ogg', 'mp3'};

  /// Converts a [WaveForm] enum value into its canonical wire name.
  ///
  /// Maps [WaveForm.sin] to `'sine'`.
  static String waveformToWire(WaveForm shape) => switch (shape) {
    WaveForm.sin => 'sine',
    WaveForm.square => 'square',
    WaveForm.saw => 'saw',
    WaveForm.triangle => 'triangle',
    WaveForm.bounce => 'bounce',
    WaveForm.jaws => 'jaws',
    WaveForm.humps => 'humps',
    WaveForm.fsquare => 'fsquare',
    WaveForm.fsaw => 'fsaw',
  };

  /// Parses a wire waveform name into a [WaveForm], or `null` if unknown.
  ///
  /// Maps `'sine'` (and `'sin'`) to [WaveForm.sin].
  static WaveForm? waveformFromWire(String name) =>
      switch (name.trim().toLowerCase()) {
        'sine' || 'sin' => WaveForm.sin,
        'square' => WaveForm.square,
        'saw' => WaveForm.saw,
        'triangle' => WaveForm.triangle,
        'bounce' => WaveForm.bounce,
        'jaws' => WaveForm.jaws,
        'humps' => WaveForm.humps,
        'fsquare' => WaveForm.fsquare,
        'fsaw' => WaveForm.fsaw,
        _ => null,
      };

  static double _clampUnit(double value, double fallback) =>
      value.isFinite ? value.clamp(0.0, 1.0).toDouble() : fallback;

  static double _clampPan(double pan) =>
      pan.isFinite ? pan.clamp(-1.0, 1.0).toDouble() : 0.0;

  static String _formatFloat(double value) {
    final fixed = value.toStringAsFixed(4);
    if (!fixed.contains('.')) return fixed;
    var end = fixed.length;
    while (end > 0 && fixed.codeUnitAt(end - 1) == 0x30) {
      end--;
    }
    if (end > 0 && fixed.codeUnitAt(end - 1) == 0x2E) {
      end--;
    }
    final result = fixed.substring(0, end);
    return result == '-0' ? '0' : result;
  }

  /// Encodes a synthetic tone synthesis APC command (`ESC _ A a=tone,... ST`).
  static String encodeTone({
    WaveForm waveform = WaveForm.sin,
    required double frequencyHz,
    required Duration duration,
    double volume = 0.8,
    double pan = 0.0,
  }) {
    if (!frequencyHz.isFinite || frequencyHz <= 0 || frequencyHz > 24000.0) {
      throw ArgumentError.value(
        frequencyHz,
        'frequencyHz',
        'Must be in (0, 24000.0]',
      );
    }
    if (duration.isNegative || duration > const Duration(seconds: 60)) {
      throw ArgumentError.value(duration, 'duration', 'Must be in [0, 60s]');
    }
    final wireWaveform = waveformToWire(waveform);
    final freqStr = _formatFloat(frequencyHz);
    final durationMs = duration.inMicroseconds / 1000.0;
    final durStr = _formatFloat(durationMs);
    final volStr = _formatFloat(_clampUnit(volume, 0.8));
    final panStr = _formatFloat(_clampPan(pan));
    return '\x1b_Aa=tone,w=$wireWaveform,f=$freqStr,d=$durStr,'
        'v=$volStr,p=$panStr;\x1b\\';
  }

  /// Encodes an in-memory audio clip into chunked `m=1`/`m=0` APC frames.
  ///
  /// Splits base64 output at [chunkSize] characters (default `4096`) so even
  /// `2 MiB` clips stay well under `AnsiParser._maxApcLength`.
  static List<String> encodeClip({
    required int clipId,
    required String format,
    required Uint8List bytes,
    double volume = 1.0,
    double pan = 0.0,
    bool loop = false,
    int chunkSize = chunkBase64Chars,
  }) {
    if (clipId <= 0) {
      throw ArgumentError.value(clipId, 'clipId', 'Must be > 0');
    }
    final normalizedFmt = format.trim().toLowerCase();
    if (!supportedFormats.contains(normalizedFmt)) {
      throw ArgumentError.value(
        format,
        'format',
        'Expected one of $supportedFormats',
      );
    }
    if (bytes.isEmpty || bytes.length > maxClipBytes) {
      throw RangeError.range(bytes.length, 1, maxClipBytes, 'bytes.length');
    }
    final step = math.max(4, chunkSize);
    final encoded = base64Encode(bytes);
    final volStr = _formatFloat(_clampUnit(volume, 1.0));
    final panStr = _formatFloat(_clampPan(pan));
    final loopFlag = loop ? 1 : 0;

    final frames = <String>[];
    for (var offset = 0; offset < encoded.length; offset += step) {
      final end = math.min(offset + step, encoded.length);
      final chunk = encoded.substring(offset, end);
      final more = end < encoded.length ? 1 : 0;
      if (offset == 0) {
        frames.add(
          '\x1b_Aa=clip,i=$clipId,fmt=$normalizedFmt,'
          'v=$volStr,p=$panStr,l=$loopFlag,m=$more;$chunk\x1b\\',
        );
      } else {
        frames.add('\x1b_Ai=$clipId,m=$more;$chunk\x1b\\');
      }
    }
    return frames;
  }

  /// Encodes an APC live voice update command (`ESC _ A a=update,... ST`).
  static String encodeUpdate({
    required int clipId,
    double? volume,
    double? pan,
  }) {
    if (clipId <= 0 || clipId > 0x7FFFFFFF) {
      throw ArgumentError.value(clipId, 'clipId', 'Must be in 1..0x7FFFFFFF');
    }
    final hasVolume = volume != null && volume.isFinite;
    final hasPan = pan != null && pan.isFinite;
    if (!hasVolume && !hasPan) {
      throw ArgumentError('At least one finite volume or pan must be provided');
    }
    final buf = StringBuffer('\x1b_Aa=update,i=$clipId');
    if (hasVolume) {
      buf.write(',v=${_formatFloat(_clampUnit(volume, 1.0))}');
    }
    if (hasPan) {
      buf.write(',p=${_formatFloat(_clampPan(pan))}');
    }
    buf.write(';\x1b\\');
    return buf.toString();
  }

  /// Encodes an APC stop command for [clipId] (or all active clips if `null`).
  static String encodeStop({int? clipId}) {
    if (clipId != null && clipId > 0) {
      return '\x1b_Aa=stop,i=$clipId;\x1b\\';
    }
    return '\x1b_Aa=stop;\x1b\\';
  }
}

sealed class _PtyAudioBuffer implements AudioBuffer {
  @override
  final int hash;

  const _PtyAudioBuffer(this.hash);
}

final class _PtyWaveformBuffer extends _PtyAudioBuffer {
  final WaveForm shape;
  final double frequency;

  const _PtyWaveformBuffer(super.hash, this.shape, this.frequency);
}

final class _PtyClipBuffer extends _PtyAudioBuffer {
  final String format;
  final Uint8List bytes;
  final Duration duration;

  const _PtyClipBuffer(super.hash, this.format, this.bytes, this.duration);
}

final class _PtyAudioBus implements AudioBus {
  @override
  final int id;
  final void Function(double) _onVolume;
  double volume = 1.0;

  _PtyAudioBus(this.id, this._onVolume);

  @override
  void setVolume(double value) {
    volume = value.isFinite ? value.clamp(0.0, 1.0).toDouble() : 1.0;
    _onVolume(volume);
  }
}

final class _ActivePtyVoice {
  final int id;
  _PtyAudioBuffer? buffer;
  final Completer<void> completer;
  final bool loop;
  final int? clipId;
  double volume;
  double pan = 0.0;
  double posX = 0.0;
  double posY = 0.0;
  double posZ = 0.0;
  double minDistance = 1.0;
  double maxDistance = 1000000.0;
  AttenuationModel attenuationModel = AttenuationModel.none;
  double attenuationRolloff = 1.0;
  String? emittedVolStr;
  String? emittedPanStr;
  bool emitted;
  Duration? scheduledDuration;
  DateTime? startedAt;
  Duration bufferDuration = Duration.zero;
  Timer? stopTimer;

  _ActivePtyVoice({
    required this.id,
    required this.buffer,
    required this.completer,
    required this.loop,
    required this.clipId,
    required this.volume,
    required this.emitted,
  });
}

/// Pure-Dart [TermuiAudioEngine] that serializes audio synthesis and clip
/// playback into `ESC _ A` APC frames written through [writeEscape].
final class PtyApcAudioEngine implements TermuiAudioEngine {
  /// Callback receiving each complete `ESC _ A ... ST` escape sequence.
  final void Function(String sequence) writeEscape;

  /// Fallback duration emitted when playing a waveform without [scheduleStop].
  final Duration defaultToneDuration;

  int _nextBufferId = 1;
  int _nextVoiceId = 1;
  int _nextBusId = 1;
  bool _disposed = false;
  final Map<int, _PtyAudioBuffer> _buffers = {};
  final Map<int, _PtyAudioBus> _buses = {};
  final Map<int, _ActivePtyVoice> _voices = {};
  final Set<int> _autoEvictedClipIds = {};

  final Future<Uint8List> Function(String path)? _readFileBytes;
  final Clock? _clockOverride;

  /// Number of currently tracked active or paused voices.
  int get activeVoiceCount => _voices.length;

  /// Creates an APC-backed [TermuiAudioEngine] emitting via [writeEscape].
  PtyApcAudioEngine(
    this.writeEscape, {
    this.defaultToneDuration = const Duration(milliseconds: 250),
    Future<Uint8List> Function(String path)? readFileBytes,
    Clock? clock,
  }) : _readFileBytes = readFileBytes ?? createDefaultApcFileReader(),
       _clockOverride = clock;

  Clock get _clock => _clockOverride ?? clock;

  @override
  Future<void> init({bool enableVisualization = true}) async {}

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final voice in _voices.values) {
      voice.stopTimer?.cancel();
      voice.stopTimer = null;
      voice.buffer = null;
      if (!voice.completer.isCompleted) {
        voice.completer.complete();
      }
    }
    _voices.clear();
    _autoEvictedClipIds.clear();
    _buffers.clear();
    _buses.clear();
  }

  @override
  Future<AudioBuffer> loadFile(
    String path, {
    bool stream = false,
    LoadProgressCallback? onProgress,
  }) async {
    final bytes = await loadFileBytes(path);
    onProgress?.call(1.0);
    return loadMem(path, bytes, stream: stream);
  }

  @override
  Future<Uint8List> loadFileBytes(String path) {
    final reader = _readFileBytes;
    if (reader == null) {
      throw UnsupportedError(
        'PtyApcAudioEngine does not read local files on this platform',
      );
    }
    return reader(path);
  }

  @override
  Future<AudioBuffer> loadUrl(String url, {LoadProgressCallback? onProgress}) =>
      throw UnsupportedError('PtyApcAudioEngine does not load URLs');

  @override
  Future<AudioBuffer> loadWaveform(
    WaveForm shape,
    double frequency, {
    bool usePcmFallback = false,
  }) async {
    final id = _nextBufferId++;
    final AudioBuffer buf;
    if (usePcmFallback) {
      final wavBytes = generateWaveformPcmWav(
        shape: shape,
        frequency: frequency,
        duration: defaultToneDuration,
      );
      buf = _PtyClipBuffer(
        id,
        'wav',
        wavBytes,
        _estimateClipDuration('wav', wavBytes),
      );
    } else {
      buf = _PtyWaveformBuffer(id, shape, frequency);
    }
    _buffers[id] = buf as _PtyAudioBuffer;
    return buf;
  }

  @override
  Future<AudioBuffer> loadMem(
    String pathId,
    Uint8List bytes, {
    bool stream = false,
  }) async {
    if (bytes.isEmpty || bytes.length > ApcAudioEncoder.maxClipBytes) {
      throw RangeError.range(
        bytes.length,
        1,
        ApcAudioEncoder.maxClipBytes,
        'bytes.length',
      );
    }
    final format = _detectClipFormat(pathId, bytes);
    final copy = Uint8List.fromList(bytes);
    final id = _nextBufferId++;
    final buf = _PtyClipBuffer(
      id,
      format,
      copy,
      _estimateClipDuration(format, copy),
    );
    _buffers[id] = buf;
    return buf;
  }

  static bool _matchesAscii(Uint8List bytes, int offset, String tag) {
    if (offset < 0 || offset + tag.length > bytes.length) return false;
    for (var i = 0; i < tag.length; i++) {
      if (bytes[offset + i] != tag.codeUnitAt(i)) return false;
    }
    return true;
  }

  static Duration _estimateClipDuration(String format, Uint8List bytes) =>
      switch (format) {
        'wav' => _estimateWavDuration(bytes),
        'ogg' => _estimateOggDuration(bytes),
        _ => Duration.zero,
      };

  static int _readWavByteRate(ByteData bd, int dataStart) {
    final byteRate = bd.getUint32(dataStart + 8, Endian.little);
    if (byteRate > 0) return byteRate;
    final channels = bd.getUint16(dataStart + 2, Endian.little);
    final sampleRate = bd.getUint32(dataStart + 4, Endian.little);
    final bitsPerSample = bd.getUint16(dataStart + 14, Endian.little);
    return (sampleRate * channels * bitsPerSample) ~/ 8;
  }

  static Duration _estimateWavDuration(Uint8List bytes) {
    if (bytes.length < 44 ||
        !_matchesAscii(bytes, 0, 'RIFF') ||
        !_matchesAscii(bytes, 8, 'WAVE')) {
      return Duration.zero;
    }
    final bd = ByteData.sublistView(bytes);
    var effectiveByteRate = 0;
    var availData = 0;
    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final chunkSize = bd.getUint32(offset + 4, Endian.little);
      final dataStart = offset + 8;
      if (chunkSize >= 16 &&
          dataStart + 16 <= bytes.length &&
          _matchesAscii(bytes, offset, 'fmt ')) {
        effectiveByteRate = _readWavByteRate(bd, dataStart);
      } else if (_matchesAscii(bytes, offset, 'data')) {
        availData = math.min(chunkSize, bytes.length - dataStart);
      }
      if (effectiveByteRate > 0 && availData > 0) {
        return Duration(
          microseconds: (availData * 1000000.0 / effectiveByteRate).round(),
        );
      }
      final next = dataStart + chunkSize + (chunkSize.isOdd ? 1 : 0);
      if (next <= offset) break;
      offset = next;
    }
    return Duration.zero;
  }

  static ({int serial, int sampleRate, int preSkip})? _parseOggHeader(
    Uint8List bytes,
    ByteData bd,
  ) {
    if (bytes.length < 27 ||
        !_matchesAscii(bytes, 0, 'OggS') ||
        bytes[4] != 0) {
      return null;
    }
    final segs = bytes[26];
    final pktOffset = 27 + segs;
    if (pktOffset > bytes.length) return null;
    var pktLen = 0;
    for (var i = 0; i < segs; i++) {
      final seg = bytes[27 + i];
      pktLen += seg;
      if (seg < 255) break;
    }
    pktLen = math.min(pktLen, bytes.length - pktOffset);
    final serial = bd.getUint32(14, Endian.little);
    if (pktLen >= 16 &&
        bytes[pktOffset] == 0x01 &&
        _matchesAscii(bytes, pktOffset + 1, 'vorbis')) {
      return (
        serial: serial,
        sampleRate: bd.getUint32(pktOffset + 12, Endian.little),
        preSkip: 0,
      );
    }
    if (pktLen >= 19 && _matchesAscii(bytes, pktOffset, 'OpusHead')) {
      return (
        serial: serial,
        sampleRate: 48000,
        preSkip: bd.getUint16(pktOffset + 10, Endian.little),
      );
    }
    return null;
  }

  static int? _readValidOggPageEnd(Uint8List bytes, int pos) {
    if (!_matchesAscii(bytes, pos, 'OggS') ||
        bytes[pos + 4] != 0 ||
        (bytes[pos + 5] & 0xF8) != 0) {
      return null;
    }
    final segs = bytes[pos + 26];
    final headerEnd = pos + 27 + segs;
    if (headerEnd > bytes.length) return null;
    var bodyLen = 0;
    for (var i = 0; i < segs; i++) {
      bodyLen += bytes[pos + 27 + i];
    }
    final pageEnd = headerEnd + bodyLen;
    if (pageEnd == bytes.length) return pageEnd;
    if (pageEnd + 4 <= bytes.length && _matchesAscii(bytes, pageEnd, 'OggS')) {
      return pageEnd;
    }
    return null;
  }

  static Duration _granuleToDuration(
    double granule,
    int preSkip,
    int sampleRate,
  ) {
    final samples = granule - preSkip;
    if (samples <= 0 || sampleRate <= 0) return Duration.zero;
    return Duration(microseconds: (samples * 1000000.0 / sampleRate).round());
  }

  static Duration _estimateOggDuration(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    final header = _parseOggHeader(bytes, bd);
    if (header == null) return Duration.zero;
    final minPos = math.max(0, bytes.length - 65307);
    double? fallbackGranule;
    for (var pos = bytes.length - 27; pos >= minPos; pos--) {
      if (_readValidOggPageEnd(bytes, pos) == null) continue;
      if (bd.getUint32(pos + 14, Endian.little) != header.serial) {
        return Duration.zero;
      }
      final high = bd.getInt32(pos + 10, Endian.little);
      if (high < 0) continue;
      final granule =
          high * 4294967296.0 + bd.getUint32(pos + 6, Endian.little);
      if ((bytes[pos + 5] & 0x04) != 0) {
        return _granuleToDuration(granule, header.preSkip, header.sampleRate);
      }
      fallbackGranule ??= granule;
    }
    if (fallbackGranule == null) return Duration.zero;
    return _granuleToDuration(
      fallbackGranule,
      header.preSkip,
      header.sampleRate,
    );
  }

  static String _detectClipFormat(String pathId, Uint8List bytes) {
    final lower = pathId.toLowerCase();
    for (final ext in ApcAudioEncoder.supportedFormats) {
      if (lower.endsWith('.$ext') || lower == ext) return ext;
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46) {
      return 'wav';
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x4F &&
        bytes[1] == 0x67 &&
        bytes[2] == 0x67 &&
        bytes[3] == 0x53) {
      return 'ogg';
    }
    if (bytes.length >= 3 &&
        ((bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) ||
            (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0))) {
      return 'mp3';
    }
    throw ArgumentError.value(
      pathId,
      'pathId',
      'Unable to infer audio format (expected wav, ogg, or mp3)',
    );
  }

  @override
  Future<AudioBuffer> createBufferStream({
    int maxBufferSize = 4 * 1024 * 1024,
    bool releaseConsumed = false,
    Duration bufferingTimeNeeds = const Duration(milliseconds: 500),
    int sampleRate = 48000,
    int channels = 2,
  }) => throw UnsupportedError('PtyApcAudioEngine does not support streaming');

  @override
  void addStreamData(AudioBuffer buffer, Uint8List chunk) =>
      throw UnsupportedError('PtyApcAudioEngine does not support streaming');

  @override
  void setStreamEnded(AudioBuffer buffer) =>
      throw UnsupportedError('PtyApcAudioEngine does not support streaming');

  @override
  Future<void> disposeBuffer(AudioBuffer buffer) async {
    _buffers.remove(buffer.hash);
  }

  @override
  AudioVoice play(
    AudioBuffer buffer, {
    bool loop = false,
    AudioBus? bus,
    bool paused = false,
  }) {
    final resolved = _resolveBuffer(buffer);
    final voiceId = _nextVoiceId++;
    final busVol = (bus is _PtyAudioBus) ? bus.volume : 1.0;
    final clipId = resolved is _PtyClipBuffer ? voiceId : null;
    final state = _ActivePtyVoice(
      id: voiceId,
      buffer: resolved,
      completer: Completer<void>(),
      loop: loop,
      clipId: clipId,
      volume: busVol,
      emitted: !paused,
    );
    _voices[voiceId] = state;
    if (!paused) {
      try {
        _emitVoicePlayback(state, durationOverride: null);
      } catch (_) {
        state.stopTimer?.cancel();
        _voices.remove(voiceId);
        rethrow;
      }
    }
    return AudioVoice(voiceId, state.completer.future);
  }

  _PtyAudioBuffer _resolveBuffer(AudioBuffer buffer) {
    if (buffer is _PtyAudioBuffer) return buffer;
    final stored = _buffers[buffer.hash];
    if (stored != null) return stored;
    throw ArgumentError('Unknown AudioBuffer for PtyApcAudioEngine');
  }

  void _evictAndCompleteVoice(int voiceId) {
    final state = _voices.remove(voiceId);
    if (state == null) return;
    state.stopTimer = null;
    state.buffer = null;
    if (state.emitted &&
        state.clipId != null &&
        state.bufferDuration <= Duration.zero) {
      if (_autoEvictedClipIds.length >= 256) {
        _autoEvictedClipIds.remove(_autoEvictedClipIds.first);
      }
      _autoEvictedClipIds.add(state.clipId!);
    }
    if (!state.completer.isCompleted) {
      state.completer.complete();
    }
  }

  static double _computeAttenuation(_ActivePtyVoice state) {
    if (state.attenuationModel == AttenuationModel.none) return 1.0;
    final rawDist = math.sqrt(
      state.posX * state.posX +
          state.posY * state.posY +
          state.posZ * state.posZ,
    );
    final minD = math.max(0.0, state.minDistance);
    final maxD = math.max(minD, state.maxDistance);
    final d = rawDist.clamp(minD, maxD).toDouble();
    final r = state.attenuationRolloff;
    if (state.attenuationModel == AttenuationModel.linearDistance) {
      return maxD <= minD
          ? 1.0
          : (1.0 - r * (d - minD) / (maxD - minD)).clamp(0.0, 1.0).toDouble();
    }
    if (minD <= 0.0) return d <= 0.0 ? 1.0 : 0.0;
    final denom = minD + r * (d - minD);
    final rawFactor = state.attenuationModel == AttenuationModel.inverseDistance
        ? (denom <= 0.0 ? 1.0 : minD / denom)
        : math.pow(d / minD, -r).toDouble();
    return rawFactor.clamp(0.0, 1.0).toDouble();
  }

  static double _effectiveVolume(_ActivePtyVoice state) =>
      (state.volume * _computeAttenuation(state)).clamp(0.0, 1.0).toDouble();

  void _syncEmittedVoice(_ActivePtyVoice state) {
    final clipId = state.clipId;
    if (_disposed || !state.emitted || clipId == null || clipId > 0x7FFFFFFF) {
      return;
    }
    final effVol = _effectiveVolume(state);
    final clampedPan = ApcAudioEncoder._clampPan(state.pan);
    final volStr = ApcAudioEncoder._formatFloat(effVol);
    final panStr = ApcAudioEncoder._formatFloat(clampedPan);
    final volChanged = volStr != state.emittedVolStr;
    final panChanged = panStr != state.emittedPanStr;
    if (!volChanged && !panChanged) {
      return;
    }
    state.emittedVolStr = volStr;
    state.emittedPanStr = panStr;
    writeEscape(
      ApcAudioEncoder.encodeUpdate(
        clipId: clipId,
        volume: volChanged ? effVol : null,
        pan: panChanged ? clampedPan : null,
      ),
    );
  }

  void _emitVoicePlayback(
    _ActivePtyVoice voice, {
    required Duration? durationOverride,
  }) {
    final buffer = voice.buffer;
    if (buffer == null) return;
    try {
      final effVol = _effectiveVolume(voice);
      final clampedPan = ApcAudioEncoder._clampPan(voice.pan);
      final Duration effectiveDuration;
      switch (buffer) {
        case _PtyWaveformBuffer(:final shape, :final frequency):
          effectiveDuration = durationOverride ?? defaultToneDuration;
          writeEscape(
            ApcAudioEncoder.encodeTone(
              waveform: shape,
              frequencyHz: frequency,
              duration: effectiveDuration,
              volume: effVol,
              pan: clampedPan,
            ),
          );
        case _PtyClipBuffer(:final format, :final bytes, :final duration):
          effectiveDuration = durationOverride ?? duration;
          voice.emittedVolStr = ApcAudioEncoder._formatFloat(effVol);
          voice.emittedPanStr = ApcAudioEncoder._formatFloat(clampedPan);
          final frames = ApcAudioEncoder.encodeClip(
            clipId: voice.clipId ?? voice.id,
            format: format,
            bytes: bytes,
            volume: effVol,
            pan: clampedPan,
            loop: voice.loop,
          );
          for (final frame in frames) {
            writeEscape(frame);
          }
      }
      voice.startedAt = _clock.now();
      voice.bufferDuration = effectiveDuration;
      if (!_disposed && !voice.loop && voice.stopTimer == null) {
        voice.stopTimer = Timer(
          effectiveDuration,
          () => _evictAndCompleteVoice(voice.id),
        );
      }
    } finally {
      voice.buffer = null;
    }
  }

  @override
  void stop(AudioVoice voice) {
    final state = _voices.remove(voice.id);
    if (state == null) {
      if (!_disposed && _autoEvictedClipIds.remove(voice.id)) {
        writeEscape(ApcAudioEncoder.encodeStop(clipId: voice.id));
      }
      return;
    }
    _autoEvictedClipIds.remove(voice.id);
    state.stopTimer?.cancel();
    state.stopTimer = null;
    state.buffer = null;
    if (state.emitted && state.clipId != null) {
      writeEscape(ApcAudioEncoder.encodeStop(clipId: state.clipId));
    }
    if (!state.completer.isCompleted) {
      state.completer.complete();
    }
  }

  @override
  void setVoiceVolume(AudioVoice voice, double volume) {
    final state = _voices[voice.id];
    if (state == null || !volume.isFinite) return;
    state.volume = volume.clamp(0.0, 1.0).toDouble();
    _syncEmittedVoice(state);
  }

  @override
  void setVoicePan(AudioVoice voice, double pan) {
    final state = _voices[voice.id];
    if (state == null || !pan.isFinite) return;
    state.pan = pan.clamp(-1.0, 1.0).toDouble();
    _syncEmittedVoice(state);
  }

  /// Resumes a paused [voice] by emitting its APC frame. Pausing an already
  /// emitted voice is a no-op because the APC wire format has no pause frame.
  @override
  void setPaused(AudioVoice voice, bool paused) {
    if (_disposed) return;
    final state = _voices[voice.id];
    if (state == null || paused || state.emitted) return;
    state.emitted = true;
    _emitVoicePlayback(state, durationOverride: state.scheduledDuration);
  }

  static double _spatialPan(double x, double y, double z) {
    if (!x.isFinite || !y.isFinite || !z.isFinite) return 0.0;
    final dist = math.sqrt(x * x + y * y + z * z);
    return (x / math.max(1.0, dist)).clamp(-1.0, 1.0).toDouble();
  }

  @override
  AudioVoice play3d(AudioBuffer buffer, double x, double y, double z) {
    final voice = play(buffer, paused: true);
    final state = _voices[voice.id];
    if (state != null && x.isFinite && y.isFinite && z.isFinite) {
      state.posX = x;
      state.posY = y;
      state.posZ = z;
      state.pan = _spatialPan(x, y, z);
    }
    setPaused(voice, false);
    return voice;
  }

  /// Updates the 3D source coordinates, stereo pan, and distance attenuation for [voice].
  @override
  void set3dSourceParameters(
    AudioVoice voice,
    double x,
    double y,
    double z, {
    double vx = 0.0,
    double vy = 0.0,
    double vz = 0.0,
  }) {
    final state = _voices[voice.id];
    if (state == null || !x.isFinite || !y.isFinite || !z.isFinite) return;
    state.posX = x;
    state.posY = y;
    state.posZ = z;
    state.pan = _spatialPan(x, y, z);
    _syncEmittedVoice(state);
  }

  @override
  void set3dSourceMinMaxDistance(
    AudioVoice voice,
    double minDistance,
    double maxDistance,
  ) {
    final state = _voices[voice.id];
    if (state == null || !minDistance.isFinite || !maxDistance.isFinite) {
      return;
    }
    state.minDistance = minDistance;
    state.maxDistance = maxDistance;
    _syncEmittedVoice(state);
  }

  @override
  void set3dSourceAttenuation(
    AudioVoice voice,
    AttenuationModel attenuationModel,
    double attenuationRolloffFactor,
  ) {
    final state = _voices[voice.id];
    if (state == null || !attenuationRolloffFactor.isFinite) return;
    state.attenuationModel = attenuationModel;
    state.attenuationRolloff = attenuationRolloffFactor;
    _syncEmittedVoice(state);
  }

  @override
  Duration getBufferDuration(AudioBuffer buffer) {
    final stored = _buffers[buffer.hash];
    if (stored == null) return Duration.zero;
    return switch (stored) {
      _PtyClipBuffer(:final duration) => duration,
      _PtyWaveformBuffer() => defaultToneDuration,
    };
  }

  @override
  Duration getVoicePosition(AudioVoice voice) {
    final state = _voices[voice.id];
    final startedAt = state?.startedAt;
    if (state == null || !state.emitted || startedAt == null) {
      return Duration.zero;
    }
    final elapsed = _clock.now().difference(startedAt);
    if (elapsed.isNegative) return Duration.zero;
    final dur = state.bufferDuration;
    if (dur <= Duration.zero) return elapsed;
    if (state.loop) {
      return Duration(
        microseconds: elapsed.inMicroseconds % dur.inMicroseconds,
      );
    }
    return elapsed > dur ? dur : elapsed;
  }

  /// No-op: the APC audio wire format has no seek command, so the local
  /// playhead remains truthful to remote playback.
  @override
  void seek(AudioVoice voice, Duration position) {}

  @override
  void setRelativePlaySpeed(
    AudioVoice voice,
    double speed, {
    bool preservePitch = false,
  }) {}

  @override
  Stream<Duration> getVoicePositionStream(
    AudioVoice voice, {
    Duration interval = const Duration(milliseconds: 50),
  }) => createVoicePositionStream(
    voice: voice,
    isVoiceActive: _voices.containsKey,
    getPosition: getVoicePosition,
    interval: interval,
  );

  @override
  void fadeRelativePlaySpeed(
    AudioVoice voice,
    double speed,
    Duration duration,
  ) {}

  @override
  void fadeVolume(AudioVoice voice, double targetVolume, Duration duration) {}

  @override
  void scheduleStop(AudioVoice voice, Duration duration) {
    if (_disposed) return;
    final state = _voices[voice.id];
    if (state == null) return;
    state.scheduledDuration = duration;
    if (state.emitted) {
      state.bufferDuration = duration;
    }
    state.stopTimer?.cancel();
    state.stopTimer = Timer(duration, () => stop(voice));
  }

  @override
  int createFilter(FilterType type) => type.index;

  @override
  void attachFilterToBus(AudioBus bus, int filterId) {}

  @override
  void setFilterParameter(
    AudioBus bus,
    int filterId,
    int paramId,
    double value,
  ) {}

  @override
  double getFilterParameter(AudioBus bus, int filterId, int paramId) => 0.0;

  @override
  void fadeFilterParameter(
    AudioBus bus,
    int filterId,
    int paramId,
    double targetValue,
    Duration duration,
  ) {}

  @override
  AudioVoice playSprite(
    AudioBuffer buffer, {
    required Duration start,
    required Duration duration,
    AudioBus? bus,
  }) {
    final resolved = _resolveBuffer(buffer);
    final voiceId = _nextVoiceId++;
    final busVol = (bus is _PtyAudioBus) ? bus.volume : 1.0;
    final clipId = resolved is _PtyClipBuffer ? voiceId : null;
    final state = _ActivePtyVoice(
      id: voiceId,
      buffer: resolved,
      completer: Completer<void>(),
      loop: false,
      clipId: clipId,
      volume: busVol,
      emitted: true,
    );
    _voices[voiceId] = state;
    final voice = AudioVoice(voiceId, state.completer.future);
    scheduleStop(voice, duration);
    try {
      _emitVoicePlayback(state, durationOverride: duration);
    } catch (_) {
      state.stopTimer?.cancel();
      _voices.remove(voiceId);
      rethrow;
    }
    return voice;
  }

  @override
  Future<void> playSpriteSequence(
    AudioBuffer buffer,
    List<SpriteSegment> segments, {
    AudioBus? bus,
  }) async {
    for (final segment in segments) {
      if (_disposed) break;
      final voice = playSprite(
        buffer,
        start: segment.start,
        duration: segment.duration,
        bus: bus,
      );
      await voice.completed;
    }
  }

  @override
  AudioBus createBus() {
    final id = _nextBusId++;
    final bus = _PtyAudioBus(id, (_) {});
    _buses[id] = bus;
    return bus;
  }

  @override
  void destroyBus(AudioBus bus) {
    _buses.remove(bus.id);
  }

  @override
  Float32List getWaveform([Float32List? outBuffer]) {
    if (outBuffer != null && outBuffer.length < 256) {
      throw ArgumentError('outBuffer must be at least 256 elements long.');
    }
    return outBuffer ?? Float32List(256);
  }
}
