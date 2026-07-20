// ignore_for_file: public_member_api_docs
import 'dart:async';

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

  /// Disposes of the audio engine and releases any held hardware/system resources.
  Future<void> dispose();
}

/// A handle referencing a loaded sound.
class SoundHandle {
  /// The underlying platform-specific unique identifier.
  final dynamic id;

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
  double _bgmVolume = 1.0;

  bool get initialized => _initialized;
  List<SoundHandle> get playedSounds => _playedSounds;
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
  Future<void> dispose() async {
    _initialized = false;
    _playedSounds.clear();
  }
}
