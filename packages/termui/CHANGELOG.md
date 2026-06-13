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
