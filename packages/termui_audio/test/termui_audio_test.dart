import 'dart:io';
import 'package:test/test.dart';
import 'package:termui_audio/termui_audio.dart';
import 'package:termui_audio/src/audio_service_cli_impl.dart';

void main() {
  group('TermuiAudio Tests', () {
    test('MockAudioService lifecycle', () async {
      // Create a mock service to test interface compliance without hardware dependencies
      final mock = MockAudioService();
      expect(mock.initialized, isFalse);

      await mock.init();
      expect(mock.initialized, isTrue);

      final sound = await mock.loadSound('test_assets/sound.wav');
      expect(sound.id, equals('test_assets/sound.wav'));

      expect(mock.playedSounds, isEmpty);
      await mock.playSound(sound, loop: true);
      expect(mock.playedSounds, contains(sound));

      await mock.stopSound(sound);
      expect(mock.playedSounds, isNot(contains(sound)));

      await mock.dispose();
      expect(mock.initialized, isFalse);
    });

    test('CliAudioService (SoLoud C++ CLI Backend) integration test', () async {
      final cli = CliAudioService();
      await cli.init();

      final soundPath = 'src/filters/signalsmith-stretch/web/demo/loop.mp3';
      var file = File('${Directory.current.path}/$soundPath');
      if (!file.existsSync()) {
        file = File(
          '${Directory.current.path}/packages/termui_audio/$soundPath',
        );
      }
      expect(file.existsSync(), isTrue);

      final handle = await cli.loadSound(file.path);
      expect(handle, isNotNull);

      // Play the sound (non-looping)
      await cli.playSound(handle);

      // Set volume
      await cli.setBgmVolume(0.5);

      // Stop the sound
      await cli.stopSound(handle);

      // Clean up
      await cli.dispose();
    });
  });
}
