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
  group('TermuiAudio Tests', () {
    test('0. TermuiAudio singleton wrapper lifecycle', () async {
      // ignore: void_checks
      expect(TermuiAudio.instance, isNotNull);
      await TermuiAudio.init();
      await TermuiAudio.dispose();
    });

    test(
      '1. CliAudioEngine lifecycle and FFI bindings integration test',
      () async {
        final cli = CliAudioEngine();
        await cli.init();

        final buffer = await _loadBuffer(cli);
        expect(buffer, isNotNull);

        final voice = cli.play(buffer);
        expect(voice, isNotNull);

        cli.set3dSourceParameters(voice, 1.0, 2.0, 3.0);
        cli.stop(voice);
        await cli.dispose();
      },
    );

    test(
      '2. TS-03: CliAudioEngine setRelativePlaySpeed sets voice speed without error',
      () async {
        final cli = CliAudioEngine();
        await cli.init();
        final buffer = await _loadBuffer(cli);
        final voice = cli.play(buffer);

        cli.setRelativePlaySpeed(voice, 1.25);
        cli.stop(voice);
        await cli.dispose();
      },
    );

    test(
      '3. TS-04: CliAudioEngine fadeRelativePlaySpeed smoothly interpolates playback speed',
      () async {
        final cli = CliAudioEngine();
        await cli.init();
        final buffer = await _loadBuffer(cli);
        final voice = cli.play(buffer);

        cli.fadeRelativePlaySpeed(
          voice,
          0.75,
          const Duration(milliseconds: 100),
        );
        cli.stop(voice);
        await cli.dispose();
      },
    );

    test(
      '4. TV-02: CliAudioEngine fadeVolume linearly fades voice volume',
      () async {
        final cli = CliAudioEngine();
        await cli.init();
        final buffer = await _loadBuffer(cli);
        final voice = cli.play(buffer);

        cli.fadeVolume(voice, 0.2, const Duration(milliseconds: 100));
        cli.stop(voice);
        await cli.dispose();
      },
    );

    test(
      '5. TV-03: CliAudioEngine rapid volume envelope fades stress test',
      () async {
        final cli = CliAudioEngine();
        await cli.init();
        final buffer = await _loadBuffer(cli);
        final voice = cli.play(buffer);

        for (var i = 0; i < 16; i++) {
          cli.fadeVolume(
            voice,
            (i % 2 == 0) ? 0.8 : 0.1,
            Duration(milliseconds: 5 * (i + 1)),
          );
        }

        cli.stop(voice);
        await cli.dispose();
      },
    );

    test(
      '6. TF-03a: CliAudioEngine FilterType enum mapping & filter creation',
      () async {
        final cli = CliAudioEngine();
        await cli.init();

        final f0 = cli.createFilter(FilterType.biquadResonant);
        final f1 = cli.createFilter(FilterType.echo);
        final f2 = cli.createFilter(FilterType.lofi);

        expect(f0, equals(0));
        expect(f1, equals(1));
        expect(f2, equals(2));

        await cli.dispose();
      },
    );

    test(
      '7. TF-03b: CliAudioEngine attachFilterToBus registers filter on native bus',
      () async {
        final cli = CliAudioEngine();
        await cli.init();

        final bus = cli.createBus();
        expect(bus.id, greaterThan(0));

        final filterId = cli.createFilter(FilterType.biquadResonant);
        cli.attachFilterToBus(bus, filterId);

        cli.destroyBus(bus);
        await cli.dispose();
      },
    );

    test(
      '8. TF-03c: CliAudioEngine setFilterParameter sets native filter attribute',
      () async {
        final cli = CliAudioEngine();
        await cli.init();

        final bus = cli.createBus();
        final filterId = cli.createFilter(FilterType.biquadResonant);
        cli.attachFilterToBus(bus, filterId);
        cli.setFilterParameter(bus, filterId, 0, 500.0);

        cli.destroyBus(bus);
        await cli.dispose();
      },
    );

    test(
      '9. TF-03d: CliAudioEngine fadeFilterParameter smoothly fades native filter attribute',
      () async {
        final cli = CliAudioEngine();
        await cli.init();

        final bus = cli.createBus();
        final filterId = cli.createFilter(FilterType.biquadResonant);
        cli.attachFilterToBus(bus, filterId);
        cli.fadeFilterParameter(
          bus,
          filterId,
          0,
          1500.0,
          const Duration(milliseconds: 100),
        );

        cli.destroyBus(bus);
        await cli.dispose();
      },
    );

    test('10. TF-03e: CliAudioEngine full filter pipeline lifecycle', () async {
      final cli = CliAudioEngine();
      await cli.init();
      final buffer = await _loadBuffer(cli);

      final bus = cli.createBus();
      final filterId = cli.createFilter(FilterType.freeverb);
      cli.attachFilterToBus(bus, filterId);
      cli.setFilterParameter(bus, filterId, 0, 0.5);
      cli.fadeFilterParameter(
        bus,
        filterId,
        0,
        0.9,
        const Duration(milliseconds: 50),
      );

      final voice = cli.play(buffer, bus: bus);
      expect(voice, isNotNull);

      cli.stop(voice);
      cli.destroyBus(bus);
      await cli.dispose();
    });

    test(
      '11. TS-12a: CliAudioEngine playSprite plays buffer slice and auto-stops',
      () async {
        final cli = CliAudioEngine();
        await cli.init();
        final buffer = await _loadBuffer(cli);

        final voice = cli.playSprite(
          buffer,
          start: const Duration(milliseconds: 50),
          duration: const Duration(milliseconds: 100),
        );
        expect(voice, isNotNull);
        expect(voice.id, greaterThan(0));

        await cli.dispose();
      },
    );

    test(
      '12. TS-12b: CliAudioEngine playSprite returns valid AudioVoice handle',
      () async {
        final cli = CliAudioEngine();
        await cli.init();
        final buffer = await _loadBuffer(cli);

        final voice = cli.playSprite(
          buffer,
          start: const Duration(milliseconds: 10),
          duration: const Duration(milliseconds: 200),
        );
        expect(voice.id, greaterThan(0));

        cli.stop(voice);
        await cli.dispose();
      },
    );

    test(
      '13. TS-12c: CliAudioEngine playSpriteSequence queues sequentially',
      () async {
        final cli = CliAudioEngine();
        await cli.init();
        final buffer = await _loadBuffer(cli);

        final segments = [
          const SpriteSegment(
            start: Duration.zero,
            duration: Duration(milliseconds: 50),
          ),
          const SpriteSegment(
            start: Duration(milliseconds: 50),
            duration: Duration(milliseconds: 50),
          ),
        ];

        cli.playSpriteSequence(buffer, segments);

        await Future.delayed(const Duration(milliseconds: 150));
        await cli.dispose();
      },
    );

    test(
      '14. TF-04: CliAudioEngine loadWaveform with different shapes',
      () async {
        final cli = CliAudioEngine();
        await cli.init();

        // This exercises the `solShape = switch (shape)` branch inside `loadWaveform`
        final b1 = await cli.loadWaveform(WaveForm.square, 440.0);
        final b2 = await cli.loadWaveform(WaveForm.saw, 440.0);
        final b3 = await cli.loadWaveform(WaveForm.triangle, 440.0);

        expect(b1.hash, isNot(b2.hash));
        expect(b2.hash, isNot(b3.hash));

        await cli.dispose();
      },
    );

    test(
      '13. TB-02a: CliAudioEngine createBus and destroyBus native mixing bus lifecycle',
      () async {
        final cli = CliAudioEngine();
        await cli.init();

        final bus = cli.createBus();
        expect(bus.id, greaterThan(0));
        bus.setVolume(0.8);

        cli.destroyBus(bus);
        await cli.dispose();
      },
    );

    test(
      '14. TB-02b: CliAudioEngine polyphonic bus pool allocation (16 buses)',
      () async {
        final cli = CliAudioEngine();
        await cli.init();
        final buffer = await _loadBuffer(cli);

        final buses = <AudioBus>[];
        for (var i = 0; i < 16; i++) {
          final bus = cli.createBus();
          expect(bus.id, greaterThan(0));
          buses.add(bus);
        }

        final voice = cli.play(buffer, bus: buses.first);
        expect(voice, isNotNull);

        cli.stop(voice);
        for (final b in buses) {
          cli.destroyBus(b);
        }
        await cli.dispose();
      },
    );
  });
}
