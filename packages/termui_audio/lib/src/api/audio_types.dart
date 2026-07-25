/// A handle for a playing sound.
class AudioVoice {
  /// The unique native identifier for this voice.
  final int id;

  /// A future that completes when the voice finishes playing.
  final Future<void> completed;

  /// Creates a new voice handle.
  const AudioVoice(this.id, this.completed);
}

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

/// The 3D audio distance attenuation model.
enum AttenuationModel {
  /// No attenuation based on distance.
  none,

  /// Inverse distance attenuation model.
  inverseDistance,

  /// Linear distance attenuation model.
  linearDistance,

  /// Exponential distance attenuation model.
  exponentialDistance,
}

/// Supported DSP filter types matching native C++ SoLoud indices.
enum FilterType {
  /// Biquad resonant filter (Lowpass, Highpass, Bandpass, Lowshelf, Highshelf, Peaking) (index 0).
  biquadResonant,

  /// Echo / delay feedback filter (index 1).
  echo,

  /// Lofi bit-crusher / sample rate reducer filter (index 2).
  lofi,

  /// Flanger filter (index 3).
  flanger,

  /// Bassboost filter (index 4).
  bassboost,

  /// WaveShaper distortion filter (index 5).
  waveShaper,

  /// Robotize formant filter (index 6).
  robotize,

  /// Freeverb acoustic reverb filter (index 7).
  freeverb,

  /// Pitch shift filter (index 8).
  pitchShift,

  /// Limiter filter (index 9).
  limiter,

  /// Compressor filter (index 10).
  compressor,

  /// Parametric EQ filter (index 11).
  parametricEq,
}
