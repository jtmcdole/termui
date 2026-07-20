import '../api/audio_engine.dart';
import 'cli/cli_audio_engine.dart';

/// Creates a new [TermuiAudioEngine] using the CLI backend.
TermuiAudioEngine createAudioEngine() => CliAudioEngine();
