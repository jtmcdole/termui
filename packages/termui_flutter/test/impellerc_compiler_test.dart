import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:flutter_test/flutter_test.dart';
import 'package:termui_flutter/src/rendering/builtin_shaders.dart';
import 'package:termui_flutter/src/rendering/gpu_atlas_shaders.dart';
import 'package:termui_flutter/src/rendering/impellerc_compiler_io.dart';
import 'package:termui_flutter/src/rendering/impellerc_compiler_stub.dart'
    as stub;
import 'package:termui_flutter/src/rendering/shader_backend.dart';
import 'package:termui_flutter/src/rendering/shader_backend_gpu.dart';
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
      final tmp = Directory.systemTemp.createTempSync('termui_resolve_test_');
      addTearDown(() => tmp.deleteSync(recursive: true));

      final exeName = Platform.isWindows ? 'impellerc.exe' : 'impellerc';
      final overrideFile = File(
        _joinPath(<String>[tmp.path, 'override_$exeName']),
      )..writeAsStringSync('override');
      final appDir = Directory(_joinPath(<String>[tmp.path, 'app']))
        ..createSync();
      final appExe = File(
        _joinPath(<String>[
          appDir.path,
          Platform.isWindows ? 'fterm.exe' : 'fterm',
        ]),
      )..writeAsStringSync('app');
      final bundledFile =
          File(_joinPath(<String>[appDir.path, 'helpers', exeName]))
            ..parent.createSync(recursive: true)
            ..writeAsStringSync('bundled');
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
                ),
          ),
        );
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
  });
}
