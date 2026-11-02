import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:termui_audio_flutter/termui_audio_flutter.dart';

final class _FakeAudioBuffer implements AudioBuffer {
  const _FakeAudioBuffer(this.hash);

  @override
  final int hash;
}

final class _FakeAudioBus implements AudioBus {
  _FakeAudioBus(this.id);

  @override
  final int id;

  double volume = 1.0;

  @override
  void setVolume(double value) {
    volume = value;
  }
}

final class _RecordingFlutterAudioEngine extends FlutterAudioEngine {
  final List<String> calls = [];
  AudioBus? lastPlayedBus;
  bool? lastPlayedPaused;
  int _nextVoiceId = 1;

  @override
  bool get isInitialized => true;

  @override
  AudioVoice play(
    AudioBuffer buffer, {
    bool loop = false,
    AudioBus? bus,
    bool paused = false,
  }) {
    lastPlayedBus = bus;
    lastPlayedPaused = paused;
    final id = _nextVoiceId++;
    calls.add('play(hash:${buffer.hash}, bus:${bus?.id}, paused:$paused)');
    return AudioVoice(id, Completer<void>().future);
  }

  @override
  void seek(AudioVoice voice, Duration position) {
    calls.add('seek(voice:${voice.id}, ms:${position.inMilliseconds})');
  }

  @override
  void setPaused(AudioVoice voice, bool paused) {
    calls.add('setPaused(voice:${voice.id}, paused:$paused)');
  }

  @override
  void scheduleStop(AudioVoice voice, Duration duration) {
    calls.add('scheduleStop(voice:${voice.id}, ms:${duration.inMilliseconds})');
  }
}

List<int> _extractPcmSamples(Uint8List wavBytes) {
  final bd = ByteData.sublistView(wavBytes, 44);
  final count = bd.lengthInBytes ~/ 2;
  return [for (var i = 0; i < count; i++) bd.getInt16(i * 2, Endian.little)];
}

void main() {
  group('TermuiAudioFlutter & FlutterAudioEngine', () {
    test(
      'TermuiAudioFlutter.register installs FlutterAudioEngine singleton',
      () {
        final registered = TermuiAudioFlutter.register();
        expect(registered, isA<FlutterAudioEngine>());
        expect(TermuiAudio.instance, same(registered));
      },
    );

    test(
      'setRelativePlaySpeed throws UnimplementedError when preservePitch is true',
      () {
        final engine = FlutterAudioEngine();
        final voice = AudioVoice(42, Completer<void>().future);

        expect(
          () => engine.setRelativePlaySpeed(voice, 1.5, preservePitch: true),
          throwsA(
            isA<UnimplementedError>().having(
              (e) => e.message,
              'message',
              contains('preservePitch is not yet supported'),
            ),
          ),
        );
      },
    );

    test(
      'generateWaveformPcmWav produces distinct PCM samples for bounce, fsaw, fsquare vs triangle',
      () {
        final triangleSamples = _extractPcmSamples(
          generateWaveformPcmWav(shape: WaveForm.triangle, frequency: 440.0),
        );
        final bounceSamples = _extractPcmSamples(
          generateWaveformPcmWav(shape: WaveForm.bounce, frequency: 440.0),
        );
        final fsawSamples = _extractPcmSamples(
          generateWaveformPcmWav(shape: WaveForm.fsaw, frequency: 440.0),
        );
        final fsquareSamples = _extractPcmSamples(
          generateWaveformPcmWav(shape: WaveForm.fsquare, frequency: 440.0),
        );

        expect(triangleSamples, isNotEmpty);
        expect(bounceSamples, isNot(equals(triangleSamples)));
        expect(fsawSamples, isNot(equals(triangleSamples)));
        expect(fsquareSamples, isNot(equals(triangleSamples)));
        expect(bounceSamples, isNot(equals(fsawSamples)));
        expect(fsawSamples, isNot(equals(fsquareSamples)));
      },
    );

    test(
      'playSprite forwards AudioBus and seeks/unpauses/schedules stop in order',
      () {
        final engine = _RecordingFlutterAudioEngine();
        const buffer = _FakeAudioBuffer(77);
        final bus = _FakeAudioBus(9);

        final voice = engine.playSprite(
          buffer,
          bus: bus,
          start: const Duration(milliseconds: 120),
          duration: const Duration(milliseconds: 250),
        );

        expect(voice.id, equals(1));
        expect(engine.lastPlayedBus, same(bus));
        expect(engine.lastPlayedPaused, isTrue);
        expect(
          engine.calls,
          equals([
            'play(hash:77, bus:9, paused:true)',
            'seek(voice:1, ms:120)',
            'setPaused(voice:1, paused:false)',
            'scheduleStop(voice:1, ms:250)',
          ]),
        );
      },
    );

    test('dispose cancels pending playSpriteSequence timers cleanly', () async {
      final engine = _RecordingFlutterAudioEngine();
      const buffer = _FakeAudioBuffer(88);
      final bus = _FakeAudioBus(3);

      unawaited(
        engine.playSpriteSequence(buffer, const [
          SpriteSegment(
            start: Duration.zero,
            duration: Duration(milliseconds: 80),
          ),
          SpriteSegment(
            start: Duration(milliseconds: 80),
            duration: Duration(milliseconds: 80),
          ),
        ], bus: bus),
      );

      // First segment starts immediately; second segment is scheduled on a tracked timer.
      expect(engine.calls.first, equals('play(hash:88, bus:3, paused:true)'));

      await engine.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 120));

      // Second segment must not fire after dispose() cancels tracked timers.
      expect(
        engine.calls.where((c) => c.startsWith('play(')).length,
        equals(1),
      );
    });
  });
}
