import '../api/audio_engine.dart';
import '../api/audio_types.dart';

/// A stub implementation of [TermuiAudioEngine] for unsupported platforms.
class StubAudioEngine implements TermuiAudioEngine {
  @override
  Future<void> init() async => throw UnsupportedError('StubAudioEngine');
  @override
  Future<void> dispose() async => throw UnsupportedError('StubAudioEngine');
  @override
  Future<AudioBuffer> loadFile(
    String path, {
    LoadProgressCallback? onProgress,
  }) async => throw UnsupportedError('StubAudioEngine');
  @override
  Future<AudioBuffer> loadUrl(
    String url, {
    LoadProgressCallback? onProgress,
  }) async => throw UnsupportedError('StubAudioEngine');
  @override
  Future<AudioBuffer> loadWaveform(WaveForm shape, double frequency) async =>
      throw UnsupportedError('StubAudioEngine');
  @override
  AudioVoice play(AudioBuffer buffer, {bool loop = false, AudioBus? bus}) =>
      throw UnsupportedError('StubAudioEngine');
  @override
  void stop(AudioVoice voice) => throw UnsupportedError('StubAudioEngine');
  @override
  void setVoiceVolume(AudioVoice voice, double volume) =>
      throw UnsupportedError('StubAudioEngine');
  @override
  AudioVoice play3d(AudioBuffer buffer, double x, double y, double z) =>
      throw UnsupportedError('StubAudioEngine');
  @override
  void set3dSourceParameters(
    AudioVoice voice,
    double x,
    double y,
    double z, {
    double vx = 0.0,
    double vy = 0.0,
    double vz = 0.0,
  }) => throw UnsupportedError('StubAudioEngine');
  @override
  void set3dSourceMinMaxDistance(
    AudioVoice voice,
    double minDistance,
    double maxDistance,
  ) => throw UnsupportedError('StubAudioEngine');
  @override
  void set3dSourceAttenuation(
    AudioVoice voice,
    AttenuationModel attenuationModel,
    double attenuationRolloffFactor,
  ) => throw UnsupportedError('StubAudioEngine');
  @override
  Duration getBufferDuration(AudioBuffer buffer) =>
      throw UnsupportedError('StubAudioEngine');
  @override
  Duration getVoicePosition(AudioVoice voice) =>
      throw UnsupportedError('StubAudioEngine');
  @override
  void seek(AudioVoice voice, Duration position) =>
      throw UnsupportedError('StubAudioEngine');

  @override
  void setRelativePlaySpeed(AudioVoice voice, double speed) =>
      throw UnsupportedError('StubAudioEngine');
  @override
  void fadeRelativePlaySpeed(
    AudioVoice voice,
    double speed,
    Duration duration,
  ) => throw UnsupportedError('StubAudioEngine');
  @override
  void fadeVolume(AudioVoice voice, double targetVolume, Duration duration) =>
      throw UnsupportedError('StubAudioEngine');
  @override
  int createFilter(FilterType type) =>
      throw UnsupportedError('StubAudioEngine');
  @override
  void attachFilterToBus(AudioBus bus, int filterId) =>
      throw UnsupportedError('StubAudioEngine');
  @override
  void setFilterParameter(
    AudioBus bus,
    int filterId,
    int paramId,
    double value,
  ) => throw UnsupportedError('StubAudioEngine');
  @override
  void fadeFilterParameter(
    AudioBus bus,
    int filterId,
    int paramId,
    double targetValue,
    Duration duration,
  ) => throw UnsupportedError('StubAudioEngine');
  @override
  AudioVoice playSprite(
    AudioBuffer buffer, {
    required Duration start,
    required Duration duration,
  }) => throw UnsupportedError('StubAudioEngine');
  @override
  AudioBus createBus() => throw UnsupportedError('StubAudioEngine');
  @override
  void destroyBus(AudioBus bus) => throw UnsupportedError('StubAudioEngine');
}

/// Creates a new [TermuiAudioEngine] throwing an unsupported error.
TermuiAudioEngine createAudioEngine() => StubAudioEngine();
