import 'src/api/audio_engine.dart';
import 'src/api/audio_types.dart';
import 'src/impl/engine_factory_stub.dart'
    if (dart.library.io) 'src/impl/engine_factory_cli.dart'
    if (dart.library.ui) 'src/impl/engine_factory_flutter.dart';

export 'src/api/audio_engine.dart';
export 'src/api/audio_types.dart';

/// The top-level multiplatform entry point for the termui audio system.
class TermuiAudio {
  static TermuiAudioEngine? _instance;

  /// Retrieves the active platform-specific [TermuiAudioEngine] implementation.
  static TermuiAudioEngine get instance => _instance ??= createAudioEngine();

  /// Sets the active [TermuiAudioEngine] implementation.
  static set instance(TermuiAudioEngine value) => _instance = value;

  /// Initializes the audio engine.
  static Future<void> init({bool enableVisualization = true}) =>
      instance.init(enableVisualization: enableVisualization);

  /// Disposes of the audio engine and releases any held hardware/system resources.
  static Future<void> dispose() => instance.dispose();
}

/// Convenient playhead tracking extension on [AudioVoice].
extension AudioVoicePlayhead on AudioVoice {
  /// Emits real-time playhead updates directly from the audio engine.
  Stream<Duration> positionStream({
    TermuiAudioEngine? engine,
    Duration interval = const Duration(milliseconds: 50),
  }) {
    return (engine ?? TermuiAudio.instance).getVoicePositionStream(
      this,
      interval: interval,
    );
  }
}
