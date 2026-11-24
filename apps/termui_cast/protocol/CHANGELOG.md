## 0.5.0

> Note: This release has breaking changes.

 - **FIX**(shaders,cast,fterm): resolve Ship-It review defects and dart2wasm record crash.
 - **FEAT**(cast,fterm): persist Cloud Run IAP config and gcloud path override in Connect UI.
 - **BREAKING** **FEAT**(cast-protocol): add SpawnSessionFrame, allowSpawn flags, and subpath URI resolution.
 - **BREAKING** **FEAT**(termui,pty,cast): add GlyphCellList, ESC _ S CLI shader/transform protocol, 0x1C cast frames, and perf tracing.

## 0.4.0

> Note: This release has breaking changes.

 - **FIX**(shaders,cast,fterm): resolve Ship-It review defects and dart2wasm record crash.
 - **FEAT**(cast,fterm): persist Cloud Run IAP config and gcloud path override in Connect UI.
 - **BREAKING** **FEAT**(cast-protocol): add SpawnSessionFrame, allowSpawn flags, and subpath URI resolution.
 - **BREAKING** **FEAT**(termui,pty,cast): add GlyphCellList, ESC _ S CLI shader/transform protocol, 0x1C cast frames, and perf tracing.

## 0.3.0

 - Graduate package to a stable release. See pre-releases prior to this version for changelog entries.

## 0.3.0-dev.0

> Note: This release has breaking changes.

 - **BREAKING** **FIX**(cast_protocol,fterm,termui_audio): fix WebSocket close timer, upload dispose, and CI test races.
 - **BREAKING** **FEAT**(cast_protocol): add v8 KittyImageChunkFrame (0x1B) wire codec.

## 0.2.1

 - **FIX**(cast_protocol): require archive ^4.7.1 and pass throwOnError on inflate.

## 0.2.0

> Note: This release has breaking changes.

 - **FIX**(ci,test): stage ConPTY in Windows E2E tests and widen CLI subprocess startup timeouts.
 - **FEAT**(termui_cast): import protocol, server, caster CLI, and client core under apps/.
 - **BREAKING** **REFACTOR**(cast): remove in-app TLS plumbing and duplicate entrypoints.
 - **BREAKING** **FIX**(cast): harden protocol, relay, caster, and client_core in Wave 1.

