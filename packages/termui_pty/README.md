# termui_pty

A high-performance virtual terminal emulator and PTY embedding widget for the `termui` ecosystem.

`termui_pty` provides a strict, MVVM-compliant terminal emulator that processes raw ANSI/VT100 byte streams into a visible buffer. It is designed to handle high-throughput command-line output (like `htop`, `btop`, or aggressive `cat` commands) without thrashing the rendering pipeline.

## Features

* **High-Performance Rendering:** Bypasses standard object-heavy string manipulation in favor of fast 1D array block memory operations (`List.setRange`) and integer-based grapheme boundaries, reducing GC pressure during heavy I/O.
* **Strict MVVM Boundaries:** The UI (`TerminalView`) is entirely decoupled from the state and I/O streams (`VirtualTerminal`).
* **Protocol Support:** Full parsing for standard CSI sequences, VT100 cursor manipulation, and DECSET/DECRST routing (including `1000` and `1006` SGR mouse tracking).
* **Transport Agnostic:** The core `TerminalView` does not care where your bytes come from. You can feed it local pseudo-terminals, remote SSH streams, or mock data for testing.
* **`pty2` Integration:** Includes a convenience widget (`PseudoTerminalView`) to instantly mount a `package:pty2` subprocess directly into your `termui` widget tree.

## Installation

Add it to your `pubspec.yaml`:

```yaml
dependencies:
  termui_pty: ^0.2.0
```

## Usage

### The Easy Way (Local PTY subprocess)

If you are using `package:pty2` to spawn local shells, use the `PseudoTerminalView` wrapper. It manages the stream subscriptions, resize events, and input routing for you.

```dart
import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:pty2/pty2.dart';

void main() {
  final pty = PseudoTerminal.start(
    'bash',
    ['-i'],
    environment: {'TERM': 'xterm-256color'},
  );

  runApp(
    PseudoTerminalView(
      pty: pty,
      transparentBackground: false,
    ),
  );
}
```

### The Architecturally Sound Way (Decoupled Transport)

For full control, SSH streams, or mocking in `WidgetTester`, instantiate the `VirtualTerminal` (ViewModel) yourself and bind it to a `TerminalView`.

```dart
import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';

// 1. Initialize the ViewModel
final terminal = VirtualTerminal(width: 80, height: 24);

// 2. Feed it raw byte streams from your data source
myCustomSocket.listen((bytes) {
  terminal.write(bytes);
});

// 3. Render the View and pipe user input back to the source
runApp(
  TerminalView(
    terminal: terminal,
    onInput: (String data) {
      myCustomSocket.write(data);
    },
  ),
);
```

## Testing

Because `TerminalView` requires only a `VirtualTerminal` instance, you can test complex terminal UIs using standard unit tests or `termui_test` without ever spawning a real OS process.

```dart
testWidgets('Terminal renders output', (tester) async {
  final terminal = VirtualTerminal(width: 80, height: 24);

  await tester.pumpWidget(TerminalView(terminal: terminal));

  // Inject mock ANSI sequence
  terminal.write('\x1b[31mHello World\x1b[0m'.codeUnits);

  // Verify buffer state without needing an actual PTY
  expect(terminal.buffer.getCharacter(0, 0), 'H');
});
```
