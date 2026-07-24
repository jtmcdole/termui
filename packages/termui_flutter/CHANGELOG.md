## 0.6.13

 - Update a dependency to the latest release.

## 0.6.12

 - **REFACTOR**(core): optimize render loops and decouple audio state.

## 0.6.11

 - **FIX**(rendering): respect unicode variation selectors for color emojis.
 - **FIX**: barrel export waitForFontsToLoad.

## 0.6.10

 - **FIX**(pty2): correct ioctl FFI varargs and remove automatic login shell flag.
 - **FIX**: web trace removing dartify.

## 0.6.9

 - **REFACTOR**(flutter): extract TerminalService for MVVM screenshot handling.

## 0.6.8

 - **FIX**(trace): resolve double-compression bug and decouple trace storage.

## 0.6.7

 - **REFACTOR**(core): extract gzip_json compression logic into termui utilities.
 - **FIX**: ensure trace viewer updates on new drops and filters asciicast files.
 - **FEAT**: implement F7 and F8 keyboard shortcuts to record trace and asciicast in example app.

## 0.6.6

 - **PERF**(termui_flutter): offload gzip decompression from main thread.
 - **FIX**(test): revert default demo to glassCompositing and update test cleanup.
 - **FEAT**(termui_flutter): add trace file decoding and platform hooks.
 - **FEAT**(tui-player): implement pure termui asciicast player with drag-and-drop web support.

## 0.6.5

 - **FEAT**(flutter): implement URL query parameter routing and sub-page deep linking.

## 0.6.4

 - Update a dependency to the latest release.

## 0.6.3

 - **REFACTOR**(core): consolidate emoji and text glyphs into a unified texture atlas.
 - **FIX**(flutter): prevent redundant background block generation in atlas.
 - **FIX**: example not showing on web.
 - **FEAT**(flutter): dump atlas table alongside screenshots.
 - **FEAT**(core): enhance emoji rendering, persistent settings, and interactive checkboxes.

## 0.6.2

 - **FIX**(termui): migrate DateTime.now to clock for test determinism.
 - **FEAT**(termui_pty): decouple VirtualTerminal from FFI for web support.
 - **FEAT**(termui_flutter): showcase PTY glass example in Flutter demo.

## 0.6.1

 - **FEAT**(demos): add glass compositing demo and flutter web integration.

## 0.6.0+2

 - Update a dependency to the latest release.

## 0.6.0+1

 - Update a dependency to the latest release.

## 0.6.0

> Note: This release has breaking changes.

 - **REFACTOR**(core): remove legacy `cells` property and optimize rendering.
 - **BREAKING** **PERF**(core): unify buffer attributes into flat array and remove Cell.

## 0.5.0

> Note: This release has breaking changes.

 - **FEAT**(recorder): support asciicast v3 format and gzip trace compression.
 - **FEAT**(perf): introduce selective subsystem profiling using TraceCategory.
 - **DOCS**(workspace): consolidate documentation and remove obsolete examples package.
 - **DOCS**: document scene management and managed prompt execution.
 - **DOCS**: document scene management and managed prompt execution.
 - **BREAKING** **REFACTOR**(window): simplify windowing system and remove WindowManager.

## 0.4.0

> Note: This release has breaking changes.

 - **DOCS**: document scene management and managed prompt execution.
 - **BREAKING** **REFACTOR**(ui): replace getChildOffset with Element.relativeOffset and ListWidget with ListView.
 - **BREAKING** **REFACTOR**(ui): transition rendering pipeline to declarative Element-based architecture.

## 0.3.0

 - Update a dependency to the latest release.

## 0.2.0+1

 - Update a dependency to the latest release.

## 0.2.0

- Add golden image tests
- Add OSC 22 mouse cursors (don't use iterm2, use something good)
- Fix form navigation; add reverse text cursor
- Consolidate widget_book examples.

## 0.1.0

A custom flutter renderer for termui that uses atlases to render performantly.
