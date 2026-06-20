# termui_test Package Documentation

This document describes the testing architecture, headless harness, event simulation model, and visual assertion APIs of the `termui_test` package. The package enables synchronous, fast, and high-fidelity testing of TUI interfaces and widget lifecycles in standard terminal layouts.

---

## 1. Headless Test Harness

The headless test harness isolates the TUI application under test by replacing physical terminal input and output streams with high-fidelity, in-memory buffers.

### Core Architecture & Synchronization

Tests are run inside a controlled, synchronous time-slice zone provided by `package:fake_async` (using `fakeAsync`). This allows the test harness to flush microtasks, fire timers, and execute layout/rendering passes synchronously and deterministically, without relying on real-world timing.

#### `TerminalTester`
`TerminalTester` acts as the main entrypoint and binding wrapper for integration testing.

##### Properties & Getters:
* `static TerminalTester? get active`: Resolves the active tester instance within the current execution scope (typically mapped to a running `fakeAsync` zone).
* `Element? get rootElement`: Returns the root element of the active widget tree. If a `PromptRunner` is currently running, it retrieves the root element from the active runner; otherwise, it returns the mounted static element root.
* `Buffer? get buffer`: Returns the active visual buffer (`_testBuffer`) currently being used in `pumpWidget` mode.
* `Terminal get terminal`: Returns the `Terminal` instance bound to the active mock backend (throws `StateError` if accessed outside a running session).
* `MockTerminalBackend get backend`: Returns the mock backend (throws `StateError` if accessed outside a running session).
* `List<String> get actionLog`: Returns an unmodifiable list of action descriptions (e.g., keys, taps, typings, resizes) simulated on this tester instance.
* `bool recordTraces`: Indicates whether asciicast trace recordings are enabled and actively writing to a `.cast` file.

##### Key Methods:
* `void run(Future<void> Function() callback)`
  Runs the provided testing callback in a `FakeAsync` zone. It instantiates the `MockTerminalBackend` and `Terminal`, redirects global prompt events, and repeatedly calls `elapse(const Duration(milliseconds: 1))` until the callback resolves or throws an error. It manages cleanup of mock channels upon termination.
* `Future<T?> runPrompt<T>(PromptRunner<T> runner, Future<void> Function() callback)`
  Runs an interactive `PromptRunner` within the tester context. This allows simulating keys and clicks directly targeting the running interactive prompt.
* `Future<void> pumpWidget(Widget widget, {Size size = const Size(80, 24)})`
  Mounts a static `Widget` inside a new test buffer of the specified dimensions. This is ideal for component-level or static layout verification.
* `Future<void> pump([Duration? duration])`
  Advances the fake clock (if a positive duration is specified), flushes pending microtasks, and triggers a layout and paint pass on the widget tree. If a `PromptRunner` is running, it calls `runner.pump()`. If `recordTraces` is true, it captures the current screen buffer and associates it with any new simulated actions.
* `Future<int> pumpAndSettle({Duration duration = const Duration(milliseconds: 10), Duration timeout = const Duration(seconds: 10)})`
  Repeatedly pumps the environment with the specified duration interval until no pending timers or microtasks remain. Throws a `TimeoutException` if the elapsed real time exceeds the timeout duration.

---

### Keyboard Input Simulation

Keyboard inputs are simulated using key codes and escape sequences mapped into raw input bytes.

#### `LogicalKey`
Encapsulates key representations, mapping them to standard escape sequences and debug names.

* **Constructor**:
  `const LogicalKey(this.escapeSequence, this.debugName)`

* **Static Standard Constants**:
  * Arrow Keys: `arrowUp` (`'\x1b[A'`), `arrowDown` (`'\x1b[B'`), `arrowRight` (`'\x1b[C'`), `arrowLeft` (`'\x1b[D'`)
  * Control Keys: `enter` (`'\r'`), `escape` (`'\x1b'`), `tab` (`'\t'`), `backspace` (`'\x7f'`), `delete` (`'\x1b[3~'`)
  * Layout/Navigation: `home` (`'\x1b[H'`), `end` (`'\x1b[F'`), `pageUp` (`'\x1b[5~'`), `pageDown` (`'\x1b[6~'`)
  * Function Keys: `f1` to `f12` (e.g. `f1` is `'\x1bOP'`, `f5` is `'\x1b[15~'`)
  * Signals/Shortcuts: `controlC` (`'\x03'`), `controlD` (`'\x04'`)

* **Static Helper**:
  `static LogicalKey character(String char)`
  Constructs a custom `LogicalKey` wrapping the character itself.

#### Keyboard Methods on `TerminalTester`:
* `void sendString(String value)`
  Directly pushes raw character units into the backend's standard input stream.
* `void typeText(String text)`
  Iterates over each character of `text` and pushes them as individual `LogicalKey` inputs.
* `void sendKey(LogicalKey key, {bool control = false, bool shift = false, bool alt = false})`
  Translates a key and its modifiers into standard terminal escape sequences:
  * Maps `LogicalKey.enter` to `'\n'`.
  * Maps `Shift + Tab` to `'\x1b[Z'`.
  * Maps `Ctrl + Backspace` to `'\x1b[127;5u'`.
  * Computes the xterm modifier code: `1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (control ? 4 : 0)`.
  * For special VT100 sequences starting with `\x1b[`, it splits and embeds the modifier code: e.g., Arrow Keys become `\x1b[1;<modifier><key>` and Delete becomes `\x1b[3;<modifier>~`.
  * Converts standard alphabetical keys to ASCII control character codes when `control` is true (e.g., Ctrl+Z maps to ASCII code `26`).

---

### Mouse Input Simulation

The harness supports simulating mouse presses, movements, drags, and releases using ANSI SGR-1006 mouse mode coordinates.

#### Coordinates & SGR Formatting
Terminal coordinates are 1-indexed (column 1, row 1 is top-left). `TerminalTester` translates coordinate commands into standard mouse escape sequences:
* Mouse Press: `\x1b[<button;x;yM`
* Mouse Release: `\x1b[<button;x;ym`
* Mouse Move/Drag: Mouse moves are encoded as moves with the button code. If dragging, the button value includes a `32` bitmask offset. Hover movements use the button code `35`.

#### Mouse Methods on `TerminalTester`:
* `void mouseDown(int x, int y, {MouseButton button = MouseButton.left})`
  Pushes a mouse button down sequence at `(x, y)`.
* `void mouseUp(int x, int y, {MouseButton button = MouseButton.left})`
  Pushes a mouse button release sequence at `(x, y)`.
* `void mouseMove(int x, int y, {bool drag = true, MouseButton button = MouseButton.left})`
  Pushes a mouse movement sequence. If `drag` is true, specifies the active button; otherwise, pushes a hover event.
* `void tap(Finder finder, {MouseButton button = MouseButton.left})`
  Resolves the target widget matching `finder` to find its absolute offset. Computes the center cell coordinates of the widget and fires a sequential `mouseDown` and `mouseUp` at that location.

---

### Terminal Control Simulation

* `Future<void> simulateResize(Size newSize)`
  Resizes the test buffer and mock terminal backend, then schedules a layout and repaint pass, firing window size observers.

---

### Mock Interfaces

#### `MockTerminalBackend`
Implements `TerminalBackend` for in-memory TTY interactions.
* **Fields**:
  * `bool isWindows`: OS configuration flag.
  * `Buffer? buffer`: Current painted screen buffer.
  * `Point<int> size`: Terminal dimensions.
* **Stream Getters**:
  * `Stream<List<int>> get rawInput`: Emits byte packages pushed into stdin.
  * `Stream<Point<int>> watchSize()`: Emits size changes.
* **Auxiliary Helpers**:
  * `void pushBytes(List<int> bytes)`: Simulates raw input bytes.
  * `void pushString(String value)`: Simulates raw input string.
  * `String get stdout`: Returns the accumulated standard output string buffer.
  * `List<String> get writes`: List of raw chunks written to stdout.
  * `void clearStdout()`: Clears stdout caches.

#### `MockTerminal`
Subclasses `Terminal` to allow direct event injection bypassing the parsing stage.
* **Methods**:
  * `void injectTestEvent(InputEvent event)`: Manually dispatches an input event (e.g. `MouseEvent`, `KeyEvent`).
  * `void injectResize(Point<int> newSize)`: Manually updates terminal size.
  * Tracks internal states `bool isCursorVisible` and `bool mouseTrackingEnabled`.

---

## 2. Verification & Matchers

The package includes queries and assertions to examine the widget tree structure and verify pixel-perfect terminal output.

### Widget Traversal and Queries: Finders

Finders inspect the mounted element tree to identify target components.

#### `Finder`
Abstract class representing a widget search query:
* `Iterable<Element> apply(Iterable<Element> candidates)`: Evaluates a collection of element candidates and returns those matching the criteria.

#### `CommonFinders`
A registry namespace exposed as a global constant `const CommonFinders find = CommonFinders();`.
* `Finder byType<T extends Widget>()`
  Matches widgets of the specified runtime type `T`.
* `Finder text(String text)`
  Matches widgets containing the exact text. For multi-line text (containing `\n`), it splits the text and matches if any line equals the specified string. Evaluates `Text.data`, `RichText.text`, `TextField.controller.text`, and dynamic properties named `text` or `label` via reflection fallback.
* `Finder textPattern(String regExpPattern, {bool caseSensitive = true})`
  Matches widgets whose text data matches the given Regular Expression pattern.
* `Finder byKey(Key key)`
  Matches widgets matching the specified key.
* `Finder descendant({required Finder of, required Finder matching})`
  Filters candidates to return widgets matching `matching` that are descendants of widgets matching `of`.

#### `collectAllElements(Element root)`
Traverses the element tree recursively starting from `root` using `visitChildren` and returns an iterable containing all active elements in pre-order traversal.

### Asserting Match Counts

The framework provides test matchers to evaluate finder results:
* `const Matcher findsNothing`: Asserts that a finder matches 0 elements.
* `const Matcher findsOneWidget`: Asserts that a finder matches exactly 1 element.
* `Matcher findsNWidgets(int count)`: Asserts that a finder matches exactly `count` elements.

### Expectation Extensions

`TerminalTesterExpectations` is an extension on `TerminalTester` that integrates with `package:test` assertions:
* `void expectUI(Finder finder, Matcher matcher, {String? reason})`
  Asserts that the finder matches the expected count. Upon failure, it prints a high-fidelity colorized ANSI screenshot of the current buffer to the test console and rethrows the failure.
* `String screenshot()`
  Returns a colorized ANSI SGR capture string of the active screen buffer wrapped in header/footer boundaries.

---

### Visual Regression (Golden Testing)

To ensure the terminal output is structurally correct down to every styled cell, the package performs visual regression tests against saved golden files.

#### `matchesAnsiGolden`
Exposed from the `termui_recorder` library:
```dart
Matcher matchesAnsiGolden(
  String goldenPath, {
  Map<String, String>? environment,
})
```

##### Visual Regression Protocol:
1. **Buffer Capture**: Takes a `Buffer` and converts it into a high-fidelity ANSI screenshot string with SGR styling sequences via `AnsiScreenshot.capture(buffer)`.
2. **Golden Updates**: Checks if `GENERATE_GOLDENS` or `UPDATE_GOLDENS` is set to `'true'` in the execution environment (or specified map). If so, it writes the captured ANSI output directly to `goldenPath` and automatically returns `true`.
3. **Missing Goldens**: If the golden file does not exist, it writes the actual output to a `.fail` file (at `$goldenPath.fail`) and returns `false`, recording a failure message detailing the location of the actual output.
4. **Layout Verification & Diffing**: If the file exists, it performs an exact string comparison. On mismatch:
   * It logs a line-by-line diff comparing expected lines (from the golden file) and actual lines.
   * It returns `false` and records a detailed failure description.
