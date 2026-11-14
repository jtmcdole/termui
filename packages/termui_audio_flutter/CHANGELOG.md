## 0.4.0

> Note: This release has breaking changes.

 - **BREAKING** **FIX**(audio,audio_flutter,pty): harden stream PCM capacity, transport fades, pitch buses, and wave gate.
 - **BREAKING** **FEAT**(termui,audio,audio_flutter,pty): add APC Float32 waveform queries and watchWaveform.
 - **BREAKING** **FEAT**(audio,audio_flutter,pty): add APC mixing buses, 12 DSP filters, and annexed pitch shift.

## 0.3.1

 - Update a dependency to the latest release.

## 0.3.0

> Note: This release has breaking changes.

 - **DOCS**(termui_audio_flutter): replace non-existent TermuiAudioFlutter snippet with FlutterAudioEngine.
 - **BREAKING** **FIX**(termui_flutter,examples): drop deprecated flutter/material.dart for Flutter 3.50.
 - **BREAKING** **FEAT**(termui_audio,termui_audio_flutter): fix dart.library.io guard, add setVoicePan, and add ApcAudioEncoder.

## 0.2.0

> Note: This release has breaking changes.

 - **BREAKING** **FEAT**(audio): split pure-Dart termui_audio and termui_audio_flutter package.

## 0.1.0

 - Initial extraction of the Flutter and Web SoLoud backend from `termui_audio`.
