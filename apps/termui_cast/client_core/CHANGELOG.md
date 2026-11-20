## 0.4.0

 - Graduate package to a stable release. See pre-releases prior to this version for changelog entries.

## 0.4.0-dev.0

> Note: This release has breaking changes.

 - **BREAKING** **FIX**(client_core,fterm): reassemble 0x1B Kitty chunks and log share diagnostics.

## 0.3.0

> Note: This release has breaking changes.

 - **BREAKING** **FIX**(client_core,fterm): preserve Kitty placeholder IDs across theme contrast and cursors.

## 0.2.1

 - Update a dependency to the latest release.

## 0.2.0

> Note: This release has breaking changes.

 - **FIX**(ci,test): stage ConPTY in Windows E2E tests and widen CLI subprocess startup timeouts.
 - **FEAT**(termui_cast): import protocol, server, caster CLI, and client core under apps/.
 - **BREAKING** **REFACTOR**(cast): remove in-app TLS plumbing and duplicate entrypoints.
 - **BREAKING** **REFACTOR**(client_core): remove unused pure-TUI viewer stack.
 - **BREAKING** **FIX**(cast): harden protocol, relay, caster, and client_core in Wave 1.

