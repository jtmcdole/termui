# termui_audio

A multiplatform, low-latency game audio engine designed for the `termui` terminal windowing system. 

`termui_audio` brings high-performance, spatial 3D audio, background music streaming, and sound effect mixing to standard TTY console environments, while seamlessly degrading or delegating to Flutter/Web engines when `termui` is embedded in a GUI or browser.

## Features

* **Multiplatform Factory:** Uses a factory pattern (`createAudioEngine()`) to automatically resolve the best audio backend for the current platform (Dart VM/CLI, Flutter Desktop/Mobile, or Web).
* **High-Performance CLI Audio:** Directly integrates with [SoLoud](https://soloud-audio.com/) via `dart:ffi` to deliver zero-latency C++ audio mixing in headless/CLI Dart applications.
* **Web Audio Support:** Offloads asset loading and caching to a dedicated Web Worker (using `idb_shim` for IndexedDB) to prevent main-thread blocking, driving audio via WASM.
* **3D Spatial Audio:** Fully supports positioning sound sources in 3D space (`x`, `y`, `z`) with velocity vectors for Doppler effects.
* **Waveform Synthesis:** Procedurally generate sine, square, sawtooth, and bounce waves without external assets.
* **Buses & Grouping:** Group audio voices for global volume ducking or effects (e.g., separating BGM from SFX).

## Architecture

`termui_audio` isolates the rendering environment from the audio mixing engine, ensuring terminal UI event loops are never blocked by synchronous audio decoding:

* **`TermuiAudioEngine`:** The core abstract API contract.
* **`CliAudioEngine`:** Uses `dart:ffi` and Native Assets to link against `libsoloud`.
* **`FlutterAudioEngine`:** Wraps the excellent `flutter_soloud` package.
* **`WebAudioService`:** Coordinates an asynchronous JS Interop Web Worker for asset fetching.

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

// Update its position and velocity dynamically
audioEngine.set3dSourceParameters(
  voice, 
  x: 2.0, y: 0.0, z: -1.0, 
  vx: -5.0 // Velocity on the X axis (Doppler)
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
* Run `dart run example/bin/main.dart` to experience the CLI audio backend with a 3D spatial grid UI.
