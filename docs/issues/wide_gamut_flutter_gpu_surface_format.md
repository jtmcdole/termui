# Issue: Preserve Wide Gamut (Display P3) on Native `flutter_gpu` Surfaces

## Summary

On wide-gamut Apple displays (such as macOS Apple Silicon / Display P3), `FlutterGpuShaderBackend` currently falls back from `gpu.PixelFormat.unknown` to `gpu.PixelFormat.b8g8r8a8UNormInt` for `GpuImageSurface` and offscreen render targets. That avoids an upstream `flutter_gpu` crash, but clamps terminal shader output to 8-bit sRGB (`[0.0, 1.0]`), losing wide-gamut Display P3 range for P3 wallpapers, P3 Kitty graphics, and unclamped (`> 1.0`) shader glow/bloom.

## Root Cause (Upstream Flutter 3.50 `flutter_gpu`)

1. On wide-gamut Apple Metal displays, Impeller's default swapchain color format is `impeller::PixelFormat::kB10G10R10A10XR` (extended-range 10-bit sRGB, 8 bytes/pixel).
2. In Flutter 3.50 (`engine/src/flutter/lib/gpu/formats.h:260-264`), `FromImpellerPixelFormat` intentionally maps Apple-only `kB10G10R10XR*` formats to `FlutterGPUPixelFormat::kUnknown`:
   ```cpp
   case impeller::PixelFormat::kB10G10R10XR:
   case impeller::PixelFormat::kB10G10R10XRSRGB:
   case impeller::PixelFormat::kB10G10R10A10XR:
     // Apple-only extended-range formats, not exposed by the Flutter GPU API.
     return FlutterGPUPixelFormat::kUnknown;
   ```
3. As a result, `gpu.gpuContext.defaultColorFormat` returns `gpu.PixelFormat.unknown`.
4. Calling `gpu.gpuContext.createImageSurface(width, height)` without an explicit format passes `defaultColorFormat` (`PixelFormat.unknown`), which `InternalFlutterGpu_Surface_Initialize` (`engine/src/flutter/lib/gpu/surface.cc:263-266`) rejects with:
   ```text
   Exception: Unsupported GpuSurface pixel format.
   ```

## Current Workaround in `termui_flutter`

`FlutterGpuShaderBackend.resolveSafeGpuColorFormat` (`packages/termui_flutter/lib/src/rendering/shader_backend_gpu.dart`) maps `gpu.PixelFormat.unknown` to `gpu.PixelFormat.b8g8r8a8UNormInt` and passes `format: _renderColorFormat` to `createImageSurface` and `_createRenderTargetTexture`.

## Proposed Improvement

1. **Wide-gamut half-float target (`r16g16b16a16Float`)**:
   - `flutter_gpu` already exposes `gpu.PixelFormat.r16g16b16a16Float` (8 bytes/pixel, same memory footprint as `kB10G10R10A10XR`).
   - Because Impeller encodes Display P3 colors in extended sRGB (channel values `< 0.0` and `> 1.0`), rendering into `r16g16b16a16Float` when `defaultColorFormat == PixelFormat.unknown` preserves the full Display P3 gamut and unclamped HDR/bloom shader output when composited onto Impeller's `kB10G10R10A10XR` swapchain.
2. **Verification needed before switching**:
   - Confirm `GpuImageSurface` and intermediate `RenderTarget` textures with `r16g16b16a16Float` render and composite with identical sRGB color accuracy (no gamma/linear shift) on macOS Metal P3 displays.
   - Benchmark GPU frame time and memory overhead vs. `b8g8r8a8UNormInt` (8 B/px vs. 4 B/px) on 4K/5K Retina panes and multi-pass foreground chains (`wallpaper_wave` + `phosphor_glow` + `crt_lottes`).
   - Verify whether any built-in or Ghostty Shadertoy shaders assume `[0, 1]` clamping between chained passes (e.g., `clamp(color, 0.0, 1.0)` vs. intentional HDR bloom).
3. **Optional upstream Flutter bug to file**:
   - Report to `flutter/flutter` (`package:flutter_gpu`) that `gpuContext.createImageSurface(w, h)` fails out of the box on wide-gamut macOS/iOS devices because `gpuContext.defaultColorFormat` returns `PixelFormat.unknown` instead of a valid wide-gamut fallback such as `PixelFormat.r16g16b16a16Float` (or exposing a safe default surface format).

## Affected Files

- `packages/termui_flutter/lib/src/rendering/shader_backend_gpu.dart` (`resolveSafeGpuColorFormat`, `_renderColorFormat`, `createImageSurface`, `_createRenderTargetTexture`)
- `packages/termui_flutter/test/impellerc_compiler_test.dart` (`resolveSafeGpuColorFormat` unit test)
