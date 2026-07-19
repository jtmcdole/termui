import 'dart:async';
import 'package:flutter_soloud/flutter_soloud.dart' as sol;
import 'audio_service.dart';

/// The Flutter Desktop audio service backend that delegates to `flutter_soloud`.
class FlutterAudioService implements AudioService {
  final Map<SoundHandle, sol.AudioSource> _loadedSources = {};
  final Map<SoundHandle, List<sol.SoundHandle>> _playingVoices = {};
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
    final handle = SoundHandle(path);
    _loadedSources[handle] = source;
    return handle;
  }

  @override
  Future<void> playSound(SoundHandle handle, {bool loop = false}) async {
    final source = _loadedSources[handle];
    if (source == null) return;
    final voice = sol.SoLoud.instance.play(source, looping: loop);
    _playingVoices.putIfAbsent(handle, () => []).add(voice);
    if (loop) {
      _bgmVoice = voice;
    }
  }

  @override
  Future<void> stopSound(SoundHandle handle) async {
    final voices = _playingVoices[handle];
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
  Future<void> dispose() async {
    if (sol.SoLoud.instance.isInitialized) {
      sol.SoLoud.instance.deinit();
    }
    _loadedSources.clear();
    _playingVoices.clear();
    _bgmVoice = null;
  }
}
