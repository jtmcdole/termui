## 0.2.0

> Note: This release has breaking changes.

 - **FIX**(ci,test): stage ConPTY in Windows E2E tests and widen CLI subprocess startup timeouts.
 - **FEAT**(termui_cast): import protocol, server, caster CLI, and client core under apps/.
 - **BREAKING** **REFACTOR**(cast): remove in-app TLS plumbing and duplicate entrypoints.
 - **BREAKING** **REFACTOR**(client_core): remove unused pure-TUI viewer stack.
 - **BREAKING** **FIX**(cast): harden protocol, relay, caster, and client_core in Wave 1.

