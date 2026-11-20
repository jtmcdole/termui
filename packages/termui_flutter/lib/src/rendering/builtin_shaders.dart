import 'shader_spec.dart';

/// Built-in Ghostty-compatible Shadertoy GLSL presets bundled with
/// `termui_flutter`.
abstract final class BuiltinShaders {
  /// Returns the Ghostty Shadertoy GLSL source for [preset], or `null` for
  /// [TerminalShaderPreset.none].
  static String? sourceForPreset(TerminalShaderPreset preset) =>
      switch (preset) {
        TerminalShaderPreset.none => null,
        TerminalShaderPreset.wallpaperWave => wallpaperWaveGlsl,
        TerminalShaderPreset.cursorGlow => cursorGlowGlsl,
        TerminalShaderPreset.scanlineOverlay => scanlineOverlayGlsl,
        TerminalShaderPreset.crtLottes => crtLottesGlsl,
        TerminalShaderPreset.phosphorGlow => phosphorGlowGlsl,
      };

  /// Returns the recommended pipeline stage for [preset].
  static TerminalShaderStage defaultStageForPreset(
    TerminalShaderPreset preset,
  ) => switch (preset) {
    TerminalShaderPreset.wallpaperWave => TerminalShaderStage.background,
    TerminalShaderPreset.none ||
    TerminalShaderPreset.cursorGlow ||
    TerminalShaderPreset.scanlineOverlay ||
    TerminalShaderPreset.crtLottes ||
    TerminalShaderPreset.phosphorGlow => TerminalShaderStage.foreground,
  };

  /// Whether [preset] samples `iPrevFrame` and requires a ping-pong buffer.
  static bool usesPrevFrame(TerminalShaderPreset preset) =>
      preset == TerminalShaderPreset.phosphorGlow;

  /// Whether [preset] samples `iChannel0` (chains on top of the previous pass)
  /// rather than generating a standalone base layer from scratch.
  static bool samplesChannel0(TerminalShaderPreset preset) => switch (preset) {
    TerminalShaderPreset.none || TerminalShaderPreset.wallpaperWave => false,
    TerminalShaderPreset.cursorGlow ||
    TerminalShaderPreset.scanlineOverlay ||
    TerminalShaderPreset.crtLottes ||
    TerminalShaderPreset.phosphorGlow => true,
  };

  /// All active built-in shader presets mapped to their GLSL sources.
  static const Map<TerminalShaderPreset, String> allPresets =
      <TerminalShaderPreset, String>{
        TerminalShaderPreset.wallpaperWave: wallpaperWaveGlsl,
        TerminalShaderPreset.cursorGlow: cursorGlowGlsl,
        TerminalShaderPreset.scanlineOverlay: scanlineOverlayGlsl,
        TerminalShaderPreset.crtLottes: crtLottesGlsl,
        TerminalShaderPreset.phosphorGlow: phosphorGlowGlsl,
      };

  /// Animated ambient wave and wallpaper tint background shader.
  ///
  /// Uniform parameters (`uParams0`):
  /// - `x`: animation speed multiplier (defaults to `0.35` when `<= 0`)
  /// - `y`: wave distortion/glow intensity (defaults to `0.35` when `<= 0`)
  /// - `z`: wallpaper blend weight (defaults to `0.65` when `<= 0`)
  static const String wallpaperWaveGlsl = '''
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / max(iResolution.xy, vec2(1.0));
  float speed = uParams0.x > 0.0 ? uParams0.x : 0.35;
  float strength = uParams0.y > 0.0 ? uParams0.y : 0.35;
  float wpMix = uParams0.z > 0.0 ? clamp(uParams0.z, 0.0, 1.0) : 0.65;
  float t = iTime * speed;

  float w1 = sin(uv.x * 5.0 + t * 1.4 + cos(uv.y * 3.0 - t * 0.7));
  float w2 = cos(uv.y * 4.5 - t * 1.1 + sin(uv.x * 3.5 + t * 0.9));
  float ribbon = 0.5 + 0.5 * (w1 * 0.55 + w2 * 0.45);

  vec3 accentA = mix(iPalette[4], vec3(0.18, 0.42, 0.78), 0.35);
  vec3 accentB = mix(iPalette[5], vec3(0.55, 0.22, 0.65), 0.35);
  vec3 aurora = mix(iBackgroundColor, mix(accentA, accentB, ribbon), strength);

  vec2 wpUv = uv + vec2(w1, w2) * (0.004 * strength);
  vec4 wallpaper = texture(iChannel1, clamp(wpUv, 0.0, 1.0));
  vec3 blended = mix(aurora, mix(wallpaper.rgb, aurora, 0.35), wallpaper.a * wpMix);
  fragColor = vec4(blended, 1.0);
}
''';

  /// Soft cursor halo and smooth cursor-motion trail shader.
  ///
  /// Uniform parameters (`uParams0`):
  /// - `x`: glow intensity (defaults to `0.45` when `<= 0`)
  /// - `y`: trail duration in seconds (defaults to `0.18` when `<= 0`)
  /// - `z`: halo radius scale (defaults to `1.8` when `<= 0`)
  static const String cursorGlowGlsl = '''
float _segmentDist(vec2 p, vec2 a, vec2 b) {
  vec2 pa = p - a;
  vec2 ba = b - a;
  float denom = max(dot(ba, ba), 1e-4);
  float h = clamp(dot(pa, ba) / denom, 0.0, 1.0);
  return length(pa - ba * h);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / max(iResolution.xy, vec2(1.0));
  vec4 base = texture(iChannel0, uv);
  if (iCursorVisible == 0 || iCurrentCursor.z <= 0.0 || iCurrentCursor.w <= 0.0) {
    fragColor = base;
    return;
  }

  float intensity = uParams0.x > 0.0 ? uParams0.x : 0.45;
  float duration = uParams0.y > 0.0 ? uParams0.y : 0.18;
  float radiusScale = uParams0.z > 0.0 ? uParams0.z : 1.8;

  vec2 curCenter = iCurrentCursor.xy + iCurrentCursor.zw * 0.5;
  vec2 prevCenter = iPreviousCursor.xy + iPreviousCursor.zw * 0.5;
  float styleBoost = iCurrentCursorStyle == CURSORSTYLE_BAR ? 0.85 : 1.0;
  float radius = max(iCurrentCursor.z, iCurrentCursor.w) * radiusScale;

  float elapsed = max(iTime - iTimeCursorChange, 0.0);
  float trailFade = 1.0 - smoothstep(0.0, duration, elapsed);
  float dCur = length(fragCoord - curCenter);
  float halo = exp(-(dCur * dCur) / max(radius * radius, 1.0)) * styleBoost;

  float dTrail = _segmentDist(fragCoord, prevCenter, curCenter);
  float trailWidth = max(min(iCurrentCursor.z, iCurrentCursor.w) * 0.75, 2.0);
  float trail = exp(-(dTrail * dTrail) / (trailWidth * trailWidth)) * trailFade;

  vec3 glowColor = mix(iCurrentCursorColor.rgb, iPreviousCursorColor.rgb, trailFade * 0.35);
  float focusScale = iFocus == 1 ? 1.0 : 0.35;
  vec3 outRgb = base.rgb + glowColor * (halo * 0.55 + trail * 0.75) * intensity * focusScale;
  fragColor = vec4(clamp(outRgb, 0.0, 1.0), base.a);
}
''';

  /// Static horizontal scanline and subtle vignette overlay shader.
  ///
  /// Uniform parameters (`uParams0`):
  /// - `x`: scanline darkness (defaults to `0.18` when `<= 0`)
  /// - `y`: pixel pitch per scanline (defaults to `2.0` when `<= 0`)
  /// - `z`: edge vignette strength (defaults to `0.22` when `<= 0`)
  static const String scanlineOverlayGlsl = '''
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / max(iResolution.xy, vec2(1.0));
  vec4 base = texture(iChannel0, uv);

  float scanStrength = uParams0.x > 0.0 ? clamp(uParams0.x, 0.0, 0.85) : 0.18;
  float pitch = uParams0.y > 0.0 ? uParams0.y : 2.0;
  float vignetteStrength = uParams0.z > 0.0 ? clamp(uParams0.z, 0.0, 0.85) : 0.22;

  float wave = 0.5 + 0.5 * sin(fragCoord.y * 3.14159265 / max(pitch, 1.0));
  float scanMask = 1.0 - scanStrength * (1.0 - wave);

  vec2 centered = uv * 2.0 - 1.0;
  float vig = 1.0 - dot(centered, centered) * 0.35 * vignetteStrength;
  vig = clamp(vig, 0.0, 1.0);

  fragColor = vec4(base.rgb * scanMask * vig, base.a);
}
''';

  /// Timothy Lottes-inspired CRT barrel distortion, aperture grille mask,
  /// scanlines, and soft bloom.
  ///
  /// Uniform parameters (`uParams0`):
  /// - `x`: barrel curvature (defaults to `0.06` when `<= 0`)
  /// - `y`: scanline intensity (defaults to `0.22` when `<= 0`)
  /// - `z`: aperture grille mask strength (defaults to `0.16` when `<= 0`)
  /// - `w`: horizontal bloom weight (defaults to `0.18` when `<= 0`)
  static const String crtLottesGlsl = '''
vec2 _warpCrtUv(vec2 uv, float curvature) {
  vec2 centered = uv * 2.0 - 1.0;
  vec2 offset = abs(centered.yx) * curvature;
  centered += centered * offset * offset;
  return centered * 0.5 + 0.5;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 res = max(iResolution.xy, vec2(1.0));
  vec2 uv = fragCoord / res;

  float curvature = uParams0.x > 0.0 ? clamp(uParams0.x, 0.0, 0.35) : 0.06;
  float scanStrength = uParams0.y > 0.0 ? clamp(uParams0.y, 0.0, 0.75) : 0.22;
  float maskStrength = uParams0.z > 0.0 ? clamp(uParams0.z, 0.0, 0.5) : 0.16;
  float bloomWeight = uParams0.w > 0.0 ? clamp(uParams0.w, 0.0, 0.6) : 0.18;

  vec2 warped = _warpCrtUv(uv, curvature);
  if (warped.x < 0.0 || warped.x > 1.0 || warped.y < 0.0 || warped.y > 1.0) {
    fragColor = vec4(iBackgroundColor * 0.15, 1.0);
    return;
  }

  vec2 texel = 1.0 / res;
  vec4 center = texture(iChannel0, warped);
  vec3 leftSample = texture(iChannel0, clamp(warped - vec2(texel.x * 1.5, 0.0), 0.0, 1.0)).rgb;
  vec3 rightSample = texture(iChannel0, clamp(warped + vec2(texel.x * 1.5, 0.0), 0.0, 1.0)).rgb;
  vec3 bloom = (leftSample + rightSample) * 0.5;
  vec3 color = mix(center.rgb, max(center.rgb, bloom * 1.15), bloomWeight);

  float scan = 1.0 - scanStrength * (0.5 - 0.5 * cos(warped.y * res.y * 3.14159265));
  float triad = mod(floor(fragCoord.x), 3.0);
  vec3 grille = vec3(
    triad < 0.5 ? 1.0 : 1.0 - maskStrength,
    triad >= 0.5 && triad < 1.5 ? 1.0 : 1.0 - maskStrength,
    triad >= 1.5 ? 1.0 : 1.0 - maskStrength
  );

  vec2 edge = smoothstep(vec2(0.0), vec2(0.025), warped) *
      smoothstep(vec2(0.0), vec2(0.025), 1.0 - warped);
  float bezel = edge.x * edge.y;
  fragColor = vec4(color * scan * grille * bezel, center.a);
}
''';

  /// Phosphor persistence and multi-tap glow shader sampling `iPrevFrame`.
  ///
  /// Uniform parameters (`uParams0`):
  /// - `x`: persistence decay factor in `[0.0, 0.96]` (defaults to `0.78`)
  /// - `y`: bloom halo strength (defaults to `0.28` when `<= 0`)
  /// - `z`: bloom radius in pixels (defaults to `2.0` when `<= 0`)
  static const String phosphorGlowGlsl = '''
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 res = max(iResolution.xy, vec2(1.0));
  vec2 uv = fragCoord / res;
  vec2 texel = 1.0 / res;

  float decay = uParams0.x > 0.0 ? clamp(uParams0.x, 0.0, 0.96) : 0.78;
  float bloomStrength = uParams0.y > 0.0 ? clamp(uParams0.y, 0.0, 1.0) : 0.28;
  float radius = uParams0.z > 0.0 ? clamp(uParams0.z, 0.5, 6.0) : 2.0;

  vec4 curr = texture(iChannel0, uv);
  vec4 prev = texture(iPrevFrame, uv);

  vec2 stepUv = texel * radius;
  vec3 halo = (
    texture(iChannel0, clamp(uv + vec2(stepUv.x, 0.0), 0.0, 1.0)).rgb +
    texture(iChannel0, clamp(uv - vec2(stepUv.x, 0.0), 0.0, 1.0)).rgb +
    texture(iChannel0, clamp(uv + vec2(0.0, stepUv.y), 0.0, 1.0)).rgb +
    texture(iChannel0, clamp(uv - vec2(0.0, stepUv.y), 0.0, 1.0)).rgb
  ) * 0.25;

  vec3 decayedPrev = prev.rgb * decay;
  vec3 combined = max(curr.rgb, decayedPrev) + max(halo - iBackgroundColor, vec3(0.0)) * bloomStrength;
  fragColor = vec4(clamp(combined, 0.0, 1.0), max(curr.a, prev.a * decay));
}
''';
}
