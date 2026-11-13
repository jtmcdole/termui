import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:termui_audio/src/impl/cli/cli_audio_engine.dart';
import 'package:termui_audio/src/impl/engine_factory_cli.dart' as cli_factory;
import 'package:termui_audio/src/impl/engine_factory_stub.dart' as stub_factory;
import 'package:termui_audio/termui_audio.dart';
import 'package:test/test.dart';

Uint8List _oggPage(
  int serial,
  int granuleLow,
  List<int> payload, {
  int headerType = 0,
  int granuleHigh = 0,
}) {
  final out = Uint8List(28 + payload.length);
  ByteData.sublistView(out)
    ..setUint32(6, granuleLow, Endian.little)
    ..setInt32(10, granuleHigh, Endian.little)
    ..setUint32(14, serial, Endian.little);
  out.setRange(0, 4, 'OggS'.codeUnits);
  out[5] = headerType;
  out[26] = 1;
  out[27] = payload.length;
  out.setRange(28, out.length, payload);
  return out;
}

Uint8List _vorbisId(int sampleRate) =>
    (Uint8List(30)
        ..[0] = 0x01
        ..setRange(1, 7, 'vorbis'.codeUnits)
        ..[11] = 2)
      ..buffer.asByteData().setUint32(12, sampleRate, Endian.little);

Uint8List _opusHead(int preSkip) =>
    (Uint8List(19)
        ..setRange(0, 8, 'OpusHead'.codeUnits)
        ..[8] = 1
        ..[9] = 2)
      ..buffer.asByteData().setUint16(10, preSkip, Endian.little);

void main() {
  group('ApcAudioEncoder', () {
    test('maps WaveForm.sin <-> sine and encodes tone APC frame', () {
      expect(ApcAudioEncoder.waveformToWire(WaveForm.sin), equals('sine'));
      expect(ApcAudioEncoder.waveformFromWire('sine'), equals(WaveForm.sin));
      expect(ApcAudioEncoder.waveformFromWire('sin'), equals(WaveForm.sin));

      final frame = ApcAudioEncoder.encodeTone(
        waveform: WaveForm.sin,
        frequencyHz: 440,
        duration: const Duration(milliseconds: 200),
        volume: 1.5,
        pan: -2.0,
      );

      expect(frame, equals('\x1b_Aa=tone,w=sine,f=440,d=200,v=1,p=-1;\x1b\\'));
    });

    test(
      'chunks 2 MiB clip into 4096-char base64 frames well below max APC length',
      () {
        final bytes = Uint8List.fromList([
          for (var i = 0; i < ApcAudioEncoder.maxClipBytes; i++) i & 0xFF,
        ]);
        final frames = ApcAudioEncoder.encodeClip(
          clipId: 42,
          format: 'ogg',
          bytes: bytes,
          volume: 0.75,
          pan: 0.5,
          loop: true,
        );

        expect(frames.length, greaterThan(600));
        expect(frames.first, startsWith('\x1b_Aa=clip,i=42,fmt=ogg,'));
        expect(frames.first, contains('m=1;'));
        expect(frames.last, endsWith('\x1b\\'));
        expect(frames.last, contains('m=0;'));

        final reassembled = StringBuffer();
        for (var i = 0; i < frames.length; i++) {
          final frame = frames[i];
          expect(frame.length, lessThan(4300));
          final body = frame.substring(3, frame.length - 2);
          final semi = body.indexOf(';');
          expect(semi, greaterThan(0));
          final meta = body.substring(0, semi);
          final b64Chunk = body.substring(semi + 1);
          expect(b64Chunk.length, lessThanOrEqualTo(4096));
          if (i < frames.length - 1) {
            expect(b64Chunk.length, equals(4096));
            expect(meta, contains('m=1'));
          } else {
            expect(meta, contains('m=0'));
          }
          reassembled.write(b64Chunk);
        }

        expect(base64Decode(reassembled.toString()), equals(bytes));
      },
    );

    test('rejects oversized clips above 2 MiB and unsupported formats', () {
      expect(
        () => ApcAudioEncoder.encodeClip(
          clipId: 1,
          format: 'wav',
          bytes: Uint8List(ApcAudioEncoder.maxClipBytes + 1),
        ),
        throwsRangeError,
      );
      expect(
        () => ApcAudioEncoder.encodeClip(
          clipId: 1,
          format: 'flac',
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
        throwsArgumentError,
      );
    });

    test('encodeTone enforces max 60s duration and 24000 Hz frequency', () {
      expect(
        () => ApcAudioEncoder.encodeTone(
          frequencyHz: 24000.1,
          duration: const Duration(milliseconds: 100),
        ),
        throwsArgumentError,
      );
      expect(
        () => ApcAudioEncoder.encodeTone(
          frequencyHz: 440,
          duration: const Duration(seconds: 61),
        ),
        throwsArgumentError,
      );
      expect(
        ApcAudioEncoder.encodeTone(
          frequencyHz: 24000,
          duration: const Duration(seconds: 60),
        ),
        contains('f=24000,d=60000,'),
      );
    });

    test('encodeStop encodes clip-specific and global stop frames', () {
      expect(ApcAudioEncoder.encodeStop(), equals('\x1b_Aa=stop;\x1b\\'));
      expect(
        ApcAudioEncoder.encodeStop(clipId: 9),
        equals('\x1b_Aa=stop,i=9;\x1b\\'),
      );
    });

    test('encodeUpdate validates clipId and params, clamps, and formats', () {
      expect(
        ApcAudioEncoder.encodeUpdate(clipId: 3, volume: 1.5, pan: -2.0),
        equals('\x1b_Aa=update,i=3,v=1,p=-1;\x1b\\'),
      );
      expect(
        ApcAudioEncoder.encodeUpdate(clipId: 4, volume: 0.25),
        equals('\x1b_Aa=update,i=4,v=0.25;\x1b\\'),
      );
      expect(
        ApcAudioEncoder.encodeUpdate(clipId: 5, pan: -0.5),
        equals('\x1b_Aa=update,i=5,p=-0.5;\x1b\\'),
      );
      expect(
        () => ApcAudioEncoder.encodeUpdate(clipId: 0, volume: 0.5),
        throwsArgumentError,
      );
      expect(
        () => ApcAudioEncoder.encodeUpdate(clipId: 0x80000000, pan: 0.0),
        throwsArgumentError,
      );
      expect(
        () => ApcAudioEncoder.encodeUpdate(clipId: 1),
        throwsArgumentError,
      );
      expect(
        () => ApcAudioEncoder.encodeUpdate(
          clipId: 1,
          volume: double.nan,
          pan: double.infinity,
        ),
        throwsArgumentError,
      );
    });
  });

  group('PtyApcAudioEngine', () {
    test(
      'plays paused waveform with volume and pan then stops cleanly',
      () async {
        final frames = <String>[];
        final engine = PtyApcAudioEngine(frames.add);
        await engine.init();

        final buf = await engine.loadWaveform(WaveForm.sin, 880);
        final voice = engine.play(buf, paused: true);
        expect(frames, isEmpty);

        engine.setVoiceVolume(voice, 0.4);
        engine.setVoicePan(voice, -0.5);
        engine.setPaused(voice, false);
        expect(
          frames,
          equals(['\x1b_Aa=tone,w=sine,f=880,d=250,v=0.4,p=-0.5;\x1b\\']),
        );

        final clip = await engine.loadMem(
          'bell.wav',
          Uint8List.fromList([0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4]),
        );
        final clipVoice = engine.play(clip, loop: true);
        expect(frames.last, contains('a=clip'));
        expect(frames.last, contains('fmt=wav'));
        expect(frames.last, contains('l=1'));

        engine.stop(clipVoice);
        expect(frames.last, equals('\x1b_Aa=stop,i=${clipVoice.id};\x1b\\'));
        await engine.dispose();
      },
    );

    test(
      'play(tone) auto-completes voice.completed and empties _voices',
      () async {
        final frames = <String>[];
        final engine = PtyApcAudioEngine(
          frames.add,
          defaultToneDuration: const Duration(milliseconds: 25),
        );
        await engine.init();

        final tone = await engine.loadWaveform(WaveForm.sin, 440);
        final voice = engine.play(tone);
        expect(engine.activeVoiceCount, equals(1));
        await voice.completed.timeout(const Duration(seconds: 2));
        expect(engine.activeVoiceCount, equals(0));
        expect(frames, hasLength(1));
        expect(frames.single, contains('a=tone'));
        await engine.dispose();
      },
    );

    test(
      'paused waveform preserves scheduleStop duration on setPaused(false)',
      () async {
        final frames = <String>[];
        final engine = PtyApcAudioEngine(frames.add);
        await engine.init();

        final tone = await engine.loadWaveform(WaveForm.square, 660);
        final voice = engine.play(tone, paused: true);
        engine.scheduleStop(voice, const Duration(milliseconds: 120));
        expect(frames, isEmpty);

        engine.setPaused(voice, false);
        expect(frames, hasLength(1));
        expect(frames.single, contains('d=120,'));

        await voice.completed.timeout(const Duration(seconds: 2));
        expect(engine.activeVoiceCount, equals(0));
        await engine.dispose();
      },
    );

    test(
      'clip voices use distinct voice wire IDs and non-looping clips auto-evict',
      () async {
        final frames = <String>[];
        final engine = PtyApcAudioEngine(frames.add);
        await engine.init();

        final clip = await engine.loadMem(
          'fx.wav',
          Uint8List.fromList([0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4]),
        );
        final v1 = engine.play(clip, loop: true);
        final v2 = engine.play(clip, loop: true);
        expect(v1.id, isNot(equals(v2.id)));
        expect(frames[0], contains('i=${v1.id},'));
        expect(frames[1], contains('i=${v2.id},'));

        engine.stop(v1);
        expect(frames.last, equals('\x1b_Aa=stop,i=${v1.id};\x1b\\'));
        expect(engine.activeVoiceCount, equals(1));

        engine.stop(v2);
        expect(frames.last, equals('\x1b_Aa=stop,i=${v2.id};\x1b\\'));
        expect(engine.activeVoiceCount, equals(0));

        final oneShot = engine.play(clip);
        await oneShot.completed.timeout(const Duration(seconds: 2));
        expect(engine.activeVoiceCount, equals(0));
        await engine.dispose();
      },
    );

    test('playSpriteSequence awaits each segment sequentially', () async {
      final frames = <String>[];
      final engine = PtyApcAudioEngine(frames.add);
      await engine.init();

      final tone = await engine.loadWaveform(WaveForm.triangle, 523.25);
      final future = engine.playSpriteSequence(tone, const [
        SpriteSegment(
          start: Duration.zero,
          duration: Duration(milliseconds: 30),
        ),
        SpriteSegment(
          start: Duration(milliseconds: 30),
          duration: Duration(milliseconds: 30),
        ),
      ]);

      expect(frames, hasLength(1));
      await future.timeout(const Duration(seconds: 2));
      expect(frames, hasLength(2));
      expect(engine.activeVoiceCount, equals(0));
      await engine.dispose();
    });

    test('StubAudioEngine.setVoicePan throws UnsupportedError', () {
      final stub = stub_factory.StubAudioEngine();
      final voice = AudioVoice(1, Future<void>.value());
      expect(() => stub.setVoicePan(voice, 0.0), throwsUnsupportedError);
    });

    test(
      'PtyApcAudioEngine estimates WAV/OGG duration, normalizes 3D spatial pan, and keeps non-looping BGM active until stopped or elapsed',
      () async {
        final frames = <String>[];
        final engine = PtyApcAudioEngine(frames.add);
        await engine.init();

        final wavBytes = generateWaveformPcmWav(
          shape: WaveForm.sin,
          frequency: 440,
          duration: const Duration(milliseconds: 400),
        );
        final wavBuf = await engine.loadMem('bgm.wav', wavBytes);
        expect(
          engine.getBufferDuration(wavBuf).inMilliseconds,
          inInclusiveRange(390, 410),
        );

        final voice = engine.play3d(wavBuf, -5.0, -5.0, 0.0);
        expect(frames, isNotEmpty);
        // (-5, -5, 0) has distance sqrt(50) ≈ 7.071 -> pan = -5 / 7.071 ≈ -0.7071 (not clamped to -1).
        expect(frames.first, contains('p=-0.7071,'));

        // Must remain active past Duration.zero so TUI togglePlay can stop it.
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(engine.activeVoiceCount, equals(1));

        engine.stop(voice);
        expect(frames.last, equals('\x1b_Aa=stop,i=${voice.id};\x1b\\'));
        expect(engine.activeVoiceCount, equals(0));
        await engine.dispose();
      },
    );

    test(
      'createAudioEngine selects APC vs CLI from TERMUI_AUDIO_APC and loadFile reads bytes',
      () async {
        final frames = <String>[];
        final apc = cli_factory.createAudioEngine(
          environment: const {'TERMUI_AUDIO_APC': '1'},
          writeEscape: frames.add,
        );
        expect(apc, isA<PtyApcAudioEngine>());
        expect(
          cli_factory.createAudioEngine(
            environment: const {'TERMUI_AUDIO_APC': ' TRUE '},
            writeEscape: frames.add,
          ),
          isA<PtyApcAudioEngine>(),
        );
        expect(
          cli_factory.createAudioEngine(
            environment: const {'TERMUI_AUDIO_APC': '0'},
          ),
          isA<CliAudioEngine>(),
        );
        expect(
          stub_factory.createAudioEngine(),
          isA<stub_factory.StubAudioEngine>(),
        );
        final defaultStdoutApc = cli_factory.createAudioEngine(
          environment: const {'TERMUI_AUDIO_APC': '1'},
        );
        expect(defaultStdoutApc, isA<PtyApcAudioEngine>());
        await defaultStdoutApc.dispose();

        final wavBytes = generateWaveformPcmWav(
          shape: WaveForm.sin,
          frequency: 440,
          duration: const Duration(milliseconds: 120),
        );
        final engine = PtyApcAudioEngine(
          frames.add,
          readFileBytes: (_) async => wavBytes,
        );
        final progresses = <double>[];
        final loaded = await engine.loadFile(
          'clip.wav',
          onProgress: progresses.add,
        );
        expect(progresses, equals([1.0]));
        expect(await engine.loadFileBytes('clip.wav'), equals(wavBytes));
        final v1 = engine.play(loaded, loop: true);
        expect(frames.first, contains('fmt=wav'));
        engine.stop(v1);

        frames.clear();
        final assetPath = File('example/assets/fast_swish1.ogg').existsSync()
            ? 'example/assets/fast_swish1.ogg'
            : 'packages/termui_audio/example/assets/fast_swish1.ogg';
        final realBuf = await (apc as PtyApcAudioEngine).loadFile(assetPath);
        final v2 = apc.play(realBuf, loop: true);
        expect(frames.first, contains('fmt=ogg'));
        apc.stop(v2);
        await apc.dispose();
        await engine.dispose();
      },
    );

    test(
      'WAV odd-chunk padding and Ogg Vorbis/Opus duration parsing handle real assets, pre-skip, fake OggS, and chained serials',
      () async {
        final engine = PtyApcAudioEngine((_) {});
        final wav = generateWaveformPcmWav(
          shape: WaveForm.sin,
          frequency: 440,
          duration: const Duration(milliseconds: 100),
        );
        final junkWav = Uint8List.fromList([
          ...wav.sublist(0, 12),
          ...'JUNK'.codeUnits,
          3,
          0,
          0,
          0,
          1,
          2,
          3,
          0,
          ...wav.sublist(12),
        ]);
        expect(
          engine
              .getBufferDuration(await engine.loadMem('junk.wav', junkWav))
              .inMilliseconds,
          inInclusiveRange(95, 105),
        );

        final vorbis = Uint8List.fromList([
          ..._oggPage(1, 0, _vorbisId(44100), headerType: 0x02),
          ..._oggPage(1, 44100, [
            ...'OggS\x00\x04'.codeUnits,
            1,
          ], headerType: 4),
        ]);
        expect(
          engine.getBufferDuration(await engine.loadMem('a.ogg', vorbis)),
          equals(const Duration(seconds: 1)),
        );

        final opus = Uint8List.fromList([
          ..._oggPage(2, 0, _opusHead(312), headerType: 0x02),
          ..._oggPage(2, 48312, [0, 1, 2]),
        ]);
        expect(
          engine.getBufferDuration(await engine.loadMem('b.ogg', opus)),
          equals(const Duration(seconds: 1)),
        );

        final chained = Uint8List.fromList([
          ..._oggPage(1, 0, _opusHead(0), headerType: 0x02),
          ..._oggPage(2, 48000, [0, 1], headerType: 0x04),
        ]);
        expect(
          engine.getBufferDuration(await engine.loadMem('c.ogg', chained)),
          equals(Duration.zero),
        );

        final assetDir = Directory('example/assets').existsSync()
            ? 'example/assets'
            : 'packages/termui_audio/example/assets';
        final swish = await engine.loadFile('$assetDir/fast_swish1.ogg');
        expect(engine.getBufferDuration(swish).inMilliseconds, equals(360));
        final bgm = await engine.loadFile('$assetDir/DontFallOffTheClouds.ogg');
        expect(
          engine.getBufferDuration(bgm).inMilliseconds,
          inInclusiveRange(90800, 90820),
        );
        await engine.dispose();
      },
    );

    test(
      'Clock tracks playhead position, seek is no-op, and set3dSourceParameters normalizes pan',
      () async {
        var now = DateTime.utc(2026, 1, 1);
        final frames = <String>[];
        final engine = PtyApcAudioEngine(frames.add, clock: Clock(() => now));
        final wavBytes = generateWaveformPcmWav(
          shape: WaveForm.sin,
          frequency: 440,
          duration: const Duration(milliseconds: 400),
        );
        final clip = await engine.loadMem('loop.wav', wavBytes);

        final pausedVoice = engine.play(clip, paused: true);
        expect(engine.getVoicePosition(pausedVoice), equals(Duration.zero));
        engine.set3dSourceParameters(pausedVoice, 3.0, 4.0, 0.0);
        engine.setPaused(pausedVoice, false);
        expect(frames.first, contains('p=0.6,'));

        now = now.add(const Duration(milliseconds: 150));
        expect(
          engine.getVoicePosition(pausedVoice),
          equals(const Duration(milliseconds: 150)),
        );
        engine.seek(pausedVoice, const Duration(milliseconds: 10));
        expect(
          engine.getVoicePosition(pausedVoice),
          equals(const Duration(milliseconds: 150)),
        );
        now = now.add(const Duration(milliseconds: 400));
        expect(
          engine.getVoicePosition(pausedVoice),
          equals(engine.getBufferDuration(clip)),
        );

        final loopVoice = engine.play(clip, loop: true);
        final streamPositions = <Duration>[];
        final sub = engine
            .getVoicePositionStream(
              loopVoice,
              interval: const Duration(milliseconds: 10),
            )
            .listen(streamPositions.add);
        now = now.add(const Duration(milliseconds: 550));
        expect(
          engine.getVoicePosition(loopVoice).inMilliseconds,
          inInclusiveRange(145, 155),
        );
        await Future<void>.delayed(const Duration(milliseconds: 25));
        expect(streamPositions, isNotEmpty);

        engine.scheduleStop(loopVoice, const Duration(milliseconds: 200));
        now = now.add(const Duration(milliseconds: 150));
        expect(
          engine.getVoicePosition(loopVoice),
          equals(const Duration(milliseconds: 100)),
        );

        final mp3Clip = await engine.loadMem(
          'unknown.mp3',
          Uint8List.fromList([0x49, 0x44, 0x33, 1, 2, 3]),
        );
        final mp3Voice = engine.play(mp3Clip);
        await mp3Voice.completed;
        frames.clear();
        engine.stop(mp3Voice);
        engine.stop(mp3Voice);
        expect(frames, equals(['\x1b_Aa=stop,i=${mp3Voice.id};\x1b\\']));

        engine.stop(pausedVoice);
        engine.stop(loopVoice);
        await sub.cancel();
        await engine.disposeBuffer(clip);
        expect(engine.getBufferDuration(clip), equals(Duration.zero));
        await engine.dispose();
      },
    );

    test(
      'emits deduplicated a=update frames for live 3D pan, distance attenuation, volume, and pan changes',
      () async {
        final frames = <String>[];
        final engine = PtyApcAudioEngine(frames.add);
        final wavBytes = generateWaveformPcmWav(
          shape: WaveForm.sin,
          frequency: 440,
          duration: const Duration(milliseconds: 20),
        );
        final clip = await engine.loadMem('track.wav', wavBytes);

        // Clouds-style start at (0, 0, 0) with min=2, max=20: no redundant update on attenuation setup.
        final clouds = engine.play3d(clip, 0.0, 0.0, 0.0);
        expect(frames, hasLength(1));
        expect(frames.single, contains('v=1,p=0,'));
        engine.set3dSourceMinMaxDistance(clouds, 2.0, 20.0);
        engine.set3dSourceAttenuation(
          clouds,
          AttenuationModel.linearDistance,
          1.0,
        );
        expect(frames, hasLength(1));

        // setVoiceVolume after emission sends a=update.
        engine.setVoiceVolume(clouds, 0.8);
        expect(
          frames.last,
          equals('\x1b_Aa=update,i=${clouds.id},v=0.8;\x1b\\'),
        );

        // Live set3dSourceParameters updates pan and linear distance attenuation.
        engine.set3dSourceParameters(clouds, 11.0, 0.0, 0.0);
        expect(
          frames.last,
          equals('\x1b_Aa=update,i=${clouds.id},v=0.4,p=1;\x1b\\'),
        );

        // Duplicate quantized update (same 4-decimal v and p) is suppressed.
        final countBeforeDup = frames.length;
        engine.set3dSourceParameters(clouds, 11.00001, 0.0, 0.0);
        expect(frames, hasLength(countBeforeDup));

        // Inverse and exponential attenuation models compute expected gain.
        engine.set3dSourceAttenuation(
          clouds,
          AttenuationModel.inverseDistance,
          1.0,
        );
        engine.set3dSourceParameters(clouds, 4.0, 0.0, 0.0);
        // min=2, d=4, r=1 -> 2 / (2 + 1*(4-2)) = 0.5; 0.8 * 0.5 = 0.4
        expect(
          frames.last,
          equals('\x1b_Aa=update,i=${clouds.id},v=0.4;\x1b\\'),
        );

        engine.set3dSourceAttenuation(
          clouds,
          AttenuationModel.exponentialDistance,
          2.0,
        );
        // min=2, d=4, r=2 -> (4/2)^(-2) = 0.25; 0.8 * 0.25 = 0.2
        expect(
          frames.last,
          equals('\x1b_Aa=update,i=${clouds.id},v=0.2;\x1b\\'),
        );

        // setVoicePan after emission sends a=update.
        engine.setVoicePan(clouds, -0.5);
        expect(
          frames.last,
          equals('\x1b_Aa=update,i=${clouds.id},p=-0.5;\x1b\\'),
        );

        // Swish-style start at (-5, -5, 0) with min=2, max=20 emits attenuated update (v=0.7183).
        frames.clear();
        final swish = engine.play3d(clip, -5.0, -5.0, 0.0);
        engine.set3dSourceMinMaxDistance(swish, 2.0, 20.0);
        engine.set3dSourceAttenuation(
          swish,
          AttenuationModel.linearDistance,
          1.0,
        );
        expect(frames, hasLength(2));
        expect(
          frames.last,
          equals('\x1b_Aa=update,i=${swish.id},v=0.7183;\x1b\\'),
        );

        engine.stop(clouds);
        engine.stop(swish);
        await engine.dispose();
      },
    );
  });
}
