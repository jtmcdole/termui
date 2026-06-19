# Developer & AI Agent Handbook: CLI Element-based Windowing System

Welcome to the **cli_experiment** / **termui** codebase. This document serves as a comprehensive developer and AI agent handbook detailing the product vision, core architectures, package layouts, element tree lifecycles, and testing practices.

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

1. **[termui](/packages/termui)** (Core package): Implements the layout engine, widgets, elements, focus management, and ANSI rendering pipeline.
2. **[termui_shared_examples](/packages/termui_shared_examples)**: Contains example interfaces and reusable scenario layouts.
3. **[termui_recorder](/packages/termui_recorder)**: Mock terminal recorder framework used for testing and validating rendering behaviors.

### Dependencies & Platforms
* **Dart SDK**: Target environment is `sdk: ">=3.11.0 <4.0.0"`.
* **Platform APIs**: Interacts with libc APIs on Linux/Unix using `dart:ffi` and Windows APIs using [win32](/pubspec.yaml#L17) (`^6.0.0`) to configure TTY raw mode and query screen sizing.
* **Unicode / Wide Characters**: Uses [characters](/pubspec.yaml#L12) (`^1.4.0`) to correctly measure and slice grapheme clusters (correctly handling multi-byte characters, ZWJ sequences, and emojis).

---

## 3. Subsystem Breakdown

```mermaid
graph TD
  NativeTTY[Native TTY / OS Console] <--> |FFI / stdin / stdout| Terminal[Terminal Layer]
  Terminal --> |Raw bytes| InputParser[Input Parser]
  InputParser --> |Structured events| SceneManager[Scene Manager / Focus Tree]
  
  subgraph Composition & Layout
    Column/Row/Stack[Layout Containers] -->|splitRect Constraints| Viewport[Viewport Clipping]
    Widgets[Core Widgets] -->|Render| Buffer[Canvas Buffers]
    Window[Window Frames] -->|Compose| Compositor[Compositor / Z-Index Occlusion]
  end
  
  Compositor -->|Screen Back-Buffer| Renderer[Diff Renderer]
  Renderer -->|Minimal ANSI codes| Terminal
```

### A. Terminal & TTY Layer
Responsible for switching terminal input modes, polling window sizes, and handling low-level byte channels.
* **[Terminal](/packages/termui/lib/terminal/terminal.dart)**: The main entrypoint exposing screen sizing, SIGWINCH size observers (or polling on Windows), and raw input streams.
* **[UnixTerminal](/packages/termui/lib/terminal/raw/unix_terminal.dart)**: Interacts with libc `tcgetattr` and `tcsetattr` via FFI, disabling terminal echo, canonical processing (`ICANON`), and signal processing (`ISIG`).
* **[WindowsTerminal](/packages/termui/lib/terminal/raw/windows_terminal.dart)**: Uses FFI to invoke Windows APIs for TTY controls.

### B. Buffering & Painting
* **[Cell](/packages/termui/lib/ui/buffer.dart#L8)**: Represents a single coordinate atom. Contains a single character grapheme cluster and a [Style](/packages/termui/lib/ui/style.dart) (combining RGB [Colors](/packages/termui/lib/ui/color.dart) and bitmask attributes like bold, dim, underline, reverse, and transparency).
* **[Buffer](/packages/termui/lib/ui/buffer.dart#L49)**: Grid layout representing a rectangular viewport.
* **[Compositor](/packages/termui/lib/ui/buffer.dart#L149)**: Composites multiple LayeredBuffer components onto a single target screen buffer. It employs a bit-packed `Uint32List` occlusion map to perform an early-exit optimization (skipping drawing cells that are obscured by solid higher Z-index layers).
* **[Renderer](/packages/termui/lib/ui/renderer.dart)**: Diffs `backBuffer` against `frontBuffer` and outputs minimal ANSI escape updates. Supports both absolute full screen alternate screen addresses and relative offset inline animations.

### C. Element & Widget Tree
The library replicates a reactive element tree:
* **[Widget](/packages/termui/lib/ui/layout.dart#L309)**: Immutable configuration classes.
* **[Element](/packages/termui/lib/ui/layout.dart#L356)**: Mutable nodes managing the lifecycle of the tree.
* **[StatelessElement](/packages/termui/lib/ui/layout.dart#L477)**: Rebuilds children dynamically on configuration changes.
* **[StatefulElement](/packages/termui/lib/ui/layout.dart#L607)**: Manages [State](/packages/termui/lib/ui/layout.dart#L564) objects, calling `initState()`, `didUpdateWidget()`, and `dispose()`.
* **[InheritedElement](/packages/termui/lib/ui/layout.dart#L706)**: Propagates data down the context tree. When updated, it triggers a `rebuild()` to ensure children configurations refresh.

### D. Focus & Input Processing
* **[FocusNode](/packages/termui/lib/ui/window.dart#L74)**: Node in the focus tree representing an interactive layout element.
* **[FocusScopeNode](/packages/termui/lib/ui/window.dart#L201)**: A specialized node grouping siblings for direction-based focus traversal (up/down/left/right/tab).
* **[FocusManager](/packages/termui/lib/ui/window.dart#L25)**: Singleton registry tracking `primaryFocus` and coordinating focus paths.
* **[InputParser](/packages/termui/lib/ui/input_parser.dart)**: Parses raw ansi escape byte streams into [InputEvent](/packages/termui/lib/ui/event.dart) classes (keys, mouse, paste events).

---

## 4. Widget Catalog

All custom widgets are located in the [widgets/](/packages/termui/lib/ui/widgets) directory and re-exported via [widget_toolkit.dart](/packages/termui/lib/ui/widget_toolkit.dart):
* **[Text](/packages/termui/lib/ui/widgets/text.dart)**: Plain or wrapped text.
* **[RichText](/packages/termui/lib/ui/widgets/rich_text.dart)**: Text styling runs with automatic wrap support.
* **[TextField](/packages/termui/lib/ui/widgets/text_field.dart#L316)**: Multi-line / single-line interactive input fields with undo/redo support, text editing controllers, and focused style attributes.
* **[DecoratedBox](/packages/termui/lib/ui/widgets/decorated_box.dart#L191)**: Applies borders and backgrounds around nested subtrees.
* **[LinearProgressIndicator](/packages/termui/lib/ui/widgets/linear_progress_indicator.dart)**: Block-based progression indicator.
* **[Canvas](/packages/termui/lib/ui/widgets/canvas.dart)**: Vector drawing viewport utilizing sub-pixel Braille dot mapping.
* **[Grid](/packages/termui/lib/ui/widgets/grid.dart)**: 2D tile layout map.
* **[Window](/packages/termui/lib/ui/window.dart#L241)**: Draggable, resizeable floating window panels.

---

## 5. Development Guidelines & Rules

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
4. **Propagate InheritedWidget Updates**: Ensure [InheritedElement.update](/packages/termui/lib/ui/layout.dart#L734) always calls `rebuild()` to ensure that children configurations get updated downstream when the parent rebuilds.
5. **Conventional Commits**: Write structured, clear commit messages conforming to the Conventional Commits 1.0.0 specification (e.g. `feat(core): ...`, `fix(focus): ...`).
6. **Avoid stdout Terminal Properties**: Never use `stdout.terminalColumns` or `stdout.hasTerminal` to determine screen dimensions or check for a terminal. Tests run in headless environments where these getters throw exceptions. Always use the `terminal` instance provided by the mock environment (e.g., `MockTerminalBackend` from `termui_test`) or `globalSceneManager.terminal.size`.
7. **Consider Terminal Emulator/Muxer Hotkey Conflicts**: When assigning keyboard shortcuts for the TUI, always consider conflicts with common terminal multiplexers (tmux, byobu) and emulators (iTerm2, Windows Terminal, PowerShell). For example, `Ctrl+S` is often intercepted by flow control (XOFF) or tmux prefixes, and `Ctrl+W` or `Ctrl+T` are common tab-management shortcuts. Always report potential conflicts to the developer and offer alternative/fallback bindings (e.g., providing `Alt+S` as an alternative to `Ctrl+S`).
8. **Finalizing Tasks (Format & Analyze)**: Always run `dart format .` and then `dart analyze --fatal-infos` when completing tasks. The `dart analyze` check must complete cleanly with no reported issues before you finish your task.

---

## 6. Testing & Golden Suites

All test files are located in [packages/termui/test](/packages/termui/test).

### Testing Practices
* **Stateful Rebuilds**: Unlike running applications which schedule frame updates on the microtask queue, tests run synchronously. You must call `element.rebuild()`, followed by `element.layout(...)` and `element.paint(...)` to force widgets to redraw after focus or state changes.
* **Focus Singleton Cleanup**: Since `FocusManager` is a singleton, focus state persists across tests. You must call `FocusManager.instance.setPrimaryFocus(null)` in `setUp()` to ensure a clean slate.
* **Golden Tests**: Uses `fake_async` and mock recorders to output Golden ANSI files under `test/goldens/` and verifies pixel-perfect compliance.

### Commands
Run the following commands inside `/app/packages/termui`:
* Run all unit and integration tests:
  ```bash
  dart test
  ```
* Run specific test suites:
  ```bash
  dart test test/multi_pane_settings_test.dart
  ```
* Verify static analysis (returns zero warnings):
  ```bash
  dart analyze
  ```
* Format codebase:
  ```bash
  dart format .
  ```

---

## 7. Example Gallery & Links

Check out the interactive examples in `packages/termui/example/`:
* **[01_questionnaire_example.dart](/packages/termui/example/01_questionnaire_example.dart)**: A simple terminal form collecting user answers.
* **[02_progress_bars.dart](/packages/termui/example/02_progress_bars.dart)**: Demonstrates linear and spinner progression indicators.
* **[03_responsive_dashboard.dart](/packages/termui/example/03_responsive_dashboard.dart)**: Grid-aligned terminal dashboard that reflows on resize.
* **[04_multi_pane_settings.dart](/packages/termui/example/04_multi_pane_settings.dart)**: Dual-pane settings panel displaying list-to-detail sibling traversal and text inputs.
* **[braille_canvas.dart](/packages/termui/example/braille_canvas.dart)**: Demonstrates vector graphics mapping on a braille sub-pixel layout.
* **[widget_book.dart](/packages/termui/example/widget_book.dart)**: Interactive widget component book with custom page routes.
