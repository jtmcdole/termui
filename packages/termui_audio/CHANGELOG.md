## 0.7.0

> Note: This release has breaking changes.

 - **BREAKING** **FIX**(audio,audio_flutter,pty): harden stream PCM capacity, transport fades, pitch buses, and wave gate.
 - **BREAKING** **FEAT**(termui,audio,audio_flutter,pty): add APC Float32 waveform queries and watchWaveform.
 - **BREAKING** **FEAT**(audio,pty): add pass-through APC buffer streaming and caster-host loadUrl.
 - **BREAKING** **FEAT**(audio,audio_flutter,pty): add APC mixing buses, 12 DSP filters, and annexed pitch shift.
 - **BREAKING** **FEAT**(audio,pty): add MP3 duration parser, transport/fade APC updates, and Doppler.
 - **BREAKING** **FEAT**(audio,pty): add live APC a=update 3D spatial pan, attenuation, and gain.

## 0.6.0

> Note: This release has breaking changes.

 - **BREAKING** **FIX**(termui_audio): parse Ogg Vorbis/Opus durations, track Clock playhead, and emit stop on zero-duration eviction.
 - **BREAKING** **FEAT**(termui_audio): route CLI createAudioEngine via TERMUI_AUDIO_APC, add loadFile, and parse WAV duration.

## 0.5.0

> Note: This release has breaking changes.

 - **DOCS**(termui_audio): fix 3D positional parameters, engine factory docs, and example README.
 - **BREAKING** **FIX**(termui_flutter,examples): drop deprecated flutter/material.dart for Flutter 3.50.
 - **BREAKING** **FEAT**(termui_audio,termui_audio_flutter): fix dart.library.io guard, add setVoicePan, and add ApcAudioEncoder.

## 0.4.0

> Note: This release has breaking changes.

 - **BREAKING** **FEAT**(audio): split pure-Dart termui_audio and termui_audio_flutter package.

## 0.3.0

> Note: This release has breaking changes.

 - **BREAKING** **REFACTOR**: replace `dynamic` and raw types across workspace packages.

## 0.2.1

 - Update a dependency to the latest release.

## 0.2.0

> Note: This release has breaking changes.

 - **BREAKING** **FIX**(termui_audio): fix stream format, FFI pointer leaks, and C++ player bugs.

## 0.1.13

 - **FIX**(testing): eliminate naked waits and migrate time sources to package:clock.

## 0.1.12

 - **FIX**(audio): dynamically attach PitchShiftFilter to active voices and bypass at 1.0x.
 - **FIX**(audio): route Opus streams to BufferStream and optimize format sniffing.
 - **FIX**(audio): forward paused parameter in CliAudioEngine.play.
 - **FEAT**(audio): add chunk & buffer streaming, pitch-preserved speed, and playhead streams.

## 0.1.11

 - Update a dependency to the latest release.

## 0.1.10

 - **FIX**(buffer): support wide BMP emojis and variation selectors.

## 0.1.9

 - **REFACTOR**: modernize codebase to Dart 3.x language idioms across monorepo.

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

