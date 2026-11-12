import 'dart:convert';
import 'dart:typed_data';

import 'package:termui_audio/src/impl/engine_factory_stub.dart';
import 'package:termui_audio/termui_audio.dart';
import 'package:test/test.dart';

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
      final stub = StubAudioEngine();
      final voice = AudioVoice(1, Future<void>.value());
      expect(() => stub.setVoicePan(voice, 0.0), throwsUnsupportedError);
    });
  });
}
