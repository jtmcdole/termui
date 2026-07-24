# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

## 2026-07-23

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`termui` - `v0.7.10`](#termui---v0710)
 - [`termui_flutter` - `v0.6.14`](#termui_flutter---v0614)
 - [`termui_recorder` - `v0.5.10+13`](#termui_recorder---v051013)
 - [`termui_test` - `v0.2.11+14`](#termui_test---v021114)
 - [`termui_hotreload` - `v0.6.13+10`](#termui_hotreload---v061310)
 - [`termui_pty` - `v0.3.10`](#termui_pty---v0310)
 - [`termui_audio` - `v0.1.3`](#termui_audio---v013)

Packages with dependency updates only:

> Packages listed below depend on other packages in this workspace that have had changes. Their versions have been incremented to bump the minimum dependency versions of the packages they depend upon in this project.

 - `termui_flutter` - `v0.6.14`
 - `termui_recorder` - `v0.5.10+13`
 - `termui_test` - `v0.2.11+14`
 - `termui_hotreload` - `v0.6.13+10`
 - `termui_pty` - `v0.3.10`
 - `termui_audio` - `v0.1.3`

---

#### `termui` - `v0.7.10`

 - **FEAT**(buffer): add active clip stack and enforce 2D spatial canvas clipping (#90).


## 2026-07-23

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`termui` - `v0.7.9`](#termui---v079)
 - [`termui_flutter` - `v0.6.13`](#termui_flutter---v0613)
 - [`termui_recorder` - `v0.5.9+12`](#termui_recorder---v05912)
 - [`termui_test` - `v0.2.10+13`](#termui_test---v021013)
 - [`termui_hotreload` - `v0.6.12+9`](#termui_hotreload---v06129)
 - [`termui_pty` - `v0.3.9`](#termui_pty---v039)
 - [`termui_audio` - `v0.1.2`](#termui_audio---v012)

Packages with dependency updates only:

> Packages listed below depend on other packages in this workspace that have had changes. Their versions have been incremented to bump the minimum dependency versions of the packages they depend upon in this project.

 - `termui_flutter` - `v0.6.13`
 - `termui_recorder` - `v0.5.9+12`
 - `termui_test` - `v0.2.10+13`
 - `termui_hotreload` - `v0.6.12+9`
 - `termui_pty` - `v0.3.9`
 - `termui_audio` - `v0.1.2`

---

#### `termui` - `v0.7.9`

 - **FIX**(ui): limit buffer drawing to 2D bounding box intersections to prevent row wrapping.


## 2026-07-20

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`pty2` - `v0.5.3`](#pty2---v053)
 - [`termui` - `v0.7.8`](#termui---v078)
 - [`termui_audio` - `v0.1.1`](#termui_audio---v011)
 - [`termui_flutter` - `v0.6.12`](#termui_flutter---v0612)
 - [`termui_hotreload` - `v0.6.11+8`](#termui_hotreload---v06118)
 - [`termui_pty` - `v0.3.8`](#termui_pty---v038)
 - [`termui_recorder` - `v0.5.8+11`](#termui_recorder---v05811)
 - [`termui_test` - `v0.2.9+12`](#termui_test---v02912)

---

#### `pty2` - `v0.5.3`

 - **REFACTOR**(core): optimize render loops and decouple audio state.
 - **FIX**: racy test in pty2.

#### `termui` - `v0.7.8`

 - **REFACTOR**(core): optimize render loops and decouple audio state.
 - **FIX**: fakeAsync for inkwell test.
 - **FEAT**(termui): add focus properties to InkwellButton and event-driven audio APIs.

#### `termui_audio` - `v0.1.1`

 - **REFACTOR**(core): optimize render loops and decouple audio state.
 - **REFACTOR**(audio): apply codefu-persona recommendations for performance and correctness.
 - **FIX**: macos / linux missing libraries.
 - **FIX**(audio_example): resolve loading hang during intrinsic measurements via MVVM refactor.
 - **FEAT**(termui_audio): add 3D distance attenuation API.
 - **FEAT**(termui): add focus properties to InkwellButton and event-driven audio APIs.
 - **FEAT**: 3d audio and mixer volume sliders.
 - **FEAT**(audio): implement engine-agnostic TermuiAudio API with 3D spatial FFI.
 - **FEAT**(audio): enable full Ogg, Vorbis, FLAC, and Opus support on Windows CLI.
 - **FEAT**(example): add interactive audio player example and update playlist mapping.
 - **FEAT**(audio): add termui_audio package for multiplatform audio playback.

#### `termui_flutter` - `v0.6.12`

 - **REFACTOR**(core): optimize render loops and decouple audio state.

#### `termui_hotreload` - `v0.6.11+8`

 - **REFACTOR**(core): optimize render loops and decouple audio state.

#### `termui_pty` - `v0.3.8`

 - **REFACTOR**(core): optimize render loops and decouple audio state.

#### `termui_recorder` - `v0.5.8+11`

 - **REFACTOR**(core): optimize render loops and decouple audio state.

#### `termui_test` - `v0.2.9+12`

 - **REFACTOR**(core): optimize render loops and decouple audio state.


## 2026-07-18

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`termui_flutter` - `v0.6.11`](#termui_flutter---v0611)

---

#### `termui_flutter` - `v0.6.11`

 - **FIX**(rendering): respect unicode variation selectors for color emojis.
 - **FIX**: barrel export waitForFontsToLoad.


## 2026-07-16

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`pty2` - `v0.5.2`](#pty2---v052)
 - [`termui` - `v0.7.7`](#termui---v077)
 - [`termui_flutter` - `v0.6.10`](#termui_flutter---v0610)
 - [`termui_pty` - `v0.3.7`](#termui_pty---v037)
 - [`termui_recorder` - `v0.5.7+10`](#termui_recorder---v05710)
 - [`termui_test` - `v0.2.8+11`](#termui_test---v02811)
 - [`termui_hotreload` - `v0.6.10+7`](#termui_hotreload---v06107)

Packages with dependency updates only:

> Packages listed below depend on other packages in this workspace that have had changes. Their versions have been incremented to bump the minimum dependency versions of the packages they depend upon in this project.

 - `termui_pty` - `v0.3.7`
 - `termui_recorder` - `v0.5.7+10`
 - `termui_test` - `v0.2.8+11`
 - `termui_hotreload` - `v0.6.10+7`

---

#### `pty2` - `v0.5.2`

 - **FIX**(pty2): resolve ConPTY initialization failures and test hangs.
 - **FIX**(pty2): quote Windows command line tokens and enable ConPTY inside automated tests.
 - **FIX**(pty2): correct ioctl FFI varargs and remove automatic login shell flag.

#### `termui` - `v0.7.7`

 - **PERF**(trace): replace duration buckets with zero-allocation IntervalTree.
 - **PERF**: buckets and callbacks to speed up rendering.
 - **FIX**(pty2): quote Windows command line tokens and enable ConPTY inside automated tests.
 - **FIX**(trace): add visual off-screen clipping indicators to TimelineCanvas.
 - **FIX**: web trace removing dartify.

#### `termui_flutter` - `v0.6.10`

 - **FIX**(pty2): correct ioctl FFI varargs and remove automatic login shell flag.
 - **FIX**: web trace removing dartify.


## 2026-07-15

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`termui_flutter` - `v0.6.9`](#termui_flutter---v069)

---

#### `termui_flutter` - `v0.6.9`

 - **REFACTOR**(flutter): extract TerminalService for MVVM screenshot handling.


## 2026-07-15

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`termui` - `v0.7.6`](#termui---v076)
 - [`termui_flutter` - `v0.6.8`](#termui_flutter---v068)
 - [`termui_recorder` - `v0.5.6+9`](#termui_recorder---v0569)
 - [`termui_test` - `v0.2.7+10`](#termui_test---v02710)
 - [`termui_hotreload` - `v0.6.9+6`](#termui_hotreload---v0696)
 - [`termui_pty` - `v0.3.6`](#termui_pty---v036)

Packages with dependency updates only:

> Packages listed below depend on other packages in this workspace that have had changes. Their versions have been incremented to bump the minimum dependency versions of the packages they depend upon in this project.

 - `termui_recorder` - `v0.5.6+9`
 - `termui_test` - `v0.2.7+10`
 - `termui_hotreload` - `v0.6.9+6`
 - `termui_pty` - `v0.3.6`

---

#### `termui` - `v0.7.6`

 - **FIX**(trace): resolve double-compression bug and decouple trace storage.

#### `termui_flutter` - `v0.6.8`

 - **FIX**(trace): resolve double-compression bug and decouple trace storage.


## 2026-07-15

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`termui` - `v0.7.5`](#termui---v075)
 - [`termui_flutter` - `v0.6.7`](#termui_flutter---v067)
 - [`termui_pty` - `v0.3.5`](#termui_pty---v035)
 - [`termui_recorder` - `v0.5.5+8`](#termui_recorder---v0558)
 - [`termui_test` - `v0.2.6+9`](#termui_test---v0269)
 - [`termui_hotreload` - `v0.6.8+5`](#termui_hotreload---v0685)

Packages with dependency updates only:

> Packages listed below depend on other packages in this workspace that have had changes. Their versions have been incremented to bump the minimum dependency versions of the packages they depend upon in this project.

 - `termui_recorder` - `v0.5.5+8`
 - `termui_test` - `v0.2.6+9`
 - `termui_hotreload` - `v0.6.8+5`

---

#### `termui` - `v0.7.5`

 - **REFACTOR**(core): extract gzip_json compression logic into termui utilities.
 - **FIX**: ensure trace viewer updates on new drops and filters asciicast files.
 - **FEAT**: implement F7 and F8 keyboard shortcuts to record trace and asciicast in example app.

#### `termui_flutter` - `v0.6.7`

 - **REFACTOR**(core): extract gzip_json compression logic into termui utilities.
 - **FIX**: ensure trace viewer updates on new drops and filters asciicast files.
 - **FEAT**: implement F7 and F8 keyboard shortcuts to record trace and asciicast in example app.

#### `termui_pty` - `v0.3.5`

 - **FIX**(termui_pty): fix multi-byte emoji parsing in virtual terminal playback.


## 2026-07-13

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`termui` - `v0.7.4`](#termui---v074)
 - [`termui_flutter` - `v0.6.6`](#termui_flutter---v066)
 - [`termui_recorder` - `v0.5.4+7`](#termui_recorder---v0547)
 - [`termui_test` - `v0.2.5+8`](#termui_test---v0258)
 - [`termui_hotreload` - `v0.6.7+4`](#termui_hotreload---v0674)
 - [`termui_pty` - `v0.3.4`](#termui_pty---v034)

Packages with dependency updates only:

> Packages listed below depend on other packages in this workspace that have had changes. Their versions have been incremented to bump the minimum dependency versions of the packages they depend upon in this project.

 - `termui_recorder` - `v0.5.4+7`
 - `termui_test` - `v0.2.5+8`
 - `termui_hotreload` - `v0.6.7+4`
 - `termui_pty` - `v0.3.4`

---

#### `termui` - `v0.7.4`

 - **PERF**(termui): remove Map allocation from compositor pipeline.
 - **PERF**(trace): optimize timeline canvas with BoolArray.
 - **FEAT**(trace): add pulse animation to selected search matches.
 - **FEAT**(termui_shared_examples): abstract platform save file capabilities.
 - **FEAT**(termui): optimize Trace Viewer search and rendering pipeline.

#### `termui_flutter` - `v0.6.6`

 - **PERF**(termui_flutter): offload gzip decompression from main thread.
 - **FIX**(test): revert default demo to glassCompositing and update test cleanup.
 - **FEAT**(termui_flutter): add trace file decoding and platform hooks.
 - **FEAT**(tui-player): implement pure termui asciicast player with drag-and-drop web support.


## 2026-07-11

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`termui` - `v0.7.3`](#termui---v073)
 - [`termui_flutter` - `v0.6.5`](#termui_flutter---v065)
 - [`termui_test` - `v0.2.4+7`](#termui_test---v0247)
 - [`termui_recorder` - `v0.5.3+6`](#termui_recorder---v0536)
 - [`termui_hotreload` - `v0.6.6+3`](#termui_hotreload---v0663)
 - [`termui_pty` - `v0.3.3`](#termui_pty---v033)

Packages with dependency updates only:

> Packages listed below depend on other packages in this workspace that have had changes. Their versions have been incremented to bump the minimum dependency versions of the packages they depend upon in this project.

 - `termui_recorder` - `v0.5.3+6`
 - `termui_hotreload` - `v0.6.6+3`
 - `termui_pty` - `v0.3.3`

---

#### `termui` - `v0.7.3`

 - **FEAT**(flutter): implement URL query parameter routing and sub-page deep linking.
 - **FEAT**(animation): add onlyDrawOnSpaces canvas option and validate game logic tests.
 - **FEAT**(termui): implement production drag-and-drop, generic sub-pixel ripples, and focused paste routing.
 - **FEAT**(terminal): add bracketed paste mode support and optimize UTF-8 decoding.

#### `termui_flutter` - `v0.6.5`

 - **FEAT**(flutter): implement URL query parameter routing and sub-page deep linking.

#### `termui_test` - `v0.2.4+7`

 - **FEAT**(terminal): add bracketed paste mode support and optimize UTF-8 decoding.


## 2026-07-08

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`termui` - `v0.7.2`](#termui---v072)
 - [`termui_flutter` - `v0.6.4`](#termui_flutter---v064)
 - [`termui_recorder` - `v0.5.2+5`](#termui_recorder---v0525)
 - [`termui_test` - `v0.2.3+6`](#termui_test---v0236)
 - [`termui_hotreload` - `v0.6.5+2`](#termui_hotreload---v0652)
 - [`termui_pty` - `v0.3.2`](#termui_pty---v032)

Packages with dependency updates only:

> Packages listed below depend on other packages in this workspace that have had changes. Their versions have been incremented to bump the minimum dependency versions of the packages they depend upon in this project.

 - `termui_flutter` - `v0.6.4`
 - `termui_recorder` - `v0.5.2+5`
 - `termui_test` - `v0.2.3+6`
 - `termui_hotreload` - `v0.6.5+2`
 - `termui_pty` - `v0.3.2`

---

#### `termui` - `v0.7.2`

 - **PERF**(widgets): eliminate render loop garbage and optimize progress bars.
 - **FEAT**(ui): add Sparkline widget and quads progress bar.
 - **FEAT**(ui): add 2D sub-unit layout and rich rendering to LinearProgressIndicator.


## 2026-07-05

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`termui` - `v0.7.1`](#termui---v071)
 - [`termui_flutter` - `v0.6.3`](#termui_flutter---v063)
 - [`termui_pty` - `v0.3.1`](#termui_pty---v031)
 - [`termui_recorder` - `v0.5.1+4`](#termui_recorder---v0514)
 - [`termui_test` - `v0.2.2+5`](#termui_test---v0225)
 - [`termui_hotreload` - `v0.6.4+1`](#termui_hotreload---v0641)

Packages with dependency updates only:

> Packages listed below depend on other packages in this workspace that have had changes. Their versions have been incremented to bump the minimum dependency versions of the packages they depend upon in this project.

 - `termui_recorder` - `v0.5.1+4`
 - `termui_test` - `v0.2.2+5`
 - `termui_hotreload` - `v0.6.4+1`

---

#### `termui` - `v0.7.1`

 - **REFACTOR**(core): improve hit-testing tests and MVVM compliance.
 - **FEAT**(core): enhance emoji rendering, persistent settings, and interactive checkboxes.

#### `termui_flutter` - `v0.6.3`

 - **REFACTOR**(core): consolidate emoji and text glyphs into a unified texture atlas.
 - **FIX**(flutter): prevent redundant background block generation in atlas.
 - **FIX**: example not showing on web.
 - **FEAT**(flutter): dump atlas table alongside screenshots.
 - **FEAT**(core): enhance emoji rendering, persistent settings, and interactive checkboxes.

#### `termui_pty` - `v0.3.1`

 - **FEAT**(core): enhance emoji rendering, persistent settings, and interactive checkboxes.


## 2026-07-05

### Changes

---

Packages with breaking changes:

 - [`termui` - `v0.7.0`](#termui---v070)
 - [`termui_pty` - `v0.3.0`](#termui_pty---v030)

Packages with other changes:

 - [`pty2` - `v0.5.1`](#pty2---v051)
 - [`termui_flutter` - `v0.6.2`](#termui_flutter---v062)
 - [`termui_hotreload` - `v0.6.4`](#termui_hotreload---v064)
 - [`termui_recorder` - `v0.5.1+3`](#termui_recorder---v0513)
 - [`termui_test` - `v0.2.2+4`](#termui_test---v0224)

Packages with dependency updates only:

> Packages listed below depend on other packages in this workspace that have had changes. Their versions have been incremented to bump the minimum dependency versions of the packages they depend upon in this project.

 - `termui_recorder` - `v0.5.1+3`
 - `termui_test` - `v0.2.2+4`

---

#### `termui` - `v0.7.0`

 - **REFACTOR**(core): change debug overlay hotkey from F6 to F10 and make logic dynamic.
 - **REFACTOR**(core): change debug overlay hotkey from F12 to F6.
 - **FIX**(termui): migrate DateTime.now to clock for test determinism.
 - **FEAT**(termui): standardize keyboard input handling with TermKey constants.
 - **FEAT**(core): implement android-style global touch visualizer and debug overlays.
 - **FEAT**(pty): stabilize termui_pty, add benchmarks, and finalize examples.
 - **FEAT**(pty): introduce termui_pty package for ANSI terminal emulation.
 - **BREAKING** **REFACTOR**(termui_pty): decouple PTY transport from terminal rendering.

#### `termui_pty` - `v0.3.0`

 - **FIX**(termui): migrate DateTime.now to clock for test determinism.
 - **FIX**(pty): fix test timer leak and buffer string comparison.
 - **FEAT**(termui_pty): decouple VirtualTerminal from FFI for web support.
 - **FEAT**(termui): standardize keyboard input handling with TermKey constants.
 - **FEAT**(pty): stabilize termui_pty, add benchmarks, and finalize examples.
 - **FEAT**(pty): introduce termui_pty package for ANSI terminal emulation.
 - **BREAKING** **REFACTOR**(termui_pty): decouple PTY transport from terminal rendering.

#### `pty2` - `v0.5.1`

 - **FIX**(tests): github actions exercised different pathways in the testing.
 - **FIX**(pty2): resolve fork deadlocks by replacing forkpty with native openpty and eagerly-resolved POSIX calls.
 - **FIX**(pty2): pre-evaluate properties before forkpty to avoid deadlocks.
 - **FIX**(pty2): strictly enforce POSIX async-signal-safety post-fork.
 - **FEAT**(termui_pty): decouple VirtualTerminal from FFI for web support.
 - **FEAT**(pty): stabilize termui_pty, add benchmarks, and finalize examples.

#### `termui_flutter` - `v0.6.2`

 - **FIX**(termui): migrate DateTime.now to clock for test determinism.
 - **FEAT**(termui_pty): decouple VirtualTerminal from FFI for web support.
 - **FEAT**(termui_flutter): showcase PTY glass example in Flutter demo.

#### `termui_hotreload` - `v0.6.4`

 - **FEAT**(termui): standardize keyboard input handling with TermKey constants.
 - **FEAT**(pty): stabilize termui_pty, add benchmarks, and finalize examples.


## 2026-07-04

### Changes

---

Packages with breaking changes:

 - [`pty2` - `v0.5.0`](#pty2---v050)

Packages with other changes:

 - [`termui` - `v0.6.3`](#termui---v063)
 - [`termui_flutter` - `v0.6.1`](#termui_flutter---v061)
 - [`termui_hotreload` - `v0.6.3`](#termui_hotreload---v063)
 - [`termui_recorder` - `v0.5.1+2`](#termui_recorder---v0512)
 - [`termui_test` - `v0.2.2+3`](#termui_test---v0223)

Packages with dependency updates only:

> Packages listed below depend on other packages in this workspace that have had changes. Their versions have been incremented to bump the minimum dependency versions of the packages they depend upon in this project.

 - `termui_recorder` - `v0.5.1+2`
 - `termui_test` - `v0.2.2+3`

---

#### `pty2` - `v0.5.0`

 - **DOCS**: fixing up documentation.
 - **BREAKING** **FEAT**(pty2): add pty2 package for cross-platform pseudo-terminals.

#### `termui` - `v0.6.3`

 - **FEAT**(demos): add glass compositing demo and flutter web integration.
 - **FEAT**(hotreload): introduce termui_hotreload package and StreamBuilder.
 - **FEAT**(hotreload): introduce termui_hotreload package and StreamBuilder.

#### `termui_flutter` - `v0.6.1`

 - **FEAT**(demos): add glass compositing demo and flutter web integration.

#### `termui_hotreload` - `v0.6.3`

 - **FEAT**(hotreload): introduce termui_hotreload package and StreamBuilder.
 - **FEAT**(hotreload): introduce termui_hotreload package and StreamBuilder.
 - **DOCS**: fixing up documentation.
 - **DOCS**(hotreload): crappy readme.


## 2026-07-02

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`termui` - `v0.6.2`](#termui---v062)
 - [`termui_hotreload` - `v0.6.2`](#termui_hotreload---v062)
 - [`termui_flutter` - `v0.6.0+2`](#termui_flutter---v0602)
 - [`termui_recorder` - `v0.5.1+1`](#termui_recorder---v0511)
 - [`termui_test` - `v0.2.2+2`](#termui_test---v0222)

Packages with dependency updates only:

> Packages listed below depend on other packages in this workspace that have had changes. Their versions have been incremented to bump the minimum dependency versions of the packages they depend upon in this project.

 - `termui_flutter` - `v0.6.0+2`
 - `termui_recorder` - `v0.5.1+1`
 - `termui_test` - `v0.2.2+2`

---

#### `termui` - `v0.6.2`

 - **FEAT**(hotreload): introduce termui_hotreload package and StreamBuilder.

#### `termui_hotreload` - `v0.6.2`

 - **FEAT**(hotreload): introduce termui_hotreload package and StreamBuilder.


## 2026-07-01

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`termui` - `v0.6.1`](#termui---v061)
 - [`termui_recorder` - `v0.5.1`](#termui_recorder---v051)
 - [`termui_test` - `v0.2.2+1`](#termui_test---v0221)
 - [`termui_flutter` - `v0.6.0+1`](#termui_flutter---v0601)

Packages with dependency updates only:

> Packages listed below depend on other packages in this workspace that have had changes. Their versions have been incremented to bump the minimum dependency versions of the packages they depend upon in this project.

 - `termui_flutter` - `v0.6.0+1`

---

#### `termui` - `v0.6.1`

 - **REFACTOR**(core): make modal dialog layers responsive to terminal resize events.
 - **FIX**(core): delegate intrinsic sizing in AbsorbPointer to child and add tests.
 - **FIX**(core): restrict alternate screen transitions in PromptRunner to standalone mode.
 - **FIX**(termui): support wide characters and CJK in tables without layout shifting.
 - **FIX**(termui): support wide characters and CJK in LazyTable without layout shifting.
 - **FIX**(testing): resolve pumpAndSettle timeouts and align fakeAsync time model with Flutter.
 - **FEAT**(core): extract Builder and implement overlay-based modal dialogs with dimming barriers.

#### `termui_recorder` - `v0.5.1`

 - **FEAT**(recorder): generate visual diff highlights and asciicast comparisons for golden mismatches.

#### `termui_test` - `v0.2.2+1`

 - **FIX**(testing): resolve pumpAndSettle timeouts and align fakeAsync time model with Flutter.


## 2026-06-25

### Changes

---

Packages with breaking changes:

 - [`termui` - `v0.6.0`](#termui---v060)
 - [`termui_flutter` - `v0.6.0`](#termui_flutter---v060)
 - [`termui_recorder` - `v0.5.0`](#termui_recorder---v050)

Packages with other changes:

 - [`termui_test` - `v0.2.2`](#termui_test---v022)

---

#### `termui` - `v0.6.0`

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

#### `termui_flutter` - `v0.6.0`

 - **REFACTOR**(core): remove legacy `cells` property and optimize rendering.
 - **BREAKING** **PERF**(core): unify buffer attributes into flat array and remove Cell.

#### `termui_recorder` - `v0.5.0`

 - **FIX**(layout): resolve implicit FlexConstraint(1) on stateful and stateless widgets.
 - **BREAKING** **PERF**(core): unify buffer attributes into flat array and remove Cell.

#### `termui_test` - `v0.2.2`

 - **FEAT**(termui): add reactive rendering support and refactor mouse event handling.


## 2026-06-19

### Changes

---

Packages with breaking changes:

 - [`termui` - `v0.5.0`](#termui---v050)
 - [`termui_flutter` - `v0.5.0`](#termui_flutter---v050)
 - [`termui_recorder` - `v0.4.0`](#termui_recorder---v040)

Packages with other changes:

 - [`termui_test` - `v0.2.1`](#termui_test---v021)

---

#### `termui` - `v0.5.0`

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

#### `termui_flutter` - `v0.5.0`

 - **FEAT**(recorder): support asciicast v3 format and gzip trace compression.
 - **FEAT**(perf): introduce selective subsystem profiling using TraceCategory.
 - **DOCS**(workspace): consolidate documentation and remove obsolete examples package.
 - **DOCS**: document scene management and managed prompt execution.
 - **DOCS**: document scene management and managed prompt execution.
 - **BREAKING** **REFACTOR**(window): simplify windowing system and remove WindowManager.

#### `termui_recorder` - `v0.4.0`

 - **REFACTOR**: modularize trace viewer and enhance testing utilities.
 - **FEAT**(recorder): support asciicast v3 format and gzip trace compression.
 - **DOCS**(workspace): consolidate documentation and remove obsolete examples package.
 - **BREAKING** **FEAT**(ui): update paint API and add trace utility.

#### `termui_test` - `v0.2.1`

 - **REFACTOR**: simplify imports by using termui barrel file.
 - **REFACTOR**: modularize trace viewer and enhance testing utilities.
 - **REFACTOR**(widgets): introduce type-safe mouse handlers and fix unmounted setState.
 - **REFACTOR**(widgets): introduce type-safe mouse handlers and fix unmounted setState.
 - **FEAT**(recorder): support asciicast v3 format and gzip trace compression.
 - **DOCS**(workspace): consolidate documentation and remove obsolete examples package.


## 2026-06-15

### Changes

---

Packages with breaking changes:

 - [`termui` - `v0.4.0`](#termui---v040)
 - [`termui_flutter` - `v0.4.0`](#termui_flutter---v040)
 - [`termui_test` - `v0.2.0`](#termui_test---v020)

Packages with other changes:

 - [`termui_recorder` - `v0.3.1`](#termui_recorder---v031)

---

#### `termui` - `v0.4.0`

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

#### `termui_flutter` - `v0.4.0`

 - **DOCS**: document scene management and managed prompt execution.
 - **BREAKING** **REFACTOR**(ui): replace getChildOffset with Element.relativeOffset and ListWidget with ListView.
 - **BREAKING** **REFACTOR**(ui): transition rendering pipeline to declarative Element-based architecture.

#### `termui_test` - `v0.2.0`

 - **REFACTOR**(widgets): introduce type-safe mouse handlers and fix unmounted setState.
 - **FIX**(ui): fix focus traversal - start to add integration tests.
 - **FEAT**(form): enable live field validation and support back tab simulation in tester.
 - **FEAT**(recorder): support action logging, trace recording, and interactive player debugging.
 - **FEAT**(widgets): implement automatic tab focus traversal and improve form state persistence.
 - **FEAT**(test): enhance TerminalTester capabilities and fix text input reactivity.
 - **FEAT**(termui_test): introduce integration testing harness and utilities.
 - **BREAKING** **REFACTOR**(ui): replace getChildOffset with Element.relativeOffset and ListWidget with ListView.

#### `termui_recorder` - `v0.3.1`

 - **FEAT**(recorder): support action logging, trace recording, and interactive player debugging.


## 2026-06-12

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`termui_flutter` - `v0.3.0`](#termui_flutter---v030)
 - [`termui_recorder` - `v0.3.0`](#termui_recorder---v030)

---

#### `termui_flutter` - `v0.3.0`

#### `termui_recorder` - `v0.3.0`


## 2026-06-12

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`termui` - `v0.3.0`](#termui---v030)

---

#### `termui` - `v0.3.0`

 - **FEAT**(termui): add multi-progress bar compilation build dashboard example.
 - **FEAT**(termui): introduce focus and key event routing interfaces with PromptScope.
 - **FEAT**(ui): add intrinsic height calculation, SelectionController, and printWidget extension (#12).


## 2026-06-11

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`termui` - `v0.2.1`](#termui---v021)
 - [`termui_flutter` - `v0.2.0+1`](#termui_flutter---v0201)
 - [`termui_recorder` - `v0.2.0+1`](#termui_recorder---v0201)

Packages with dependency updates only:

> Packages listed below depend on other packages in this workspace that have had changes. Their versions have been incremented to bump the minimum dependency versions of the packages they depend upon in this project.

 - `termui_flutter` - `v0.2.0+1`
 - `termui_recorder` - `v0.2.0+1`

---

#### `termui` - `v0.2.1`

 - **FEAT**(ui): add intrinsic height calculation, SelectionController, and printWidget extension.

# Changelog

See packages for changes!
