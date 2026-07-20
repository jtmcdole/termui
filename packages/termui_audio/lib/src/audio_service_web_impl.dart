import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:flutter_soloud/flutter_soloud.dart' as sol;
import 'package:web/web.dart' as web;
import 'audio_service.dart';

/// The Web audio service backend that delegates asset loading, HTTP fetching,
/// and IndexedDB caching to a Web Worker (`worker.dart.js`), and plays audio
/// using `flutter_soloud`'s WASM engine.
class WebAudioService implements AudioService {
  final Map<String, sol.AudioSource> _loadedSources = {};
  final Map<String, List<sol.SoundHandle>> _playingVoices = {};
  final Map<String, Completer<SoundHandle>> _pendingLoads = {};
  sol.SoundHandle? _bgmVoice;
  web.Worker? _worker;

  @override
  Future<void> init() async {
    if (!sol.SoLoud.instance.isInitialized) {
      await sol.SoLoud.instance.init();
    }

    // Initialize the Web Worker
    final worker = web.Worker('packages/termui_audio/web/worker.dart.js'.toJS);
    _worker = worker;

    // Listen to worker responses
    worker.onmessage = (web.MessageEvent event) {
      final jsData = event.data;
      if (jsData == null) return;
      final data = jsData.dartify();
      if (data is Map) {
        final action = data['action'] as String?;
        final path = data['path'] as String?;
        if (path == null) return;

        final completer = _pendingLoads.remove(path);
        if (completer == null) return;

        if (action == 'loaded') {
          final bytes = data['bytes'];
          if (bytes is Uint8List) {
            // Load the buffer into SoLoud
            sol.SoLoud.instance
                .loadMem(path, bytes)
                .then((source) {
                  _loadedSources[path] = source;
                  completer.complete(SoundHandle(path));
                })
                .catchError((e) {
                  completer.completeError(e);
                });
          } else {
            completer.completeError(
              Exception('Invalid bytes format received from worker'),
            );
          }
        } else if (action == 'error') {
          final errorMsg = data['error'] as String? ?? 'Unknown error';
          completer.completeError(Exception(errorMsg));
        }
      }
    }.toJS;
  }

  @override
  Future<SoundHandle> loadSound(String path) async {
    if (_worker == null) {
      throw Exception('Web worker not initialized.');
    }

    if (_loadedSources.containsKey(path)) {
      return SoundHandle(path);
    }

    final completer = Completer<SoundHandle>();
    _pendingLoads[path] = completer;

    // Delegate loading and caching to worker
    _worker!.postMessage({'action': 'load', 'path': path}.jsify());

    return completer.future;
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
  Future<void> dispose() async {
    _worker?.terminate();
    _worker = null;
    if (sol.SoLoud.instance.isInitialized) {
      sol.SoLoud.instance.deinit();
    }
    _loadedSources.clear();
    _playingVoices.clear();
    _bgmVoice = null;

    // Resolve any hanging futures before disposing
    for (final completer in _pendingLoads.values) {
      if (!completer.isCompleted) {
        completer.completeError(Exception('AudioService was disposed.'));
      }
    }
    _pendingLoads.clear();
  }
}
