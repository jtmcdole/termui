# termui_audio_flutter

Flutter Desktop, Mobile, and Web SoLoud backend for `termui_audio`.

## Usage

Instantiate and initialize `FlutterAudioEngine` and pass it to your `termui` application or audio controller:

```dart
import 'package:flutter/widgets.dart';
import 'package:termui_audio_flutter/termui_audio_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final audioEngine = FlutterAudioEngine();
  await audioEngine.init();

  final buffer = await audioEngine.loadFile('assets/sfx/click.wav');
  audioEngine.play(buffer);
}
```
