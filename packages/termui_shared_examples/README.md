# termui_shared_examples

Shared interactive example layouts, runners, and scenarios reused across the native CLI (`termui`) and Flutter/Web (`termui_flutter`) targets.

## Included Examples

Run from `packages/termui_shared_examples`:

* **[widget_book.dart](example/widget_book.dart)**: A 20-page interactive widget catalog showcasing inputs, forms, tables, split panes, tabs, trees, animations, Braille canvas graphics, and Asciicast recording.
  ```bash
  dart run example/widget_book.dart
  ```
* **[06_glass_compositing.dart](example/06_glass_compositing.dart)**: Demonstrates overlapping translucent glass windows and post-processing effects (`DimmerEffect`, alpha compositing) via `SceneManager`.
  ```bash
  dart run example/06_glass_compositing.dart
  ```
* **[pty_glass_example.dart](example/pty_glass_example.dart)**: Spawns a live subprocess inside `PseudoTerminalView` (`termui_pty` + `pty2`) as a background layer beneath draggable translucent `termui` glass windows.
  ```bash
  dart run example/pty_glass_example.dart
  ```
* **[ktty_probe.dart](bin/ktty_probe.dart)**: Standalone Kitty & VT capability probe and interactive diagnostic suite (`APC` graphics `a=q`/`f=32`/`o=z`/`f=100`, 32-bit `U+10EEEE` placeholders, `CSI ? u` Kitty keyboard, `XTVERSION`, `DECRQM` `?2026`/`?1016`/`?2027`/`?2004`/`?1004`/`?1006`, `OSC 10/11`, `OSC 52`, `OSC 99`, `OSC 133`, extended `SGR 4:1..5` + `58:2` + `53`).
  ```bash
  dart run bin/ktty_probe.dart
  dart run bin/ktty_probe.dart --report
  dart run bin/ktty_probe.dart --self-test
  ```
