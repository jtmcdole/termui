import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:termui_audio/src/api/audio_types.dart';
import 'package:termui_audio/src/impl/cli/cli_audio_engine.dart';

Future<AudioBuffer> _loadBuffer(CliAudioEngine cli) async {
  const soundPath = 'src/filters/signalsmith-stretch/web/demo/loop.mp3';
  var file = File('${Directory.current.path}/$soundPath');
  if (!file.existsSync()) {
    file = File('${Directory.current.path}/packages/termui_audio/$soundPath');
  }
  expect(file.existsSync(), isTrue, reason: 'Test audio file must exist');
  return cli.loadFile(file.path);
}

void main() {
  late CliAudioEngine cli;
  late AudioBuffer buffer;

  setUp(() async {
    cli = CliAudioEngine();
    await cli.init();
    buffer = await _loadBuffer(cli);
  });

  tearDown(() async {
    await cli.dispose();
  });

  group('DSP Edge Case 1: Speed Multipliers (Negative / Zero / Extreme)', () {
    test('setRelativePlaySpeed with 0.0 speed', () {
      final voice = cli.play(buffer);
      expect(() => cli.setRelativePlaySpeed(voice, 0.0), returnsNormally);
      cli.stop(voice);
    });

    test('setRelativePlaySpeed with negative speed (-1.0, -0.5)', () {
      final voice = cli.play(buffer);
      expect(() => cli.setRelativePlaySpeed(voice, -1.0), returnsNormally);
      expect(() => cli.setRelativePlaySpeed(voice, -0.5), returnsNormally);
      cli.stop(voice);
    });

    test('setRelativePlaySpeed with extreme large speed (100.0, 1e5)', () {
      final voice = cli.play(buffer);
      expect(() => cli.setRelativePlaySpeed(voice, 100.0), returnsNormally);
      expect(() => cli.setRelativePlaySpeed(voice, 1e5), returnsNormally);
      cli.stop(voice);
    });

    test('fadeRelativePlaySpeed with 0.0 target speed', () {
      final voice = cli.play(buffer);
      expect(
        () => cli.fadeRelativePlaySpeed(
          voice,
          0.0,
          const Duration(milliseconds: 100),
        ),
        returnsNormally,
      );
      cli.stop(voice);
    });

    test('fadeRelativePlaySpeed with negative target speed (-1.0)', () {
      final voice = cli.play(buffer);
      expect(
        () => cli.fadeRelativePlaySpeed(
          voice,
          -1.0,
          const Duration(milliseconds: 100),
        ),
        returnsNormally,
      );
      cli.stop(voice);
    });
  });

  group('DSP Edge Case 2: Duration = 0ms (Fades and Sprites)', () {
    test('fadeRelativePlaySpeed with duration = 0ms', () {
      final voice = cli.play(buffer);
      expect(
        () => cli.fadeRelativePlaySpeed(voice, 1.5, Duration.zero),
        returnsNormally,
      );
      cli.stop(voice);
    });

    test('fadeVolume with duration = 0ms', () {
      final voice = cli.play(buffer);
      expect(() => cli.fadeVolume(voice, 0.5, Duration.zero), returnsNormally);
      cli.stop(voice);
    });

    test('fadeFilterParameter with duration = 0ms', () {
      final bus = cli.createBus();
      final filterId = cli.createFilter(FilterType.biquadResonant);
      cli.attachFilterToBus(bus, filterId);

      expect(
        () => cli.fadeFilterParameter(bus, filterId, 0, 1000.0, Duration.zero),
        returnsNormally,
      );
      cli.destroyBus(bus);
    });

    test(
      'playSprite with duration = 0ms auto-stops without throwing',
      () async {
        final voice = cli.playSprite(
          buffer,
          start: const Duration(milliseconds: 100),
          duration: Duration.zero,
        );
        expect(voice, isNotNull);
        expect(voice.id, greaterThan(0));
        // Wait for 0ms timer callback execution
        await Future<void>.delayed(const Duration(milliseconds: 20));
      },
    );
  });

  group('DSP Edge Case 3: Invalid Voice Handles', () {
    final invalidVoice0 = AudioVoice(0, Completer<void>().future);
    final invalidVoiceNeg1 = AudioVoice(-1, Completer<void>().future);
    final invalidVoiceLarge = AudioVoice(999999, Completer<void>().future);

    test(
      'Operations on invalid voice handle (0, -1, 999999) do not crash native process',
      () {
        for (final invalidVoice in [
          invalidVoice0,
          invalidVoiceNeg1,
          invalidVoiceLarge,
        ]) {
          expect(() => cli.setVoiceVolume(invalidVoice, 0.5), returnsNormally);
          expect(() => cli.stop(invalidVoice), returnsNormally);
          expect(
            () => cli.seek(invalidVoice, const Duration(seconds: 1)),
            returnsNormally,
          );
          expect(() => cli.getVoicePosition(invalidVoice), returnsNormally);
          expect(
            () => cli.setRelativePlaySpeed(invalidVoice, 1.5),
            returnsNormally,
          );
          expect(
            () => cli.fadeRelativePlaySpeed(
              invalidVoice,
              1.5,
              const Duration(milliseconds: 100),
            ),
            returnsNormally,
          );
          expect(
            () => cli.fadeVolume(
              invalidVoice,
              0.5,
              const Duration(milliseconds: 100),
            ),
            returnsNormally,
          );
          expect(
            () => cli.set3dSourceParameters(invalidVoice, 1, 2, 3),
            returnsNormally,
          );
          expect(
            () => cli.set3dSourceMinMaxDistance(invalidVoice, 1, 10),
            returnsNormally,
          );
          expect(
            () => cli.set3dSourceAttenuation(
              invalidVoice,
              AttenuationModel.linearDistance,
              1.0,
            ),
            returnsNormally,
          );
        }
      },
    );

    test(
      'getVoicePosition on invalid/stopped voice returns Duration.zero safely',
      () {
        final pos0 = cli.getVoicePosition(invalidVoice0);
        expect(pos0, equals(Duration.zero));
        final posLarge = cli.getVoicePosition(invalidVoiceLarge);
        expect(posLarge, equals(Duration.zero));
      },
    );
  });

  group('DSP Edge Case 4: Out-of-bounds Filter Parameter Values & IDs', () {
    test(
      'setFilterParameter with invalid/out-of-bounds parameter IDs (-1, 999)',
      () {
        final bus = cli.createBus();
        final filterId = cli.createFilter(FilterType.biquadResonant);
        cli.attachFilterToBus(bus, filterId);

        // Parameter ID -1 and 999 are ignored by native SoLoud without crashing
        expect(
          () => cli.setFilterParameter(bus, filterId, -1, 1.0),
          returnsNormally,
        );
        expect(
          () => cli.setFilterParameter(bus, filterId, 999, 1.0),
          returnsNormally,
        );

        cli.destroyBus(bus);
      },
    );

    test('setFilterParameter with extreme values (-99999.0, 0.0, 1e12)', () {
      final bus = cli.createBus();
      final filterId = cli.createFilter(FilterType.biquadResonant);
      cli.attachFilterToBus(bus, filterId);

      expect(
        () => cli.setFilterParameter(bus, filterId, 0, -99999.0),
        returnsNormally,
      );
      expect(
        () => cli.setFilterParameter(bus, filterId, 0, 0.0),
        returnsNormally,
      );
      expect(
        () => cli.setFilterParameter(bus, filterId, 0, 1e12),
        returnsNormally,
      );

      cli.destroyBus(bus);
    });

    test('fadeFilterParameter with negative target parameter value', () {
      final bus = cli.createBus();
      final filterId = cli.createFilter(FilterType.biquadResonant);
      cli.attachFilterToBus(bus, filterId);

      expect(
        () => cli.fadeFilterParameter(
          bus,
          filterId,
          0,
          -500.0,
          const Duration(milliseconds: 50),
        ),
        returnsNormally,
      );

      cli.destroyBus(bus);
    });

    test('attachFilterToBus with invalid filter handle (e.g. 999)', () {
      final bus = cli.createBus();
      try {
        cli.attachFilterToBus(bus, 999);
      } catch (e) {
        expect(e.toString(), contains('Failed to attach filter to bus'));
      } finally {
        cli.destroyBus(bus);
      }
    });
  });

  group('DSP Edge Case 5: Destroying Non-existent / Duplicate Buses', () {
    test('destroyBus with non-existent bus handle (id = 0, -1, 999999)', () {
      expect(() => cli.destroyBus(const CliAudioBus(0)), returnsNormally);
      expect(() => cli.destroyBus(const CliAudioBus(-1)), returnsNormally);
      expect(() => cli.destroyBus(const CliAudioBus(999999)), returnsNormally);
    });

    test('destroyBus called twice on the same bus handle', () {
      final bus = cli.createBus();
      expect(bus.id, greaterThan(0));

      expect(() => cli.destroyBus(bus), returnsNormally);
      // Second destroy call is ignored safely by native SoLoud
      expect(() => cli.destroyBus(bus), returnsNormally);
    });

    test(
      'attachFilterToBus on destroyed bus handle throws Exception with error code 31',
      () {
        final bus = cli.createBus();
        cli.destroyBus(bus);

        final filterId = cli.createFilter(FilterType.echo);
        expect(
          () => cli.attachFilterToBus(bus, filterId),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('Failed to attach filter to bus. Error code: 31'),
            ),
          ),
        );
      },
    );

    test(
      'setFilterParameter and bus.setVolume on destroyed bus handle return normally without crashing',
      () {
        final bus = cli.createBus();
        cli.destroyBus(bus);

        final filterId = cli.createFilter(FilterType.echo);
        expect(
          () => cli.setFilterParameter(bus, filterId, 0, 0.5),
          returnsNormally,
        );
        expect(() => bus.setVolume(0.5), returnsNormally);
      },
    );
  });
}
