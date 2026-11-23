import 'dart:convert';
import 'dart:typed_data';

import 'shader_backend.dart';
import 'shader_spec.dart';

/// Static analysis summary extracted from a user Ghostty Shadertoy `.glsl`
/// source prior to shimming.
final class ShadertoyGlslAnalysis {
  /// Whether the shader references `iTime`, `iTimeDelta`, or `iFrame`.
  final bool usesTime;

  /// Whether the shader references `iPrevFrame` for multi-frame persistence.
  final bool usesPrevFrame;

  /// Whether the shader references `iChannel0` (terminal frame or prior pass).
  final bool samplesChannel0;

  /// Whether the shader references `iChannel1` (wallpaper or image texture).
  final bool samplesChannel1;

  /// Whether the shader references cursor, focus, or foreground-text uniforms
  /// (`iCurrentCursor*`, `iPreviousCursor*`, `iCursorVisible`, `iFocus`,
  /// `iForegroundColor`, etc.).
  final bool usesCursorUniforms;

  /// Whether the shader references `iMouse` for live pointer interaction.
  final bool usesMouse;

  /// Recommended pipeline stage inferred from an optional
  /// `// @fterm-stage: bg | fg | both` comment directive or static uniform
  /// analysis.
  final ShaderStageHint stageHint;

  /// UTF-8 byte size of the validated input source.
  final int sourceByteLength;

  /// Creates an immutable static analysis report.
  const ShadertoyGlslAnalysis({
    required this.usesTime,
    required this.usesPrevFrame,
    required this.samplesChannel0,
    required this.samplesChannel1,
    required this.sourceByteLength,
    this.usesCursorUniforms = false,
    this.usesMouse = false,
    this.stageHint = ShaderStageHint.any,
  });
}

/// Complete shimmed shader sources generated from a single Ghostty Shadertoy
/// GLSL file for both Desktop Impeller (`flutter_gpu`) and Web (`WebGL2`).
final class ShimmedShaderPair {
  /// Static feature analysis of the validated user source.
  final ShadertoyGlslAnalysis analysis;

  /// Shared Impeller GLSL 460 full-screen vertex shader source.
  final String impellerVertexGlsl;

  /// Impeller GLSL 460 fragment shader wrapping the user's `mainImage`.
  final String impellerFragmentGlsl;

  /// Shared WebGL2 GLSL ES 3.00 full-screen vertex shader source.
  final String webgl2VertexGlsl;

  /// WebGL2 GLSL ES 3.00 fragment shader wrapping the user's `mainImage`.
  final String webgl2FragmentGlsl;

  /// Creates a shimmed shader output bundle.
  const ShimmedShaderPair({
    required this.analysis,
    required this.impellerVertexGlsl,
    required this.impellerFragmentGlsl,
    required this.webgl2VertexGlsl,
    required this.webgl2FragmentGlsl,
  });
}

/// Wraps verbatim Ghostty Shadertoy GLSL (`void mainImage(out vec4 fragColor,
/// in vec2 fragCoord)`) into Impeller GLSL 460 and WebGL2 GLSL ES 3.00 targets
/// with matching `std140` UBO layouts and per-backend UV V-flip wrappers.
abstract final class ShadertoyGlslShim {
  /// Maximum allowed UTF-8 byte size for a single user shader (`64 KiB`).
  static const int maxSourceBytes = 65536;

  /// Reflected uniform block name bound by both `flutter_gpu` and WebGL2.
  static const String uniformBlockName = 'TerminalUniforms';

  /// Vertex shader key used in `impellerc --shader-bundle` specs.
  static const String vertexShaderName = 'TerminalShaderVertex';

  /// Fragment shader key used in `impellerc --shader-bundle` specs.
  static const String fragmentShaderName = 'TerminalShaderFragment';

  /// Total `std140` byte size of [uniformBlockName].
  static const int uniformBufferByteLength = 4416;

  /// Shared Impeller GLSL 460 full-screen triangle vertex shader.
  ///
  /// Expects a 3-vertex NDC triangle (`(-1,-1), (3,-1), (-1,3)`) bound at
  /// attribute location `0` (`a_position`), producing Y-up `v_uv` in `[0, 1]`.
  static const String impellerVertexShaderSource = '''
#version 460 core

layout(location = 0) in vec2 a_position;
layout(location = 0) out vec2 v_uv;

void main() {
  v_uv = a_position * 0.5 + 0.5;
  gl_Position = vec4(a_position, 0.0, 1.0);
}
''';

  /// Shared WebGL2 GLSL ES 3.00 full-screen triangle vertex shader.
  static const String webgl2VertexShaderSource = '''
#version 300 es
precision highp float;

layout(location = 0) in vec2 a_position;
out vec2 v_uv;

void main() {
  v_uv = a_position * 0.5 + 0.5;
  gl_Position = vec4(a_position, 0.0, 1.0);
}
''';

  static final RegExp _includeDirectivePattern = RegExp(
    r'^\s*#\s*include\b',
    multiLine: true,
  );
  static final RegExp _versionDirectivePattern = RegExp(
    r'^\s*#\s*version\b',
    multiLine: true,
  );
  static final RegExp _timeUsagePattern = RegExp(
    r'\b(?:iTime|iTimeDelta|iFrame)\b',
  );
  static final RegExp _prevFramePattern = RegExp(r'\biPrevFrame\b');
  static final RegExp _mousePattern = RegExp(r'\biMouse\b');
  static final RegExp _channel0Pattern = RegExp(r'\biChannel0\b');
  static final RegExp _channel1Pattern = RegExp(r'\biChannel1\b');
  static final RegExp _cursorUniformPattern = RegExp(
    r'\b(?:iCurrentCursor|iPreviousCursor|iCurrentCursorColor|'
    r'iPreviousCursorColor|iCursorColor|iCurrentCursorStyle|'
    r'iTimeCursorChange|iCursorVisible|iFocus|iTimeFocus|'
    r'iForegroundColor|CURSORSTYLE_\w+)\b',
  );
  static final RegExp _stageDirectivePattern = RegExp(
    r'^\s*//\s*@(?:fterm-)?stage\s*:\s*(background|bg|foreground|fg|both|any)\b',
    multiLine: true,
    caseSensitive: false,
  );
  static final RegExp _mainImagePattern = RegExp(r'\bvoid\s+mainImage\s*\(');

  static const String _uboMembersGlsl = '''
  vec3 iResolution;
  float iTime;
  float iTimeDelta;
  float _termuiFrame;
  float iFrameRate;
  float iTimeCursorChange;
  vec4 iMouse;
  vec4 iDate;
  vec3 iChannelResolution[4];
  vec3 iPalette[256];
  vec3 iBackgroundColor;
  float _termuiFlipUvY;
  vec3 iForegroundColor;
  float _padFg;
  vec4 iCurrentCursor;
  vec4 iPreviousCursor;
  vec4 iCurrentCursorColor;
  vec4 iPreviousCursorColor;
  vec4 iCursorColor;
  float _termuiCurrentCursorStyle;
  float _termuiCursorVisible;
  float _termuiFocus;
  float iTimeFocus;
  vec4 iRegionRect;
  vec2 iCellSize;
  vec2 _padCell;
  vec4 uParams0;
  vec4 uParams1;''';

  static const String _cursorStyleConstantsGlsl = '''
const int CURSORSTYLE_BLOCK = 0;
const int CURSORSTYLE_BAR = 1;
const int CURSORSTYLE_UNDERLINE = 2;
const int CURSORSTYLE_BLOCK_HOLLOW = 3;
#define iFrame int(_termuiFrame)
#define iCurrentCursorStyle int(_termuiCurrentCursorStyle)
#define iCursorVisible int(_termuiCursorVisible)
#define iFocus int(_termuiFocus)''';

  static const String _impellerPrefix =
      '''
#version 460 core

layout(set = 0, binding = 0, std140) uniform $uniformBlockName {
$_uboMembersGlsl
};

layout(set = 0, binding = 1) uniform sampler2D iChannel0;
layout(set = 0, binding = 2) uniform sampler2D iChannel1;
layout(set = 0, binding = 3) uniform sampler2D iPrevFrame;

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_frag_color;

$_cursorStyleConstantsGlsl

// Impeller unifies offscreen render targets to a top-left texture origin across
// Metal, Vulkan (negative viewport height), and OpenGLES (`_impeller_y_flip`),
// while Shadertoy `v_uv` / `fragCoord` are Y-up (`0` at bottom, `1` at top).
vec2 _termuiFlipUv(vec2 uv) {
  return vec2(uv.x, 1.0 - uv.y);
}

vec4 _termuiSample(sampler2D s, vec2 uv) {
  return texture(s, _termuiFlipUv(uv));
}

vec4 _termuiSample(sampler2D s, vec2 uv, float bias) {
  return texture(s, _termuiFlipUv(uv), bias);
}

vec4 _termuiSampleLod(sampler2D s, vec2 uv, float lod) {
  return textureLod(s, _termuiFlipUv(uv), lod);
}

#define texture _termuiSample
#define texture2D texture
#define textureLod _termuiSampleLod
''';

  static const String _webgl2Prefix =
      '''
#version 300 es
precision highp float;
precision highp int;

layout(std140) uniform $uniformBlockName {
$_uboMembersGlsl
};

uniform sampler2D iChannel0;
uniform sampler2D iChannel1;
uniform sampler2D iPrevFrame;

in vec2 v_uv;
out vec4 out_frag_color;

$_cursorStyleConstantsGlsl

vec2 _termuiFlipUv(vec2 uv) {
  return vec2(uv.x, mix(uv.y, 1.0 - uv.y, _termuiFlipUvY));
}

vec4 _termuiSample(sampler2D s, vec2 uv) {
  return texture(s, _termuiFlipUv(uv));
}

vec4 _termuiSample(sampler2D s, vec2 uv, float bias) {
  return texture(s, _termuiFlipUv(uv), bias);
}

vec4 _termuiSampleLod(sampler2D s, vec2 uv, float lod) {
  return textureLod(s, _termuiFlipUv(uv), lod);
}

#define texture _termuiSample
#define texture2D texture
#define textureLod _termuiSampleLod
''';

  static const String _fragmentSuffix = '''

#undef iFocus
#undef iCursorVisible
#undef iCurrentCursorStyle
#undef iFrame
#undef textureLod
#undef texture2D
#undef texture

void main() {
  vec2 fragCoord = v_uv * iResolution.xy;
  vec4 color = vec4(0.0);
  mainImage(color, fragCoord);
  out_frag_color = color;
}
''';

  /// Validates and analyzes [source] without emitting target GLSL strings.
  ///
  /// Throws [ShaderCompileException] if [source] exceeds [maxSourceBytes],
  /// contains `#include` or `#version` directives, or omits `mainImage`.
  static ShadertoyGlslAnalysis analyze(
    String source, {
    String shaderId = '<inline>',
  }) {
    final byteLength = utf8.encode(source).length;
    if (byteLength == 0) {
      throw ShaderCompileException(
        shaderId: shaderId,
        message: 'Shader source is empty.',
      );
    }
    if (byteLength > maxSourceBytes) {
      throw ShaderCompileException(
        shaderId: shaderId,
        message:
            'Shader source is $byteLength bytes, exceeding the '
            '$maxSourceBytes byte (64 KiB) limit.',
      );
    }
    final stripped = _stripComments(source);
    if (_includeDirectivePattern.hasMatch(source) ||
        _includeDirectivePattern.hasMatch(stripped)) {
      throw ShaderCompileException(
        shaderId: shaderId,
        message: '#include directives are disallowed in custom shaders.',
      );
    }
    if (_versionDirectivePattern.hasMatch(stripped)) {
      throw ShaderCompileException(
        shaderId: shaderId,
        message:
            '#version directives must be omitted; ShadertoyGlslShim injects '
            'the target version header automatically.',
      );
    }
    if (!_mainImagePattern.hasMatch(stripped)) {
      throw ShaderCompileException(
        shaderId: shaderId,
        message:
            'Shader must define `void mainImage(out vec4 fragColor, '
            'in vec2 fragCoord)`.',
      );
    }
    final samplesChannel0 = _channel0Pattern.hasMatch(stripped);
    final samplesChannel1 = _channel1Pattern.hasMatch(stripped);
    final usesCursorUniforms = _cursorUniformPattern.hasMatch(stripped);
    final stageHint = _resolveStageHint(
      source: source,
      samplesChannel0: samplesChannel0,
      samplesChannel1: samplesChannel1,
      usesCursorUniforms: usesCursorUniforms,
    );
    return ShadertoyGlslAnalysis(
      usesTime: _timeUsagePattern.hasMatch(stripped),
      usesPrevFrame: _prevFramePattern.hasMatch(stripped),
      samplesChannel0: samplesChannel0,
      samplesChannel1: samplesChannel1,
      usesCursorUniforms: usesCursorUniforms,
      usesMouse: _mousePattern.hasMatch(stripped),
      stageHint: stageHint,
      sourceByteLength: byteLength,
    );
  }

  static ShaderStageHint _resolveStageHint({
    required String source,
    required bool samplesChannel0,
    required bool samplesChannel1,
    required bool usesCursorUniforms,
  }) {
    final directiveMatch = _stageDirectivePattern.firstMatch(source);
    if (directiveMatch != null) {
      return switch (directiveMatch.group(1)!.toLowerCase()) {
        'bg' || 'background' => ShaderStageHint.background,
        'fg' || 'foreground' => ShaderStageHint.foreground,
        _ => ShaderStageHint.any,
      };
    }
    if (!samplesChannel0) {
      return ShaderStageHint.background;
    }
    if (usesCursorUniforms) {
      return ShaderStageHint.foreground;
    }
    if (samplesChannel1) {
      return ShaderStageHint.any;
    }
    return ShaderStageHint.foreground;
  }

  /// Validates [source] and generates both Impeller GLSL 460 and WebGL2 GLSL
  /// ES 3.00 shader sources.
  static ShimmedShaderPair shim(String source, {String shaderId = '<inline>'}) {
    final analysis = analyze(source, shaderId: shaderId);
    final normalized = _normalizeLineEndings(source);
    return ShimmedShaderPair(
      analysis: analysis,
      impellerVertexGlsl: impellerVertexShaderSource,
      impellerFragmentGlsl: '$_impellerPrefix\n$normalized\n$_fragmentSuffix',
      webgl2VertexGlsl: webgl2VertexShaderSource,
      webgl2FragmentGlsl: '$_webgl2Prefix\n$normalized\n$_fragmentSuffix',
    );
  }

  /// Packs [uniforms] into [target] starting at [byteOffset] using the exact
  /// `std140` byte layout of [uniformBlockName] ([uniformBufferByteLength]
  /// bytes).
  ///
  /// Set [flipUvY] to `true` on WebGL2 when external textures are uploaded with
  /// top-left origin (`UNPACK_FLIP_Y_WEBGL == false`); Impeller GLSL 460 uses
  /// compile-time target macros instead. Set [skipPalette] to `true` when
  /// reusing a scratch buffer that already contains the identical 4 KiB
  /// `iPalette` slice at [byteOffset].
  static void packUniformsStd140(
    TerminalShaderUniforms uniforms,
    ByteData target, {
    int byteOffset = 0,
    bool flipUvY = false,
    bool skipPalette = false,
  }) {
    if (byteOffset < 0 ||
        byteOffset + uniformBufferByteLength > target.lengthInBytes) {
      throw RangeError(
        'Target buffer requires at least $uniformBufferByteLength bytes from '
        'offset $byteOffset (length=${target.lengthInBytes}).',
      );
    }
    final o = byteOffset;
    _writeVec3(target, o + 0, uniforms.width, uniforms.height, 1.0);
    target.setFloat32(o + 12, uniforms.timeSeconds, Endian.little);
    target.setFloat32(o + 16, uniforms.deltaSeconds, Endian.little);
    target.setFloat32(o + 20, uniforms.frameIndex.toDouble(), Endian.little);
    target.setFloat32(o + 24, uniforms.frameRate, Endian.little);
    target.setFloat32(o + 28, uniforms.timeCursorChange, Endian.little);
    _writeFloat4(target, o + 32, uniforms.mouseXyzw);
    _writeFloat4(target, o + 48, uniforms.dateYmdSec);
    _writeChannelResolutions(target, o + 64, uniforms.channelResolutions);
    if (!skipPalette) {
      _writePalette256(target, o + 128, uniforms.palette256Argb);
    }
    _writeArgbRgb(target, o + 4224, uniforms.backgroundArgb);
    target.setFloat32(o + 4236, flipUvY ? 1.0 : 0.0, Endian.little);
    _writeArgbRgb(target, o + 4240, uniforms.foregroundArgb);
    target.setFloat32(o + 4252, 0.0, Endian.little);
    _writeFloat4(target, o + 4256, uniforms.currentCursorXywh);
    _writeFloat4(target, o + 4272, uniforms.previousCursorXywh);
    _writeArgbRgba(target, o + 4288, uniforms.currentCursorArgb);
    _writeArgbRgba(target, o + 4304, uniforms.previousCursorArgb);
    _writeArgbRgba(target, o + 4320, uniforms.currentCursorArgb);
    target.setFloat32(
      o + 4336,
      uniforms.currentCursorStyle.toDouble(),
      Endian.little,
    );
    target.setFloat32(
      o + 4340,
      uniforms.cursorVisible ? 1.0 : 0.0,
      Endian.little,
    );
    target.setFloat32(o + 4344, uniforms.isFocused ? 1.0 : 0.0, Endian.little);
    target.setFloat32(o + 4348, uniforms.timeFocusChange, Endian.little);
    final rect = uniforms.regionRect;
    _writeVec4(target, o + 4352, rect.left, rect.top, rect.width, rect.height);
    target.setFloat32(o + 4368, uniforms.cellSize.width, Endian.little);
    target.setFloat32(o + 4372, uniforms.cellSize.height, Endian.little);
    target.setFloat32(o + 4376, 0.0, Endian.little);
    target.setFloat32(o + 4380, 0.0, Endian.little);
    _writeFloat4(target, o + 4384, uniforms.params, srcOffset: 0);
    _writeFloat4(target, o + 4400, uniforms.params, srcOffset: 4);
  }

  static void _writeVec3(
    ByteData target,
    int offset,
    double x,
    double y,
    double z,
  ) {
    target.setFloat32(offset, x, Endian.little);
    target.setFloat32(offset + 4, y, Endian.little);
    target.setFloat32(offset + 8, z, Endian.little);
  }

  static void _writeVec4(
    ByteData target,
    int offset,
    double x,
    double y,
    double z,
    double w,
  ) {
    target.setFloat32(offset, x, Endian.little);
    target.setFloat32(offset + 4, y, Endian.little);
    target.setFloat32(offset + 8, z, Endian.little);
    target.setFloat32(offset + 12, w, Endian.little);
  }

  static void _writeFloat4(
    ByteData target,
    int offset,
    Float32List values, {
    int srcOffset = 0,
  }) {
    target.setFloat32(offset, values[srcOffset], Endian.little);
    target.setFloat32(offset + 4, values[srcOffset + 1], Endian.little);
    target.setFloat32(offset + 8, values[srcOffset + 2], Endian.little);
    target.setFloat32(offset + 12, values[srcOffset + 3], Endian.little);
  }

  static void _writeChannelResolutions(
    ByteData target,
    int offset,
    Float32List res,
  ) {
    for (var i = 0; i < 4; i++) {
      final dst = offset + i * 16;
      final src = i * 3;
      target.setFloat32(dst, res[src], Endian.little);
      target.setFloat32(dst + 4, res[src + 1], Endian.little);
      target.setFloat32(dst + 8, res[src + 2], Endian.little);
      target.setFloat32(dst + 12, 0.0, Endian.little);
    }
  }

  static Uint32List? _lastPackedPalette;
  static Uint8List? _lastPackedPaletteBytes;

  static void _writePalette256(
    ByteData target,
    int offset,
    Uint32List palette,
  ) {
    var cached = identical(palette, _lastPackedPalette)
        ? _lastPackedPaletteBytes
        : null;
    if (cached == null) {
      final bytes = Uint8List(TerminalShaderUniforms.paletteLength * 16);
      final bd = ByteData.sublistView(bytes);
      for (var i = 0; i < TerminalShaderUniforms.paletteLength; i++) {
        final dst = i * 16;
        _writeArgbRgb(bd, dst, palette[i]);
        bd.setFloat32(dst + 12, 0.0, Endian.little);
      }
      _lastPackedPalette = palette;
      _lastPackedPaletteBytes = bytes;
      cached = bytes;
    }
    target.buffer
        .asUint8List(target.offsetInBytes + offset, cached.length)
        .setRange(0, cached.length, cached);
  }

  static void _writeArgbRgb(ByteData target, int offset, int argb) {
    target.setFloat32(offset, ((argb >> 16) & 0xFF) / 255.0, Endian.little);
    target.setFloat32(offset + 4, ((argb >> 8) & 0xFF) / 255.0, Endian.little);
    target.setFloat32(offset + 8, (argb & 0xFF) / 255.0, Endian.little);
  }

  static void _writeArgbRgba(ByteData target, int offset, int argb) {
    _writeArgbRgb(target, offset, argb);
    target.setFloat32(
      offset + 12,
      ((argb >> 24) & 0xFF) / 255.0,
      Endian.little,
    );
  }

  static String _normalizeLineEndings(String source) =>
      source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  static String _stripComments(String source) {
    final buffer = StringBuffer();
    final len = source.length;
    var i = 0;
    while (i < len) {
      final ch = source.codeUnitAt(i);
      final next = i + 1 < len ? source.codeUnitAt(i + 1) : 0;
      if (ch == 0x2F && next == 0x2F) {
        i = _skipLineComment(source, i + 2);
        continue;
      }
      if (ch == 0x2F && next == 0x2A) {
        i = _skipBlockComment(source, i + 2, buffer);
        continue;
      }
      buffer.writeCharCode(ch);
      i++;
    }
    return buffer.toString();
  }

  static int _skipLineComment(String source, int start) {
    var i = start;
    while (i < source.length && source.codeUnitAt(i) != 0x0A) {
      i++;
    }
    return i;
  }

  static int _skipBlockComment(String source, int start, StringBuffer out) {
    var i = start;
    while (i + 1 < source.length) {
      final ch = source.codeUnitAt(i);
      if (ch == 0x2A && source.codeUnitAt(i + 1) == 0x2F) {
        out.writeCharCode(0x20);
        return i + 2;
      }
      if (ch == 0x0A) {
        out.writeCharCode(0x0A);
      }
      i++;
    }
    return source.length;
  }
}
