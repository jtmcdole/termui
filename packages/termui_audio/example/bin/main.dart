// ignore_for_file: public_member_api_docs, avoid_print
import 'dart:io';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui_audio/termui_audio.dart';
import 'package:termui_audio_example/src/audio_player_app.dart';

void main() async {
  // Get the active audio service backend
  final audioService = TermuiAudio.instance;
  await audioService.init();

  // Define asset loader for CLI targeting the local filesystem paths
  Future<AudioBuffer> cliLoadAsset(
    String assetPath, {
    LoadProgressCallback? onProgress,
  }) async {
    var file = File(assetPath);
    if (!file.existsSync()) {
      file = File('example/$assetPath');
    }
    if (!file.existsSync()) {
      file = File('packages/termui_audio/example/$assetPath');
    }
    if (!file.existsSync()) {
      throw Exception('Could not find audio asset at $assetPath');
    }
    final absPath = file.absolute.path;
    return await audioService.loadFile(absPath, onProgress: onProgress);
  }

  try {
    // Run the terminal UI guarded to ensure terminal configuration is restored on exit
    await term.Terminal.runGuarded((terminal) async {
      await runAudioPlayerApp(terminal, audioService, cliLoadAsset);
    });
  } finally {
    // Dispose the audio service and release hardware resources
    await audioService.dispose();
  }

  print('Audio player example exited cleanly.');
  exit(0);
}
