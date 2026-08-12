## 0.1.8

 - Update a dependency to the latest release.

## 0.1.7

 - **PERF**(core): optimize render loops and defer layout clipping.
 - **FIX**(termui_audio): prevent native crash on invalid voice/bus handles.

## 0.1.6

 - **PERF**(core): optimize render loops and defer layout clipping.
 - **FIX**(termui_audio): prevent native crash on invalid voice/bus handles.

## 0.1.5

 - **REFACTOR**(audio): modernize control flow and implement setPaused.
 - **REFACTOR**(audio): modernize TermuiAudioEngine API and purge dead code.
 - **REFACTOR**(termui): optimize dsp loop, clean pattern match, and guard terminal focus.
 - **FIX**(audio): address memory boundaries and FFI allocator mismatch.
 - **FEAT**(audio): expose playSpriteSequence, waveform tapping, and golden WAV mixing.
 - **FEAT**(audio): implement in-memory WAV waveform generator for loadWaveform on CLI.
 - **FEAT**(audio): expose SoLoud pitch shifting, volume fading, DSP filter pipelines, audio sprite splicing, and bus management APIs.

## 0.1.4

 - Update a dependency to the latest release.

## 0.1.3

 - Update a dependency to the latest release.

## 0.1.2

 - Update a dependency to the latest release.

## 0.1.1

 - **REFACTOR**(core): optimize render loops and decouple audio state.
 - **REFACTOR**(audio): apply codefu-persona recommendations for performance and correctness.
 - **FIX**: macos / linux missing libraries.
 - **FIX**(audio_example): resolve loading hang during intrinsic measurements via MVVM refactor.
 - **FEAT**(termui_audio): add 3D distance attenuation API.
 - **FEAT**(termui): add focus properties to InkwellButton and event-driven audio APIs.
 - **FEAT**: 3d audio and mixer volume sliders.
 - **FEAT**(audio): implement engine-agnostic TermuiAudio API with 3D spatial FFI.
 - **FEAT**(audio): enable full Ogg, Vorbis, FLAC, and Opus support on Windows CLI.
 - **FEAT**(example): add interactive audio player example and update playlist mapping.
 - **FEAT**(audio): add termui_audio package for multiplatform audio playback.

