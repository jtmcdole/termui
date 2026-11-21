# Rendering & Shader Plans: Architecture Decisions & Open Checks

This document records resolved design decisions and remaining build checks for the three-step rendering and shader roadmap:

1. [step1_optimized_draw_raw_atlas_plan.md](step1_optimized_draw_raw_atlas_plan.md): Zero-allocation `Buffer` storage (`GlyphCellList`), `Renderer` code-point diffing, and row-cached `drawRawAtlas` staging.
2. [step2_fragment_shader_effects_issue_364_plan.md](step2_fragment_shader_effects_issue_364_plan.md): Unified Desktop (`flutter_gpu` + bundled `impellerc`) and Web (WebGL2) custom shader engine with Ghostty/Kitty parity and live hot-reload (Issue #364).
3. [step3_cli_artistic_shaders_and_transforms_plan.md](step3_cli_artistic_shaders_and_transforms_plan.md): CLI per-cell transforms, 120 Hz host `CellTween` interpolation, scoped `ShaderRegion` effects ("word on fire"), `termui` widgets, `ESC _ S` trust policy, and negotiated `termui_cast` `0x1C` relay forwarding.

---

## Resolved Decisions

### Step 1: Optimized `drawRawAtlas`

| Topic | Decision | Rationale |
| :--- | :--- | :--- |
| `Buffer.characters` storage contract | Keep `Buffer.characters` typed as `List<String>` via `GlyphCellList extends ListBase<String>`. | Exposes read-only `glyphCodes` (`codes.asUnmodifiableView()`) and routes bulk writes through `GlyphCellList.fillCodeRange` / `copyCellsFrom`. Cross-buffer copies remap `0x80000000 \| id` clusters safely. |
| Cluster compaction cadence | Compact on `clear()`, `resize()`, and via full-buffer liveness scan when `_clusterStrings.length > max(1024, liveEstimate * 2)`. | Keeps long-lived scrolling logs and TUI games bounded even when clusters are deduplicated or overwritten in bulk. |
| `ScrollbackLine` & `Renderer` compatibility | Keep `ScrollbackLine({required List<String> characters})` compatible plus `fromGlyphCells`; compare `glyphCodes` in `Renderer._isCellChanged`. | Prevents breaking `remote_terminal_port.dart:539` and avoids allocating two `String`s per non-ASCII cell per frame in pure-Dart TUI apps. |
| Per-cell overrides & rollback | Add `Uint8List? cellOverrideMask` covering all foreground/decoration passes, plus `bool enableRowCache = true` on `TerminalSurface`. | Lets Step 3 hide transformed or shader-replaced glyphs (including emoji, italic, fallback, and ligatures) and gives a runtime rollback lever. |

### Step 2: Custom User Shaders & Runtime Compilation (Issue #364)

| Topic | Decision | Rationale |
| :--- | :--- | :--- |
| Cross-platform shader backend | Build `TerminalShaderBackend` in `packages/termui_flutter` with three states: `flutterGpu`, `webGl2`, and `disabled`. | Desktop uses Impeller (`TRUE` by default on macOS, Linux, and Windows in Flutter 3.50) + `flutter_gpu` + `impellerc`. Web uses `OffscreenCanvas` WebGL2 (`transferToImageBitmap` + `ui_web.createImageFromImageBitmap`). Skia Desktop and software rendering are unsupported and report `disabled` (`glsl=0` on `a=query`). Impeller on Web (WIMP) remains experimental and can plug into `TerminalShaderBackend` later. |
| SDK constraints & Melos | Bump `termui_flutter` and `apps/fterm` to Flutter `>=3.50.0` / Dart `>=3.13.0`, and remove `melos.command.bootstrap.environment` from root `pubspec.yaml`. | Prevents `melos bootstrap` from reverting SDK floors. Verified `flutter pub publish --dry-run` passes with `0 warnings` for `flutter_gpu: sdk: flutter`, and full-workspace `dart pub get` resolves on Dart `3.14.0` (while standalone `termui` / `termui_pty` pub consumers stay on Dart `>=3.11.0`). |
| Desktop `impellerc` distribution & invocation | Bundle platform `impellerc` (`impellerc.exe` on Windows, `5.8` to `11 MB`) in `fterm` release archives; invoke with inline JSON (`--shader-bundle='<json>'`), no platform flags, and no `runtime_effect.glsl`. | Verified `--shader-bundle` parses inline JSON and emits all 5 GPU targets in one bundle. On macOS, ad-hoc sign `Contents/Helpers/impellerc` and re-sign `fterm.app` (`codesign --force --sign -`) so `update_service_io.dart`'s `codesign --verify --deep --strict` passes without an Apple cert. |
| Ghostty compatibility & hot-reload | Match Ghostty's verbatim `shadertoy_prefix.glsl` (`vec3 iPalette[256]`, `vec3 iForegroundColor`/`iBackgroundColor`, `(x, y, w, h)` cursor rects) with per-backend sampler V-flips and reflection-guarded uniform binds. | Lets users drop in community Ghostty shaders unchanged. Use `Ctrl+Shift+F5` across all desktop platforms for manual reload (avoiding `Ctrl+Shift+,` Settings collision on Linux/Windows) alongside `~/.config/fterm/shaders/` file watching. |
| Frame pacing & compile timeout | Use `gpu.GpuImageSurface` (`acquireNextFrame`) for Desktop outputs, synchronous background passes, single-flight latest-wins async staging for `iChannel0` passes, and an `8s` user-shader compile timeout. | Avoids awaiting inside `CustomPainter.paint()`, prevents overwriting in-flight Flutter textures, and handles `64 KiB` multi-target `impellerc` builds. |

### Step 3: CLI Shaders, Scoped Regions & Per-Cell Transforms

| Topic | Decision | Rationale |
| :--- | :--- | :--- |
| Scoped effects ("word on fire") | Use region-based `ShaderRegion` (`List<Rect> sourceRects`, `CellPadding`, blend stage, `prevFrameKey`), capped at `max_regions=8` per pane, rendering `uGlyphMask` GPU-to-GPU inside `DirectTerminalShaderBackend` (expanded up to `512x512` logical px for moving glyphs) with `PictureRecorder` + `renderPassesAsync` retained for canvas-fallback frames. | Eliminates WebGL2 readback and async lag, lets full-pane FG shaders post-process `overGlyphs` effects, bounds per-frame FBO cost, and keeps regions working alongside ligatures. |
| Per-cell spatial transforms & tweens | Use a lazy sparse `CellTransformTable` with finite-duration (`<= 30s`) `CellTween` interpolation (`easing`, `fromCurrent`, `clearOnFinish`) rather than hardcoded ballistic physics. Direct GPU renders full non-uniform scale and `a_extra.w` rotation in one instanced pass; Canvas fallback uses uniform `drawRawAtlas` only (no `drawVertices`). Strictly clipped to the terminal pane viewport (no 4-cell cage); hit-testing remains logical-grid-anchored in v1. | Keeps host animation general-purpose (CLI apps drive arbitrary physics such as gravity or explosions at 20-30 Hz while the host interpolates at 120 Hz), guarantees the ticker stops when tweens finish, and keeps pane-viewport clipping as the security boundary. |
| APC wire grammar & lifecycle | Use `/` to separate wrapped `rects` (`rects=x:y:w:h/...`), reserve `;` for base64 payload, advertise `max_regions=8` in `a=query`, use a chunkable `64`-byte `a=xforms` stride (up to `4,096` live transforms), and scope metadata per screen buffer (`_primaryBuffer` vs `_altBuffer`). | Prevents `;` parsing collisions, supports full-screen shatters within `<= 64 KiB` wire frames, and cleans up on `?47`/`?1047`/`?1049`, scroll, resize, and `_viewportOffset` scrollback. |
| CLI security policy, full-pane stacking & watchdog | Use 4-level `CliShaderPolicy` (`disabled`, `presetsAndTransforms`, `promptCustomGlsl`, `allowLocalCustomGlsl`), `CliFullPaneShaderMode` (default `cliBeforeUser` so user CRT/bloom builds on top, plus `cliReplacesUser` and `askOnConflict`), `<= 4` pending SHA-256 prompts, and a best-effort GPU watchdog that quarantines only the offending custom CLI shader ID on that pane. | Protects panes from GPU hangs, banner floods, and TOCTOU swaps while preserving CLI artistic intent, built-in presets, and user post-processing. |
| Remote `termui_cast` `0x1C` forwarding | Negotiate a `shaderFrames` capability bit in `AuthAcceptedFrame` / `SubscribeSessionFrame`, flush pending `0x1C` frames alongside `BufferDeltaFrame` on the same 16ms coalesce tick (coalescing redundant uniforms/xforms), relay via `_fanOutSynchronizedFrame`, replay state on `RequestKeyframeFrame`, and enforce per-session budgets. | Prevents disconnecting older relays/viewers, keeps remote text cells synchronized with their matching regions/transforms, and prevents `a=define`/`a=reset` drops under backpressure. |

---

## Remaining Implementation Checks

These CI and benchmark checks do not block plan approval and execute during Step 2:

1. Smoke-test `project.set_enable_flutter_gpu(true);` in `apps/fterm/windows/runner/main.cpp` on Windows CI (verified present in Flutter 3.50 `dart_project.h:158`).
2. Verify macOS ad-hoc bundle signing (`codesign --verify --deep --strict fterm.app`) in `release-fterm.yml` after copying `Contents/Helpers/impellerc`.
3. Prototype and benchmark the WebGL2 `ui.Image` -> `texImage2D` upload round-trip at 1080p/4K under Chrome CanvasKit and Skwasm during Step 2 Track 2B.
4. Run `flutter build apk --debug` after adding `flutter_gpu: sdk: flutter` to `packages/termui_flutter` to verify Android/iOS consumers stay green.
