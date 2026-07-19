import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'audio_service.dart';
import 'soloud_cli.dart';

/// The pure Dart CLI backend that directly interfaces with the compiled C++
/// SoLoud library using FFI and Native Assets.
class CliAudioService implements AudioService {
  final Map<SoundHandle, int> _loadedHashes = {};
  final Map<SoundHandle, List<int>> _playingVoices = {};
  int? _bgmVoice;
  bool _inited = false;

  // Auto-Reclaiming Memory (NativeFinalizer)
  // Bind SoLoud_destroySound address to NativeFinalizer
  late final NativeFinalizer _soundFinalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(Pointer<Void>)>>(
      SoLoud_destroySound,
    ),
  );

  @override
  Future<void> init() async {
    if (_inited) return;

    // Hardware Release (ProcessSignal)
    try {
      ProcessSignal.sigint.watch().listen((_) {
        disposeEngine();
        exit(0);
      });
    } catch (_) {}

    final res = initEngine(-1, 44100, 2048, 2, 1);
    if (res != 0) {
      throw Exception(
        'Failed to initialize SoLoud CLI Engine. Error code: $res',
      );
    }
    _inited = true;
  }

  @override
  Future<SoundHandle> loadSound(String path) async {
    if (!_inited) throw Exception('Engine not initialized.');

    final file = File(path);
    if (!file.existsSync()) {
      throw FileSystemException('Sound file not found', path);
    }
    final bytes = file.readAsBytesSync();

    final namePtr = path.toNativeUtf8().cast<Char>();
    final bufferPtr = calloc<Uint8>(bytes.length);
    bufferPtr.asTypedList(bytes.length).setAll(0, bytes);
    final hashPtr = calloc<Uint32>();

    try {
      final res = loadMem(namePtr, bufferPtr, bytes.length, 1, hashPtr);
      if (res != 0) {
        throw Exception('Failed to load sound into memory. Error code: $res');
      }
      final hash = hashPtr.value;
      final handle = SoundHandle(hash);
      _loadedHashes[handle] = hash;

      // Attach finalizer to the SoundHandle to auto-dispose memory
      // We pass the hash as an address pointer using Pointer.fromAddress(hash)
      _soundFinalizer.attach(handle, Pointer.fromAddress(hash), detach: handle);

      return handle;
    } finally {
      calloc.free(namePtr);
      calloc.free(bufferPtr);
      calloc.free(hashPtr);
    }
  }

  @override
  Future<void> playSound(SoundHandle handle, {bool loop = false}) async {
    if (!_inited) throw Exception('Engine not initialized.');

    final hash = _loadedHashes[handle];
    if (hash == null) return;

    final voicePtr = calloc<Uint32>();
    try {
      final res = play(hash, 0, 1.0, 0.0, false, loop, 0.0, voicePtr);
      if (res != 0) {
        throw Exception('Failed to play sound. Error code: $res');
      }
      final voice = voicePtr.value;
      _playingVoices.putIfAbsent(handle, () => []).add(voice);
      if (loop) {
        _bgmVoice = voice;
      }
    } finally {
      calloc.free(voicePtr);
    }
  }

  @override
  Future<void> stopSound(SoundHandle handle) async {
    if (!_inited) return;

    final voices = _playingVoices[handle];
    if (voices != null) {
      for (final voice in voices) {
        stop(voice);
      }
      voices.clear();
    }
  }

  @override
  Future<void> setBgmVolume(double volume) async {
    if (!_inited) return;
    if (_bgmVoice != null) {
      setVolume(_bgmVoice!, volume);
    }
  }

  @override
  Future<void> dispose() async {
    if (!_inited) return;

    // Detach finalizer from all loaded handles as we are explicitly disposing
    for (final handle in _loadedHashes.keys) {
      _soundFinalizer.detach(handle);
      disposeSound(_loadedHashes[handle]!);
    }

    disposeEngine();
    _loadedHashes.clear();
    _playingVoices.clear();
    _bgmVoice = null;
    _inited = false;
  }
}
