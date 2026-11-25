import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:source_span/source_span.dart';
import 'package:termui_flutter/src/rendering/builtin_shaders.dart';
import 'package:termui_flutter/src/rendering/gpu_frame_watchdog.dart';
import 'package:termui_flutter/src/rendering/shader_backend.dart';
import 'package:termui_flutter/src/rendering/shader_controller.dart';
import 'package:termui_flutter/src/rendering/shader_diagnostic_parser.dart';
import 'package:termui_flutter/src/rendering/shader_region_painter.dart';
import 'package:termui_flutter/src/rendering/shader_spec.dart';
import 'package:termui_flutter/src/rendering/shadertoy_glsl_shim.dart';

/// Community-style Ghostty shaders exercising verbatim `shadertoy_prefix.glsl`
/// uniforms (`iPalette[256]`, `iBackgroundColor`, `iForegroundColor`,
/// `iCurrentCursor`/`iPreviousCursor` `(x, y, w, h)`, `iCurrentCursorStyle`,
/// `CURSORSTYLE_*`, `iFocus`, `iTimeFocus`, `iChannelResolution`, `texture2D`,
/// and Kitty `iPrevFrame`).
const Map<String, String> _ghosttyCommunityCorpus = <String, String>{
  'ghostty_cursor_blaze': '''
// Community-style Ghostty cursor smear / blaze shader
float easeOut(float x) {
  return 1.0 - pow(1.0 - clamp(x, 0.0, 1.0), 3.0);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / iResolution.xy;
  vec4 terminal = texture2D(iChannel0, uv);
  if (iCursorVisible == 0) {
    fragColor = terminal;
    return;
  }
  float dt = easeOut((iTime - iTimeCursorChange) / 0.25);
  vec2 cur = iCurrentCursor.xy + iCurrentCursor.zw * 0.5;
  vec2 prev = iPreviousCursor.xy + iPreviousCursor.zw * 0.5;
  vec2 lerped = mix(prev, cur, dt);
  float dist = length(fragCoord - lerped);
  float glow = exp(-dist * 0.08) * (1.0 - dt);
  vec3 tint = iCurrentCursorStyle == CURSORSTYLE_BAR
      ? iCurrentCursorColor.rgb
      : mix(iPreviousCursorColor.rgb, iCursorColor.rgb, dt);
  fragColor = vec4(terminal.rgb + tint * glow * 0.6, terminal.a);
}
''',
  'ghostty_palette_theme_tint': '''
// Uses full 256-entry ANSI palette plus foreground/background colors
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / iResolution.xy;
  vec4 base = texture(iChannel0, uv);
  int idx = int(clamp(floor(uv.x * 255.0), 0.0, 255.0));
  vec3 palColor = iPalette[idx];
  vec3 accent = mix(iBackgroundColor, iForegroundColor, 0.15);
  vec3 cr = iChannelResolution[0];
  float safeScale = cr.x > 0.0 ? 0.04 : 0.03;
  fragColor = vec4(mix(base.rgb, palColor + accent * 0.05, safeScale), base.a);
}
''',
  'ghostty_focus_dim': '''
// Static focus dim shader with smooth focus transition timestamp
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / iResolution.xy;
  vec4 base = texture(iChannel0, uv);
  float dimFactor = iFocus == 1 ? 1.0 : 0.72;
  float edge = length(uv - 0.5);
  vec3 tinted = mix(base.rgb * dimFactor, iBackgroundColor, (1.0 - dimFactor) * edge * 0.4);
  fragColor = vec4(tinted, base.a + iTimeFocus * 0.0);
}
''',
  'ghostty_cursor_styles_and_region': '''
// Exercises all CURSORSTYLE_* constants, iMouse, iDate, iRegionRect, iCellSize
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / iResolution.xy;
  vec4 base = texture(iChannel0, uv);
  float styleWeight = 0.0;
  if (iCurrentCursorStyle == CURSORSTYLE_BLOCK) styleWeight = 1.0;
  else if (iCurrentCursorStyle == CURSORSTYLE_BAR) styleWeight = 0.75;
  else if (iCurrentCursorStyle == CURSORSTYLE_UNDERLINE) styleWeight = 0.5;
  else if (iCurrentCursorStyle == CURSORSTYLE_BLOCK_HOLLOW) styleWeight = 0.25;
  vec2 cellUv = fract((fragCoord - iRegionRect.xy) / max(iCellSize, vec2(1.0)));
  float pulse = 0.5 + 0.5 * sin(iDate.w + iMouse.x * 0.01 + float(iFrame) * 0.05);
  fragColor = vec4(base.rgb + vec3(cellUv.x * 0.02 * styleWeight * pulse) + uParams1.rgb * 0.0, base.a);
}
''',
  'kitty_prev_frame_trail': '''
// Exercises Kitty/fterm iPrevFrame feedback plus iChannel1 wallpaper blend
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / iResolution.xy;
  vec4 curr = texture(iChannel0, uv);
  vec4 prev = texture(iPrevFrame, uv);
  vec4 wp = texture(iChannel1, uv);
  vec3 merged = max(curr.rgb, prev.rgb * 0.82);
  fragColor = vec4(mix(merged, wp.rgb, 0.05), curr.a);
}
''',
};

String? _findImpellerc() {
  final envPath = Platform.environment['FTERM_IMPELLERC_PATH'];
  if (envPath != null && envPath.isNotEmpty && File(envPath).existsSync()) {
    return envPath;
  }
  final engineSubdir = Platform.isWindows
      ? 'windows-x64/impellerc.exe'
      : (Platform.isMacOS ? 'darwin-x64/impellerc' : 'linux-x64/impellerc');
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  final candidates = <String>[
    if (flutterRoot != null && flutterRoot.isNotEmpty)
      '$flutterRoot/bin/cache/artifacts/engine/$engineSubdir',
    '/srv/opt/flutter/stable/bin/cache/artifacts/engine/linux-x64/impellerc',
    if (Platform.isWindows) r'C:\development\flutter\stable\bin\cache\artifacts\engine\windows-x64\impellerc.exe',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  var dir = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 6; i++) {
    final probe = File('${dir.path}/cache/artifacts/engine/$engineSubdir');
    if (probe.existsSync()) return probe.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

void main() {
  group('ShadertoyGlslShim static analysis and validation', () {
    test(
      'detects usesTime, usesPrevFrame, samplesChannel0, samplesChannel1',
      () {
        final wp = ShadertoyGlslShim.analyze(BuiltinShaders.wallpaperWaveGlsl);
        expect(wp.usesTime, isTrue);
        expect(wp.usesPrevFrame, isFalse);
        expect(wp.samplesChannel0, isFalse);
        expect(wp.samplesChannel1, isTrue);
        expect(wp.usesCursorUniforms, isFalse);
        expect(wp.stageHint, ShaderStageHint.background);

        final scan = ShadertoyGlslShim.analyze(
          BuiltinShaders.scanlineOverlayGlsl,
        );
        expect(scan.usesTime, isFalse);
        expect(scan.usesPrevFrame, isFalse);
        expect(scan.samplesChannel0, isTrue);
        expect(scan.samplesChannel1, isFalse);
        expect(scan.usesCursorUniforms, isFalse);
        expect(scan.stageHint, ShaderStageHint.foreground);

        final phosphor = ShadertoyGlslShim.analyze(
          BuiltinShaders.phosphorGlowGlsl,
        );
        expect(phosphor.usesTime, isFalse);
        expect(phosphor.usesPrevFrame, isTrue);
        expect(phosphor.samplesChannel0, isTrue);
        expect(phosphor.samplesChannel1, isFalse);
        expect(phosphor.stageHint, ShaderStageHint.foreground);

        final focusDim = ShadertoyGlslShim.analyze(
          _ghosttyCommunityCorpus['ghostty_focus_dim']!,
        );
        expect(focusDim.usesTime, isFalse);
        expect(focusDim.usesPrevFrame, isFalse);
        expect(focusDim.usesMouse, isFalse);
        expect(focusDim.samplesChannel0, isTrue);
        expect(focusDim.usesCursorUniforms, isTrue);
        expect(focusDim.stageHint, ShaderStageHint.foreground);

        final retro = ShadertoyGlslShim.analyze(
          BuiltinShaders.retroPhosphorGlsl,
        );
        expect(retro.usesTime, isFalse);
        expect(retro.usesPrevFrame, isFalse);
        expect(retro.usesMouse, isFalse);
        expect(retro.samplesChannel0, isTrue);
        expect(retro.stageHint, ShaderStageHint.foreground);

        final mouseShader = ShadertoyGlslShim.analyze('''
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / iResolution.xy;
  float d = length(fragCoord - iMouse.xy);
  fragColor = vec4(vec3(step(d, 20.0)), 1.0);
}
''');
        expect(mouseShader.usesMouse, isTrue);
        expect(mouseShader.usesTime, isFalse);

        final commentedMouse = ShadertoyGlslShim.analyze('''
// iMouse is only in a comment
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  fragColor = texture(iChannel0, fragCoord / iResolution.xy);
}
''');
        expect(commentedMouse.usesMouse, isFalse);

        // Explicit @fterm-stage / @stage directives override heuristics.
        final explicitBg = ShadertoyGlslShim.analyze('''
// @fterm-stage: bg
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  fragColor = texture(iChannel0, fragCoord / iResolution.xy);
}
''');
        expect(explicitBg.stageHint, ShaderStageHint.background);

        final explicitBoth = ShadertoyGlslShim.analyze('''
// @stage: both
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  fragColor = vec4(1.0);
}
''');
        expect(explicitBoth.stageHint, ShaderStageHint.any);

        final explicitFg = ShadertoyGlslShim.analyze('''
// @fterm-stage: foreground
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  fragColor = vec4(1.0);
}
''');
        expect(explicitFg.stageHint, ShaderStageHint.foreground);

        // Sampling both iChannel0 and iChannel1 without cursor uniforms -> any.
        final dualChannel = ShadertoyGlslShim.analyze('''
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / iResolution.xy;
  fragColor = mix(texture(iChannel0, uv), texture(iChannel1, uv), 0.5);
}
''');
        expect(dualChannel.stageHint, ShaderStageHint.any);
      },
    );

    test('ignores identifiers inside single-line and block comments', () {
      const source = '''
// iTime iPrevFrame iChannel1
/*
  iTimeDelta iFrame iPrevFrame
  #not_an_include
*/
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  fragColor = texture(iChannel0, fragCoord / iResolution.xy);
}
''';
      final analysis = ShadertoyGlslShim.analyze(source);
      expect(analysis.usesTime, isFalse);
      expect(analysis.usesPrevFrame, isFalse);
      expect(analysis.samplesChannel0, isTrue);
      expect(analysis.samplesChannel1, isFalse);
    });

    test('rejects #include directives including comment-obfuscated forms', () {
      const plainInclude = '''
#include "secret.glsl"
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  fragColor = vec4(1.0);
}
''';
      expect(
        () => ShadertoyGlslShim.shim(plainInclude, shaderId: 'bad_inc'),
        throwsA(
          isA<ShaderCompileException>()
              .having((e) => e.shaderId, 'shaderId', 'bad_inc')
              .having((e) => e.message, 'message', contains('#include')),
        ),
      );

      const obfuscatedInclude = '''
#/*comment*/include <etc/passwd>
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  fragColor = vec4(1.0);
}
''';
      expect(
        () => ShadertoyGlslShim.shim(obfuscatedInclude),
        throwsA(isA<ShaderCompileException>()),
      );
    });

    test('rejects empty sources, > 64 KiB sources, #version, and missing mainImage', () {
      expect(
        () => ShadertoyGlslShim.shim(''),
        throwsA(isA<ShaderCompileException>()),
      );

      final oversized =
          'void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n'
          '  // ${'a' * (ShadertoyGlslShim.maxSourceBytes + 1)}\n'
          '  fragColor = vec4(1.0);\n'
          '}\n';
      expect(
        () => ShadertoyGlslShim.shim(oversized),
        throwsA(
          isA<ShaderCompileException>().having(
            (e) => e.message,
            'message',
            contains('64 KiB'),
          ),
        ),
      );

      const withVersion = '''
#version 300 es
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  fragColor = vec4(1.0);
}
''';
      expect(
        () => ShadertoyGlslShim.shim(withVersion),
        throwsA(isA<ShaderCompileException>()),
      );

      const noMainImage = 'vec4 helper() { return vec4(1.0); }';
      expect(
        () => ShadertoyGlslShim.shim(noMainImage),
        throwsA(isA<ShaderCompileException>()),
      );
    });
  });

  group('ShadertoyGlslShim Impeller GLSL 460 and WebGL2 ES 3.00 emission', () {
    test('emits verbatim Ghostty uniform block and UV flip wrappers for both targets', () {
      final shimmed = ShadertoyGlslShim.shim(
        _ghosttyCommunityCorpus['ghostty_cursor_blaze']!,
        shaderId: 'cursor_blaze',
      );

      // Impeller GLSL 460 assertions
      expect(shimmed.impellerVertexGlsl, contains('#version 460 core'));
      expect(shimmed.impellerFragmentGlsl, contains('#version 460 core'));
      expect(
        shimmed.impellerFragmentGlsl,
        contains(
          'layout(set = 0, binding = 0, std140) uniform TerminalUniforms',
        ),
      );
      expect(
        shimmed.impellerFragmentGlsl,
        contains('layout(set = 0, binding = 1) uniform sampler2D iChannel0;'),
      );
      expect(
        shimmed.impellerFragmentGlsl,
        contains('layout(set = 0, binding = 2) uniform sampler2D iChannel1;'),
      );
      expect(
        shimmed.impellerFragmentGlsl,
        contains('layout(set = 0, binding = 3) uniform sampler2D iPrevFrame;'),
      );
      expect(
        shimmed.impellerFragmentGlsl,
        contains('return vec2(uv.x, 1.0 - uv.y);'),
      );
      expect(
        shimmed.impellerFragmentGlsl,
        isNot(contains('IMPELLER_TARGET_OPENGLES')),
      );
      expect(shimmed.impellerFragmentGlsl, contains('vec3 iPalette[256];'));
      expect(
        shimmed.impellerFragmentGlsl,
        contains('#define texture2D texture'),
      );
      expect(shimmed.impellerFragmentGlsl, contains('CURSORSTYLE_BLOCK = 0'));
      expect(shimmed.impellerFragmentGlsl, contains('CURSORSTYLE_BAR = 1'));
      expect(
        shimmed.impellerFragmentGlsl,
        contains('CURSORSTYLE_UNDERLINE = 2'),
      );
      expect(
        shimmed.impellerFragmentGlsl,
        contains('CURSORSTYLE_BLOCK_HOLLOW = 3'),
      );
      expect(
        shimmed.impellerFragmentGlsl,
        contains('vec2 fragCoord = v_uv * iResolution.xy;'),
      );

      // WebGL2 GLSL ES 3.00 assertions
      expect(shimmed.webgl2VertexGlsl, contains('#version 300 es'));
      expect(shimmed.webgl2FragmentGlsl, contains('#version 300 es'));
      expect(shimmed.webgl2FragmentGlsl, contains('precision highp float;'));
      expect(
        shimmed.webgl2FragmentGlsl,
        contains('layout(std140) uniform TerminalUniforms'),
      );
      expect(shimmed.webgl2FragmentGlsl, isNot(contains('layout(set = 0')));
      expect(
        shimmed.webgl2FragmentGlsl,
        contains('uniform sampler2D iChannel0;'),
      );
      expect(
        shimmed.webgl2FragmentGlsl,
        contains('uniform sampler2D iChannel1;'),
      );
      expect(
        shimmed.webgl2FragmentGlsl,
        contains('uniform sampler2D iPrevFrame;'),
      );
      expect(shimmed.webgl2FragmentGlsl, contains('_termuiFlipUv'));
    });

    test('packs std140 UBO buffer with exact offsets and values', () {
      final palette = Uint32List(256);
      palette[0] = 0xFF112233;
      palette[255] = 0xFFCCDDEE;
      final uniforms = TerminalShaderUniforms(
        width: 1920.0,
        height: 1080.0,
        timeSeconds: 12.5,
        deltaSeconds: 0.016,
        frameIndex: 42,
        frameRate: 60.0,
        currentCursorXywh: Float32List.fromList(<double>[10, 20, 8, 16]),
        previousCursorXywh: Float32List.fromList(<double>[2, 4, 8, 16]),
        currentCursorArgb: 0xFF336699,
        previousCursorArgb: 0x80112233,
        currentCursorStyle: TerminalShaderUniforms.cursorStyleBar,
        timeCursorChange: 12.0,
        cursorVisible: true,
        isFocused: false,
        timeFocusChange: 9.5,
        foregroundArgb: 0xFFE6EDF3,
        backgroundArgb: 0xFF0D1117,
        palette256Argb: palette,
        regionRect: const ui.Rect.fromLTWH(5, 6, 70, 80),
        cellSize: const ui.Size(9, 18),
        params: Float32List.fromList(<double>[1, 2, 3, 4, 5, 6, 7, 8]),
        mouseXyzw: Float32List.fromList(<double>[100, 200, 300, 400]),
        dateYmdSec: Float32List.fromList(<double>[2026, 11, 20, 3600]),
        channelResolutions: Float32List.fromList(<double>[
          1920,
          1080,
          1,
          800,
          600,
          1,
          1920,
          1080,
          1,
          0,
          0,
          0,
        ]),
      );

      final bytes = ByteData(ShadertoyGlslShim.uniformBufferByteLength);
      ShadertoyGlslShim.packUniformsStd140(uniforms, bytes, flipUvY: true);

      expect(bytes.getFloat32(0, Endian.little), closeTo(1920.0, 1e-5));
      expect(bytes.getFloat32(4, Endian.little), closeTo(1080.0, 1e-5));
      expect(bytes.getFloat32(8, Endian.little), closeTo(1.0, 1e-5));
      expect(bytes.getFloat32(12, Endian.little), closeTo(12.5, 1e-5));
      expect(bytes.getFloat32(16, Endian.little), closeTo(0.016, 1e-5));
      expect(bytes.getFloat32(20, Endian.little), closeTo(42.0, 1e-5));
      expect(bytes.getFloat32(24, Endian.little), closeTo(60.0, 1e-5));
      expect(bytes.getFloat32(28, Endian.little), closeTo(12.0, 1e-5));
      expect(bytes.getFloat32(32, Endian.little), closeTo(100.0, 1e-5));
      expect(bytes.getFloat32(48, Endian.little), closeTo(2026.0, 1e-5));
      expect(bytes.getFloat32(64, Endian.little), closeTo(1920.0, 1e-5));
      expect(bytes.getFloat32(80, Endian.little), closeTo(800.0, 1e-5));
      // Palette slot 0 and 255
      expect(bytes.getFloat32(128, Endian.little), closeTo(0x11 / 255.0, 1e-5));
      expect(
        bytes.getFloat32(128 + 255 * 16 + 8, Endian.little),
        closeTo(0xEE / 255.0, 1e-5),
      );
      // Background & flip flag & foreground
      expect(
        bytes.getFloat32(4224, Endian.little),
        closeTo(0x0D / 255.0, 1e-5),
      );
      expect(bytes.getFloat32(4236, Endian.little), closeTo(1.0, 1e-5));
      expect(
        bytes.getFloat32(4240, Endian.little),
        closeTo(0xE6 / 255.0, 1e-5),
      );
      // Cursor geometry & colors & states
      expect(bytes.getFloat32(4256, Endian.little), closeTo(10.0, 1e-5));
      expect(bytes.getFloat32(4272, Endian.little), closeTo(2.0, 1e-5));
      expect(
        bytes.getFloat32(4288, Endian.little),
        closeTo(0x33 / 255.0, 1e-5),
      );
      expect(
        bytes.getFloat32(4316, Endian.little),
        closeTo(0x80 / 255.0, 1e-5),
      );
      expect(
        bytes.getFloat32(4336, Endian.little),
        closeTo(TerminalShaderUniforms.cursorStyleBar.toDouble(), 1e-5),
      );
      expect(bytes.getFloat32(4340, Endian.little), closeTo(1.0, 1e-5));
      expect(bytes.getFloat32(4344, Endian.little), closeTo(0.0, 1e-5));
      expect(bytes.getFloat32(4348, Endian.little), closeTo(9.5, 1e-5));
      // Region, cell size, params
      expect(bytes.getFloat32(4352, Endian.little), closeTo(5.0, 1e-5));
      expect(bytes.getFloat32(4368, Endian.little), closeTo(9.0, 1e-5));
      expect(bytes.getFloat32(4384, Endian.little), closeTo(1.0, 1e-5));
      expect(bytes.getFloat32(4412, Endian.little), closeTo(8.0, 1e-5));

      expect(
        () => ShadertoyGlslShim.packUniformsStd140(uniforms, ByteData(16)),
        throwsRangeError,
      );
    });
  });

  group('Shader specs, presets, and wire codecs', () {
    test('ShaderAnimationMode, ShaderBackendKind, and TerminalShaderPreset codecs round-trip', () {
      for (final mode in ShaderAnimationMode.values) {
        expect(ShaderAnimationMode.fromWireName(mode.wireName), mode);
        expect(ShaderAnimationMode.fromWireName(mode.name), mode);
      }
      expect(
        ShaderAnimationMode.fromWireName('bogus'),
        ShaderAnimationMode.focused,
      );

      for (final kind in ShaderBackendKind.values) {
        expect(ShaderBackendKind.tryFromWireName(kind.wireName), kind);
        expect(ShaderBackendKind.tryFromWireName(kind.name), kind);
      }
      expect(ShaderBackendKind.tryFromWireName('bogus'), isNull);

      for (final preset in TerminalShaderPreset.values) {
        expect(TerminalShaderPreset.fromWireName(preset.wireName), preset);
        expect(TerminalShaderPreset.fromWireName(preset.name), preset);
      }
      expect(
        TerminalShaderPreset.fromWireName('bogus'),
        TerminalShaderPreset.none,
      );
    });

    test('ShaderPassSpec, TerminalShaderConfig, and ShaderCompileException semantics', () {
      final passA = ShaderPassSpec(
        id: 'p1',
        stage: TerminalShaderStage.foreground,
        preset: TerminalShaderPreset.crtLottes,
        params: Float32List.fromList(<double>[0.1, 0.2]),
      );
      final passB = passA.copyWith();
      expect(passA, equals(passB));
      expect(passA.hashCode, equals(passB.hashCode));
      expect(passA.params.length, ShaderPassSpec.paramCount);
      expect(passA.params[0], closeTo(0.1, 1e-6));
      expect(passA.params[7], 0.0);

      expect(TerminalShaderConfig.empty.isEmpty, isTrue);
      expect(TerminalShaderConfig.empty.hasBackgroundStage, isFalse);
      expect(TerminalShaderConfig.empty.hasForegroundStage, isFalse);

      final active = TerminalShaderConfig.empty.copyWith(
        foregroundPasses: <ShaderPassSpec>[passA],
        backgroundOpacity: 0.5,
      );
      expect(active.isEmpty, isFalse);
      expect(active.hasForegroundStage, isTrue);
      expect(active.backgroundOpacity, 0.5);
      expect(active, equals(active.copyWith()));
      expect(active.hashCode, equals(active.copyWith().hashCode));

      const err = ShaderCompileException(
        shaderId: 'broken.glsl',
        message: 'syntax error',
        lineNumber: 12,
      );
      expect(
        err.toString(),
        contains('ShaderCompileException[broken.glsl (line 12)]: syntax error'),
      );
      const errNoLine = ShaderCompileException(
        shaderId: 'broken.glsl',
        message: 'bad token',
      );
      expect(
        errNoLine.toString(),
        contains('ShaderCompileException[broken.glsl]: bad token'),
      );

      // Exercise TerminalShaderConfig clearBackgroundImage & disabled & inequality
      final disabled = active.copyWith(
        enabled: false,
        backgroundPasses: <ShaderPassSpec>[
          passA.copyWith(id: 'bg', stage: TerminalShaderStage.background),
        ],
        clearBackgroundImage: true,
        backgroundOpacity: double.nan,
      );
      expect(disabled.isEmpty, isTrue);
      expect(disabled.hasBackgroundStage, isFalse);
      expect(disabled.hasForegroundStage, isFalse);
      expect(disabled.backgroundOpacity, 0.5);
      expect(disabled == active, isFalse);
      expect(
        passA == passA.copyWith(params: Float32List.fromList(<double>[9.0])),
        isFalse,
      );
    });

    test(
      'BuiltinShaders exposes all 5 active presets with expected metadata',
      () {
        expect(
          BuiltinShaders.sourceForPreset(TerminalShaderPreset.none),
          isNull,
        );
        expect(BuiltinShaders.allPresets.length, 6);
        expect(
          BuiltinShaders.defaultStageForPreset(
            TerminalShaderPreset.retroPhosphor,
          ),
          TerminalShaderStage.foreground,
        );
        expect(
          BuiltinShaders.usesPrevFrame(TerminalShaderPreset.retroPhosphor),
          isFalse,
        );
        expect(
          BuiltinShaders.defaultStageForPreset(
            TerminalShaderPreset.wallpaperWave,
          ),
          TerminalShaderStage.background,
        );
        expect(
          BuiltinShaders.defaultStageForPreset(TerminalShaderPreset.crtLottes),
          TerminalShaderStage.foreground,
        );
        expect(
          BuiltinShaders.usesPrevFrame(TerminalShaderPreset.phosphorGlow),
          isTrue,
        );
        expect(
          BuiltinShaders.usesPrevFrame(TerminalShaderPreset.scanlineOverlay),
          isFalse,
        );
        expect(
          BuiltinShaders.samplesChannel0(TerminalShaderPreset.none),
          isFalse,
        );
        expect(
          BuiltinShaders.stageHint(TerminalShaderPreset.none),
          ShaderStageHint.any,
        );
        for (final preset in BuiltinShaders.allPresets.keys) {
          final src = BuiltinShaders.sourceForPreset(preset);
          expect(src, isNotNull);
          final shimmed = ShadertoyGlslShim.shim(
            src!,
            shaderId: preset.wireName,
          );
          expect(
            shimmed.analysis.usesPrevFrame,
            BuiltinShaders.usesPrevFrame(preset),
          );
          expect(
            shimmed.analysis.samplesChannel0,
            BuiltinShaders.samplesChannel0(preset),
          );
          expect(shimmed.analysis.stageHint, BuiltinShaders.stageHint(preset));
        }
      },
    );
  });

  group('Real impellerc compilation verification', () {
    final impellerc = _findImpellerc();

    test(
      'compiles all built-in full-pane presets, region presets, and Ghostty community shaders through impellerc --shader-bundle',
      () {
        final tmpDir = Directory.systemTemp.createTempSync('termui_shim_test_');
        final incDir = Directory('${tmpDir.path}/inc')..createSync();
        try {
          final vertFile = File('${tmpDir.path}/vertex.glsl')
            ..writeAsStringSync(ShadertoyGlslShim.impellerVertexShaderSource);

          final cases = <String, String>{
            for (final entry in BuiltinShaders.allPresets.entries)
              'preset_${entry.key.wireName}': entry.value,
            for (final id in ShaderRegionPresets.presetIds)
              'region_$id': ShaderRegionPresets.sourceFor(id)!,
            ..._ghosttyCommunityCorpus,
          };

          for (final entry in cases.entries) {
            final shimmed = ShadertoyGlslShim.shim(
              entry.value,
              shaderId: entry.key,
            );
            final fragFile = File('${tmpDir.path}/${entry.key}.frag.glsl')
              ..writeAsStringSync(shimmed.impellerFragmentGlsl);
            final outFile = File('${tmpDir.path}/${entry.key}.shaderbundle');

            final bundleSpec = jsonEncode(<String, Object?>{
              ShadertoyGlslShim.vertexShaderName: <String, Object?>{
                'type': 'vertex',
                'file': vertFile.path,
              },
              ShadertoyGlslShim.fragmentShaderName: <String, Object?>{
                'type': 'fragment',
                'file': fragFile.path,
              },
            });

            final result = Process.runSync(impellerc!, <String>[
              '--shader-bundle=$bundleSpec',
              '--sl=${outFile.path}',
              '--include=${incDir.path}',
              '--verbose',
            ]);

            expect(
              result.exitCode,
              0,
              reason:
                  'impellerc failed for ${entry.key}:\n'
                  'STDOUT:\n${result.stdout}\nSTDERR:\n${result.stderr}',
            );
            expect(outFile.existsSync(), isTrue);
            expect(outFile.lengthSync(), greaterThan(1024));
          }
        } finally {
          tmpDir.deleteSync(recursive: true);
        }
      },
      skip: impellerc == null
          ? 'impellerc binary not found in Flutter SDK cache'
          : false,
    );

    test(
      'impellerc std140 reflection offsets match ShadertoyGlslShim.packUniformsStd140',
      () {
        const allFieldsShader = '''
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / max(iResolution.xy, vec2(1.0));
  vec3 acc = iResolution + iChannelResolution[0] + iPalette[0] + iPalette[255] +
      iBackgroundColor + iForegroundColor + iMouse.rgb + iDate.rgb +
      iCurrentCursor.rgb + iPreviousCursor.rgb + iCurrentCursorColor.rgb +
      iPreviousCursorColor.rgb + iCursorColor.rgb + iRegionRect.rgb +
      vec3(iCellSize, 0.0) + uParams0.rgb + uParams1.rgb +
      vec3(iTime + iTimeDelta + float(iFrame) + iFrameRate + iTimeCursorChange +
           float(iCurrentCursorStyle + iCursorVisible + iFocus) + iTimeFocus);
  fragColor = texture(iChannel0, uv) + vec4(acc * 0.0, 1.0);
}
''';
        final shimmed = ShadertoyGlslShim.shim(allFieldsShader);
        final tmpDir = Directory.systemTemp.createTempSync('termui_refl_test_');
        final incDir = Directory('${tmpDir.path}/inc')..createSync();
        try {
          final fragFile = File('${tmpDir.path}/all.frag.glsl')
            ..writeAsStringSync(shimmed.impellerFragmentGlsl);
          final reflFile = File('${tmpDir.path}/refl.json');
          final result = Process.runSync(impellerc!, <String>[
            '--metal-desktop',
            '--input=${fragFile.path}',
            '--input-type=frag',
            '--sl=${tmpDir.path}/all.metal',
            '--spirv=${tmpDir.path}/all.spv',
            '--reflection-json=${reflFile.path}',
            '--include=${incDir.path}',
          ]);
          expect(result.exitCode, 0, reason: '${result.stderr}');
          final decoded =
              jsonDecode(reflFile.readAsStringSync()) as Map<String, Object?>;
          final buffers = decoded['buffers'] as List<Object?>;
          final ubo = buffers.first as Map<String, Object?>;
          expect(ubo['name'], ShadertoyGlslShim.uniformBlockName);
          final type = ubo['type'] as Map<String, Object?>;
          final members = type['members'] as List<Object?>;
          final memberMaps = members.cast<Map<String, Object?>>().toList();
          // Impeller OpenGLES backend (`buffer_bindings_gles.cc`) only supports
          // float/vec/mat UBO members (`ShaderType::kFloat`), rejecting int32.
          for (final member in memberMaps) {
            final name = member['name'] as String;
            if (name.startsWith('_PADDING_')) continue;
            expect(
              member['base_type'],
              'ShaderType::kFloat',
              reason:
                  'UBO member $name (${member['base_type']}) must be '
                  'float-backed for Impeller OpenGLES compatibility',
            );
          }
          final offsets = <String, int>{
            for (final m in memberMaps) m['name'] as String: m['offset'] as int,
          };

          expect(offsets['iResolution'], 0);
          expect(offsets['iTime'], 12);
          expect(offsets['iTimeDelta'], 16);
          expect(offsets['_termuiFrame'], 20);
          expect(offsets['iFrameRate'], 24);
          expect(offsets['iTimeCursorChange'], 28);
          expect(offsets['iMouse'], 32);
          expect(offsets['iDate'], 48);
          expect(offsets['iChannelResolution'], 64);
          expect(offsets['iPalette'], 128);
          expect(offsets['iBackgroundColor'], 4224);
          expect(offsets['iForegroundColor'], 4240);
          expect(offsets['iCurrentCursor'], 4256);
          expect(offsets['iPreviousCursor'], 4272);
          expect(offsets['iCurrentCursorColor'], 4288);
          expect(offsets['iPreviousCursorColor'], 4304);
          expect(offsets['iCursorColor'], 4320);
          expect(offsets['_termuiCurrentCursorStyle'], 4336);
          expect(offsets['_termuiCursorVisible'], 4340);
          expect(offsets['_termuiFocus'], 4344);
          expect(offsets['iTimeFocus'], 4348);
          expect(offsets['iRegionRect'], 4352);
          expect(offsets['iCellSize'], 4368);
          expect(offsets['uParams0'], 4384);
          expect(offsets['uParams1'], 4400);
        } finally {
          tmpDir.deleteSync(recursive: true);
        }
      },
      skip: impellerc == null
          ? 'impellerc binary not found in Flutter SDK cache'
          : false,
    );

    test(
      'rejects line-spliced #\\<newline>include directive that impellerc would otherwise preprocess',
      () {
        const lineSplicedInclude =
            '#\\\n'
            'include "secret.glsl"\n'
            'void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n'
            '  fragColor = SECRET_COLOR;\n'
            '}\n';

        // First verify whether real impellerc actually processes the
        // backslash-newline line splice when not blocked by the shim.
        final tmpDir = Directory.systemTemp.createTempSync(
          'termui_splice_test_',
        );
        final incDir = Directory('${tmpDir.path}/inc')..createSync();
        try {
          File('${incDir.path}/secret.glsl').writeAsStringSync(
            '#define SECRET_COLOR vec4(1.0, 0.25, 0.5, 1.0)\n',
          );
          final vertFile = File('${tmpDir.path}/vertex.glsl')
            ..writeAsStringSync(ShadertoyGlslShim.impellerVertexShaderSource);

          ShimmedShaderPair? shimmed;
          try {
            shimmed = ShadertoyGlslShim.shim(
              lineSplicedInclude,
              shaderId: 'spliced_inc',
            );
          } on ShaderCompileException {
            // Expected once fixed.
          }

          if (shimmed != null) {
            final fragFile = File('${tmpDir.path}/spliced.frag.glsl')
              ..writeAsStringSync(shimmed.impellerFragmentGlsl);
            final outFile = File('${tmpDir.path}/spliced.shaderbundle');
            final bundleSpec = jsonEncode(<String, Object?>{
              ShadertoyGlslShim.vertexShaderName: <String, Object?>{
                'type': 'vertex',
                'file': vertFile.path,
              },
              ShadertoyGlslShim.fragmentShaderName: <String, Object?>{
                'type': 'fragment',
                'file': fragFile.path,
              },
            });
            final result = Process.runSync(impellerc!, <String>[
              '--shader-bundle=$bundleSpec',
              '--sl=${outFile.path}',
              '--include=${incDir.path}',
              '--verbose',
            ]);
            fail(
              'ShadertoyGlslShim allowed line-spliced #\\\\\\ninclude! '
              'impellerc exitCode=${result.exitCode}, '
              'outExists=${outFile.existsSync()}, '
              'stderr=${result.stderr}',
            );
          }
        } finally {
          tmpDir.deleteSync(recursive: true);
        }

        expect(
          () => ShadertoyGlslShim.shim(
            lineSplicedInclude,
            shaderId: 'spliced_inc',
          ),
          throwsA(
            isA<ShaderCompileException>().having(
              (e) => e.message,
              'message',
              contains('#include'),
            ),
          ),
        );

        const crlfSplicedInclude =
            '#inc\\\r\n'
            'lude "secret.glsl"\r\n'
            'void mainImage(out vec4 fragColor, in vec2 fragCoord) {\r\n'
            '  fragColor = vec4(1.0);\r\n'
            '}\r\n';
        expect(
          () => ShadertoyGlslShim.shim(
            crlfSplicedInclude,
            shaderId: 'spliced_crlf',
          ),
          throwsA(
            isA<ShaderCompileException>().having(
              (e) => e.message,
              'message',
              contains('#include'),
            ),
          ),
        );
      },
      skip: impellerc == null
          ? 'impellerc binary not found in Flutter SDK cache'
          : false,
    );
  });

  group('ShaderDiagnostic, shim span errors, lint rules, and per-pass errors', () {
    test(
      'ShaderDiagnostic.toSourceSpan resolves and clamps coordinates safely',
      () {
        final sourceFile = SourceFile.fromString(
          'line one\n  vec4 foo = bar;\n',
          url: Uri.parse('shader.glsl'),
        );

        const exact = ShaderDiagnostic(
          severity: ShaderDiagnosticSeverity.error,
          origin: ShaderDiagnosticOrigin.compiler,
          message: 'undeclared identifier',
          line: 2,
          column: 14,
          length: 3,
        );
        final exactSpan = exact.toSourceSpan(sourceFile);
        expect(exactSpan, isNotNull);
        expect(exactSpan!.text, equals('bar'));
        expect(exactSpan.start.line, equals(1));
        expect(exactSpan.start.column, equals(13));
        expect(exact.toString(), contains('(2:14)'));

        // Null line returns null.
        const noLine = ShaderDiagnostic(
          severity: ShaderDiagnosticSeverity.info,
          origin: ShaderDiagnosticOrigin.linter,
          message: 'general note',
        );
        expect(noLine.toSourceSpan(sourceFile), isNull);

        // Null column highlights the entire line content without trailing newline.
        const fullLine = ShaderDiagnostic(
          severity: ShaderDiagnosticSeverity.warning,
          origin: ShaderDiagnosticOrigin.linter,
          message: 'line warning',
          line: 1,
        );
        final fullLineSpan = fullLine.toSourceSpan(sourceFile);
        expect(fullLineSpan!.text, equals('line one'));

        // Out-of-range lines/columns/lengths clamp cleanly without throwing.
        const outOfRange = ShaderDiagnostic(
          severity: ShaderDiagnosticSeverity.error,
          origin: ShaderDiagnosticOrigin.compiler,
          message: 'oob',
          line: 99,
          column: 99,
          length: 50,
        );
        expect(outOfRange.toSourceSpan(sourceFile), isNotNull);

        const negativeCoords = ShaderDiagnostic(
          severity: ShaderDiagnosticSeverity.error,
          origin: ShaderDiagnosticOrigin.compiler,
          message: 'neg',
          line: -3,
          column: 0,
          length: 0,
        );
        final negSpan = negativeCoords.toSourceSpan(sourceFile);
        expect(negSpan!.text, equals('l'));

        // Empty source file never throws.
        final emptyFile = SourceFile.fromString('');
        expect(exact.toSourceSpan(emptyFile)!.text, equals(''));

        // Value equality & hashCode.
        const duplicate = ShaderDiagnostic(
          severity: ShaderDiagnosticSeverity.error,
          origin: ShaderDiagnosticOrigin.compiler,
          message: 'undeclared identifier',
          line: 2,
          column: 14,
          length: 3,
        );
        expect(exact, equals(duplicate));
        expect(exact.hashCode, equals(duplicate.hashCode));
      },
    );

    test(
      'ShadertoyGlslShim.analyze attaches exact line/column ShaderDiagnostics',
      () {
        const indentedInclude = '''
// Header comment
  #include "foo.glsl"
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  fragColor = vec4(1.0);
}
''';
        try {
          ShadertoyGlslShim.analyze(indentedInclude, shaderId: 'inc.glsl');
          fail('Expected ShaderCompileException');
        } on ShaderCompileException catch (e) {
          expect(e.lineNumber, equals(2));
          expect(e.diagnostics, hasLength(1));
          final diag = e.diagnostics.single;
          expect(diag.severity, ShaderDiagnosticSeverity.error);
          expect(diag.origin, ShaderDiagnosticOrigin.shim);
          expect(diag.line, equals(2));
          expect(diag.column, equals(3));
          final span = diag.toSourceSpan(
            SourceFile.fromString(indentedInclude),
          );
          expect(span!.text, equals('#include'));
        }

        const commentedThenRealVersion = '''
// #version 300 es
/* #version 450 */
   #version 460 core
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  fragColor = vec4(1.0);
}
''';
        try {
          ShadertoyGlslShim.analyze(
            commentedThenRealVersion,
            shaderId: 'ver.glsl',
          );
          fail('Expected ShaderCompileException');
        } on ShaderCompileException catch (e) {
          expect(e.lineNumber, equals(3));
          expect(e.diagnostics, hasLength(1));
          final diag = e.diagnostics.single;
          expect(diag.line, equals(3));
          expect(diag.column, equals(4));
          final span = diag.toSourceSpan(
            SourceFile.fromString(commentedThenRealVersion),
          );
          expect(span!.text, equals('#version'));
        }

        try {
          ShadertoyGlslShim.analyze('vec4 x() { return vec4(1.0); }');
          fail('Expected ShaderCompileException');
        } on ShaderCompileException catch (e) {
          expect(e.lineNumber, equals(1));
          expect(e.diagnostics, hasLength(1));
          expect(e.diagnostics.single.line, equals(1));
          expect(e.diagnostics.single.column, equals(1));
          expect(e.diagnostics.single.hint, isNotNull);
        }
      },
    );

    test('ShadertoyGlslShim.lint detects all warning and info rules with exact spans', () {
      // 1. FG shader ignoring iChannel0 + discard; + / 0.0 + missing @fterm-stage
      const fgHazards = '''
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  // discard; and 1.0 / 0.0 in comments must be ignored
  float safe = 1.0 / 0.5 + 1.0 / 0.05 + 1.0 / 10.0;
  float bad = safe / 0.0;
  if (bad > 1.0) discard;
  fragColor = vec4(1.0);
}
''';
      final fgSourceFile = SourceFile.fromString(fgHazards);
      final fgDiags = ShadertoyGlslShim.lint(
        fgHazards,
        stage: TerminalShaderStage.foreground,
      );

      final infoDiag = fgDiags.where(
        (d) => d.severity == ShaderDiagnosticSeverity.info,
      );
      expect(infoDiag, hasLength(1));
      expect(infoDiag.single.hint, equals('// @fterm-stage: bg'));

      final warnings = fgDiags
          .where((d) => d.severity == ShaderDiagnosticSeverity.warning)
          .toList();
      expect(warnings, hasLength(3));

      final missingChannel0 = warnings.firstWhere(
        (d) => d.message.contains('iChannel0'),
      );
      expect(
        missingChannel0.toSourceSpan(fgSourceFile)!.text,
        equals('mainImage'),
      );

      final divZero = warnings.firstWhere((d) => d.message.contains('zero'));
      expect(divZero.line, equals(4));
      expect(divZero.toSourceSpan(fgSourceFile)!.text, equals('/ 0.0'));

      final discardWarn = warnings.firstWhere(
        (d) => d.message.contains('discard;'),
      );
      expect(discardWarn.line, equals(5));
      expect(discardWarn.toSourceSpan(fgSourceFile)!.text, equals('discard;'));

      // 2. BG first pass reading iChannel0 with explicit @fterm-stage (no info diagnostic).
      const bgReadsChannel0 = '''
// @fterm-stage: bg
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  fragColor = texture(iChannel0, fragCoord / max(iResolution.xy, vec2(1.0)));
}
''';
      final bgDiags = ShadertoyGlslShim.lint(
        bgReadsChannel0,
        stage: TerminalShaderStage.background,
      );
      expect(bgDiags, hasLength(1));
      expect(bgDiags.single.severity, ShaderDiagnosticSeverity.warning);
      expect(bgDiags.single.line, equals(3));
      expect(
        bgDiags.single
            .toSourceSpan(SourceFile.fromString(bgReadsChannel0))!
            .text,
        equals('iChannel0'),
      );

      // 3. Clean annotated FG shader emits zero diagnostics.
      const cleanFg = '''
// @fterm-stage: fg
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  fragColor = texture(iChannel0, fragCoord / max(iResolution.xy, vec2(1.0)));
}
''';
      expect(
        ShadertoyGlslShim.lint(cleanFg, stage: TerminalShaderStage.foreground),
        isEmpty,
      );
    });

    test(
      'TerminalShaderController tracks and prunes per-pass compile errors',
      () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        final backend = _StubCompileBackend();
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);

        const goodGlsl = '''
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  fragColor = vec4(1.0);
}
''';
        final config = TerminalShaderConfig(
          backgroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'bg:ok',
              stage: TerminalShaderStage.background,
              inlineGlsl: goodGlsl,
            ),
            ShaderPassSpec(
              id: 'bg:bad',
              stage: TerminalShaderStage.background,
              inlineGlsl: '#version 460 core\n$goodGlsl',
            ),
          ],
        );
        await controller.syncConfig(config);

        expect(controller.compileErrorForPass('bg:ok'), isNull);
        final badErr = controller.compileErrorForPass('bg:bad');
        expect(badErr, isNotNull);
        expect(badErr!.diagnostics, hasLength(1));
        expect(controller.passCompileErrors.keys, equals(<String>['bg:bad']));
        expect(controller.lastCompileError, same(badErr));

        // Removing the failing pass prunes its error cleanly.
        await controller.syncConfig(
          TerminalShaderConfig(
            backgroundPasses: <ShaderPassSpec>[
              ShaderPassSpec(
                id: 'bg:ok',
                stage: TerminalShaderStage.background,
                inlineGlsl: goodGlsl,
              ),
            ],
          ),
        );
        expect(controller.compileErrorForPass('bg:bad'), isNull);
        expect(controller.passCompileErrors, isEmpty);
        expect(controller.lastCompileError, isNull);

        // L4: reportRuntimeError populates & deduplicates passCompileErrors,
        // and clearLastCompileError clears passCompileErrors and notifies.
        var notifications = 0;
        controller.addListener(() => notifications++);
        const runtimeErr = ShaderCompileException(
          shaderId: 'bg:ok',
          message: 'GPU link failed',
        );
        controller.reportRuntimeError(runtimeErr);
        expect(controller.compileErrorForPass('bg:ok'), same(runtimeErr));
        expect(notifications, equals(1));
        controller.reportRuntimeError(
          const ShaderCompileException(
            shaderId: 'bg:ok',
            message: 'GPU link failed',
          ),
        );
        expect(notifications, equals(1));

        controller.clearLastCompileError();
        expect(controller.passCompileErrors, isEmpty);
        expect(controller.lastCompileError, isNull);
        expect(notifications, equals(2));
      },
    );

    test('hardens diagnostic spans for commented #include, clamped epilogue lines, identifier boundaries, and leading WARNING prefixes', () {
      // L1: Commented #include before real #include points to real directive.
      const commentedInclude = '''
// Do not use #include here
#include "evil.glsl"
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  fragColor = vec4(1.0);
}
''';
      expect(
        () => ShadertoyGlslShim.analyze(commentedInclude),
        throwsA(
          isA<ShaderCompileException>()
              .having((e) => e.lineNumber, 'lineNumber', equals(2))
              .having((e) => e.diagnostics.first.column, 'column', equals(1)),
        ),
      );

      // M2: Clamped preamble/epilogue lines omit misleading column/token spans.
      const shortUser = 'void mainImage(out vec4 fragColor) {\n}';
      final epilogueDiags = parseWebGlDiagnostics(
        "0:120(12): error: 'mainImage' : no matching overloaded function",
        userSource: shortUser,
        prefixLineOffset: 50,
      );
      expect(epilogueDiags, hasLength(1));
      expect(epilogueDiags.first.line, equals(2));
      expect(epilogueDiags.first.column, isNull);

      // M3: Identifier token does not match mid-word substring.
      expect(
        resolveQuotedTokenSpan(
          'float mixVal = 1.0;',
          "ERROR: 'x' : undeclared identifier",
        ),
        isNull,
      );

      // L2: Leading WARNING prefix on named .glsl line parses as warning.
      final warnDiags = parseImpellercDiagnostics(
        'WARNING: fragment.glsl:51: implicit truncation of vector',
        userSource: 'void mainImage(out vec4 c, in vec2 p) { c = vec4(1.0); }',
        shimPrefixLineCount: 50,
      );
      expect(warnDiags, hasLength(1));
      expect(
        warnDiags.first.severity,
        equals(ShaderDiagnosticSeverity.warning),
      );
    });
  });
}

final class _StubHandle implements CompiledShaderHandle {
  @override
  final String id;

  @override
  final bool usesPrevFrame;

  _StubHandle(this.id, this.usesPrevFrame);

  @override
  void dispose() {}
}

final class _StubCompileBackend implements TerminalShaderBackend {
  @override
  ShaderBackendKind get kind => ShaderBackendKind.flutterGpu;

  @override
  bool get supportsCustomGlsl => true;

  @override
  bool get supportsSyncBackground => true;

  @override
  Future<CompiledShaderHandle> compile(
    String id,
    String shadertoyGlsl, {
    bool usesPrevFrame = false,
  }) async => _StubHandle(id, usesPrevFrame);

  @override
  Future<void> reload(
    CompiledShaderHandle handle,
    String shadertoyGlsl,
  ) async {}

  @override
  ui.Image? renderBackgroundSync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? wallpaperImage,
    GpuFrameWatchdog? watchdog,
  }) => null;

  @override
  Future<ui.Image?> renderPassesAsync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? inputImage,
    ui.Image? wallpaperImage,
    GpuFrameWatchdog? watchdog,
  }) async => null;

  @override
  void dispose() {}
}
