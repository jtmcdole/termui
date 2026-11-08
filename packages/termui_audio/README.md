# termui_audio

A multiplatform, low-latency game audio engine designed for the `termui` terminal windowing system.

`termui_audio` brings high-performance, spatial 3D audio, background music streaming, and sound effect mixing to standard TTY console environments, while seamlessly degrading or delegating to Flutter/Web engines when `termui` is embedded in a GUI or browser.

## Features

* **CLI Factory:** Provides `createAudioEngine()` to construct the native `CliAudioEngine` on Dart VM/CLI platforms (via `dart:ffi`), alongside `FlutterAudioEngine` in `termui_audio_flutter` for Flutter Desktop, Mobile, and Web.
* **High-Performance CLI Audio:** Directly integrates with [SoLoud](https://soloud-audio.com/) via `dart:ffi` and Native Assets to deliver low-latency C++ audio mixing in headless and CLI Dart applications.
* **Flutter & Web Audio Support:** Companion package `termui_audio_flutter` wraps `flutter_soloud` for Flutter Desktop, Mobile, and Web targets.
* **3D Spatial Audio:** Supports positioning sound sources in 3D space (`x`, `y`, `z`) with velocity vectors for Doppler effects and distance attenuation models.
* **Waveform Synthesis & Visualization:** Procedurally generate sine, square, sawtooth, and triangle/bounce waves without external assets, and query real-time PCM output frames (`getWaveform`).
* **Buses, DSP Filters & Audio Sprites:** Group audio voices into buses (`AudioBus`), attach DSP filters (`FilterType.biquadResonant`, `echo`, `freeverb`, `bassboost`, `flanger`), play sub-segment sprites (`playSprite`, `playSpriteSequence`), stream PCM buffers (`createBufferStream`), and adjust playback speed with pitch preservation (`setRelativePlaySpeed(..., preservePitch: true)`).

## Architecture

`termui_audio` isolates the rendering environment from the audio mixing engine so terminal UI event loops are not blocked by synchronous audio decoding:

* **`TermuiAudioEngine`:** The core abstract API contract.
* **`CliAudioEngine`:** Uses `dart:ffi` and Native Assets to link against `libsoloud` (returned by `createAudioEngine()` on Dart VM/CLI).
* **`termui_audio_flutter`:** Companion package providing `FlutterAudioEngine` (`package:termui_audio_flutter/termui_audio_flutter.dart`) wrapping `flutter_soloud` for Flutter Desktop, Mobile, and Web.

## Usage

### 1. Initialization

Create and initialize the audio engine before running your TUI application:

```dart
import 'package:termui_audio/termui_audio.dart';

void main() async {
  // Automatically detects the platform and creates the appropriate backend
  final audioEngine = createAudioEngine();
  await audioEngine.init();

  // Load a sound effect
  final jumpSound = await audioEngine.loadFile('assets/sfx/jump.ogg');

  // Play it!
  audioEngine.play(jumpSound);

  // Clean up when done
  await audioEngine.dispose();
}
```

### 2. 3D Spatial Audio

`termui_audio` supports positioning audio voices in physical space. This is highly effective when combined with `termui`'s grid rendering to provide directional audio cues in console games.

```dart
// Start a sound in 3D space (x, y, z)
final engineLoop = await audioEngine.loadFile('assets/engine.ogg');
final voice = audioEngine.play3d(engineLoop, 5.0, 0.0, 0.0);

// Configure distance attenuation (volume falloff)
audioEngine.set3dSourceMinMaxDistance(voice, 2.0, 20.0);
audioEngine.set3dSourceAttenuation(voice, AttenuationModel.linearDistance, 1.0);

// Update its position (x, y, z) and velocity dynamically
audioEngine.set3dSourceParameters(
  voice,
  2.0,
  0.0,
  -1.0,
  vx: -5.0, // Velocity on the X axis (Doppler)
);
```

### 3. Integrating with `termui` Widgets

When building interactive UI elements (like an `InkwellButton`), decouple high-frequency state updates from root `build()` methods to prevent TTY flickering.

```dart
// Example: A background music volume slider
SizedBox(
  width: 20,
  height: 1,
  child: Slider(
    value: currentVolume,
    min: 0.0,
    max: 1.0,
    onChanged: (vol) {
      audioEngine.setVoiceVolume(bgmVoice, vol);
    },
  ),
);
```

> [!CAUTION]
> **Performance Rule:** Never bind high-frequency data streams (like playhead position) directly to `setState()` at the root of a complex widget tree. Isolate progress sliders into their own leaf `StatefulWidget` or use granular listeners to maintain 60 FPS terminal rendering.

## Examples

Check out the interactive example located in `example/`:
* From `packages/termui_audio/example`, run `dart run bin/main.dart` for the CLI TUI audio player or `flutter run` for the Flutter GUI/Web target.
