import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'audio_service.dart';
import 'soloud_cli.dart' as ffi;
import 'soloud_cli.dart' show SoLoud_destroySound;

/// A Finalizable version of SoundHandle used by the CLI engine.
class FinalizableSoundHandle extends SoundHandle implements Finalizable {
  /// Creates a [FinalizableSoundHandle] wrapping the given ID.
  const FinalizableSoundHandle(super.id);
}

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
        ffi.disposeEngine();
        exit(0);
      });
    } catch (_) {}

    final res = ffi.initEngine(-1, 48000, 2048, 2, 0);
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
      final res = ffi.loadMem(namePtr, bufferPtr, bytes.length, 1, hashPtr);
      if (res != 0) {
        throw Exception('Failed to load sound into memory. Error code: $res');
      }
      final hash = hashPtr.value;
      final handle = FinalizableSoundHandle(hash);
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
      final res = ffi.play(hash, 0, 1.0, 0.0, false, loop, 0.0, voicePtr);
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
        ffi.stop(voice);
      }
      voices.clear();
    }
  }

  @override
  Future<void> setBgmVolume(double volume) async {
    if (!_inited) return;
    if (_bgmVoice != null) {
      ffi.setVolume(_bgmVoice!, volume);
    }
  }

  @override
  Future<void> setRelativePlaySpeed(SoundHandle handle, double speed) async {
    if (!_inited) return;
    final hash = handle.id as int;
    final voices = _playingVoices[hash];
    if (voices != null) {
      for (final voice in voices) {
        ffi.setRelativePlaySpeed(voice, speed);
      }
    }
  }

  @override
  Future<void> fadeRelativePlaySpeed(
    SoundHandle handle,
    double speed,
    Duration duration,
  ) async {
    if (!_inited) return;
    final hash = handle.id as int;
    final voices = _playingVoices[hash];
    if (voices != null) {
      for (final voice in voices) {
        ffi.fadeRelativePlaySpeed(
          voice,
          speed,
          duration.inMicroseconds / 1000000.0,
        );
      }
    }
  }

  @override
  Future<void> fadeVolume(
    SoundHandle handle,
    double targetVolume,
    Duration duration,
  ) async {
    if (!_inited) return;
    final hash = handle.id as int;
    final voices = _playingVoices[hash];
    if (voices != null) {
      for (final voice in voices) {
        ffi.fadeVolume(
          voice,
          targetVolume,
          duration.inMicroseconds / 1000000.0,
        );
      }
    }
  }

  @override
  Future<void> fadeBgmVolume(double targetVolume, Duration duration) async {
    if (!_inited) return;
    if (_bgmVoice != null) {
      ffi.fadeVolume(
        _bgmVoice!,
        targetVolume,
        duration.inMicroseconds / 1000000.0,
      );
    }
  }

  @override
  Future<void> playSpriteSequence(
    SoundHandle handle,
    List<SpriteSegment> segments,
  ) async {
    if (!_inited || segments.isEmpty) return;
    final hash = handle.id as int;

    var totalDelay = Duration.zero;
    for (final seg in segments) {
      final segDelay = totalDelay;
      totalDelay += seg.duration;

      if (segDelay == Duration.zero) {
        final voicePtr = calloc<Uint32>();
        try {
          final startSec = seg.start.inMicroseconds / 1000000.0;
          final res = ffi.play(
            hash,
            0,
            1.0,
            0.0,
            false,
            false,
            startSec,
            voicePtr,
          );
          if (res == 0) {
            final voice = voicePtr.value;
            final durationSec = seg.duration.inMicroseconds / 1000000.0;
            ffi.fadeVolume(voice, 0.0, durationSec);
          }
        } finally {
          calloc.free(voicePtr);
        }
      } else {
        unawaited(
          Future.delayed(segDelay, () {
            if (!_inited) return;
            final voicePtr = calloc<Uint32>();
            try {
              final startSec = seg.start.inMicroseconds / 1000000.0;
              final res = ffi.play(
                hash,
                0,
                1.0,
                0.0,
                false,
                false,
                startSec,
                voicePtr,
              );
              if (res == 0) {
                final voice = voicePtr.value;
                final durationSec = seg.duration.inMicroseconds / 1000000.0;
                ffi.fadeVolume(voice, 0.0, durationSec);
              }
            } finally {
              calloc.free(voicePtr);
            }
          }),
        );
      }
    }
  }

  @override
  Float32List getWaveform() {
    if (!_inited) return Float32List(256);
    final wavePtr = ffi.getWave();
    if (wavePtr == nullptr) return Float32List(256);
    final list = Float32List(256);
    final nativeList = wavePtr.asTypedList(256);
    list.setAll(0, nativeList);
    return list;
  }

  @override
  Uint8List renderWavGolden({
    required Duration duration,
    int sampleRate = 44100,
  }) {
    if (!_inited) return Uint8List(0);
    final numSamples = (sampleRate * (duration.inMicroseconds / 1000000.0))
        .round();
    final pcmPtr = calloc<Int16>(numSamples);

    try {
      ffi.mixSigned16(pcmPtr, numSamples);
      final pcmBytes = pcmPtr.cast<Uint8>().asTypedList(numSamples * 2);

      final dataSize = numSamples * 2;
      final fileSize = 36 + dataSize;
      final header = ByteData(44);

      // RIFF header
      header.setUint8(0, 0x52); // R
      header.setUint8(1, 0x49); // I
      header.setUint8(2, 0x46); // F
      header.setUint8(3, 0x46); // F
      header.setUint32(4, fileSize, Endian.little);
      header.setUint8(8, 0x57); // W
      header.setUint8(9, 0x41); // A
      header.setUint8(10, 0x56); // V
      header.setUint8(11, 0x45); // E
      // fmt subchunk
      header.setUint8(12, 0x66); // f
      header.setUint8(13, 0x6d); // m
      header.setUint8(14, 0x74); // t
      header.setUint8(15, 0x20); // ' '
      header.setUint32(16, 16, Endian.little);
      header.setUint16(20, 1, Endian.little);
      header.setUint16(22, 1, Endian.little);
      header.setUint32(24, sampleRate, Endian.little);
      header.setUint32(28, sampleRate * 2, Endian.little);
      header.setUint16(32, 2, Endian.little);
      header.setUint16(34, 16, Endian.little);
      // data subchunk
      header.setUint8(36, 0x64); // d
      header.setUint8(37, 0x61); // a
      header.setUint8(38, 0x74); // t
      header.setUint8(39, 0x61); // a
      header.setUint32(40, dataSize, Endian.little);

      final result = Uint8List(44 + dataSize);
      result.setAll(0, header.buffer.asUint8List());
      result.setAll(44, pcmBytes);
      return result;
    } finally {
      calloc.free(pcmPtr);
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
      ffi.disposeSound(entry.key);
    }

    ffi.disposeEngine();
    _loadedHandles.clear();
    _playingVoices.clear();
    _bgmVoice = null;
    _inited = false;
  }
}
