import 'dart:async';
import 'dart:typed_data';
import 'package:termui_audio/termui_audio.dart';
import 'package:test/test.dart';

class MockAudioBus implements AudioBus {
  @override
  final int id;
  double _volume = 1.0;

  MockAudioBus(this.id);

  @override
  void setVolume(double volume) {
    _volume = volume;
  }

  double get volume => _volume;
}

class MockAudioEngine extends TermuiAudioEngine {
  final List<String> callLog = [];
  final Map<int, double> voiceSpeeds = {};
  final Map<int, (double, Duration)> voiceSpeedFades = {};
  final Map<int, (double, Duration)> voiceVolumeFades = {};
  final Map<int, FilterType> activeFilters = {};
  final Map<int, List<int>> busAttachedFilters = {};
  final Map<String, double> filterParams = {};
  final Set<int> activeBuses = {};
  int _nextFilterId = 1;
  int _nextBusId = 1;
  int _nextVoiceId = 1;

  @override
  Future<void> dispose() async {}

  @override
  Future<void> init() async {}

  @override
  void scheduleStop(AudioVoice voice, Duration duration) {
    callLog.add('scheduleStop(${voice.id})');
  }

  @override
  Future<AudioBuffer> loadFile(
    String path, {
    LoadProgressCallback? onProgress,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<AudioBuffer> loadUrl(
    String url, {
    LoadProgressCallback? onProgress,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<AudioBuffer> loadWaveform(WaveForm shape, double frequency, {bool usePcmFallback = false}) async {
    throw UnimplementedError();
  }

  @override
  Future<void> disposeBuffer(AudioBuffer buffer) async {}

  @override
  AudioVoice play(AudioBuffer buffer, {bool loop = false, AudioBus? bus}) {
    final voiceId = _nextVoiceId++;
    callLog.add('play(${buffer.hash}, loop: $loop, bus: ${bus?.id})');
    return AudioVoice(voiceId, Completer<void>().future);
  }

  @override
  AudioVoice play3d(AudioBuffer buffer, double x, double y, double z) {
    final voiceId = _nextVoiceId++;
    callLog.add('play3d(${buffer.hash}, $x, $y, $z)');
    return AudioVoice(voiceId, Completer<void>().future);
  }

  @override
  void set3dSourceParameters(
    AudioVoice voice,
    double x,
    double y,
    double z, {
    double vx = 0.0,
    double vy = 0.0,
    double vz = 0.0,
  }) {}

  @override
  void setVoiceVolume(AudioVoice voice, double volume) {}

  @override
  void set3dSourceMinMaxDistance(
    AudioVoice voice,
    double minDistance,
    double maxDistance,
  ) {}

  @override
  void set3dSourceAttenuation(
    AudioVoice voice,
    AttenuationModel attenuationModel,
    double attenuationRolloffFactor,
  ) {}

  @override
  void stop(AudioVoice voice) {
    callLog.add('stop(${voice.id})');
  }

  @override
  Duration getBufferDuration(AudioBuffer buffer) => Duration.zero;

  @override
  Duration getVoicePosition(AudioVoice voice) => Duration.zero;

  @override
  void seek(AudioVoice voice, Duration position) {
    callLog.add('seek(${voice.id}, ${position.inMilliseconds}ms)');
  }

  @override
  void setRelativePlaySpeed(AudioVoice voice, double speed) {
    callLog.add('setRelativePlaySpeed(${voice.id}, $speed)');
    voiceSpeeds[voice.id] = speed;
  }

  @override
  void fadeRelativePlaySpeed(
    AudioVoice voice,
    double speed,
    Duration duration,
  ) {
    callLog.add(
      'fadeRelativePlaySpeed(${voice.id}, $speed, ${duration.inMilliseconds}ms)',
    );
    voiceSpeedFades[voice.id] = (speed, duration);
  }

  @override
  void fadeVolume(AudioVoice voice, double targetVolume, Duration duration) {
    callLog.add(
      'fadeVolume(${voice.id}, $targetVolume, ${duration.inMilliseconds}ms)',
    );
    voiceVolumeFades[voice.id] = (targetVolume, duration);
  }

  @override
  int createFilter(FilterType type) {
    final id = _nextFilterId++;
    activeFilters[id] = type;
    callLog.add('createFilter($type) -> $id');
    return id;
  }

  @override
  void attachFilterToBus(AudioBus bus, int filterId) {
    callLog.add('attachFilterToBus(${bus.id}, $filterId)');
    busAttachedFilters.putIfAbsent(bus.id, () => []).add(filterId);
  }

  @override
  void setFilterParameter(
    AudioBus bus,
    int filterId,
    int paramId,
    double value,
  ) {
    callLog.add('setFilterParameter(${bus.id}, $filterId, $paramId, $value)');
    filterParams['${bus.id}_${filterId}_$paramId'] = value;
  }

  @override
  void fadeFilterParameter(
    AudioBus bus,
    int filterId,
    int paramId,
    double targetValue,
    Duration duration,
  ) {
    callLog.add(
      'fadeFilterParameter(${bus.id}, $filterId, $paramId, $targetValue, ${duration.inMilliseconds}ms)',
    );
    filterParams['fade_${bus.id}_${filterId}_$paramId'] = targetValue;
  }

  @override
  AudioVoice playSprite(
    AudioBuffer buffer, {
    required Duration start,
    required Duration duration,
  }) {
    final voiceId = _nextVoiceId++;
    callLog.add(
      'playSprite(${buffer.hash}, start: ${start.inMilliseconds}ms, duration: ${duration.inMilliseconds}ms)',
    );
    final completer = Completer<void>();
    Future.delayed(duration, () => completer.complete());
    return AudioVoice(voiceId, completer.future);
  }

  @override
  void playSpriteSequence(
    AudioBuffer buffer,
    List<SpriteSegment> segments, {
    AudioBus? bus,
  }) {
    callLog.add(
      'playSpriteSequence(${buffer.hash}, count: ${segments.length})',
    );
  }

  @override
  AudioBus createBus() {
    final busId = _nextBusId++;
    activeBuses.add(busId);
    callLog.add('createBus() -> $busId');
    return MockAudioBus(busId);
  }

  @override
  void destroyBus(AudioBus bus) {
    callLog.add('destroyBus(${bus.id})');
    activeBuses.remove(bus.id);
  }

  @override
  Float32List getWaveform() => Float32List(256);
}

class MockAudioBuffer implements AudioBuffer {
  @override
  int get hash => 12345;
}

void main() {
  test(
    'TermuiAudioEngine API surface has MVVM duration, position, and completion getters',
    () {
      final TermuiAudioEngine engine = MockAudioEngine();

      final AudioBuffer dummyBuffer = MockAudioBuffer();
      final Duration length = engine.getBufferDuration(dummyBuffer);
      expect(length, isNotNull);

      final AudioVoice dummyVoice = AudioVoice(0, Completer<void>().future);
      final Duration pos = engine.getVoicePosition(dummyVoice);
      expect(pos, isNotNull);
    },
  );

  test('TermuiAudioEngine API surface has distance attenuation methods', () {
    final TermuiAudioEngine engine = MockAudioEngine();
    final AudioVoice dummyVoice = AudioVoice(0, Completer<void>().future);

    engine.set3dSourceMinMaxDistance(dummyVoice, 1.0, 10.0);
    engine.set3dSourceAttenuation(
      dummyVoice,
      AttenuationModel.linearDistance,
      1.0,
    );
  });

  group('MockAudioEngine DSP & Filter API Surface Tests', () {
    late MockAudioEngine engine;
    late AudioVoice voice;

    setUp(() {
      engine = MockAudioEngine();
      voice = AudioVoice(1, Completer<void>().future);
    });

    test('TS-01: setRelativePlaySpeed updates speed state', () {
      engine.setRelativePlaySpeed(voice, 1.5);
      expect(engine.voiceSpeeds[1], equals(1.5));
      expect(engine.callLog, contains('setRelativePlaySpeed(1, 1.5)'));
    });

    test('TS-02: fadeRelativePlaySpeed updates fade target and duration', () {
      const dur = Duration(milliseconds: 300);
      engine.fadeRelativePlaySpeed(voice, 0.75, dur);
      expect(engine.voiceSpeedFades[1], equals((0.75, dur)));
      expect(engine.callLog, contains('fadeRelativePlaySpeed(1, 0.75, 300ms)'));
    });

    test('TV-01: fadeVolume updates volume fade target and duration', () {
      const dur = Duration(milliseconds: 150);
      engine.fadeVolume(voice, 0.0, dur);
      expect(engine.voiceVolumeFades[1], equals((0.0, dur)));
      expect(engine.callLog, contains('fadeVolume(1, 0.0, 150ms)'));
    });

    test('TF-01: createFilter returns unique IDs for FilterTypes', () {
      final f1 = engine.createFilter(FilterType.biquadResonant);
      final f2 = engine.createFilter(FilterType.echo);
      expect(f1, isNot(equals(f2)));
      expect(engine.activeFilters[f1], equals(FilterType.biquadResonant));
      expect(engine.activeFilters[f2], equals(FilterType.echo));
    });

    test(
      'TF-02: attachFilterToBus, setFilterParameter, fadeFilterParameter',
      () {
        final bus = engine.createBus();
        final filterId = engine.createFilter(FilterType.flanger);
        engine.attachFilterToBus(bus, filterId);
        engine.setFilterParameter(bus, filterId, 0, 440.0);
        engine.fadeFilterParameter(
          bus,
          filterId,
          0,
          880.0,
          const Duration(milliseconds: 200),
        );

        expect(engine.busAttachedFilters[bus.id], contains(filterId));
        expect(engine.filterParams['${bus.id}_${filterId}_0'], equals(440.0));
        expect(
          engine.filterParams['fade_${bus.id}_${filterId}_0'],
          equals(880.0),
        );
      },
    );

    test(
      'TS-10: playSprite invokes sprite playback and resolves completion',
      () async {
        final buffer = MockAudioBuffer();
        final spriteVoice = engine.playSprite(
          buffer,
          start: const Duration(milliseconds: 100),
          duration: const Duration(milliseconds: 50),
        );
        expect(spriteVoice, isNotNull);
        expect(
          engine.callLog,
          contains('playSprite(12345, start: 100ms, duration: 50ms)'),
        );
        await expectLater(spriteVoice.completed, completes);
      },
    );

    test('TB-01: createBus and destroyBus manage bus lifecycle', () {
      final bus = engine.createBus();
      expect(engine.activeBuses, contains(bus.id));
      engine.destroyBus(bus);
      expect(engine.activeBuses, isNot(contains(bus.id)));
    });
  });
}
