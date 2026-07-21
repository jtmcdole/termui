import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:flutter_soloud/flutter_soloud.dart' as sol;
import 'package:web/web.dart' as web;
import 'audio_service.dart';

@JS('eval')
external void _eval(JSString code);

@JS('window.resumeAllAudioContexts')
external void _resumeAllAudioContexts();

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
    // Intercept AudioContext creation to auto-resume on first user gesture.
    // This allows developers to call init() during a loading screen without
    // the audio remaining permanently muted.
    // Use JS eval to install the interceptor
    final jsCode =
        '''
      (function() {
        if (window._audioContextAutoResumerInstalled) return;
        window._audioContextAutoResumerInstalled = true;

        window._audioContexts = [];
        const OrigContext = window.AudioContext || window.webkitAudioContext;
        if (OrigContext) {
          window.AudioContext = function(...args) {
            const ctx = new OrigContext(...args);
            window._audioContexts.push(ctx);
            return ctx;
          };
          window.AudioContext.prototype = OrigContext.prototype;
        }

        window.resumeAllAudioContexts = () => {
          window._audioContexts.forEach(ctx => {
            if (ctx.state === 'suspended') ctx.resume();
          });
        };

        window.addEventListener('click', window.resumeAllAudioContexts, { capture: true });
        window.addEventListener('keydown', window.resumeAllAudioContexts, { capture: true });
      })();
    '''
            .toJS;

    // Call global eval
    _eval(jsCode);

    // Defer SoLoud initialization until first sound is loaded/played
    // to ensure the AudioContext is created during a user gesture if possible.

    // Initialize the Web Worker
    final worker = web.Worker(
      'assets/packages/termui_audio/web/worker.dart.js'.toJS,
    );
    _worker = worker;

    // Listen to worker responses
    worker.onmessage = ((web.MessageEvent event) {
      final jsData = event.data as JSObject?;
      if (jsData == null) return;

      final action = jsData.getProperty('action'.toJS).dartify() as String?;
      final path = jsData.getProperty('path'.toJS).dartify() as String?;

      if (action == null || path == null) return;

      final completer = _pendingLoads.remove(path);
      if (completer == null) return;

      if (action == 'loaded') {
        final buffer = jsData.getProperty('bytes'.toJS) as JSArrayBuffer?;
        if (buffer != null) {
          final bytes = buffer.toDart.asUint8List();
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
        final errorMsg =
            jsData.getProperty('error'.toJS).dartify() as String? ??
            'Unknown error';
        completer.completeError(Exception(errorMsg));
      }
    }).toJS;
  }

  @override
  Future<SoundHandle> loadSound(String path) async {
    if (!sol.SoLoud.instance.isInitialized) {
      await sol.SoLoud.instance.init();
    }
    if (_worker == null) {
      throw Exception('Web worker not initialized.');
    }

    // Resolve relative paths against the document's base URI
    // to properly support `<base href="...">` like `--base-href="/roguetui/"`.
    String absolutePath = path;
    if (!path.startsWith('http://') && !path.startsWith('https://')) {
      absolutePath = web.URL(path, web.document.baseURI).href;
    }

    if (_loadedSources.containsKey(absolutePath)) {
      return SoundHandle(absolutePath);
    }

    final completer = Completer<SoundHandle>();
    _pendingLoads[absolutePath] = completer;

    // Delegate loading and caching to worker
    final req = JSObject();
    req['action'] = 'load'.toJS;
    req['path'] = absolutePath.toJS;
    _worker!.postMessage(req);

    return completer.future;
  }

  @override
  Future<void> playSound(SoundHandle handle, {bool loop = false}) async {
    if (!sol.SoLoud.instance.isInitialized) {
      await sol.SoLoud.instance.init();
    }
    _resumeAllAudioContexts();
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
