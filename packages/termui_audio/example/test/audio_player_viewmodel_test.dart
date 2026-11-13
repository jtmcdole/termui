import 'dart:async';
import 'dart:convert';
import 'dart:math' show Point;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui_audio/termui_audio.dart';
import 'package:termui_audio_example/src/audio_player_app.dart';

class MockAudioBuffer implements AudioBuffer {
  @override
  int get hash => 12345;
}

class MockAudioEngine implements TermuiAudioEngine {
  @override
  Future<void> init({bool enableVisualization = true}) async {}
  @override
  Future<Uint8List> loadFileBytes(String path) async => Uint8List(0);
  @override
  Future<AudioBuffer> loadMem(
    String pathId,
    Uint8List bytes, {
    bool stream = false,
  }) async => MockAudioBuffer();
  @override
  Future<AudioBuffer> createBufferStream({
    int maxBufferSize = 4 * 1024 * 1024,
    bool releaseConsumed = false,
    Duration bufferingTimeNeeds = const Duration(milliseconds: 500),
    int sampleRate = 48000,
    int channels = 2,
  }) async => MockAudioBuffer();
  @override
  void addStreamData(AudioBuffer buffer, Uint8List chunk) {}
  @override
  void setStreamEnded(AudioBuffer buffer) {}
  @override
  Future<void> dispose() async {}
  @override
  Future<AudioBuffer> loadFile(
    String path, {
    bool stream = false,
    LoadProgressCallback? onProgress,
  }) async => throw UnimplementedError();
  @override
  Future<AudioBuffer> loadUrl(
    String url, {
    LoadProgressCallback? onProgress,
  }) async => throw UnimplementedError();
  @override
  Future<AudioBuffer> loadWaveform(
    WaveForm shape,
    double frequency, {
    bool usePcmFallback = false,
  }) async => throw UnimplementedError();
  @override
  Future<void> disposeBuffer(AudioBuffer buffer) async {}
  @override
  AudioVoice play(
    AudioBuffer buffer, {
    AudioBus? bus,
    bool loop = false,
    bool paused = false,
  }) => throw UnimplementedError();
  @override
  void setPaused(AudioVoice voice, bool paused) {}
  @override
  void stop(AudioVoice voice) {}
  @override
  void setVoiceVolume(AudioVoice voice, double volume) {}
  @override
  void setVoicePan(AudioVoice voice, double pan) {}
  @override
  AudioVoice play3d(AudioBuffer buffer, double x, double y, double z) =>
      throw UnimplementedError();
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
  Duration getBufferDuration(AudioBuffer buffer) => Duration.zero;
  @override
  Duration getVoicePosition(AudioVoice voice) => Duration.zero;
  @override
  Stream<Duration> getVoicePositionStream(
    AudioVoice voice, {
    Duration interval = const Duration(milliseconds: 50),
  }) => Stream.value(Duration.zero);
  @override
  void seek(AudioVoice voice, Duration position) {}

  @override
  void setRelativePlaySpeed(
    AudioVoice voice,
    double speed, {
    bool preservePitch = false,
  }) {}
  @override
  void fadeRelativePlaySpeed(
    AudioVoice voice,
    double speed,
    Duration duration,
  ) {}
  @override
  void fadeVolume(AudioVoice voice, double targetVolume, Duration duration) {}

  @override
  void scheduleStop(AudioVoice voice, Duration duration) {}
  @override
  int createFilter(FilterType type) => 0;
  @override
  void attachFilterToBus(AudioBus bus, int filterId) {}
  @override
  void setFilterParameter(
    AudioBus bus,
    int filterId,
    int paramId,
    double value,
  ) {}
  @override
  double getFilterParameter(AudioBus bus, int filterId, int paramId) => 0.0;
  @override
  void fadeFilterParameter(
    AudioBus bus,
    int filterId,
    int paramId,
    double targetValue,
    Duration duration,
  ) {}
  @override
  AudioVoice playSprite(
    AudioBuffer buffer, {
    AudioBus? bus,
    required Duration start,
    required Duration duration,
  }) => throw UnimplementedError();
  @override
  Future<void> playSpriteSequence(
    AudioBuffer buffer,
    List<SpriteSegment> segments, {
    AudioBus? bus,
  }) async {}
  @override
  AudioBus createBus() => throw UnimplementedError();
  @override
  void destroyBus(AudioBus bus) {}
  @override
  Float32List getWaveform([Float32List? outBuffer]) =>
      outBuffer ?? Float32List(256);

  @override
  Future<Float32List> fetchWaveform([Float32List? outBuffer]) async =>
      getWaveform(outBuffer);

  @override
  Stream<Float32List> watchWaveform({
    Duration interval = const Duration(milliseconds: 100),
  }) => const Stream.empty();
}

final class _MemoryTerminalBackend implements term.TerminalBackend {
  final StreamController<List<int>> _input = StreamController<List<int>>();
  final List<String> writes = [];

  @override
  bool get isWindows => false;

  @override
  Stream<List<int>> get rawInput => _input.stream;

  @override
  void write(String data) {
    writes.add(data);
  }

  @override
  Point<int> get size => const Point(80, 24);

  @override
  Stream<Point<int>> watchSize() => const Stream.empty();

  @override
  void enableRawMode() {}

  @override
  void disableRawMode() {}

  @override
  void dispose() {
    unawaited(_input.close());
  }

  void emitApcReply(String frame) {
    _input.add(utf8.encode(frame));
  }

  void sendCtrlC() {
    _input.add([0x03]);
  }
}

void main() {
  test('AudioPlayerViewModel should support activeRadarIndex and movement', () {
    final vm = AudioPlayerViewModel(
      audioService: MockAudioEngine(),
      loadAsset: (path, {onProgress}) async => throw UnimplementedError(),
    );

    // Assert that activeRadarIndex exists and defaults to 0
    expect(vm.activeRadarIndex, equals(0));

    // Assert that cycleRadarIndex wraps around
    vm.cycleRadarIndex();
    expect(vm.activeRadarIndex, equals(1));

    // Assert moveRadarIndex updates sourceX/sourceY for the active index
    final initialX = vm.sourceX[1];
    vm.moveRadarIndex(2.0, -1.0);
    expect(vm.sourceX[1], equals(initialX + 2.0));

    // Assert volume bounding
    vm.changeBgmVolume(0.5);
    expect(vm.bgmVolume, equals(1.0)); // bounded to 1.0 max
    vm.changeSfxVolume(-2.0);
    expect(vm.sfxVolume, equals(0.0)); // bounded to 0.0 min
  });

  test(
    'runAudioPlayerApp attaches terminal.audioApcReplies to PtyApcAudioEngine',
    () async {
      final backend = _MemoryTerminalBackend();
      final terminal = term.Terminal(backend);
      final engine = PtyApcAudioEngine(backend.write);

      final appFuture = runAudioPlayerApp(
        terminal,
        engine,
        (path, {onProgress}) async => MockAudioBuffer(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final samples = Float32List(256)..[7] = 0.42;
      final fetchFuture = engine.fetchWaveform();
      await Future<void>.delayed(Duration.zero);
      expect(
        backend.writes.any((w) => w.contains('\x1b_Aa=wave,q=1;\x1b\\')),
        isTrue,
      );
      backend.emitApcReply(ApcAudioEncoder.encodeWaveformReply(1, samples));

      final received = await fetchFuture.timeout(const Duration(seconds: 2));
      expect(received[7], closeTo(0.42, 1e-6));

      backend.sendCtrlC();
      await appFuture.timeout(const Duration(seconds: 2));
      await engine.dispose();
      terminal.dispose();
    },
  );
}
