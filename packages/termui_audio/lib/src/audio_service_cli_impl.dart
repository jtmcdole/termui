import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'audio_service.dart';
import 'soloud_cli.dart';

/// The pure Dart CLI backend that directly interfaces with the compiled C++
/// SoLoud library using FFI and Native Assets.
class CliAudioService implements AudioService {
  final Map<int, WeakReference<SoundHandle>> _loadedHandles = {};
  final Map<int, List<int>> _playingVoices = {};
  int? _bgmVoice;
  bool _inited = false;
  StreamSubscription<ProcessSignal>? _sigintSub;

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
      _sigintSub = ProcessSignal.sigint.watch().listen((_) {
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
    if (!await file.exists()) {
      throw FileSystemException('Sound file not found', path);
    }
    final bytes = await file.readAsBytes();

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
      _loadedHandles[hash] = WeakReference(handle);

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

    final hash = handle.id as int;
    final voicePtr = calloc<Uint32>();
    try {
      final res = play(hash, 0, 1.0, 0.0, false, loop, 0.0, voicePtr);
      if (res != 0) {
        throw Exception('Failed to play sound. Error code: $res');
      }
      final voice = voicePtr.value;
      _playingVoices.putIfAbsent(hash, () => []).add(voice);
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

    final hash = handle.id as int;
    final voices = _playingVoices[hash];
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

    await _sigintSub?.cancel();
    _sigintSub = null;

    // Detach finalizer from all loaded handles as we are explicitly disposing
    for (final entry in _loadedHandles.entries) {
      final handle = entry.value.target;
      if (handle != null) {
        _soundFinalizer.detach(handle);
      }
      disposeSound(entry.key);
    }

    disposeEngine();
    _loadedHandles.clear();
    _playingVoices.clear();
    _bgmVoice = null;
    _inited = false;
  }
}
