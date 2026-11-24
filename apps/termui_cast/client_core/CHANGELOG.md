## 0.5.0

> Note: This release has breaking changes.

 - **FIX**(shaders,cast,fterm): resolve Ship-It review defects and dart2wasm record crash.
 - **FEAT**(caster-cli,client-core): add multi-PTY shell spawning and client requestSpawnSession.
 - **FEAT**(cast,fterm): persist Cloud Run IAP config and gcloud path override in Connect UI.
 - **BREAKING** **FEAT**(termui,pty,cast): add GlyphCellList, ESC _ S CLI shader/transform protocol, 0x1C cast frames, and perf tracing.

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

