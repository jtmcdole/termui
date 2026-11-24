## 0.7.0

> Note: This release has breaking changes.

 - **FIX**(shaders,cast,fterm): resolve Ship-It review defects and dart2wasm record crash.
 - **FEAT**(fterm): add subpath WS, proxy auto-connect, sessionStorage resume, remote spawn UI, and What's New.
 - **FEAT**(fterm): add About-styled Web splash and Nerd Font v3 / COLRv1 emoji fonts.
 - **FEAT**(cast,fterm): persist Cloud Run IAP config and gcloud path override in Connect UI.
 - **FEAT**(fterm): add Ghostty GLSL shaders, GPU Driver picker, Perf HUD, tracing, and What's New.
 - **DOCS**(apps): add TermUI protocol SPEC.md and link from app READMEs.
 - **BREAKING** **FEAT**(cast-protocol): add SpawnSessionFrame, allowSpawn flags, and subpath URI resolution.

## 0.6.0

> Note: This release has breaking changes.

 - **FIX**(shaders,cast,fterm): resolve Ship-It review defects and dart2wasm record crash.
 - **FEAT**(fterm): add subpath WS, proxy auto-connect, sessionStorage resume, remote spawn UI, and What's New.
 - **FEAT**(fterm): add About-styled Web splash and Nerd Font v3 / COLRv1 emoji fonts.
 - **FEAT**(cast,fterm): persist Cloud Run IAP config and gcloud path override in Connect UI.
 - **FEAT**(fterm): add Ghostty GLSL shaders, GPU Driver picker, Perf HUD, tracing, and What's New.
 - **BREAKING** **FEAT**(cast-protocol): add SpawnSessionFrame, allowSpawn flags, and subpath URI resolution.

## 0.5.0

 - Graduate package to a stable release. See pre-releases prior to this version for changelog entries.

## 0.5.0-dev.1

 - **FEAT**(fterm): add blackout and highlight editor for feedback screenshots.
 - **FEAT**(fterm): add guided GitHub feedback modal with opt-in diagnostics.
 - **FEAT**(flutter,fterm): highlight per-row wrapped links and propagate local PTY wraps.

## 0.5.0-dev.0

> Note: This release has breaking changes.

 - **BREAKING** **FIX**(termui_pty,termui): encode legacy xterm modifiers and decode double-ESC/SS3 keys.
 - **BREAKING** **FIX**(cast_protocol,fterm,termui_audio): fix WebSocket close timer, upload dispose, and CI test races.
 - **BREAKING** **FIX**(client_core,fterm): reassemble 0x1B Kitty chunks and log share diagnostics.

## 0.4.0

> Note: This release has breaking changes.

 - **BREAKING** **FIX**(client_core,fterm): preserve Kitty placeholder IDs across theme contrast and cursors.
 - **BREAKING** **FIX**: replace restricted audio assets and fix POSIX CI test races.
 - **BREAKING** **FEAT**(fterm): add splash About overlay and open-source licenses viewer.
 - **BREAKING** **FEAT**(selection): root scrollback selection and migrate pointer gestures to HSM.

## 0.3.0

> Note: This release has breaking changes.

 - **FEAT**(fterm): add portable auto-update engine and single-binary swapper.
 - **DOCS**(fterm): document appBuildName versioning and immutable release flow.
 - **BREAKING** **FIX**(fterm): parallelize local PTY teardown and canonicalize launch file flags.
 - **BREAKING** **FEAT**(fterm): wire auto-update settings controls, badges, and exit hooks.
 - **BREAKING** **BUILD**(fterm): set org.mcdole.fterm bundle IDs and stage immutable release manifests.

## 0.2.2

 - Update a dependency to the latest release.

## 0.2.1

 - **FEAT**(fterm): add persistent login shell and custom shell overrides.
 - **FEAT**(fterm): add WSLg MediaQuery text scaling, font zoom, and pillNotifier.

## 0.2.0

> Note: This release has breaking changes.

 - **FIX**(fterm): download and await ConPTY sidecar on Windows shell launch.
 - **FEAT**(ci,docs): add Melos fterm release prepare workflow and unsigned install docs.
 - **FEAT**(fterm): import fterm desktop mux and WASM web client under apps/fterm.
 - **BREAKING** **FEAT**(fterm): remediate security, performance, lifecycle, and UI defects.

