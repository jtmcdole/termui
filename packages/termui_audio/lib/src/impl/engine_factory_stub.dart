import '../api/audio_engine.dart';

/// Creates a new [TermuiAudioEngine] throwing an unsupported error.
TermuiAudioEngine createAudioEngine() =>
    throw UnsupportedError('Platform not supported');
