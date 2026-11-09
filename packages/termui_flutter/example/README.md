# termui_flutter Example (`example_flutter`)

Interactive Flutter Desktop and Web host applications for `termui`, `termui_shared_examples`, `termui_pty`, and `termui_recorder`.

## Entrypoints

Run from `packages/termui_flutter/example`:

* **Main Demo Launcher (`lib/main.dart`)**:
  ```bash
  flutter run -t lib/main.dart
  ```
  Includes the **KTTY Probe (`VirtualTerminal`)** demo (`?demo=ktty-probe`), which runs the standalone wire-protocol KTTY capability probe inside an in-memory `termui_pty` `VirtualTerminal` + `TerminalView`. Press `F9` to toggle programming font ligatures (uses host system `Cascadia Code` / `Fira Code` / `JetBrains Mono` when installed, falling back to bundled `MesloLGS NF` / `Cascadia Mono`).
* **Interactive Widget Book (`lib/widget_book.dart`)**:
  ```bash
  flutter run -t lib/widget_book.dart
  ```
* **Rendering Benchmark (`lib/benchmark_main.dart`)**:
  ```bash
  flutter run -t lib/benchmark_main.dart
  ```
* **Asciicast Player & Trace Viewer**:
  Located under `lib/src/tui_player/`, supporting `.cast` / `.cast.gz` playback and JSON performance trace inspection in Flutter and Web.
