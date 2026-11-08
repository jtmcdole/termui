# Examples

This directory contains runnable examples demonstrating `termui` layouts, widgets, animations, overlapping windows, and event handling.

## Running the Examples

Run any example from `packages/termui`:

```bash
# Interactive layout and state dashboard
dart run example/state.dart

# Interactive widget catalog (from packages/termui_shared_examples)
dart run ../termui_shared_examples/example/widget_book.dart

# Overlapping window compositor demo
dart run example/compositor_demo.dart

# Sub-pixel Braille canvas demo
dart run example/braille_canvas.dart

# Box constraints and flex layout demo
dart run example/layout_demo.dart

# Data dashboard and overlay menus showcase
dart run example/dashboard_demo.dart

# Questionnaire form prompt
dart run example/01_questionnaire_example.dart

# Linear progress bars and spinners
dart run example/02_progress_bars.dart

# Responsive dashboard that reflows on terminal resize
dart run example/03_responsive_dashboard.dart

# Mouse drag-and-drop demo
dart run example/drag_drop_demo.dart

# Scrollable form controls and modal dialog
dart run example/scroll_input_demo.dart

# Custom themes and border decorations
dart run example/theme_decoration_demo.dart
```

---

## Example Directory

### 1. [State & Layout Example (`state.dart`)](state.dart)
Showcases the Flutter-inspired layout box, geometry, and reactive state management systems:
* Nested compositions using `Row`, `Column`, `Stack`, `Positioned`, `SizedBox`, `Expanded`, `Flexible`, `Center`, and `Align`.
* Reactive `StatefulWidget` updates calling `setState()` to schedule subtree rebuilds.
* App-wide theme properties propagated down the element tree via an `InheritedWidget` (`AppTheme`).
* Live terminal resize handling and keyboard counter controls.

### 2. [Widget Book (`../termui_shared_examples/example/widget_book.dart`)](../../termui_shared_examples/example/widget_book.dart)
A 20-page interactive catalog covering the widget toolkit:
* Text inputs, multi-line text areas, number selectors, checkboxes, radio groups, switches, sliders, and dropdowns.
* Resizable `SplitPane` containers, data tables with paginators, scrollbars, trees, and modal overlays.
* Real-time vector rendering using the sub-pixel Braille `Canvas`.
* Runs in either alternate screen mode or inline cursor-relative mode (`--inline`).

### 3. [Overlapping Window Compositor (`compositor_demo.dart`)](compositor_demo.dart)
Demonstrates floating desktop-style window management via `SceneManager`:
* Floating `Window` layers that can be dragged by their title bar and resized from their bottom-right corner.
* Click-to-focus z-order promotion and bit-packed occlusion culling in `Compositor`.
* Keyboard focus traversal scoped to the active window.

### 4. [Braille Canvas Animation (`braille_canvas.dart`)](braille_canvas.dart)
Demonstrates drawing high-resolution vector lines and shapes using 2x4 Unicode Braille sub-pixel rendering (`Canvas`).

### 5. [Layout Demo (`layout_demo.dart`)](layout_demo.dart)
A non-interactive layout demonstration splitting the terminal into panels using `Column`, `Row`, `Expanded`, `Flexible`, and `SizedBox`.

### 6. [Data Dashboard & Overlays (`dashboard_demo.dart`)](dashboard_demo.dart)
Showcases data tables containing live-updating progress bars and spinners alongside floating `Overlay` dropdown menus.

### 7. [Questionnaire Prompt (`01_questionnaire_example.dart`)](01_questionnaire_example.dart)
An inline interactive form that collects user text input, radio choices, and confirmation using `PromptRunner`.

### 8. [Progress Bars & Spinners (`02_progress_bars.dart`)](02_progress_bars.dart)
Demonstrates determinate and indeterminate `LinearProgressIndicator` and `Spinner` widgets.

### 9. [Responsive Dashboard (`03_responsive_dashboard.dart`)](03_responsive_dashboard.dart)
Uses `LayoutBuilder` and flex widgets to adapt panel arrangements dynamically when the terminal is resized.

### 10. [Drag and Drop (`drag_drop_demo.dart`)](drag_drop_demo.dart)
Demonstrates mouse drag-and-drop interactions between `Draggable` items and `DragTarget` drop zones.

### 11. [Scrollable Inputs & Modal (`scroll_input_demo.dart`)](scroll_input_demo.dart)
Demonstrates a scrollable form with `SingleChildScrollView`, `ScrollBar`, and a `ModalOverlay` dialog.

### 12. [Themes & Decorations (`theme_decoration_demo.dart`)](theme_decoration_demo.dart)
Demonstrates `DecoratedBox` border styles, background fills, and dynamic theme switching.
