import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
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

      void playSegment() {
        if (!sol.SoLoud.instance.isInitialized) return;
        final voice = sol.SoLoud.instance.play(source, looping: false);
        _playingVoices.putIfAbsent(path, () => []).add(voice);
        if (seg.start.inMicroseconds > 0) {
          sol.SoLoud.instance.seek(voice, seg.start);
        }
        Timer(seg.duration, () {
          try {
            sol.SoLoud.instance.fadeVolume(
              voice,
              0.0,
              const Duration(milliseconds: 10),
            );
            Timer(const Duration(milliseconds: 12), () {
              try {
                if (sol.SoLoud.instance.getIsValidVoiceHandle(voice)) {
                  sol.SoLoud.instance.stop(voice);
                }
              } catch (_) {}
            });
          } catch (_) {}
        });
      }

      if (segDelay == Duration.zero) {
        playSegment();
      } else {
        unawaited(Future.delayed(segDelay, playSegment));
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
