# termui_audio_flutter

Flutter and Web SoLoud backend for `termui_audio`.

## Usage

Register the Flutter audio backend before initializing `TermuiAudio`:

```dart
import 'package:flutter/widgets.dart';
import 'package:termui_audio_flutter/termui_audio_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  TermuiAudioFlutter.register();
  await TermuiAudio.init();
}
```
