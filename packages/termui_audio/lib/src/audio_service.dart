import 'dart:async';
import 'dart:typed_data';
import 'api/audio_types.dart';
export 'api/audio_types.dart';

/// The unified abstraction interface for multiplatform audio playback.
abstract class AudioService {
  /// Initializes the audio engine.
  Future<void> init();

  /// Loads a sound file from the given path or URL and returns a unique [SoundHandle].
  Future<SoundHandle> loadSound(String path);

  /// Plays a loaded sound identified by [handle].
  Future<void> playSound(SoundHandle handle, {bool loop = false});

  /// Stops a playing sound identified by [handle].
  Future<void> stopSound(SoundHandle handle);

  /// Sets the volume of the played sound (or background music).
  Future<void> setBgmVolume(double volume);

  /// Sets the relative playback speed of a loaded sound identified by [handle].
  Future<void> setRelativePlaySpeed(SoundHandle handle, double speed);

  /// Fades the relative play speed of a loaded sound identified by [handle] over [duration].
  Future<void> fadeRelativePlaySpeed(
    SoundHandle handle,
    double speed,
    Duration duration,
  );

  /// Fades the volume of a loaded sound identified by [handle] over [duration].
  Future<void> fadeVolume(
    SoundHandle handle,
    double targetVolume,
    Duration duration,
  );

  /// Fades the background music volume over [duration].
  Future<void> fadeBgmVolume(double targetVolume, Duration duration);

  /// Plays a sequence of audio sprite segments back-to-back in low-latency native audio memory.
  Future<void> playSpriteSequence(
    SoundHandle handle,
    List<SpriteSegment> segments,
  );

  /// Retrieves a 256-element PCM audio waveform array currently outputting from the engine.
  Float32List getWaveform();

  /// Renders mixed audio directly into a 16-bit 44.1kHz mono WAV byte buffer for golden sound testing.
  Uint8List renderWavGolden({
    required Duration duration,
    int sampleRate = 44100,
  });

  /// Disposes of the audio engine and releases any held hardware/system resources.
  Future<void> dispose();
}

/// Recorded sprite sequence invocation for testing.
class RecordedSpriteSequence {
  /// The target sound handle played in the sequence.
  final SoundHandle handle;

  /// The list of sprite segments executed sequentially.
  final List<SpriteSegment> segments;

  /// Creates a new [RecordedSpriteSequence] with [handle] and [segments].
  const RecordedSpriteSequence(this.handle, this.segments);
}

/// A handle referencing a loaded sound.
class SoundHandle {
  /// The underlying platform-specific unique identifier.
  final dynamic id;

  /// Creates a new [SoundHandle] referencing [id].
  const SoundHandle(this.id);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SoundHandle &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'SoundHandle($id)';
}

/// A mock implementation of [AudioService] used for testing/headless execution.
class MockAudioService implements AudioService {
  bool _initialized = false;
  final List<SoundHandle> _playedSounds = [];
  final List<RecordedSpriteSequence> _playedSequences = [];
  double _bgmVolume = 1.0;

  /// Whether the mock audio service has been initialized.
  bool get initialized => _initialized;

  /// The list of sounds that have been triggered via [playSound].
  List<SoundHandle> get playedSounds => _playedSounds;

  /// The list of sprite sequences triggered via [playSpriteSequence].
  List<RecordedSpriteSequence> get playedSequences => _playedSequences;

  /// The active background music volume level.
  double get bgmVolume => _bgmVolume;

  @override
  Future<void> init() async {
    _initialized = true;
  }

  @override
  Future<SoundHandle> loadSound(String path) async {
    return SoundHandle(path);
  }

  @override
  Future<void> playSound(SoundHandle handle, {bool loop = false}) async {
    if (!_playedSounds.contains(handle)) {
      _playedSounds.add(handle);
    }
  }

  @override
  Future<void> stopSound(SoundHandle handle) async {
    _playedSounds.remove(handle);
  }

  @override
  Future<void> setBgmVolume(double volume) async {
    _bgmVolume = volume;
  }

  @override
  Future<void> setRelativePlaySpeed(SoundHandle handle, double speed) async {}

  @override
  Future<void> fadeRelativePlaySpeed(
    SoundHandle handle,
    double speed,
    Duration duration,
  ) async {}

  @override
  Future<void> fadeVolume(
    SoundHandle handle,
    double targetVolume,
    Duration duration,
  ) async {}

  @override
  Future<void> fadeBgmVolume(double targetVolume, Duration duration) async {}

  @override
  Future<void> playSpriteSequence(
    SoundHandle handle,
    List<SpriteSegment> segments,
  ) async {
    if (segments.isNotEmpty) {
      _playedSequences.add(RecordedSpriteSequence(handle, segments));
    }
  }

  @override
  Float32List getWaveform() {
    return Float32List(256);
  }

  @override
  Uint8List renderWavGolden({
    required Duration duration,
    int sampleRate = 44100,
  }) {
    final numSamples = (sampleRate * (duration.inMicroseconds / 1000000.0))
        .round();
    final dataSize = numSamples * 2;
    final fileSize = 36 + dataSize;

    final bytes = ByteData(44 + dataSize);
    // RIFF header
    bytes.setUint8(0, 0x52); // R
    bytes.setUint8(1, 0x49); // I
    bytes.setUint8(2, 0x46); // F
    bytes.setUint8(3, 0x46); // F
    bytes.setUint32(4, fileSize, Endian.little);
    bytes.setUint8(8, 0x57); // W
    bytes.setUint8(9, 0x41); // A
    bytes.setUint8(10, 0x56); // V
    bytes.setUint8(11, 0x45); // E
    // fmt subchunk
    bytes.setUint8(12, 0x66); // f
    bytes.setUint8(13, 0x6d); // m
    bytes.setUint8(14, 0x74); // t
    bytes.setUint8(15, 0x20); // ' '
    bytes.setUint32(16, 16, Endian.little); // Subchunk1Size (16 for PCM)
    bytes.setUint16(20, 1, Endian.little); // AudioFormat (1 for PCM)
    bytes.setUint16(22, 1, Endian.little); // NumChannels (1 mono)
    bytes.setUint32(24, sampleRate, Endian.little); // SampleRate
    bytes.setUint32(28, sampleRate * 2, Endian.little); // ByteRate
    bytes.setUint16(32, 2, Endian.little); // BlockAlign
    bytes.setUint16(34, 16, Endian.little); // BitsPerSample
    // data subchunk
    bytes.setUint8(36, 0x64); // d
    bytes.setUint8(37, 0x61); // a
    bytes.setUint8(38, 0x74); // t
    bytes.setUint8(39, 0x61); // a
    bytes.setUint32(40, dataSize, Endian.little);

    return bytes.buffer.asUint8List();
  }

  @override
  Future<void> dispose() async {
    _initialized = false;
    _playedSounds.clear();
    _playedSequences.clear();
  }
}
