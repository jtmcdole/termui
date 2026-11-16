# Rendering & Shader Plans: Open Questions

Tracking decisions to resolve before executing [step1_optimized_draw_raw_atlas_plan.md](step1_optimized_draw_raw_atlas_plan.md) and [step2_fragment_shader_effects_issue_364_plan.md](step2_fragment_shader_effects_issue_364_plan.md) (GitHub Issue #364).

## Step 1: Optimized `drawRawAtlas`

1. **`Buffer.characters` Storage Contract (`GlyphCellList` vs breaking `Uint32List`):**
   - *Proposed*: Keep `Buffer.characters` typed as `List<String>` via `GlyphCellList extends ListBase<String>` backed by `Uint32List glyphCodes`, while migrating hot loops to `glyphCodes` / `copyCellsFrom`.
   - *Alternative*: Break `Buffer.characters` into `Uint32List` directly (eliminates wrapper class, but requires updating every test and external caller).
2. **Cluster Compaction Cadence:**
   - *Proposed*: Compact the per-`Buffer` multi-codepoint cluster table automatically on `Buffer.clear()` and `Buffer.resize()`.
   - *Question*: Should long-lived buffers that scroll continuously via `setRange` without `clear()` also trigger lazy compaction when dead cluster entries exceed a threshold (e.g., 1,024 entries)?

## Step 2: Custom `FragmentShader` Effects & CLI Shader Protocol (#364)

1. **Default Value for `allowCliShaders` (`ESC _ S`):**
   - *Option A (Proposed)*: Default `allowCliShaders` to `false` globally in `FtermPreferences` with an explicit toggle in `_SettingsOverlay`.
   - *Option B*: Default to `true` for local desktop shells (`LocalPaneHost`) and `false` for remote `termui_cast` relay panes.
2. **Remote Relay Forwarding of `ESC _ S` in `termui_cast`:**
   - *Option A (Proposed)*: Wire `TerminalPort.addShaderListener` in Wave 2 so `RemoteTerminalPort` conforms, but defer binary wire framing (`termui_cast_protocol`) to a follow-up.
   - *Option B*: Include `ESC _ S` wire messages in `termui_cast_protocol` and `termui_cast_server` in v1 so casters can drive shaders on remote viewers.
3. **User-Authored `.frag` Compilation Workflow:**
   - *Option A (Proposed)*: Ship 5 AOT-compiled `.frag` presets + JSON parameter profiles (`~/.config/fterm/shaders/*.json`) + `utils/compile_user_shader.dart` for Desktop `.frag` authors (since `dart:ui` has no runtime GLSL compiler and bundling `impellerc` adds 30+ MB).
   - *Option B*: Bundle `impellerc` or a platform-specific compiler plugin in Desktop builds to compile arbitrary `.frag` files dropped into `~/.config/fterm/shaders/` at runtime.
4. **Web Fallback for Pixel-Sampling Post-Process Shaders (`crt_lottes`, `phosphor_glow`):**
   - *Option A (Proposed)*: Keep `ImageFilter.shader` Desktop-only (`Impeller`), run `scanline_overlay.frag` and `cursor_glow.frag` as foreground blend overlays on Web, and show `ShaderBackendStatus.unsupportedOnWeb` in Settings.
   - *Option B*: Render the terminal into an offscreen `PictureRecorder.toImage()` when a post-process shader is active on Web so `FragmentShader` can sample it (adds per-frame GPU readback/copy overhead on Web).
