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
