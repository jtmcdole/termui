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
  final List<_FakeAudioBus> createdBuses = [];
  final List<int> destroyedBusIds = [];
  final List<(int busId, int filterId)> attachedFilters = [];
  final List<(int busId, int filterId, int paramId, double value)>
  filterParams = [];
  final List<(int busId, int voiceId)> annexedVoices = [];
  bool throwOnAnnex = false;
  AudioBus? lastPlayedBus;
  bool? lastPlayedPaused;
  int _nextVoiceId = 1;
  int _nextBusId = 100;

  @override
  bool get isInitialized => true;

  @override
  AudioBus createBus() {
    final bus = _FakeAudioBus(_nextBusId++);
    createdBuses.add(bus);
    calls.add('createBus(${bus.id})');
    return bus;
  }

  @override
  void destroyBus(AudioBus bus) {
    destroyedBusIds.add(bus.id);
    calls.add('destroyBus(${bus.id})');
  }

  @override
  void attachFilterToBus(AudioBus bus, int filterId) {
    attachedFilters.add((bus.id, filterId));
    calls.add('attachFilter(bus:${bus.id}, ft:$filterId)');
  }

  @override
  void setFilterParameter(
    AudioBus bus,
    int filterId,
    int paramId,
    double value,
  ) {
    filterParams.add((bus.id, filterId, paramId, value));
    calls.add(
      'setFilterParam(bus:${bus.id}, ft:$filterId, pm:$paramId, v:$value)',
    );
  }

  @override
  void annexVoiceToBus(AudioBus bus, int voiceId) {
    if (throwOnAnnex) throw StateError('annex failed');
    annexedVoices.add((bus.id, voiceId));
    calls.add('annexVoice(bus:${bus.id}, voice:$voiceId)');
  }

  @override
  void setEngineRelativePlaySpeed(int voiceId, double speed) {
    calls.add('setEngineSpeed(voice:$voiceId, speed:$speed)');
  }

  @override
  void stopEngineVoice(int voiceId) {
    calls.add('stopEngineVoice(voice:$voiceId)');
  }

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
      'setRelativePlaySpeed throws when uninitialized and manages per-voice pitch bus when preservePitch is true',
      () async {
        final uninit = FlutterAudioEngine();
        final uninitVoice = AudioVoice(42, Completer<void>().future);
        expect(
          () => uninit.setRelativePlaySpeed(
            uninitVoice,
            1.5,
            preservePitch: true,
          ),
          throwsA(isA<Exception>()),
        );

        final engine = _RecordingFlutterAudioEngine();
        final v1 = AudioVoice(10, Completer<void>().future);
        final v2 = AudioVoice(20, Completer<void>().future);
        final pitchFt = FilterType.pitchShift.index;

        // Non-finite or non-positive speed with preservePitch is ignored.
        engine.setRelativePlaySpeed(v1, 0.0, preservePitch: true);
        engine.setRelativePlaySpeed(v1, double.nan, preservePitch: true);
        expect(engine.createdBuses, isEmpty);

        // 0.5x speed allocates bus once, attaches pitchShift, annexes voice, and sets wet=1.0, shift=2.0.
        engine.setRelativePlaySpeed(v1, 0.5, preservePitch: true);
        expect(engine.createdBuses, hasLength(1));
        final b1 = engine.createdBuses.single;
        expect(engine.attachedFilters, equals([(b1.id, pitchFt)]));
        expect(engine.annexedVoices, equals([(b1.id, 10)]));
        expect(
          engine.filterParams,
          equals([(b1.id, pitchFt, 0, 1.0), (b1.id, pitchFt, 1, 2.0)]),
        );

        // 0.25x clamps shift=4.0 (> 3.0) via semitones (+24.0) without reallocating bus.
        engine.setRelativePlaySpeed(v1, 0.25, preservePitch: true);
        expect(engine.createdBuses, hasLength(1));
        expect(engine.filterParams.last.$3, equals(2));
        expect(engine.filterParams.last.$4, closeTo(24.0, 1e-6));

        // Near-1.0x speed bypasses pitchShiftFilter (wet=0.0, shift=1.0).
        engine.setRelativePlaySpeed(v1, 1.0005, preservePitch: true);
        expect(
          engine.filterParams.skip(engine.filterParams.length - 2),
          equals([(b1.id, pitchFt, 0, 0.0), (b1.id, pitchFt, 1, 1.0)]),
        );

        // Subsequent preservePitch: false also bypasses existing pitch bus without disposing mid-flight.
        engine.setRelativePlaySpeed(v1, 1.5, preservePitch: false);
        expect(engine.destroyedBusIds, isEmpty);
        expect(
          engine.filterParams.skip(engine.filterParams.length - 2),
          equals([(b1.id, pitchFt, 0, 0.0), (b1.id, pitchFt, 1, 1.0)]),
        );

        // stop(v1) disposes v1's pitch bus cleanly.
        engine.stop(v1);
        expect(engine.destroyedBusIds, equals([b1.id]));

        // Failed annex rolls back allocated pitch bus immediately.
        engine.throwOnAnnex = true;
        expect(
          () => engine.setRelativePlaySpeed(v2, 0.5, preservePitch: true),
          throwsStateError,
        );
        expect(engine.destroyedBusIds, hasLength(2));
        engine.throwOnAnnex = false;

        // dispose() cleans up any remaining voice pitch buses.
        engine.setRelativePlaySpeed(v2, 2.0, preservePitch: true);
        final b2 = engine.createdBuses.last;
        expect(engine.destroyedBusIds, isNot(contains(b2.id)));
        await engine.dispose();
        expect(engine.destroyedBusIds, contains(b2.id));

        // Base annexVoiceToBus no-ops safely for unregistered non-FlutterAudioBus handles.
        uninit.annexVoiceToBus(_FakeAudioBus(999), 1);
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

    test('setVoicePan throws when engine is not initialized', () {
      final engine = FlutterAudioEngine();
      final voice = AudioVoice(7, Completer<void>().future);

      expect(() => engine.setVoicePan(voice, -0.5), throwsA(isA<Exception>()));
    });
  });
}
