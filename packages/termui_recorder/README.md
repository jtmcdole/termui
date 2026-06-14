# termui_recorder

Testing and recording utilities for the [termui](https://pub.dev/termui) package. This package supports capturing ANSI screenshots, recording and playing back terminal sessions using the Asciinema Asciicast v2 format, and validating terminal layouts with golden tests.

For Flutter integration, see [termui_flutter](https://pub.dev/termui_flutter).

---

## Features

- **Asciicast v2 Recording & Playback**: Record screen frame deltas into standard `.cast` files and play them back interactively.
- **Raw String Ingestion**: Ingest raw Asciicast string data directly, making it ready for web and browser playback environments.
- **Time-Travel Debugger**: Interactively play, pause, and step through recorded sessions frame-by-frame.
- **Metadata Overlay**: View custom debug events in a dedicated border box above the status line.
- **ANSI Screenshots**: Capture terminal `Buffer` states as a styled ANSI string representation.
- **Golden Testing**: Verify terminal layouts via golden files with automatic golden generation support.

---

## Key APIs & Classes

- **`AsciicastRecorder`**: Captures terminal frame states and serializes them to the Asciinema Asciicast v2 format.
- **`AsciicastPlayer`**: Plays back recorded asciicast sessions. Supports raw string data ingestion (web/browser ready), speed multipliers, interactive play/pause, time-travel frame stepping, and custom debug metadata overlays.
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

### Playing Back with `AsciicastPlayer`

Here is how you can play back a session programmatically using raw string data (perfect for web/browser use):

```dart
import 'package:termui_recorder/termui_recorder.dart';

void main() async {
  // Raw JSONL asciicast string data
  final String asciicastData = '''
{"version": 2, "width": 80, "height": 24}
[0.1, "o", "Hello world!"]
[0.5, "d", "Actions: Key: enter"]
[0.5, "o", "\\n"]
''';

  final player = AsciicastPlayer(asciicastData);

  // Play back interactively
  await player.play(
    speedMultiplier: 1.5,
    interactive: true,
    paused: true,        // Start playback paused
    noCloseAtEnd: true,  // Stay in player on completion (holds alternate screen)
  );
}
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
- `-p, --paused` : Start playback in a paused state. Defaults to `false`.
- `-k, --keep-alive` : Do not close the player when playback reaches the end (holds player in alternate screen; maps to the `noCloseAtEnd` configuration parameter). Defaults to `false`.
- `-h, --help` : Show usage instructions.

### Interactive Controls (Default)

During playback, you can use the following keyboard controls:
- `Space`: Pause / resume playback.
- `,` (Comma): Step backward one frame (replay state; only works if paused).
- `.` (Period): Step forward one frame (only works if paused).
- `+` or `=`: Speed up playback (x1.25).
- `-` or `_`: Slow down playback (x0.8).
- `q` or `Escape`: Quit playback.

### Debug Metadata Overlay

When interactive mode is active and the asciicast file contains custom debug events (type `'d'`), the player renders a dedicated Unicode Metadata border box immediately above the status line. This box displays custom debug info (such as test action logs) dynamically at the exact point in the playback timeline that they occurred.
