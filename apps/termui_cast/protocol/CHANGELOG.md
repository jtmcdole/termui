## 0.2.1

 - **FIX**(cast_protocol): require archive ^4.7.1 and pass throwOnError on inflate.

## 0.2.0

> Note: This release has breaking changes.

 - **FIX**(ci,test): stage ConPTY in Windows E2E tests and widen CLI subprocess startup timeouts.
 - **FEAT**(termui_cast): import protocol, server, caster CLI, and client core under apps/.
 - **BREAKING** **REFACTOR**(cast): remove in-app TLS plumbing and duplicate entrypoints.
 - **BREAKING** **FIX**(cast): harden protocol, relay, caster, and client_core in Wave 1.

