import 'dart:io';
import 'package:test/test.dart';
import 'package:termui_audio/src/impl/cli/cli_audio_engine.dart';

void main() {
  group('TermuiAudio Tests', () {
    test(
      'CliAudioEngine lifecycle and FFI bindings integration test',
      () async {
        final cli = CliAudioEngine();
        await cli.init();

        final soundPath = 'src/filters/signalsmith-stretch/web/demo/loop.mp3';
        var file = File('${Directory.current.path}/$soundPath');
        if (!file.existsSync()) {
          file = File(
            '${Directory.current.path}/packages/termui_audio/$soundPath',
          );
        }
        expect(file.existsSync(), isTrue);

        final buffer = await cli.loadFile(file.path);
        expect(buffer, isNotNull);

        // Play the sound (non-looping)
        final voice = cli.play(buffer);
        expect(voice, isNotNull);

        // Verify 3D positioning doesn't crash (requires voice.id)
        cli.set3dSourceParameters(voice, 1.0, 2.0, 3.0);

        // Stop the sound
        cli.stop(voice);

        // Clean up
        await cli.dispose();
      },
    );
  });
}
