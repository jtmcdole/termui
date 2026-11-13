import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:clock/clock.dart';

import 'apc_fs_stub.dart' if (dart.library.io) 'apc_fs_io.dart';
import 'api/audio_engine.dart';
import 'api/audio_types.dart';
import 'utils/audio_dsp_utils.dart';
import 'utils/mp3_duration.dart';

extension on Duration {
  String letMs(String Function(double ms) fmt) => fmt(inMicroseconds / 1000.0);
}

/// Encodes audio playback commands into chunked `ESC _ A <k=v,...>;<base64> ST`
/// APC escape sequences safe for PTY transport across native and Web targets.
abstract final class ApcAudioEncoder {
  /// Maximum decoded byte length permitted for an APC audio clip (`2 MiB`).
  static const int maxClipBytes = 2 * 1024 * 1024;

  /// Maximum resident/total byte length permitted for an APC audio stream (`16 MiB`).
  static const int maxStreamBytes = 16 * 1024 * 1024;

  /// Base64 payload characters per emitted chunk (`4096` chars per APC frame).
  static const int chunkBase64Chars = 4096;

  /// Wire audio container formats accepted by [encodeClip].
  static const Set<String> supportedFormats = {'wav', 'ogg', 'mp3'};

  /// Wire operations accepted by [encodeBus].
  static const Set<String> supportedBusOps = {
    'create',
    'destroy',
    'vol',
    'attach',
    'param',
    'fade',
  };

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

  static void _validateWireBusId(int busId) {
    if (busId <= 0 || busId > 0x7FFFFFFF) {
      throw ArgumentError.value(busId, 'busId', 'Must be in 1..0x7FFFFFFF');
    }
  }

  static void _validateWireId(int id, String name) {
    if (id <= 0 || id > 0x7FFFFFFF) {
      throw ArgumentError.value(id, name, 'Must be in 1..0x7FFFFFFF');
    }
  }

  static String _formatClipMeta({
    required double volume,
    required double pan,
    required bool loop,
    required Duration startOffset,
    required int? busId,
  }) {
    if (startOffset.isNegative) {
      throw ArgumentError.value(startOffset, 'startOffset', 'Must be >= 0');
    }
    if (busId != null) {
      _validateWireBusId(busId);
    }
    final volStr = _formatFloat(_clampUnit(volume, 1.0));
    final panStr = _formatFloat(_clampPan(pan));
    final loopFlag = loop ? 1 : 0;
    final startPart = startOffset > Duration.zero
        ? ',s=${_formatFloat(startOffset.inMicroseconds / 1000.0)}'
        : '';
    final busPart = busId != null ? ',b=$busId' : '';
    return 'v=$volStr,p=$panStr,l=$loopFlag$startPart$busPart';
  }

  /// Encodes a synthetic tone synthesis APC command (`ESC _ A a=tone,... ST`).
  static String encodeTone({
    WaveForm waveform = WaveForm.sin,
    required double frequencyHz,
    required Duration duration,
    double volume = 0.8,
    double pan = 0.0,
    int? busId,
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
    if (busId != null) {
      _validateWireBusId(busId);
    }
    final wireWaveform = waveformToWire(waveform);
    final freqStr = _formatFloat(frequencyHz);
    final durationMs = duration.inMicroseconds / 1000.0;
    final durStr = _formatFloat(durationMs);
    final volStr = _formatFloat(_clampUnit(volume, 0.8));
    final panStr = _formatFloat(_clampPan(pan));
    final busPart = busId != null ? ',b=$busId' : '';
    return '\x1b_Aa=tone,w=$wireWaveform,f=$freqStr,d=$durStr,'
        'v=$volStr,p=$panStr$busPart;\x1b\\';
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
    Duration startOffset = Duration.zero,
    int? busId,
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
    final meta = _formatClipMeta(
      volume: volume,
      pan: pan,
      loop: loop,
      startOffset: startOffset,
      busId: busId,
    );
    final step = math.max(4, chunkSize);
    final encoded = base64Encode(bytes);

    final frames = <String>[];
    for (var offset = 0; offset < encoded.length; offset += step) {
      final end = math.min(offset + step, encoded.length);
      final chunk = encoded.substring(offset, end);
      final more = end < encoded.length ? 1 : 0;
      if (offset == 0) {
        frames.add(
          '\x1b_Aa=clip,i=$clipId,fmt=$normalizedFmt,$meta,m=$more;$chunk\x1b\\',
        );
      } else {
        frames.add('\x1b_Ai=$clipId,m=$more;$chunk\x1b\\');
      }
    }
    return frames;
  }

  /// Encodes an APC stream-open command (`ESC _ A a=stream,op=open,... ST`).
  static String encodeStreamOpen({
    required int streamId,
    int maxBufferSize = 4 * 1024 * 1024,
    bool releaseConsumed = false,
    Duration bufferingTimeNeeds = const Duration(milliseconds: 500),
    int sampleRate = 48000,
    int channels = 2,
  }) {
    _validateWireId(streamId, 'streamId');
    if (maxBufferSize <= 0 || maxBufferSize > maxStreamBytes) {
      throw RangeError.range(maxBufferSize, 1, maxStreamBytes, 'maxBufferSize');
    }
    if (bufferingTimeNeeds.isNegative) {
      throw ArgumentError.value(
        bufferingTimeNeeds,
        'bufferingTimeNeeds',
        'Must be >= 0',
      );
    }
    if (sampleRate <= 0 || sampleRate > 384000) {
      throw ArgumentError.value(
        sampleRate,
        'sampleRate',
        'Must be in 1..384000',
      );
    }
    if (channels != 1 && channels != 2) {
      throw ArgumentError.value(channels, 'channels', 'Must be 1 or 2');
    }
    final rel = releaseConsumed ? 1 : 0;
    final bufMs = _formatFloat(bufferingTimeNeeds.inMicroseconds / 1000.0);
    return '\x1b_Aa=stream,op=open,s=$streamId,max=$maxBufferSize,'
        'rel=$rel,buf=$bufMs,sr=$sampleRate,ch=$channels;\x1b\\';
  }

  /// Encodes raw audio [bytes] into pass-through `4096`-char base64 `a=stream,op=chunk`
  /// frames with monotonic `seq` starting at [startSeq].
  static List<String> encodeStreamChunk({
    required int streamId,
    required Uint8List bytes,
    int startSeq = 0,
    int chunkSize = chunkBase64Chars,
  }) {
    _validateWireId(streamId, 'streamId');
    if (startSeq < 0) {
      throw ArgumentError.value(startSeq, 'startSeq', 'Must be >= 0');
    }
    if (bytes.isEmpty || bytes.length > maxStreamBytes) {
      throw RangeError.range(bytes.length, 1, maxStreamBytes, 'bytes.length');
    }
    final alignedChars = math.max(4, chunkSize - (chunkSize % 4));
    final rawStep = (alignedChars ~/ 4) * 3;
    final frames = <String>[];
    var seq = startSeq;
    for (var offset = 0; offset < bytes.length; offset += rawStep) {
      final end = math.min(offset + rawStep, bytes.length);
      final encoded = base64Encode(Uint8List.sublistView(bytes, offset, end));
      frames.add('\x1b_Aa=stream,op=chunk,s=$streamId,seq=$seq;$encoded\x1b\\');
      seq++;
    }
    return frames;
  }

  /// Encodes an APC stream-end command (`ESC _ A a=stream,op=end,s=<streamId>[,seq=<seq>]; ST`).
  static String encodeStreamEnd({required int streamId, int? seq}) {
    _validateWireId(streamId, 'streamId');
    if (seq != null && seq < 0) {
      throw ArgumentError.value(seq, 'seq', 'Must be >= 0');
    }
    final seqPart = seq != null ? ',seq=$seq' : '';
    return '\x1b_Aa=stream,op=end,s=$streamId$seqPart;\x1b\\';
  }

  /// Encodes an APC stream-backed clip play command (`ESC _ A a=clip,i=<clipId>,st=<streamId>,... ST`).
  static String encodeStreamPlay({
    required int clipId,
    required int streamId,
    double volume = 1.0,
    double pan = 0.0,
    bool loop = false,
    Duration startOffset = Duration.zero,
    int? busId,
  }) {
    _validateWireId(clipId, 'clipId');
    _validateWireId(streamId, 'streamId');
    final meta = _formatClipMeta(
      volume: volume,
      pan: pan,
      loop: loop,
      startOffset: startOffset,
      busId: busId,
    );
    return '\x1b_Aa=clip,i=$clipId,st=$streamId,$meta;\x1b\\';
  }

  static double _clampSpeed(double speed) =>
      speed.isFinite ? speed.clamp(0.125, 8.0).toDouble() : 1.0;

  static void _validateUpdatePair(
    double? target,
    Duration? duration,
    String name,
  ) {
    if ((target == null) != (duration == null)) {
      throw ArgumentError(
        '$name target and duration must both be provided or both null',
      );
    }
    if (duration != null && duration.isNegative) {
      throw ArgumentError.value(duration, '${name}Duration', 'Must be >= 0');
    }
    if (target != null && !target.isFinite) {
      throw ArgumentError.value(target, '${name}Target', 'Must be finite');
    }
  }

  static void _validateUpdateDuration(Duration? d, String name) {
    if (d != null && d.isNegative) {
      throw ArgumentError.value(d, name, 'Must be >= 0');
    }
  }

  static String? _formatFiniteField(
    double? value,
    double Function(double) clampFn,
  ) => (value != null && value.isFinite) ? _formatFloat(clampFn(value)) : null;

  static String? _formatFadeField(
    double? target,
    Duration? duration,
    double Function(double) clampFn,
  ) {
    if (target == null || duration == null) return null;
    return '${_formatFloat(clampFn(target))}:'
        '${_formatFloat(duration.inMicroseconds / 1000.0)}';
  }

  static void _appendUpdateFields(
    StringBuffer buf, {
    required double? volume,
    required double? pan,
    required Duration? seekPosition,
    required bool? paused,
    required double? speed,
    required bool? preservePitch,
    required double? fadeVolumeTarget,
    required Duration? fadeVolumeDuration,
    required double? fadeSpeedTarget,
    required Duration? fadeSpeedDuration,
    required Duration? scheduleStopDuration,
  }) {
    final entries = <(String, String?)>[
      ('v', _formatFiniteField(volume, (v) => _clampUnit(v, 1.0))),
      ('p', _formatFiniteField(pan, _clampPan)),
      ('s', seekPosition?.letMs((ms) => _formatFloat(ms))),
      ('pa', paused == null ? null : (paused ? '1' : '0')),
      ('sp', _formatFiniteField(speed, _clampSpeed)),
      ('pp', preservePitch == null ? null : (preservePitch ? '1' : '0')),
      (
        'fv',
        _formatFadeField(
          fadeVolumeTarget,
          fadeVolumeDuration,
          (v) => _clampUnit(v, 1.0),
        ),
      ),
      ('fs', _formatFadeField(fadeSpeedTarget, fadeSpeedDuration, _clampSpeed)),
      ('st', scheduleStopDuration?.letMs((ms) => _formatFloat(ms))),
    ];
    var wroteAny = false;
    for (final (key, val) in entries) {
      if (val == null) continue;
      buf.write(',$key=$val');
      wroteAny = true;
    }
    if (!wroteAny) {
      throw ArgumentError('At least one finite update parameter must be set');
    }
  }

  /// Encodes an APC live voice update command (`ESC _ A a=update,... ST`).
  static String encodeUpdate({
    required int clipId,
    double? volume,
    double? pan,
    Duration? seekPosition,
    bool? paused,
    double? speed,
    bool? preservePitch,
    double? fadeVolumeTarget,
    Duration? fadeVolumeDuration,
    double? fadeSpeedTarget,
    Duration? fadeSpeedDuration,
    Duration? scheduleStopDuration,
  }) {
    if (clipId <= 0 || clipId > 0x7FFFFFFF) {
      throw ArgumentError.value(clipId, 'clipId', 'Must be in 1..0x7FFFFFFF');
    }
    _validateUpdateDuration(seekPosition, 'seekPosition');
    _validateUpdateDuration(scheduleStopDuration, 'scheduleStopDuration');
    _validateUpdatePair(fadeVolumeTarget, fadeVolumeDuration, 'fadeVolume');
    _validateUpdatePair(fadeSpeedTarget, fadeSpeedDuration, 'fadeSpeed');

    final buf = StringBuffer('\x1b_Aa=update,i=$clipId');
    _appendUpdateFields(
      buf,
      volume: volume,
      pan: pan,
      seekPosition: seekPosition,
      paused: paused,
      speed: speed,
      preservePitch: preservePitch,
      fadeVolumeTarget: fadeVolumeTarget,
      fadeVolumeDuration: fadeVolumeDuration,
      fadeSpeedTarget: fadeSpeedTarget,
      fadeSpeedDuration: fadeSpeedDuration,
      scheduleStopDuration: scheduleStopDuration,
    );
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

  /// Encodes an APC mixing bus lifecycle or DSP filter command (`ESC _ A a=bus,... ST`).
  static String encodeBus({
    required String op,
    required int busId,
    int? filterId,
    int? paramId,
    double? value,
    Duration? duration,
  }) {
    if (!supportedBusOps.contains(op)) {
      throw ArgumentError.value(op, 'op', 'Expected one of $supportedBusOps');
    }
    _validateWireBusId(busId);
    final buf = StringBuffer('\x1b_Aa=bus,op=$op,b=$busId');
    _appendBusOpFields(
      buf,
      op: op,
      filterId: filterId,
      paramId: paramId,
      value: value,
      duration: duration,
    );
    buf.write(';\x1b\\');
    return buf.toString();
  }

  static void _appendBusOpFields(
    StringBuffer buf, {
    required String op,
    required int? filterId,
    required int? paramId,
    required double? value,
    required Duration? duration,
  }) {
    switch (op) {
      case 'create' || 'destroy':
        return;
      case 'vol':
        if (value == null || !value.isFinite) {
          throw ArgumentError.value(value, 'value', 'Must be finite for vol');
        }
        buf.write(',v=${_formatFloat(_clampUnit(value, 1.0))}');
      case 'attach':
        _validateBusFilterId(filterId);
        buf.write(',ft=$filterId');
      case 'param':
        _validateBusFilterAndParam(filterId, paramId, value);
        buf.write(',ft=$filterId,pm=$paramId,v=${_formatFloat(value!)}');
      case 'fade':
        _validateBusFilterAndParam(filterId, paramId, value);
        if (duration == null || duration.isNegative) {
          throw ArgumentError.value(duration, 'duration', 'Must be >= 0');
        }
        buf.write(
          ',ft=$filterId,pm=$paramId,v=${_formatFloat(value!)},'
          'd=${_formatFloat(duration.inMicroseconds / 1000.0)}',
        );
    }
  }

  static void _validateBusFilterId(int? filterId) {
    if (filterId == null ||
        filterId < 0 ||
        filterId >= FilterType.values.length) {
      throw ArgumentError.value(
        filterId,
        'filterId',
        'Must be in 0..${FilterType.values.length - 1}',
      );
    }
  }

  static void _validateBusFilterAndParam(
    int? filterId,
    int? paramId,
    double? value,
  ) {
    _validateBusFilterId(filterId);
    if (paramId == null || paramId < 0) {
      throw ArgumentError.value(paramId, 'paramId', 'Must be >= 0');
    }
    if (value == null || !value.isFinite) {
      throw ArgumentError.value(value, 'value', 'Must be finite');
    }
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

final class _PtyStreamBuffer extends _PtyAudioBuffer {
  final int streamId;
  final int maxBufferSize;
  final bool releaseConsumed;
  final Duration bufferingTimeNeeds;
  final int sampleRate;
  final int channels;
  int nextSeq = 0;
  bool ended = false;

  _PtyStreamBuffer(
    super.hash, {
    required this.streamId,
    required this.maxBufferSize,
    required this.releaseConsumed,
    required this.bufferingTimeNeeds,
    required this.sampleRate,
    required this.channels,
  });
}

final class _PtyAudioBus implements AudioBus {
  @override
  final int id;
  final void Function(double) _onVolume;
  double volume = 1.0;
  final Set<int> attachedFilters = {};
  final Map<(int, int), double> paramValues = {};
  final Map<
    (int, int),
    ({double from, double to, DateTime startAt, Duration duration})
  >
  paramFades = {};

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
  final int? busId;
  final bool isStreamVoice;
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
  String emittedSpeedStr = '1';
  bool emitted;
  bool isPaused;
  Duration basePosition = Duration.zero;
  DateTime? anchorAt;
  double speed = 1.0;
  ({double from, double to, Duration duration})? speedRamp;
  double dopplerFactor = 1.0;
  bool preservePitch = false;
  bool emittedPreservePitch = false;
  Duration? scheduledStopRemaining;
  DateTime? scheduledStopAnchorAt;
  bool scheduleStopByStopCmd = false;
  double? pendingFadeVolumeTarget;
  Duration? pendingFadeVolumeDuration;
  double? pendingFadeSpeedTarget;
  Duration? pendingFadeSpeedDuration;
  Duration bufferDuration = Duration.zero;
  Timer? stopTimer;

  _ActivePtyVoice({
    required this.id,
    required this.buffer,
    required this.completer,
    required this.loop,
    required this.clipId,
    this.busId,
    this.isStreamVoice = false,
    required this.volume,
    required this.emitted,
    required this.isPaused,
    this.basePosition = Duration.zero,
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
  final Future<Uint8List> Function(
    String url, {
    LoadProgressCallback? onProgress,
  })?
  _readUrlBytes;
  final Clock? _clockOverride;

  /// Number of currently tracked active or paused voices.
  int get activeVoiceCount => _voices.length;

  /// Creates an APC-backed [TermuiAudioEngine] emitting via [writeEscape].
  PtyApcAudioEngine(
    this.writeEscape, {
    this.defaultToneDuration = const Duration(milliseconds: 250),
    Future<Uint8List> Function(String path)? readFileBytes,
    Future<Uint8List> Function(String url, {LoadProgressCallback? onProgress})?
    urlByteReader,
    Clock? clock,
  }) : _readFileBytes = readFileBytes ?? createDefaultApcFileReader(),
       _readUrlBytes = urlByteReader ?? createDefaultApcUrlReader(),
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
  Future<AudioBuffer> loadUrl(
    String url, {
    LoadProgressCallback? onProgress,
  }) async {
    final reader = _readUrlBytes;
    if (reader == null) {
      throw UnsupportedError(
        'PtyApcAudioEngine does not load URLs on this platform',
      );
    }
    final bytes = await reader(url, onProgress: onProgress);
    if (bytes.isEmpty || bytes.length > ApcAudioEncoder.maxStreamBytes) {
      throw RangeError.range(
        bytes.length,
        1,
        ApcAudioEncoder.maxStreamBytes,
        'bytes.length',
      );
    }
    onProgress?.call(1.0);
    if (bytes.length <= ApcAudioEncoder.maxClipBytes) {
      return loadMem(url, bytes);
    }
    final streamBuf = await createBufferStream(maxBufferSize: bytes.length);
    addStreamData(streamBuf, bytes);
    setStreamEnded(streamBuf);
    return streamBuf;
  }

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
        'mp3' => estimateMp3Duration(bytes),
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
  }) async {
    final id = _nextBufferId++;
    final frame = ApcAudioEncoder.encodeStreamOpen(
      streamId: id,
      maxBufferSize: maxBufferSize,
      releaseConsumed: releaseConsumed,
      bufferingTimeNeeds: bufferingTimeNeeds,
      sampleRate: sampleRate,
      channels: channels,
    );
    final buf = _PtyStreamBuffer(
      id,
      streamId: id,
      maxBufferSize: maxBufferSize,
      releaseConsumed: releaseConsumed,
      bufferingTimeNeeds: bufferingTimeNeeds,
      sampleRate: sampleRate,
      channels: channels,
    );
    _buffers[id] = buf;
    if (!_disposed) {
      writeEscape(frame);
    }
    return buf;
  }

  _PtyStreamBuffer _resolveStreamBuffer(AudioBuffer buffer) {
    final resolved = _buffers[buffer.hash];
    if (resolved is _PtyStreamBuffer) return resolved;
    throw ArgumentError('Unknown stream AudioBuffer for PtyApcAudioEngine');
  }

  @override
  void addStreamData(AudioBuffer buffer, Uint8List chunk) {
    if (_disposed) return;
    final streamBuf = _resolveStreamBuffer(buffer);
    if (streamBuf.ended || chunk.isEmpty) return;
    final frames = ApcAudioEncoder.encodeStreamChunk(
      streamId: streamBuf.streamId,
      bytes: chunk,
      startSeq: streamBuf.nextSeq,
    );
    streamBuf.nextSeq += frames.length;
    for (final frame in frames) {
      writeEscape(frame);
    }
  }

  @override
  void setStreamEnded(AudioBuffer buffer) {
    if (_disposed) return;
    final streamBuf = _resolveStreamBuffer(buffer);
    if (streamBuf.ended) return;
    streamBuf.ended = true;
    writeEscape(
      ApcAudioEncoder.encodeStreamEnd(
        streamId: streamBuf.streamId,
        seq: streamBuf.nextSeq,
      ),
    );
  }

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
    final busId = (bus is _PtyAudioBus && _buses.containsKey(bus.id))
        ? bus.id
        : null;
    final clipId = (resolved is _PtyClipBuffer || resolved is _PtyStreamBuffer)
        ? voiceId
        : null;
    final state = _ActivePtyVoice(
      id: voiceId,
      buffer: resolved,
      completer: Completer<void>(),
      loop: loop,
      clipId: clipId,
      busId: busId,
      isStreamVoice: resolved is _PtyStreamBuffer,
      volume: 1.0,
      emitted: !paused,
      isPaused: paused,
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
        !state.isStreamVoice &&
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

  void _refreshExpiredSpeedRamp(_ActivePtyVoice state, DateTime now) {
    final ramp = state.speedRamp;
    final anchor = state.anchorAt;
    if (ramp == null || anchor == null || state.isPaused) return;
    if (now.difference(anchor) >= ramp.duration) {
      _snapshotPlayhead(state, now);
    }
  }

  void _syncEmittedVoice(_ActivePtyVoice state) {
    final clipId = state.clipId;
    if (_disposed || !state.emitted || clipId == null || clipId > 0x7FFFFFFF) {
      return;
    }
    _refreshExpiredSpeedRamp(state, _clock.now());
    final effVol = _effectiveVolume(state);
    final clampedPan = ApcAudioEncoder._clampPan(state.pan);
    final effSpeed = _effectiveSpeed(state);
    final volStr = ApcAudioEncoder._formatFloat(effVol);
    final panStr = ApcAudioEncoder._formatFloat(clampedPan);
    final speedStr = ApcAudioEncoder._formatFloat(effSpeed);
    final volChanged = volStr != state.emittedVolStr;
    final panChanged = panStr != state.emittedPanStr;
    final speedChanged =
        state.speedRamp == null && speedStr != state.emittedSpeedStr;
    if (!volChanged && !panChanged && !speedChanged) {
      return;
    }
    state.emittedVolStr = volStr;
    state.emittedPanStr = panStr;
    if (speedChanged) {
      state.emittedSpeedStr = speedStr;
    }
    writeEscape(
      ApcAudioEncoder.encodeUpdate(
        clipId: clipId,
        volume: volChanged ? effVol : null,
        pan: panChanged ? clampedPan : null,
        speed: speedChanged ? effSpeed : null,
      ),
    );
  }

  static double _effectiveSpeed(_ActivePtyVoice state) =>
      (state.speed * state.dopplerFactor).clamp(0.125, 8.0).toDouble();

  static double _computeRadialDoppler(
    double x,
    double y,
    double z,
    double vx,
    double vy,
    double vz,
  ) {
    if (!vx.isFinite || !vy.isFinite || !vz.isFinite) return 1.0;
    if (vx == 0.0 && vy == 0.0 && vz == 0.0) return 1.0;
    final dist = math.sqrt(x * x + y * y + z * z);
    if (dist <= 0.0) return 1.0;
    // Closing velocity (positive when source moves toward listener at origin).
    final vRadial = -(x * vx + y * vy + z * vz) / dist;
    const speedOfSound = 343.3;
    final denom = speedOfSound - vRadial;
    if (denom <= 0.0) return 8.0;
    return (speedOfSound / denom).clamp(0.125, 8.0).toDouble();
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
      final busId = (voice.busId != null && _buses.containsKey(voice.busId))
          ? voice.busId
          : null;
      final Duration bufferDur;
      switch (buffer) {
        case _PtyWaveformBuffer(:final shape, :final frequency):
          bufferDur = durationOverride ?? defaultToneDuration;
          writeEscape(
            ApcAudioEncoder.encodeTone(
              waveform: shape,
              frequencyHz: frequency,
              duration: bufferDur,
              volume: effVol,
              pan: clampedPan,
              busId: busId,
            ),
          );
        case _PtyClipBuffer(:final format, :final bytes, :final duration):
          bufferDur = duration;
          voice.emittedVolStr = ApcAudioEncoder._formatFloat(effVol);
          voice.emittedPanStr = ApcAudioEncoder._formatFloat(clampedPan);
          voice.emittedSpeedStr = '1';
          final frames = ApcAudioEncoder.encodeClip(
            clipId: voice.clipId ?? voice.id,
            format: format,
            bytes: bytes,
            volume: effVol,
            pan: clampedPan,
            loop: voice.loop,
            startOffset: voice.basePosition,
            busId: busId,
          );
          for (final frame in frames) {
            writeEscape(frame);
          }
        case _PtyStreamBuffer(:final streamId):
          bufferDur = Duration.zero;
          voice.emittedVolStr = ApcAudioEncoder._formatFloat(effVol);
          voice.emittedPanStr = ApcAudioEncoder._formatFloat(clampedPan);
          voice.emittedSpeedStr = '1';
          writeEscape(
            ApcAudioEncoder.encodeStreamPlay(
              clipId: voice.clipId ?? voice.id,
              streamId: streamId,
              volume: effVol,
              pan: clampedPan,
              loop: voice.loop,
              startOffset: voice.basePosition,
              busId: busId,
            ),
          );
      }
      final now = _clock.now();
      voice.bufferDuration = bufferDur;
      voice.anchorAt = voice.isPaused ? null : now;
      if (voice.scheduledStopRemaining != null && !voice.isPaused) {
        voice.scheduledStopAnchorAt = now;
      }
      _emitPreEmissionUpdates(voice);
      _rescheduleStopTimer(voice, now);
    } finally {
      voice.buffer = null;
    }
  }

  void _emitPreEmissionUpdates(_ActivePtyVoice voice) {
    final clipId = voice.clipId;
    if (_disposed || clipId == null || clipId > 0x7FFFFFFF) return;
    final effSpeed = _effectiveSpeed(voice);
    final sendSpeed = voice.speedRamp == null && (effSpeed - 1.0).abs() > 1e-6;
    final sendPp = voice.preservePitch;
    final fadeVolTarget = voice.pendingFadeVolumeTarget;
    final fadeVolDur = voice.pendingFadeVolumeDuration;
    final fadeSpTarget = voice.pendingFadeSpeedTarget;
    final fadeSpDur = voice.pendingFadeSpeedDuration;
    final stopDur = voice.scheduledStopRemaining;
    if (!sendSpeed &&
        !sendPp &&
        fadeVolTarget == null &&
        fadeSpTarget == null &&
        stopDur == null) {
      return;
    }
    if (sendSpeed) {
      voice.emittedSpeedStr = ApcAudioEncoder._formatFloat(effSpeed);
    }
    if (sendPp) {
      voice.emittedPreservePitch = true;
    }
    voice.pendingFadeVolumeTarget = null;
    voice.pendingFadeVolumeDuration = null;
    voice.pendingFadeSpeedTarget = null;
    voice.pendingFadeSpeedDuration = null;
    writeEscape(
      ApcAudioEncoder.encodeUpdate(
        clipId: clipId,
        speed: sendSpeed ? effSpeed : null,
        preservePitch: sendPp ? true : null,
        fadeVolumeTarget: fadeVolTarget,
        fadeVolumeDuration: fadeVolDur,
        fadeSpeedTarget: fadeSpTarget,
        fadeSpeedDuration: fadeSpDur,
        scheduleStopDuration: stopDur,
      ),
    );
  }

  static double _currentSpeedAt(_ActivePtyVoice state, DateTime now) {
    final ramp = state.speedRamp;
    final anchor = state.anchorAt;
    if (ramp == null || anchor == null || state.isPaused) {
      return state.speed;
    }
    final rampUs = ramp.duration.inMicroseconds;
    if (rampUs <= 0) return ramp.to;
    final elapsedUs = now.difference(anchor).inMicroseconds;
    if (elapsedUs <= 0) return ramp.from;
    if (elapsedUs >= rampUs) return ramp.to;
    return ramp.from + (ramp.to - ramp.from) * (elapsedUs / rampUs);
  }

  static Duration _computeRawPosition(_ActivePtyVoice state, DateTime now) {
    final anchor = state.anchorAt;
    if (anchor == null || state.isPaused) return state.basePosition;
    final elapsedUs = now.difference(anchor).inMicroseconds;
    if (elapsedUs <= 0) return state.basePosition;
    final ramp = state.speedRamp;
    final int deltaUs;
    if (ramp == null) {
      deltaUs = (elapsedUs * _effectiveSpeed(state)).round();
    } else {
      deltaUs = _integrateSpeedRampUs(elapsedUs, ramp);
    }
    return state.basePosition + Duration(microseconds: deltaUs);
  }

  static int _integrateSpeedRampUs(
    int elapsedUs,
    ({double from, double to, Duration duration}) ramp,
  ) {
    final rampUs = ramp.duration.inMicroseconds;
    if (rampUs <= 0) return (elapsedUs * ramp.to).round();
    if (elapsedUs <= rampUs) {
      final cur = ramp.from + (ramp.to - ramp.from) * (elapsedUs / rampUs);
      return (elapsedUs * (ramp.from + cur) / 2.0).round();
    }
    final rampArea = rampUs * (ramp.from + ramp.to) / 2.0;
    final tailArea = (elapsedUs - rampUs) * ramp.to;
    return (rampArea + tailArea).round();
  }

  static Duration _normalizePosition(_ActivePtyVoice state, Duration rawPos) {
    if (rawPos <= Duration.zero) return Duration.zero;
    final dur = state.bufferDuration;
    if (dur <= Duration.zero) return rawPos;
    if (state.loop) {
      return Duration(microseconds: rawPos.inMicroseconds % dur.inMicroseconds);
    }
    return rawPos > dur ? dur : rawPos;
  }

  void _snapshotPlayhead(_ActivePtyVoice state, DateTime now) {
    final pos = _normalizePosition(state, _computeRawPosition(state, now));
    final curSpeed = _currentSpeedAt(state, now);
    final ramp = state.speedRamp;
    if (ramp != null && state.anchorAt != null && !state.isPaused) {
      final elapsed = now.difference(state.anchorAt!);
      final remainingRamp = ramp.duration - elapsed;
      if (remainingRamp > Duration.zero) {
        state.speedRamp = (
          from: curSpeed,
          to: ramp.to,
          duration: remainingRamp,
        );
      } else {
        state.speedRamp = null;
      }
    }
    state.speed = curSpeed;
    state.basePosition = pos;
    state.anchorAt = state.isPaused ? null : now;

    final stopAnchor = state.scheduledStopAnchorAt;
    final stopRem = state.scheduledStopRemaining;
    if (stopAnchor != null && stopRem != null && !state.isPaused) {
      final left = stopRem - now.difference(stopAnchor);
      state.scheduledStopRemaining = left > Duration.zero
          ? left
          : Duration.zero;
      state.scheduledStopAnchorAt = now;
    }
  }

  static Duration _wallTimeForMediaDelta(
    Duration mediaDelta,
    double effSpeed,
    ({double from, double to, Duration duration})? ramp,
  ) {
    if (mediaDelta <= Duration.zero) return Duration.zero;
    final mediaUs = mediaDelta.inMicroseconds.toDouble();
    if (ramp == null) {
      return Duration(microseconds: (mediaUs / effSpeed).round());
    }
    final rampUs = ramp.duration.inMicroseconds.toDouble();
    final rampArea = rampUs * (ramp.from + ramp.to) / 2.0;
    if (rampUs <= 0 || mediaUs >= rampArea) {
      final extraUs = (mediaUs - rampArea) / ramp.to;
      return Duration(microseconds: (rampUs + extraUs).round());
    }
    final slope = (ramp.to - ramp.from) / rampUs;
    if (slope.abs() < 1e-9) {
      return Duration(microseconds: (mediaUs / ramp.from).round());
    }
    final a = 0.5 * slope;
    final b = ramp.from;
    final disc = math.max(0.0, b * b + 4.0 * a * mediaUs);
    final t = (-b + math.sqrt(disc)) / (2.0 * a);
    return Duration(microseconds: math.max(0.0, t).round());
  }

  void _rescheduleStopTimer(_ActivePtyVoice state, DateTime now) {
    state.stopTimer?.cancel();
    state.stopTimer = null;
    if (_disposed || !state.emitted || state.isPaused) return;

    Duration? delay;
    var triggerStop = false;
    final schedRem = state.scheduledStopRemaining;
    if (schedRem != null) {
      delay = schedRem;
      triggerStop = state.scheduleStopByStopCmd;
    }
    if (!state.loop && state.bufferDuration > Duration.zero) {
      final pos = _normalizePosition(state, _computeRawPosition(state, now));
      final mediaDelay = _wallTimeForMediaDelta(
        state.bufferDuration - pos,
        _effectiveSpeed(state),
        state.speedRamp,
      );
      if (delay == null || mediaDelay < delay) {
        delay = mediaDelay;
        triggerStop = false;
      }
    } else if (!state.loop && !state.isStreamVoice && delay == null) {
      delay = Duration.zero;
    }
    if (delay == null) return;
    final voiceId = state.id;
    state.stopTimer = Timer(delay, () {
      if (triggerStop) {
        stop(AudioVoice(voiceId, state.completer.future));
      } else {
        _evictAndCompleteVoice(voiceId);
      }
    });
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

  /// Pauses or resumes [voice], emitting deferred APC playback on first resume
  /// or `a=update,pa=<0|1>` after emission.
  @override
  void setPaused(AudioVoice voice, bool paused) {
    if (_disposed) return;
    final state = _voices[voice.id];
    if (state == null) return;
    if (!state.emitted) {
      if (paused) {
        state.isPaused = true;
        return;
      }
      state.emitted = true;
      state.isPaused = false;
      _emitVoicePlayback(state, durationOverride: state.scheduledStopRemaining);
      return;
    }
    if (state.isPaused == paused) return;
    final now = _clock.now();
    _snapshotPlayhead(state, now);
    state.isPaused = paused;
    if (paused) {
      state.anchorAt = null;
      state.scheduledStopAnchorAt = null;
    } else {
      state.anchorAt = now;
      if (state.scheduledStopRemaining != null) {
        state.scheduledStopAnchorAt = now;
      }
    }
    _rescheduleStopTimer(state, now);
    final clipId = state.clipId;
    if (clipId != null && clipId <= 0x7FFFFFFF) {
      writeEscape(ApcAudioEncoder.encodeUpdate(clipId: clipId, paused: paused));
    }
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

  /// Updates the 3D source coordinates, velocity Doppler, stereo pan, and distance attenuation for [voice].
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
    final nextDoppler = _computeRadialDoppler(x, y, z, vx, vy, vz);
    if (nextDoppler != state.dopplerFactor && state.emitted) {
      final now = _clock.now();
      _snapshotPlayhead(state, now);
      state.dopplerFactor = nextDoppler;
      _rescheduleStopTimer(state, now);
    } else {
      state.dopplerFactor = nextDoppler;
    }
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
      _PtyStreamBuffer() => Duration.zero,
    };
  }

  @override
  Duration getVoicePosition(AudioVoice voice) {
    final state = _voices[voice.id];
    if (state == null || !state.emitted) return Duration.zero;
    return _normalizePosition(state, _computeRawPosition(state, _clock.now()));
  }

  /// Seeks [voice] to [position], rescheduling `stopTimer` and emitting `a=update,s=...`.
  @override
  void seek(AudioVoice voice, Duration position) {
    if (_disposed) return;
    final state = _voices[voice.id];
    if (state == null) return;
    var target = position.isNegative ? Duration.zero : position;
    final dur = state.bufferDuration;
    if (dur > Duration.zero && target > dur) {
      target = dur;
    }
    final now = _clock.now();
    state.basePosition = target;
    state.anchorAt = (state.emitted && !state.isPaused) ? now : null;
    if (!state.emitted) return;
    _rescheduleStopTimer(state, now);
    final clipId = state.clipId;
    if (clipId != null && clipId <= 0x7FFFFFFF) {
      writeEscape(
        ApcAudioEncoder.encodeUpdate(clipId: clipId, seekPosition: target),
      );
    }
  }

  @override
  void setRelativePlaySpeed(
    AudioVoice voice,
    double speed, {
    bool preservePitch = false,
  }) {
    if (_disposed) return;
    final state = _voices[voice.id];
    if (state == null || !speed.isFinite || speed <= 0) return;
    final clamped = ApcAudioEncoder._clampSpeed(speed);
    final now = _clock.now();
    if (state.emitted) {
      _snapshotPlayhead(state, now);
    }
    state.speed = clamped;
    state.preservePitch = preservePitch;
    state.speedRamp = null;
    if (!state.emitted) return;
    _rescheduleStopTimer(state, now);
    final clipId = state.clipId;
    if (clipId != null && clipId <= 0x7FFFFFFF) {
      final effSpeed = _effectiveSpeed(state);
      state.emittedSpeedStr = ApcAudioEncoder._formatFloat(effSpeed);
      final emitPp = preservePitch || state.emittedPreservePitch
          ? preservePitch
          : null;
      state.emittedPreservePitch = preservePitch;
      writeEscape(
        ApcAudioEncoder.encodeUpdate(
          clipId: clipId,
          speed: effSpeed,
          preservePitch: emitPp,
        ),
      );
    }
  }

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
  ) {
    if (_disposed) return;
    final state = _voices[voice.id];
    if (state == null || !speed.isFinite || speed <= 0) return;
    final clamped = ApcAudioEncoder._clampSpeed(speed);
    final dur = duration.isNegative ? Duration.zero : duration;
    final now = _clock.now();
    if (state.emitted) {
      _snapshotPlayhead(state, now);
    }
    if (dur == Duration.zero) {
      state.speed = clamped;
      state.speedRamp = null;
    } else {
      state.speedRamp = (from: state.speed, to: clamped, duration: dur);
    }
    if (!state.emitted) {
      state.pendingFadeSpeedTarget = clamped;
      state.pendingFadeSpeedDuration = dur;
      return;
    }
    _rescheduleStopTimer(state, now);
    final clipId = state.clipId;
    if (clipId != null && clipId <= 0x7FFFFFFF) {
      final effTarget = (clamped * state.dopplerFactor)
          .clamp(0.125, 8.0)
          .toDouble();
      state.emittedSpeedStr = ApcAudioEncoder._formatFloat(effTarget);
      writeEscape(
        ApcAudioEncoder.encodeUpdate(
          clipId: clipId,
          fadeSpeedTarget: effTarget,
          fadeSpeedDuration: dur,
        ),
      );
    }
  }

  @override
  void fadeVolume(AudioVoice voice, double targetVolume, Duration duration) {
    if (_disposed) return;
    final state = _voices[voice.id];
    if (state == null || !targetVolume.isFinite) return;
    final clamped = targetVolume.clamp(0.0, 1.0).toDouble();
    final dur = duration.isNegative ? Duration.zero : duration;
    state.volume = clamped;
    final effVol = _effectiveVolume(state);
    if (!state.emitted) {
      state.pendingFadeVolumeTarget = effVol;
      state.pendingFadeVolumeDuration = dur;
      return;
    }
    state.emittedVolStr = ApcAudioEncoder._formatFloat(effVol);
    final clipId = state.clipId;
    if (clipId != null && clipId <= 0x7FFFFFFF) {
      writeEscape(
        ApcAudioEncoder.encodeUpdate(
          clipId: clipId,
          fadeVolumeTarget: effVol,
          fadeVolumeDuration: dur,
        ),
      );
    }
  }

  @override
  void scheduleStop(AudioVoice voice, Duration duration) {
    if (_disposed) return;
    final state = _voices[voice.id];
    if (state == null) return;
    final dur = duration.isNegative ? Duration.zero : duration;
    final now = _clock.now();
    state.scheduledStopRemaining = dur;
    state.scheduledStopAnchorAt = (state.emitted && !state.isPaused)
        ? now
        : null;
    state.scheduleStopByStopCmd = true;
    if (!state.emitted) return;
    _rescheduleStopTimer(state, now);
    final clipId = state.clipId;
    if (clipId != null && clipId <= 0x7FFFFFFF) {
      writeEscape(
        ApcAudioEncoder.encodeUpdate(clipId: clipId, scheduleStopDuration: dur),
      );
    }
  }

  static const List<List<double>> _defaultFilterParams = [
    [1.0, 0.0, 1000.0, 2.0], // biquadResonant
    [1.0, 0.3, 0.7, 0.0], // echo
    [1.0, 4000.0, 3.0], // lofi
    [1.0, 0.005, 10.0], // flanger
    [1.0, 2.0], // bassboost
    [1.0, 0.0], // waveShaper
    [1.0, 30.0, 0.0], // robotize
    [1.0, 0.0, 0.5, 0.5, 1.0], // freeverb
    [1.0, 1.0, 0.0], // pitchShift
    [1.0, -3.0, -1.0, 6.0, 50.0, 1.0], // limiter
    [1.0, -6.0, 0.0, 2.0, 3.0, 10.0, 100.0], // compressor
    [1.0, 1024.0, 3.0], // parametricEq (band gains 3..66 default to 1.0)
  ];

  static bool _isValidFilterParam(int filterId, int paramId) {
    if (filterId < 0 ||
        filterId >= _defaultFilterParams.length ||
        paramId < 0) {
      return false;
    }
    final maxParams = filterId == FilterType.parametricEq.index
        ? 67
        : _defaultFilterParams[filterId].length;
    return paramId < maxParams;
  }

  static double _defaultFilterParamValue(int filterId, int paramId) {
    if (!_isValidFilterParam(filterId, paramId)) return 0.0;
    final defaults = _defaultFilterParams[filterId];
    return paramId < defaults.length ? defaults[paramId] : 1.0;
  }

  static void _seedFilterDefaults(_PtyAudioBus busState, int filterId) {
    if (!busState.attachedFilters.add(filterId)) return;
    final count = filterId == FilterType.parametricEq.index
        ? 67
        : _defaultFilterParams[filterId].length;
    for (var p = 0; p < count; p++) {
      busState.paramValues.putIfAbsent((
        filterId,
        p,
      ), () => _defaultFilterParamValue(filterId, p));
    }
  }

  static void _syncPairedPitchParams(
    _PtyAudioBus busState,
    int filterId,
    int paramId,
    double value,
  ) {
    if (filterId != FilterType.pitchShift.index) return;
    if (paramId == 1 && value > 0.0) {
      final semitones = 12.0 * math.log(value) / math.ln2;
      busState.paramFades.remove((filterId, 2));
      busState.paramValues[(filterId, 2)] = semitones;
    } else if (paramId == 2) {
      final shift = math.pow(2.0, value / 12.0).toDouble();
      busState.paramFades.remove((filterId, 1));
      busState.paramValues[(filterId, 1)] = shift;
    }
  }

  @override
  int createFilter(FilterType type) => type.index;

  @override
  void attachFilterToBus(AudioBus bus, int filterId) {
    if (_disposed) return;
    if (filterId < 0 || filterId >= FilterType.values.length) {
      throw RangeError.index(filterId, FilterType.values, 'filterId');
    }
    final busState = _buses[bus.id];
    if (busState == null) {
      throw StateError('AudioBus ${bus.id} is not registered on this engine.');
    }
    _seedFilterDefaults(busState, filterId);
    writeEscape(
      ApcAudioEncoder.encodeBus(
        op: 'attach',
        busId: bus.id,
        filterId: filterId,
      ),
    );
  }

  @override
  void setFilterParameter(
    AudioBus bus,
    int filterId,
    int paramId,
    double value,
  ) {
    if (_disposed || !value.isFinite) return;
    final busState = _buses[bus.id];
    if (busState == null || !_isValidFilterParam(filterId, paramId)) return;
    _seedFilterDefaults(busState, filterId);
    final key = (filterId, paramId);
    busState.paramFades.remove(key);
    busState.paramValues[key] = value;
    _syncPairedPitchParams(busState, filterId, paramId, value);
    writeEscape(
      ApcAudioEncoder.encodeBus(
        op: 'param',
        busId: bus.id,
        filterId: filterId,
        paramId: paramId,
        value: value,
      ),
    );
  }

  @override
  double getFilterParameter(AudioBus bus, int filterId, int paramId) {
    if (_disposed) return 0.0;
    final busState = _buses[bus.id];
    if (busState == null || !_isValidFilterParam(filterId, paramId)) return 0.0;
    final key = (filterId, paramId);
    final fade = busState.paramFades[key];
    if (fade != null) {
      final elapsed = _clock.now().difference(fade.startAt);
      if (fade.duration <= Duration.zero || elapsed >= fade.duration) {
        busState.paramFades.remove(key);
        busState.paramValues[key] = fade.to;
        return fade.to;
      }
      if (elapsed <= Duration.zero) return fade.from;
      final t = elapsed.inMicroseconds / fade.duration.inMicroseconds;
      return fade.from + (fade.to - fade.from) * t;
    }
    return busState.paramValues[key] ??
        _defaultFilterParamValue(filterId, paramId);
  }

  @override
  void fadeFilterParameter(
    AudioBus bus,
    int filterId,
    int paramId,
    double targetValue,
    Duration duration,
  ) {
    if (_disposed || !targetValue.isFinite) return;
    final busState = _buses[bus.id];
    if (busState == null || !_isValidFilterParam(filterId, paramId)) return;
    _seedFilterDefaults(busState, filterId);
    final key = (filterId, paramId);
    final current = getFilterParameter(bus, filterId, paramId);
    final dur = duration.isNegative ? Duration.zero : duration;
    if (dur == Duration.zero) {
      busState.paramFades.remove(key);
      busState.paramValues[key] = targetValue;
      _syncPairedPitchParams(busState, filterId, paramId, targetValue);
    } else {
      busState.paramFades[key] = (
        from: current,
        to: targetValue,
        startAt: _clock.now(),
        duration: dur,
      );
    }
    writeEscape(
      ApcAudioEncoder.encodeBus(
        op: 'fade',
        busId: bus.id,
        filterId: filterId,
        paramId: paramId,
        value: targetValue,
        duration: dur,
      ),
    );
  }

  @override
  AudioVoice playSprite(
    AudioBuffer buffer, {
    required Duration start,
    required Duration duration,
    AudioBus? bus,
  }) {
    final resolved = _resolveBuffer(buffer);
    final voiceId = _nextVoiceId++;
    final busId = (bus is _PtyAudioBus && _buses.containsKey(bus.id))
        ? bus.id
        : null;
    final clipId = (resolved is _PtyClipBuffer || resolved is _PtyStreamBuffer)
        ? voiceId
        : null;
    final clampedStart = start.isNegative ? Duration.zero : start;
    final clampedDur = duration.isNegative ? Duration.zero : duration;
    final state = _ActivePtyVoice(
      id: voiceId,
      buffer: resolved,
      completer: Completer<void>(),
      loop: false,
      clipId: clipId,
      busId: busId,
      isStreamVoice: resolved is _PtyStreamBuffer,
      volume: 1.0,
      emitted: true,
      isPaused: false,
      basePosition: clampedStart,
    );
    state.scheduledStopRemaining = clampedDur;
    state.scheduleStopByStopCmd = true;
    _voices[voiceId] = state;
    final voice = AudioVoice(voiceId, state.completer.future);
    try {
      _emitVoicePlayback(state, durationOverride: clampedDur);
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
    final bus = _PtyAudioBus(id, (volume) {
      if (_disposed || !_buses.containsKey(id)) return;
      writeEscape(
        ApcAudioEncoder.encodeBus(op: 'vol', busId: id, value: volume),
      );
    });
    _buses[id] = bus;
    if (!_disposed) {
      writeEscape(ApcAudioEncoder.encodeBus(op: 'create', busId: id));
    }
    return bus;
  }

  @override
  void destroyBus(AudioBus bus) {
    final removed = _buses.remove(bus.id);
    if (removed != null && !_disposed) {
      writeEscape(ApcAudioEncoder.encodeBus(op: 'destroy', busId: removed.id));
    }
  }

  @override
  Float32List getWaveform([Float32List? outBuffer]) {
    if (outBuffer != null && outBuffer.length < 256) {
      throw ArgumentError('outBuffer must be at least 256 elements long.');
    }
    return outBuffer ?? Float32List(256);
  }
}
