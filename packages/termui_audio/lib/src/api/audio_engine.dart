import 'audio_types.dart';

/// The core engine service abstracting the audio backend.
abstract class TermuiAudioEngine {
  /// Initializes the audio engine.
  Future<void> init();

  /// Disposes the audio engine and releases resources.
  Future<void> dispose();

  /// Loads a sound file from the local file system.
  Future<AudioBuffer> loadFile(String path, {LoadProgressCallback? onProgress});

  /// Loads a sound file from a remote URL.
  Future<AudioBuffer> loadUrl(String url, {LoadProgressCallback? onProgress});

  /// Loads a synthetic waveform generator.
  Future<AudioBuffer> loadWaveform(WaveForm shape, double frequency);

  /// Plays a loaded [buffer].
  AudioVoice play(AudioBuffer buffer, {bool loop = false, AudioBus? bus});

  /// Stops a playing [voice].
  void stop(AudioVoice voice);

  /// Sets the volume of a playing [voice].
  void setVoiceVolume(AudioVoice voice, double volume);

  /// Plays a loaded [buffer] at a specific 3D location.
  AudioVoice play3d(AudioBuffer buffer, double x, double y, double z);

  /// Updates the 3D position and velocity of a playing [voice].
  void set3dSourceParameters(
    AudioVoice voice,
    double x,
    double y,
    double z, {
    double vx = 0.0,
    double vy = 0.0,
    double vz = 0.0,
  });

  /// Sets the minimum and maximum distance parameters of a 3D audio source.
  void set3dSourceMinMaxDistance(
    AudioVoice voice,
    double minDistance,
    double maxDistance,
  );

  /// Sets the attenuation model and rolloff factor of a 3D audio source.
  void set3dSourceAttenuation(
    AudioVoice voice,
    AttenuationModel attenuationModel,
    double attenuationRolloffFactor,
  );

  /// Retrieves the total duration of a loaded audio buffer.
  Duration getBufferDuration(AudioBuffer buffer);

  /// Retrieves the current playhead position of a playing voice.
  Duration getVoicePosition(AudioVoice voice);

  /// Seeks a playing voice to a specific time position.
  void seek(AudioVoice voice, Duration position);

  /// Sets the relative playback speed multiplier for a playing [voice].
  void setRelativePlaySpeed(AudioVoice voice, double speed);

  /// Smoothly fades the relative play speed of a playing [voice] to [speed] over [duration].
  void fadeRelativePlaySpeed(AudioVoice voice, double speed, Duration duration);

  /// Smoothly fades the volume of a playing [voice] to [targetVolume] over [duration].
  void fadeVolume(AudioVoice voice, double targetVolume, Duration duration);

  /// Creates a filter instance of the given [type] and returns a filter identifier handle.
  int createFilter(FilterType type);

  /// Attaches a created filter [filterId] to a native mixing [bus].
  void attachFilterToBus(AudioBus bus, int filterId);

  /// Sets a specific parameter [paramId] on a filter attached to [bus] to [value].
  void setFilterParameter(
    AudioBus bus,
    int filterId,
    int paramId,
    double value,
  );

  /// Fades a parameter [paramId] on a filter attached to [bus] to [targetValue] over [duration].
  void fadeFilterParameter(
    AudioBus bus,
    int filterId,
    int paramId,
    double targetValue,
    Duration duration,
  );

  /// Plays a segment/sprite of a loaded [buffer] starting at [start] for [duration].
  AudioVoice playSprite(
    AudioBuffer buffer, {
    required Duration start,
    required Duration duration,
  });

  /// Dynamically creates a new native mixing bus.
  AudioBus createBus();

  /// Destroys a native mixing bus [bus].
  void destroyBus(AudioBus bus);
}
