/// Zero-cost handle for a playing sound.
extension type AudioVoice(int id) {}

/// Represents a loaded sound source.
abstract class AudioBuffer {
  /// Unique hash identifier for this buffer.
  int get hash;
}

/// Represents a mixing bus.
abstract class AudioBus {
  /// Unique identifier for this bus.
  int get id;

  /// Sets the volume for this bus.
  void setVolume(double volume);
}

/// The types of waveforms supported by the synthesizer.
enum WaveForm {
  /// A square wave.
  square,

  /// A sawtooth wave.
  saw,

  /// A sine wave.
  sin,

  /// A triangle wave.
  triangle,

  /// A bouncing wave.
  bounce,

  /// A jaws wave.
  jaws,

  /// A humps wave.
  humps,

  /// A fast square wave.
  fsquare,

  /// A fast sawtooth wave.
  fsaw,
}

/// A callback used to report progress when loading an audio file.
///
/// Progress is a value between 0.0 and 1.0.
typedef LoadProgressCallback = void Function(double progress);
