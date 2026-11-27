## 0.4.2

 - Update a dependency to the latest release.

## 0.4.1

 - **REFACTOR**(api): apply API review mitigations.
 - **REFACTOR**(api): apply API review mitigations.
 - **FIX**(review): address code review feedback - pass 1.
 - **FIX**(review): address code review feedback - pass 1.
 - **FIX**(termui_cast_server): log bound address and clickable HTTP URL on startup.
 - **FEAT**(cast-server,release): bundle gzip-only fterm WASM viewer with termui_cast_server (#423).

## 0.4.0

> Note: This release has breaking changes.

 - **FEAT**(cast-server): add loopback Host allowlist, static compression, subpath hosting, proxy auth, and spawn routing.
 - **BREAKING** **FEAT**(termui,pty,cast): add GlyphCellList, ESC _ S CLI shader/transform protocol, 0x1C cast frames, and perf tracing.

## 0.3.0

 - Graduate package to a stable release. See pre-releases prior to this version for changelog entries.

## 0.3.0-dev.0

> Note: This release has breaking changes.

 - **BREAKING** **FEAT**(cast_server): relay 0x1B Kitty image chunks zero-copy.

## 0.2.1

 - Update a dependency to the latest release.

## 0.2.0

> Note: This release has breaking changes.

 - **FEAT**(termui_cast): import protocol, server, caster CLI, and client core under apps/.
 - **BREAKING** **REFACTOR**(cast): remove in-app TLS plumbing and duplicate entrypoints.
 - **BREAKING** **FIX**(cast): harden protocol, relay, caster, and client_core in Wave 1.

