import 'src/audio_service.dart';
import 'src/audio_service_stub.dart'
    if (dart.library.js_interop) 'src/audio_service_web.dart'
    if (dart.library.io) 'src/audio_service_cli.dart'
    if (dart.library.ui) 'src/audio_service_flutter.dart';

export 'src/audio_service.dart'
    show AudioService, SoundHandle, MockAudioService;

/// The top-level multiplatform entry point for the termui audio system.
class TermuiAudio {
  static AudioService? _instance;

  /// Retrieves the active platform-specific [AudioService] implementation.
  static AudioService get instance => _instance ??= createAudioService();

  /// Sets the active [AudioService] implementation.
  static set instance(AudioService value) => _instance = value;

  /// Initializes the audio engine.
  static Future<void> init() => instance.init();

  /// Loads a sound file from the given path or URL and returns a unique [SoundHandle].
  static Future<SoundHandle> loadSound(String path) => instance.loadSound(path);

  /// Plays a loaded sound identified by [handle].
  static Future<void> playSound(SoundHandle handle, {bool loop = false}) =>
      instance.playSound(handle, loop: loop);

  /// Stops a playing sound identified by [handle].
  static Future<void> stopSound(SoundHandle handle) =>
      instance.stopSound(handle);

  /// Sets the volume of the played sound (or background music).
  static Future<void> setBgmVolume(double volume) =>
      instance.setBgmVolume(volume);

  /// Disposes of the audio engine and releases any held hardware/system resources.
  static Future<void> dispose() => instance.dispose();
}
