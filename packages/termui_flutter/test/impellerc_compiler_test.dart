import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:flutter_test/flutter_test.dart';
import 'package:source_span/source_span.dart';
import 'package:termui_flutter/src/rendering/builtin_shaders.dart';
import 'package:termui_flutter/src/rendering/gpu_atlas_batch.dart';
import 'package:termui_flutter/src/rendering/gpu_atlas_shaders.dart';
import 'package:termui_flutter/src/rendering/impellerc_compiler_io.dart';
import 'package:termui_flutter/src/rendering/impellerc_compiler_stub.dart'
    as stub;
import 'package:termui_flutter/src/rendering/shader_backend.dart';
import 'package:termui_flutter/src/rendering/shader_backend_gpu.dart';
import 'package:termui_flutter/src/rendering/shader_diagnostic_parser.dart';
import 'package:termui_flutter/src/rendering/shader_region_painter.dart';
import 'package:termui_flutter/src/rendering/shader_spec.dart';
import 'package:termui_flutter/src/rendering/shadertoy_glsl_shim.dart';

/// Real Ghostty-compatible community shaders exercising verbatim
/// `shadertoy_prefix.glsl` uniforms (`iPalette[256]`, `iBackgroundColor`,
/// `iForegroundColor`, `iCurrentCursor`/`iPreviousCursor` `(x, y, w, h)`,
/// `iCurrentCursorStyle`, `CURSORSTYLE_*`, `iFocus`, `iTimeFocus`,
/// `texture2D`, and `iPrevFrame`).
const Map<String, String> _ghosttyCommunityShaders = <String, String>{
  'ghostty_cursor_smear': '''
float easeOutCubic(float t) {
  float inv = 1.0 - clamp(t, 0.0, 1.0);
  return 1.0 - inv * inv * inv;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / max(iResolution.xy, vec2(1.0));
  vec4 base = texture2D(iChannel0, uv);
  if (iCursorVisible == 0) {
    fragColor = base;
    return;
  }
  float progress = easeOutCubic((iTime - iTimeCursorChange) / 0.22);
  vec2 cur = iCurrentCursor.xy + iCurrentCursor.zw * 0.5;
  vec2 prev = iPreviousCursor.xy + iPreviousCursor.zw * 0.5;
  vec2 pos = mix(prev, cur, progress);
  float glow = exp(-length(fragCoord - pos) * 0.06) * (1.0 - progress);
  vec3 tint = iCurrentCursorStyle == CURSORSTYLE_BAR
      ? iCurrentCursorColor.rgb
      : mix(iPreviousCursorColor.rgb, iCursorColor.rgb, progress);
  fragColor = vec4(base.rgb + tint * glow * 0.55, base.a);
}
''',
  'ghostty_palette_aurora': '''
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / max(iResolution.xy, vec2(1.0));
  vec4 terminal = texture(iChannel0, uv);
  int slot = int(clamp(floor(uv.x * 255.0), 0.0, 255.0));
  vec3 pal = iPalette[slot];
  vec3 themeMix = mix(iBackgroundColor, iForegroundColor, 0.12);
  float focusDim = iFocus == 1 ? 1.0 : 0.78;
  fragColor = vec4(mix(terminal.rgb, pal + themeMix * 0.05, 0.04) * focusDim, terminal.a);
}
''',
  'ghostty_retro_persistence': '''
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / max(iResolution.xy, vec2(1.0));
  vec4 current = texture(iChannel0, uv);
  vec4 previous = texture(iPrevFrame, uv);
  vec4 wallpaper = texture(iChannel1, uv);
  float focusFade = clamp((iTime - iTimeFocus) * 2.0, 0.0, 1.0);
  vec3 trail = max(current.rgb, previous.rgb * 0.8);
  fragColor = vec4(mix(trail, wallpaper.rgb, 0.05 * focusFade), current.a);
}
''',
};

final class _FakeHandle implements CompiledShaderHandle {
  @override
  final String id;

  @override
  final bool usesPrevFrame;

  const _FakeHandle(this.id, {this.usesPrevFrame = false});

  @override
  void dispose() {}
}

/// Models Impeller Metal's `MTLCommandBuffer` single-active-encoder contract
/// under Flutter 3.50's `flutter_gpu`, where encoders stay open until
/// `submit()`.
final class _StrictMetalCommandBuffer {
  final int id;
  final List<String> ops = <String>[];
  bool _hasOpenEncoder = false;
  bool submitted = false;

  _StrictMetalCommandBuffer(this.id);

  void encodeRenderPass(String target) {
    _openEncoder('render:$target');
  }

  void encodeBlitCopy(String source, String destination) {
    _openEncoder('blit:$source->$destination');
  }

  void submit() {
    if (submitted) {
      throw StateError('CommandBuffer #$id already submitted.');
    }
    submitted = true;
    _hasOpenEncoder = false;
  }

  void _openEncoder(String op) {
    if (submitted) {
      throw StateError('CommandBuffer #$id already submitted.');
    }
    if (_hasOpenEncoder) {
      throw StateError(
        'A command encoder is already encoding to this command buffer',
      );
    }
    _hasOpenEncoder = true;
    ops.add(op);
  }
}

String _joinPath(List<String> parts) => parts.join(Platform.pathSeparator);

String _writeExecutableScript(Directory dir, String name, String body) {
  final file = File(_joinPath(<String>[dir.path, name]))
    ..writeAsStringSync(body);
  if (!Platform.isWindows) {
    Process.runSync('chmod', <String>['+x', file.path]);
  }
  return file.path;
}

void main() {
  final defaultCompiler = ImpellercCompiler();
  final realImpellercPath = defaultCompiler.resolveImpellercPath();

  group('ImpellercCompiler pure-Dart SHA-256 and error parsing', () {
    test('computes FIPS 180-4 SHA-256 test vectors accurately', () {
      expect(
        ImpellercCompiler.sha256Hex(''),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        ImpellercCompiler.sha256Hex('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(
        ImpellercCompiler.sha256Hex(
          'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
        ),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
    });

    test('validates IPSB FlatBuffer header bytes', () {
      final valid = Uint8List(20);
      valid[4] = 0x49; // 'I'
      valid[5] = 0x50; // 'P'
      valid[6] = 0x53; // 'S'
      valid[7] = 0x42; // 'B'
      expect(ImpellercCompiler.isValidShaderBundleBytes(valid), isTrue);
      expect(ImpellercCompiler.isValidShaderBundleBytes(Uint8List(8)), isFalse);
      expect(
        ImpellercCompiler.isValidShaderBundleBytes(Uint8List(20)),
        isFalse,
      );
    });

    test('parses compiler line numbers with shim offset adjustment', () {
      const sampleLog =
          'Compilation failed for bundled shader "TerminalShaderFragment".\n'
          'TerminalShaderFragment:80: error: \'badVar\' : undeclared identifier\n';
      expect(ImpellercCompiler.parseErrorLineNumber(sampleLog), 80);
      expect(
        ImpellercCompiler.parseErrorLineNumber(
          sampleLog,
          shimPrefixLineCount: 75,
          userLineCount: 10,
        ),
        5,
      );
      // Out-of-bounds falls back to compiler line number.
      expect(
        ImpellercCompiler.parseErrorLineNumber(
          sampleLog,
          shimPrefixLineCount: 75,
          userLineCount: 3,
        ),
        80,
      );
      expect(
        ImpellercCompiler.parseErrorLineNumber(
          sampleLog,
          shimPrefixLineCount: 90,
          userLineCount: 10,
        ),
        80,
      );
      expect(
        ImpellercCompiler.parseErrorLineNumber('ERROR: 0:14: syntax error'),
        14,
      );
      expect(
        ImpellercCompiler.parseErrorLineNumber('vertex.glsl:9: error: bad'),
        9,
      );
      expect(ImpellercCompiler.parseErrorLineNumber('no line info'), isNull);

      expect(
        ImpellercCompiler.formatCompilerError(sampleLog),
        "'badVar' : undeclared identifier",
      );
      expect(
        ImpellercCompiler.formatCompilerError('plain failure line\nsecond'),
        'plain failure line',
      );
      expect(
        ImpellercCompiler.formatCompilerError('   \n  '),
        contains('without diagnostic output'),
      );
    });

    test('parseImpellercDiagnostics extracts multi-error, warning, and info spans with shim clamping', () {
      const userSource = '''
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  float mixVal = max(0.0, x);
  vec4 col = unknownVar;
  fragColor = col;
}
''';
      const log = '''
Compilation failed for bundled shader "TerminalShaderFragment".
"TerminalShaderFragment": GLSL to SPIRV failed; Compilation error. 3 error(s) and 1 warning(s).
TerminalShaderFragment:77: warning: 'x' : variable is not initialized
TerminalShaderFragment:78: error: 'unknownVar' : undeclared identifier
TerminalShaderFragment:78: error: '=' : cannot convert from ' temp float' to ' temp highp 4-component vector of float'
TerminalShaderFragment:79:15: info: 'col' : value truncated
TerminalShaderVertex:4: error: 'a_pos' : invalid location
TerminalShaderFragment:50: error: preamble failure
TerminalShaderFragment:120: error: epilogue failure
''';
      final diagnostics = parseImpellercDiagnostics(
        log,
        userSource: userSource,
        shimPrefixLineCount: 75,
      );
      final sourceFile = SourceFile.fromString(userSource);
      expect(diagnostics, hasLength(7));

      // Whole-word match finds 'x', not 'mixVal' or 'max'.
      expect(diagnostics[0].severity, ShaderDiagnosticSeverity.warning);
      expect(diagnostics[0].origin, ShaderDiagnosticOrigin.compiler);
      expect(diagnostics[0].line, 2);
      expect(diagnostics[0].toSourceSpan(sourceFile)!.text, 'x');

      // Quoted identifier token span.
      expect(diagnostics[1].severity, ShaderDiagnosticSeverity.error);
      expect(diagnostics[1].line, 3);
      expect(diagnostics[1].toSourceSpan(sourceFile)!.text, 'unknownVar');

      // Quoted operator token span.
      expect(diagnostics[2].line, 3);
      expect(diagnostics[2].toSourceSpan(sourceFile)!.text, '=');

      // Explicit column + info severity.
      expect(diagnostics[3].severity, ShaderDiagnosticSeverity.info);
      expect(diagnostics[3].line, 4);
      expect(diagnostics[3].column, 15);
      expect(diagnostics[3].toSourceSpan(sourceFile)!.text, 'col');

      // Vertex shader error does not subtract fragment shim prefix.
      expect(diagnostics[4].line, 4);

      // Preamble and epilogue errors clamp into [1, userLineCount].
      expect(diagnostics[5].line, 1);
      expect(diagnostics[6].line, 5);

      // firstErrorDiagnostic skips leading warnings.
      expect(firstErrorDiagnostic(diagnostics), equals(diagnostics[1]));
      expect(
        firstErrorDiagnostic(<ShaderDiagnostic>[diagnostics[0]]),
        equals(diagnostics[0]),
      );
      expect(firstErrorDiagnostic(const <ShaderDiagnostic>[]), isNull);

      // Empty/whitespace and unstructured fallback logs.
      expect(
        parseImpellercDiagnostics('  \n\t ', userSource: userSource),
        isEmpty,
      );
      final fallback = parseImpellercDiagnostics(
        'linker: error: undefined symbol',
        userSource: userSource,
      );
      expect(fallback, hasLength(1));
      expect(fallback.single.line, isNull);
      expect(fallback.single.message, 'undefined symbol');
      expect(
        parseImpellercDiagnostics(
          'plain failure\nsecond',
          userSource: '',
        ).single.message,
        'plain failure',
      );
      // Empty userSource still subtracts offset and clamps low values to 1.
      expect(
        parseImpellercDiagnostics(
          'ERROR: 0:10: syntax error',
          userSource: '',
          shimPrefixLineCount: 20,
        ).single.line,
        1,
      );
    });

    test('parseWebGlDiagnostics parses ANGLE, Mesa, generic line, and link logs with token spans', () {
      const userSource = '''
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  float unusedVar = 1.0;
  fragColor = badToken + 1.0;
}
''';
      final sourceFile = SourceFile.fromString(userSource);

      // ANGLE multi-error/warning log with trailing NUL byte.
      const angleLog =
          "WARNING: 0:42: 'unusedVar' : unused variable\n"
          "ERROR: 0:43: 'badToken' : undeclared identifier\n"
          "ERROR: 0:43: '' : syntax error\u0000";
      final angleDiags = parseWebGlDiagnostics(
        angleLog,
        userSource: userSource,
        prefixLineOffset: 40,
      );
      expect(angleDiags, hasLength(3));
      expect(angleDiags[0].severity, ShaderDiagnosticSeverity.warning);
      expect(angleDiags[0].line, 2);
      expect(angleDiags[0].toSourceSpan(sourceFile)!.text, 'unusedVar');
      expect(angleDiags[1].severity, ShaderDiagnosticSeverity.error);
      expect(angleDiags[1].line, 3);
      expect(angleDiags[1].toSourceSpan(sourceFile)!.text, 'badToken');
      expect(angleDiags[2].line, 3);
      expect(angleDiags[2].column, isNull);

      // Mesa multi-error/warning log with explicit 1-based columns.
      const mesaLog =
          "0:42(9): warning: unused variable 'unusedVar'\n"
          "0:43(15): error: 'badToken' undeclared\n"
          '0:43(24): error: invalid operator\n'
          '0:43(15): preprocessor error: bad directive\n';
      final mesaDiags = parseWebGlDiagnostics(
        mesaLog,
        userSource: userSource,
        prefixLineOffset: 40,
      );
      expect(mesaDiags, hasLength(4));
      expect(mesaDiags[0].severity, ShaderDiagnosticSeverity.warning);
      expect(mesaDiags[0].line, 2);
      expect(mesaDiags[0].column, 9);
      expect(mesaDiags[0].toSourceSpan(sourceFile)!.text, 'unusedVar');
      expect(mesaDiags[1].line, 3);
      expect(mesaDiags[1].column, 15);
      expect(mesaDiags[1].toSourceSpan(sourceFile)!.text, 'badToken');
      expect(mesaDiags[2].column, 24);
      expect(mesaDiags[2].length, 1);
      expect(mesaDiags[3].severity, ShaderDiagnosticSeverity.error);
      expect(mesaDiags[3].toSourceSpan(sourceFile)!.text, 'badToken');

      // Generic line fallback with severities + link fallback + empty log.
      const genericLog =
          'WARNING: implicit cast on line 42\n'
          'NOTE: check precision on line 43\n'
          'ERROR: syntax error at line 99\n';
      final genericDiags = parseWebGlDiagnostics(
        genericLog,
        userSource: userSource,
        prefixLineOffset: 40,
      );
      expect(genericDiags, hasLength(3));
      expect(genericDiags[0].severity, ShaderDiagnosticSeverity.warning);
      expect(genericDiags[0].line, 2);
      expect(genericDiags[1].severity, ShaderDiagnosticSeverity.info);
      expect(genericDiags[1].line, 3);
      expect(genericDiags[2].severity, ShaderDiagnosticSeverity.error);
      expect(genericDiags[2].line, 4);

      final linkDiag = parseWebGlDiagnostics(
        'Fragment shader failed to link.\u0000',
        userSource: userSource,
        prefixLineOffset: 40,
      );
      expect(linkDiag, hasLength(1));
      expect(linkDiag.single.line, isNull);
      expect(linkDiag.single.message, 'Fragment shader failed to link.');
      expect(
        parseWebGlDiagnostics(
          '\u0000  \n',
          userSource: userSource,
          prefixLineOffset: 40,
        ),
        isEmpty,
      );

      // Explicit column on empty line clamps safely.
      expect(
        resolveQuotedTokenSpan('', 'bad', explicitColumn: 5),
        equals((column: 1, length: 1)),
      );
      expect(resolveQuotedTokenSpan('', "'foo'"), isNull);
    });

    test(
      'avoids quadratic ReDoS on adversarial impellerc and Mesa log lines',
      () {
        final swNamedMulti = Stopwatch()..start();
        parseImpellercDiagnostics('a.glsl' * 1600, userSource: '');
        swNamedMulti.stop();
        expect(swNamedMulti.elapsedMilliseconds, lessThan(200));

        final swNamedSingle = Stopwatch()..start();
        parseImpellercDiagnostics('${'a' * 16000}.glsl', userSource: '');
        swNamedSingle.stop();
        expect(swNamedSingle.elapsedMilliseconds, lessThan(200));

        final swMesa = Stopwatch()..start();
        parseWebGlDiagnostics(
          '0:1${' ' * 16000}!',
          userSource: '',
          prefixLineOffset: 0,
        );
        swMesa.stop();
        expect(swMesa.elapsedMilliseconds, lessThan(200));

        // Delimiter-anchored named file pattern still matches colon- and
        // whitespace-prefixed compiler lines as well as unprefixed lines.
        final prefixed = parseImpellercDiagnostics(
          'impellerc:foo.glsl:1:3: error: bad token',
          userSource: 'float x = bad;',
        );
        expect(prefixed, hasLength(1));
        expect(prefixed.single.line, equals(1));
        expect(prefixed.single.column, equals(3));

        // Mesa lines without explicit column still parse with trailing spaces.
        final mesaNoCol = parseWebGlDiagnostics(
          '0:12   : warning: precision hint',
          userSource: '',
          prefixLineOffset: 0,
        );
        expect(mesaNoCol, hasLength(1));
        expect(mesaNoCol.single.line, equals(12));
        expect(mesaNoCol.single.column, isNull);
        expect(mesaNoCol.single.severity, ShaderDiagnosticSeverity.warning);
      },
    );

    test('handles empty quotes before real quoted token and skips comments in token lookup', () {
      const userSource =
          'void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n'
          '  fragColor = badToken + 1.0;\n'
          '}\n';
      final sourceFile = SourceFile.fromString(userSource);
      final diags = parseWebGlDiagnostics(
        "ERROR: 0:42: '' : syntax error, unexpected 'badToken'",
        userSource: userSource,
        prefixLineOffset: 40,
      );
      expect(diags, hasLength(1));
      expect(diags.single.line, equals(2));
      expect(diags.single.column, isNotNull);
      expect(diags.single.toSourceSpan(sourceFile)!.text, equals('badToken'));

      // Inline block comments and trailing line comments are masked before search.
      const leadingCommentLine = '/* badToken */ fragColor = badToken;';
      final leadingSpan = resolveQuotedTokenSpan(
        leadingCommentLine,
        "ERROR: 'badToken' : undeclared identifier",
      );
      expect(leadingSpan, isNotNull);
      expect(leadingSpan!.column, equals(28));
      expect(leadingSpan.length, equals('badToken'.length));

      expect(
        resolveQuotedTokenSpan(
          'fragColor = vec4(1.0); // badToken',
          "ERROR: 'badToken' : undeclared identifier",
        ),
        isNull,
      );
      expect(
        resolveQuotedTokenSpan(
          '/* unclosed badToken',
          "ERROR: 'badToken' : undeclared identifier",
        ),
        isNull,
      );
    });

    test(
      'returns unmodifiable diagnostic lists from impellerc and WebGL parsers',
      () {
        final impParsed = parseImpellercDiagnostics(
          'ERROR: TerminalShaderFragment:5: syntax error',
          userSource: '',
        );
        final impFallback = parseImpellercDiagnostics(
          'plain failure',
          userSource: '',
        );
        final webParsed = parseWebGlDiagnostics(
          'ERROR: 0:5: syntax error',
          userSource: '',
          prefixLineOffset: 0,
        );
        final webFallback = parseWebGlDiagnostics(
          'Fragment shader failed to link.',
          userSource: '',
          prefixLineOffset: 0,
        );
        expect(() => impParsed.clear(), throwsUnsupportedError);
        expect(() => impFallback.clear(), throwsUnsupportedError);
        expect(() => webParsed.clear(), throwsUnsupportedError);
        expect(() => webFallback.clear(), throwsUnsupportedError);
      },
    );
  });

  group('ImpellercCompiler executable and cache path resolution', () {
    test('resolves bundled helper and cache directories across OS layouts', () {
      expect(
        ImpellercCompiler.bundledHelperCandidatesFor(
          '/Applications/fterm.app/Contents/MacOS/fterm',
          operatingSystem: 'macos',
        ),
        contains('/Applications/fterm.app/Contents/Helpers/impellerc'),
      );
      expect(
        ImpellercCompiler.bundledHelperCandidatesFor(
          '/opt/fterm/fterm',
          operatingSystem: 'linux',
        ),
        <String>['/opt/fterm/helpers/impellerc'],
      );
      expect(
        ImpellercCompiler.bundledHelperCandidatesFor(
          r'C:\Program Files\fterm\fterm.exe',
          operatingSystem: 'windows',
        ),
        <String>[r'C:\Program Files\fterm\helpers\impellerc.exe'],
      );
      expect(
        ImpellercCompiler.bundledHelperCandidatesFor(
          '',
          operatingSystem: 'linux',
        ),
        isEmpty,
      );

      expect(
        ImpellercCompiler.defaultCacheDirectoryFor(<String, String>{
          'HOME': '/home/alice',
        }, operatingSystem: 'linux'),
        '/home/alice/.cache/fterm/shaders',
      );
      expect(
        ImpellercCompiler.defaultCacheDirectoryFor(<String, String>{
          'LOCALAPPDATA': r'C:\Users\Alice\AppData\Local',
        }, operatingSystem: 'windows'),
        r'C:\Users\Alice\AppData\Local\fterm\shaders',
      );
      expect(
        ImpellercCompiler.defaultCacheDirectoryFor(
          const <String, String>{},
          operatingSystem: 'linux',
        ),
        isNull,
      );
      expect(
        ImpellercCompiler.defaultCacheDirectoryFor(
          const <String, String>{},
          operatingSystem: 'windows',
        ),
        isNull,
      );
    });

    test('enforces resolution precedence: override > bundled > env > FLUTTER_ROOT > PATH > fallback', () {
      final rawTmp = Directory.systemTemp.createTempSync(
        'termui_resolve_test_',
      );
      addTearDown(() => rawTmp.deleteSync(recursive: true));
      // Resolve OS symlinks / Windows 8.3 short paths (e.g. RUNNER~1 ->
      // runneradmin) so expected paths match PATH lookup resolution.
      final tmp = Directory(rawTmp.resolveSymbolicLinksSync());

      final exeName = Platform.isWindows ? 'impellerc.exe' : 'impellerc';
      final overrideFile = File(
        _joinPath(<String>[tmp.path, 'override_$exeName']),
      )..writeAsStringSync('override');
      final appDir = Directory(_joinPath(<String>[tmp.path, 'app']))
        ..createSync();
      final appExe = Platform.isMacOS
          ? (File(
                _joinPath(<String>[appDir.path, 'Contents', 'MacOS', 'fterm']),
              )
              ..parent.createSync(recursive: true)
              ..writeAsStringSync('app'))
          : (File(
              _joinPath(<String>[
                appDir.path,
                Platform.isWindows ? 'fterm.exe' : 'fterm',
              ]),
            )..writeAsStringSync('app'));
      final bundledFile = Platform.isMacOS
          ? (File(
                _joinPath(<String>[
                  appDir.path,
                  'Contents',
                  'Helpers',
                  exeName,
                ]),
              )
              ..parent.createSync(recursive: true)
              ..writeAsStringSync('bundled'))
          : (File(_joinPath(<String>[appDir.path, 'helpers', exeName]))
              ..parent.createSync(recursive: true)
              ..writeAsStringSync('bundled'));
      final envFile = File(_joinPath(<String>[tmp.path, 'env_$exeName']))
        ..writeAsStringSync('env');

      final isArm64 = Platform.version.toLowerCase().contains('arm64');
      final archDir = Platform.isMacOS
          ? (isArm64 ? 'darwin-arm64' : 'darwin-x64')
          : Platform.isWindows
          ? (isArm64 ? 'windows-arm64' : 'windows-x64')
          : (isArm64 ? 'linux-arm64' : 'linux-x64');

      final flutterRootDir = Directory(
        _joinPath(<String>[tmp.path, 'sdk_env']),
      );
      final flutterRootImpellerc =
          File(
              _joinPath(<String>[
                flutterRootDir.path,
                'bin',
                'cache',
                'artifacts',
                'engine',
                archDir,
                exeName,
              ]),
            )
            ..parent.createSync(recursive: true)
            ..writeAsStringSync('sdk_env');

      final pathSdkDir = Directory(_joinPath(<String>[tmp.path, 'sdk_path']));
      final pathFlutterBin = Directory(
        _joinPath(<String>[pathSdkDir.path, 'bin']),
      )..createSync(recursive: true);
      File(
        _joinPath(<String>[
          pathFlutterBin.path,
          Platform.isWindows ? 'flutter.bat' : 'flutter',
        ]),
      ).writeAsStringSync('flutter');
      final pathImpellerc =
          File(
              _joinPath(<String>[
                pathSdkDir.path,
                'bin',
                'cache',
                'artifacts',
                'engine',
                archDir,
                exeName,
              ]),
            )
            ..parent.createSync(recursive: true)
            ..writeAsStringSync('sdk_path');

      final fallbackSdkDir = Directory(
        _joinPath(<String>[tmp.path, 'sdk_fallback']),
      );
      final fallbackImpellerc =
          File(
              _joinPath(<String>[
                fallbackSdkDir.path,
                'bin',
                'cache',
                'artifacts',
                'engine',
                archDir,
                exeName,
              ]),
            )
            ..parent.createSync(recursive: true)
            ..writeAsStringSync('sdk_fallback');
      final noHelpersExe = _joinPath(<String>[tmp.path, 'no_helpers', 'fterm']);

      // 1. Explicit override wins over everything else.
      final c1 = ImpellercCompiler(
        impellercPathOverride: overrideFile.path,
        resolvedExecutablePath: appExe.path,
        environment: <String, String>{
          'FTERM_IMPELLERC_PATH': envFile.path,
          'FLUTTER_ROOT': flutterRootDir.path,
          'PATH': pathFlutterBin.path,
        },
        fallbackSdkRoots: <String>[fallbackSdkDir.path],
      );
      expect(c1.resolveImpellercPath(), overrideFile.path);
      expect(c1.isAvailable, isTrue);

      // 2. Bundled helper wins over env and SDK.
      final c2 = ImpellercCompiler(
        resolvedExecutablePath: appExe.path,
        environment: <String, String>{
          'FTERM_IMPELLERC_PATH': envFile.path,
          'FLUTTER_ROOT': flutterRootDir.path,
          'PATH': pathFlutterBin.path,
        },
        fallbackSdkRoots: <String>[fallbackSdkDir.path],
      );
      expect(c2.resolveImpellercPath(), bundledFile.path);

      // 3. FTERM_IMPELLERC_PATH wins over FLUTTER_ROOT / PATH / fallback.
      final c3 = ImpellercCompiler(
        resolvedExecutablePath: noHelpersExe,
        environment: <String, String>{
          'FTERM_IMPELLERC_PATH': envFile.path,
          'FLUTTER_ROOT': flutterRootDir.path,
          'PATH': pathFlutterBin.path,
        },
        fallbackSdkRoots: <String>[fallbackSdkDir.path],
      );
      expect(c3.resolveImpellercPath(), envFile.path);

      // 4. FLUTTER_ROOT wins over PATH and fallback.
      final c4 = ImpellercCompiler(
        resolvedExecutablePath: noHelpersExe,
        environment: <String, String>{
          'FLUTTER_ROOT': flutterRootDir.path,
          'PATH': pathFlutterBin.path,
        },
        fallbackSdkRoots: <String>[fallbackSdkDir.path],
      );
      expect(c4.resolveImpellercPath(), flutterRootImpellerc.path);

      // 5. PATH flutter wins over fallback SDK roots.
      final c5 = ImpellercCompiler(
        resolvedExecutablePath: noHelpersExe,
        environment: <String, String>{'PATH': pathFlutterBin.path},
        fallbackSdkRoots: <String>[fallbackSdkDir.path],
      );
      expect(c5.resolveImpellercPath(), pathImpellerc.path);

      // 6. Fallback SDK root used when env is empty.
      final c6 = ImpellercCompiler(
        resolvedExecutablePath: noHelpersExe,
        environment: const <String, String>{},
        fallbackSdkRoots: <String>[fallbackSdkDir.path],
      );
      expect(c6.resolveImpellercPath(), fallbackImpellerc.path);

      expect(
        ImpellercCompiler(
          environment: Platform.isWindows
              ? const <String, String>{'LOCALAPPDATA': r'C:\tmp\local_app_data'}
              : const <String, String>{'HOME': '/tmp/home_test'},
        ).resolveCacheDirectoryPath(),
        Platform.isWindows
            ? r'C:\tmp\local_app_data\fterm\shaders'
            : '/tmp/home_test/.cache/fterm/shaders',
      );

      // 7. Missing binary reports unavailable and throws ShaderCompileException.
      final cMissing = ImpellercCompiler(
        resolvedExecutablePath: noHelpersExe,
        environment: const <String, String>{},
        fallbackSdkRoots: const <String>[],
      );
      expect(cMissing.resolveImpellercPath(), isNull);
      expect(cMissing.isAvailable, isFalse);
      expect(
        () => cMissing.compile(
          BuiltinShaders.scanlineOverlayGlsl,
          shaderId: 'missing_bin',
        ),
        throwsA(
          isA<ShaderCompileException>().having(
            (e) => e.shaderId,
            'shaderId',
            'missing_bin',
          ),
        ),
      );
    });
  });

  group('ImpellercCompiler real impellerc compilation', () {
    test(
      'compiles all 5 built-in presets and 3 Ghostty community shaders into valid IPSB FlatBuffers',
      () async {
        final cacheDir = Directory.systemTemp.createTempSync(
          'termui_shader_cache_',
        );
        addTearDown(() => cacheDir.deleteSync(recursive: true));

        final compiler = ImpellercCompiler(
          impellercPathOverride: realImpellercPath,
          cacheDirectoryPath: cacheDir.path,
        );

        final corpus = <String, String>{
          for (final entry in BuiltinShaders.allPresets.entries)
            'preset_${entry.key.wireName}': entry.value,
          ..._ghosttyCommunityShaders,
        };

        for (final entry in corpus.entries) {
          final compiled = await compiler.compile(
            entry.value,
            shaderId: entry.key,
          );
          final bytes = compiled.bytes.buffer.asUint8List(
            compiled.bytes.offsetInBytes,
            compiled.bytes.lengthInBytes,
          );
          expect(compiled.fromCache, isFalse);
          expect(compiled.cacheKey.length, 64);
          expect(
            ImpellercCompiler.isValidShaderBundleBytes(bytes),
            isTrue,
            reason: '${entry.key} did not produce a valid IPSB FlatBuffer',
          );
          expect(bytes.length, greaterThan(1024));
        }
      },
      skip: realImpellercPath == null
          ? 'impellerc binary not found in Flutter SDK cache'
          : false,
    );

    test(
      'compiles all 8 ShaderRegionPresets and invalidates cacheKey when GLSL changes for same shaderId',
      () async {
        final cacheDir = Directory.systemTemp.createTempSync(
          'termui_region_shader_cache_',
        );
        addTearDown(() => cacheDir.deleteSync(recursive: true));

        final compiler = ImpellercCompiler(
          impellercPathOverride: realImpellercPath,
          cacheDirectoryPath: cacheDir.path,
        );

        for (final id in ShaderRegionPresets.presetIds) {
          final compiled = await compiler.compile(
            ShaderRegionPresets.sourceFor(id)!,
            shaderId: id,
          );
          final bytes = compiled.bytes.buffer.asUint8List(
            compiled.bytes.offsetInBytes,
            compiled.bytes.lengthInBytes,
          );
          expect(compiled.fromCache, isFalse);
          expect(
            ImpellercCompiler.isValidShaderBundleBytes(bytes),
            isTrue,
            reason: 'Region preset $id did not produce a valid IPSB FlatBuffer',
          );
        }

        // Changing GLSL for the same shaderId must miss cache with a fresh SHA-256 key.
        final v1 = await compiler.compile(
          ShaderRegionPresets.forgeSparkGlsl,
          shaderId: 'forge_spark',
        );
        expect(v1.fromCache, isTrue);

        final v2 = await compiler.compile(
          '${ShaderRegionPresets.forgeSparkGlsl}\n// modified revision\n',
          shaderId: 'forge_spark',
        );
        expect(v2.fromCache, isFalse);
        expect(v2.cacheKey, isNot(equals(v1.cacheKey)));
      },
      skip: realImpellercPath == null
          ? 'impellerc binary not found in Flutter SDK cache'
          : false,
    );

    test(
      'emits GLSL ES 3.00 (#version 300 es) instead of #version 100 for const array initializers',
      () async {
        final cacheDir = Directory.systemTemp.createTempSync(
          'termui_gles300_shader_cache_',
        );
        addTearDown(() => cacheDir.deleteSync(recursive: true));

        final compiler = ImpellercCompiler(
          impellercPathOverride: realImpellercPath,
          cacheDirectoryPath: cacheDir.path,
        );

        const arrayInitShader = '''
const vec2 kCorners[] = vec2[](
  vec2(0.0, 0.0),
  vec2(1.0, 0.0),
  vec2(0.0, 1.0),
  vec2(1.0, 1.0)
);

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / max(iResolution.xy, vec2(1.0));
  vec2 c = kCorners[int(mod(iTime, 4.0))];
  fragColor = vec4(uv, c.x, 1.0);
}
''';

        final compiled = await compiler.compile(
          arrayInitShader,
          shaderId: 'northern_nested_circles_repro',
        );
        final bytes = compiled.bytes.buffer.asUint8List(
          compiled.bytes.offsetInBytes,
          compiled.bytes.lengthInBytes,
        );
        expect(ImpellercCompiler.isValidShaderBundleBytes(bytes), isTrue);

        final bundleText = latin1.decode(bytes);
        expect(bundleText, contains('#version 300 es'));
        expect(bundleText, isNot(contains('#version 100')));
      },
      skip: realImpellercPath == null
          ? 'impellerc binary not found in Flutter SDK cache'
          : false,
    );

    test(
      'resolveSafeGpuColorFormat maps PixelFormat.unknown to b8g8r8a8UNormInt',
      () {
        expect(
          FlutterGpuShaderBackend.resolveSafeGpuColorFormat(
            gpu.PixelFormat.unknown,
          ),
          equals(gpu.PixelFormat.b8g8r8a8UNormInt),
        );
        expect(
          FlutterGpuShaderBackend.resolveSafeGpuColorFormat(
            gpu.PixelFormat.r8g8b8a8UNormInt,
          ),
          equals(gpu.PixelFormat.r8g8b8a8UNormInt),
        );
        expect(
          FlutterGpuShaderBackend.resolveSafeGpuColorFormat(
            gpu.PixelFormat.b8g8r8a8UNormInt,
          ),
          equals(gpu.PixelFormat.b8g8r8a8UNormInt),
        );
      },
    );

    test('filterHealthyShaderPasses preserves healthy lists without copying and drops failed handles', () {
      final uniforms = TerminalShaderUniforms(width: 640, height: 480);
      final ShaderPassInvocation healthy = (
        handle: const _FakeHandle('bg:healthy'),
        uniforms: uniforms,
        prevFrameKey: null,
      );
      final ShaderPassInvocation broken = (
        handle: const _FakeHandle('bg:broken'),
        uniforms: uniforms,
        prevFrameKey: null,
      );

      const empty = <ShaderPassInvocation>[];
      expect(
        identical(
          FlutterGpuShaderBackend.filterHealthyShaderPasses(empty),
          empty,
        ),
        isTrue,
      );

      final allHealthy = <ShaderPassInvocation>[healthy];
      expect(
        identical(
          FlutterGpuShaderBackend.filterHealthyShaderPasses(allHealthy),
          allHealthy,
        ),
        isTrue,
      );

      final filtered = FlutterGpuShaderBackend.filterHealthyShaderPasses(
        <ShaderPassInvocation>[healthy, broken],
        isFailed: (h) => h.id == 'bg:broken',
      );
      expect(filtered.map((p) => p.handle.id), equals(<String>['bg:healthy']));

      final allBroken = FlutterGpuShaderBackend.filterHealthyShaderPasses(
        <ShaderPassInvocation>[broken],
        isFailed: (h) => h.id == 'bg:broken',
      );
      expect(allBroken, isEmpty);
    });

    test(
      'compiles GpuAtlasShaders instanced Impeller bundle via real impellerc into valid IPSB FlatBuffer',
      () async {
        final cacheDir = Directory.systemTemp.createTempSync(
          'termui_atlas_bundle_',
        );
        addTearDown(() => cacheDir.deleteSync(recursive: true));

        final compiler = ImpellercCompiler(
          impellercPathOverride: realImpellercPath,
          cacheDirectoryPath: cacheDir.path,
        );
        final compiled = await compiler.compileRawBundle(
          vertexGlsl: GpuAtlasShaders.impellerVertexSource,
          fragmentGlsl: GpuAtlasShaders.impellerFragmentSource,
          vertexEntryName: GpuAtlasShaders.impellerVertexName,
          fragmentEntryName: GpuAtlasShaders.impellerFragmentName,
          shaderId: 'direct_gpu_atlas',
        );
        final bytes = compiled.buffer.asUint8List(
          compiled.offsetInBytes,
          compiled.lengthInBytes,
        );
        expect(ImpellercCompiler.isValidShaderBundleBytes(bytes), isTrue);
        expect(bytes.length, greaterThan(512));
      },
      skip: realImpellercPath == null
          ? 'impellerc binary not found in Flutter SDK cache'
          : false,
    );

    test(
      'serves second compilation from SHA-256 disk cache without invoking impellerc',
      () async {
        final tmp = Directory.systemTemp.createTempSync('termui_cache_hit_');
        addTearDown(() => tmp.deleteSync(recursive: true));
        final cacheDir = Directory('${tmp.path}/cache')..createSync();
        final counterFile = File('${tmp.path}/invocations.txt');

        final wrapperPath = _writeExecutableScript(
          tmp,
          'impellerc_wrapper.sh',
          '#!/bin/sh\n'
              'echo run >> "${counterFile.path}"\n'
              'exec "$realImpellercPath" "\$@"\n',
        );

        final compiler = ImpellercCompiler(
          impellercPathOverride: wrapperPath,
          cacheDirectoryPath: cacheDir.path,
        );

        final first = await compiler.compile(
          BuiltinShaders.crtLottesGlsl,
          shaderId: 'crt_lottes',
        );
        expect(first.fromCache, isFalse);
        expect(counterFile.readAsLinesSync().length, 1);

        final second = await compiler.compile(
          BuiltinShaders.crtLottesGlsl,
          shaderId: 'crt_lottes',
        );
        expect(second.fromCache, isTrue);
        expect(second.cacheKey, first.cacheKey);
        expect(
          second.bytes.buffer.asUint8List(
            second.bytes.offsetInBytes,
            second.bytes.lengthInBytes,
          ),
          first.bytes.buffer.asUint8List(
            first.bytes.offsetInBytes,
            first.bytes.lengthInBytes,
          ),
        );
        // Subprocess must NOT have been spawned a second time.
        expect(counterFile.readAsLinesSync().length, 1);

        // Corrupt cached file -> automatically treated as miss & recompiled.
        final cachedFile = File(
          '${cacheDir.path}/${first.cacheKey}.shaderbundle',
        );
        cachedFile.writeAsBytesSync(<int>[1, 2, 3, 4]);
        final third = await compiler.compile(
          BuiltinShaders.crtLottesGlsl,
          shaderId: 'crt_lottes',
        );
        expect(third.fromCache, isFalse);
        expect(counterFile.readAsLinesSync().length, 2);
      },
      skip: realImpellercPath == null || Platform.isWindows
          ? 'POSIX wrapper script test requires real impellerc on POSIX'
          : false,
    );

    test(
      'enforces subprocess timeout and kills hung impellerc processes',
      () async {
        final tmp = Directory.systemTemp.createTempSync('termui_timeout_test_');
        addTearDown(() => tmp.deleteSync(recursive: true));

        final slowScript = _writeExecutableScript(
          tmp,
          'slow_impellerc.sh',
          '#!/bin/sh\nexec sleep 5\n',
        );
        final compiler = ImpellercCompiler(
          impellercPathOverride: slowScript,
          cacheDirectoryPath: '${tmp.path}/cache',
          timeout: const Duration(milliseconds: 120),
        );

        final stopwatch = Stopwatch()..start();
        await expectLater(
          compiler.compile(
            BuiltinShaders.scanlineOverlayGlsl,
            shaderId: 'slow_shader',
          ),
          throwsA(
            isA<ShaderCompileException>()
                .having((e) => e.shaderId, 'shaderId', 'slow_shader')
                .having((e) => e.message, 'message', contains('timed out')),
          ),
        );
        stopwatch.stop();
        expect(stopwatch.elapsedMilliseconds, lessThan(2500));
      },
      skip: Platform.isWindows ? 'POSIX sleep helper script' : false,
    );

    test(
      'rejects #include directives in shim and via empty --include sandbox',
      () async {
        final tmp = Directory.systemTemp.createTempSync('termui_include_test_');
        addTearDown(() => tmp.deleteSync(recursive: true));

        final compiler = ImpellercCompiler(
          impellercPathOverride: realImpellercPath,
          cacheDirectoryPath: '${tmp.path}/cache',
        );

        // Layer 1: Static rejection in ShadertoyGlslShim.
        const shaderWithInclude = '''
#include "secret.glsl"
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  fragColor = vec4(1.0);
}
''';
        await expectLater(
          compiler.compile(shaderWithInclude, shaderId: 'inc_shim'),
          throwsA(
            isA<ShaderCompileException>().having(
              (e) => e.message,
              'message',
              contains('#include'),
            ),
          ),
        );

        // Layer 2: Real impellerc fails with empty --include directory.
        const rawIncludeFragment = '''
#version 460 core
#include "secret.glsl"
layout(location = 0) out vec4 out_frag_color;
void main() {
  out_frag_color = vec4(1.0);
}
''';
        await expectLater(
          compiler.compileRawBundle(
            vertexGlsl: ShadertoyGlslShim.impellerVertexShaderSource,
            fragmentGlsl: rawIncludeFragment,
            shaderId: 'inc_raw',
            useCache: false,
          ),
          throwsA(
            isA<ShaderCompileException>()
                .having((e) => e.shaderId, 'shaderId', 'inc_raw')
                .having((e) => e.lineNumber, 'lineNumber', 2)
                .having(
                  (e) => e.compilerLog,
                  'compilerLog',
                  contains('#include'),
                ),
          ),
        );
      },
      skip: realImpellercPath == null
          ? 'impellerc binary not found in Flutter SDK cache'
          : false,
    );

    test(
      'parses GLSL syntax errors into user-relative line numbers',
      () async {
        final tmp = Directory.systemTemp.createTempSync('termui_syntax_test_');
        addTearDown(() => tmp.deleteSync(recursive: true));

        final compiler = ImpellercCompiler(
          impellercPathOverride: realImpellercPath,
          cacheDirectoryPath: '${tmp.path}/cache',
        );

        const brokenShader = '''
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / iResolution.xy;
  fragColor = undeclared_identifier_xyz;
}
''';
        await expectLater(
          compiler.compile(brokenShader, shaderId: 'broken.glsl'),
          throwsA(
            isA<ShaderCompileException>()
                .having((e) => e.shaderId, 'shaderId', 'broken.glsl')
                .having((e) => e.lineNumber, 'lineNumber', 3)
                .having(
                  (e) => e.message,
                  'message',
                  contains('undeclared_identifier_xyz'),
                )
                .having(
                  (e) => e.compilerLog,
                  'compilerLog',
                  contains('TerminalShaderFragment'),
                )
                .having((e) => e.diagnostics, 'diagnostics', isNotEmpty),
          ),
        );

        // Multi-error shader produces multiple span-annotated ShaderDiagnostics.
        const multiBrokenShader = '''
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec4 a = undeclared_one;
  vec4 b = undeclared_two;
  fragColor = a + b;
}
''';
        ShaderCompileException? multiError;
        try {
          await compiler.compile(multiBrokenShader, shaderId: 'multi.glsl');
        } on ShaderCompileException catch (error) {
          multiError = error;
        }
        expect(multiError, isNotNull);
        expect(multiError!.lineNumber, 2);
        expect(multiError.message, contains('undeclared_one'));
        expect(multiError.diagnostics.length, greaterThanOrEqualTo(2));

        final sourceFile = SourceFile.fromString(multiBrokenShader);
        final firstIdent = multiError.diagnostics.firstWhere(
          (d) => d.message.contains('undeclared_one'),
        );
        final secondIdent = multiError.diagnostics.firstWhere(
          (d) => d.message.contains('undeclared_two'),
        );
        expect(firstIdent.line, 2);
        expect(firstIdent.toSourceSpan(sourceFile)!.text, 'undeclared_one');
        expect(secondIdent.line, 3);
        expect(secondIdent.toSourceSpan(sourceFile)!.text, 'undeclared_two');
      },
      skip: realImpellercPath == null
          ? 'impellerc binary not found in Flutter SDK cache'
          : false,
    );

    test('rejects non-executable binary, missing output file, and invalid IPSB payload', () async {
      final tmp = Directory.systemTemp.createTempSync('termui_bad_out_test_');
      addTearDown(() => tmp.deleteSync(recursive: true));

      // 1. Non-executable file fails to spawn -> ShaderCompileException.
      final notExec = File('${tmp.path}/not_exec')..writeAsStringSync('hi');
      final badLaunch = ImpellercCompiler(
        impellercPathOverride: notExec.path,
        cacheDirectoryPath: '${tmp.path}/cache1',
      );
      await expectLater(
        badLaunch.compile(BuiltinShaders.scanlineOverlayGlsl, shaderId: 'nx'),
        throwsA(
          isA<ShaderCompileException>()
              .having((e) => e.shaderId, 'shaderId', 'nx')
              .having(
                (e) => e.message,
                'message',
                contains('Failed to launch'),
              ),
        ),
      );

      // 2. Exits 0 without creating --sl file -> ShaderCompileException.
      final noopScript = _writeExecutableScript(
        tmp,
        'noop_impellerc.sh',
        '#!/bin/sh\nexit 0\n',
      );
      final noOutput = ImpellercCompiler(
        impellercPathOverride: noopScript,
        cacheDirectoryPath: '${tmp.path}/cache2',
      );
      await expectLater(
        noOutput.compile(BuiltinShaders.scanlineOverlayGlsl, shaderId: 'no'),
        throwsA(
          isA<ShaderCompileException>().having(
            (e) => e.message,
            'message',
            contains('no .shaderbundle output'),
          ),
        ),
      );

      // 3. Exits 0 with bogus bytes -> ShaderCompileException.
      final bogusScript = _writeExecutableScript(
        tmp,
        'bogus_impellerc.sh',
        '#!/bin/sh\n'
            'for arg in "\$@"; do\n'
            '  case "\$arg" in\n'
            '    --sl=*) printf "NOT_A_VALID_BUNDLE" > "\${arg#--sl=}" ;;\n'
            '  esac\n'
            'done\n'
            'exit 0\n',
      );
      final badMagic = ImpellercCompiler(
        impellercPathOverride: bogusScript,
        cacheDirectoryPath: '${tmp.path}/cache3',
      );
      await expectLater(
        badMagic.compile(BuiltinShaders.scanlineOverlayGlsl, shaderId: 'bm'),
        throwsA(
          isA<ShaderCompileException>().having(
            (e) => e.message,
            'message',
            contains('IPSB FlatBuffer'),
          ),
        ),
      );
    }, skip: Platform.isWindows ? 'POSIX shell script test' : false);
  });

  group('impellerc_compiler_stub contract', () {
    test('reports unavailable and throws ShaderCompileException', () async {
      final stubCompiler = stub.ImpellercCompiler();
      expect(stubCompiler.isAvailable, isFalse);
      expect(stubCompiler.resolveImpellercPath(), isNull);
      expect(stubCompiler.resolveCacheDirectoryPath(), isNull);
      expect(
        stub.ImpellercCompiler.parseErrorLineNumber(
          'TerminalShaderFragment:4:',
        ),
        isNull,
      );
      const paritySource = 'void mainImage() {\n  fragColor = badVar;\n}\n';
      const parityLog =
          "TerminalShaderFragment:12: error: 'badVar' : undeclared identifier\n";
      expect(
        stub.ImpellercCompiler.parseDiagnostics(
          parityLog,
          userSource: paritySource,
          shimPrefixLineCount: 10,
        ),
        equals(
          ImpellercCompiler.parseDiagnostics(
            parityLog,
            userSource: paritySource,
            shimPrefixLineCount: 10,
          ),
        ),
      );
      expect(stub.ImpellercCompiler.formatCompilerError(' err '), 'err');
      expect(
        stub.ImpellercCompiler.bundledHelperCandidatesFor(
          '/app/fterm',
          operatingSystem: 'linux',
        ),
        isEmpty,
      );
      expect(
        stub.ImpellercCompiler.defaultCacheDirectoryFor(
          const <String, String>{},
          operatingSystem: 'linux',
        ),
        isNull,
      );
      expect(
        () => stub.ImpellercCompiler.sha256Hex('abc'),
        throwsA(isA<ShaderCompileException>()),
      );
      final valid = Uint8List(16)
        ..[4] = 0x49
        ..[5] = 0x50
        ..[6] = 0x53
        ..[7] = 0x42;
      expect(stub.ImpellercCompiler.isValidShaderBundleBytes(valid), isTrue);

      await expectLater(
        stubCompiler.compile(
          BuiltinShaders.scanlineOverlayGlsl,
          shaderId: 's1',
        ),
        throwsA(
          isA<ShaderCompileException>().having((e) => e.shaderId, 'id', 's1'),
        ),
      );
      await expectLater(
        stubCompiler.compileRawBundle(
          vertexGlsl: '',
          fragmentGlsl: '',
          shaderId: 's2',
        ),
        throwsA(
          isA<ShaderCompileException>().having((e) => e.shaderId, 'id', 's2'),
        ),
      );

      final bundle = stub.CompiledShaderBundle(
        bytes: ByteData(16),
        analysis: ShadertoyGlslShim.analyze(BuiltinShaders.scanlineOverlayGlsl),
        cacheKey: 'k',
        fromCache: false,
      );
      expect(bundle.cacheKey, 'k');
      expect(bundle.fromCache, isFalse);
    });
  });

  group('FlutterGpuShaderBackend and pure GPU helpers', () {
    test(
      'tryCreate safely returns null under flutter test software rendering',
      () {
        expect(FlutterGpuShaderBackend.tryCreate(), isNull);
      },
    );

    test('alignUniformByteSize and packAlignedUniformBatch obey alignment', () {
      expect(alignUniformByteSize(0, 256), 0);
      expect(alignUniformByteSize(4416, 1), 4416);
      expect(alignUniformByteSize(4416, 0), 4416);
      expect(alignUniformByteSize(4416, 64), 4416);
      expect(alignUniformByteSize(4416, 256), 4608);
      expect(alignUniformByteSize(4416, 512), 4608);

      final u0 = TerminalShaderUniforms(
        width: 800,
        height: 600,
        timeSeconds: 1.5,
      );
      final u1 = TerminalShaderUniforms(
        width: 1280,
        height: 720,
        timeSeconds: 3.25,
      );
      final batch = packAlignedUniformBatch(<TerminalShaderUniforms>[
        u0,
        u1,
      ], minimumUniformByteAlignment: 256);
      expect(batch.alignedStride, 4608);
      expect(batch.data.lengthInBytes, 4608 * 2);
      expect(batch.data.getFloat32(0, Endian.little), closeTo(800.0, 1e-5));
      expect(batch.data.getFloat32(12, Endian.little), closeTo(1.5, 1e-5));
      expect(batch.data.getFloat32(4608, Endian.little), closeTo(1280.0, 1e-5));
      expect(
        batch.data.getFloat32(4608 + 12, Endian.little),
        closeTo(3.25, 1e-5),
      );
    });

    test('GpuReflectionBindingCache skips stripped uniforms and memoizes stripped samplers', () {
      final cache = GpuReflectionBindingCache();

      // Stripped uniform block returns null.
      expect(
        cache.resolveUniformBindLength(null, maxLengthInBytes: 4608),
        isNull,
      );
      expect(cache.resolveUniformBindLength(0, maxLengthInBytes: 4608), isNull);
      expect(
        cache.resolveUniformBindLength(4416, maxLengthInBytes: 4608),
        4416,
      );
      expect(
        cache.resolveUniformBindLength(5000, maxLengthInBytes: 4608),
        4608,
      );

      // Present sampler binds cleanly.
      var bindCalls = 0;
      expect(cache.tryBindSampler('iChannel0', () => bindCalls++), isTrue);
      expect(bindCalls, 1);

      // Stripped sampler catches missing-texture exception once, then skips.
      var strippedAttempts = 0;
      expect(
        cache.tryBindSampler('iChannel1', () {
          strippedAttempts++;
          throw Exception(
            "Failed to bind texture (no texture named 'iChannel1')",
          );
        }),
        isFalse,
      );
      expect(strippedAttempts, 1);
      expect(cache.strippedSamplers, contains('iChannel1'));

      // Subsequent calls skip without invoking bind.
      expect(
        cache.tryBindSampler('iChannel1', () => strippedAttempts++),
        isFalse,
      );
      expect(strippedAttempts, 1);

      // Non-reflection exceptions are rethrown rather than swallowed.
      expect(
        () => cache.tryBindSampler('iPrevFrame', () {
          throw Exception('Device lost');
        }),
        throwsException,
      );

      // Reload invalidation clears memoized stripped samplers.
      cache.invalidate();
      expect(cache.strippedSamplers, isEmpty);
      expect(
        cache.tryBindSampler('iChannel1', () => strippedAttempts++),
        isTrue,
      );
      expect(strippedAttempts, 2);
    });

    test('GpuPingPongRegistry alternates read/write pairs, resets on resize, and bounds LRU size', () {
      final registry = GpuPingPongRegistry<String>(maxEntries: 2);
      var allocId = 0;
      String alloc(int w, int h) => 'tex_${++allocId}_${w}x$h';

      // Key resolution falls back to handle.id when prevFrameKey is null.
      final handle = const _FakeHandle('phosphor', usesPrevFrame: true);
      final uniforms = TerminalShaderUniforms(width: 640, height: 480);
      expect(
        resolvePrevFrameKey((
          handle: handle,
          uniforms: uniforms,
          prevFrameKey: null,
        )),
        'phosphor',
      );
      expect(
        resolvePrevFrameKey((
          handle: handle,
          uniforms: uniforms,
          prevFrameKey: 'region_42',
        )),
        'region_42',
      );

      // Frame 0: readTexture is null to avoid reading uninitialized VRAM.
      final slot = registry.acquire('phosphor', 640, 480, alloc);
      expect(slot.hasHistory, isFalse);
      expect(slot.readTexture, isNull);
      final firstWrite = slot.writeTexture;
      slot.commitWriteAndSwap();

      // Frame 1: readTexture is Frame 0's writeTexture; writeTexture alternates.
      final sameSlot = registry.acquire('phosphor', 640, 480, alloc);
      expect(identical(sameSlot, slot), isTrue);
      expect(sameSlot.hasHistory, isTrue);
      expect(sameSlot.readTexture, firstWrite);
      final secondWrite = sameSlot.writeTexture;
      expect(secondWrite, isNot(firstWrite));
      sameSlot.commitWriteAndSwap();
      expect(sameSlot.readTexture, secondWrite);
      expect(sameSlot.writeTexture, firstWrite);

      // Resize reallocates fresh textures and resets history.
      final resized = registry.acquire('phosphor', 800, 600, alloc);
      expect(resized.hasHistory, isFalse);
      expect(resized.readTexture, isNull);
      expect(resized.width, 800);
      expect(resized.height, 600);

      // LRU bound evicts oldest key when exceeding maxEntries.
      registry.acquire('region_a', 100, 100, alloc);
      expect(registry.length, 2);
      registry.acquire('region_b', 100, 100, alloc);
      expect(registry.length, 2);

      registry.remove('region_a');
      expect(registry.length, 1);
      registry.clear();
      expect(registry.length, 0);
    });

    test('GpuSizePool caches by dimensions and evicts LRU entries', () {
      final pool = GpuSizePool<String>(maxEntries: 2);
      var count = 0;
      String create(int w, int h) => 'surface_${++count}_${w}x$h';

      final s1 = pool.obtain(800, 600, create);
      final s1Again = pool.obtain(800, 600, create);
      expect(s1Again, s1);
      expect(count, 1);

      final s2 = pool.obtain(1024, 768, create);
      expect(s2, isNot(s1));
      // Touch s1 so s2 becomes least recently used.
      expect(pool.obtain(800, 600, create), s1);
      // Adding a third size evicts s2.
      final s3 = pool.obtain(1280, 720, create);
      expect(s3, isNot(s1));
      expect(pool.length, 2);

      // Re-obtaining 1024x768 must allocate a new entry because s2 was evicted.
      final s2New = pool.obtain(1024, 768, create);
      expect(s2New, isNot(s2));

      pool.remove(1024, 768);
      expect(pool.length, 1);
      pool.clear();
      expect(pool.length, 0);

      expect(
        const GpuTextureSizeKey(10, 20),
        equals(const GpuTextureSizeKey(10, 20)),
      );
      expect(
        const GpuTextureSizeKey(10, 20).hashCode,
        equals(const GpuTextureSizeKey(10, 20).hashCode),
      );
    });

    test('executeSingleEncoderGpuPassChain isolates render and blit encoders across command buffers', () {
      const surfaceTex = 'surface_color';

      // 1. Single pass rendering directly to finalSurfaceTexture uses 1 CB.
      final singleDirectBuffers = <_StrictMetalCommandBuffer>[];
      final singleDirectFinal =
          executeSingleEncoderGpuPassChain<_StrictMetalCommandBuffer, String>(
            passCount: 1,
            finalSurfaceTexture: surfaceTex,
            createCommandBuffer: () {
              final cb = _StrictMetalCommandBuffer(singleDirectBuffers.length);
              singleDirectBuffers.add(cb);
              return cb;
            },
            encodeRenderPass: (i, cb) {
              cb.encodeRenderPass(surfaceTex);
              return surfaceTex;
            },
            submitIntermediate: (cb) => cb.submit(),
            encodeCopyToSurface: (cb, src, dst) => cb.encodeBlitCopy(src, dst),
          );
      expect(singleDirectBuffers, hasLength(1));
      expect(identical(singleDirectFinal, singleDirectBuffers.single), isTrue);
      expect(singleDirectFinal.submitted, isFalse);
      expect(singleDirectFinal.ops, <String>['render:surface_color']);

      // 2. Single ping-pong pass (usesPrevFrame) submits render CB before
      // opening a fresh CB for the trailing texture-to-texture blit copy.
      final singlePingPongBuffers = <_StrictMetalCommandBuffer>[];
      final singlePingPongFinal =
          executeSingleEncoderGpuPassChain<_StrictMetalCommandBuffer, String>(
            passCount: 1,
            finalSurfaceTexture: surfaceTex,
            createCommandBuffer: () {
              final cb = _StrictMetalCommandBuffer(
                singlePingPongBuffers.length,
              );
              singlePingPongBuffers.add(cb);
              return cb;
            },
            encodeRenderPass: (i, cb) {
              cb.encodeRenderPass('ping_pong_write');
              return 'ping_pong_write';
            },
            submitIntermediate: (cb) => cb.submit(),
            encodeCopyToSurface: (cb, src, dst) => cb.encodeBlitCopy(src, dst),
          );
      expect(singlePingPongBuffers, hasLength(2));
      expect(singlePingPongBuffers[0].submitted, isTrue);
      expect(singlePingPongBuffers[0].ops, <String>['render:ping_pong_write']);
      expect(identical(singlePingPongFinal, singlePingPongBuffers[1]), isTrue);
      expect(singlePingPongFinal.submitted, isFalse);
      expect(singlePingPongFinal.ops, <String>[
        'blit:ping_pong_write->surface_color',
      ]);

      // 3. Multi-pass chain ending on surface submits pass 0 and returns
      // pass 1's CB unsubmitted for surfaceFrame.present().
      final multiDirectBuffers = <_StrictMetalCommandBuffer>[];
      final multiDirectFinal =
          executeSingleEncoderGpuPassChain<_StrictMetalCommandBuffer, String>(
            passCount: 2,
            finalSurfaceTexture: surfaceTex,
            createCommandBuffer: () {
              final cb = _StrictMetalCommandBuffer(multiDirectBuffers.length);
              multiDirectBuffers.add(cb);
              return cb;
            },
            encodeRenderPass: (i, cb) {
              final target = i == 0 ? 'scratch_0' : surfaceTex;
              cb.encodeRenderPass(target);
              return target;
            },
            submitIntermediate: (cb) => cb.submit(),
            encodeCopyToSurface: (cb, src, dst) => cb.encodeBlitCopy(src, dst),
          );
      expect(multiDirectBuffers, hasLength(2));
      expect(multiDirectBuffers[0].submitted, isTrue);
      expect(multiDirectBuffers[0].ops, <String>['render:scratch_0']);
      expect(identical(multiDirectFinal, multiDirectBuffers[1]), isTrue);
      expect(multiDirectFinal.submitted, isFalse);
      expect(multiDirectFinal.ops, <String>['render:surface_color']);

      // 4. Multi-pass chain ending on a ping-pong texture uses 3 CBs:
      // pass 0 (submitted), pass 1 (submitted), final blit (unsubmitted).
      final multiPingPongBuffers = <_StrictMetalCommandBuffer>[];
      final multiPingPongFinal =
          executeSingleEncoderGpuPassChain<_StrictMetalCommandBuffer, String>(
            passCount: 2,
            finalSurfaceTexture: surfaceTex,
            createCommandBuffer: () {
              final cb = _StrictMetalCommandBuffer(multiPingPongBuffers.length);
              multiPingPongBuffers.add(cb);
              return cb;
            },
            encodeRenderPass: (i, cb) {
              final target = i == 0 ? 'scratch_0' : 'ping_pong_1';
              cb.encodeRenderPass(target);
              return target;
            },
            submitIntermediate: (cb) => cb.submit(),
            encodeCopyToSurface: (cb, src, dst) => cb.encodeBlitCopy(src, dst),
          );
      expect(multiPingPongBuffers, hasLength(3));
      expect(multiPingPongBuffers[0].submitted, isTrue);
      expect(multiPingPongBuffers[0].ops, <String>['render:scratch_0']);
      expect(multiPingPongBuffers[1].submitted, isTrue);
      expect(multiPingPongBuffers[1].ops, <String>['render:ping_pong_1']);
      expect(identical(multiPingPongFinal, multiPingPongBuffers[2]), isTrue);
      expect(multiPingPongFinal.submitted, isFalse);
      expect(multiPingPongFinal.ops, <String>[
        'blit:ping_pong_1->surface_color',
      ]);

      // 5. Rejects non-positive passCount.
      expect(
        () =>
            executeSingleEncoderGpuPassChain<_StrictMetalCommandBuffer, String>(
              passCount: 0,
              finalSurfaceTexture: surfaceTex,
              createCommandBuffer: () => _StrictMetalCommandBuffer(0),
              encodeRenderPass: (i, cb) => surfaceTex,
              submitIntermediate: (cb) => cb.submit(),
              encodeCopyToSurface: (cb, src, dst) {},
            ),
        throwsRangeError,
      );
    });

    test('KittyTextureUploadCache uploads raw RGBA synchronously, evicts replaced slots, and enforces LRU capacity', () async {
      TestWidgetsFlutterBinding.ensureInitialized();

      Future<ui.Image> makeImage(int w, int h, int seed) {
        final pixels = Uint8List(w * h * 4);
        for (var i = 0; i < pixels.length; i += 4) {
          pixels[i] = seed & 0xFF;
          pixels[i + 1] = 100;
          pixels[i + 2] = 200;
          pixels[i + 3] = 255;
        }
        final c = Completer<ui.Image>();
        ui.decodeImageFromPixels(
          pixels,
          w,
          h,
          ui.PixelFormat.rgba8888,
          c.complete,
        );
        return c.future;
      }

      GpuKittyQuad makeQuad(
        ui.Image image, {
        Uint8List? rawRgbaPixels,
        Object? cacheSlot,
      }) => GpuKittyQuad(
        image: image,
        rawRgbaPixels: rawRgbaPixels,
        cacheSlot: cacheSlot,
        dstX: 0,
        dstY: 0,
        dstWidth: image.width.toDouble(),
        dstHeight: image.height.toDouble(),
        u0: 0,
        v0: 0,
        u1: 1,
        v1: 1,
      );

      final img1 = await makeImage(2, 2, 10);
      final img2 = await makeImage(2, 2, 20);
      final img3 = await makeImage(2, 2, 30);
      final img4 = await makeImage(2, 2, 40);
      addTearDown(() {
        img1.dispose();
        img2.dispose();
        img3.dispose();
        img4.dispose();
      });

      // Rejects non-positive initialCapacity with RangeError.
      expect(
        () => KittyTextureUploadCache<String>(initialCapacity: 0),
        throwsRangeError,
      );
      expect(
        () => KittyTextureUploadCache<String>(initialCapacity: -1),
        throwsRangeError,
      );

      final cache = KittyTextureUploadCache<String>(initialCapacity: 2);
      var uploadCount = 0;
      String? upload(int w, int h, ByteData bytes) {
        uploadCount++;
        return 'tex_${uploadCount}_${w}x${h}_${bytes.lengthInBytes}';
      }

      // Empty quad list resolves immediately without uploading.
      expect(
        cache.resolveQuads(const <GpuKittyQuad>[], uploadRawRgba: upload),
        isEmpty,
      );

      // Cache miss with valid RGBA32 buffer uploads synchronously and caches.
      final raw1 = Uint8List.fromList(List<int>.filled(16, 11));
      final first = cache.resolveQuads(<GpuKittyQuad>[
        makeQuad(img1, rawRgbaPixels: raw1, cacheSlot: ('reg', 1)),
      ], uploadRawRgba: upload);
      expect(first, equals(<String>['tex_1_2x2_16']));
      expect(cache.length, equals(1));
      expect(cache.contains(img1), isTrue);

      // Cache hit reuses texture without re-uploading.
      final hit = cache.resolveQuads(<GpuKittyQuad>[
        makeQuad(img1, rawRgbaPixels: raw1, cacheSlot: ('reg', 1)),
      ], uploadRawRgba: upload);
      expect(hit, equals(<String>['tex_1_2x2_16']));
      expect(uploadCount, equals(1));

      // Replacing the same cacheSlot evicts the superseded image immediately.
      final raw2 = Uint8List.fromList(List<int>.filled(16, 22));
      final replaced = cache.resolveQuads(<GpuKittyQuad>[
        makeQuad(img2, rawRgbaPixels: raw2, cacheSlot: ('reg', 1)),
      ], uploadRawRgba: upload);
      expect(replaced, equals(<String>['tex_2_2x2_16']));
      expect(cache.length, equals(1));
      expect(cache.contains(img1), isFalse);
      expect(cache.contains(img2), isTrue);

      // Primed textures without an initial slot bind cacheSlot on cache hit
      // so replacing that slot later evicts the primed texture.
      cache.store(img3, 'primed_png_v1');
      expect(
        cache.resolveQuads(<GpuKittyQuad>[
          makeQuad(img3, cacheSlot: ('reg', 99)),
        ], uploadRawRgba: upload),
        equals(<String>['primed_png_v1']),
      );
      cache.store(img4, 'primed_png_v2');
      expect(
        cache.resolveQuads(<GpuKittyQuad>[
          makeQuad(img4, cacheSlot: ('reg', 99)),
        ], uploadRawRgba: upload),
        equals(<String>['primed_png_v2']),
      );
      expect(cache.contains(img3), isFalse);
      expect(cache.contains(img4), isTrue);

      // Distinct slots beyond initialCapacity evict oldest LRU entry.
      cache.clear();
      cache.store(img2, 'manual_2', cacheSlot: ('reg', 1));
      cache.store(img3, 'manual_3', cacheSlot: ('reg', 2));
      expect(cache.length, equals(2));
      expect(
        cache.resolveQuads(<GpuKittyQuad>[
          makeQuad(img2, cacheSlot: ('reg', 1)),
        ], uploadRawRgba: upload),
        equals(<String>['manual_2']),
      );
      cache.store(img4, 'manual_4', cacheSlot: ('reg', 3));
      expect(cache.length, equals(2));
      expect(cache.contains(img3), isFalse);
      expect(cache.contains(img2), isTrue);
      expect(cache.contains(img4), isTrue);

      // Unuploadable misses do not prematurely inflate capacity.
      cache.clear();
      expect(cache.length, equals(0));
      expect(cache.capacity, equals(2));
      expect(
        cache.resolveQuads(<GpuKittyQuad>[
          makeQuad(img1),
          makeQuad(img2),
          makeQuad(img3),
        ], uploadRawRgba: upload),
        isNull,
      );
      expect(cache.capacity, equals(2));

      // Single frame referencing more distinct images than capacity expands it.
      final raw3 = Uint8List.fromList(List<int>.filled(16, 33));
      final raw4 = Uint8List.fromList(List<int>.filled(16, 44));
      final expanded = cache.resolveQuads(<GpuKittyQuad>[
        makeQuad(img1, rawRgbaPixels: raw1, cacheSlot: ('reg', 10)),
        makeQuad(img3, rawRgbaPixels: raw3, cacheSlot: ('reg', 11)),
        makeQuad(img4, rawRgbaPixels: raw4, cacheSlot: ('reg', 12)),
      ], uploadRawRgba: upload);
      expect(expanded, hasLength(3));
      expect(cache.capacity, equals(3));

      // Short buffer or failed upload returns null.
      cache.clear();
      expect(
        cache.resolveQuads(<GpuKittyQuad>[
          makeQuad(img1, rawRgbaPixels: Uint8List(4)),
        ], uploadRawRgba: upload),
        isNull,
      );
      expect(
        cache.resolveQuads(<GpuKittyQuad>[
          makeQuad(img1, rawRgbaPixels: raw1),
        ], uploadRawRgba: (_, _, _) => null),
        isNull,
      );
    });
  });
}
