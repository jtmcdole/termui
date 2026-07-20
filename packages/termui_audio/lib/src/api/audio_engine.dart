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
}
