## 0.8.1

 - **FEAT**(fterm): refresh What's New cards and add minor-release reminder.

## 0.8.0

> Note: This release has breaking changes.

 - **FEAT**(fterm): add VS Code-style Command Palette with scrollback jump and search (#486).
 - **FEAT**(fterm): overhaul Settings modal with Blender-style sidebar, panels, and search (#485).
 - **FEAT**(fterm): wire HTTP automation v1 router, OpenAPI spec, ConPTY fix, and sizzle director (#483).
 - **FEAT**(fterm): add loopback HTTP automation server, screen search, and Settings tab (#482).
 - **FEAT**(fterm): add automation driver contracts, CLI flags, and Win32 window bounds (#481).
 - **BREAKING** **REFACTOR**(fterm): unify command, setting, and shortcut descriptors (#487).

## 0.7.0

> Note: This release has breaking changes.

 - **REFACTOR**(api): apply API review mitigations.
 - **FIX**(review): address code review feedback - pass 1.
 - **FIX**(fterm): opt into 500ms undo burst coalescing in ShaderEditorController.
 - **FIX**(fterm): use default cell background in shader editor so BG preview shows.
 - **FIX**(fterm): surface runtime GPU link errors in open shader editors.
 - **FIX**(fterm): pass through unhandled Meta/Cmd chords by default on Web and macOS (#465).
 - **FEAT**(fterm): add Save As workflow and selection highlight to shader editor.
 - **FEAT**(fterm): enable GpuFrameWatchdog warmup for CLI and editor shaders.
 - **FEAT**(fterm): add escape pill above opaque FG previews lacking iChannel0.
 - **FEAT**(fterm): add dirty shader tab highlight and right-click context menu.
 - **FEAT**(fterm): render shader editor pane leaves and E-Stop recovery pill.
 - **FEAT**(fterm): add shader editor shortcut and settings overlay entry points.
 - **FEAT**(fterm): track ShaderEditorPane lifecycle in workspace controller.
 - **FEAT**(fterm): add in-process ShaderEditorPane host.
 - **FEAT**(fterm): add pure termui ShaderEditorView widget.
 - **FEAT**(fterm): add shader editor controller with debounced compile.
 - **FEAT**(fterm): bind Ctrl+Shift+F6 and Ctrl+\ 0 hotkeys to shader E-Stop.
 - **FEAT**(fterm): add shader emergency stop state and watchdog escalation.
 - **FEAT**(fterm): add chord recorder, platform presets, and collision hints to Keyboard Settings (#471).
 - **FEAT**(fterm): add Ignored Chords list and validated text input to Keyboard Settings tab (#470).
 - **FEAT**(fterm): add General and Keyboard Settings tabs with Meta key policy and toggles (#469).
 - **FEAT**(fterm): dispatch configured passthroughShortcuts through host and early-F12 handlers (#468).
 - **FEAT**(fterm): add compact KeyChord codec and persist passthroughShortcuts in FtermPreferences (#467).
 - **FEAT**(fterm): add configurable FtermMetaKeyMode preference for Meta/Cmd key policy (#466).
 - **FEAT**(cast-server,release): bundle gzip-only fterm WASM viewer with termui_cast_server (#423).
 - **DOCS**(fterm): document GLSL shader editor and Emergency Stop controls.
 - **BREAKING** **FIX**(fterm): address all 22 PR #475 shader editor review findings.
 - **BREAKING** **FEAT**(termui_flutter): add HostShortcutResult and TerminalMetaKeyPolicy to TerminalImeClient (#464).

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

