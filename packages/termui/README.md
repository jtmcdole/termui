# termui

A high-performance, double-buffered **Terminal User Interface (TUI)** and **declarative layout engine** for Dart.

`termui` enables you to build complex, rich, and highly interactive terminal applications with overlapping windows, layout grids, and a widget tree structure inspired by Flutter; without the performance pitfalls, low-level ANSI complexity, or terminal flickering of naive CLI output printing.

<video src="https://github.com/user-attachments/assets/a850086b-de1b-4fda-86f0-c97e339ff271" width="50%" autoplay loop muted controls></video>

---

## Interactive Demo

See what is possible with `termui` in your browser! Check out our live interactive web demo hosting the entire Widget Book:

  **[Live Web Demo](https://jtmcdole.github.io/termui/)**

### Looking for Flutter support?

To host a `termui` TUI application in a graphical environment (e.g. within a Flutter mobile/desktop widget or a browser canvas), check out the companion package:

  **[termui_flutter](../termui_flutter)**

---

## Screenshots

<video src="https://github.com/user-attachments/assets/e7975a3a-0732-4f54-a987-49b0375bd307" width="50%" autoplay loop muted controls></video>

<img width="1267" height="110" alt="Screenshot 2026-06-19 221607" src="https://github.com/user-attachments/assets/86581ba2-722a-46db-a607-a0ce349ff80c" />
<img width="293" height="181" alt="Screenshot 2026-06-19 221456" src="https://github.com/user-attachments/assets/9c741765-a612-43cd-b0e0-9e58eb3fac2c" />
<img width="260" height="178" alt="Screenshot 2026-06-19 221452" src="https://github.com/user-attachments/assets/d45946fc-7186-4088-893e-cc81de04f07f" />
<img width="221" height="237" alt="Screenshot 2026-06-19 221439" src="https://github.com/user-attachments/assets/ced3691c-1fce-4342-ac17-9c742db39026" />
<img width="263" height="90" alt="Screenshot 2026-06-19 221409" src="https://github.com/user-attachments/assets/59040743-c9d3-4292-bbbd-12b7d48873b7" />
<img width="295" height="77" alt="Screenshot 2026-06-19 221402" src="https://github.com/user-attachments/assets/e9e67ff8-39cf-4df1-8214-805534fb5555" />
<img width="940" height="135" alt="Screenshot 2026-06-19 215626" src="https://github.com/user-attachments/assets/9a6f272e-757d-4aa3-b924-03572f294066" />

---

## Hot Reloading

`termui` provides native support for Dart VM hot reloading via the companion package **[termui_hotreload](../termui_hotreload)**. This enables rapid prototyping of terminal layout structures and state without requiring manual process restarts or rebuilding.

To use it, wrap your application initialization with `TermuiHotReload` and execute your Dart script with the VM service enabled:

```bash
dart --enable-vm-service bin/main.dart
```

**Implementation Snapshot:**
```dart
import 'package:termui_hotreload/termui_hotreload.dart';

void main() async {
  // 1. Enable watcher before UI startup
  final hotreload = await TermuiHotReload.enable(
    onError: (e) => print('Failed to attach HotReloader: $e'),
  );

  // 2. Initialize terminal and run PromptRunner
  final terminal = Terminal();
  final runner = PromptRunner<void>(...);
  await runner.run();

  // 3. Disable watcher and free descriptors to exit cleanly
  await hotreload?.disable();
  terminal.dispose();
}
```

Check out the interactive stateful example at **[termui_hotreload/example](../termui_hotreload/example/lib/main.dart)**.

---

## 1. System Architecture

The core rendering and windowing model of `termui` revolves around three central components: `SceneManager`, `Compositor`, and `Renderer`. Together, they coordinate hardware abstraction, overlapping UI layer flattening, and minimum-cost terminal updates.

```
+-----------------------------------------------------------------+
|                          SceneManager                           |
|  - Listens to terminal events (Terminal.events)                 |
|  - Routes input to focused SceneLayer / SceneRenderer           |
|  - Instigates render frames via Compositor & Renderer           |
+-------------------------------+---------------------------------+
                                |
                                v
+-----------------------------------------------------------------+
|                           Compositor                            |
|  - Flattens all active layers onto a single target screen Buffer|
|  - Employs bit-packed Uint32List occlusion map for early-exit   |
+-------------------------------+---------------------------------+
                                |
                                v
+-----------------------------------------------------------------+
|                            Renderer                             |
|  - Diffs back-buffer against persistent _frontBuffer            |
|  - Outputs minimal ANSI escape codes to StringSink              |
+-----------------------------------------------------------------+
```

### SceneManager (`lib/ui/widgets/core/scene_manager.dart`)
`SceneManager` is the orchestrator of the terminal windowing workspace. It manages the collection of renderable screen layers, coordinates user focus, captures terminal I/O events, and synchronizes the TTY hardware state.

* **Key Roles**:
  * Tracks and manages the stack of `SceneLayer` instances.
  * Directs incoming keyboard `KeyEvent` and mouse `MouseEvent` instances from the `Terminal` event stream to the active layer and focused elements.
  * Performs hit-testing to handle floating window drags and corner-based resizes.
  * Synchronizes hardware properties, such as showing or hiding the cursor, and requesting native TTY mouse tracking.
* **Core Fields**:
  * `final Terminal terminal`: The native/mock hardware terminal interface.
  * `final RenderingMode renderingMode`: The target rendering mode (absolute alternate screen vs. cursor-relative inline).
  * `final List<SceneLayer> layers`: Stored stack of layers active on the scene.
  * `SceneLayer? focusedLayer`: The layer currently holding user keyboard focus.
  * `bool enableMouseTracking`: Dictates whether mouse events are monitored.
  * `final Compositor _compositor`: Internal instance of the layering compositor.
  * `Renderer? _renderer`: internal diff-based terminal painter.
  * `Buffer? _targetBuffer`: In-memory back-buffer coordinate grid for compositing.
* **Component Interactions**:
  1. It handles terminal resizing by adjusting fullscreen layers and invoking `render()`.
  2. It intercepts TTY events. If a mouse press hits a layer boundary, it updates `focusedLayer`, relocates the layer to the top of the stack if needed, and sets up window dragging or resizing.
  3. When `render()` is called, it constructs a list of `LayeredBuffer` items representing each layer's current state, instructs the `Compositor` to flatten them onto the `_targetBuffer`, and then prompts the `Renderer` to diff and write the output.

### Compositor (`lib/ui/buffer.dart`)
The `Compositor` flattens overlapping, out-of-order layers onto a single 2D target screen buffer.

* **LayeredBuffer**:
  An auxiliary data class encapsulating the visual payload of a layer:
  * `final Buffer buffer`: The coordinate cell data of the layer.
  * `final int x`, `final int y`: The coordinate offsets on the target screen.
  * `final int zIndex`: Stacking priority (higher values are rendered on top).
* **Composition Mechanism (`composite`)**:
  * Accepts the `target` screen `Buffer` and a list of `layers`.
  * Sorts the layers in descending order of `zIndex` (topmost layers are processed first). If Z-indices are equal, it maintains original ordering.
  * Allocates a bit-packed `Uint32List` named `written` of size `(totalCells + 31) >> 5` where `totalCells = target.width * target.height`. This array acts as a coordinate occlusion map.
  * For each layer, it computes target coordinates. If a coordinate is already marked in `written`, that pixel is occluded by a higher layer, and writing is skipped.
  * Cell drawing is skipped if the cell is marked as transparent (`sourceCell.isTransparent`).
  * If a layer's opaque cells cover the target screen completely, `remainingTargetCells` reaches 0, and the loop breaks early (early-exit optimization).

### Renderer (`lib/ui/renderer.dart`)
The `Renderer` writes minimal ANSI escape sequences by comparing the new screen state with the previous state.

* **Key Roles**:
  * Prevents screen flickering by avoiding full redraws.
  * Restricts TTY throughput by identifying and repainting only changed rectangular runs of cells.
* **Core Fields**:
  * `final Buffer _frontBuffer`: Persistent buffer cache retaining the state of the terminal screen from the last write.
  * `final RenderingMode mode`: Determines the coordinate baseline (absolute alternate screen vs. cursor-relative inline).
  * `int _lastHeight`: Tracks the height of inline animations to reset the cursor offset upwards on subsequent frames.
  * `bool _firstFrame`: Tracks whether the terminal must undergo a full initialization sweep.
* **Diffing & Write Sequences (`render`)**:
  * If in `inline` mode and it is not the first frame, it emits `\x1b[<height>F` to move the cursor back to the top-left of the inline block.
  * If in `alternateScreen` mode and screen size changes, it clears the screen (`\x1b[2J\x1b[H`) and resizes the front buffer.
  * Iterates row-by-row and cell-by-cell. It compares `backBuffer` cell properties against `_frontBuffer`.
  * If a mismatch in character cluster or style attributes is found, it scans forward to identify the end of the contiguous run of dirty cells.
  * Positions the cursor at the run start (using relative offset jumps in inline mode or absolute coordinates `\x1b[y;xH` in alternate screen mode).
  * Emits ANSI style transitions via `_writeStyleTransition` (comparing active color/formatting states and outputting `\x1b[38;2;r;g;bm` for foregrounds, `\x1b[48;2;r;g;bm` for backgrounds, and corresponding numeric flags for bold/italic/underline/reverse/blink modifiers).
  * Writes the character run and copies the updated state into `_frontBuffer`.

---

## 2. Deferred Microtask Rendering Pipeline

The rendering system schedules builds using the Dart event and microtask loop to batch state changes and avoid redundant UI repaints.

```
State Mutation (e.g. setState, focus)
               |
               v
     Element.markNeedsBuild()
               |
               v
  BuildOwner.scheduleBuildFor(element)
               |
               v
PromptRunner._scheduleRender() (Deferred via microtask)
               |
               +---[ Guarded by _drawScheduled ]
               |
               v (Next microtask execution)
      PromptRunner.render()
        1. BuildOwner.buildScope() (Rebuild dirty nodes)
        2. Root Element.layout(BoxConstraints) (Layout pass)
        3. Root Element.paint(Buffer, Offset) (Paint pass)
        4. Renderer.render(Buffer, StringSink) (Diff & write ANSI to TTY)
```

### BuildOwner (`lib/ui/widgets/core/build_owner.dart`)
The `BuildOwner` manages the lifecycle of the reactive element tree.
* **Fields**:
  * `final Set<Element> isDirtyElements`: Holds elements requiring a configuration rebuild.
  * `final void Function()? onNeedVisualUpdate`: Callback fired when a visual update is requested.
* **Methods**:
  * `scheduleBuildFor(Element element)`: Flags an element as dirty (`element.isDirty = true`), inserts it into `isDirtyElements`, and fires `onNeedVisualUpdate`.
  * `buildScope()`: Called at the start of a render pass. It filters and sorts `isDirtyElements` by `treeDepth` ascending. This ensures ancestor elements rebuild before descendants, preventing redundant sub-tree builds. It iterates and triggers `element.performRebuild()` on all elements that are still mounted and dirty.

### PromptRunner (`lib/ui/widgets/core/prompt_runner.dart`)
`PromptRunner` runs interactive inline prompts by managing the event loop and the element tree lifecycle.
* **Render Scheduling (`_scheduleRender`)**:
  * When an element calls `markNeedsBuild()`, it registers with the `BuildOwner`, which triggers `_scheduleRender`.
  * `_scheduleRender()` checks the `_drawScheduled` boolean guard. If it is false, it sets the flag to true and schedules a callback using `scheduleMicrotask()`.
  * When the microtask queue executes, `_drawScheduled` is reset to false, and the synchronous visual update sequence is triggered.

### Visual Update Sequence
Once `render()` is invoked, the framework executes these phases in order:
1. **Rebuild (`BuildOwner.buildScope`)**: Dirty elements resolve their configuration updates.
2. **Layout (`Element.layout`)**: The layout pass traverses down the element tree. The parent calls `layout(BoxConstraints constraints)` on its children, which executes `performLayout()` to compute sizes and assign offsets (`relativeOffset`).
3. **Paint (`Element.paint`)**: The paint pass traverses the tree. Elements write characters and `Style` states onto the double-buffered `Buffer` using `performPaint()`.
4. **Compositing & Terminal Write**: The back-buffer is passed to the `Renderer`. The `Renderer` diffs the new frame against `_frontBuffer` and writes the resulting ANSI sequences to the terminal's write channel.

---

## 3. Core Controllers API Blueprints

Controllers in `termui` manage the mutable state of interactive widgets.

### DiscreteScrollController (`lib/ui/scroll_controller.dart`)
Manages vertical and horizontal offsets in discrete cell-based layouts.
* **Fields**:
  * `int _scrollOffset`: Current line/cell offset.
  * `int _totalExtent`: Total content height/width.
  * `int _viewportExtent`: Visible height/width.
* **Public APIs**:
  * `int get scrollOffset`: Returns the current scroll offset.
  * `set scrollOffset(int value)`: Updates the offset, clamping it between `0` and `maxScrollExtent`. Invokes `notifyListeners()` on change.
  * `int get totalExtent` / `set totalExtent(int value)`: The total size of scrollable content.
  * `int get viewportExtent` / `set viewportExtent(int value)`: The size of the visible window.
  * `int get maxScrollExtent`: Returns the maximum valid scroll offset (`max(0, totalExtent - viewportExtent)`).
  * `void jumpTo(int offset)`: Sets the scroll offset directly.
  * `void addListener(void Function() listener)`: Registers a callback for scroll changes.
  * `void removeListener(void Function() listener)`: Removes a registered callback.
  * `void dispose()`: Clears all listeners.

### TextEditingController (`lib/ui/widgets/interactive/text_field.dart`)
Manages text input state, cursor selection coordinates, and change history.
* **Public APIs**:
  * `TextEditingValue get value` / `set value(TextEditingValue newValue)`: The current text and selection state.
  * `String get text` / `set text(String newText)`: Text helper that updates the cursor to the end of the text.
  * `void saveStateToHistory()`: Pushes the current value to the undo history stack (caps at 100 entries).
  * `void undo()`: Reverts to the last history state.
  * `void redo()`: Reapplies the last undone change.
  * `void clear()`: Resets the text and selection states to empty.
* **Associated Structs**:
  * `TextEditingValue`: Immutable snapshot containing `final String text` and `final TextSelection selection`.
  * `TextSelection`: Represents selection boundaries. Fields include `baseOffset`, `extentOffset`, `cursorLine`, `cursorColumn`, and `bool get isCollapsed`.

### FocusManager (`lib/ui/window.dart`)
A singleton registry that manages the application's focus tree.
* **Public APIs**:
  * `static final FocusManager instance`: The singleton instance.
  * `FocusNode? get primaryFocus`: The currently focused leaf node.
  * `void setPrimaryFocus(FocusNode? node)`: Updates focus state. It traces the path from the old and new nodes to the root, calling `_setFocused(false)` on nodes exiting the path and `_setFocused(true)` on nodes entering the path.

### FocusNode (`lib/ui/window.dart`)
A node in the focus traversal tree.
* **Properties**:
  * `final String id`: Unique identifier.
  * `FocusNode? parent`: Ancestor focus node.
  * `final List<FocusNode> children`: List of children.
  * `bool get hasFocus`: Returns true if this node is focused.
  * `bool get isFocused`: Returns true if this node is focused.
  * `bool get hasPrimaryFocus`: True if focused and no children are focused.
  * `void Function(bool hasFocus)? onFocusChange`: Callback fired on focus state transitions.
  * `bool Function(KeyEvent event)? onKeyEvent`: Callback to intercept key events.
* **Traversals & Lifecycle**:
  * `void requestFocus()`: Requests focus via `FocusManager`.
  * `void unfocus()`: Relinquishes focus and redirects it to the parent.
  * `void addChild(FocusNode child)`: Inserts a child node.
  * `void removeChild(FocusNode child)`: Removes a child node.
  * `bool bubbleKeyEvent(KeyEvent event)`: Bubbles key events up the parent chain until a node consumes it.
  * `FocusNode? findFocusedLeaf()`: Resolves the deeply focused leaf node.
  * `void dispose()`: Cleans up the node and removes it from the focus tree.

### FocusScopeNode (`lib/ui/window.dart`)
A specialized node that groups focusable siblings and manages focus cycles.
* **Public APIs**:
  * `FocusNode? get focusedChild`: The active child in this scope.
  * `void nextFocus()`: Cycles focus forward to the next child in the list.
  * `void previousFocus()`: Cycles focus backward to the previous child.

### SelectionController<T> (`lib/ui/widgets/interactive/selection_controller.dart`)
Manages selection state for option-based widgets like lists, radio groups, or dropdowns.
* **Public APIs**:
  * `final List<T> options`: The list of selectable options.
  * `int get selectedIndex` / `set selectedIndex(int index)`: Index of the selected option.
  * `int get focusedIndex` / `set focusedIndex(int index)`: Index of the focused option.
  * `T get selected` / `set selected(T value)`: Getter and setter for the selected value.
  * `void addListener(void Function() listener)` / `void removeListener(void Function() listener)`: Listens for selection updates.

### TabController (`lib/ui/widgets/interactive/tab_bar.dart`)
Coordinates the active index across tab components.
* **Public APIs**:
  * `final int length`: Total number of tabs.
  * `int get index` / `set index(int value)`: The active tab index (clamped to bounds).
  * `void addListener(void Function() listener)`: Registers a callback for index changes.
  * `void removeListener(void Function() listener)`: Removes a registered callback.

---

## 4. Widget Taxonomy

Widgets in `termui` are organized into four functional categories.

### A. Layout Widgets
These widgets configure constraints and position child widgets in 2D space:
* `Align`: Aligns a child within itself.
* `Column`: Arranges children vertically.
* `ConstrainedBox`: Imposes explicit constraints on a child.
* `Flexible`: Controls child sizing relative to sibling flex ratios.
* `LayoutBuilder`: Builds a widget tree dynamically based on parent constraints.
* `Padding`: Adds margins around its child.
* `Positioned`: Positions children inside a `Stack`.
* `Row`: Arranges children horizontally.
* `SafeLayout`: Guards children against terminal viewport boundaries.
* `SingleChildScrollView`: Enables single-axis scrolling for a child widget.
* `SizedBox`: Enforces a fixed size on a child.
* `SplitPane`: Divides space into resizable dual panes.
* `Stack`: Overlays multiple children on top of each other.

### B. Interactive Widgets
These widgets capture keyboard and mouse events:
* `AnimatedButton`: A button that plays transition effects when selected.
* `Button`: Standard clickable button.
* `Checkbox`: A toggle widget for boolean values.
* `Focus`: Wraps a subtree and manages a `FocusNode`.
* `Form`: A container that groups input fields.
* `HorizontalRadioGroup`: Horizontal list of mutually exclusive options.
* `InkwellButton`: Button that displays selection indicators.
* `NumberSelector`: Incremental/decremental input selector.
* `Radio`: An individual option button inside a radio group.
* `ScrollBar`: Interactive scrollbar overlay.
* `Slider`: Numeric input slider.
* `StatefulBuilder`: Exposes a local builder callback to trigger widget rebuilds.
* `Switch`: Horizontal toggle switch.
* `TabBar`: Navigation tab selector.
* `TextField`: Multi-line or single-line text input field.

### C. Display Widgets
These widgets render static or dynamic visual elements:
* `Canvas`: Vector drawing canvas utilizing sub-pixel Braille dot mapping.
* `DecoratedBox`: Draws borders and backgrounds around its child.
* `Grid`: A tile-aligned layout grid.
* `Help`: Renders a toolbar showing active hotkey references.
* `LazyTable`: High-performance table widget that renders only visible cells.
* `LeftBorder`: Draws a border on the left side of a widget.
* `LinearProgressIndicator`: Progress bar showing task completion status.
* `ListView`: Lists widgets or strings sequentially.
* `Paginator`: Pagination controls for structured lists.
* `RichText`: Displays text with mixed style configurations.
* `SevenSegmentDisplay`: Renders numerical digits in a seven-segment style.
* `Spinner`: Displays a rotating character to indicate loading status.
* `Table`: Renders grid-aligned tabular datasets.
* `Text`: Standard text wrapper.
* `TimerWidget`: A counting timer that updates periodically.
* `TreeWidget`: Collapsible tree node hierarchy.

### D. Core/Scaffold Widgets
These widgets handle screen overlays and modal dialog systems:
* `ModalOverlay`: Displays an overlay box that intercepts background events.
* `Overlay`: Manages stacked independent overlay panels.
* `Window`: A floating, draggable panel with titles, borders, and controls.

---

## 5. Performance Tracing

The performance tracing framework profiling tools are located in `lib/perf` and `lib/trace`.

### Tracer (`lib/perf/tracer.dart`)
A high-performance, low-overhead event tracer that writes to a binary log file.
* **Recording Categories (`TraceCategory`)**:
  * `build`: Widget construction events.
  * `layout`: Sizing and layout events.
  * `paint`: Buffer drawing events.
  * `events`: Mouse and keyboard events.
  * `compositor`: Compositing events.
* **Phases**:
  * `Phase.begin` (1): The start of a profiled event block.
  * `Phase.end` (2): The end of a profiled event block.
  * `Phase.instant` (3): A point-in-time event.
* **Ring Buffer Mechanism**:
  * Uses a circular buffer of size `262144` (256k events) to record events with minimal allocation overhead.
  * Writes events using two 64-bit words:
    * **Word 0**: Bit-packed metadata: `(stringId << 32) | (isolateId << 8) | phase`.
    * **Word 1**: Monotonic timestamp in microseconds: `_stopwatch.elapsedMicroseconds`.
  * Key-value metadata is mapped to the event index in `_activeMetadata`.
  * When `_writeIndex` wraps around, it swaps buffers and flushes the completed buffer to the `TracerSink`.

### Trace Viewer UI Components
The profiling visualizer uses a split-screen dashboard:

* **TraceViewerApp (`lib/trace/widgets/trace_viewer_app.dart`)**:
  * Provides the primary interface for loading and exploring binary trace outputs.
  * Supports zoom and pan controls.
  * Manages an undo/redo crop history stack (`_undoStack`/`_redoStack`) to isolate and inspect specific time ranges.

* **SearchOverlay (`lib/trace/widgets/search_overlay.dart`)**:
  * An interactive panel to search and filter trace spans.
  * Tokenizes query strings using key-value rules:
    * `dur:` / `duration:` filters by duration using operators like `<`, `>`, `<=`, or `>=` (e.g., `dur:>=16ms`).
    * `name:` or `cat:` targets event names or categories.
    * Prefixing a token with `-` excludes matching events (e.g., `-cat:events`).
  * Supports regular expression matching when query strings are enclosed in slashes (e.g., `/layout_.*/`).
  * Employs "Smart Case" matching; queries containing capital letters perform case-sensitive searches, otherwise searches are case-insensitive.

* **TimelineCanvas (`lib/trace/widgets/timeline_canvas.dart`)**:
  * Renders a horizontal flame chart representing execution tracks.
  * Culls off-screen spans using binary search (`_getCulledSpans`) for smooth navigation.
  * Maps microsecond durations to columns using the current zoom level and offsets.
  * Uses block character segments (`▏` to `█`) to show fractional durations (sub-pixel rendering).
  * Includes a measurement caliper: press and drag to display the duration between two points (e.g., `├─ 12.3ms ─┤`).

* **buildInspectorPanel (`lib/trace/widgets/inspector_panel.dart`)**:
  * Displays details for the hovered trace span.
  * Displays the start time, end time, and duration in formatted notation (nanoseconds, microseconds, or milliseconds).
  * Lists any arguments and metadata recorded with the event.

---

## 6. Imperative Breakout

The framework bridges declarative widget state with imperative console drawing using the `Element` class.

### Element Layout and Paint Lifecycle
* **Layout Phase (`layout`)**:
  * Called by the parent element with `BoxConstraints`.
  * Saves constraints in `_cachedConstraints`.
  * Invokes `performLayout(constraints)`.
  * Caches the size returned by clamping the dimensions: `_cachedSize = constraints.constrain(resolvedSize)`.
* **Paint Phase (`paint`)**:
  * Called by the parent element with the current `Buffer` and visual `Offset`.
  * Traces the paint phase and delegates to `performPaint(buffer, offset)`.

### Custom Layout Implementations
Custom elements override `performLayout` and `performPaint` to determine child placement and write pixels to the console.

#### Example: PaddingElement Walk-Through (`lib/ui/widgets/layout/padding.dart`)
`PaddingElement` manages the layout and paint operations for the `Padding` widget.

1. **Child Constraints Construction (`performLayout`)**:
   ```dart
   final padding = widget.padding;
   final doubleWidth = padding.left + padding.right;
   final doubleHeight = padding.top + padding.bottom;

   // Subtract padding from the current constraints to determine constraints for the child
   final childMinWidth = max(0, constraints.minWidth - doubleWidth);
   final childMaxWidth = constraints.maxWidth == BoxConstraints.infinity
       ? BoxConstraints.infinity
       : max(0, constraints.maxWidth - doubleWidth);

   final childMinHeight = max(0, constraints.minHeight - doubleHeight);
   final childMaxHeight = constraints.maxHeight == BoxConstraints.infinity
       ? BoxConstraints.infinity
       : max(0, constraints.maxHeight - doubleHeight);

   final childConstraints = BoxConstraints(
     minWidth: childMinWidth,
     maxWidth: childMaxWidth,
     minHeight: childMinHeight,
     maxHeight: childMaxHeight,
   );
   ```

2. **Child Layout and Offset Placement**:
   If `childElement` is not null, `PaddingElement` calls layout on the child with the computed constraints:
   ```dart
   final childSize = childElement!.layout(childConstraints);

   // Assign the child's relative offset relative to the parent top-left corner
   childElement!.relativeOffset = Offset(padding.left, padding.top);

   // Return the child size increased by the padding margins
   return Size(
     childSize.width + doubleWidth,
     childSize.height + doubleHeight,
   );
   ```

3. **Imperative Painting (`performPaint`)**:
   During the paint pass, `PaddingElement` delegates painting to its child element by applying the relative offset:
   ```dart
   @override
   void performPaint(Buffer buffer, Offset offset) {
     if (size.width > doubleWidth &&
         size.height > doubleHeight &&
         childElement != null) {
       childElement!.paint(buffer, offset + childElement!.relativeOffset);
     }
   }
   ```
