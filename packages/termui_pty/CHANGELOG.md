## 0.2.0-wip

* **BREAKING**: Replaced `PlatformView` with `TerminalView` and `PseudoTerminalView` to decouple the UI from `package:pty2` and adhere to strict MVVM architecture.
* **PERF**: Removed synchronous, blocking file I/O (`writeAsStringSync`) from the `AnsiParser` hot path.
* **PERF**: Bypassed string allocation and `grapheme.runes.first` decoding during rapid layout composition in `buffer.dart` by implementing 1D array blitting and integer-based boundaries (`isWideCodePoint`).
* **FIX**: Mouse events are properly gated by DECSET `?1000h` and `?1006h` parsing to prevent unexpected input injection.
* **FIX**: Resolved memory leak in `SceneManager` by properly cancelling `_debugTouchTimer` on disposal.
