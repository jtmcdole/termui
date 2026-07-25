import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:termui_audio/termui_audio.dart';
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
  group('DSP & Audio Engine Stress Test Harness', () {
    late CliAudioEngine engine;
    late AudioBuffer buffer;

    setUp(() async {
      engine = CliAudioEngine();
      await engine.init();
      buffer = await _loadBuffer(engine);
    });

    tearDown(() async {
      await engine.dispose();
    });

    test(
      'ST-01: High-frequency voice playback and play speed updates (500 iterations)',
      () async {
        final voices = <AudioVoice>[];
        for (var i = 0; i < 500; i++) {
          final voice = engine.play(buffer);
          expect(voice.id, greaterThan(0));
          voices.add(voice);

          final speed = 0.5 + (i % 10) * 0.25;
          engine.setRelativePlaySpeed(voice, speed);
        }

        for (final voice in voices) {
          engine.stop(voice);
        }
      },
    );

    test('ST-02: Rapid volume envelope fade flooding (1000 fades)', () async {
      final voice = engine.play(buffer);
      expect(voice.id, greaterThan(0));

      for (var i = 0; i < 1000; i++) {
        final targetVol = (i % 2 == 0) ? 0.9 : 0.05;
        final durMs = (i % 20) + 1;
        engine.fadeVolume(voice, targetVol, Duration(milliseconds: durMs));
      }

      engine.stop(voice);
    });

    test(
      'ST-03: Play speed fading stress and extreme boundary values',
      () async {
        final voice = engine.play(buffer);

        // Extreme speed values
        engine.setRelativePlaySpeed(voice, 0.0);
        engine.setRelativePlaySpeed(voice, 0.001);
        engine.setRelativePlaySpeed(voice, 50.0);
        engine.setRelativePlaySpeed(voice, -1.0);

        // Fading play speed rapidly
        for (var i = 0; i < 200; i++) {
          final targetSpeed = 0.1 + (i % 50) * 0.1;
          engine.fadeRelativePlaySpeed(
            voice,
            targetSpeed,
            Duration(milliseconds: (i % 10) + 1),
          );
        }

        engine.stop(voice);
      },
    );

    test(
      'ST-04: Dynamic multi-filter pipeline & high-frequency parameter flooding',
      () async {
        final bus = engine.createBus();
        expect(bus.id, greaterThan(0));

        final filterIds = <int>[];
        // Native backend supports max FILTERS_PER_STREAM = 8 per bus
        for (final type in FilterType.values.take(8)) {
          final filterId = engine.createFilter(type);
          engine.attachFilterToBus(bus, filterId);
          filterIds.add(filterId);
        }

        // Assert that attaching a 9th filter throws maxNumberOfFiltersReached (error code 14)
        final filter9 = engine.createFilter(FilterType.limiter);
        expect(
          () => engine.attachFilterToBus(bus, filter9),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('Error code: 14'),
            ),
          ),
        );

        // Assert that attaching a duplicate filter throws filterAlreadyAdded
        final dupFilter = engine.createFilter(FilterType.biquadResonant);
        expect(
          () => engine.attachFilterToBus(bus, dupFilter),
          throwsA(isA<Exception>()),
        );

        final voice = engine.play(buffer, bus: bus);

        // Flood filter parameter updates across all 8 attached filters
        for (var i = 0; i < 500; i++) {
          final filterId = filterIds[i % filterIds.length];
          final paramId = i % 4;
          final val = (i * 13.37) % 1000.0;
          engine.setFilterParameter(bus, filterId, paramId, val);
          engine.fadeFilterParameter(
            bus,
            filterId,
            paramId,
            val * 1.5,
            Duration(milliseconds: (i % 15) + 1),
          );
        }

        engine.stop(voice);
        engine.destroyBus(bus);
      },
    );

    test(
      'ST-05: Bus churn (rapid creation, active voice binding, filter attachment, destruction)',
      () async {
        for (var cycle = 0; cycle < 100; cycle++) {
          final bus = engine.createBus();
          expect(bus.id, greaterThan(0));

          final filterId = engine.createFilter(FilterType.biquadResonant);
          engine.attachFilterToBus(bus, filterId);

          final voice = engine.play(buffer, bus: bus);
          engine.setFilterParameter(bus, filterId, 0, 440.0 + cycle);

          engine.stop(voice);
          engine.destroyBus(bus);
        }
      },
    );

    test(
      'ST-06: Sprite splicing high-frequency churn and boundary conditions',
      () async {
        final spriteVoices = <AudioVoice>[];

        // High-frequency sprite triggering
        for (var i = 0; i < 200; i++) {
          final startMs = (i * 50) % 2000;
          final durMs = (i % 30) + 5;
          final voice = engine.playSprite(
            buffer,
            start: Duration(milliseconds: startMs),
            duration: Duration(milliseconds: durMs),
          );
          expect(voice.id, greaterThan(0));
          spriteVoices.add(voice);
        }

        // Boundary condition: micro-duration sprite
        final microVoice = engine.playSprite(
          buffer,
          start: const Duration(milliseconds: 100),
          duration: const Duration(microseconds: 1),
        );
        expect(microVoice.id, greaterThan(0));

        // Boundary condition: zero-duration sprite
        final zeroVoice = engine.playSprite(
          buffer,
          start: const Duration(milliseconds: 100),
          duration: Duration.zero,
        );
        expect(zeroVoice.id, greaterThan(0));

        // Boundary condition: start far beyond duration
        final outOfBoundsVoice = engine.playSprite(
          buffer,
          start: const Duration(hours: 10),
          duration: const Duration(milliseconds: 50),
        );
        expect(outOfBoundsVoice.id, greaterThan(0));

        // Stop all sprite voices cleanly
        for (final v in spriteVoices) {
          engine.stop(v);
        }
        engine.stop(microVoice);
        engine.stop(zeroVoice);
        engine.stop(outOfBoundsVoice);
      },
    );

    test('ST-07: Concurrent multi-bus polyphonic filter stress', () async {
      final buses = <AudioBus>[];
      final voices = <AudioVoice>[];

      for (var b = 0; b < 16; b++) {
        final bus = engine.createBus();
        buses.add(bus);

        final filterId = engine.createFilter(FilterType.echo);
        engine.attachFilterToBus(bus, filterId);

        final voice = engine.play(buffer, bus: bus);
        voices.add(voice);

        engine.setFilterParameter(bus, filterId, 0, 0.2);
        engine.fadeFilterParameter(
          bus,
          filterId,
          1,
          0.8,
          const Duration(milliseconds: 100),
        );
      }

      for (final v in voices) {
        engine.stop(v);
      }
      for (final b in buses) {
        engine.destroyBus(b);
      }
    });

    test('ST-08: Invalid handle resilience testing', () async {
      final dummyVoice = AudioVoice(999999, Future.value());
      final dummyBus = CliAudioBus(888888);

      // Operations on non-existent voice should handle cleanly without crashing
      expect(() => engine.stop(dummyVoice), returnsNormally);
      expect(() => engine.setVoiceVolume(dummyVoice, 0.5), returnsNormally);
      expect(
        () => engine.setRelativePlaySpeed(dummyVoice, 1.5),
        returnsNormally,
      );
      expect(
        () => engine.fadeRelativePlaySpeed(
          dummyVoice,
          2.0,
          const Duration(milliseconds: 50),
        ),
        returnsNormally,
      );
      expect(
        () => engine.fadeVolume(
          dummyVoice,
          0.0,
          const Duration(milliseconds: 50),
        ),
        returnsNormally,
      );

      // Operations on non-existent bus
      expect(() => engine.destroyBus(dummyBus), returnsNormally);
      expect(
        () => engine.setFilterParameter(dummyBus, 0, 0, 1.0),
        returnsNormally,
      );
    });
  });
}
