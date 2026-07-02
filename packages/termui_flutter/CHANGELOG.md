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
