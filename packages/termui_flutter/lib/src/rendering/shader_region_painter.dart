import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/shader_region.dart';
import 'package:termui/ui/terminal_palette.dart';
import 'package:termui/ui/widgets/core/geometry.dart' as tui_geo;

import 'atlas.dart';
import 'cell_transform_painter.dart';
import 'gpu_atlas_batch.dart';
import 'gpu_frame_watchdog.dart';
import 'shader_backend.dart';
import 'shadertoy_glsl_shim.dart';

/// Built-in Ghostty Shadertoy GLSL presets designed for scoped [ShaderRegion]
/// effects (`iChannel0` = tight `uGlyphMask`).
abstract final class ShaderRegionPresets {
  /// Ordered list of all built-in scoped region preset identifiers.
  static const List<String> presetIds = <String>[
    'fire',
    'ice_frost',
    'neon_pulse',
    'glitch_tear',
    'one_ring',
    'vortex',
    'forge_spark',
    'water_ripple',
  ];

  /// Returns `true` when [id] matches one of the built-in region presets.
  static bool isPreset(String id) => sourceFor(id) != null;

  /// Returns the Ghostty Shadertoy GLSL source for built-in region preset [id],
  /// or `null` if [id] is not a built-in region preset.
  static String? sourceFor(String id) => switch (id) {
    'fire' => fireGlsl,
    'ice_frost' => iceFrostGlsl,
    'neon_pulse' => neonPulseGlsl,
    'glitch_tear' => glitchTearGlsl,
    'one_ring' => oneRingGlsl,
    'vortex' => vortexGlsl,
    'forge_spark' => forgeSparkGlsl,
    'water_ripple' => waterRippleGlsl,
    _ => null,
  };

  /// Rising procedural fire and ember glow fueled by `iChannel0` (`uGlyphMask`).
  ///
  /// Uniform parameters (`uParams0`):
  /// - `x`: flame intensity multiplier (defaults to `1.15` when `<= 0`)
  /// - `y`: rise speed multiplier (defaults to `1.0` when `<= 0`)
  /// - `z`: turbulence scale (defaults to `1.0` when `<= 0`)
  static const String fireGlsl = '''
float _fireHash(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

float _fireNoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  float a = _fireHash(i);
  float b = _fireHash(i + vec2(1.0, 0.0));
  float c = _fireHash(i + vec2(0.0, 1.0));
  float d = _fireHash(i + vec2(1.0, 1.0));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float _fireFbm(vec2 p) {
  float v = 0.0;
  float amp = 0.55;
  for (int i = 0; i < 4; i++) {
    v += amp * _fireNoise(p);
    p = p * 2.03 + vec2(1.7, 9.2);
    amp *= 0.5;
  }
  return v;
}

float _fireMaskSample(vec2 uv) {
  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
    return 0.0;
  }
  return texture(iChannel0, uv).a;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 res = max(iResolution.xy, vec2(1.0));
  vec2 uv = fragCoord / res;
  float intensity = uParams0.x > 0.0 ? uParams0.x : 1.15;
  float speed = uParams0.y > 0.0 ? uParams0.y : 1.0;
  float turb = uParams0.z > 0.0 ? uParams0.z : 1.0;
  float t = iTime * speed;

  vec2 cellUv = max(iCellSize / res, vec2(1.0 / res));
  vec2 flowP = vec2(uv.x * 7.5 * turb, uv.y * 4.5 - t * 3.2);
  vec2 warp = vec2(
    _fireFbm(flowP + vec2(2.3, 1.7)),
    _fireFbm(flowP + vec2(8.1, -t * 1.4))
  ) - 0.5;

  // Hoisted domain-warped 9-tap advection upward from the bilinearly filtered
  // glyph ink mask (4 FBM total per fragment instead of 20).
  float fuel = 0.0;
  float baseInk = _fireMaskSample(uv);
  for (int i = 0; i < 9; i++) {
    float s = float(i) / 8.0;
    float rise = s * cellUv.y * 2.55;
    float sway = (warp.x + warp.y * s) * cellUv.x * (0.25 + 1.85 * s * s);
    vec2 sampleUv = vec2(uv.x - sway, uv.y - rise);
    float m = _fireMaskSample(sampleUv);
    float w = (1.0 - s * 0.85) * (1.0 - s * 0.6);
    fuel += m * w;
  }
  fuel = fuel * 0.42 + baseInk * 0.45;

  // Turbulent tongue erosion: carves flickering flame tips as fuel thins upward.
  float tongues = _fireFbm(vec2(uv.x * 11.5 * turb, uv.y * 6.5 - t * 4.6) + warp * 1.7);
  float wisps = _fireFbm(vec2(uv.x * 22.0 * turb, uv.y * 12.0 - t * 6.4) + warp * 2.2);
  float noiseField = tongues * 0.72 + wisps * 0.28;

  float edgeFade =
      smoothstep(1.0, 0.78, uv.y) *
      smoothstep(0.0, 0.03, uv.x) *
      smoothstep(1.0, 0.97, uv.x);
  float flame = clamp(
    (fuel * 1.25 + (noiseField - 0.44) * 1.05 * smoothstep(0.03, 0.42, fuel)) *
        intensity *
        edgeFade,
    0.0,
    1.0
  );
  float alpha = smoothstep(0.06, 0.52, flame);

  vec3 crimson = vec3(0.78, 0.06, 0.01);
  vec3 orange = vec3(1.0, 0.40, 0.02);
  vec3 gold = vec3(1.0, 0.84, 0.16);
  vec3 core = vec3(1.0, 0.98, 0.86);

  vec3 col = mix(crimson, orange, smoothstep(0.08, 0.42, flame));
  col = mix(col, gold, smoothstep(0.42, 0.74, flame));
  col = mix(col, core, smoothstep(0.74, 0.96, flame));

  fragColor = vec4(col * alpha, alpha);
}
''';

  /// Dramatic Voronoi crystalline frost crust, edge dendrites, and rime halos
  /// coating `iChannel0` (`uGlyphMask`).
  ///
  /// Uniform parameters (`uParams0`):
  /// - `x`: freeze progress (`0.0` = warm/clear, `1.0` = solid ice,
  ///   `1.3` = deep cryo crystal; negative values default to `1.0`)
  static const String iceFrostGlsl = '''
float _iceHash(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

vec2 _iceHash2(vec2 p) {
  return vec2(_iceHash(p), _iceHash(p + vec2(41.3, 289.1)));
}

float _iceNoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(
    mix(_iceHash(i), _iceHash(i + vec2(1.0, 0.0)), u.x),
    mix(_iceHash(i + vec2(0.0, 1.0)), _iceHash(i + vec2(1.0, 1.0)), u.x),
    u.y
  );
}

float _iceFbm(vec2 p) {
  float v = 0.0;
  float amp = 0.55;
  for (int i = 0; i < 4; i++) {
    v += amp * _iceNoise(p);
    p = p * 2.04 + vec2(4.3, 8.7);
    amp *= 0.5;
  }
  return v;
}

vec3 _iceVoronoi(vec2 p) {
  vec2 n = floor(p);
  vec2 f = fract(p);
  float md1 = 8.0;
  float md2 = 8.0;
  float cid = 0.0;
  for (int y = -1; y <= 1; y++) {
    for (int x = -1; x <= 1; x++) {
      vec2 g = vec2(float(x), float(y));
      vec2 o = _iceHash2(n + g);
      vec2 r = g + (0.15 + 0.70 * o) - f;
      float d = dot(r, r);
      if (d < md1) {
        md2 = md1;
        md1 = d;
        cid = o.x;
      } else if (d < md2) {
        md2 = d;
      }
    }
  }
  return vec3(sqrt(md1), sqrt(md2) - sqrt(md1), cid);
}

float _iceSample(vec2 uv) {
  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
    return 0.0;
  }
  return texture(iChannel0, uv).a;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 res = max(iResolution.xy, vec2(1.0));
  vec2 uv = fragCoord / res;
  vec2 texel = 1.0 / res;

  float freeze = uParams0.x < 0.0 ? 1.0 : clamp(uParams0.x, 0.0, 1.5);
  if (freeze <= 0.001) {
    fragColor = vec4(0.0);
    return;
  }
  float normFreeze = clamp(freeze, 0.0, 1.25);

  float cellMin = max(min(iCellSize.x, iCellSize.y), 6.0);
  float r1 = max(cellMin * 0.36, 2.0);
  float r2 = max(cellMin * 0.80, 4.5);

  float glyph = _iceSample(uv);
  float rime = glyph * 0.52;
  for (int i = 0; i < 8; i++) {
    float a = float(i) * 0.78539816;
    vec2 dir = vec2(cos(a), sin(a));
    rime += _iceSample(uv + dir * r1 * texel) * 0.14;
    rime += _iceSample(uv + dir * r2 * texel) * 0.07;
  }
  rime = clamp(rime, 0.0, 1.0);

  // Cellular Voronoi ice crystal facets & fracture veins.
  vec2 crystalUv = fragCoord / max(cellMin * 0.95, 7.0);
  vec3 vor = _iceVoronoi(crystalUv);
  float facetEdge = 1.0 - smoothstep(0.02, 0.16, vor.y);
  float fineVor = 1.0 - smoothstep(0.02, 0.18, _iceVoronoi(crystalUv * 2.15 + 3.7).y);
  float dendrite = _iceFbm(crystalUv * 1.45 + vec2(0.0, 1.9));

  // Frost dendrites creep inward from the region border and outward from letters.
  float edgeDist = min(min(uv.x, 1.0 - uv.x) * 2.0, min(uv.y, 1.0 - uv.y) * 2.0);
  float creepFront = normFreeze * 0.92 + (dendrite - 0.38) * 0.58;
  float edgeFrost = smoothstep(edgeDist - 0.14, edgeDist + 0.18, creepFront) *
      (0.32 + 0.68 * (1.0 - smoothstep(0.0, 0.72, edgeDist)));

  // Crystalline frost coating directly on and around glyph strokes.
  float glyphSpread = smoothstep(0.18, 0.95, normFreeze + dendrite * 0.42);
  float glyphCrust = clamp(
    glyph * (0.65 + 0.45 * facetEdge) +
        rime * (0.58 + 0.52 * fineVor + 0.35 * dendrite),
    0.0,
    1.0
  ) * glyphSpread;

  // Sparkling facet glints animated over time.
  float glintWave = 0.5 + 0.5 * sin(iTime * 3.8 + vor.z * 18.85 + uv.x * 7.0);
  float sparkle = pow(glintWave, 6.0) * (0.45 + 0.55 * facetEdge) *
      smoothstep(0.25, 1.0, normFreeze);
  float microDust = step(0.92, _iceHash(floor(fragCoord * 0.5))) *
      (0.5 + 0.5 * sin(iTime * 6.5 + fragCoord.x * 0.37)) *
      smoothstep(0.35, 1.1, normFreeze);

  float crystalMask = clamp(
    max(glyphCrust, edgeFrost * (0.38 + 0.62 * max(facetEdge, dendrite))) +
        facetEdge * rime * 0.45 * smoothstep(0.3, 1.1, normFreeze),
    0.0,
    1.0
  );

  vec3 deepGlacier = vec3(0.14, 0.52, 0.92);
  vec3 cryoCyan = vec3(0.48, 0.90, 1.0);
  vec3 crystalWhite = vec3(0.95, 0.99, 1.0);

  vec3 col = mix(deepGlacier, cryoCyan, clamp(dendrite * 0.75 + rime * 0.55, 0.0, 1.0));
  col = mix(
    col,
    crystalWhite,
    clamp(facetEdge * 0.72 + glyph * 0.68 + sparkle * 0.85 + microDust * 0.75, 0.0, 1.0)
  );

  float alpha = clamp(
    crystalMask * (0.48 + 0.44 * clamp(normFreeze, 0.0, 1.0)) +
        sparkle * (rime * 0.55 + edgeFrost * 0.35),
    0.0,
    0.94
  );
  fragColor = vec4(col * alpha, alpha);
}
''';

  /// Glowing glass neon tube with wide multi-ring wall bloom, white-hot core,
  /// and subtle transformer flicker driven by `iChannel0` (`uGlyphMask`).
  static const String neonPulseGlsl = '''
float _neonHash(float n) {
  return fract(sin(n * 127.1 + 311.7) * 43758.5453);
}

float _neonSample(vec2 uv) {
  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
    return 0.0;
  }
  return texture(iChannel0, uv).a;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 res = max(iResolution.xy, vec2(1.0));
  vec2 uv = fragCoord / res;
  vec2 texel = 1.0 / res;
  float speed = uParams0.x > 0.0 ? uParams0.x : 2.6;
  float intensity = uParams0.y > 0.0 ? uParams0.y : 1.15;

  float cellMin = max(min(iCellSize.x, iCellSize.y), 6.0);
  float rTight = max(cellMin * 0.40, 2.2);
  float rWide = max(cellMin * 1.15, 6.8);
  float rHalo = max(cellMin * 2.05, 12.5);

  float center = _neonSample(uv);
  float tight = 0.0;
  float wide = 0.0;
  for (int i = 0; i < 12; i++) {
    float a = float(i) * 0.52359878;
    vec2 dir = vec2(cos(a), sin(a));
    tight += _neonSample(uv + dir * rTight * texel);
    wide += _neonSample(uv + dir * rWide * texel);
  }
  tight /= 12.0;
  wide /= 12.0;

  float halo = 0.0;
  for (int i = 0; i < 8; i++) {
    float a = float(i) * 0.78539816 + 0.39269908;
    vec2 dir = vec2(cos(a), sin(a));
    halo += _neonSample(uv + dir * rHalo * texel);
  }
  halo /= 8.0;

  // Transformer 60Hz hum + occasional realistic neon tube micro-flicker.
  float hum = 0.94 + 0.06 * sin(iTime * speed * 6.0 + uv.x * 3.0);
  float flickSlot = floor(iTime * 9.5);
  float flickTrig = step(0.955, _neonHash(flickSlot));
  float flickDip = 1.0 - flickTrig * (0.28 + 0.16 * _neonHash(flickSlot + 19.0));
  float pulse = (0.86 + 0.14 * sin(iTime * speed + uv.x * 3.5)) * hum * flickDip;

  vec3 electricCyan = vec3(0.04, 0.90, 1.0);
  vec3 hotMagenta = vec3(1.0, 0.10, 0.72);
  float colorWave = 0.5 + 0.5 * sin(iTime * 1.15 + uv.x * 3.8);
  vec3 tubeCol = mix(electricCyan, hotMagenta, colorWave);
  vec3 hotCoreCol = mix(tubeCol, vec3(1.0, 0.96, 1.0), 0.84);

  float coreMask = smoothstep(0.16, 0.72, center);
  float innerGlow = clamp(tight * 1.65, 0.0, 1.0);
  float outerSpill = clamp(wide * 1.35 + halo * 0.95, 0.0, 1.0);

  vec3 col = tubeCol * (0.72 + 0.42 * innerGlow);
  col = mix(col, hotCoreCol, coreMask);

  float alpha = clamp(
    (coreMask * 0.96 + innerGlow * 0.68 + outerSpill * 0.42) * pulse * intensity,
    0.0,
    0.98
  );
  fragColor = vec4(col * alpha, alpha);
}
''';

  /// Horizontal scanline chromatic split and tear effect on `iChannel0` (`uGlyphMask`).
  static const String glitchTearGlsl = '''
float _glitchRand(float y) {
  return fract(sin(y * 91.7 + floor(iTime * 14.0) * 17.3) * 43758.5453);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 res = max(iResolution.xy, vec2(1.0));
  vec2 uv = fragCoord / res;
  float strength = uParams0.x > 0.0 ? uParams0.x : 1.0;

  float band = floor(fragCoord.y / max(iCellSize.y * 0.25, 2.0));
  float trigger = step(0.76, _glitchRand(band));
  float shift = (_glitchRand(band + 13.0) - 0.5) * 0.08 * trigger * strength;
  float chroma = (0.008 + abs(shift) * 0.65) * strength;

  vec4 sR = texture(iChannel0, clamp(uv + vec2(shift + chroma, 0.0), 0.0, 1.0));
  vec4 sG = texture(iChannel0, clamp(uv + vec2(shift, 0.0), 0.0, 1.0));
  vec4 sB = texture(iChannel0, clamp(uv + vec2(shift - chroma, 0.0), 0.0, 1.0));
  float alpha = clamp(max(max(sR.a, sG.a), sB.a), 0.0, 1.0);
  vec3 rgb = vec3(sR.r, sG.g, sB.b);
  fragColor = vec4(rgb * alpha, alpha);
}
''';

  /// *The One Ring of Power* — opaque dark hammered-gold band concealing cold
  /// runes completely (`alpha = 1.0`), illuminated by a single exclusive live
  /// flame (`iMouse` drag > hover > Auto-Torch `uParams0`) that heats glyph
  /// strokes until they latch glowing in molten gold via `iPrevFrame`.
  ///
  /// Uniform parameters:
  /// - `uParams0.xy`: normalized `[0..1]` Auto-Torch UV (or `(0, 0)` when off)
  /// - `uParams0.z`: torch radius (defaults to `0.18` when `<= 0`)
  /// - `uParams0.w`: torch power (`> 0.0`); when `uParams0.xy == (0, 0)` and
  ///   `uParams0.w > 0.5`, pointer hover ignites runes without holding click
  /// - `uParams1.x`: `> 0.5` cools and clears all latched rune glow immediately
  /// - `uParams1.y`: `> 0.5` softly reveals the bottom prompt line while editing
  static const String oneRingGlsl = '''
float _ringHash(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

float _ringNoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(
    mix(_ringHash(i), _ringHash(i + vec2(1.0, 0.0)), u.x),
    mix(_ringHash(i + vec2(0.0, 1.0)), _ringHash(i + vec2(1.0, 1.0)), u.x),
    u.y
  );
}

float _ringFbm(vec2 p) {
  float v = 0.0;
  float amp = 0.55;
  for (int i = 0; i < 4; i++) {
    v += amp * _ringNoise(p);
    p = p * 2.02 + vec2(3.1, 7.4);
    amp *= 0.5;
  }
  return v;
}

float _ringMask(vec2 uv) {
  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
    return 0.0;
  }
  return texture(iChannel0, uv).a;
}

float _ringPrevGlyphGlow(vec2 uv) {
  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
    return 0.0;
  }
  float g = texture(iChannel0, uv).a;
  if (g <= 0.10) {
    return 0.0;
  }
  float r = texture(iPrevFrame, uv).r;
  return clamp((r - 0.14) / 0.86, 0.0, 1.0) * smoothstep(0.10, 0.35, g);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 res = max(iResolution.xy, vec2(1.0));
  vec2 uv = fragCoord / res;
  vec2 texel = 1.0 / res;

  // Opaque dark hammered-gold band surface (max channel <= 0.092, safely
  // below the 0.14 glow readback floor) 100% conceals cold underlying glyphs.
  float grain = _ringNoise(vec2(uv.x * 26.0, uv.y * 120.0));
  float sheen = _ringNoise(vec2(uv.x * 6.5, uv.y * 14.0));
  vec3 metalCol = vec3(0.075, 0.058, 0.032) * (0.86 + 0.22 * grain + 0.12 * sheen);

  float glyph = _ringMask(uv);
  bool onGlyph = glyph > 0.10;
  bool resetGlow = uParams1.x > 0.5;
  bool editingPrompt = uParams1.y > 0.5;

  float dt = clamp(iTimeDelta, 0.004, 0.05);
  float dtNorm = dt * 60.0;

  float radius = uParams0.z > 0.0 ? clamp(uParams0.z, 0.03, 0.65) : 0.18;
  float minDim = max(min(res.x, res.y), 48.0);
  float rPx = radius * minDim * 1.30;
  float fbm = _ringFbm(vec2(uv.x * 10.5, uv.y * 6.5 - iTime * 2.8));

  // Strictly single exclusive live flame source:
  // native iMouse drag > native iMouse hover > Auto-Torch uParams0.xy.
  vec2 mouseUv = iMouse.xy / res;
  bool mouseNear = mouseUv.x >= -0.25 && mouseUv.x <= 1.25 &&
      mouseUv.y >= -0.25 && mouseUv.y <= 1.25;
  bool mouseDragging = mouseNear && iMouse.z > 0.0;
  bool hasAutoTorch = uParams0.w > 0.0 && (uParams0.x > 0.0 || uParams0.y > 0.0);
  bool mouseHoverTorch = mouseNear && !mouseDragging && !hasAutoTorch &&
      uParams0.w > 0.5 && (iMouse.x > 0.0 || iMouse.y > 0.0);

  bool hasFlame = false;
  vec2 flamePx = vec2(0.0);
  float flamePower = 0.0;
  if (mouseDragging) {
    hasFlame = true;
    flamePx = iMouse.xy;
    flamePower = 1.0;
  } else if (mouseHoverTorch) {
    hasFlame = true;
    flamePx = iMouse.xy;
    flamePower = 0.85;
  } else if (hasAutoTorch) {
    hasFlame = true;
    flamePx = clamp(uParams0.xy, vec2(0.0), vec2(1.0)) * res;
    flamePower = clamp(uParams0.w, 0.0, 2.0);
  }

  // Whole-letter cell-quantized heating so each character heats and latches
  // cleanly as a complete rune (never half-chopped pixels).
  vec2 cell = max(iCellSize, vec2(6.0, 12.0));
  float colIdx = floor(fragCoord.x / cell.x);
  float rowFromTop = floor(max(res.y - fragCoord.y, 0.0) / cell.y);
  vec2 cellCenterPx = vec2(
    (colIdx + 0.5) * cell.x,
    res.y - (rowFromTop + 0.5) * cell.y
  );

  // Purely instantaneous live flame (NEVER stored in open-air iPrevFrame).
  float flameHeat = 0.0;
  float flameVis = 0.0;
  if (hasFlame) {
    vec2 delta = (fragCoord - flamePx) / max(rPx, 1.0);
    vec2 tongue = delta;
    tongue.y *= tongue.y > 0.0 ? 0.72 : 1.16;
    tongue.x += (fbm - 0.5) * 0.36 * max(tongue.y + 0.30, 0.0);
    float dF = length(tongue);
    float wisp = 0.72 + 0.56 * fbm;
    flameVis = clamp(exp(-(dF * dF) * 2.15) * flamePower * wisp, 0.0, 1.0);
    vec2 cellDelta = (cellCenterPx - flamePx) / max(rPx, 1.0);
    float dH = length(cellDelta);
    flameHeat = exp(-(dH * dH) * 1.65) * flamePower;
  }

  // Persistent latched glyph glow stored strictly on glyph pixels.
  float glow = 0.0;
  if (!resetGlow && onGlyph) {
    float prevGlow = clamp((texture(iPrevFrame, uv).r - 0.14) / 0.86, 0.0, 1.0);
    float heatAdd = flameHeat * dt * 4.5;
    glow = clamp(prevGlow + heatAdd, 0.0, 1.0);
    if (glow >= 0.40) {
      // Latched molten state: heated letters remain permanently illuminated.
      glow = max(glow, 0.84);
    } else if (heatAdd <= 0.001) {
      // Unlatched brief brush-bys cool smoothly back to exact zero.
      glow = max(glow * pow(0.90, dtNorm) - 0.005 * dtNorm, 0.0);
    }
    if (editingPrompt && uv.y < 0.28) {
      glow = max(glow, 0.86);
    }
  }

  vec3 emberCrimson = vec3(0.84, 0.12, 0.02);
  vec3 moltenOrange = vec3(1.0, 0.48, 0.05);
  vec3 whiteGold = vec3(1.0, 0.94, 0.68);

  if (onGlyph) {
    if (glow <= 0.001) {
      fragColor = vec4(metalCol, 1.0);
      return;
    }
    // Multi-frequency living molten fire flicker on latched runes while keeping
    // fragColor.r >= 0.84 strictly above the 0.40 latch readback floor.
    float fbmFlicker = _ringFbm(
      vec2(colIdx * 0.7 + uv.x * 6.0, uv.y * 8.0 - iTime * 4.8)
    );
    float fbmFast = _ringNoise(
      vec2(uv.x * 16.0 + colIdx * 1.3, uv.y * 14.0 - iTime * 9.2)
    );
    float cellWave = 0.5 + 0.5 * sin(iTime * 9.5 + colIdx * 2.3 + rowFromTop * 5.1);
    float slowBreath = 0.5 + 0.5 * sin(iTime * 3.7 + colIdx * 1.1 - rowFromTop * 2.9);
    float flicker = clamp(
      fbmFlicker * 0.52 + fbmFast * 0.20 + cellWave * 0.18 + slowBreath * 0.10,
      0.0,
      1.0
    );
    float fireCurve = smoothstep(0.18, 0.86, flicker);
    float hotFlare = smoothstep(0.66, 0.95, flicker);

    float encodedR = clamp(0.14 + glow * 0.86, 0.14, 1.0);
    float molten = smoothstep(0.05, 0.85, glow);
    float latched = smoothstep(0.40, 0.84, glow);
    float stroke = smoothstep(0.10, 0.72, glyph);

    vec3 deepEmber = vec3(0.86, 0.24, 0.02);
    vec3 moltenGold = vec3(1.0, 0.72, 0.10);
    vec3 whiteHot = vec3(1.0, 0.96, 0.72);
    vec3 latchedCol = mix(
      deepEmber,
      moltenGold,
      clamp(fireCurve * (0.72 + 0.38 * stroke), 0.0, 1.0)
    );
    latchedCol = mix(
      latchedCol,
      whiteHot,
      clamp(hotFlare * (0.55 + 0.45 * stroke), 0.0, 1.0)
    );

    float outR = mix(encodedR, max(latchedCol.r, 0.84), latched);
    float outG = mix(metalCol.g + molten * 0.48, latchedCol.g, latched);
    float outB = mix(metalCol.b + molten * 0.06, latchedCol.b, latched);
    fragColor = vec4(
      clamp(outR, 0.0, 1.0),
      clamp(outG, 0.0, 1.0),
      clamp(outB, 0.0, 1.0),
      1.0
    );
    return;
  }

  // Open metal pixel: smooth radial molten halo around nearby glowing runes
  // (read only from glyph pixels so open metal never feeds back into iPrevFrame).
  float halo = 0.0;
  if (!resetGlow) {
    float cellMin = max(min(iCellSize.x, iCellSize.y), 6.0);
    float r1 = max(cellMin * 0.24, 1.6);
    float r2 = max(cellMin * 0.52, 3.4);
    for (int i = 0; i < 6; i++) {
      float a1 = float(i) * 1.04719755;
      float a2 = a1 + 0.52359878;
      halo += _ringPrevGlyphGlow(uv + vec2(cos(a1), sin(a1)) * r1 * texel) * 0.17;
      halo += _ringPrevGlyphGlow(uv + vec2(cos(a2), sin(a2)) * r2 * texel) * 0.08;
    }
    halo = clamp(halo, 0.0, 1.0);
  }

  vec3 outRgb = metalCol;
  if (halo > 0.005) {
    float haloFbm = _ringFbm(
      vec2(colIdx * 0.65 + uv.x * 6.5, uv.y * 8.5 - iTime * 4.8)
    );
    float haloWave = 0.5 + 0.5 * sin(iTime * 8.5 + colIdx * 2.1 + rowFromTop * 4.7);
    float haloFlicker = clamp(haloFbm * 0.68 + haloWave * 0.32, 0.0, 1.0);
    float haloMod = 0.65 + 0.55 * haloFlicker;
    float softHalo = clamp(halo * (0.55 + 0.45 * halo) * haloMod, 0.0, 1.0);
    vec3 haloCol = mix(
      emberCrimson,
      moltenOrange,
      smoothstep(0.08, 0.72, halo * (0.75 + 0.50 * haloFlicker))
    );
    haloCol = mix(
      haloCol,
      whiteGold,
      smoothstep(0.72, 0.98, halo * haloFlicker) * 0.45
    );
    outRgb = mix(outRgb, haloCol, clamp(softHalo * 0.52, 0.0, 0.78));
  }

  if (flameVis > 0.02) {
    vec2 sparkCell = vec2(fragCoord.x * 0.24, fragCoord.y * 0.18 - iTime * 11.0);
    float sparkId = _ringHash(floor(sparkCell));
    vec2 sparkF = fract(sparkCell) - 0.5;
    float sparkDot = smoothstep(0.28, 0.04, length(sparkF)) *
        step(0.88, sparkId) * smoothstep(0.25, 0.85, flameVis);
    vec3 flameCol = mix(emberCrimson, moltenOrange, smoothstep(0.10, 0.52, flameVis));
    flameCol = mix(flameCol, whiteGold, smoothstep(0.55, 0.94, flameVis));
    flameCol += whiteGold * sparkDot * 0.55;
    float flameBlend = smoothstep(0.04, 0.62, flameVis);
    outRgb = mix(outRgb, flameCol, flameBlend);
  }

  fragColor = vec4(clamp(outRgb, 0.0, 1.0), 1.0);
}
''';

  /// *Vortext — Black Hole & Top-Down Hurricane Aura* driven by `iMouse` or
  /// `uParams0`.
  ///
  /// Uniform parameters (`uParams0`):
  /// - `x`, `y`: normalized `[0..1]` vortex center when not dragging `iMouse`
  ///   (defaults to `(0.5, 0.5)`)
  /// - `z`: pull/intensity multiplier (defaults to `1.0` when `<= 0`; flares
  ///   higher when letters are swallowed by the Black Hole)
  /// - `w`: mode (`< 0.5` = Black Hole singularity + Einstein photon ring;
  ///   `>= 0.5` = top-down Hurricane eye & logarithmic spiral cloud bands)
  static const String vortexGlsl = '''
float _vortexHash(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

float _vortexNoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(
    mix(_vortexHash(i), _vortexHash(i + vec2(1.0, 0.0)), u.x),
    mix(_vortexHash(i + vec2(0.0, 1.0)), _vortexHash(i + vec2(1.0, 1.0)), u.x),
    u.y
  );
}

float _vortexFbm(vec2 p) {
  float v = 0.0;
  float amp = 0.55;
  for (int i = 0; i < 3; i++) {
    v += amp * _vortexNoise(p);
    p = p * 2.05 + vec2(2.7, 6.1);
    amp *= 0.5;
  }
  return v;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 res = max(iResolution.xy, vec2(1.0));
  vec2 uv = fragCoord / res;
  vec2 texel = 1.0 / res;

  // Always anchor to uParams0.xy (or centered 0.5, 0.5) without needing a click;
  // live iMouse drag only repositions when pressing inside the vortex region.
  vec2 center = (uParams0.x > 0.0 || uParams0.y > 0.0)
      ? clamp(uParams0.xy, vec2(0.0), vec2(1.0))
      : vec2(0.5, 0.5);
  vec2 mouseUv = iMouse.xy / res;
  bool mouseInRegion = mouseUv.x >= -0.05 && mouseUv.x <= 1.05 &&
      mouseUv.y >= -0.05 && mouseUv.y <= 1.05;
  if (iMouse.z > 0.0 && mouseInRegion) {
    center = clamp(mouseUv, vec2(0.0), vec2(1.0));
  }
  float intensity = uParams0.z > 0.0 ? clamp(uParams0.z, 0.25, 2.5) : 1.0;
  float visIntensity = max(intensity, 0.95);
  bool isHurricane = uParams0.w >= 0.5;

  vec2 aspect = vec2(res.x / res.y, 1.0);
  vec2 p = (uv - center) * aspect;
  float r = length(p);
  float angle = atan(p.y, p.x);

  float spread = max(min(iCellSize.x, iCellSize.y) * 0.28, 1.5);
  float gCenter = texture(iChannel0, uv).a;
  float gHalo = gCenter * 0.5;
  gHalo += texture(iChannel0, clamp(uv + vec2(spread * texel.x, 0.0), 0.0, 1.0)).a * 0.16;
  gHalo += texture(iChannel0, clamp(uv - vec2(spread * texel.x, 0.0), 0.0, 1.0)).a * 0.16;
  gHalo += texture(iChannel0, clamp(uv + vec2(0.0, spread * texel.y), 0.0, 1.0)).a * 0.16;
  gHalo += texture(iChannel0, clamp(uv - vec2(0.0, spread * texel.y), 0.0, 1.0)).a * 0.16;
  gHalo = clamp(gHalo, 0.0, 1.0);

  if (!isHurricane) {
    // Black Hole: pitch-black event horizon, flaring Einstein photon ring,
    // and Doppler-boosted accretion disk — always visible even before clicking.
    float feedFlare = clamp((intensity - 1.15) * 1.1, 0.0, 1.0);
    float rH = 0.145 * clamp(visIntensity, 0.85, 1.45);
    float coreMask = 1.0 - smoothstep(rH * 0.76, rH * 1.04, r);
    float photonRing = exp(-pow((r - rH * 1.14) / max(rH * (0.24 + 0.10 * feedFlare), 0.018), 2.0));
    float outerCorona = exp(-pow((r - rH * 1.50) / max(rH * 0.78, 0.04), 2.0));

    float swirlAngle = angle * 3.0 - iTime * 3.4 + 1.65 / (r + 0.12);
    float diskWave = 0.5 + 0.5 * sin(swirlAngle);
    float streakNoise = _vortexNoise(vec2(angle * 2.5 + iTime * 0.9, r * 14.0 - iTime * 2.2));
    float doppler = 0.68 + 0.32 * cos(angle - 0.75);
    float accretion = outerCorona * (0.38 + 0.62 * diskWave * streakNoise) * doppler;

    vec2 lensDir = r > 1e-4 ? (p / r) : vec2(0.0);
    vec2 tangent = vec2(-lensDir.y, lensDir.x);
    vec2 lensUv = clamp(
      uv + (tangent * 0.014 + lensDir * 0.008) * outerCorona * visIntensity,
      0.0,
      1.0
    );
    float lensedGlyph = texture(iChannel0, lensUv).a;
    float edgeHalo = max(gHalo, lensedGlyph) * (0.42 + 0.58 * outerCorona);

    vec3 deepViolet = vec3(0.46, 0.16, 0.96);
    vec3 goldAmber = vec3(1.0, 0.56, 0.10);
    vec3 whiteHot = vec3(1.0, 0.95, 0.82);

    vec3 auraCol = mix(deepViolet, goldAmber, clamp(accretion * 1.3 + photonRing * 0.85, 0.0, 1.0));
    auraCol = mix(auraCol, whiteHot, clamp(photonRing * (0.92 + 0.45 * feedFlare), 0.0, 1.0));
    vec3 glyphTint = mix(deepViolet * 1.15, goldAmber, clamp(photonRing + accretion, 0.0, 1.0));

    float auraAlpha = clamp((photonRing * (0.98 + 0.32 * feedFlare) + accretion * 0.82) * visIntensity, 0.0, 0.98);
    float glyphAlpha = clamp(edgeHalo * 0.72 * visIntensity, 0.0, 0.92) * (1.0 - coreMask * 0.88);
    float outAlpha = clamp(max(coreMask, max(auraAlpha, glyphAlpha)), 0.0, 1.0);

    vec3 combined = mix(glyphTint, auraCol, clamp(auraAlpha / max(auraAlpha + glyphAlpha, 1e-4), 0.0, 1.0));
    vec3 eventHorizon = vec3(0.01, 0.0, 0.03);
    vec3 finalRgb = mix(combined, eventHorizon, coreMask);
    fragColor = vec4(finalRgb * outAlpha, outAlpha);
    return;
  }

  // Top-down Hurricane / Cyclone: calm dark central eye, bright eyewall ring,
  // and swirling counter-clockwise logarithmic spiral cloud/rain bands.
  float eyeR = 0.12 * clamp(visIntensity, 0.85, 1.45);
  float eyeMask = 1.0 - smoothstep(eyeR * 0.65, eyeR * 1.08, r);
  float eyeWall = exp(-pow((r - eyeR * 1.24) / max(eyeR * 0.46, 0.02), 2.0));

  float logR = log(max(r, 0.025));
  float swirlSpeed = iTime * 3.8;
  vec2 turbCoord = vec2(cos(angle - iTime * 0.8), sin(angle - iTime * 0.8)) * (r * 5.2);
  float cloudTurb = _vortexFbm(turbCoord + vec2(logR * 1.8, -iTime * 0.9));

  // Counter-clockwise trailing logarithmic spiral rainbands (3 primary + 5 fine).
  float armPrimary = 0.5 + 0.5 * sin(angle * 3.0 + logR * 7.8 - swirlSpeed + cloudTurb * 2.4);
  float armSecondary = 0.5 + 0.5 * sin(angle * 5.0 + logR * 11.5 - swirlSpeed * 1.25 - cloudTurb * 1.8);
  float outerEnv = smoothstep(eyeR * 0.82, eyeR * 1.32, r) * exp(-max(r - eyeR, 0.0) * 1.65);

  float spiralBands = outerEnv * pow(clamp(armPrimary * 0.72 + armSecondary * 0.28, 0.0, 1.0), 1.35) *
      (0.55 + 0.45 * cloudTurb);
  float stormDensity = clamp(eyeWall * (0.78 + 0.35 * cloudTurb) + spiralBands * 1.05, 0.0, 1.0);

  vec3 calmEye = vec3(0.04, 0.08, 0.14);
  vec3 stormSlate = vec3(0.18, 0.34, 0.52);
  vec3 electricCyan = vec3(0.24, 0.78, 0.98);
  vec3 eyewallWhite = vec3(0.94, 0.99, 1.0);

  vec3 cloudCol = mix(stormSlate, electricCyan, clamp(spiralBands * 1.25 + eyeWall * 0.55, 0.0, 1.0));
  cloudCol = mix(cloudCol, eyewallWhite, clamp(eyeWall * 0.88 + pow(spiralBands, 2.0) * 0.45, 0.0, 1.0));
  vec3 finalStorm = mix(cloudCol, calmEye, eyeMask);

  float stormAlpha = clamp(
    max(eyeMask * 0.82, (stormDensity * 0.88 + gHalo * (0.28 + 0.45 * stormDensity)) * clamp(visIntensity, 0.85, 1.6)),
    0.0,
    0.94
  );
  fragColor = vec4(finalStorm * stormAlpha, stormAlpha);
}
''';

  /// *Forge Strike / Micro-Pixel Welding Sparks* — 14 crisp welding sparks
  /// (`~0.9–1.1 px` heads with fine `2.25–4.25 px` fading trails) arcing out
  /// under parabolic gravity strictly from the struck character cell
  /// (`uParams0.xy`) with a subtle `0.20`-alpha warm glint on that single
  /// glyph's ink. Zero rings or orbs.
  ///
  /// Uniform parameters (`uParams0`):
  /// - `x`, `y`: normalized `[0..1]` strike origin UV (struck cell center)
  /// - `z`: strike pulse age in seconds (`0.0 < z < 0.54` emits sparks; `<= 0`
  ///   or `>= 0.54` outputs exact transparent zero)
  /// - `w`: intensity multiplier (defaults to `1.0` when `<= 0`)
  static const String forgeSparkGlsl = '''
float _sparkHash(float n) {
  return fract(sin(n * 127.1 + 311.7) * 43758.5453);
}

float _sparkSegDist(vec2 p, vec2 a, vec2 b) {
  vec2 pa = p - a;
  vec2 ba = b - a;
  float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
  return length(pa - ba * h);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  float age = uParams0.z;
  if (age <= 0.0 || age >= 0.54) {
    fragColor = vec4(0.0);
    return;
  }

  vec2 res = max(iResolution.xy, vec2(1.0));
  vec2 uv = fragCoord / res;
  vec2 origin = clamp(uParams0.xy, vec2(0.0), vec2(1.0));
  float intensity = uParams0.w > 0.0 ? clamp(uParams0.w, 0.25, 2.0) : 1.0;

  vec2 originPx = origin * res;
  vec2 cell = max(iCellSize, vec2(8.0, 16.0));
  float cellScale = max(cell.y, 12.0);
  float pxScale = clamp(cellScale / 18.0, 0.75, 2.0);
  vec2 relPx = fragCoord - originPx;

  // Super-subtle 0.20-alpha warm white-gold glint strictly on the struck
  // character's own glyph ink for the first 0.10s (zero ring or orb).
  float glyph = texture(iChannel0, uv).a;
  vec2 glyphRel = relPx / (cell * 0.65);
  float inStruckCell = 1.0 - smoothstep(0.60, 0.95, length(glyphRel));
  float glintFade = 1.0 - smoothstep(0.0, 0.10, age);
  float struckGlint = glyph * inStruckCell * glintFade * 0.20;

  // 14 crisp pixel-scale welding sparks (+25% larger, +50% further cast).
  float seed = floor(origin.x * 137.0 + origin.y * 59.0);
  float sparkAccum = 0.0;
  float sparkHot = 0.0;
  const float gravity = 15.0;
  float tPrev = max(age - 0.018, 0.0);
  float headR = max(1.06, 0.90 * pxScale);
  float trailW = max(0.525, 0.45 * pxScale);

  for (int i = 0; i < 14; i++) {
    float fi = float(i);
    float h1 = _sparkHash(seed + fi * 13.7 + 1.0);
    float h2 = _sparkHash(seed + fi * 29.3 + 7.0);
    float h3 = _sparkHash(seed + fi * 43.1 + 19.0);

    // Wider ballistic spray (+50% reach off the struck character).
    float ang = (fi / 14.0) * 6.2831853 + (h1 - 0.5) * 0.50;
    float spd = 1.425 + h2 * 2.475;
    vec2 vel = vec2(cos(ang) * spd, sin(ang) * spd + 1.95);

    vec2 headPx = (vel * age - vec2(0.0, 0.5 * gravity * age * age)) * cellScale;
    vec2 tailPx = (vel * tPrev - vec2(0.0, 0.5 * gravity * tPrev * tPrev)) * cellScale;

    // Cap tail length to crisp 2.25–4.25 physical pixels (+25% vs baseline).
    vec2 deltaTail = tailPx - headPx;
    float tailLen = length(deltaTail);
    float maxTail = (2.25 + 2.0 * h2) * pxScale;
    if (tailLen > maxTail) {
      tailPx = headPx + deltaTail * (maxTail / tailLen);
    }

    float dHead = length(relPx - headPx);
    float dSeg = _sparkSegDist(relPx, tailPx, headPx);
    float maxLife = (0.20 + 0.24 * h3) * 1.15;
    float life = 1.0 - smoothstep(maxLife * 0.52, maxLife, age);
    float twinkle = 0.86 + 0.14 * sin(iTime * 62.0 + fi * 9.3);

    float tip = smoothstep(headR, 0.225 * pxScale, dHead) * life * twinkle;
    float streak = smoothstep(trailW, 0.10 * pxScale, dSeg) * life * 0.48;
    sparkAccum += max(tip, streak);
    sparkHot += tip;
  }

  float energy = clamp(struckGlint + sparkAccum * intensity, 0.0, 1.0);
  if (energy <= 0.01) {
    fragColor = vec4(0.0);
    return;
  }

  vec3 emberOrange = vec3(1.0, 0.42, 0.05);
  vec3 forgeGold = vec3(1.0, 0.82, 0.24);
  vec3 whiteHot = vec3(1.0, 0.98, 0.88);

  vec3 col = mix(emberOrange, forgeGold, smoothstep(0.15, 0.60, energy));
  col = mix(
    col,
    whiteHot,
    smoothstep(0.32, 0.88, clamp(sparkHot + struckGlint * 2.5, 0.0, 1.0))
  );

  fragColor = vec4(col * energy, energy);
}
''';

  /// *Liquid / Magnetic Ripple* — domain-warped caustic shimmer and expanding
  /// concentric cyan/aqua ripple rings radiating from `iMouse.xy` or
  /// `uParams0.xy`.
  ///
  /// Uniform parameters (`uParams0`):
  /// - `x`, `y`: fallback normalized `[0..1]` ripple center UV when pointer is
  ///   inactive (defaults to `(0.5, 0.5)`)
  /// - `z`: ripple intensity multiplier (defaults to `1.0` when `<= 0`)
  /// - `w`: wave speed multiplier (defaults to `1.0` when `<= 0`)
  static const String waterRippleGlsl = '''
float _rippleCaustic(vec2 p, float t) {
  vec2 q = p * 4.2;
  float w1 = sin(q.x + sin(q.y * 1.3 + t * 1.4) + t * 0.9);
  float w2 = cos(q.y * 1.2 - cos(q.x * 1.1 - t * 1.2) + t * 0.7);
  float ridge = 1.0 - abs(w1 + w2) * 0.5;
  return pow(clamp(ridge, 0.0, 1.0), 3.0);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 res = max(iResolution.xy, vec2(1.0));
  vec2 uv = fragCoord / res;
  vec2 texel = 1.0 / res;

  vec2 origin = vec2(0.5, 0.5);
  bool hasPointer = iMouse.z > 0.0 ||
      ((uParams0.x <= 0.0 && uParams0.y <= 0.0) &&
          (iMouse.x != 0.0 || iMouse.y != 0.0));
  if (hasPointer) {
    origin = clamp(iMouse.xy / res, vec2(0.0), vec2(1.0));
  } else if (uParams0.x > 0.0 || uParams0.y > 0.0) {
    origin = clamp(uParams0.xy, vec2(0.0), vec2(1.0));
  }
  float intensity = uParams0.z > 0.0 ? clamp(uParams0.z, 0.25, 2.5) : 1.0;
  float speed = uParams0.w > 0.0 ? clamp(uParams0.w, 0.25, 3.0) : 1.0;
  float t = iTime * speed;

  vec2 aspect = vec2(res.x / res.y, 1.0);
  vec2 p = (uv - origin) * aspect;
  float d = length(p);
  vec2 radialDir = d > 1e-4 ? (p / d) : vec2(0.0);

  // Expanding concentric ripple waves + harmonic crest.
  float wPrimary = sin(d * 34.0 - t * 6.2) * exp(-d * 2.4);
  float wHarmonic = sin(d * 54.0 - t * 8.8 + 1.1) * exp(-d * 3.6);
  float wave = wPrimary * 0.68 + wHarmonic * 0.32;
  float crest = pow(max(0.0, wave), 1.8) * 1.15;

  // Domain-warped water caustics.
  vec2 causticP = uv * aspect + radialDir * (wave * 0.06);
  float caustic = _rippleCaustic(causticP, t) * 0.65 +
      _rippleCaustic(causticP * 1.65 + vec2(1.9, -1.3), -t * 0.85) * 0.35;

  // Refracted glyph sample + specular caustic halo around iChannel0.a.
  vec2 refrUv = clamp(uv + radialDir * (wave * 0.008 * intensity), 0.0, 1.0);
  float gRefr = texture(iChannel0, refrUv).a;
  float spread = max(min(iCellSize.x, iCellSize.y) * 0.28, 1.5);
  float gHalo = gRefr * 0.55;
  gHalo += texture(iChannel0, clamp(refrUv + vec2(spread * texel.x, 0.0), 0.0, 1.0)).a * 0.15;
  gHalo += texture(iChannel0, clamp(refrUv - vec2(spread * texel.x, 0.0), 0.0, 1.0)).a * 0.15;
  gHalo += texture(iChannel0, clamp(refrUv + vec2(0.0, spread * texel.y), 0.0, 1.0)).a * 0.15;
  gHalo += texture(iChannel0, clamp(refrUv - vec2(0.0, spread * texel.y), 0.0, 1.0)).a * 0.15;
  gHalo = clamp(gHalo, 0.0, 1.0);

  vec3 deepCerulean = vec3(0.04, 0.42, 0.74);
  vec3 aquaGlow = vec3(0.14, 0.88, 0.96);
  vec3 specularIce = vec3(0.84, 0.99, 1.0);

  float shimmer = clamp(crest * 0.85 + caustic * (0.35 + 0.65 * gHalo), 0.0, 1.0);
  vec3 col = mix(deepCerulean, aquaGlow, smoothstep(0.10, 0.62, shimmer));
  col = mix(col, specularIce, smoothstep(0.58, 0.95, clamp(crest + gRefr * caustic, 0.0, 1.0)));

  float fieldAlpha = clamp(
    (crest * 0.58 + caustic * 0.22 * exp(-d * 1.4) + gHalo * (0.48 + 0.42 * caustic + 0.30 * crest)) *
        intensity,
    0.0,
    0.94
  );
  fragColor = vec4(col * fieldAlpha, fieldAlpha);
}
''';
}

/// Tight computed layout and isolated cell membership for one active
/// [ShaderRegion].
final class ComputedShaderRegionLayout {
  /// Hard logical pixel cap (`512x512` logical px) bounding per-region FBO size.
  static const double maxRegionLogicalExtent = 512.0;

  /// Hard per-pane physical pixel area budget across all active region FBOs
  /// (`2048 * 2048` physical px) preventing built-in preset fill-rate DoS.
  static const int maxPaneRegionPhysicalPixels = 2048 * 2048;

  /// Truncates [layouts] in ascending display order so the combined physical
  /// pixel area (`physicalWidth * physicalHeight`) never exceeds
  /// [maxTotalPhysicalPixels].
  static List<ComputedShaderRegionLayout> applyPanePixelBudget(
    List<ComputedShaderRegionLayout> layouts, {
    int maxTotalPhysicalPixels = maxPaneRegionPhysicalPixels,
  }) {
    if (layouts.isEmpty || maxTotalPhysicalPixels <= 0) {
      return const <ComputedShaderRegionLayout>[];
    }
    final budgeted = <ComputedShaderRegionLayout>[];
    var usedPixels = 0;
    for (final layout in layouts) {
      final area = layout.physicalWidth * layout.physicalHeight;
      if (area <= 0 || usedPixels + area > maxTotalPhysicalPixels) {
        continue;
      }
      usedPixels += area;
      budgeted.add(layout);
    }
    return budgeted;
  }

  /// Original region descriptor.
  final ShaderRegion region;

  /// Stable layout identifier (`region.id` for single-component regions, or
  /// `'${region.id}#$index'` when a wrapped/disconnected multi-rect region is
  /// partitioned into independent sub-layouts).
  final String layoutId;

  /// Tight logical-pixel union of [ShaderRegion.sourceRects] (expanded for
  /// active moving transforms up to [maxRegionLogicalExtent]).
  final ui.Rect sourceUnionLogical;

  /// Logical-pixel region output rectangle including clamped padding and
  /// clipped strictly to the terminal pane viewport (`<= 512x512` logical px).
  final ui.Rect outputRectLogical;

  /// Physical-pixel region output rectangle matching [physicalWidth] and
  /// [physicalHeight].
  final ui.Rect outputRectPhysical;

  /// Integer physical FBO width (`>= 1`).
  final int physicalWidth;

  /// Integer physical FBO height (`>= 1`).
  final int physicalHeight;

  /// Deduplicated flat cell indices strictly inside this layout's source rects
  /// (never including adjacent cells inside [ShaderRegion.padding]).
  final List<int> sourceCellIndices;

  /// Creates an immutable computed region layout.
  ComputedShaderRegionLayout({
    required this.region,
    String? layoutId,
    required this.sourceUnionLogical,
    required this.outputRectLogical,
    required this.outputRectPhysical,
    required this.physicalWidth,
    required this.physicalHeight,
    required this.sourceCellIndices,
  }) : layoutId = layoutId ?? region.id;

  /// Transforms pane-space Shadertoy Y-up physical pixel `iMouse`
  /// `(x, y, clickX, clickY)` into this region's local Y-up physical pixel
  /// coordinate space, writing the 4 floats into [out] while preserving the
  /// click sign (`z > 0` while pressed, `z < 0` after release, `0` before
  /// first click).
  void writeRegionMouseXyzw({
    required Float32List paneMouseXyzw,
    required double panePhysicalHeight,
    required Float32List out,
  }) {
    final paneX = paneMouseXyzw[0];
    final paneY = paneMouseXyzw[1];
    final paneClickZ = paneMouseXyzw[2];
    final paneClickW = paneMouseXyzw[3];
    if (paneX == 0.0 &&
        paneY == 0.0 &&
        paneClickZ == 0.0 &&
        paneClickW == 0.0) {
      out[0] = 0.0;
      out[1] = 0.0;
      out[2] = 0.0;
      out[3] = 0.0;
      return;
    }
    final paneTopDownY = panePhysicalHeight - paneY;
    out[0] = paneX - outputRectPhysical.left;
    out[1] =
        outputRectPhysical.height - (paneTopDownY - outputRectPhysical.top);

    if (paneClickZ == 0.0 && paneClickW == 0.0) {
      out[2] = 0.0;
      out[3] = 0.0;
      return;
    }
    final clickSign = (paneClickZ > 0.0 || paneClickW > 0.0) ? 1.0 : -1.0;
    final clickTopDownY = panePhysicalHeight - paneClickW.abs();
    final localClickX = paneClickZ.abs() - outputRectPhysical.left;
    final localClickY =
        outputRectPhysical.height - (clickTopDownY - outputRectPhysical.top);
    out[2] = clickSign * (localClickX > 0.0 ? localClickX : 1e-3);
    out[3] = clickSign * (localClickY > 0.0 ? localClickY : 1e-3);
  }

  /// Transforms a pane-space Shadertoy Y-up physical pixel cursor rectangle
  /// `(left, bottomY, width, height)` into this region's local Y-up physical
  /// pixel coordinate space, writing the 4 floats into [out].
  void writeRegionCursorXywh({
    required Float32List paneCursorXywh,
    required double panePhysicalHeight,
    required Float32List out,
  }) {
    if (paneCursorXywh[2] <= 0.0 || paneCursorXywh[3] <= 0.0) {
      out[0] = 0.0;
      out[1] = 0.0;
      out[2] = 0.0;
      out[3] = 0.0;
      return;
    }
    final paneTopDownBottom = panePhysicalHeight - paneCursorXywh[1];
    out[0] = paneCursorXywh[0] - outputRectPhysical.left;
    out[1] =
        outputRectPhysical.height -
        (paneTopDownBottom - outputRectPhysical.top);
    out[2] = paneCursorXywh[2];
    out[3] = paneCursorXywh[3];
  }

  /// Computes the primary tight bounding box and isolated cell list for
  /// [region], returning `null` when [region] has no visible cells.
  static ComputedShaderRegionLayout? compute({
    required ShaderRegion region,
    required int gridCols,
    required int gridRows,
    required double cellWidth,
    required double cellHeight,
    required ui.Size paneLogicalSize,
    required double devicePixelRatio,
    Map<int, EvaluatedCellTransform>? activeTransforms,
  }) {
    final all = computeAll(
      region: region,
      gridCols: gridCols,
      gridRows: gridRows,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      paneLogicalSize: paneLogicalSize,
      devicePixelRatio: devicePixelRatio,
      activeTransforms: activeTransforms,
    );
    return all.isEmpty ? null : all.first;
  }

  /// Computes one or more tight layouts for [region], partitioning disconnected
  /// or wrapped [ShaderRegion.sourceRects] whose combined padded box would
  /// exceed [maxRegionLogicalExtent] (`512x512` logical px) so wrapped lines
  /// render both fragments instead of cropping to an empty center window.
  static List<ComputedShaderRegionLayout> computeAll({
    required ShaderRegion region,
    required int gridCols,
    required int gridRows,
    required double cellWidth,
    required double cellHeight,
    required ui.Size paneLogicalSize,
    required double devicePixelRatio,
    Map<int, EvaluatedCellTransform>? activeTransforms,
  }) {
    if (region.sourceRects.isEmpty ||
        gridCols <= 0 ||
        gridRows <= 0 ||
        cellWidth <= 0.0 ||
        cellHeight <= 0.0 ||
        paneLogicalSize.isEmpty) {
      return const <ComputedShaderRegionLayout>[];
    }
    final pad = region.padding.clamped();
    final clusters = _partitionRectsIntoClusters(
      sourceRects: region.sourceRects,
      cols: gridCols,
      rows: gridRows,
      cellW: cellWidth,
      cellH: cellHeight,
      pad: pad,
    );
    if (clusters.isEmpty) return const <ComputedShaderRegionLayout>[];
    final layouts = <ComputedShaderRegionLayout>[];
    for (var i = 0; i < clusters.length; i++) {
      final layout = _computeClusterLayout(
        region: region,
        layoutId: clusters.length == 1 ? region.id : '${region.id}#$i',
        rects: clusters[i],
        pad: pad,
        gridCols: gridCols,
        gridRows: gridRows,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        paneLogicalSize: paneLogicalSize,
        devicePixelRatio: devicePixelRatio,
        activeTransforms: activeTransforms,
      );
      if (layout != null) {
        layouts.add(layout);
      }
    }
    return layouts;
  }

  static List<List<tui_geo.Rect>> _partitionRectsIntoClusters({
    required List<tui_geo.Rect> sourceRects,
    required int cols,
    required int rows,
    required double cellW,
    required double cellH,
    required CellPadding pad,
  }) {
    final valid = _clampValidSourceRects(sourceRects, cols, rows);
    if (valid.length <= 1) {
      return valid.isEmpty
          ? const <List<tui_geo.Rect>>[]
          : <List<tui_geo.Rect>>[valid];
    }

    final clusters = <List<tui_geo.Rect>>[];
    final clusterBounds = <ui.Rect>[];
    for (final rect in valid) {
      final padded = _paddedLogicalRect(rect, cellW, cellH, pad);
      final mergedIdx = _findMergeableClusterIndex(clusterBounds, padded);
      if (mergedIdx >= 0) {
        clusters[mergedIdx].add(rect);
        clusterBounds[mergedIdx] = clusterBounds[mergedIdx].expandToInclude(
          padded,
        );
      } else {
        clusters.add(<tui_geo.Rect>[rect]);
        clusterBounds.add(padded);
      }
    }
    return clusters;
  }

  static List<tui_geo.Rect> _clampValidSourceRects(
    List<tui_geo.Rect> sourceRects,
    int cols,
    int rows,
  ) {
    final valid = <tui_geo.Rect>[];
    for (final rect in sourceRects) {
      final minX = rect.x.clamp(0, cols);
      final maxX = (rect.x + rect.width).clamp(0, cols);
      final minY = rect.y.clamp(0, rows);
      final maxY = (rect.y + rect.height).clamp(0, rows);
      if (maxX > minX && maxY > minY) {
        valid.add(tui_geo.Rect(minX, minY, maxX - minX, maxY - minY));
      }
    }
    return valid;
  }

  static int _findMergeableClusterIndex(
    List<ui.Rect> clusterBounds,
    ui.Rect candidate,
  ) {
    for (var i = 0; i < clusterBounds.length; i++) {
      if (_canMergeClusterRects(clusterBounds[i], candidate)) return i;
    }
    return -1;
  }

  static ui.Rect _paddedLogicalRect(
    tui_geo.Rect rect,
    double cellW,
    double cellH,
    CellPadding pad,
  ) => ui.Rect.fromLTRB(
    (rect.x - pad.left) * cellW,
    (rect.y - pad.top) * cellH,
    (rect.x + rect.width + pad.right) * cellW,
    (rect.y + rect.height + pad.bottom) * cellH,
  );

  static bool _canMergeClusterRects(ui.Rect a, ui.Rect b) {
    final combined = a.expandToInclude(b);
    if (combined.width > maxRegionLogicalExtent ||
        combined.height > maxRegionLogicalExtent) {
      return false;
    }
    return a.overlaps(b);
  }

  static ComputedShaderRegionLayout? _computeClusterLayout({
    required ShaderRegion region,
    required String layoutId,
    required List<tui_geo.Rect> rects,
    required CellPadding pad,
    required int gridCols,
    required int gridRows,
    required double cellWidth,
    required double cellHeight,
    required ui.Size paneLogicalSize,
    required double devicePixelRatio,
    required Map<int, EvaluatedCellTransform>? activeTransforms,
  }) {
    final cellIndices = _collectSourceCellIndices(rects, gridCols, gridRows);
    if (cellIndices.isEmpty) return null;

    final baseUnion = _computeSourceUnionRect(
      rects,
      gridCols,
      gridRows,
      cellWidth,
      cellHeight,
    );
    if (baseUnion == null) return null;

    final expandedUnion = _expandUnionForMovingTransforms(
      baseUnion: baseUnion,
      cellIndices: cellIndices,
      gridCols: gridCols,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      activeTransforms: activeTransforms,
    );

    final paddedRect = ui.Rect.fromLTRB(
      expandedUnion.left - pad.left * cellWidth,
      expandedUnion.top - pad.top * cellHeight,
      expandedUnion.right + pad.right * cellWidth,
      expandedUnion.bottom + pad.bottom * cellHeight,
    );
    final clipped = _clipAndCapLogicalRect(paddedRect, paneLogicalSize);
    if (clipped == null) return null;

    final dpr = devicePixelRatio.isFinite && devicePixelRatio > 0.0
        ? devicePixelRatio
        : 1.0;
    final physLeft = (clipped.left * dpr).floorToDouble();
    final physTop = (clipped.top * dpr).floorToDouble();
    final maxPhysW = math.max(1, (maxRegionLogicalExtent * dpr).round());
    final maxPhysH = math.max(1, (maxRegionLogicalExtent * dpr).round());
    final physW = (clipped.width * dpr).ceil().clamp(1, maxPhysW);
    final physH = (clipped.height * dpr).ceil().clamp(1, maxPhysH);
    final outputPhysical = ui.Rect.fromLTWH(
      physLeft,
      physTop,
      physW.toDouble(),
      physH.toDouble(),
    );

    return ComputedShaderRegionLayout(
      region: region,
      layoutId: layoutId,
      sourceUnionLogical: expandedUnion,
      outputRectLogical: clipped,
      outputRectPhysical: outputPhysical,
      physicalWidth: physW,
      physicalHeight: physH,
      sourceCellIndices: cellIndices,
    );
  }

  static List<int> _collectSourceCellIndices(
    List<tui_geo.Rect> sourceRects,
    int cols,
    int rows,
  ) {
    final clamped = _clampValidSourceRects(sourceRects, cols, rows);
    if (clamped.isEmpty) return const <int>[];
    if (clamped.length == 1) {
      return _collectSingleRectIndices(clamped.first, cols);
    }

    final (minY, maxY) = _verticalBounds(clamped, rows);
    final out = <int>[];
    final rowSpans = <(int, int)>[];
    for (var y = minY; y < maxY; y++) {
      _collectRowSpans(clamped, y, rowSpans);
      if (rowSpans.isEmpty) continue;
      _appendMergedRowSpans(out, y * cols, rowSpans);
    }
    return out;
  }

  static (int, int) _verticalBounds(List<tui_geo.Rect> rects, int rows) {
    var minY = rows;
    var maxY = 0;
    for (final rect in rects) {
      if (rect.y < minY) minY = rect.y;
      final endY = rect.y + rect.height;
      if (endY > maxY) maxY = endY;
    }
    return (minY, maxY);
  }

  static void _collectRowSpans(
    List<tui_geo.Rect> rects,
    int y,
    List<(int, int)> outSpans,
  ) {
    outSpans.clear();
    for (final rect in rects) {
      if (y >= rect.y && y < rect.y + rect.height) {
        outSpans.add((rect.x, rect.x + rect.width));
      }
    }
  }

  static List<int> _collectSingleRectIndices(tui_geo.Rect rect, int cols) {
    final out = <int>[];
    final maxY = rect.y + rect.height;
    final maxX = rect.x + rect.width;
    for (var y = rect.y; y < maxY; y++) {
      final rowBase = y * cols;
      for (var x = rect.x; x < maxX; x++) {
        out.add(rowBase + x);
      }
    }
    return out;
  }

  static void _appendMergedRowSpans(
    List<int> out,
    int rowBase,
    List<(int, int)> spans,
  ) {
    spans.sort((a, b) => a.$1.compareTo(b.$1));
    var curStart = spans.first.$1;
    var curEnd = spans.first.$2;
    for (var i = 1; i < spans.length; i++) {
      final span = spans[i];
      if (span.$1 <= curEnd) {
        if (span.$2 > curEnd) curEnd = span.$2;
        continue;
      }
      for (var x = curStart; x < curEnd; x++) {
        out.add(rowBase + x);
      }
      curStart = span.$1;
      curEnd = span.$2;
    }
    for (var x = curStart; x < curEnd; x++) {
      out.add(rowBase + x);
    }
  }

  static ui.Rect? _computeSourceUnionRect(
    List<tui_geo.Rect> sourceRects,
    int cols,
    int rows,
    double cellW,
    double cellH,
  ) {
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (final rect in sourceRects) {
      final x0 = rect.x.clamp(0, cols) * cellW;
      final y0 = rect.y.clamp(0, rows) * cellH;
      final x1 = (rect.x + rect.width).clamp(0, cols) * cellW;
      final y1 = (rect.y + rect.height).clamp(0, rows) * cellH;
      if (x1 <= x0 || y1 <= y0) continue;
      if (x0 < minX) minX = x0;
      if (y0 < minY) minY = y0;
      if (x1 > maxX) maxX = x1;
      if (y1 > maxY) maxY = y1;
    }
    if (!minX.isFinite || maxX <= minX || maxY <= minY) return null;
    return ui.Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  static ui.Rect _expandUnionForMovingTransforms({
    required ui.Rect baseUnion,
    required List<int> cellIndices,
    required int gridCols,
    required double cellWidth,
    required double cellHeight,
    required Map<int, EvaluatedCellTransform>? activeTransforms,
  }) {
    if (activeTransforms == null || activeTransforms.isEmpty) return baseUnion;
    var union = baseUnion;
    for (final idx in cellIndices) {
      final pose = activeTransforms[idx];
      if (pose == null || !pose.isVisible) continue;
      final col = idx % gridCols;
      final row = idx ~/ gridCols;
      final glyphRect = _transformedGlyphLogicalRect(
        col,
        row,
        cellWidth,
        cellHeight,
        pose,
      );
      final candidate = union.expandToInclude(glyphRect);
      if (candidate.width <= maxRegionLogicalExtent &&
          candidate.height <= maxRegionLogicalExtent) {
        union = candidate;
      }
    }
    return union;
  }

  static ui.Rect _transformedGlyphLogicalRect(
    int col,
    int row,
    double cellW,
    double cellH,
    EvaluatedCellTransform pose,
  ) {
    final cx = (col + 0.5 + pose.dx) * cellW;
    final cy = (row + 0.5 + pose.dy) * cellH;
    final halfW = cellW * 0.5 * pose.scaleX;
    final halfH = cellH * 0.5 * pose.scaleY;
    if (pose.rotationRad == 0.0) {
      return ui.Rect.fromLTRB(cx - halfW, cy - halfH, cx + halfW, cy + halfH);
    }
    final c = math.cos(pose.rotationRad).abs();
    final s = math.sin(pose.rotationRad).abs();
    final rotHalfW = halfW * c + halfH * s;
    final rotHalfH = halfW * s + halfH * c;
    return ui.Rect.fromLTRB(
      cx - rotHalfW,
      cy - rotHalfH,
      cx + rotHalfW,
      cy + rotHalfH,
    );
  }

  static ui.Rect? _clipAndCapLogicalRect(ui.Rect rect, ui.Size paneSize) {
    final paneRect = ui.Rect.fromLTWH(
      0.0,
      0.0,
      paneSize.width,
      paneSize.height,
    );
    var clipped = rect.intersect(paneRect);
    if (clipped.width <= 0.0 || clipped.height <= 0.0) return null;
    if (clipped.width > maxRegionLogicalExtent ||
        clipped.height > maxRegionLogicalExtent) {
      final cappedW = math.min(clipped.width, maxRegionLogicalExtent);
      final cappedH = math.min(clipped.height, maxRegionLogicalExtent);
      final center = clipped.center;
      final left = (center.dx - cappedW * 0.5)
          .clamp(0.0, math.max(0.0, paneSize.width - cappedW))
          .toDouble();
      final top = (center.dy - cappedH * 0.5)
          .clamp(0.0, math.max(0.0, paneSize.height - cappedH))
          .toDouble();
      clipped = ui.Rect.fromLTWH(left, top, cappedW, cappedH);
    }
    return clipped;
  }
}

/// Staged GPU region-mask instance buffer and per-region slice table.
typedef StagedRegionMasksResult = ({
  Float32List data,
  int count,
  int generation,
  List<GpuRegionMaskSlice> slices,
  List<ComputedShaderRegionLayout> layouts,
  bool hasCanvasOnlyFallback,
});

/// Packs tight `uGlyphMask` glyph instances for up to `8` active
/// [ShaderRegion]s into one contiguous GPU instance buffer.
final class ShaderRegionGpuStager {
  final CellTransformGpuStager _maskStager = CellTransformGpuStager();

  /// Stages up to [ShaderRegion.maxRegionsPerPane] (`8`) active regions in
  /// ascending `zIndex` order, emitting ONLY glyphs inside each region's
  /// `sourceRects` shifted into mask-local physical coordinates.
  StagedRegionMasksResult stageRegionMasks({
    required Buffer buffer,
    required GlyphAtlas atlas,
    required List<ShaderRegion> regions,
    required ui.Size paneLogicalSize,
    required double devicePixelRatio,
    required int defaultForegroundArgb,
    required int defaultBackgroundArgb,
    required double faintOpacity,
    required TerminalColorTheme palette,
    Map<int, EvaluatedCellTransform>? activeTransforms,
    bool Function(String shaderId)? isShaderQuarantined,
  }) {
    _maskStager.resetWriteCursor();
    if (regions.isEmpty) {
      final gen = _maskStager.commitGeneration();
      return (
        data: _maskStager.buffer,
        count: 0,
        generation: gen,
        slices: const <GpuRegionMaskSlice>[],
        layouts: const <ComputedShaderRegionLayout>[],
        hasCanvasOnlyFallback: false,
      );
    }

    final ordered = _selectActiveRegions(regions, isShaderQuarantined);
    final candidateLayouts = <ComputedShaderRegionLayout>[];
    for (final region in ordered) {
      if (candidateLayouts.length >= ShaderRegion.maxRegionsPerPane) break;
      final regionLayouts = ComputedShaderRegionLayout.computeAll(
        region: region,
        gridCols: buffer.width,
        gridRows: buffer.height,
        cellWidth: atlas.cellWidth,
        cellHeight: atlas.cellHeight,
        paneLogicalSize: paneLogicalSize,
        devicePixelRatio: devicePixelRatio,
        activeTransforms: activeTransforms,
      );
      for (final layout in regionLayouts) {
        if (candidateLayouts.length >= ShaderRegion.maxRegionsPerPane) break;
        candidateLayouts.add(layout);
      }
    }
    final layouts = ComputedShaderRegionLayout.applyPanePixelBudget(
      candidateLayouts,
    );
    final slices = <GpuRegionMaskSlice>[];
    final invAtlasW = atlas.image.width > 0 ? 1.0 / atlas.image.width : 0.0;
    final invAtlasH = atlas.image.height > 0 ? 1.0 / atlas.image.height : 0.0;
    var hasCanvasFallback = false;

    for (final layout in layouts) {
      final startIdx = _maskStager.count;
      final ok = _stageSingleRegionMask(
        layout: layout,
        buffer: buffer,
        atlas: atlas,
        activeTransforms: activeTransforms,
        dpr: devicePixelRatio,
        invAtlasW: invAtlasW,
        invAtlasH: invAtlasH,
        defaultForegroundArgb: defaultForegroundArgb,
        defaultBackgroundArgb: defaultBackgroundArgb,
        faintOpacity: faintOpacity,
        palette: palette,
      );
      if (!ok) hasCanvasFallback = true;

      slices.add(
        GpuRegionMaskSlice(
          regionId: layout.layoutId,
          startInstance: startIdx,
          instanceCount: _maskStager.count - startIdx,
          outputRectPhysical: layout.outputRectPhysical,
        ),
      );
    }

    final gen = _maskStager.commitGeneration();
    return (
      data: _maskStager.buffer,
      count: _maskStager.count,
      generation: gen,
      slices: slices,
      layouts: layouts,
      hasCanvasOnlyFallback: hasCanvasFallback,
    );
  }

  bool _stageSingleRegionMask({
    required ComputedShaderRegionLayout layout,
    required Buffer buffer,
    required GlyphAtlas atlas,
    required Map<int, EvaluatedCellTransform>? activeTransforms,
    required double dpr,
    required double invAtlasW,
    required double invAtlasH,
    required int defaultForegroundArgb,
    required int defaultBackgroundArgb,
    required double faintOpacity,
    required TerminalColorTheme palette,
  }) {
    var allSupported = true;
    final cols = buffer.width;
    final originX = layout.outputRectPhysical.left;
    final originY = layout.outputRectPhysical.top;
    for (final cellIdx in layout.sourceCellIndices) {
      final pose =
          activeTransforms?[cellIdx] ?? EvaluatedCellTransform.identity;
      final ok = _maskStager.appendCellInstances(
        buffer: buffer,
        atlas: atlas,
        col: cellIdx % cols,
        row: cellIdx ~/ cols,
        pose: pose,
        originOffsetPhysX: originX,
        originOffsetPhysY: originY,
        devicePixelRatio: dpr,
        invAtlasW: invAtlasW,
        invAtlasH: invAtlasH,
        defaultForegroundArgb: defaultForegroundArgb,
        defaultBackgroundArgb: defaultBackgroundArgb,
        faintOpacity: faintOpacity,
        palette: palette,
      );
      if (!ok) allSupported = false;
    }
    return allSupported;
  }

  static List<ShaderRegion> _selectActiveRegions(
    List<ShaderRegion> regions,
    bool Function(String shaderId)? isQuarantined,
  ) {
    final active = <ShaderRegion>[
      for (final r in regions)
        if (!(isQuarantined?.call(r.shaderId) ?? false)) r,
    ];
    active.sort((a, b) => a.zIndex.compareTo(b.zIndex));
    if (active.length <= ShaderRegion.maxRegionsPerPane) return active;
    return active.sublist(0, ShaderRegion.maxRegionsPerPane);
  }
}

/// Manages compiled built-in region presets and CLI-uploaded custom GLSL
/// shaders with a `4s` compile timeout, `32 KiB` source cap, `16`-slot limit,
/// and per-shader-ID quarantine enforcement.
final class CliShaderRegistry extends ChangeNotifier {
  /// Maximum compilation timeout enforced for CLI-uploaded shaders (`4s`).
  static const Duration cliCompileTimeout = Duration(seconds: 4);

  /// Maximum simultaneous custom CLI shader slots permitted per pane (`16`).
  static const int maxCliShaderSlots = 16;

  /// Maximum UTF-8 byte length permitted for a single CLI GLSL shader (`32 KiB`).
  static const int maxCliSourceBytes = 32768;

  TerminalShaderBackend? _backend;
  GpuFrameWatchdog? _watchdog;

  final Map<String, _CompiledCliEntry> _entries = <String, _CompiledCliEntry>{};
  final Map<String, Future<CompiledShaderHandle?>> _inFlight =
      <String, Future<CompiledShaderHandle?>>{};
  final Set<String> _quarantinedIds = <String>{};

  ShaderCompileException? _lastError;
  bool _disposed = false;

  /// Creates a [CliShaderRegistry] optionally bound to [backend] and [watchdog].
  CliShaderRegistry({
    TerminalShaderBackend? backend,
    GpuFrameWatchdog? watchdog,
  }) {
    _backend = backend;
    _watchdog = watchdog;
  }

  /// Most recent CLI shader compile or timeout error, if any.
  ShaderCompileException? get lastError => _lastError;

  /// Active compiled shader IDs (both presets and custom CLI slots).
  Set<String> get compiledShaderIds => Set<String>.unmodifiable(_entries.keys);

  /// Active non-quarantined custom CLI shader IDs currently registered.
  Set<String> get activeCustomShaderIds => Set<String>.unmodifiable(<String>{
    for (final entry in _entries.values)
      if (entry.isCustomCli && !isQuarantined(entry.id)) entry.id,
  });

  /// Number of currently live custom CLI shader slots (`<= 16`).
  int get customCliSlotCount =>
      _entries.values.where((entry) => entry.isCustomCli).length;

  /// Whether any compiled non-quarantined region shader uses `iTime`/`iFrame`.
  bool get anyShaderUsesTime => _entries.values.any(
    (entry) => !isQuarantined(entry.id) && entry.analysis.usesTime,
  );

  /// Whether any compiled non-quarantined region shader uses `iMouse`.
  bool get anyShaderUsesMouse => _entries.values.any(
    (entry) => !isQuarantined(entry.id) && entry.analysis.usesMouse,
  );

  /// Whether [shaderId] is a custom CLI shader (as opposed to a built-in preset).
  bool isCustomShader(String shaderId) =>
      _entries[shaderId]?.isCustomCli ?? false;

  /// Whether [shaderId] has been quarantined by the watchdog or explicitly.
  bool isQuarantined(String shaderId) {
    if (ShaderRegionPresets.isPreset(shaderId)) return false;
    return _quarantinedIds.contains(shaderId) ||
        (_watchdog?.isQuarantined(shaderId) ?? false);
  }

  /// Attaches or replaces the active [GpuFrameWatchdog].
  void attachWatchdog(GpuFrameWatchdog? watchdog) {
    _watchdog = watchdog;
    _watchdog?.setActiveCustomShaders(activeCustomShaderIds);
  }

  /// Attaches or switches the backing [TerminalShaderBackend], disposing stale
  /// handles from the previous backend.
  void attachBackend(TerminalShaderBackend? backend) {
    if (identical(_backend, backend)) return;
    _disposeAllEntries();
    _inFlight.clear();
    _backend = backend;
    _watchdog?.setActiveCustomShaders(const <String>[]);
    if (!_disposed) notifyListeners();
  }

  /// Returns the compiled [CompiledShaderHandle] for [shaderId], or `null` if
  /// uncompiled or quarantined.
  CompiledShaderHandle? handleForShader(String shaderId) {
    if (isQuarantined(shaderId)) return null;
    return _entries[shaderId]?.handle;
  }

  /// Registers and compiles a custom CLI GLSL [source] under [id] with a
  /// bounded [timeout] (defaults to `4s`).
  ///
  /// Throws [ShaderCompileException] if [source] exceeds [maxCliSourceBytes],
  /// slot count exceeds [maxCliShaderSlots], compilation fails, or [timeout]
  /// expires.
  Future<CompiledShaderHandle?> registerCliShader({
    required String id,
    required String source,
    bool usesPrevFrame = false,
    Duration timeout = cliCompileTimeout,
  }) {
    if (_disposed) return Future<CompiledShaderHandle?>.value();
    final backend = _backend;
    if (backend == null || !backend.supportsCustomGlsl) {
      return Future<CompiledShaderHandle?>.value();
    }
    if (isQuarantined(id)) {
      return Future<CompiledShaderHandle?>.value();
    }
    final byteLen = utf8.encode(source).length;
    if (byteLen > maxCliSourceBytes) {
      final err = ShaderCompileException(
        shaderId: id,
        message:
            'CLI shader source is $byteLen bytes, exceeding the '
            '$maxCliSourceBytes byte (32 KiB) limit.',
      );
      _lastError = err;
      return Future<CompiledShaderHandle?>.error(err);
    }
    final existing = _entries[id];
    if (existing != null &&
        existing.source == source &&
        (!usesPrevFrame || existing.handle.usesPrevFrame)) {
      return Future<CompiledShaderHandle?>.value(existing.handle);
    }
    if (existing == null && customCliSlotCount >= maxCliShaderSlots) {
      final err = ShaderCompileException(
        shaderId: id,
        message: 'CLI shader slot cap ($maxCliShaderSlots) reached.',
      );
      _lastError = err;
      return Future<CompiledShaderHandle?>.error(err);
    }
    return _compileShaderDedup(
      id: id,
      source: source,
      usesPrevFrame: usesPrevFrame,
      isCustomCli: true,
      timeout: timeout,
    );
  }

  /// Ensures the shader referenced by [region] (either a built-in preset or an
  /// inline [CustomGlslShaderRef]) is compiled for the current backend.
  Future<CompiledShaderHandle?> ensureRegionShaderCompiled(
    ShaderRegion region,
  ) {
    if (_disposed || isQuarantined(region.shaderId)) {
      return Future<CompiledShaderHandle?>.value();
    }
    final existing = _entries[region.shaderId];
    if (existing != null &&
        (!region.persist || existing.handle.usesPrevFrame)) {
      return Future<CompiledShaderHandle?>.value(existing.handle);
    }
    final presetSource = ShaderRegionPresets.sourceFor(region.shaderId);
    if (presetSource != null) {
      return _compileShaderDedup(
        id: region.shaderId,
        source: presetSource,
        usesPrevFrame: region.persist,
        isCustomCli: false,
        timeout: cliCompileTimeout,
      );
    }
    final ref = region.shaderRef;
    if (ref is CustomGlslShaderRef) {
      return registerCliShader(
        id: region.shaderId,
        source: ref.source,
        usesPrevFrame: region.persist || ref.persist,
      );
    }
    return Future<CompiledShaderHandle?>.value();
  }

  /// Removes and disposes a compiled custom CLI shader [id].
  void removeCliShader(String id) {
    final removed = _entries.remove(id);
    removed?.handle.dispose();
    _quarantinedIds.remove(id);
    _watchdog?.clearQuarantine(id);
    _watchdog?.setActiveCustomShaders(activeCustomShaderIds);
    if (removed != null && !_disposed) notifyListeners();
  }

  /// Removes and disposes all custom CLI shaders while preserving built-in presets.
  void clearCliShaders() {
    final customIds = <String>[
      for (final entry in _entries.values)
        if (entry.isCustomCli) entry.id,
    ];
    for (final id in customIds) {
      _entries.remove(id)?.handle.dispose();
      _quarantinedIds.remove(id);
    }
    _watchdog?.setActiveCustomShaders(const <String>[]);
    if (customIds.isNotEmpty && !_disposed) notifyListeners();
  }

  /// Quarantines custom CLI shader [id] on this pane (built-in presets are
  /// exempt) and notifies listeners so rendering skips it immediately.
  void quarantineShader(String id, String reason) {
    if (_disposed || ShaderRegionPresets.isPreset(id)) return;
    _quarantinedIds.add(id);
    _watchdog?.quarantineShader(id, reason);
    _watchdog?.setActiveCustomShaders(activeCustomShaderIds);
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _disposeAllEntries();
    _inFlight.clear();
    _quarantinedIds.clear();
    super.dispose();
  }

  Future<CompiledShaderHandle?> _compileShaderDedup({
    required String id,
    required String source,
    required bool usesPrevFrame,
    required bool isCustomCli,
    required Duration timeout,
  }) {
    final activeFuture = _inFlight[id];
    if (activeFuture != null) return activeFuture;

    final future = _compileShaderInternal(
      id: id,
      source: source,
      usesPrevFrame: usesPrevFrame,
      isCustomCli: isCustomCli,
      timeout: timeout,
    );
    _inFlight[id] = future;
    return future;
  }

  Future<CompiledShaderHandle?> _compileShaderInternal({
    required String id,
    required String source,
    required bool usesPrevFrame,
    required bool isCustomCli,
    required Duration timeout,
  }) async {
    final backend = _backend;
    if (_disposed || backend == null || !backend.supportsCustomGlsl) {
      return null;
    }
    try {
      final analysis = ShadertoyGlslShim.analyze(source, shaderId: id);
      final handle = await backend
          .compile(
            id,
            source,
            usesPrevFrame: usesPrevFrame || analysis.usesPrevFrame,
          )
          .timeout(
            timeout,
            onTimeout: () => throw ShaderCompileException(
              shaderId: id,
              message:
                  'CLI shader compilation timed out after '
                  '${timeout.inSeconds}s.',
            ),
          );
      if (_disposed || !identical(_backend, backend) || isQuarantined(id)) {
        handle.dispose();
        return null;
      }
      _entries.remove(id)?.handle.dispose();
      _entries[id] = _CompiledCliEntry(
        id: id,
        source: source,
        handle: handle,
        analysis: analysis,
        isCustomCli: isCustomCli,
      );
      _lastError = null;
      _watchdog?.setActiveCustomShaders(activeCustomShaderIds);
      notifyListeners();
      return handle;
    } on ShaderCompileException catch (err) {
      _lastError = err;
      if (isCustomCli) rethrow;
      return null;
    } finally {
      _inFlight.remove(id);
    }
  }

  void _disposeAllEntries() {
    final list = _entries.values.toList(growable: false);
    _entries.clear();
    for (final entry in list) {
      entry.handle.dispose();
    }
  }
}

final class _CompiledCliEntry {
  final String id;
  final String source;
  final CompiledShaderHandle handle;
  final ShadertoyGlslAnalysis analysis;
  final bool isCustomCli;

  const _CompiledCliEntry({
    required this.id,
    required this.source,
    required this.handle,
    required this.analysis,
    required this.isCustomCli,
  });
}

/// Rendered region output image paired with its logical placement and stage
/// for Canvas-fallback compositing.
final class RenderedShaderRegionImage {
  /// Stable region identifier.
  final String regionId;

  /// Compositing stage (`underGlyphs`, `replaceGlyphs`, or `overGlyphs`).
  final ShaderRegionStage stage;

  /// Ascending stacking order.
  final int zIndex;

  /// Logical destination rectangle on the terminal pane viewport.
  final ui.Rect outputRectLogical;

  /// GPU-rendered region image owned by the host and disposed post-frame.
  final ui.Image image;

  /// Creates a rendered region output record.
  const RenderedShaderRegionImage({
    required this.regionId,
    required this.stage,
    required this.zIndex,
    required this.outputRectLogical,
    required this.image,
  });
}

/// Canvas-fallback `PictureRecorder` + `renderPassesAsync` stager ensuring
/// [ShaderRegion] effects still render when ligatures or unbaked fallback
/// glyphs temporarily drop a pane out of direct GPU mode.
final class ShaderRegionCanvasStager {
  final CellTransformPainter _transformPainter = CellTransformPainter();

  /// Renders isolated `uGlyphMask` images via `ui.PictureRecorder` and executes
  /// each active region pass asynchronously via [backend.renderPassesAsync].
  Future<List<RenderedShaderRegionImage>> renderRegionsFallbackAsync({
    required TerminalShaderBackend backend,
    required Buffer buffer,
    required GlyphAtlas atlas,
    required List<ComputedShaderRegionLayout> layouts,
    required List<ShaderRegionPassInvocation> passes,
    required double devicePixelRatio,
    required int defaultForegroundArgb,
    required int defaultBackgroundArgb,
    required double faintOpacity,
    required TerminalColorTheme palette,
    required String fontFamily,
    required List<String>? fontFamilyFallback,
    required Map<(String, bool, bool, bool, Color), TextPainter>
    fallbackPainters,
    Map<int, EvaluatedCellTransform>? activeTransforms,
    ui.Image? wallpaperImage,
    GpuFrameWatchdog? watchdog,
  }) async {
    if (layouts.isEmpty || passes.isEmpty) {
      return const <RenderedShaderRegionImage>[];
    }
    final layoutById = <String, ComputedShaderRegionLayout>{
      for (final layout in layouts) layout.layoutId: layout,
    };
    final outputs = <RenderedShaderRegionImage>[];
    for (final pass in passes) {
      final layout = layoutById[pass.regionId];
      if (layout == null) continue;
      final rendered = await _renderSingleRegionFallback(
        backend: backend,
        buffer: buffer,
        atlas: atlas,
        layout: layout,
        pass: pass,
        dpr: devicePixelRatio,
        defaultForegroundArgb: defaultForegroundArgb,
        defaultBackgroundArgb: defaultBackgroundArgb,
        faintOpacity: faintOpacity,
        palette: palette,
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
        fallbackPainters: fallbackPainters,
        activeTransforms: activeTransforms,
        wallpaperImage: wallpaperImage,
        watchdog: watchdog,
      );
      if (rendered != null) outputs.add(rendered);
    }
    return outputs;
  }

  Future<RenderedShaderRegionImage?> _renderSingleRegionFallback({
    required TerminalShaderBackend backend,
    required Buffer buffer,
    required GlyphAtlas atlas,
    required ComputedShaderRegionLayout layout,
    required ShaderRegionPassInvocation pass,
    required double dpr,
    required int defaultForegroundArgb,
    required int defaultBackgroundArgb,
    required double faintOpacity,
    required TerminalColorTheme palette,
    required String fontFamily,
    required List<String>? fontFamilyFallback,
    required Map<(String, bool, bool, bool, Color), TextPainter>
    fallbackPainters,
    Map<int, EvaluatedCellTransform>? activeTransforms,
    ui.Image? wallpaperImage,
    GpuFrameWatchdog? watchdog,
  }) async {
    final maskImage = await _rasterizeGlyphMask(
      buffer: buffer,
      atlas: atlas,
      layout: layout,
      dpr: dpr,
      defaultForegroundArgb: defaultForegroundArgb,
      defaultBackgroundArgb: defaultBackgroundArgb,
      faintOpacity: faintOpacity,
      palette: palette,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fallbackPainters: fallbackPainters,
      activeTransforms: activeTransforms,
    );
    try {
      final output = await backend.renderPassesAsync(
        passes: <ShaderPassInvocation>[pass.toPassInvocation()],
        physicalSize: ui.Size(
          layout.physicalWidth.toDouble(),
          layout.physicalHeight.toDouble(),
        ),
        inputImage: maskImage,
        wallpaperImage: wallpaperImage,
        watchdog: watchdog,
      );
      if (output == null) return null;
      return RenderedShaderRegionImage(
        regionId: pass.regionId,
        stage: pass.stage,
        zIndex: pass.zIndex,
        outputRectLogical: layout.outputRectLogical,
        image: output,
      );
    } finally {
      maskImage.dispose();
    }
  }

  Future<ui.Image> _rasterizeGlyphMask({
    required Buffer buffer,
    required GlyphAtlas atlas,
    required ComputedShaderRegionLayout layout,
    required double dpr,
    required int defaultForegroundArgb,
    required int defaultBackgroundArgb,
    required double faintOpacity,
    required TerminalColorTheme palette,
    required String fontFamily,
    required List<String>? fontFamilyFallback,
    required Map<(String, bool, bool, bool, Color), TextPainter>
    fallbackPainters,
    Map<int, EvaluatedCellTransform>? activeTransforms,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(dpr, dpr);
    canvas.translate(
      -layout.outputRectLogical.left,
      -layout.outputRectLogical.top,
    );
    final cols = buffer.width;
    final entries = <EvaluatedCellEntry>[
      for (final idx in layout.sourceCellIndices)
        (
          cellIndex: idx,
          col: idx % cols,
          row: idx ~/ cols,
          pose: activeTransforms?[idx] ?? EvaluatedCellTransform.identity,
        ),
    ];
    _transformPainter.paintCanvas(
      canvas: canvas,
      viewportSize: ui.Size(
        layout.outputRectLogical.right,
        layout.outputRectLogical.bottom,
      ),
      buffer: buffer,
      atlas: atlas,
      entries: entries,
      defaultForegroundArgb: defaultForegroundArgb,
      defaultBackgroundArgb: defaultBackgroundArgb,
      faintOpacity: faintOpacity,
      palette: palette,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fallbackPainters: fallbackPainters,
    );
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(layout.physicalWidth, layout.physicalHeight);
    } finally {
      picture.dispose();
    }
  }
}
