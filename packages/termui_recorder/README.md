# termui_recorder Package Documentation

This document provides a detailed and technically precise guide to the screenshot, recording, playback, and visual regression testing utilities of the `termui_recorder` package.

---

## 1. Screenshot Engine (`AnsiScreenshot`)

The `AnsiScreenshot` class is a utility designed to capture the contents of an in-memory 2D `Buffer` and convert it into a styled ANSI escape sequence representation. This output can be printed directly to a terminal or written to an ANSI-compatible log file.

### API Signature
```dart
class AnsiScreenshot {
  /// Converts the given [Buffer] to a styled ANSI string representation.
  ///
  /// Set [resetLineEndings] to true to output `\x1b[0m` at the end of every row.
  static String capture(Buffer buffer, {bool resetLineEndings = true});
}
```

### Capturing Mechanism
`AnsiScreenshot.capture` processes the input `Buffer` cell-by-cell, traversing the coordinates row-by-row (`y` index from `0` to `height - 1`) and column-by-column (`x` index from `0` to `width - 1`).

1. **Cell Retrieval & Character Skipping**:
   * It calls `buffer.getCell(x, y)` to retrieve the `Cell` at the current coordinates.
   * If the cell is `null` or its character is empty (`cell.char == ''`), it is skipped. This naturally handles wide character padding cells (which are represented by empty strings to prevent double rendering of the second half of a wide character/emoji).
2. **Style Transition Tracking**:
   * It maintains a running state of the active style, initialized to `Style.empty`.
   * For each valid cell, it determines the styling transition from the current active style to the cell's style by calling the internal `_writeStyleTransition` method.
   * It appends the resulting ANSI escape sequences to the output `StringBuffer` and then writes the character cluster (`cell.char`).
3. **Line Endings & Final Reset**:
   * If `resetLineEndings` is `true` and the active style at the end of a row is not `Style.empty`, it appends `\x1b[0m` to reset cell formatting before appending a newline (`\n`). This ensures style leaking does not occur across line breaks in standard text viewports.
   * After completing the loop, a final check is run: if the active style is not empty, it appends a final `\x1b[0m` reset code to ensure the terminal output stream is left clean.

### Style Transition Generation (`_writeStyleTransition`)
The transition logic is optimized to write the shortest possible style modifiers. If the current style matches the target style, it returns immediately without writing anything.

* **Full Reset Condition**:
  * If the target style is `Style.empty`, it immediately outputs a full reset sequence (`\x1b[0m`).
  * If a color is cleared (i.e. the current style has a foreground/background color set but the target style does not) OR if any modifier is turned off (e.g. a bold flag was set but is now unset), it outputs a full reset (`\x1b[0m`) and resets the effective current style to `Style.empty`.
* **Color Transitions**:
  * If the target foreground color differs from the current active foreground color and is not null, it emits an RGB foreground escape sequence:
    `38;2;<r>;<g>;<b>;`
  * If the target background color differs from the current active background color and is not null, it emits an RGB background escape sequence:
    `48;2;<r>;<g>;<b>;`
* **Modifier Flags**:
  * It checks all 8 style modifier bits (representing formatting attributes) using `Modifier.has(modifiers, mask)`.
  * If a modifier is present in the target style but was not present in the current style, the corresponding ANSI code is added to the transition:
    * **Bold**: `1`
    * **Dim**: `2`
    * **Italic**: `3`
    * **Underline**: `4`
    * **Blink**: `5`
    * **Reverse**: `7`
    * **Hidden**: `8`
    * **Crossed Out**: `9`
* **String Assembly**:
  * All active transition parameters are compiled into a semi-colon separated string, stripped of trailing semi-colons, and wrapped in control boundaries: `\x1b[<codes>m`.

---

## 2. Asciicast v3 Recording (`AsciicastRecorder` & `AsciicastWriter`)

The Asciicast recorder subsystem records a sequence of terminal frames and outputs them in the Asciinema Asciicast v3 JSON format (lines of JSON arrays containing timestamp, type, and payload).

### AsciicastWriter Interface
The `AsciicastWriter` acts as the abstraction layer for writing lines of Asciicast recordings.

```dart
abstract interface class AsciicastWriter {
  /// Writes a single line to the output destination.
  void writeLine(String line);

  /// Closes the output destination.
  void close();
}
```

#### Out-of-the-Box Writers:
1. **`FileAsciicastWriter`**:
   * Designed for file-based persistence. It buffers the encoded lines in an in-memory `StringBuffer`.
   * When `close()` is called, it encodes the buffer content into UTF-8, compresses the bytes using GZip (`GZipEncoder` from `package:archive/archive.dart`), and writes the compressed bytes synchronously to the target file.
   * During initialization, it automatically deletes any pre-existing file at the target path and creates a new one recursively.
2. **`StringSinkAsciicastWriter`**:
   * Wraps an in-memory `StringSink` (such as a `StringBuffer`).
   * Writes lines directly to the sink. The `close()` operation is a no-op.

---

### `AsciicastRecorder`
The `AsciicastRecorder` tracks terminal frame updates and formats them as a stream of Asciicast JSON lines.

```dart
class AsciicastRecorder {
  final int width;
  final int height;

  AsciicastRecorder(
    AsciicastWriter writer, {
    required this.width,
    required this.height,
  });

  /// Records a frame change from the given [buffer] by diff-rendering it.
  void recordFrame(Buffer buffer, [List<String>? actions]);

  /// Closes the recorder and its underlying writer.
  void close();
}
```

#### Core Mechanisms
* **Renderer Initialization**:
  On initialization, the recorder spins up an internal `Renderer` configured to the target `width` and `height`, with `RenderingMode.alternateScreen` enabled.
* **Header Serialization**:
  Before the first frame is recorded, it writes a v3 header JSON record:
  ```json
  {"version": 3, "term": {"cols": 80, "rows": 24}, "timestamp": 1729482810}
  ```
  The timestamp field is stored as Unix epoch seconds computed from the session's start time.
* **Frame Recording (`recordFrame`)**:
  1. Computes timestamps using `clock.now()` (via `package:clock/clock.dart`). The first frame initializes `_startTime` and `_lastEventTime`.
  2. Compares the current `buffer` against the renderer's cached front-buffer using `_renderer.render(buffer, frameOutput)`.
  3. If the resulting delta ANSI string is empty (meaning no cells changed), the frame is skipped.
  4. Computes the interval seconds since the last event:
     $$\Delta t = \frac{\text{elapsed microseconds}}{1,000,000}$$
     and updates `_lastEventTime` to the current timestamp.
  5. **Actions (Metadata) Logging**:
     If an `actions` array is supplied and is not empty, it writes a metadata row with an interval of `0.0` (matching the exact timeline tick of the subsequent frame) and type `'d'`:
     ```json
     [0.0, "d", "Actions: keypress space, click 10;12"]
     ```
  6. **Frame Output Writing**:
     It serializes and writes the standard output event row of type `'o'` containing the delta ANSI characters:
     ```json
     [0.1524, "o", "\u001b[2;3HHello"]
     ```

---

## 3. Asciicast Playback (`AsciicastPlayer`)

The `AsciicastPlayer` reads an Asciinema Asciicast recording and reproduces the terminal states inside a physical or mock terminal. It supports variable playback speeds and interactive time-travel controls in standard terminal raw modes.

### API Signature
```dart
class AsciicastEvent {
  final double time;
  final String type;
  final String data;

  AsciicastEvent(this.time, this.type, this.data);
}

class AsciicastPlayer {
  final String asciicastData;

  AsciicastPlayer(this.asciicastData, {StringSink? stdout});

  /// Plays the asciicast session back to the terminal.
  Future<void> play({
    double speedMultiplier = 1.0,
    bool interactive = true,
    bool paused = false,
    bool noCloseAtEnd = false,
  });
}
```

### Parsing Recording Streams
* The player splits `asciicastData` by line breaks.
* The header (line 0) is parsed to extract metadata. If the version is `3`, it queries the nested `term.cols` and `term.rows` structures. Otherwise, it defaults to standard `width` and `height` properties (v2).
* Subsequent lines are parsed as JSON arrays `[time, type, data]`.
  * **v3 Timestamps**: In Asciicast v3, time stamps are relative deltas. The player accumulates these increments into a running absolute time (`accumulatedTime`).
  * **v2 Timestamps**: Timestamps are absolute, so they are stored directly.
  * Only valid events containing three fields are appended to the internal `events` list.

---

### Playback Control Modes

#### 1. Non-Interactive Playback (`interactive = false`)
* In this mode, the player processes events sequentially.
* It filters events of type `'o'` (output sequences).
* For each event, it calculates the target execution time:
  $$\text{Target Real Elapsed} = \frac{\text{event.time} \times 1000.0}{\text{speedMultiplier}}$$
* It measures the actual elapsed time from a running `Stopwatch`. If the target elapsed time is in the future, it delays execution using `Future.delayed`.
* It writes the output byte string directly to the configured `stdout` StringSink (or falls back to `print`).

#### 2. Interactive Playback (`interactive = true`)
The interactive playback engine enters a raw TTY alternate screen environment using `Terminal.runGuarded((terminal) async { ... })`.

##### Keyboard Navigation & Control Bindings
During playback, the keyboard event stream is monitored via `terminal.events.listen`. Users can trigger the following commands:
* **`Space`**: Toggles playback between paused and running states.
* **`.` (Period)**: Steps forward one frame (only works if playback is paused).
* **`,` (Comma)**: Steps backward one frame (only works if playback is paused).
* **`+` or `=`**: Speeds up the playback speed factor by $1.25\times$ (capped at $100\times$).
* **`-` or `_`**: Slows down the playback speed factor by $0.8\times$ (floored at $0.1\times$).
* **`q` or `Escape`**: Aborts playback and exits the interactive player.

##### Drift-Free Timing and Speed Adjustment Logic
To support real-time speed mutations and pausing without accumulating timing drift, the player tracks the following clock offsets:
* `stopwatch`: Master real-world stopwatch.
* `totalPausedMs`: Accumulation of time spent in a paused state.
* `pauseStartMs`: The timestamp when the pause button was pressed.
* `recordedTimeAtLastSpeedChange`: The virtual recorded position in the `.cast` file when the user last adjusted the speed multiplier.
* `realTimeAtLastSpeedChangeMs`: The active real-world running duration (excluding pauses) when the speed was last modified.

When calculating the duration of the current frame's sleep, the target real-world time is derived dynamically:
$$\text{Target Real MS} = \text{realTimeAtLastSpeedChangeMs} + \frac{(\text{event.time} - \text{recordedTimeAtLastSpeedChange}) \times 1000.0}{\text{speed}}$$

##### Step-Backward Frame Reconstruction
Because ANSI sequences are streaming state mutations (rather than static keyframes), stepping backward requires complete state reconstruction:
1. It queries the list of events to find the index of the previous output (`'o'`) event.
2. It resets the terminal canvas state by emitting clear screen (`\x1b[2J`) and home cursor (`\x1b[H`) instructions.
3. It iterates forward from event `0` up to the target index, writing each output event's payload to the terminal sequentially and instantaneously. This rebuilds the terminal's coordinate matrix to match the target frame exactly.

##### Interruptible Sleeps (`_InterruptibleSleep`)
Standard `Future.delayed` calls cannot be canceled early. If a frame has a 5-second pause, a user keypress (like resume or step) would lag until the timer finished.
To resolve this, the player utilizes an internal `_InterruptibleSleep` class. It manages a `Timer` alongside a `Completer<void>`. When a keyboard event modifies the playback state (e.g. toggles pause, adjusts speed, or quits), it calls `interrupt()`. This cancels the timer and completes the future instantly, allowing the main playback loop to recalculate constraints and respond immediately.

##### Status Bar Rendering
The player draws an interactive status bar at the bottom of the terminal using reverse video (`\x1b[7m`) to avoid interfering with the recorded content:
* It saves the active cursor position using `\x1b[s`.
* Moves the cursor to the bottom row (`row = termHeight`).
* Writes the active status text (playback status, speed factor, and key commands).
* Restores the cursor back to the terminal viewport using `\x1b[u`.

##### Metadata Box Drawing
If the current output event has a corresponding metadata `'d'` event (e.g. actions) at the exact same timestamp, a two-row debugger window is rendered directly above the status bar:
* **Row `row - 2`**: Draws a border box top line with a title indicator: `┌─ Debug Metadata ───────────────────┐`
* **Row `row - 1`**: Encloses the recorded action string in vertical border lines: `│ Actions: click 12;2                │`
* If no metadata is present on the active frame, these rows are cleared using the `\x1b[K` escape sequence.

---

## 4. Supplementary Utilities

### `AnsiParser`
`AnsiParser` acts as the counterpart to `AnsiScreenshot`, deserializing ANSI escape streams back into standard structured `Buffer` grids.

* **Static Parsing (`parse`)**:
  * Reads a full ANSI string and parses characters.
  * If dimensions are omitted, it computes the height based on newline boundaries and the width using the maximum length of grapheme lines (stripping ANSI codes first using `_stripAnsi`).
  * Iterates characters using `ansi.characters`. When it encounters `\x1b[`, it reads up to the terminator `m` and parses the style change via `_applyAnsiCodes`, modifying the running style.
* **Stream Parsing (`parseStream`)**:
  * Applies delta ANSI escape commands directly to an existing `Buffer`.
  * Recognizes cursor movement commands:
    * `H` (Cursor Position)
    * `A` (Cursor Up)
    * `C` (Cursor Forward)
    * `D` (Cursor Backward)
    * `F` (Cursor Preceding Line)
    * `J` (Erase in Display; clears buffer when parameter is `2`).
  * Returns the updated coordinates and active style as a Dart record: `(int cursorX, int cursorY, Style currentStyle)`.

### `matchesAnsiGolden`
A test matcher used for visual regression testing of TUI layouts.

* **Visual Matching**:
  * Converts the test `Buffer` to an ANSI screenshot string via `AnsiScreenshot.capture`.
  * If the environment variable `GENERATE_GOLDENS` or `UPDATE_GOLDENS` is set to `'true'`, it creates or updates the target golden file on disk with the current buffer output and returns `true`.
  * Otherwise, it reads the expected ANSI representation from the golden file and performs an exact string comparison.
  * If the golden file does not exist, it writes the current output to a `.fail` file adjacent to the expected path for visual debugging.
