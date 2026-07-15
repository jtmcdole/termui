## 0.7.5

 - **REFACTOR**(core): extract gzip_json compression logic into termui utilities.
 - **FIX**: ensure trace viewer updates on new drops and filters asciicast files.
 - **FEAT**: implement F7 and F8 keyboard shortcuts to record trace and asciicast in example app.

## 0.7.4

 - **PERF**(termui): remove Map allocation from compositor pipeline.
 - **PERF**(trace): optimize timeline canvas with BoolArray.
 - **FEAT**(trace): add pulse animation to selected search matches.
 - **FEAT**(termui_shared_examples): abstract platform save file capabilities.
 - **FEAT**(termui): optimize Trace Viewer search and rendering pipeline.

## 0.7.3

 - **FEAT**(flutter): implement URL query parameter routing and sub-page deep linking.
 - **FEAT**(animation): add onlyDrawOnSpaces canvas option and validate game logic tests.
 - **FEAT**(termui): implement production drag-and-drop, generic sub-pixel ripples, and focused paste routing.
 - **FEAT**(terminal): add bracketed paste mode support and optimize UTF-8 decoding.

## 0.7.2

 - **PERF**(widgets): eliminate render loop garbage and optimize progress bars.
 - **FEAT**(ui): add Sparkline widget and quads progress bar.
 - **FEAT**(ui): add 2D sub-unit layout and rich rendering to LinearProgressIndicator.

## 0.7.1

 - **REFACTOR**(core): improve hit-testing tests and MVVM compliance.
 - **FEAT**(core): enhance emoji rendering, persistent settings, and interactive checkboxes.

## 0.7.0

> Note: This release has breaking changes.

 - **REFACTOR**(core): change debug overlay hotkey from F6 to F10 and make logic dynamic.
 - **REFACTOR**(core): change debug overlay hotkey from F12 to F6.
 - **FIX**(termui): migrate DateTime.now to clock for test determinism.
 - **FEAT**(termui): standardize keyboard input handling with TermKey constants.
 - **FEAT**(core): implement android-style global touch visualizer and debug overlays.
 - **FEAT**(pty): stabilize termui_pty, add benchmarks, and finalize examples.
 - **FEAT**(pty): introduce termui_pty package for ANSI terminal emulation.
 - **BREAKING** **REFACTOR**(termui_pty): decouple PTY transport from terminal rendering.

## 0.6.3

 - **FEAT**(demos): add glass compositing demo and flutter web integration.
 - **FEAT**(hotreload): introduce termui_hotreload package and StreamBuilder.
 - **FEAT**(hotreload): introduce termui_hotreload package and StreamBuilder.

## 0.6.2

 - **FEAT**(hotreload): introduce termui_hotreload package and StreamBuilder.

## 0.6.1

 - **REFACTOR**(core): make modal dialog layers responsive to terminal resize events.
 - **FIX**(core): delegate intrinsic sizing in AbsorbPointer to child and add tests.
 - **FIX**(core): restrict alternate screen transitions in PromptRunner to standalone mode.
 - **FIX**(termui): support wide characters and CJK in tables without layout shifting.
 - **FIX**(termui): support wide characters and CJK in LazyTable without layout shifting.
 - **FIX**(testing): resolve pumpAndSettle timeouts and align fakeAsync time model with Flutter.
 - **FEAT**(core): extract Builder and implement overlay-based modal dialogs with dimming barriers.

## 0.6.0

> Note: This release has breaking changes.

 - **REFACTOR**(termui): simplify Stack layout constraints calculation with pattern matching.
 - **REFACTOR**(termui): improve SceneRenderer lifecycle, memory management, and layout performance.
 - **REFACTOR**(core): remove legacy `cells` property and optimize rendering.
 - **PERF**(renderer): eliminate hot-path style allocations and add ASCII fast-path.
 - **PERF**(ui): optimize terminal effects to avoid Cell and Style allocations.
 - **PERF**(core): optimize buffer storage with typed arrays and modularize pointer absorption.
 - **FIX**(layout): support dynamic offset calculations for positioned children in Stack.
 - **FIX**(layout): resolve implicit FlexConstraint(1) on stateful and stateless widgets.
 - **FIX**(termui): correct intrinsic size measurement and avoid layout/focus desyncs.
 - **FEAT**(widgets): add custom border presets and border gradients.
 - **FEAT**(termui): add reactive rendering support and refactor mouse event handling.
 - **FEAT**(layout): implement terminal-native FittedBox.
 - **FEAT**(ui): implement terminal effects pipeline and dimming barrier.
 - **BREAKING** **PERF**(core): unify buffer attributes into flat array and remove Cell.

## 0.5.0

> Note: This release has breaking changes.

 - **REFACTOR**: simplify imports by using termui barrel file.
 - **REFACTOR**: modularize trace viewer and enhance testing utilities.
 - **REFACTOR**(core): rename draw to render in rendering pipeline.
 - **REFACTOR**(widgets): introduce type-safe mouse handlers and fix unmounted setState.
 - **REFACTOR**(widgets): introduce type-safe mouse handlers and fix unmounted setState.
 - **FIX**(core): globally clear mouse hover state on keyboard events and correctly clear list view hover out-of-bounds.
 - **FIX**(widgetbook): Prevent graceful exit on unhandled Enter key and clear hover highlight when selecting pages.
 - **FIX**(example): ensure 02_progress_bars exits on completion and add regression test.
 - **FEAT**(layout): implement intrinsic dimension queries for LayoutBuilder and SizedBox.
 - **FEAT**(examples): add 3D isometric logo widget book example.
 - **FEAT**(recorder): support asciicast v3 format and gzip trace compression.
 - **FEAT**(perf): introduce selective subsystem profiling using TraceCategory.
 - **FEAT**(widgets): enhance modal overlay focus management and event routing.
 - **FEAT**(ui): allow forcing mouse tracking in SceneManager.
 - **FEAT**(ui): add visual debug overlays and stable layer compositing.
 - **FEAT**(ui): add draggable layers and mouse event capturing in SceneManager.
 - **FEAT**(ui): introduce SceneManager for multi-layer rendering and input routing.
 - **FEAT**(ui): allow forcing mouse tracking in SceneManager.
 - **FEAT**(ui): add visual debug overlays and stable layer compositing.
 - **FEAT**(ui): add draggable layers and mouse event capturing in SceneManager.
 - **FEAT**(ui): introduce SceneManager for multi-layer rendering and input routing.
 - **DOCS**(workspace): consolidate documentation and remove obsolete examples package.
 - **DOCS**: document scene management and managed prompt execution.
 - **DOCS**: document scene management and managed prompt execution.
 - **BREAKING** **REFACTOR**(window): simplify windowing system and remove WindowManager.
 - **BREAKING** **FIX**(ui): make widgets immutable and preserve state on rebuild.
 - **BREAKING** **FEAT**(ui): update paint API and add trace utility.

## 0.4.0

> Note: This release has breaking changes.

 - **REFACTOR**(widgets): introduce type-safe mouse handlers and fix unmounted setState.
 - **FIX**(ui): fix focus traversal - start to add integration tests.
 - **FEAT**(ui): allow forcing mouse tracking in SceneManager.
 - **FEAT**(ui): add visual debug overlays and stable layer compositing.
 - **FEAT**(ui): add draggable layers and mouse event capturing in SceneManager.
 - **FEAT**(ui): introduce SceneManager for multi-layer rendering and input routing.
 - **FEAT**(form): enable live field validation and support back tab simulation in tester.
 - **FEAT**(recorder): support action logging, trace recording, and interactive player debugging.
 - **FEAT**(widgets): implement automatic tab focus traversal and improve form state persistence.
 - **FEAT**(test): enhance TerminalTester capabilities and fix text input reactivity.
 - **FEAT**(core): introduce BuildOwner scheduler and spatial mouse event routing.
 - **FEAT**(termui_test): introduce integration testing harness and utilities.
 - **FEAT**(widgets): move SafeLayout to ui widget library.
 - **FEAT**(ui): implement widget-based focus system and key event bubbling.
 - **DOCS**: document scene management and managed prompt execution.
 - **BREAKING** **REFACTOR**(ui): replace getChildOffset with Element.relativeOffset and ListWidget with ListView.
 - **BREAKING** **REFACTOR**(ui): transition rendering pipeline to declarative Element-based architecture.

## 0.3.0

 - **FEAT**(termui): add multi-progress bar compilation build dashboard example.
 - **FEAT**(termui): introduce focus and key event routing interfaces with PromptScope.
 - **FEAT**(ui): add intrinsic height calculation, SelectionController, and printWidget extension (#12).

## 0.2.1

 - **FEAT**(ui): add intrinsic height calculation, SelectionController, and printWidget extension.

# Changelog

All notable changes to this project will be documented in this file.

## 0.2.0

- Add golden image tests
- Add OSC 22 mouse cursors (don't use iterm2, use something good)
- Fix form navigation; add reverse text cursor
- Consolidate widget_book examples.
- upgrade win32 package to 6+

## 0.1.0

Overhauled to be more flutter like!

## 0.0.1

### Added

- **Color Interpolation APIs:**
  - `drawLineColored`: Bresenham line drawing with linear color gradients.
  - `fillTriangleColored`: Scanline-based triangle rasterizer with 3-way vertex color interpolation (RGB Triangle).
  - `fillQuadColored`: Bilinear quadrilateral rasterizer with 4-corner color interpolation (Bilinear Quad Gradient).
- **Per-Cell Style Overrides:** Added a custom `List<Style?> _styles` override grid to the `Canvas` widget, allowing custom coloring on a per-cell basis while falling back to the default widget `style`.
- **Interactive Pause Control:** Added a keyboard binding for the **`P`** key to pause/resume the shape rotations and radar sweeps in real-time, displaying `[PAUSED]` or `[RUNNING]` in the demo header.
- **High-Fidelity TUI Showcase:**
  - Styled the Analog Clock with custom amber ticks, steel face outlines, and sweeping color-coded hands.
  - Colored the Radar scopes and cross-hairs in forest green, sweep lines in bright neon green, and fade-out blips in amber/orange.
  - Integrated rotating outline and filled RGB triangles/quads using the new color interpolation APIs.

### Changed

- **Gap-Free Rasterization:**
  - Replaced the edge-sweep triangle filler with a mathematically sound **scanline rasterization algorithm** to guarantee 100% solid fills with no empty cells or gaps at any rotation angle.
  - Quad rasterization now splits the polygon into two adjacent scanline-rasterized triangles, ensuring zero-gap fills.
- **Project Renaming:** Renamed the codebase/package from `cli_experiment` to `termui` in `pubspec.yaml`, package lock configuration, and all 86 project-wide Dart source imports.

### Fixed

- Fixed sub-pixel coverage gaps inside the rotating triangles and squares where the lines would fan out and leave unfilled cells.
