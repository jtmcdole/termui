// ignore_for_file: avoid_relative_lib_imports
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:termui_audio/termui_audio.dart';
import '../example/lib/src/audio_player_app.dart';

class MockAudioEngine implements TermuiAudioEngine {
  @override
  Future<void> init() async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<AudioBuffer> loadFile(
    String path, {
    LoadProgressCallback? onProgress,
  }) async => throw UnimplementedError();
  @override
  Future<AudioBuffer> loadUrl(
    String url, {
    LoadProgressCallback? onProgress,
  }) async => throw UnimplementedError();
  @override
  Future<AudioBuffer> loadWaveform(WaveForm shape, double frequency, {bool usePcmFallback = false}) async =>
      throw UnimplementedError();
  @override
  Future<void> disposeBuffer(AudioBuffer buffer) async {}
  @override
  AudioVoice play(AudioBuffer buffer, {bool loop = false, AudioBus? bus}) =>
      throw UnimplementedError();
  @override
  void stop(AudioVoice voice) {}
  @override
  void setVoiceVolume(AudioVoice voice, double volume) {}
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
  void seek(AudioVoice voice, Duration position) {}

  @override
  void setRelativePlaySpeed(AudioVoice voice, double speed) {}
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
    required Duration start,
    required Duration duration,
  }) => throw UnimplementedError();
  @override
  void playSpriteSequence(
    AudioBuffer buffer,
    List<SpriteSegment> segments, {
    AudioBus? bus,
  }) {}
  @override
  AudioBus createBus() => throw UnimplementedError();
  @override
  void destroyBus(AudioBus bus) {}
  @override
  Float32List getWaveform() => Float32List(256);
}

void main() {
  test('AudioPlayerViewModel should support activeRadarIndex and movement', () {
    final vm = AudioPlayerViewModel(
      audioService: MockAudioEngine(),
      loadAsset: (path, {onProgress}) async => throw UnimplementedError(),
    );

    // Assert that activeRadarIndex exists and defaults to 0
    expect((vm as dynamic).activeRadarIndex, equals(0));

    // Assert that cycleRadarIndex wraps around
    (vm as dynamic).cycleRadarIndex();
    expect((vm as dynamic).activeRadarIndex, equals(1));

    // Assert moveRadarIndex updates sourceX/sourceY for the active index
    final initialX = vm.sourceX[1];
    (vm as dynamic).moveRadarIndex(2.0, -1.0);
    expect(vm.sourceX[1], equals(initialX + 2.0));

    // Assert volume bounding
    (vm as dynamic).changeBgmVolume(0.5);
    expect(vm.bgmVolume, equals(1.0)); // bounded to 1.0 max
    (vm as dynamic).changeSfxVolume(-2.0);
    expect(vm.sfxVolume, equals(0.0)); // bounded to 0.0 min
  });
}
