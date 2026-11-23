import 'dart:typed_data';

/// Shared instanced terminal atlas shaders and geometry helpers for both
/// Web (`WebGL2` GLSL ES 3.00) and Native Desktop (`flutter_gpu` / Impeller
/// GLSL 460).
///
/// The single instanced quad program handles:
/// - `BoxFit.cover` wallpaper quads (when no background shader is active)
/// - Default terminal background fill (`modeFlags = 1.0`)
/// - Staged `bg`, `fg`, `emoji`, `italic` (+ synthetic bold-italic), and `deco`
///   atlas quads (`modeFlags = 0.0`)
/// - Coalesced Kitty graphics textured quads (`modeFlags = 0.0`, Kitty texture)
/// - `outOfBoundsDimming` scrim and 1 px border quads (`modeFlags = 1.0`)
abstract final class GpuAtlasShaders {
  /// Reflected uniform block name bound by Impeller (`flutter_gpu`).
  static const String uniformBlockName = 'AtlasUniforms';

  /// Uniform name for the physical viewport size (`vec2`) on WebGL2.
  static const String viewportUniformName = 'u_viewport_size';

  /// Sampler uniform name for the bound atlas, Kitty, or wallpaper texture.
  static const String atlasSamplerName = 'u_atlas';

  /// Impeller shader bundle vertex shader entry name.
  static const String impellerVertexName = 'GpuAtlasVertex';

  /// Impeller shader bundle fragment shader entry name.
  static const String impellerFragmentName = 'GpuAtlasFragment';

  /// Byte size of the Impeller `std140` `AtlasUniforms` UBO (`vec2` + `vec2`).
  static const int impellerUniformByteLength = 16;

  /// Vertex attribute name for unit quad corner `[0, 1]^2` (`loc 0`).
  static const String attrCorner = 'a_corner';

  /// Vertex attribute name for per-instance destination rect (`loc 1`).
  static const String attrDstRect = 'a_dst_rect';

  /// Vertex attribute name for per-instance normalized UV rect (`loc 2`).
  static const String attrUvRect = 'a_uv_rect';

  /// Vertex attribute name for per-instance premultiplied RGBA color (`loc 3`).
  static const String attrColor = 'a_color';

  /// Vertex attribute name for per-instance shear, mode flags, and rotation (`loc 4`).
  ///
  /// Layout: `(shearSlopeX, shearOriginY, modeFlags, rotationRad)`.
  static const String attrExtra = 'a_extra';

  /// 6-vertex (2-triangle) unit quad in `[0, 1]^2` for `loc 0` (`a_corner`).
  ///
  /// Counter-clockwise winding in screen coordinates:
  /// `(0,0) -> (1,0) -> (0,1)` and `(1,0) -> (1,1) -> (0,1)`.
  static final Float32List unitQuadVertices = Float32List.fromList(
    const <double>[
      0.0, 0.0, // top-left
      1.0, 0.0, // top-right
      0.0, 1.0, // bottom-left
      1.0, 0.0, // top-right
      1.0, 1.0, // bottom-right
      0.0, 1.0, // bottom-left
    ],
  );

  /// Computes normalized `(u0, v0, u1, v1)` texture coordinates matching
  /// Flutter's `BoxFit.cover` centered inside `[viewportWidth] x [viewportHeight]`.
  static ({double u0, double v0, double u1, double v1}) computeCoverUvRect({
    required double imageWidth,
    required double imageHeight,
    required double viewportWidth,
    required double viewportHeight,
  }) {
    if (imageWidth <= 0.0 ||
        imageHeight <= 0.0 ||
        viewportWidth <= 0.0 ||
        viewportHeight <= 0.0) {
      return (u0: 0.0, v0: 0.0, u1: 1.0, v1: 1.0);
    }
    final imageAspect = imageWidth / imageHeight;
    final viewportAspect = viewportWidth / viewportHeight;
    if (imageAspect > viewportAspect) {
      final visibleWidthFraction = viewportAspect / imageAspect;
      final inset = (1.0 - visibleWidthFraction) * 0.5;
      return (u0: inset, v0: 0.0, u1: 1.0 - inset, v1: 1.0);
    }
    final visibleHeightFraction = imageAspect / viewportAspect;
    final inset = (1.0 - visibleHeightFraction) * 0.5;
    return (u0: 0.0, v0: inset, u1: 1.0, v1: 1.0 - inset);
  }

  /// Packs a single untinted textured quad (such as a `BoxFit.cover` wallpaper
  /// or Kitty graphics quad) into [out] at offset `0` (`16` floats).
  static void writeTexturedQuadInstance(
    Float32List out, {
    required double dstX,
    required double dstY,
    required double dstWidth,
    required double dstHeight,
    required double u0,
    required double v0,
    required double u1,
    required double v1,
  }) {
    out[0] = dstX;
    out[1] = dstY;
    out[2] = dstWidth;
    out[3] = dstHeight;
    out[4] = u0;
    out[5] = v0;
    out[6] = u1;
    out[7] = v1;
    out[8] = 1.0;
    out[9] = 1.0;
    out[10] = 1.0;
    out[11] = 1.0;
    out[12] = 0.0;
    out[13] = 0.0;
    out[14] = 0.0;
    out[15] = 0.0;
  }

  /// WebGL2 GLSL ES 3.00 instanced atlas vertex shader.
  static const String webgl2VertexSource =
      '''
#version 300 es
precision highp float;

uniform vec2 $viewportUniformName;

layout(location = 0) in vec2 $attrCorner;
layout(location = 1) in vec4 $attrDstRect;
layout(location = 2) in vec4 $attrUvRect;
layout(location = 3) in vec4 $attrColor;
layout(location = 4) in vec4 $attrExtra;

out vec2 v_uv;
out vec4 v_color;
out float v_mode;

void main() {
  vec2 pos = $attrDstRect.xy + $attrCorner * $attrDstRect.zw;
  pos.x += $attrExtra.x * (pos.y - $attrExtra.y);
  if ($attrExtra.w != 0.0) {
    vec2 center = $attrDstRect.xy + $attrDstRect.zw * 0.5;
    vec2 rel = pos - center;
    float c = cos($attrExtra.w);
    float s = sin($attrExtra.w);
    pos = center + vec2(rel.x * c - rel.y * s, rel.x * s + rel.y * c);
  }
  vec2 ndc = vec2(
    (pos.x / $viewportUniformName.x) * 2.0 - 1.0,
    1.0 - (pos.y / $viewportUniformName.y) * 2.0
  );
  gl_Position = vec4(ndc, 0.0, 1.0);
  v_uv = mix($attrUvRect.xy, $attrUvRect.zw, $attrCorner);
  v_color = $attrColor;
  v_mode = $attrExtra.z;
}
''';

  /// WebGL2 GLSL ES 3.00 instanced atlas fragment shader.
  ///
  /// Outputs premultiplied RGBA compatible with `gl.blendFunc(ONE, ONE_MINUS_SRC_ALPHA)`.
  static const String webgl2FragmentSource =
      '''
#version 300 es
precision highp float;

uniform sampler2D $atlasSamplerName;

in vec2 v_uv;
in vec4 v_color;
in float v_mode;

out vec4 out_frag_color;

void main() {
  if (v_mode >= 0.5) {
    out_frag_color = v_color;
    return;
  }
  out_frag_color = texture($atlasSamplerName, v_uv) * v_color;
}
''';

  /// Impeller (`flutter_gpu`) GLSL 460 instanced atlas vertex shader.
  static const String impellerVertexSource =
      '''
#version 460 core

layout(set = 0, binding = 0, std140) uniform $uniformBlockName {
  vec2 $viewportUniformName;
  vec2 _pad0;
};

layout(location = 0) in vec2 $attrCorner;
layout(location = 1) in vec4 $attrDstRect;
layout(location = 2) in vec4 $attrUvRect;
layout(location = 3) in vec4 $attrColor;
layout(location = 4) in vec4 $attrExtra;

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec4 v_color;
layout(location = 2) out float v_mode;

void main() {
  vec2 pos = $attrDstRect.xy + $attrCorner * $attrDstRect.zw;
  pos.x += $attrExtra.x * (pos.y - $attrExtra.y);
  if ($attrExtra.w != 0.0) {
    vec2 center = $attrDstRect.xy + $attrDstRect.zw * 0.5;
    vec2 rel = pos - center;
    float c = cos($attrExtra.w);
    float s = sin($attrExtra.w);
    pos = center + vec2(rel.x * c - rel.y * s, rel.x * s + rel.y * c);
  }
  vec2 ndc = vec2(
    (pos.x / $viewportUniformName.x) * 2.0 - 1.0,
    1.0 - (pos.y / $viewportUniformName.y) * 2.0
  );
  gl_Position = vec4(ndc, 0.0, 1.0);
  v_uv = mix($attrUvRect.xy, $attrUvRect.zw, $attrCorner);
  v_color = $attrColor;
  v_mode = $attrExtra.z;
}
''';

  /// Impeller (`flutter_gpu`) GLSL 460 instanced atlas fragment shader.
  static const String impellerFragmentSource =
      '''
#version 460 core

layout(set = 0, binding = 1) uniform sampler2D $atlasSamplerName;

layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec4 v_color;
layout(location = 2) in float v_mode;

layout(location = 0) out vec4 out_frag_color;

void main() {
  if (v_mode >= 0.5) {
    out_frag_color = v_color;
    return;
  }
  out_frag_color = texture($atlasSamplerName, v_uv) * v_color;
}
''';
}
