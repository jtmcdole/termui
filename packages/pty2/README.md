# pty2

A modern, high-performance Pseudo-Terminal (PTY) package for Dart and Flutter.

`pty2` gives Dart apps direct access to native OS pseudo-terminals. You can spawn and control shells or CLI tools like `bash`, `pwsh`, `vim`, or `htop`. It provides the native backend for terminal emulators and CLI wrappers.

## Features
- Cross-platform support for Windows (ConPTY and legacy pipes) and Unix (Linux and macOS via `openpty` and a native reaper shim).
- Non-blocking isolate architecture that offloads both PTY reads and PTY writes to background isolates so blocking OS pipes never stall the Dart event loop.
- Stateful UTF-8 decoding that buffers split multi-byte characters (such as emojis) across chunk boundaries.
- Deterministic native resource cleanup using `Arena` scoping, exclusive writer ownership transfer, and `NativeFinalizer` guards.

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  pty2: ^0.8.0
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

To keep Flutter and CLI event loops responsive, `pty2` moves blocking native I/O off the caller isolate into three background isolates:

- A reader isolate (`_readUntilExit`) runs blocking reads against the PTY output handle. It decodes split UTF-8 sequences with a stateful `Utf8Decoder` and sends strings over a `SendPort`.
- A writer isolate (`_writeUntilClosed`) owns the PTY input write handle and drains queued `write()` payloads in FIFO order. This prevents bidirectional pipe deadlocks when `ackProcessed: true` pauses reads while the caller writes terminal replies.
- An exit-waiter isolate (`_waitForExitCode`) waits for child process termination and resolves `exitCode`.

For architecture diagrams, sequence flows, and handle lifecycle details, see [doc/architecture.md](doc/architecture.md).
