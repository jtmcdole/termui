## 0.8.3

 - **FIX**(termui_pty): support SGR 6/21 and DECSED/DECSEL selective erase.
 - **FIX**(termui_pty): reset cursorX on IL/DL, guard CSI T/u, and support HPR/VPR.
 - **FIX**(termui_pty): support REP (CSI b) repeat preceding graphic character.
 - **FIX**(termui_pty): support CHT (CSI I) and CBT (CSI Z) tab-stop cursor motion.
 - **FEAT**(termui_pty): track independent mouse modes, focus reporting (?1004), and DECSCUSR.
 - **FEAT**(termui_pty): support custom tab stops via HTS (ESC H), TBC (CSI g), and DECST8C.
 - **FEAT**(termui_pty): answer DSR, CPR, DA1, DA2, DECRQM, and XTWINOPS 18t queries via onReply.
 - **FEAT**(termui_pty): track DECSET 2026 synchronizedOutput and 2027 graphemeClusterMode.
 - **FEAT**(termui_pty): support DEC Special Graphics G0/G1 charsets and SO/SI.
 - **FEAT**(termui_pty): clamp CUU/CUD/CNL/CPL at scroll margins and support DECOM (?6h/l).
 - **FEAT**(termui_pty): support ANSI IRM insert/replace mode (CSI 4 h/l).

## 0.8.2

 - **FIX**(termui_pty): preserve non-blank rows below cursorY on height shrink.
 - **FIX**(termui_pty): consume DCS/SOS/PM/APC control strings and unwrap tmux OSC passthrough.

## 0.8.1

 - Update a dependency to the latest release.

## 0.8.0

> Note: This release has breaking changes.

 - **FEAT**(termui_pty): integrate primary scrollback and row wrap tracking in VirtualTerminal.
 - **FEAT**(termui_pty): add ScrollbackBuffer ring data structure.
 - **FEAT**(termui_pty): add non-SGR X10 mouse encoding and wire TerminalView modes.
 - **FEAT**(termui_pty): track DECCKM/DECSET 1007 modes and encode alternate scroll.
 - **BREAKING** **FIX**(termui_pty): consume SGR 58 underline colors and parse colon subparameters.

## 0.7.0

> Note: This release has breaking changes.

 - **BREAKING** **FIX**(termui_pty): handle wide graphemes, bounds, and lifecycle in VirtualTerminal.
 - **BREAKING** **FEAT**(termui_pty): parse OSC 52 clipboard writes and bound OSC buffer.
 - **BREAKING** **FEAT**(termui_pty): add DECSET 2004 bracketed paste and Meta key guard.

## 0.6.1

 - **FEAT**(termui_pty): encode Shift+Tab, C0 punctuation, and mouse bounds in InputEncoder.

## 0.6.0

> Note: This release has breaking changes.

 - **FIX**(pty): decompose VirtualTerminal helpers and fix SGR 5/25 and 38/48.
 - **FIX**(pty): support RIS/DECSTR resets, DECSC/DECRC, CHA/VPA/ECH, and CSI intermediate guards.
 - **FEAT**(pty): add DECSTBM scroll regions and line/character editing.
 - **BREAKING** **REFACTOR**: replace `dynamic` and raw types across workspace packages.
 - **BREAKING** **FIX**(buffer): replace stale cell colors on unstyled writes and BCE erases.
 - **BREAKING** **FEAT**(pty): add alternate screen buffers (?47, ?1047, ?1048, ?1049).
 - **BREAKING** **FEAT**(pty): add DECTCEM (?25), DECAWM (?7), and right-margin wrap fixes.

## 0.5.0

> Note: This release has breaking changes.

 - **BREAKING** **FIX**(pty): complete enclosing PromptScope when PTY process exits.

## 0.4.0

> Note: This release has breaking changes.

 - **FIX**(termui_pty): decode streaming UTF-8, keep CSI params, and cancel timer.
 - **BREAKING** **REFACTOR**(examples): move shared example runners and tests to termui_shared_examples.

## 0.3.19

 - Update a dependency to the latest release.

## 0.3.18

 - Update a dependency to the latest release.

## 0.3.17

 - Update a dependency to the latest release.

## 0.3.16

 - Update a dependency to the latest release.

## 0.3.15

 - **REFACTOR**: modernize codebase to Dart 3.x language idioms across monorepo.

## 0.3.14

 - Update a dependency to the latest release.

## 0.3.13

 - Update a dependency to the latest release.

## 0.3.12

 - Update a dependency to the latest release.

## 0.3.11

 - Update a dependency to the latest release.

## 0.3.10

 - Update a dependency to the latest release.

## 0.3.9

 - Update a dependency to the latest release.

## 0.3.8

 - **REFACTOR**(core): optimize render loops and decouple audio state.

## 0.3.7

 - Update a dependency to the latest release.

## 0.3.6

 - Update a dependency to the latest release.

## 0.3.5

 - **FIX**(termui_pty): fix multi-byte emoji parsing in virtual terminal playback.

## 0.3.4

 - Update a dependency to the latest release.

## 0.3.3

 - Update a dependency to the latest release.

## 0.3.2

 - Update a dependency to the latest release.

## 0.3.1

 - **FEAT**(core): enhance emoji rendering, persistent settings, and interactive checkboxes.

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
