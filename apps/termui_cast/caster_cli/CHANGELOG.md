## 0.4.1

 - Update a dependency to the latest release.

## 0.4.0

> Note: This release has breaking changes.

 - **FIX**(shaders,cast,fterm): resolve Ship-It review defects and dart2wasm record crash.
 - **FEAT**(caster-cli,client-core): add multi-PTY shell spawning and client requestSpawnSession.
 - **BREAKING** **FEAT**(termui,pty,cast): add GlyphCellList, ESC _ S CLI shader/transform protocol, 0x1C cast frames, and perf tracing.

## 0.3.0

 - Graduate package to a stable release. See pre-releases prior to this version for changelog entries.

## 0.3.0-dev.0

> Note: This release has breaking changes.

 - **BREAKING** **FIX**(cast_protocol,fterm,termui_audio): fix WebSocket close timer, upload dispose, and CI test races.
 - **BREAKING** **FEAT**(caster_cli): stage and pace >4 MiB Kitty textures as 0x1B chunks.

## 0.2.2

 - **FIX**(caster_cli): defer revision reconnect during pending upload tasks.

## 0.2.1

 - **FIX**(caster_cli): pause upload idle timer during queued disk tasks.

## 0.2.0

> Note: This release has breaking changes.

 - **FIX**(ci,test): stage ConPTY in Windows E2E tests and widen CLI subprocess startup timeouts.
 - **FEAT**(termui_cast): import protocol, server, caster CLI, and client core under apps/.
 - **BREAKING** **REFACTOR**(cast): remove in-app TLS plumbing and duplicate entrypoints.
 - **BREAKING** **FIX**(cast): harden protocol, relay, caster, and client_core in Wave 1.

