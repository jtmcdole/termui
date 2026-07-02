# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

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
