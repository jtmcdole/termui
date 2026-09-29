import 'dart:typed_data';
import 'audio_types.dart';

/// The core engine service abstracting the audio backend.
abstract class TermuiAudioEngine {
  /// Initializes the audio engine.
  Future<void> init({bool enableVisualization = true});

  /// Disposes the audio engine and releases resources.
  Future<void> dispose();

  /// Loads a sound file from the local file system or asset bundle.
  ///
  /// When [stream] is true, the audio is streamed on-the-fly rather than
  /// fully decompressed into resident memory.
  Future<AudioBuffer> loadFile(
    String path, {
    bool stream = false,
    LoadProgressCallback? onProgress,
  });

  /// Reads a sound file into bytes.
  Future<Uint8List> loadFileBytes(String path);

  /// Loads a sound file from a remote URL.
  Future<AudioBuffer> loadUrl(String url, {LoadProgressCallback? onProgress});

  /// Loads a synthetic waveform generator.
  Future<AudioBuffer> loadWaveform(
    WaveForm shape,
    double frequency, {
    bool usePcmFallback = false,
  });

  /// Loads audio from memory bytes.
  ///
  /// When [stream] is true, the audio is decoded on-the-fly using a sliding window.
  Future<AudioBuffer> loadMem(
    String pathId,
    Uint8List bytes, {
    bool stream = false,
  });

  /// Creates an in-memory streaming audio buffer for progressive chunk loading
  /// (e.g. loading segments of large audio files).
  ///
  /// When [releaseConsumed] is true, consumed audio samples are discarded from the
  /// circular buffer, keeping resident memory capped at [maxBufferSize].
  Future<AudioBuffer> createBufferStream({
    int maxBufferSize = 4 * 1024 * 1024,
    bool releaseConsumed = false,
    Duration bufferingTimeNeeds = const Duration(milliseconds: 500),
    int sampleRate = 48000,
    int channels = 2,
  });

  /// Appends an audio data chunk (e.g. from an HTTP range response or package slice)
  /// to an active buffer stream.
  void addStreamData(AudioBuffer buffer, Uint8List chunk);

  /// Signals that all audio chunks have been added to the stream buffer.
  void setStreamEnded(AudioBuffer buffer);

  /// Disposes of the audio buffer, freeing native memory.
  Future<void> disposeBuffer(AudioBuffer buffer);

  /// Plays a loaded [buffer].
  AudioVoice play(
    AudioBuffer buffer, {
    bool loop = false,
    AudioBus? bus,
    bool paused = false,
  });

  /// Stops a playing [voice].
  void stop(AudioVoice voice);

  /// Sets the volume of a playing [voice].
  void setVoiceVolume(AudioVoice voice, double volume);

  /// Pauses or unpauses a playing [voice].
  void setPaused(AudioVoice voice, bool paused);

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
  ///
  /// When [preservePitch] is true, speech pitch is preserved using DSP time-stretching
  /// without producing chipmunk or slow groaning effects.
  void setRelativePlaySpeed(
    AudioVoice voice,
    double speed, {
    bool preservePitch = false,
  });

  /// Retrieves a stream emitting real-time playhead updates for [voice].
  ///
  /// The stream emits at the specified [interval] and completes automatically
  /// when the voice finishes or stops.
  Stream<Duration> getVoicePositionStream(
    AudioVoice voice, {
    Duration interval = const Duration(milliseconds: 50),
  });

  /// Smoothly fades the relative play speed of a playing [voice] to [speed] over [duration].
  void fadeRelativePlaySpeed(AudioVoice voice, double speed, Duration duration);

  /// Smoothly fades the volume of a playing [voice] to [targetVolume] over [duration].
  void fadeVolume(AudioVoice voice, double targetVolume, Duration duration);

  /// Schedules the specified [voice] to stop after [duration].
  void scheduleStop(AudioVoice voice, Duration duration);

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

  /// Retrieves a specific parameter [paramId] from a filter attached to [bus].
  double getFilterParameter(AudioBus bus, int filterId, int paramId);

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
    AudioBus? bus,
  });

  /// Plays a sequence of audio sprite segments back-to-back in low-latency native audio memory.
  ///
  /// WARNING: This method currently relies on Dart timers for sequencing, which can be
  /// brittle and lead to stuttering or gaps. Avoid relying on this for sample-accurate
  /// sequencing until `playClocked` and `play3dClocked` are available from the underlying backend.
  Future<void> playSpriteSequence(
    AudioBuffer buffer,
    List<SpriteSegment> segments, {
    AudioBus? bus,
  });

  /// Dynamically creates a new native mixing bus.
  AudioBus createBus();

  /// Destroys a native mixing bus [bus].
  void destroyBus(AudioBus bus);

  /// Retrieves a 256-element PCM audio waveform array currently outputting from the engine.
  ///
  /// If [outBuffer] is provided, it must be at least 256 elements long and will be populated
  /// and returned. Otherwise, a new [Float32List] is allocated.
  Float32List getWaveform([Float32List? outBuffer]);
}
