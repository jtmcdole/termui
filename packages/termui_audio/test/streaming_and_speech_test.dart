import 'dart:async';
import 'dart:io';
import 'package:termui_audio/termui_audio.dart';
import 'package:termui_audio/src/impl/cli/cli_audio_engine.dart';
import 'package:test/test.dart';

String _resolveAudioPath(String relativePath) {
  var file = File('${Directory.current.path}/$relativePath');
  if (!file.existsSync()) {
    file = File(
      '${Directory.current.path}/packages/termui_audio/$relativePath',
    );
  }
  expect(
    file.existsSync(),
    isTrue,
    reason: 'Audio test file must exist: $relativePath',
  );
  return file.path;
}

void main() {
  group('Streaming & Speech Player Tests', () {
    late CliAudioEngine cli;

    setUp(() async {
      cli = CliAudioEngine();
      await cli.init();
    });

    tearDown(() async {
      await cli.dispose();
    });

    test(
      'TS-STR01: Disk streaming with loadFile(stream: true) loads and plays',
      () async {
        final soundPath = _resolveAudioPath(
          'src/filters/signalsmith-stretch/web/demo/loop.mp3',
        );

        // 1. Load with disk streaming
        final buffer = await cli.loadFile(soundPath, stream: true);
        expect(buffer, isNotNull);
        expect(buffer.hash, isNonZero);

        // 2. Check duration
        final duration = cli.getBufferDuration(buffer);
        expect(duration.inMilliseconds, greaterThan(1000));

        // 3. Play stream
        final voice = cli.play(buffer);
        expect(voice, isNotNull);
        expect(voice.id, isNonZero);

        // 4. Verify position reading
        final pos = cli.getVoicePosition(voice);
        expect(pos, isNotNull);

        // 5. Cleanup
        cli.stop(voice);
        await cli.disposeBuffer(buffer);
      },
    );

    test('TS-STR02: In-memory streaming with loadMem(stream: true)', () async {
      final soundPath = _resolveAudioPath(
        'src/filters/signalsmith-stretch/web/demo/loop.mp3',
      );
      final bytes = await File(soundPath).readAsBytes();

      final buffer = await cli.loadMem('loop_mem_stream', bytes, stream: true);
      expect(buffer, isNotNull);
      expect(buffer.hash, isNonZero);

      final duration = cli.getBufferDuration(buffer);
      expect(duration.inMilliseconds, greaterThan(1000));

      final voice = cli.play(buffer);
      expect(voice.id, isNonZero);

      cli.stop(voice);
      await cli.disposeBuffer(buffer);
    });

    test('TS-STR03: Pitch-preserved playback speed scaling', () async {
      final soundPath = _resolveAudioPath(
        'src/filters/signalsmith-stretch/web/demo/loop.mp3',
      );
      final buffer = await cli.loadFile(soundPath, stream: true);
      final voice = cli.play(buffer);

      // Test multiple playback rates with pitch preservation enabled
      for (final rate in [0.75, 1.0, 1.25, 1.5, 2.0]) {
        expect(
          () => cli.setRelativePlaySpeed(voice, rate, preservePitch: true),
          returnsNormally,
        );
      }

      cli.stop(voice);
      await cli.disposeBuffer(buffer);
    });

    test(
      'TS-STR04: Reactive playhead stream emits updates and completes',
      () async {
        final soundPath = _resolveAudioPath(
          'src/filters/signalsmith-stretch/web/demo/loop.mp3',
        );
        final buffer = await cli.loadFile(soundPath, stream: true);
        final voice = cli.play(buffer);

        final positions = <Duration>[];
        final completer = Completer<void>();

        final sub = cli
            .getVoicePositionStream(
              voice,
              interval: const Duration(milliseconds: 20),
            )
            .listen((pos) {
              positions.add(pos);
              if (positions.length >= 3 && !completer.isCompleted) {
                completer.complete();
              }
            });

        // Wait for at least 3 position ticks
        await completer.future.timeout(const Duration(seconds: 2));
        expect(positions.length, greaterThanOrEqualTo(3));

        await sub.cancel();
        cli.stop(voice);
        await cli.disposeBuffer(buffer);
      },
    );

    test(
      'TS-STR05: AudioVoice.positionStream extension method works with TermuiAudio',
      () async {
        final soundPath = _resolveAudioPath(
          'src/filters/signalsmith-stretch/web/demo/loop.mp3',
        );
        final buffer = await cli.loadFile(soundPath, stream: true);
        final voice = cli.play(buffer);

        final stream = voice.positionStream(
          engine: cli,
          interval: const Duration(milliseconds: 20),
        );
        expect(stream, isNotNull);

        final firstPos = await stream.first.timeout(const Duration(seconds: 2));
        expect(firstPos, isNotNull);

        cli.stop(voice);
        await cli.disposeBuffer(buffer);
      },
    );

    test('TS-STR06: Long-form audio track streaming and seek', () async {
      final soundPath = _resolveAudioPath(
        'example/assets/DontFallOffTheClouds.ogg',
      );
      final buffer = await cli.loadFile(soundPath, stream: true);

      final duration = cli.getBufferDuration(buffer);
      // Track is ~37 seconds long
      expect(duration.inSeconds, greaterThan(30));

      final voice = cli.play(buffer);
      expect(voice.id, isNonZero);

      // Seek forward into the stream
      cli.seek(voice, const Duration(seconds: 10));

      cli.stop(voice);
      await cli.disposeBuffer(buffer);
    });

    test(
      'TS-STR07: Progressive chunk streaming (createBufferStream, addStreamData, setStreamEnded)',
      () async {
        final soundPath = _resolveAudioPath(
          'src/filters/signalsmith-stretch/web/demo/loop.mp3',
        );
        final fileBytes = await File(soundPath).readAsBytes();

        // Create buffer stream (e.g. 4 MB max buffer, releasing consumed audio)
        final buffer = await cli.createBufferStream(
          maxBufferSize: 4 * 1024 * 1024,
          releaseConsumed: true,
          bufferingTimeNeeds: const Duration(milliseconds: 100),
        );
        expect(buffer, isNotNull);
        expect(buffer.hash, isNonZero);

        // Feed first chunk (simulating first HTTP range chunk / EPUB package slice)
        const chunkSize = 16 * 1024;
        var offset = 0;
        final firstChunk = fileBytes.sublist(
          0,
          chunkSize.clamp(0, fileBytes.length),
        );
        cli.addStreamData(buffer, firstChunk);
        offset += firstChunk.length;

        // Play the stream
        final voice = cli.play(buffer);
        expect(voice, isNotNull);
        expect(voice.id, isNonZero);

        // Feed remaining chunks progressively (simulating progressive HTTP range delivery)
        while (offset < fileBytes.length) {
          final end = (offset + chunkSize).clamp(0, fileBytes.length);
          final chunk = fileBytes.sublist(offset, end);
          cli.addStreamData(buffer, chunk);
          offset = end;
        }

        // Signal stream ended
        cli.setStreamEnded(buffer);

        // Verify voice position is readable
        final pos = cli.getVoicePosition(voice);
        expect(pos, isNotNull);

        cli.stop(voice);
        await cli.disposeBuffer(buffer);
      },
    );

    test(
      'TS-STR08: Progressive chunk streaming with pitch-preserved speed scaling',
      () async {
        final soundPath = _resolveAudioPath(
          'src/filters/signalsmith-stretch/web/demo/loop.mp3',
        );
        final fileBytes = await File(soundPath).readAsBytes();

        final buffer = await cli.createBufferStream(
          maxBufferSize: 2 * 1024 * 1024,
          releaseConsumed: true,
          bufferingTimeNeeds: const Duration(milliseconds: 100),
        );

        // Feed first half of audio file
        final half = fileBytes.length ~/ 2;
        cli.addStreamData(buffer, fileBytes.sublist(0, half));

        final voice = cli.play(buffer);
        expect(voice.id, isNonZero);

        // Change speed with pitch preservation enabled
        cli.setRelativePlaySpeed(voice, 1.5, preservePitch: true);

        // Feed second half
        cli.addStreamData(buffer, fileBytes.sublist(half));
        cli.setStreamEnded(buffer);

        cli.stop(voice);
        await cli.disposeBuffer(buffer);
      },
    );
  });
}
