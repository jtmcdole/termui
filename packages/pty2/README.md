# pty2

A modern, high-performance Pseudo-Terminal (PTY) package for Dart and Flutter. 

`pty2` provides programmatic access to native OS terminal file descriptors, allowing you to spawn and interact with command-line applications (like `bash`, `pwsh`, `vim`, or `htop`) directly from Dart. It serves as the native backend for building terminal emulators and CLI wrappers.

## Features
- **Cross-Platform**: Full support for Windows (via ConPTY/legacy pipes) and Unix (Linux/macOS via `forkpty`).
- **Non-Blocking Architecture**: Uses FFI across background Isolates to prevent synchronous OS reads from blocking the Dart event loop.
- **Robust UTF-8 Decoding**: Correctly buffers and stitches split multi-byte characters (e.g. emojis) that cross chunk boundaries.
- **Memory Management**: Strict `Arena` scoping and `NativeFinalizer` cleanup reduces FFI memory leaks and ensures handles are deterministically closed.

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  pty2: ^0.5.0
```

## Usage

Below is a simple example demonstrating how to spawn a shell, write to its stdin, and read from its stdout.

```dart
import 'dart:io';
import 'package:pty2/pty2.dart';

void main() async {
  // 1. Spawn a Pseudo-Terminal
  final pty = PseudoTerminal.start(
    Platform.isWindows ? 'pwsh.exe' : 'bash',
    [], // Arguments
    environment: {'MY_VAR': 'Hello World'},
    raw: true, // Use raw mode on Unix to disable kernel echoing/buffering
  );

  // 2. Resize the terminal window buffer
  pty.resize(120, 40); // width: 120 cols, height: 40 rows

  // 3. Listen to the output stream
  pty.out.listen((data) {
    stdout.write(data);
  });

  // 4. Write commands to stdin
  if (Platform.isWindows) {
    pty.write('echo \$env:MY_VAR\r\n');
  } else {
    pty.write('echo \$MY_VAR\n');
  }

  // 5. Cleanup
  await Future.delayed(const Duration(seconds: 1));
  pty.kill();

  // 6. Wait for the exit code
  final exitCode = await pty.exitCode;
  print('Process exited with code: $exitCode');
}
```

## Architecture

To achieve high rendering throughput for Flutter TUI/GUI applications, `pty2` completely decouples the blocking native I/O layer from the main isolate. It spawns a background isolate that executes blocking `ReadFile`/`read` calls against the native pipe. Raw `Uint8List` byte chunks are then fed into a stateful `Utf8Decoder` which buffers split grapheme clusters before sending valid `String` messages back to the main isolate via `SendPort`.

For detailed architecture diagrams, sequence flows, and memory lifecycle documentation, see [doc/architecture.md](doc/architecture.md).
