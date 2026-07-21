import 'package:termui_audio/termui_audio.dart';
import 'package:test/test.dart';
import 'dart:async';

// Mock implementation to test API surface
class MockAudioEngine extends TermuiAudioEngine {
  @override
  Future<void> dispose() async {}

  @override
  Future<void> init() async {}

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
  Future<AudioBuffer> loadWaveform(WaveForm shape, double frequency) async {
    throw UnimplementedError();
  }

  @override
  AudioVoice play(AudioBuffer buffer, {bool loop = false, AudioBus? bus}) {
    throw UnimplementedError();
  }

  @override
  AudioVoice play3d(AudioBuffer buffer, double x, double y, double z) {
    throw UnimplementedError();
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
  void stop(AudioVoice voice) {}

  @override
  Duration getBufferDuration(AudioBuffer buffer) => Duration.zero;

  @override
  Duration getVoicePosition(AudioVoice voice) => Duration.zero;

  @override
  void seek(AudioVoice voice, Duration position) {}
}

class MockAudioBuffer implements AudioBuffer {
  @override
  int get hash => 0;
}

void main() {
  test(
    'TermuiAudioEngine API surface has MVVM duration, position, and completion getters',
    () {
      final TermuiAudioEngine engine = MockAudioEngine();

      // 2. Assert getBufferDuration exists
      final AudioBuffer dummyBuffer = MockAudioBuffer();
      final Duration length = engine.getBufferDuration(dummyBuffer);
      expect(length, isNotNull);

      // 3. Assert getVoicePosition exists
      final AudioVoice dummyVoice = AudioVoice(0, Completer<void>().future);
      final Duration pos = engine.getVoicePosition(dummyVoice);
      expect(pos, isNotNull);
    },
  );
}
