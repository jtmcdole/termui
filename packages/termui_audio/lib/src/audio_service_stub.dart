import 'audio_service.dart';

/// Default factory function throwing on unsupported platforms.
AudioService createAudioService() =>
    throw UnsupportedError('AudioService is not supported on this platform.');
