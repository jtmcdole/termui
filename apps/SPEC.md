# TermUI Protocol Specification

This document specifies the first-party terminal escape sequences, custom host queries, and chunked file transfer framing implemented across `termui`, `termui_pty`, `termui_audio`, `termui_flutter`, `termui_cast`, and `fterm`.

Third-party protocols supported by `termui_pty` follow their upstream specifications. These include Kitty Graphics (`ESC _ G`), Kitty Keyboard (`CSI ... u`), and Kitty Notifications (`OSC 99`).

## 1. Common APC Framing

First-party in-band extensions use ECMA-48 Application Program Command (APC) sequences.

### Wire Envelope

```text
APC <prefix> <control> [ ; <payload> ] ST
```

| Element | Encoding | Notes |
| :------ | :------- | :---- |
| `APC` | `0x1B 0x5F` (`ESC _`) or C1 `0x9F` | Starts an APC sequence (`0x9F` applies to PTY `stdout`; host replies on `stdin` use `ESC _`). |
| `<prefix>` | Single ASCII letter (`A` or `S`) | Selects the protocol. |
| `<control>` | Comma-separated `key=value` pairs | Whitespace around keys and values is trimmed. No mandatory space follows `<prefix>`. |
| `;` | `0x3B` | Separates `<control>` from `<payload>`. Reserved strictly for payload separation. |
| `<payload>` | Standard Base64 (RFC 4648) | Optional. Whitespace inside `<payload>` is ignored before decoding. |
| `ST` | `0x1B 0x5C` (`ESC \`), `0x9C`, or `0x07` (`BEL`) | Terminates the sequence (`0x9C` applies to PTY `stdout`; host replies on `stdin` use `ESC \` or `BEL`). |

### Parser Rules and Transport Safety

- `CAN` (`0x18`) and `SUB` (`0x1A`) cancel an in-progress APC sequence and return the parser to the ground state.
- The outer `AnsiParser` caps any single APC sequence at `1,400,000` characters. Individual protocols enforce tighter per-frame limits.
- Tmux DCS passthrough (`ESC P tmux; ... ESC \`) is unwrapped for embedded APC and OSC sequences when inner `ESC` bytes are doubled.
- Host-to-client reply actions (`a=waver` under `APC A` and `a=caps` under `APC S`) are ignored when received on PTY `stdout`. This prevents echo loops under canonical TTY line disciplines.
- Host replies on PTY `stdin` (`a=waver`, `a=caps`) must use 7-bit `ESC _` and `ESC \` (or `BEL`). In `a=waver` replies, `a=waver` must appear immediately after `A` with no leading whitespace.
- Malformed, out-of-range, or non-finite (`NaN`, `Infinity`) commands are ignored silently unless a reply format is defined.

---

## 2. Audio Protocol (`ESC _ A`)

The `APC A` protocol lets CLI applications synthesize tones, play audio files, stream long audio, configure DSP mixing buses, and sample the host mixer waveform.

Reference implementations:
- Decoder: `packages/termui_pty/lib/src/audio_apc_handler.dart`
- Encoder: `packages/termui_audio/lib/src/apc_audio_encoder.dart`

### Identifier and Numeric Conventions

- Explicit wire IDs (`i`, `b`, `s`, `st`, `q`) must be positive 31-bit integers in `1 .. 2,147,483,647` (`0x7FFFFFFF`).
- Boolean flags accept `1` / `true` and `0` / `false` (case-insensitive).
- Volumes clamp to `[0.0, 1.0]`. Stereo pan clamps to `[-1.0, 1.0]`.
- Playback speed must be finite and `> 0`, and clamps to `[0.125, 8.0]`.
- Durations are finite milliseconds `>= 0`. General transport durations clamp to `86,400,000` ms (24 hours).

### 2.1 Synthetic Tones (`a=tone`)

Triggers a short synthesized waveform on the host audio engine.

```text
ESC _ A a=tone[,w=<wave>],f=<hz>,d=<ms>[,v=<vol>][,p=<pan>][,b=<busId>]; ST
```

| Key | Required | Type / Range | Default | Description |
| :-- | :------- | :----------- | :------ | :---------- |
| `w` | No | Enum | `sine` | Waveform: `sine` (alias `sin`), `square`, `saw`, `triangle`, `bounce`, `jaws`, `humps`, `fsquare`, `fsaw`. |
| `f` | Yes | Float `> 0`, clamped `[20, 20000]` | - | Frequency in Hz. |
| `d` | Yes | Float `>= 0`, clamped `[0, 10000]` | - | Duration in milliseconds. |
| `v` | No | Float `[0.0, 1.0]` | `0.8` | Playback volume. |
| `p` | No | Float `[-1.0, 1.0]` | `0.0` | Stereo pan (`-1` left, `0` center, `1` right). |
| `b` | No | `1 .. 0x7FFFFFFF` | none | Target mixing bus ID. |

Example:

```text
ESC _ A a=tone,w=sine,f=440,d=250,v=0.8,p=0; ST
```

### 2.2 In-Memory Audio Clips (`a=clip`)

Uploads a complete `wav`, `ogg`, or `mp3` file in one or more Base64 chunks (`<= 2 MiB` decoded), or starts playback of an open audio stream.

#### Chunked Clip Upload

First frame:

```text
ESC _ A a=clip[,i=<clipId>][,fmt=<fmt>][,v=<vol>][,p=<pan>][,l=<0|1>][,s=<ms>][,b=<busId>][,m=<0|1>];<base64> ST
```

Continuation frames (when prior frame set `m=1`):

```text
ESC _ A [i=<clipId>,]m=<0|1>;<base64> ST
```

| Key | Required | Type / Range | Default | Description |
| :-- | :------- | :----------- | :------ | :---------- |
| `i` | No | `1 .. 0x7FFFFFFF` | auto | Clip identifier. If omitted on the first frame, the decoder assigns an internal ID (`>= 0x80000001`). Continuation frames may omit `i` to target the most recent active upload. |
| `fmt` | No | `wav`, `ogg`, `mp3` | `wav` | Audio container format. Aliases `c` and `f` are accepted. |
| `v` | No | Float `[0.0, 1.0]` | `1.0` | Initial playback volume. |
| `p` | No | Float `[-1.0, 1.0]` | `0.0` | Initial stereo pan. |
| `l` | No | Bool (`0`/`1`) | `0` | Loop playback until stopped. |
| `s` | No | Float `>= 0` | `0` | Initial start offset in milliseconds. |
| `b` | No | `1 .. 0x7FFFFFFF` | none | Target mixing bus ID. |
| `m` | No | `0` or `1` | `0` | Chunk continuation flag. `1` indicates more chunks follow; `0` finalizes and plays the clip. |

Upload bounds and ordering:
- Recommended chunk size is `4,096` Base64 characters per frame.
- Maximum decoded size per clip is `2 MiB` (`2,097,152` bytes).
- Up to `8` concurrent incomplete clip uploads are tracked. A 9th upload evicts the oldest incomplete upload.
- Any `a=update` received for an in-flight `clipId` is buffered and applied automatically when the final `m=0` chunk finishes decoding.

#### Stream-Backed Clip Playback

Starts playback from a previously opened `a=stream` buffer without uploading clip bytes:

```text
ESC _ A a=clip,i=<clipId>,st=<streamId>[,v=<vol>][,p=<pan>][,l=<0|1>][,s=<ms>][,b=<busId>]; ST
```

### 2.3 Pass-Through Audio Streaming (`a=stream`)

Streams audio up to `16 MiB` compressed wire bytes into a host ring buffer (up to `128 MiB` decoded PCM).

#### Open Stream (`op=open`)

```text
ESC _ A a=stream,op=open,s=<streamId>[,max=<bytes>][,rel=<0|1>][,buf=<ms>][,sr=<hz>][,ch=<1|2>]; ST
```

| Key | Required | Type / Range | Default | Description |
| :-- | :------- | :----------- | :------ | :---------- |
| `s` | Yes | `1 .. 0x7FFFFFFF` | - | Stream identifier. |
| `max` | No | `1 .. 134,217,728` | `4,194,304` | Maximum decoded PCM buffer size in bytes (`<= 128 MiB`). |
| `rel` | No | Bool (`0`/`1`) | `0` | Release consumed samples from the ring buffer. |
| `buf` | No | Float `[0, 60000]` | `500` | Pre-playback buffering target in milliseconds. |
| `sr` | No | `1 .. 384,000` | `48000` | Sample rate in Hz. |
| `ch` | No | `1` or `2` | `2` | Channel count (`1` mono, `2` stereo). |

#### Feed Chunk (`op=chunk`)

```text
ESC _ A a=stream,op=chunk,s=<streamId>,seq=<seq>;<base64> ST
```

- `seq` is a monotonic integer in `0 .. 0x7FFFFFFF`.
- The encoder aligns chunks to `3,072` raw bytes (`4,096` Base64 characters) per frame.
- Each decoded chunk must be non-empty and `<= 2 MiB`.

#### Close Stream (`op=end`)

```text
ESC _ A a=stream,op=end,s=<streamId>[,seq=<seq>]; ST
```

Signals end-of-stream so the host drains remaining buffered audio cleanly.

### 2.4 Live Voice Updates (`a=update`) and Stop (`a=stop`)

Updates one or more parameters on an active or in-flight voice:

```text
ESC _ A a=update,i=<clipId>[,v=<vol>][,p=<pan>][,s=<ms>][,pa=<0|1>][,sp=<rate>][,pp=<0|1>][,fv=<v>:<ms>][,fs=<rate>:<ms>][,st=<ms>]; ST
```

| Key | Format / Range | Description |
| :-- | :------------- | :---------- |
| `i` | `1 .. 0x7FFFFFFF` | Target clip ID (required). |
| `v` | Float `[0.0, 1.0]` | Immediate volume. Cancels any pending volume fade on an in-flight upload. |
| `p` | Float `[-1.0, 1.0]` | Stereo pan. |
| `s` | Float `>= 0` | Seek position in milliseconds. |
| `pa` | Bool (`0`/`1`) | Pause (`1`) or resume (`0`). |
| `sp` | Float `> 0`, clamped `[0.125, 8.0]` | Relative playback speed. Cancels any pending speed fade on an in-flight upload. |
| `pp` | Bool (`0`/`1`) | Preserve pitch when changing speed. |
| `fv` | `<target>:<durMs>` | Fade volume to `target` (`[0.0, 1.0]`) over `durMs` milliseconds. |
| `fs` | `<target>:<durMs>` | Fade playback speed to `target` (`> 0`, clamped `[0.125, 8.0]`) over `durMs` milliseconds. |
| `st` | Float `>= 0` | Schedule automatic stop after `st` milliseconds. |

At least one update field besides `i` must be present.

To stop playback:

```text
ESC _ A a=stop[,i=<clipId>]; ST
```

Omitting `i` stops all active voices.

### 2.5 Mixing Buses and DSP Filters (`a=bus`)

Creates mixing buses and controls attached DSP filters.

```text
ESC _ A a=bus,op=<op>,b=<busId>[,v=<val>][,ft=<filterId>][,pm=<paramId>][,d=<ms>]; ST
```

| `op` | Required Extra Keys | Description |
| :--- | :------------------ | :---------- |
| `create` | none | Creates mixing bus `b`. |
| `destroy` | none | Destroys mixing bus `b`. |
| `vol` | `v` (`[0.0, 1.0]`) | Sets bus master volume. |
| `attach` | `ft` (`0 .. 11`) | Attaches DSP filter `ft` to bus `b`. |
| `param` | `ft` (`0..11`), `pm` (`0..66`), `v` (finite float) | Sets filter parameter `pm` immediately. |
| `fade` | `ft` (`0..11`), `pm` (`0..66`), `v` (finite float), `d` (`>= 0` ms) | Ramps filter parameter `pm` to `v` over `d` ms. |

#### DSP Filter (`ft`) and Parameter (`pm`) Map

| `ft` | Filter | Parameter Indices (`pm`) |
| :--- | :----- | :----------------------- |
| `0` | Biquad Resonant | `0` wet, `1` type, `2` frequency, `3` resonance |
| `1` | Echo | `0` wet, `1` delay, `2` decay, `3` filter |
| `2` | Lofi | `0` wet, `1` sampleRate, `2` bitDepth |
| `3` | Flanger | `0` wet, `1` delay, `2` frequency |
| `4` | Bassboost | `0` wet, `1` boost |
| `5` | WaveShaper | `0` wet, `1` amount |
| `6` | Robotize | `0` wet, `1` frequency, `2` waveform |
| `7` | Freeverb | `0` wet, `1` freeze, `2` roomSize, `3` damp, `4` width |
| `8` | Pitch Shift | `0` wet, `1` shift, `2` semitones |
| `9` | Limiter | `0` wet, `1` threshold, `2` outputCeiling, `3` kneeWidth, `4` releaseTime, `5` attackTime |
| `10` | Compressor | `0` wet, `1` threshold, `2` makeupGain, `3` kneeWidth, `4` ratio, `5` attackTime, `6` releaseTime |
| `11` | Parametric EQ | `0` wet, `1` stftWindowSize, `2` numBands, `3..66` bandGain (`pm - 3`) |

### 2.6 Waveform Capture Query (`a=wave` / `a=waver`)

CLI apps can request a 256-sample snapshot of the host audio output for live visualizers.

Query (application to host):

```text
ESC _ A a=wave,q=<requestId>; ST
```

Reply (host to application on PTY `stdin`):

```text
ESC _ A a=waver,q=<requestId>;<base64> ST
```

- `q` is a positive 31-bit correlation ID (`1 .. 0x7FFFFFFF`).
- When audio data is available, `<base64>` decodes to `1,024` bytes containing `256` little-endian IEEE-754 `float32` samples. Non-finite samples are replaced with `0.0`.
- When visualization is inactive or silent, the host emits an empty payload (`ESC _ A a=waver,q=<requestId>; ST`), which clients interpret as `256` zero samples.

---

## 3. Shader and Cell Transform Protocol (`ESC _ S`)

The `APC S` protocol lets CLI applications query GPU capabilities, upload Ghostty-compatible Shadertoy GLSL shaders, and activate region or full-pane passes. It also supports live uniform updates and per-cell spatial transforms with 120 Hz host tweens.

Reference implementations:
- Decoder: `packages/termui_pty/lib/src/shader_apc_handler.dart`
- Encoder: `packages/termui/lib/terminal/shader_apc_encoder.dart`
- Transform binary codec: `packages/termui/lib/ui/cell_transform.dart`
- GLSL shim: `packages/termui_flutter/lib/src/rendering/shadertoy_glsl_shim.dart`

### Common Bounds

| Limit | Value |
| :---- | :---- |
| Max single APC wire frame | `64 KiB` (`65,536` characters) |
| Identifier grammar (`id`, `s`, `preset`) | `^[A-Za-z0-9_.-]{1,64}$` |
| Max decoded GLSL source per `a=define` | `32 KiB` (`32,768` UTF-8 bytes) |
| Max live custom GLSL slots per pane | `16` |
| Max concurrent pending `a=define` uploads | `4` (oldest evicted) |
| Max active scoped regions per pane | `8` |
| Max source rectangles per region | `32` |
| Max bleed padding per edge | `8` cells (`0..8`) |
| Max live cell transforms per pane | `4,096` |
| User uniform floats (`p0..p7`) | `8` floats, clamped to `[-16.0, 16.0]` |

### 3.1 Capability Query (`a=query` / `a=caps`)

Applications should probe shader support before uploading GLSL or activating effects.

Query (application to host):

```text
ESC _ S a=query ST
```

Reply (host to application on PTY `stdin`):

```text
ESC _ S a=caps,backend=<backend>,glsl=<0|1>,xform=<0|1>,region=<0|1>,max_slots=<n>,max_regions=<n> ST
```

| Field | Values | Description |
| :---- | :----- | :---------- |
| `backend` | `flutter_gpu`, `webgl2`, `disabled` | Active GPU shader backend. |
| `glsl` | `0` or `1` | Whether custom `a=define` GLSL uploads are permitted by host policy. |
| `xform` | `0` or `1` | Whether per-cell transforms (`a=xform` / `a=xforms`) are supported. |
| `region` | `0` or `1` | Whether scoped region shaders (`a=region`) are supported. |
| `max_slots` | Integer `>= 0` | Maximum custom GLSL slots allowed per pane (typically `16`, or `0` when policy is `disabled`). |
| `max_regions` | Integer `>= 0` | Maximum active regions allowed per pane (typically `8`, or `0` when policy is `disabled`). |

### 3.2 Defining Custom GLSL Shaders (`a=define`)

Uploads a Ghostty Shadertoy GLSL fragment shader into a named pane slot. Payloads exceeding one frame are split across `m=1` chunks and finished with `m=0`.

First frame:

```text
ESC _ S a=define,id=<slotId>[,persist=<0|1>],m=<0|1>;<base64-utf8> ST
```

Continuation frames:

```text
ESC _ S a=define,id=<slotId>,m=<0|1>;<base64-utf8> ST
```

- Decoded bytes must be non-empty, valid UTF-8, `<= 32 KiB`, and free of NUL (`0x00`) bytes.
- Setting `persist=1` requests a previous-frame feedback texture (`iPrevFrame`) for the slot.
- Re-defining an existing `id` replaces that slot without consuming an extra slot toward the 16-slot cap.
- The reference encoder chunks raw UTF-8 bytes at `4,095` bytes per frame (`4,096` rounded down to a multiple of 3, giving `5,460` Base64 chars).

#### GLSL Contract and Uniforms

Custom shaders implement the Shadertoy entry point:

```glsl
void mainImage(out vec4 fragColor, in vec2 fragCoord)
```

The host shim compiles the source for Impeller GLSL 460 (`flutter_gpu`) and GLSL ES 3.00 (`webgl2`). Both targets share a `4,416`-byte `std140` uniform block (`TerminalUniforms`) with automatic UV Y-flip normalization:

- Preprocessor directives `#version` and `#include` are rejected.
- Optional comment hint `// @fterm-stage: bg | fg | both` tells the host which pipeline stage the shader targets.
- Samplers:
  - `iChannel0`: rendered terminal frame (full-pane passes) or tight glyph mask `uGlyphMask` (scoped region passes).
  - `iChannel1`: host wallpaper or auxiliary texture when configured.
  - `iPrevFrame`: previous pass output when `persist=1`.
- Built-in uniforms:
  - Timing and viewport: `vec3 iResolution`, `float iTime`, `float iTimeDelta`, `int iFrame`, `float iFrameRate`, `vec4 iDate`, `vec4 iMouse`, `vec3 iChannelResolution[4]`.
  - Palette and colors: `vec3 iPalette[256]`, `vec3 iBackgroundColor`, `vec3 iForegroundColor`.
  - Cursor and focus: `vec4 iCurrentCursor`, `vec4 iPreviousCursor`, `vec4 iCurrentCursorColor`, `vec4 iPreviousCursorColor`, `vec4 iCursorColor`, `int iCurrentCursorStyle` (`CURSORSTYLE_BLOCK = 0`, `CURSORSTYLE_BAR = 1`, `CURSORSTYLE_UNDERLINE = 2`, `CURSORSTYLE_BLOCK_HOLLOW = 3`), `float iTimeCursorChange`, `int iCursorVisible`, `int iFocus`, `float iTimeFocus`.
  - TermUI extensions: `vec4 iRegionRect`, `vec2 iCellSize`, `vec4 uParams0` (`p0..p3`), `vec4 uParams1` (`p4..p7`).

#### Host Trust Policy and Quarantine

Because `a=define` runs untrusted GPU code, conforming hosts enforce user trust policies:
- `disabled`: ignores all `APC S` visual effects and reports `backend=disabled,glsl=0,xform=0,region=0,max_slots=0,max_regions=0`. If no GPU backend is active under another policy, the host may report `backend=disabled,glsl=0,xform=1,region=0,max_slots=16,max_regions=8`.
- `presetsAndTransforms`: permits built-in presets and cell transforms, but rejects `a=define` custom GLSL.
- `promptCustomGlsl`: hashes each `a=define` source with SHA-256 and prompts the user before compiling unknown hashes. Each pane queues at most `4` prompts, and approval binds strictly to the SHA-256 digest to prevent TOCTOU swaps.
- `allowLocalCustomGlsl`: compiles custom GLSL automatically on local panes while keeping stricter controls on remote sessions.
- Hosts enforce a `4`-second compilation timeout and a per-shader GPU frame watchdog that quarantines offending custom shader IDs without disrupting built-in presets.

### 3.3 Triggering Scoped Region Shaders (`a=region`)

Attaches a built-in preset or defined custom shader to one or more cell rectangles. Only glyphs inside `rects` render into the region's `iChannel0` mask. The output quad expands by `pad` cells so halos or flames can bleed over neighboring cells.

Attach or update:

```text
ESC _ S a=region,id=<regionId>,s=<shaderId>,rects=<x:y:w:h>[/<x:y:w:h>...][,pad=<t:r:b:l>][,stage=<stage>][,z=<int>][,persist=<0|1>][,p0=<f>..p7=<f>] ST
```

Remove:

```text
ESC _ S a=region,id=<regionId>,del=1 ST
```

| Key | Required | Format / Range | Default | Description |
| :-- | :------- | :------------- | :------ | :---------- |
| `id` | Yes | Identifier (`<= 64`) | - | Stable region key used for updates, removal, and feedback buffers. |
| `s` | Yes* | Identifier (`<= 64`) | - | Built-in region preset name or `a=define` slot ID. (*Omitted when `del=1`.) |
| `rects` | Yes* | `x:y:w:h` joined by `/` | - | `1..32` zero-based cell rectangles (`x,y` in `0..65535`; `w,h` in `1..65535`). |
| `pad` | No | `t:r:b:l` | `0:0:0:0` | Bleed padding in cells per edge, clamped to `0..8`. |
| `stage` | No | `under`, `replace`, `over` | `over` | Draw behind glyphs (`under`), mask source glyphs and replace them (`replace`), or composite over glyphs (`over`). |
| `z` | No | Int `[-1000, 1000]` | `0` | Ascending draw order among active regions. |
| `persist` | No | Bool (`0`/`1`) | `0` | Enable previous-frame feedback (`iPrevFrame`). |
| `p0..p7` | No | Float `[-16.0, 16.0]` | `0.0` | Initial user uniform floats mapped to `uParams0.xyzw` and `uParams1.xyzw`. |

Built-in scoped region presets (`s`):
`fire`, `ice_frost`, `neon_pulse`, `glitch_tear`, `one_ring`, `vortex`, `forge_spark`, `water_ripple`.

### 3.4 Triggering Full-Pane Shaders (`a=set`)

Activates or clears a full-pane background, foreground, or post-process shader pass.

Activate:

```text
ESC _ S a=set[,stage=<bg|fg|post>],(preset=<presetId>|id=<slotId>)[,p0=<f>..p7=<f>] ST
```

Clear:

```text
ESC _ S a=set[,stage=<bg|fg|post>],clear=1 ST
```

- `stage` defaults to `post` (valid values: `bg`, `fg`, `post`).
- Custom slot selection accepts `id=<slotId>` or alias `s=<slotId>`.
- Clearing accepts `clear=1` or `del=1`.
- Built-in full-pane presets (`preset`): `wallpaper_wave` (background), `cursor_glow`, `scanline_overlay`, `crt_lottes`, `phosphor_glow`, `retro_phosphor` (foreground).

### 3.5 Live Uniform Updates (`a=uniform`)

Updates any subset of `p0..p7` without recompiling the shader or restating region geometry.

```text
ESC _ S a=uniform[,id=<targetId>],p<n>=<value>[,...] ST
```

- Omitting `id` targets all active full-pane CLI shader passes.
- Supplying `id` targets the matching active scoped region (`a=region`).
- Only specified `p0..p7` indices are overwritten; omitted indices retain their previous values.

### 3.6 Per-Cell Transforms (`a=xform` and `a=xforms`)

Applies visual-only offset, scale, rotation, opacity, z-layer, and finite-duration host tweens to individual grid cells. Logical cell coordinates for text selection and pointer hit-testing do not change.

#### Single Cell (`a=xform`)

Set or animate a cell at zero-based `(c, r)`:

```text
ESC _ S a=xform,c=<col>,r=<row>[,dx=<f>][,dy=<f>][,sx=<f>][,sy=<f>][,rot=<rad>][,al=<f>][,z=<int>][,<tween-keys>] ST
```

Remove a cell transform:

```text
ESC _ S a=xform,c=<col>,r=<row>,del=1 ST
```

Sending an identity transform (`dx=0, dy=0, sx=1, sy=1, rot=0, al=1, z=0`, no tween) also removes the transform.

| Key | Range | Default | Description |
| :-- | :---- | :------ | :---------- |
| `c`, `r` | `0 .. 65535` | required | Zero-based column and row. |
| `dx`, `dy` | Finite float | `0.0` | Fractional horizontal/vertical offset in cell units. |
| `sx`, `sy` | `[0.0, 4.0]` | `1.0` | Horizontal and vertical scale factor. |
| `rot` | Finite float | `0.0` | Rotation in radians around cell center. |
| `al` | `[0.0, 1.0]` | `1.0` | Glyph opacity (alias `alpha`). |
| `z` | `[-128, 127]` | `0` | Signed 8-bit z-layer (`0` = base grid, `> 0` floats above). |

Optional tween keys (including any tween key attaches a finite host tween):

| Key | Range / Values | Default | Description |
| :-- | :------------- | :------ | :---------- |
| `aid` | `0 .. 65535` | `0` | Logical animation ID. Re-sending the same `aid` does not restart an active tween. |
| `edx`, `edy` | Finite float | `0.0` | Target cell offset. |
| `esx`, `esy` | `[0.0, 4.0]` | `1.0` | Target scale. |
| `erot` | Finite float | `0.0` | Target rotation in radians. |
| `ea` | `[0.0, 1.0]` | `1.0` | Target opacity. |
| `dur` | `> 0`, clamped `[0.01, 30.0]` | `0.3` | Tween duration in seconds. |
| `ease` | `linear`, `in`, `out`, `in_out` | `linear` | Easing curve (aliases `lin`, `easein`, `ease_in`, `easeout`, `ease_out`, `inout`, `easeinout`, `ease_in_out`). |
| `cur` | Bool (`0`/`1`) | `0` | Start interpolating from the cell's current live animated pose. |
| `clr` | Bool (`0`/`1`) | `0` | Remove the transform when the tween finishes instead of holding the end pose. |

#### Batched Binary Transforms (`a=xforms`)

Updates up to `4,096` cells per batch using Base64-encoded, little-endian 64-byte structs. Large batches split across `m=1` frames and commit on `m=0`.

```text
ESC _ S a=xforms[,replace=<0|1>],m=<0|1>;<base64-binary> ST
```

- Setting `replace=1` on the first chunk clears all existing cell transforms before applying the batch.
- The reference encoder chunks at `<= 750` entries (`48,000` raw bytes = `64,000` Base64 chars) so every frame stays under `64 KiB`.
- Total decoded byte length must be a non-zero multiple of `64` and `<= 4,096 * 64` (`262,144` bytes).

Each 64-byte record uses little-endian byte order:

| Offset | Size | Type | Field | Notes |
| :----- | :--- | :--- | :---- | :---- |
| `0` | 2 | `uint16` | `col` | Zero-based column. |
| `2` | 2 | `uint16` | `row` | Zero-based row. |
| `4` | 1 | `uint8` | `flags` | Bitmask (see below). Unknown bits (`0x80`) are rejected. |
| `5` | 1 | `int8` | `zLayer` | Stacking layer (`-128 .. 127`). |
| `6` | 2 | `uint16` | `animationId` | Logical tween ID (`0` if unused). |
| `8` | 4 | `float32` | `dx` | Start horizontal offset in cells. |
| `12` | 4 | `float32` | `dy` | Start vertical offset in cells. |
| `16` | 4 | `float32` | `scaleX` | Start horizontal scale (`[0.0, 4.0]`). |
| `20` | 4 | `float32` | `scaleY` | Start vertical scale (`[0.0, 4.0]`). |
| `24` | 4 | `float32` | `rotationRad` | Start rotation in radians. |
| `28` | 4 | `float32` | `alpha` | Start opacity (`[0.0, 1.0]`). |
| `32` | 4 | `float32` | `endDx` | Tween target `dx` (when `flags & 0x01`). |
| `36` | 4 | `float32` | `endDy` | Tween target `dy`. |
| `40` | 4 | `float32` | `endScaleX` | Tween target `scaleX` (`[0.0, 4.0]`). |
| `44` | 4 | `float32` | `endScaleY` | Tween target `scaleY` (`[0.0, 4.0]`). |
| `48` | 4 | `float32` | `endRotationRad` | Tween target rotation in radians. |
| `52` | 4 | `float32` | `endAlpha` | Tween target opacity (`[0.0, 1.0]`). |
| `56` | 4 | `float32` | `durationSec` | Tween duration in seconds (`[0.01, 30.0]`). |
| `60` | 4 | `uint32` | `reserved` | Must be `0`. Non-zero values reject the entire batch. |

`flags` bit layout:

| Bit(s) | Mask | Meaning |
| :----- | :--- | :------ |
| `0` | `0x01` | `hasTween`: bytes `32..59` contain valid tween fields. |
| `1` | `0x02` | `clearOnFinish`: clear transform upon tween completion. |
| `2..4` | `0x1C` | `easing`: `0` = `linear`, `1` = `easeIn`, `2` = `easeOut`, `3` = `easeInOut`. Values `4..7` are invalid. |
| `5` | `0x20` | `fromCurrent`: start tween from the cell's live interpolated pose. |
| `6` | `0x40` | `remove`: delete the transform at `(col, row)` (bytes `8..59` ignored). |
| `7` | `0x80` | Reserved; must be `0`. |

### 3.7 Reset and Screen Lifecycle (`a=reset`)

```text
ESC _ S a=reset[,target=<all|regions|xforms|pane>] ST
```

- `target` defaults to `all` (clears custom definitions, regions, transforms, and full-pane overrides).
- Primary and alternate screen buffers store independent region and transform tables.
- `RIS` (`ESC c`) and `DECSTR` (`CSI ! p`) reset active shader and transform state.
- Exiting the alternate screen clears alt-screen regions, transforms, and alt-screen definitions while preserving primary-screen state.
- Scrolling shifts active regions and cell transforms vertically and drops entries that scroll past the viewport margin. Viewing scrollback hides live overlays until the viewport returns to the bottom.

---

## 4. Chunked File Transfer (`termui_cast` Binary Frames `0x12`–`0x15`)

Chunked drag-and-drop file uploads run out-of-band over the `termui_cast` binary WebSocket protocol (protocol version `8`) rather than inside the TTY byte stream. Keeping file transfer out-of-band prevents untrusted terminal output from initiating or spoofing uploads.

Reference implementations:
- Codec: `apps/termui_cast/protocol/lib/src/buffer_frame_codec.dart`
- Client coordinator: `apps/termui_cast/client_core/lib/src/file_upload_coordinator.dart`
- Host receiver: `apps/termui_cast/caster_cli/lib/src/file_upload_receiver.dart`

### Binary Envelope and Primitive Types

Every `termui_cast` frame starts with `[uint8 version = 8][uint8 tag]`, followed by tag-specific fields in big-endian byte order:

| Type | Encoding |
| :--- | :------- |
| `uint8`, `uint16`, `uint32` | Unsigned big-endian integer (1, 2, or 4 bytes). |
| `uint53` | Two big-endian `uint32` words (`hi = v ~/ 2^32`, `lo = v % 2^32`), range `0 .. 2^53 - 1`. |
| `string16` | `uint16` UTF-8 byte length followed by UTF-8 bytes. |
| `bytes32` | `uint32` byte length followed by raw bytes. |
| `sessionId` | `string16` session identifier (`1..128` printable ASCII bytes `0x21..0x7E`; no `/`, `\`, `.`, or `..`). |

### Frame Definitions

#### `0x12` `FileUploadStartFrame` (Client to Caster)

Initiates a file upload and requests an exclusive `.part` staging file.

| Field | Type | Constraints |
| :---- | :--- | :---------- |
| `sessionId` | `sessionId` | Target session. |
| `transferId` | `uint32` | Client-assigned transfer correlation ID. |
| `fileName` | `string16` | Sanitized base filename (`1..255` UTF-8 bytes; no `/`, `\`, C0/DEL/C1 controls, `.`, or `..`). |
| `totalBytes` | `uint53` | Total file size in bytes. |

#### `0x13` `FileUploadChunkFrame` (Client to Caster)

Delivers a contiguous slice of file bytes.

| Field | Type | Constraints |
| :---- | :--- | :---------- |
| `sessionId` | `sessionId` | Target session. |
| `transferId` | `uint32` | Matches `FileUploadStartFrame.transferId`. |
| `offset` | `uint53` | Zero-based starting byte offset; must equal the caster's expected write cursor. |
| `data` | `bytes32` | `1 .. 65,536` bytes (`<= 64 KiB`). Empty or oversized chunks fail decoding. |

#### `0x14` `FileUploadEndFrame` (Client to Caster)

Completes or aborts an active upload.

| Field | Type | Constraints |
| :---- | :--- | :---------- |
| `sessionId` | `sessionId` | Target session. |
| `transferId` | `uint32` | Matches `FileUploadStartFrame.transferId`. |
| `aborted` | `uint8` | `0` = complete and verify; `1` = cancel and delete staging file. |
| `sha256` | `bytes32` | Exactly `32` bytes (raw SHA-256 digest) when `aborted == 0`; `0` bytes when `aborted == 1`. |

#### `0x15` `FileUploadAckFrame` (Caster to Client)

Paces the upload window and reports finalization or rejection.

| Field | Type | Constraints |
| :---- | :--- | :---------- |
| `sessionId` | `sessionId` | Owning session. |
| `transferId` | `uint32` | Echoed from client frames. |
| `status` | `uint8` | `0` = `ready`, `1` = `chunkAck`, `2` = `completed`, `3` = `rejected`. |
| `nextOffset` | `uint53` | Cumulative bytes confirmed written by the caster. |
| `message` | `string16` | Resolved host path on `completed`, diagnostic reason on `rejected`, empty otherwise (`<= 4,096` UTF-8 bytes). |

### Flow Control, Quotas, and Security

- The client waits for `status=ready` (`0`) after `0x12`, then pipelines up to `8` chunks (`8 * 64 KiB = 512 KiB`) in flight. Each `status=chunkAck` (`1`) advances the window.
- The client waits up to `30` seconds for each expected `FileUploadAckFrame`.
- Caster default quotas: `256 MiB` per file, `1 GiB` cumulative per session, and `256` completed files per session.
- The caster strips directory paths, replaces control and shell metacharacters with `_`, and prefixes Windows reserved names (`CON`, `PRN`, `AUX`, `NUL`, `COM0..9`, `LPT0..9`). It truncates names to `200` UTF-8 bytes preserving extensions, and resolves collisions with `(N)` suffixes up to `1,000` attempts.
- On `0x14` (`aborted=0`), the caster verifies total bytes and SHA-256 against the staged `.part` file. It then atomically renames the file into the session upload directory and injects the shell-escaped host path into the PTY.

---

## 5. Terminal Queries and Host Replies

This section lists all custom APC queries alongside the standard VT/OSC/CSI queries answered by `VirtualTerminal` (`packages/termui_pty/lib/src/virtual_terminal.dart`).

### 5.1 Custom TermUI Queries

| Protocol | Query (App to Host) | Reply (Host to App on `stdin`) | Section |
| :------- | :------------------ | :----------------------------- | :------ |
| Audio waveform | `ESC _ A a=wave,q=<id>; ST` | `ESC _ A a=waver,q=<id>;<b64-256xf32> ST` | [2.6](#26-waveform-capture-query-awave--awaver) |
| Shader capabilities | `ESC _ S a=query ST` | `ESC _ S a=caps,backend=...,glsl=...,xform=...,region=...,max_slots=...,max_regions=... ST` | [3.1](#31-capability-query-aquery--acaps) |

### 5.2 VirtualTerminal Standard Queries

| Query | Sequence | Reply | Notes |
| :---- | :------- | :---- | :---- |
| Primary DA (`DA1`) | `CSI c` or `CSI 0 c` | `CSI ? 62 ; 22 c` | Reports VT220 with ANSI color support. |
| Secondary DA (`DA2`) | `CSI > c` or `CSI > 0 c` | `CSI > 1 ; 10 ; 0 c` | Reports VT220 secondary ID. |
| Terminal Version (`XTVERSION`) | `CSI > q` or `CSI > 0 q` | `ESC P >\|termui(0.8.3) ESC \` | Identifies the `termui_pty` emulator. |
| Device Status (`DSR`) | `CSI 5 n` | `CSI 0 n` | Terminal ready. |
| Cursor Position (`CPR`) | `CSI 6 n` | `CSI <row> ; <col> R` | 1-based cursor coordinates (respects `DECOM`). |
| Extended CPR (`DECXCPR`) | `CSI ? 6 n` | `CSI ? <row> ; <col> ; 1 R` | 1-based coordinates with page `1`. |
| Color Scheme (`DSR 996`) | `CSI ? 996 n` | `CSI ? 997 ; <1\|2> n` | `1` = dark, `2` = light. Also emitted unsolicited on theme change when `DECSET 2031` is active. |
| Request Mode (`DECRQM`) | `CSI ? <Ps> $ p` or `CSI <Ps> $ p` | `CSI [?] <Ps> ; <Pm> $ y` | `Pm`: `0` unrecognized, `1` set, `2` reset. Private modes recognized: `1, 6, 7, 9, 25, 47, 1000, 1002, 1003, 1004, 1006, 1007, 1016, 1047, 1048, 1049, 2004, 2026, 2027, 2031, 2048`. Standard mode recognized: `4` (`IRM`). |
| In-Band Window Resize (`DECSET 2048`) | `CSI ? 2048 h` / `l` | `CSI 48 ; <rows> ; <cols> ; <pxH> ; <pxW> t` | Emitted immediately on enable and whenever grid or cell pixel dimensions change. |
| Window Pixel Size (`XTWINOPS 14t`) | `CSI 14 t` | `CSI 4 ; <pxH> ; <pxW> t` | Viewport size in pixels (`height * cellPxH`, `width * cellPxW`). |
| Cell Pixel Size (`XTWINOPS 16t`) | `CSI 16 t` | `CSI 6 ; <cellPxH> ; <cellPxW> t` | Single cell dimensions in pixels. |
| Grid Size (`XTWINOPS 18t`) | `CSI 18 t` | `CSI 8 ; <rows> ; <cols> t` | Active grid dimensions in cells. |
| Palette Color (`OSC 4`) | `OSC 4 ; <idx> ; ? ST` | `OSC 4 ; <idx> ; rgb:<rrrr>/<gggg>/<bbbb> ST` | 16-bit per channel X11 hex color for palette index `0..255`. |
| Dynamic Colors (`OSC 10/11/12`) | `OSC <10\|11\|12> ; ? ST` | `OSC <code> ; rgb:<rrrr>/<gggg>/<bbbb> ST` | Queries effective foreground (`10`), background (`11`), or cursor (`12`) color. |
| Clipboard Read (`OSC 52`) | `OSC 52 ; <sel> ; ? ST` | Blocked (no reply) | Denied by default for security; invokes host blocked-read callback instead. |
