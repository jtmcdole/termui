import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_soloud/flutter_soloud.dart' as sol;
import 'audio_service.dart';

/// The Flutter Desktop audio service backend that delegates to `flutter_soloud`.
class FlutterAudioService implements AudioService {
  final Map<String, sol.AudioSource> _loadedSources = {};
  final Map<String, List<sol.SoundHandle>> _playingVoices = {};
  sol.SoundHandle? _bgmVoice;

  @override
  Future<void> init() async {
    if (!sol.SoLoud.instance.isInitialized) {
      await sol.SoLoud.instance.init();
    }
  }

  @override
  Future<SoundHandle> loadSound(String path) async {
    final source = await sol.SoLoud.instance.loadFile(path);
    _loadedSources[path] = source;
    return SoundHandle(path);
  }

  @override
  Future<void> playSound(SoundHandle handle, {bool loop = false}) async {
    final path = handle.id as String;
    final source = _loadedSources[path];
    if (source == null) return;
    final voice = sol.SoLoud.instance.play(source, looping: loop);
    _playingVoices.putIfAbsent(path, () => []).add(voice);
    if (loop) {
      _bgmVoice = voice;
    }
  }

  @override
  Future<void> stopSound(SoundHandle handle) async {
    final path = handle.id as String;
    final voices = _playingVoices[path];
    if (voices != null) {
      for (final voice in voices) {
        if (sol.SoLoud.instance.getIsValidVoiceHandle(voice)) {
          sol.SoLoud.instance.stop(voice);
        }
      }
      voices.clear();
    }
  }

  @override
  Future<void> setBgmVolume(double volume) async {
    if (_bgmVoice != null &&
        sol.SoLoud.instance.getIsValidVoiceHandle(_bgmVoice!)) {
      sol.SoLoud.instance.setVolume(_bgmVoice!, volume);
    }
  }

  @override
  Future<void> setRelativePlaySpeed(SoundHandle handle, double speed) async {
    final path = handle.id as String;
    final voices = _playingVoices[path];
    if (voices != null) {
      for (final voice in voices) {
        if (sol.SoLoud.instance.getIsValidVoiceHandle(voice)) {
          sol.SoLoud.instance.setRelativePlaySpeed(voice, speed);
        }
      }
    }
  }

  @override
  Future<void> fadeRelativePlaySpeed(
    SoundHandle handle,
    double speed,
    Duration duration,
  ) async {
    final path = handle.id as String;
    final voices = _playingVoices[path];
    if (voices != null) {
      for (final voice in voices) {
        if (sol.SoLoud.instance.getIsValidVoiceHandle(voice)) {
          sol.SoLoud.instance.fadeRelativePlaySpeed(voice, speed, duration);
        }
      }
    }
  }

  @override
  Future<void> fadeVolume(
    SoundHandle handle,
    double targetVolume,
    Duration duration,
  ) async {
    final path = handle.id as String;
    final voices = _playingVoices[path];
    if (voices != null) {
      for (final voice in voices) {
        if (sol.SoLoud.instance.getIsValidVoiceHandle(voice)) {
          sol.SoLoud.instance.fadeVolume(voice, targetVolume, duration);
        }
      }
    }
  }

  @override
  Future<void> fadeBgmVolume(double targetVolume, Duration duration) async {
    if (_bgmVoice != null &&
        sol.SoLoud.instance.getIsValidVoiceHandle(_bgmVoice!)) {
      sol.SoLoud.instance.fadeVolume(_bgmVoice!, targetVolume, duration);
    }
  }

  @override
  Future<void> playSpriteSequence(
    SoundHandle handle,
    List<SpriteSegment> segments,
  ) async {
    if (segments.isEmpty) return;
    final path = handle.id as String;
    final source = _loadedSources[path];
    if (source == null) return;

    var totalDelay = Duration.zero;
    for (final seg in segments) {
      final segDelay = totalDelay;
      totalDelay += seg.duration;

      if (segDelay == Duration.zero) {
        final voice = sol.SoLoud.instance.play(source, looping: false);
        if (seg.start.inMicroseconds > 0) {
          sol.SoLoud.instance.seek(voice, seg.start);
        }
        sol.SoLoud.instance.fadeVolume(voice, 0.0, seg.duration);
      } else {
        unawaited(
          Future.delayed(segDelay, () {
            if (!sol.SoLoud.instance.isInitialized) return;
            final voice = sol.SoLoud.instance.play(source, looping: false);
            if (seg.start.inMicroseconds > 0) {
              sol.SoLoud.instance.seek(voice, seg.start);
            }
            sol.SoLoud.instance.fadeVolume(voice, 0.0, seg.duration);
          }),
        );
      }
    }
  }

  @override
  Float32List getWaveform() {
    return Float32List(256);
  }

  @override
  Uint8List renderWavGolden({
    required Duration duration,
    int sampleRate = 44100,
  }) {
    final numSamples = (sampleRate * (duration.inMicroseconds / 1000000.0))
        .round();
    final dataSize = numSamples * 2;
    final fileSize = 36 + dataSize;

    final bytes = ByteData(44 + dataSize);
    bytes.setUint8(0, 0x52);
    bytes.setUint8(1, 0x49);
    bytes.setUint8(2, 0x46);
    bytes.setUint8(3, 0x46);
    bytes.setUint32(4, fileSize, Endian.little);
    bytes.setUint8(8, 0x57);
    bytes.setUint8(9, 0x41);
    bytes.setUint8(10, 0x56);
    bytes.setUint8(11, 0x45);
    bytes.setUint8(12, 0x66);
    bytes.setUint8(13, 0x6d);
    bytes.setUint8(14, 0x74);
    bytes.setUint8(15, 0x20);
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little);
    bytes.setUint16(22, 1, Endian.little);
    bytes.setUint32(24, sampleRate, Endian.little);
    bytes.setUint32(28, sampleRate * 2, Endian.little);
    bytes.setUint16(32, 2, Endian.little);
    bytes.setUint16(34, 16, Endian.little);
    bytes.setUint8(36, 0x64);
    bytes.setUint8(37, 0x61);
    bytes.setUint8(38, 0x74);
    bytes.setUint8(39, 0x61);
    bytes.setUint32(40, dataSize, Endian.little);

    return bytes.buffer.asUint8List();
  }

  @override
  Future<void> dispose() async {
    if (sol.SoLoud.instance.isInitialized) {
      sol.SoLoud.instance.deinit();
    }
    _loadedSources.clear();
    _playingVoices.clear();
    _bgmVoice = null;
  }
}
