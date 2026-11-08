# Developer & AI Agent Handbook: CLI Element-based Windowing System

Welcome to the **termui** codebase. This document serves as a comprehensive developer and AI agent handbook detailing the product vision, core architectures, package layouts, element tree lifecycles, and testing practices.

---

## 1. Product Overview & System Map

`termui` is a high-performance, double-buffered **Terminal User Interface (TUI)** and **Windowing System** written in Dart. It moves away from naive CLI output printing (which causes terminal flicker and high overhead) and provides a desktop-like environment inside standard ANSI/TTY terminal applications.

### Core Goals
* **Overlapping Window Management**: Supports floating, draggable, and resizeable frames with custom titles, borders, and Z-index layering.
* **Double Buffering**: Prevents terminal flickering by maintaining an in-memory frame buffer of what is visible on-screen and comparing it with a previous frame to compute delta updates.
* **Minimal ANSI Diffing**: Emits the shortest possible terminal sequences (cursor jumps and style transitions) to repaint only the modified cells.
* **Element & Widget Tree**: Re-implements a Flutter-like reactive layout system where widgets describe configurations, elements manage tree lifecycles, and states hold stateful properties.
* **Hierarchical Input & Focus System**: Translates raw ANSI byte streams from `stdin` into high-level event objects (keys, mouse clicks/scrolls/drags, paste segments) and dispatches them down a keyboard focus node tree.
* **Modular Widget Toolkit**: Standard widgets including paragraph wrappers, lists, interactive input fields with visual cursors, progress bars, a braille-based grid canvas, tile maps, and menu overlays.

---

## 2. Monorepo Package Architecture

The project is managed as a Melos monorepo with the following workspace packages:

1. **[termui](/packages/termui)** (Core package): Implements the layout engine, widgets, elements, focus management, performance tracing, and ANSI rendering pipeline.
2. **[termui_flutter](/packages/termui_flutter)** (Core package): Hardware-accelerated Flutter and Web glyph atlas renderer.
3. **[termui_test](/packages/termui_test)** (Core package): Fakes, mocks, headless integration testing (`TerminalTester`), finders, and golden testing.
4. **[termui_shared_examples](/packages/termui_shared_examples)**: Shared example interfaces, Widget Book catalog, and reusable glass/PTY scenario layouts.
5. **[termui_recorder](/packages/termui_recorder)**: Asciicast v2/v3 recording, interactive playback (`termui_play`), ANSI screenshots, and golden matchers.
6. **[pty2](/packages/pty2)**: Cross-platform native pseudo-terminal (PTY) bindings using Unix `openpty`/`fork` and Windows `ConPTY`.
7. **[termui_pty](/packages/termui_pty)**: Streaming ANSI/VT virtual terminal emulator (`VirtualTerminal`) and `TerminalView` / `PseudoTerminalView` widgets.
8. **[termui_hotreload](/packages/termui_hotreload)**: Dart VM service hot reload integration for `termui` applications.
9. **[termui_audio](/packages/termui_audio)**: Multiplatform 3D spatial audio, waveform synthesis, and bus filtering engine backed by SoLoud FFI on CLI.
10. **[termui_audio_flutter](/packages/termui_audio_flutter)**: Flutter Desktop, Mobile, and Web SoLoud backend (`FlutterAudioEngine`) for `termui_audio`.
11. **[termui_tinpot](/packages/termui_tinpot)**: Chafa-inspired Unicode block and DIN99d perceptual image-to-ANSI quantizer.

### Dependencies & Platforms
* **Dart SDK**: Target environment is `sdk: ">=3.11.0 <4.0.0"`.
* **Platform APIs**: Interacts with libc APIs on Linux/Unix using `dart:ffi` and Windows APIs using [win32](/packages/termui/pubspec.yaml#L37) (`^6.0.0`) to configure TTY raw mode and query screen sizing.
* **Unicode / Wide Characters**: Uses [characters](/packages/termui/pubspec.yaml#L31) (`^1.4.0`) to correctly measure and slice grapheme clusters (correctly handling multi-byte characters, ZWJ sequences, and emojis).

---

## 3. Development Guidelines & Rules

When writing or modifying code in this repository:

1. **Use Modern Dart Collections**: Leverage Dart collection language features such as `if` elements, `for` elements, spread operators (`...`), and null-aware collection entries. See the [Dart Collections Guide](https://dart.dev/language/collections) for syntax references.
2. **Multi-byte & Emoji Safety**: Never use `String.length` or `String.substring` for coordinates or drawing offsets. Always use `text.characters` from `package:characters` to handle grapheme cluster boundaries.
3. **Always Check if Mounted**: Focus changes can fire when widgets are being unmounted or cleaned up. Always guard `setState` calls in focus listeners with an `if (mounted)` check:
   ```dart
   focusNode.onFocusChange = (hasFocus) {
     if (hasFocus && mounted) {
       setState(() {
         // Update state properties
       });
     }
   };
   ```
4. **Propagate InheritedWidget Updates**: Ensure [InheritedElement.update](/packages/termui/lib/ui/widgets/core/element.dart#L476) always calls `rebuild()` to ensure that children configurations get updated downstream when the parent rebuilds.
5. **Conventional Commits & Breaking Changes**: Write structured commit messages conforming to Conventional Commits 1.0.0 (e.g. `feat(core): ...`, `fix(focus): ...`). Before committing, audit every diff for both **public API breaks** (removed/renamed symbols, changed signatures, removed runtime dependencies, moved files/entrypoints) and **behavioral or side-effect changes** (lifecycle/unmount order, ownership/disposal rules, sync-to-async shifts, signal handling, stricter exceptions, or rendering occlusion). Every breaking or side-effecting commit MUST include **both** `!` in the header (`fix(scope)!: summary`) and a `BREAKING CHANGE: <reason>` footer on the final line:
   ```text
   fix(focus)!: detach children on dispose and preserve external FocusNodes

   <body explaining the change>

   BREAKING CHANGE: FocusableStateMixin no longer disposes externally provided FocusNode instances on unmount; callers that pass a custom FocusNode must dispose it themselves.
   ```
6. **Avoid stdout Terminal Properties**: Never use `stdout.terminalColumns` or `stdout.hasTerminal` to determine screen dimensions or check for a terminal. Tests run in headless environments where these getters throw exceptions. Always use the `terminal` instance provided by the mock environment (e.g., `MockTerminalBackend` from `termui_test`) or `globalSceneManager.terminal.size`.
7. **Consider Terminal Emulator/Muxer Hotkey Conflicts**: When assigning keyboard shortcuts for the TUI, always consider conflicts with common terminal multiplexers (tmux, byobu) and emulators (iTerm2, Windows Terminal, PowerShell). For example, `Ctrl+S` is often intercepted by flow control (XOFF) or tmux prefixes, and `Ctrl+W` or `Ctrl+T` are common tab-management shortcuts. Always report potential conflicts to the developer and offer alternative/fallback bindings (e.g., providing `Alt+S` as an alternative to `Ctrl+S`).
8. **Finalizing Tasks (Format & Analyze)**: Always run `dart format .` and then `dart analyze --fatal-infos` when completing tasks. The `dart analyze` check must complete cleanly with no reported issues before you finish your task.
9. **Avoid Unnecessary Caching / Prefer Generational GC**: In Dart, generational GC is highly optimized for short-lived nursery objects. Avoid caching objects (like `Canvas` or `Element` render trees) and manually calling `clear()` or `reset()` on every frame, as the O(N) list-clearing overhead often exceeds the cost of a fresh bump-pointer allocation. Rely on microbenchmarks to justify caching/pooling.
10. **Ban `dynamic` and `<dynamic>`**: Never use `dynamic`, `<dynamic>`, `Map<String, dynamic>`, `List<dynamic>`, or `as dynamic` in production, example, or test code. Always use `Object?`, `<Object?>`, concrete static types, or Dart 3 pattern matching. Workspace `analysis_options.yaml` files enforce `strict-casts`, `strict-inference`, `strict-raw-types`, `avoid_annotating_with_dynamic`, and `avoid_dynamic_calls`, and CI rejects explicit `<dynamic>` and `as dynamic` tokens.
11. **Keep Cognitive Complexity Low**: Keep production functions at or below a SonarSource cognitive complexity score of 15. Prefer flat guard clauses over nested conditionals, and avoid single-caller pass-through helpers.

---

## 4. Testing & Golden Suites

Core testing utilities (`TerminalTester`, `MockTerminalBackend`, `find`) are located in [packages/termui_test](/packages/termui_test), and each package maintains its own test suite under `packages/<package>/test`.

### Testing Practices
* **Stateful Rebuilds**: Unlike running applications which schedule frame updates on the microtask queue, tests run synchronously. You must call `element.rebuild()`, followed by `element.layout(...)` and `element.paint(...)` to force widgets to redraw after focus or state changes.
* **Focus Singleton Cleanup**: Since `FocusManager` is a singleton, focus state persists across tests. You must call `FocusManager.instance.setPrimaryFocus(null)` in `setUp()` to ensure a clean slate.
* **Golden Tests**: Uses `fake_async` and mock recorders to output Golden ANSI files under `test/goldens/` and verifies pixel-perfect compliance.
* **User-Observable Assertions**: Assert rendered `Buffer` cells, keyboard event routing, pointer drag or resize positions, and lifecycle callbacks rather than internal flags alone.
* **Diff Coverage Gate**: Maintain at least 90% LCOV line coverage on modified production lines (`dart test --coverage=coverage` followed by `dart run coverage:format_coverage --lcov`). Remove temporary `coverage/` directories before committing.

### Commands
Run the following commands inside `packages/termui` (or at the workspace root):
* Run all unit and integration tests:
  ```bash
  dart test
  ```
* Run specific test suites:
  ```bash
  dart test test/compositor_demo_test.dart
  ```
* Verify static analysis (returns zero warnings):
  ```bash
  dart analyze --fatal-infos
  ```
* Format codebase:
  ```bash
  dart format .
  ```

---

## 5. Example Gallery & Links

Check out the interactive examples in `packages/termui/example/` and `packages/termui_shared_examples/example/`:
* **[01_questionnaire_example.dart](/packages/termui/example/01_questionnaire_example.dart)**: A simple terminal form collecting user answers.
* **[02_progress_bars.dart](/packages/termui/example/02_progress_bars.dart)**: Demonstrates linear and spinner progression indicators.
* **[03_responsive_dashboard.dart](/packages/termui/example/03_responsive_dashboard.dart)**: Grid-aligned terminal dashboard that reflows on resize.
* **[braille_canvas.dart](/packages/termui/example/braille_canvas.dart)**: Demonstrates vector graphics mapping on a braille sub-pixel layout.
* **[compositor_demo.dart](/packages/termui/example/compositor_demo.dart)**: Overlapping floating windows with z-index layering, occlusion culling, and tracing.
* **[dashboard_demo.dart](/packages/termui/example/dashboard_demo.dart)**: Data tables with embedded animated widgets and floating dropdown overlays.
* **[drag_drop_demo.dart](/packages/termui/example/drag_drop_demo.dart)**: Interactive mouse drag-and-drop between `Draggable` items and `DragTarget` zones.
* **[layout_demo.dart](/packages/termui/example/layout_demo.dart)**: Static flex and box constraint layout demonstration.
* **[scroll_input_demo.dart](/packages/termui/example/scroll_input_demo.dart)**: Scrollable form controls and modal overlay dialog.
* **[state.dart](/packages/termui/example/state.dart)**: Reactive `StatefulWidget` and `InheritedWidget` layout and counter showcase.
* **[theme_decoration_demo.dart](/packages/termui/example/theme_decoration_demo.dart)**: Custom themes, border decorations, and dynamic styling.
* **[widget_book.dart](/packages/termui_shared_examples/example/widget_book.dart)**: Interactive 20-page widget component catalog with alternate and inline screen modes.
* **[06_glass_compositing.dart](/packages/termui_shared_examples/example/06_glass_compositing.dart)**: Semi-transparent glass window compositing with blur/tint effects.
* **[pty_glass_example.dart](/packages/termui_shared_examples/example/pty_glass_example.dart)**: Live subprocess PTY rendered beneath translucent glass TUI windows.
