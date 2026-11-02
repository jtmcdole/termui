import 'package:termui_audio/termui_audio.dart';

import 'src/flutter_audio_engine.dart';

export 'package:termui_audio/termui_audio.dart';
export 'src/flutter_audio_engine.dart';

/// Registration entry point for the Flutter and Web SoLoud audio backend.
abstract final class TermuiAudioFlutter {
  /// Instantiates a [FlutterAudioEngine], assigns it to [TermuiAudio.instance], and returns it.
  static FlutterAudioEngine register() {
    final engine = FlutterAudioEngine();
    TermuiAudio.instance = engine;
    return engine;
  }
}
