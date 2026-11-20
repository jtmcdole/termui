import 'dart:typed_data';

import 'shader_backend.dart';
import 'shadertoy_glsl_shim.dart';

/// Result of compiling a Ghostty Shadertoy `.glsl` shader into an Impeller
/// `.shaderbundle` FlatBuffer payload.
final class CompiledShaderBundle {
  /// Compiled `.shaderbundle` FlatBuffer bytes ready for
  /// `gpu.ShaderLibrary.fromBytes`.
  final ByteData bytes;

  /// Static analysis report extracted from the user Shadertoy source.
  final ShadertoyGlslAnalysis analysis;

  /// Lowercase hexadecimal SHA-256 cache key for this compiled bundle.
  final String cacheKey;

  /// Whether [bytes] were served from the on-disk SHA-256 cache without
  /// spawning `impellerc`.
  final bool fromCache;

  /// Creates a compiled shader bundle result.
  const CompiledShaderBundle({
    required this.bytes,
    required this.analysis,
    required this.cacheKey,
    required this.fromCache,
  });
}

/// Stub `impellerc` compiler used on platforms without `dart:io` (such as
/// Flutter Web).
///
/// Mirrors the public API of `impellerc_compiler_io.dart` while reporting
/// unavailability and throwing [ShaderCompileException] if compilation is
/// attempted.
final class ImpellercCompiler {
  /// Default compilation timeout for local user shaders (`8 seconds`).
  static const Duration defaultTimeout = Duration(seconds: 8);

  /// Four-byte FlatBuffer identifier at byte offset `4` of valid Impeller
  /// shader bundles (`IPSB`).
  static const String bundleMagic = 'IPSB';

  /// Default local Flutter SDK roots probed when no override or environment
  /// variable resolves `impellerc`.
  static const List<String> defaultFallbackSdkRoots = <String>[
    '/srv/opt/flutter/stable',
  ];

  /// Explicit path override for the `impellerc` binary.
  final String? impellercPathOverride;

  /// Explicit directory override for the on-disk `.shaderbundle` cache.
  final String? cacheDirectoryPath;

  /// Maximum duration allowed for each `impellerc` subprocess invocation.
  final Duration timeout;

  /// Creates a stub `impellerc` compiler instance.
  ImpellercCompiler({
    this.impellercPathOverride,
    this.cacheDirectoryPath,
    this.timeout = defaultTimeout,
    Map<String, String>? environment,
    String? resolvedExecutablePath,
    List<String> fallbackSdkRoots = defaultFallbackSdkRoots,
  });

  /// Always returns `false` on platforms without `dart:io`.
  bool get isAvailable => false;

  /// Always returns `null` on platforms without `dart:io`.
  String? resolveImpellercPath() => null;

  /// Always returns `null` on platforms without `dart:io`.
  String? resolveCacheDirectoryPath() => null;

  /// Always throws [ShaderCompileException] on platforms without `dart:io`.
  Future<CompiledShaderBundle> compile(
    String shadertoyGlsl, {
    String shaderId = '<inline>',
    Duration? timeoutOverride,
  }) => Future<CompiledShaderBundle>.error(
    ShaderCompileException(
      shaderId: shaderId,
      message: 'impellerc is unavailable on this platform.',
    ),
  );

  /// Always throws [ShaderCompileException] on platforms without `dart:io`.
  Future<ByteData> compileRawBundle({
    required String vertexGlsl,
    required String fragmentGlsl,
    String shaderId = '<inline>',
    int shimPrefixLineCount = 0,
    int? userLineCount,
    Duration? timeoutOverride,
    bool useCache = true,
  }) => Future<ByteData>.error(
    ShaderCompileException(
      shaderId: shaderId,
      message: 'impellerc is unavailable on this platform.',
    ),
  );

  /// Validates that [bytes] is a non-empty Impeller shader bundle carrying the
  /// 4-byte `IPSB` FlatBuffer identifier at byte offset `4`.
  static bool isValidShaderBundleBytes(Uint8List bytes) =>
      bytes.length >= 16 &&
      bytes[4] == 0x49 &&
      bytes[5] == 0x50 &&
      bytes[6] == 0x53 &&
      bytes[7] == 0x42;

  /// Always returns `null` on stub platforms.
  static int? parseErrorLineNumber(
    String stderr, {
    int shimPrefixLineCount = 0,
    int? userLineCount,
  }) => null;

  /// Returns a trimmed fallback message from [stderr].
  static String formatCompilerError(String stderr) => stderr.trim();

  /// Unsupported on stub platforms; throws [ShaderCompileException].
  static String sha256Hex(String input) => throw const ShaderCompileException(
    shaderId: '<sha256>',
    message: 'impellerc disk cache hashing is unavailable on this platform.',
  );

  /// Returns bundled `impellerc` helper candidates relative to
  /// [executablePath] for [operatingSystem].
  static List<String> bundledHelperCandidatesFor(
    String executablePath, {
    required String operatingSystem,
  }) => const <String>[];

  /// Returns the default on-disk shader cache directory for [operatingSystem]
  /// using [environment], or `null` if unavailable.
  static String? defaultCacheDirectoryFor(
    Map<String, String> environment, {
    required String operatingSystem,
  }) => null;
}
