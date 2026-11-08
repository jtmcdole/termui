# termui_pty

A high-performance virtual terminal emulator and PTY embedding widget for the `termui` ecosystem.

`termui_pty` provides a strict, MVVM-compliant terminal emulator that processes raw ANSI/VT100 byte streams into a visible buffer. It is designed to handle high-throughput command-line output (like `htop`, `btop`, or aggressive `cat` commands) without thrashing the rendering pipeline.

## Features

* **High-Performance Rendering:** Uses flat typed-data cell buffers (`Uint32List` attributes and code units) and `package:characters` grapheme segmentation to reduce allocation pressure during heavy I/O.
* **Strict MVVM Boundaries:** The UI (`TerminalView`) is decoupled from the state and I/O streams (`VirtualTerminal`).
* **Protocol Support:** Parses standard CSI cursor movement, `DECSTBM` scroll regions, line/char editing, SGR 16/256/TrueColor attributes, custom tab stops (`HTS`, `TBC`, `CHT`, `CBT`, `DECST8C`), DEC Special Graphics (`G0`/`G1`), `REP`, `DECOM`, `IRM`, alternate screen (`?47`/`?1047`/`?1049`), scrollback history (`ScrollbackBuffer`), `OSC 52` clipboard write/read-blocking, and `DSR`/`CPR`/`DA1`/`DA2`/`DECRQM`/`XTWINOPS 18t` query replies. Also tracks `DECTCEM` cursor visibility, `DECSCUSR` cursor shape, `DECAWM` auto-wrap, `?1004` focus reporting, `?1007` alternate scroll, `?2004` bracketed paste, `?2026` synchronized output, `?2027` grapheme cluster mode, and `?9`/`?1000`/`?1002`/`?1003`/`?1006` mouse modes.
* **Transport Agnostic:** The core `TerminalView` accepts any byte or string stream. You can feed it local pseudo-terminals, remote SSH streams, or mock data for testing.
* **`pty2` Integration:** Includes a convenience widget (`PseudoTerminalView`) to mount a `package:pty2` subprocess directly into your `termui` widget tree.

## Installation

Add it to your `pubspec.yaml`:

```yaml
dependencies:
  termui_pty: ^0.8.3
```

## Usage

### The Easy Way (Local PTY subprocess)

If you are using `package:pty2` to spawn local shells, use the `PseudoTerminalView` wrapper. It manages the stream subscriptions, resize events, and input routing for you.

```dart
import 'package:pty2/pty2.dart';
import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';

Future<void> main() async {
  final pty = PseudoTerminal.start(
    'bash',
    ['-i'],
    environment: {'TERM': 'xterm-256color'},
  );

  final terminal = Terminal();
  final runner = PromptRunner<void>(
    terminal: terminal,
    alternateScreen: true,
    widget: PseudoTerminalView(
      pty: pty,
      transparentBackground: false,
    ),
  );
  await runner.run();
}
```

### The Architecturally Sound Way (Decoupled Transport)

For full control, SSH streams, or mocking in `TerminalTester`, instantiate the `VirtualTerminal` (ViewModel) yourself and bind it to a `TerminalView`.

```dart
import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';

// 1. Initialize the ViewModel
final vterm = VirtualTerminal(width: 80, height: 24);

// 2. Feed it raw byte streams from your data source
myCustomSocket.listen((bytes) {
  vterm.write(bytes);
});

// 3. Render the View and pipe user input back to the source
final runner = PromptRunner<void>(
  terminal: Terminal(),
  alternateScreen: true,
  widget: TerminalView(
    terminal: vterm,
    onInput: (String data) {
      myCustomSocket.write(data);
    },
  ),
);
await runner.run();
```

## Testing

Because `TerminalView` requires only a `VirtualTerminal` instance, you can test terminal UIs using `package:test` and `TerminalTester` from `termui_test` without spawning a real OS process.

```dart
import 'package:termui_pty/termui_pty.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

void main() {
  test('Terminal renders output', () {
    final tester = TerminalTester();
    tester.run(() async {
      final vterm = VirtualTerminal(width: 80, height: 24);

      await tester.pumpWidget(TerminalView(terminal: vterm));

      // Inject mock ANSI sequence
      vterm.writeString('\x1b[31mHello World\x1b[0m');
      await tester.pump();

      // Verify buffer state without needing an actual PTY
      expect(vterm.buffer.getCharacter(0, 0), 'H');
    });
  });
}
```
