# Examples

This package contains several examples demonstrating the capabilities of `termui`, ranging from basic layout constraints to complex interactive window systems.

# Running the Examples

You can run any of the examples directly using the Dart SDK:

```bash
# Run the main interactive layout and state dashboard example
dart run example/state.dart

# Run the interactive widget catalog
dart run example/widget_book.dart

# Run the overlapping window manager demo
dart run example/window_manager_interactive.dart

# Run the high-performance sub-pixel braille drawing demo
dart run example/braille_canvas.dart

# Run the simple constraints layout demo
dart run example/layout_demo.dart

# Run the data dashboard & overlays showcase
dart run example/dashboard_demo.dart
```

---

## Example Directory

### 0. [State & Layout Example (example/state.dart)](file:///app/packages/termui/example/state.dart)
The primary entrypoint example showcasing the new Flutter-aligned layout box, geometry, and state management systems. Features:
* **Declarative Layouts:** Nested compositions using `Row`, `Column`, `Stack`, `Positioned`, `SizedBox`, `Expanded`, `Flexible`, `Center`, and `Align`.
* **State Management:** Reactive `StatefulWidget` updates calling `setState()` to dynamically schedule partial subtree updates.
* **Inherited Widgets:** App-wide properties (styling and colors) propagated down the element tree via an inherited `AppTheme` context.
* **Live Event Processing:** Resizing triggers terminal size watches, adjusting viewports, and keyboard inputs drive counter changes instantly.

### 1. [Widget Book (example/widget_book.dart)](file:///app/example/widget_book.dart)
A comprehensive catalog showing off the entire interactive widget toolkit. It showcases:
* **Interactive Inputs:** Text inputs, multi-line text areas, spinner numeric selectors, checkbox-style confirm fields, and selection dropdowns.
* **Complex Containers:** Nested `SplitPane` layout containers (which support mouse dragging to resize), data tables with paginators, scrollbars, and modal overlays.
* **Vector Graphics:** A real-time rendering clock and radar utilizing sub-pixel Braille canvas calculations.
* **Form Validation:** Traversable forms with focus rings, real-time input validation, and submission handlers.
* **Alternate and Inline Screen Modes:** Can be run in standard alternate screen mode (full TUI) or inline mode (rendering relative to the terminal cursor without clearing scroll history).

### 2. [Overlapping Window Manager (example/window_manager_interactive.dart)](file:///app/example/window_manager_interactive.dart)
Demonates the floating desktop-like window manager system. Features include:
* **Interactive Windows:** Windows can be dragged to move, and resized from the bottom-right corner using mouse drag events.
* **Layering & Z-Order:** Click-to-focus brings clicked windows to the front, executing early-exit occlusion calculations to only redraw visible cells.
* **Keyboard Focus Routing:** Seamless traversal of key events down the focus node hierarchy to the active window's widgets.

### 3. [Braille Canvas Animation (example/braille_canvas.dart)](file:///app/example/braille_canvas.dart)
Demonstrates drawing high-resolution vector lines and math formulas using 2D Unicode Braille rendering:
* Morphing circle geometries and moving noise waves rendered at up to 60 FPS.
* Double-buffered diff calculations to prevent terminal flickering during rapid updates.

### 4. [Layout Demo (example/layout_demo.dart)](file:///app/example/layout_demo.dart)
A basic, non-interactive layout model demonstration that splits the terminal workspace into clean rectangular grids:
* Aligning sidebars and main content frames using percentage-based (`PercentageConstraint`), fixed-width (`LengthConstraint`), and proportional flex layouts (`FlexConstraint`).

### 5. [Data Dashboard & Overlays (example/dashboard_demo.dart)](file:///app/packages/termui/example/dashboard_demo.dart)
Showcases advanced data layout, time-driven animations, and the overlay menu system. Features:
* **Arbitrary Widgets in Table Cells:** Spawning live-updating progress indicators and clock-driven animation spinners inside a `Table` widget.
* **Floating Dropdowns & Menus:** Triggers overlay dropdown items and popup options that float on top of the main layout, with support for mouse clicks and keyboard selection/cancellation.
