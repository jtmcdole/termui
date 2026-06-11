# termui_recorder

Testing and recording utilities for the [termui](https://pub.dev/termui) package. This package supports capturing ANSI screenshots, recording and playing back terminal sessions using the Asciinema Asciicast v2 format, and validating terminal layouts with golden tests.

For Flutter integration, see [termui_flutter](https://pub.dev/termui_flutter).

---

## Features

- **Asciicast v2 Recording & Playback**: Record screen frame deltas into standard `.cast` files and play them back interactively.
- **ANSI Screenshots**: Capture terminal `Buffer` states as a styled ANSI string representation.
- **Golden Testing**: Verify terminal layouts via golden files with automatic golden generation support.

---

## Key APIs & Classes

- **`AsciicastRecorder`**: Captures terminal frame states and serializes them to the Asciinema Asciicast v2 format.
- **`AsciicastPlayer`**: Plays back recorded asciicast files with speed multipliers and interactive overlay support.
- **`AnsiScreenshot`**: Converts a `Buffer` into a styled ANSI string representation.
- **`matchesAnsiGolden`**: A test matcher to assert if a layout's `Buffer` matches a saved ANSI golden file.

---

## Code Examples

### Recording with `AsciicastRecorder`

Here is how you can record frames of your layout or application:

```dart
import 'dart:io';
import 'package:termui/termui.dart';
import 'package:termui_recorder/termui_recorder.dart';

void main() async {
  final file = File('session.cast');
  final sink = file.openWrite();

  // Create the recorder with specified terminal dimensions
  final recorder = AsciicastRecorder(sink, width: 80, height: 24);

  // Initialize a terminal buffer
  final buffer = Buffer.blank(80, 24);

  // Write some content
  buffer.writeString(0, 0, 'Welcome to termui', Style.empty);
  recorder.recordFrame(buffer);

  // Write updated content
  buffer.writeString(0, 1, 'Recording in progress...', Style.empty);
  recorder.recordFrame(buffer);

  await sink.close();
}
```

### Golden Testing with `matchesAnsiGolden`

You can use the `matchesAnsiGolden` matcher in your unit tests to assert that a `Buffer` matches a reference ANSI file.

```dart
import 'package:test/test.dart';
import 'package:termui/termui.dart';
import 'package:termui_recorder/termui_recorder.dart';

void main() {
  test('renders text correctly', () {
    final buffer = Buffer.blank(20, 3);
    
    // Using modern Dart collection structures to configure styles
    final showBold = true;
    final showUnderline = false;
    final style = Style(
      foreground: Colors.yellow,
      modifiers: [
        if (showBold) Modifier.bold,
        if (showUnderline) Modifier.underline,
      ].fold(Modifier.none, (prev, element) => prev | element),
    );

    buffer.writeString(0, 0, 'Hello World', style);

    expect(buffer, matchesAnsiGolden('test/goldens/hello_world.ansi'));
  });
}
```

To automatically generate or update the golden files, set the `GENERATE_GOLDENS` environment variable to `true` when running tests.

On Windows:
```cmd
set GENERATE_GOLDENS=true; dart test
```

On macOS/Linux:
```bash
GENERATE_GOLDENS=true dart test
```

---

## CLI Player Usage

You can play back recorded Asciinema sessions (`.cast` files) directly in your terminal using the player utility.

```bash
dart run termui_recorder:termui_play [options] <input.cast>
```

### Options

- `-s, --speed` : Playback speed multiplier (e.g., `2.0` for double speed, `0.5` for half speed). Defaults to `1.0`.
- `-n, --non-interactive` : Disable interactive controls and status bar overlays. Defaults to `false`.
- `-h, --help` : Show usage instructions.

### Interactive Controls (Default)

During playback, you can use the following keyboard controls:
- `Space`: Pause / resume playback.
- `+` or `=`: Speed up playback (x1.25).
- `-` or `_`: Slow down playback (x0.8).
- `q` or `Escape`: Quit playback.
