# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

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
