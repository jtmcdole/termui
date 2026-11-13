import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../api/audio_types.dart';

/// Generates an in-memory 16-bit mono PCM WAV buffer for [shape] at [frequency].
///
/// Applies a 5ms cosine attack fade-in and a 10ms cosine decay fade-out to
/// prevent click artifacts at playback boundaries.
Uint8List generateWaveformPcmWav({
  required WaveForm shape,
  required double frequency,
  Duration duration = const Duration(milliseconds: 250),
  int sampleRate = 44100,
}) {
  final numSamples = (sampleRate * (duration.inMicroseconds / 1000000.0))
      .round();
  final pcmByteLength = numSamples * 2;
  final totalLength = 44 + pcmByteLength;
  final bytes = Uint8List(totalLength);
  final bd = ByteData.sublistView(bytes);

  _writeMono16WavHeader(bytes, bd, sampleRate, pcmByteLength);

  final attackSamples = (sampleRate * 0.005).round();
  final decaySamples = (sampleRate * 0.010).round();
  final attackStep = attackSamples > 0 ? math.pi / attackSamples : 0.0;
  final decayStep = decaySamples > 0 ? math.pi / decaySamples : 0.0;

  for (var i = 0; i < numSamples; i++) {
    final t = i / sampleRate;
    final phase = (t * frequency) % 1.0;
    final sample = _sampleWaveform(shape, phase);
    final envelope = _cosineEnvelope(
      index: i,
      numSamples: numSamples,
      attackSamples: attackSamples,
      decaySamples: decaySamples,
      attackStep: attackStep,
      decayStep: decayStep,
    );

    final intSample = (sample * envelope * 32767.0)
        .clamp(-32768.0, 32767.0)
        .toInt();
    bd.setInt16(44 + i * 2, intSample, Endian.little);
  }
  return bytes;
}

void _writeMono16WavHeader(
  Uint8List bytes,
  ByteData bd,
  int sampleRate,
  int pcmByteLength,
) {
  bytes.setRange(0, 4, 'RIFF'.codeUnits);
  bd.setUint32(4, 36 + pcmByteLength, Endian.little);
  bytes.setRange(8, 12, 'WAVE'.codeUnits);
  bytes.setRange(12, 16, 'fmt '.codeUnits);
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little);
  bd.setUint16(22, 1, Endian.little);
  bd.setUint32(24, sampleRate, Endian.little);
  bd.setUint32(28, sampleRate * 2, Endian.little);
  bd.setUint16(32, 2, Endian.little);
  bd.setUint16(34, 16, Endian.little);
  bytes.setRange(36, 40, 'data'.codeUnits);
  bd.setUint32(40, pcmByteLength, Endian.little);
}

double _sampleWaveform(WaveForm shape, double phase) => switch (shape) {
  WaveForm.sin => math.sin(2.0 * math.pi * phase),
  WaveForm.triangle => phase < 0.5 ? (4.0 * phase - 1.0) : (3.0 - 4.0 * phase),
  WaveForm.saw || WaveForm.fsaw => 2.0 * phase - 1.0,
  WaveForm.bounce ||
  WaveForm.jaws ||
  WaveForm.humps => (math.sin(2.0 * math.pi * phase)).abs() * 2.0 - 1.0,
  WaveForm.square || WaveForm.fsquare => phase < 0.5 ? 0.7 : -0.7,
};

double _cosineEnvelope({
  required int index,
  required int numSamples,
  required int attackSamples,
  required int decaySamples,
  required double attackStep,
  required double decayStep,
}) {
  if (index < attackSamples) {
    return (1.0 - math.cos(index * attackStep)) / 2.0;
  }
  final decayStart = numSamples - decaySamples;
  if (index > decayStart) {
    return (1.0 + math.cos((index - decayStart) * decayStep)) / 2.0;
  }
  return 1.0;
}

/// Creates a broadcast playhead position stream for [voice] polled at [interval].
///
/// Automatically emits a final position and closes when [voice] completes or
/// when [isVoiceActive] returns `false`.
Stream<Duration> createVoicePositionStream({
  required AudioVoice voice,
  required bool Function(int voiceId) isVoiceActive,
  required Duration Function(AudioVoice voice) getPosition,
  Duration interval = const Duration(milliseconds: 50),
}) {
  if (!isVoiceActive(voice.id)) {
    return const Stream.empty();
  }
  late final StreamController<Duration> controller;
  Timer? ticker;

  controller = StreamController<Duration>.broadcast(
    onListen: () {
      ticker = Timer.periodic(interval, (_) {
        if (!isVoiceActive(voice.id)) {
          controller.close();
          ticker?.cancel();
          return;
        }
        controller.add(getPosition(voice));
      });
    },
    onCancel: () {
      ticker?.cancel();
    },
  );

  unawaited(
    voice.completed.then((_) {
      if (!controller.isClosed) {
        controller.add(getPosition(voice));
        controller.close();
        ticker?.cancel();
      }
    }),
  );

  return controller.stream;
}

/// Minimum polling interval enforced by [createWaveformStream].
const Duration minWaveformWatchInterval = Duration(milliseconds: 50);

/// Creates a broadcast waveform stream polling [fetchWaveform] at [interval].
///
/// Clamps [interval] to at least `50ms`, skips re-entrant ticks while a fetch
/// is already in flight, and closes cleanly on cancel or engine disposal.
Stream<Float32List> createWaveformStream({
  required Future<Float32List> Function([Float32List? outBuffer]) fetchWaveform,
  required bool Function() isDisposed,
  Duration interval = const Duration(milliseconds: 100),
  Future<void>? onDisposed,
}) {
  if (isDisposed()) {
    return const Stream.empty();
  }
  final effectiveInterval = interval < minWaveformWatchInterval
      ? minWaveformWatchInterval
      : interval;
  return _WaveformWatchSession(
    fetchWaveform: fetchWaveform,
    isDisposed: isDisposed,
    interval: effectiveInterval,
    onDisposed: onDisposed,
  ).stream;
}

final class _WaveformWatchSession {
  _WaveformWatchSession({
    required this.fetchWaveform,
    required this.isDisposed,
    required this.interval,
    Future<void>? onDisposed,
  }) {
    _controller = StreamController<Float32List>.broadcast(
      onListen: _startTicker,
      onCancel: _stopTicker,
    );
    if (onDisposed != null) {
      unawaited(onDisposed.then((_) => _close()));
    }
  }

  final Future<Float32List> Function([Float32List? outBuffer]) fetchWaveform;
  final bool Function() isDisposed;
  final Duration interval;

  late final StreamController<Float32List> _controller;
  Timer? _ticker;
  var _inFlight = false;

  Stream<Float32List> get stream => _controller.stream;

  void _startTicker() {
    if (isDisposed()) {
      _close();
      return;
    }
    _ticker = Timer.periodic(interval, (_) => unawaited(_poll()));
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _close() {
    _stopTicker();
    if (!_controller.isClosed) {
      unawaited(_controller.close());
    }
  }

  Future<void> _poll() async {
    if (isDisposed() || _controller.isClosed) {
      _close();
      return;
    }
    if (_inFlight) return;
    _inFlight = true;
    try {
      final samples = await fetchWaveform();
      if (!isDisposed() && !_controller.isClosed) {
        _controller.add(samples);
      }
    } catch (error, stackTrace) {
      if (!isDisposed() && !_controller.isClosed) {
        _controller.addError(error, stackTrace);
      }
    } finally {
      _inFlight = false;
    }
  }
}
