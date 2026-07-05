## 0.3.0

> Note: This release has breaking changes.

 - **FIX**(termui): migrate DateTime.now to clock for test determinism.
 - **FIX**(pty): fix test timer leak and buffer string comparison.
 - **FEAT**(termui_pty): decouple VirtualTerminal from FFI for web support.
 - **FEAT**(termui): standardize keyboard input handling with TermKey constants.
 - **FEAT**(pty): stabilize termui_pty, add benchmarks, and finalize examples.
 - **FEAT**(pty): introduce termui_pty package for ANSI terminal emulation.
 - **BREAKING** **REFACTOR**(termui_pty): decouple PTY transport from terminal rendering.

## 0.2.0-wip

* **BREAKING**: Replaced `PlatformView` with `TerminalView` and `PseudoTerminalView` to decouple the UI from `package:pty2` and adhere to strict MVVM architecture.
* **PERF**: Removed synchronous, blocking file I/O (`writeAsStringSync`) from the `AnsiParser` hot path.
* **PERF**: Bypassed string allocation and `grapheme.runes.first` decoding during rapid layout composition in `buffer.dart` by implementing 1D array blitting and integer-based boundaries (`isWideCodePoint`).
* **FIX**: Mouse events are properly gated by DECSET `?1000h` and `?1006h` parsing to prevent unexpected input injection.
* **FIX**: Resolved memory leak in `SceneManager` by properly cancelling `_debugTouchTimer` on disposal.
