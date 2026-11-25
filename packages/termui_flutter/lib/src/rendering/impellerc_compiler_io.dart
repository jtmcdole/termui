import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'shader_backend.dart';
import 'shader_diagnostic_parser.dart';
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

/// Out-of-process Impeller shader bundle compiler backed by `impellerc`.
///
/// Wraps Ghostty Shadertoy GLSL via [ShadertoyGlslShim], compiles vertex and
/// fragment stages with `impellerc --shader-bundle='<inline-json>'`, enforces a
/// subprocess timeout, and caches `.shaderbundle` bytes on disk by SHA-256.
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

  static const String _cacheSchemaVersion = 'v2';

  static int _atomicWriteCounter = 0;

  static final RegExp _fragmentLinePattern = RegExp(
    r'TerminalShaderFragment:(\d+):',
  );
  static final RegExp _glslangErrorPattern = RegExp(
    r'\bERROR:\s*\d+:(\d+):',
    caseSensitive: false,
  );
  static final RegExp _genericFileLinePattern = RegExp(
    r'(?:\.glsl|TerminalShaderVertex):(\d+):',
  );
  static final RegExp _errorDetailPattern = RegExp(
    r'(?:^|\s)error:\s*(.+)$',
    caseSensitive: false,
  );

  /// Explicit path override for the `impellerc` binary.
  final String? impellercPathOverride;

  /// Explicit directory override for the on-disk `.shaderbundle` cache.
  final String? cacheDirectoryPath;

  /// Maximum duration allowed for each `impellerc` subprocess invocation.
  final Duration timeout;

  final Map<String, String> _environment;
  final String _resolvedExecutablePath;
  final List<String> _fallbackSdkRoots;
  bool _impellercPathResolved = false;
  String? _cachedImpellercPath;

  /// Creates an `impellerc` compiler instance.
  ///
  /// Resolution priority for `impellerc`:
  /// 1. [impellercPathOverride]
  /// 2. Bundled helper relative to [resolvedExecutablePath] (defaults to
  ///    `Platform.resolvedExecutable`)
  /// 3. `FTERM_IMPELLERC_PATH` in [environment] (defaults to
  ///    `Platform.environment`)
  /// 4. Local Flutter SDK cache (`FLUTTER_ROOT`, `flutter` on `PATH`, or
  ///    [fallbackSdkRoots])
  ImpellercCompiler({
    this.impellercPathOverride,
    this.cacheDirectoryPath,
    this.timeout = defaultTimeout,
    Map<String, String>? environment,
    String? resolvedExecutablePath,
    List<String> fallbackSdkRoots = defaultFallbackSdkRoots,
  }) : _environment = environment ?? Platform.environment,
       _resolvedExecutablePath =
           resolvedExecutablePath ?? Platform.resolvedExecutable,
       _fallbackSdkRoots = List<String>.unmodifiable(fallbackSdkRoots);

  /// Whether an `impellerc` executable can currently be resolved.
  bool get isAvailable => resolveImpellercPath() != null;

  /// Resolves the path to the `impellerc` binary, or returns `null` if none is
  /// found.
  ///
  /// Both resolved paths and misses (`null`) are memoized on this instance so
  /// hot render loops avoid repeated synchronous filesystem probes.
  String? resolveImpellercPath() {
    if (_impellercPathResolved) return _cachedImpellercPath;
    _cachedImpellercPath = _resolveImpellercPathUncached();
    _impellercPathResolved = true;
    return _cachedImpellercPath;
  }

  /// Clears the memoized `impellerc` binary resolution cache.
  @visibleForTesting
  void resetCache() {
    _impellercPathResolved = false;
    _cachedImpellercPath = null;
  }

  String? _resolveImpellercPathUncached() {
    final override = _existingFilePath(impellercPathOverride);
    if (override != null) return override;

    final bundled = _resolveBundledHelper();
    if (bundled != null) return bundled;

    final envPath = _existingFilePath(_environment['FTERM_IMPELLERC_PATH']);
    if (envPath != null) return envPath;

    return _resolveSdkImpellerc();
  }

  /// Resolves the on-disk `.shaderbundle` cache directory, or returns `null`
  /// when no cache root is available in the environment.
  String? resolveCacheDirectoryPath() {
    final override = cacheDirectoryPath?.trim();
    if (override != null && override.isNotEmpty) {
      return override;
    }
    return defaultCacheDirectoryFor(
      _environment,
      operatingSystem: Platform.operatingSystem,
    );
  }

  /// Compiles [shadertoyGlsl] into a `.shaderbundle` [CompiledShaderBundle].
  ///
  /// Validates and shims [shadertoyGlsl] via [ShadertoyGlslShim.shim], checks
  /// the SHA-256 on-disk cache, and invokes `impellerc` on a cache miss.
  /// Throws [ShaderCompileException] on validation failure, missing binary,
  /// timeout, or GLSL compilation errors.
  Future<CompiledShaderBundle> compile(
    String shadertoyGlsl, {
    String shaderId = '<inline>',
    Duration? timeoutOverride,
  }) async {
    final shimmed = ShadertoyGlslShim.shim(shadertoyGlsl, shaderId: shaderId);
    final normalizedUser = shadertoyGlsl
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    final prefixLines = _computeShimPrefixLineCount(
      shimmed.impellerFragmentGlsl,
      normalizedUser,
    );
    final userLines = '\n'.allMatches(normalizedUser).length + 1;

    final result = await _compileInternal(
      vertexGlsl: shimmed.impellerVertexGlsl,
      fragmentGlsl: shimmed.impellerFragmentGlsl,
      shaderId: shaderId,
      userSource: normalizedUser,
      shimPrefixLineCount: prefixLines,
      userLineCount: userLines,
      timeoutOverride: timeoutOverride,
      useCache: true,
    );
    return CompiledShaderBundle(
      bytes: result.bytes,
      analysis: shimmed.analysis,
      cacheKey: result.cacheKey,
      fromCache: result.fromCache,
    );
  }

  /// Compiles raw Impeller GLSL 460 [vertexGlsl] and [fragmentGlsl] sources
  /// directly through `impellerc --shader-bundle='<inline-json>'` with an
  /// empty `--include` directory.
  Future<ByteData> compileRawBundle({
    required String vertexGlsl,
    required String fragmentGlsl,
    String vertexEntryName = ShadertoyGlslShim.vertexShaderName,
    String fragmentEntryName = ShadertoyGlslShim.fragmentShaderName,
    String shaderId = '<inline>',
    int shimPrefixLineCount = 0,
    int? userLineCount,
    Duration? timeoutOverride,
    bool useCache = true,
  }) async {
    final result = await _compileInternal(
      vertexGlsl: vertexGlsl,
      fragmentGlsl: fragmentGlsl,
      vertexEntryName: vertexEntryName,
      fragmentEntryName: fragmentEntryName,
      shaderId: shaderId,
      userSource: _sliceUserSource(
        fragmentGlsl,
        shimPrefixLineCount: shimPrefixLineCount,
        userLineCount: userLineCount,
      ),
      shimPrefixLineCount: shimPrefixLineCount,
      userLineCount: userLineCount,
      timeoutOverride: timeoutOverride,
      useCache: useCache,
    );
    return result.bytes;
  }

  static String _sliceUserSource(
    String fragmentGlsl, {
    required int shimPrefixLineCount,
    int? userLineCount,
  }) {
    if (shimPrefixLineCount <= 0 && userLineCount == null) return fragmentGlsl;
    final lines = fragmentGlsl.split('\n');
    final start = shimPrefixLineCount.clamp(0, lines.length);
    final end = userLineCount != null
        ? (start + userLineCount).clamp(start, lines.length)
        : lines.length;
    return lines.sublist(start, end).join('\n');
  }

  /// Computes a lowercase 64-character hexadecimal SHA-256 digest of UTF-8
  /// [input].
  static String sha256Hex(String input) =>
      _Sha256.digestHex(Uint8List.fromList(utf8.encode(input)));

  /// Validates that [bytes] is a non-empty Impeller shader bundle FlatBuffer
  /// carrying the 4-byte `IPSB` identifier at byte offset `4`.
  static bool isValidShaderBundleBytes(Uint8List bytes) =>
      bytes.length >= 16 &&
      bytes[4] == 0x49 &&
      bytes[5] == 0x50 &&
      bytes[6] == 0x53 &&
      bytes[7] == 0x42;

  /// Parses `impellerc` [stderr] into span-annotated [ShaderDiagnostic] entries
  /// mapped back to 1-based [userSource] coordinates.
  static List<ShaderDiagnostic> parseDiagnostics(
    String stderr, {
    String userSource = '',
    int shimPrefixLineCount = 0,
  }) => parseImpellercDiagnostics(
    stderr,
    userSource: userSource,
    shimPrefixLineCount: shimPrefixLineCount,
  );

  /// Parses a 1-based line number from `impellerc` [stderr], adjusting by
  /// [shimPrefixLineCount] when the error falls inside the user's
  /// [userLineCount]-line shader source.
  static int? parseErrorLineNumber(
    String stderr, {
    int shimPrefixLineCount = 0,
    int? userLineCount,
  }) {
    final rawLine = _extractRawLineNumber(stderr);
    if (rawLine == null) return null;
    if (shimPrefixLineCount <= 0) return rawLine;
    final adjusted = rawLine - shimPrefixLineCount;
    if (adjusted < 1) return rawLine;
    if (userLineCount != null && adjusted > userLineCount) return rawLine;
    return adjusted;
  }

  /// Extracts a concise human-readable diagnostic message from `impellerc`
  /// [stderr].
  static String formatCompilerError(String stderr) {
    final lines = stderr
        .replaceAll('\r\n', '\n')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (lines.isEmpty) {
      return 'impellerc failed without diagnostic output.';
    }
    for (final line in lines) {
      final match = _errorDetailPattern.firstMatch(line);
      if (match != null) {
        final detail = match.group(1)?.trim();
        if (detail != null && detail.isNotEmpty) {
          return detail;
        }
      }
    }
    return lines.first;
  }

  /// Returns candidate bundled `impellerc` helper paths relative to
  /// [executablePath] for [operatingSystem].
  static List<String> bundledHelperCandidatesFor(
    String executablePath, {
    required String operatingSystem,
  }) {
    if (executablePath.isEmpty) return const <String>[];
    final sep = operatingSystem == 'windows' ? '\\' : '/';
    final exeDir = _dirname(executablePath);
    if (exeDir.isEmpty) return const <String>[];
    if (operatingSystem == 'macos') {
      final contentsDir = _dirname(exeDir);
      return <String>[
        if (contentsDir.isNotEmpty)
          _joinSegments(<String>[contentsDir, 'Helpers', 'impellerc'], sep),
        _joinSegments(<String>[
          exeDir,
          'Contents',
          'Helpers',
          'impellerc',
        ], sep),
      ];
    }
    final exeName = operatingSystem == 'windows'
        ? 'impellerc.exe'
        : 'impellerc';
    return <String>[
      _joinSegments(<String>[exeDir, 'helpers', exeName], sep),
    ];
  }

  /// Returns the default on-disk shader cache directory for [operatingSystem]
  /// using [environment], or `null` if the required home/app-data variable is
  /// absent.
  static String? defaultCacheDirectoryFor(
    Map<String, String> environment, {
    required String operatingSystem,
  }) {
    if (operatingSystem == 'windows') {
      final localAppData = environment['LOCALAPPDATA']?.trim();
      if (localAppData == null || localAppData.isEmpty) return null;
      return _joinSegments(<String>[localAppData, 'fterm', 'shaders'], '\\');
    }
    final home = environment['HOME']?.trim();
    if (home == null || home.isEmpty) return null;
    return _joinSegments(<String>[home, '.cache', 'fterm', 'shaders'], '/');
  }

  Future<({ByteData bytes, String cacheKey, bool fromCache})> _compileInternal({
    required String vertexGlsl,
    required String fragmentGlsl,
    String vertexEntryName = ShadertoyGlslShim.vertexShaderName,
    String fragmentEntryName = ShadertoyGlslShim.fragmentShaderName,
    required String shaderId,
    required String userSource,
    required int shimPrefixLineCount,
    required int? userLineCount,
    required Duration? timeoutOverride,
    required bool useCache,
  }) async {
    final impellercPath = resolveImpellercPath();
    if (impellercPath == null) {
      throw ShaderCompileException(
        shaderId: shaderId,
        message:
            'Could not locate impellerc binary. Set FTERM_IMPELLERC_PATH or '
            'ensure the Flutter SDK cache is available.',
      );
    }

    final identity = _compilerIdentity(impellercPath);
    final entryKey =
        vertexEntryName == ShadertoyGlslShim.vertexShaderName &&
            fragmentEntryName == ShadertoyGlslShim.fragmentShaderName
        ? ''
        : '$vertexEntryName:$fragmentEntryName\n';
    final cacheKey = sha256Hex(
      '$identity\n$entryKey$vertexGlsl\n$fragmentGlsl',
    );
    final cacheDir = useCache ? resolveCacheDirectoryPath() : null;

    if (cacheDir != null) {
      final cached = await _tryReadCache(cacheDir, cacheKey);
      if (cached != null) {
        return (bytes: cached, cacheKey: cacheKey, fromCache: true);
      }
    }

    final effectiveTimeout = timeoutOverride ?? timeout;
    final compiledBytes = await _invokeImpellerc(
      impellercPath: impellercPath,
      vertexGlsl: vertexGlsl,
      fragmentGlsl: fragmentGlsl,
      vertexEntryName: vertexEntryName,
      fragmentEntryName: fragmentEntryName,
      shaderId: shaderId,
      userSource: userSource,
      shimPrefixLineCount: shimPrefixLineCount,
      userLineCount: userLineCount,
      effectiveTimeout: effectiveTimeout,
    );

    if (cacheDir != null) {
      await _tryWriteCacheAtomically(cacheDir, cacheKey, compiledBytes);
    }
    return (
      bytes: ByteData.sublistView(compiledBytes),
      cacheKey: cacheKey,
      fromCache: false,
    );
  }

  Future<Uint8List> _invokeImpellerc({
    required String impellercPath,
    required String vertexGlsl,
    required String fragmentGlsl,
    required String vertexEntryName,
    required String fragmentEntryName,
    required String shaderId,
    required String userSource,
    required int shimPrefixLineCount,
    required int? userLineCount,
    required Duration effectiveTimeout,
  }) async {
    final tempDir = await Directory.systemTemp.createTemp('termui_impellerc_');
    try {
      final incDir = await Directory(_joinPath(tempDir.path, 'include'))
          .create();
      final vertFile = File(_joinPath(tempDir.path, 'vertex.glsl'));
      final fragFile = File(_joinPath(tempDir.path, 'fragment.glsl'));
      final outFile = File(_joinPath(tempDir.path, 'bundle.shaderbundle'));
      await vertFile.writeAsString(vertexGlsl);
      await fragFile.writeAsString(fragmentGlsl);

      final bundleSpec = jsonEncode(<String, Object?>{
        vertexEntryName: <String, Object?>{
          'type': 'vertex',
          'file': vertFile.path,
        },
        fragmentEntryName: <String, Object?>{
          'type': 'fragment',
          'file': fragFile.path,
        },
      });
      final args = <String>[
        '--shader-bundle=$bundleSpec',
        '--sl=${outFile.path}',
        '--include=${incDir.path}',
        '--gles-language-version=300',
        '--verbose',
      ];
      final result = await _runSubprocessWithTimeout(
        executable: impellercPath,
        arguments: args,
        shaderId: shaderId,
        timeout: effectiveTimeout,
      );
      if (result.exitCode != 0) {
        final combinedLog = _combineProcessOutput(result.stderr, result.stdout);
        final diagnostics = parseDiagnostics(
          combinedLog,
          userSource: userSource,
          shimPrefixLineCount: shimPrefixLineCount,
        );
        final firstError = firstErrorDiagnostic(diagnostics);
        throw ShaderCompileException(
          shaderId: shaderId,
          message: firstError?.message ?? formatCompilerError(combinedLog),
          lineNumber:
              firstError?.line ??
              parseErrorLineNumber(
                combinedLog,
                shimPrefixLineCount: shimPrefixLineCount,
                userLineCount: userLineCount,
              ),
          compilerLog: combinedLog,
          diagnostics: diagnostics,
        );
      }
      return await _readValidatedBundleFile(outFile, shaderId);
    } finally {
      await _safeDeleteDirectory(tempDir);
    }
  }

  Future<({int exitCode, String stdout, String stderr})>
  _runSubprocessWithTimeout({
    required String executable,
    required List<String> arguments,
    required String shaderId,
    required Duration timeout,
  }) async {
    final Process process;
    try {
      process = await Process.start(executable, arguments, runInShell: false);
    } on ProcessException catch (error) {
      resetCache();
      throw ShaderCompileException(
        shaderId: shaderId,
        message: 'Failed to launch impellerc: ${error.message}',
      );
    }
    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();
    final stdoutSub = process.stdout
        .transform(utf8.decoder)
        .listen(
          stdoutBuffer.write,
          onError: (Object _) {},
          onDone: () => _completeOnce(stdoutDone),
        );
    final stderrSub = process.stderr
        .transform(utf8.decoder)
        .listen(
          stderrBuffer.write,
          onError: (Object _) {},
          onDone: () => _completeOnce(stderrDone),
        );

    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      process.kill(ProcessSignal.sigkill);
    });

    final int exitCode;
    try {
      exitCode = await process.exitCode;
    } finally {
      timer.cancel();
    }
    if (timedOut) {
      unawaited(stdoutSub.cancel());
      unawaited(stderrSub.cancel());
      throw ShaderCompileException(
        shaderId: shaderId,
        message:
            'impellerc compilation timed out after '
            '${timeout.inMilliseconds} ms.',
        compilerLog: _combineProcessOutput(
          stderrBuffer.toString(),
          stdoutBuffer.toString(),
        ),
      );
    }
    await Future.wait<void>(<Future<void>>[
      stdoutDone.future,
      stderrDone.future,
    ]);
    return (
      exitCode: exitCode,
      stdout: stdoutBuffer.toString(),
      stderr: stderrBuffer.toString(),
    );
  }

  Future<Uint8List> _readValidatedBundleFile(
    File outFile,
    String shaderId,
  ) async {
    if (!await outFile.exists()) {
      throw ShaderCompileException(
        shaderId: shaderId,
        message: 'impellerc succeeded but produced no .shaderbundle output.',
      );
    }
    final bytes = await outFile.readAsBytes();
    if (!isValidShaderBundleBytes(bytes)) {
      throw ShaderCompileException(
        shaderId: shaderId,
        message:
            'impellerc output is not a valid IPSB FlatBuffer shader bundle '
            '(${bytes.length} bytes).',
      );
    }
    return bytes;
  }

  Future<ByteData?> _tryReadCache(String cacheDir, String cacheKey) async {
    final file = File(_joinPath(cacheDir, '$cacheKey.shaderbundle'));
    try {
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (!isValidShaderBundleBytes(bytes)) return null;
      return ByteData.sublistView(bytes);
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _tryWriteCacheAtomically(
    String cacheDir,
    String cacheKey,
    Uint8List bytes,
  ) async {
    final finalPath = _joinPath(cacheDir, '$cacheKey.shaderbundle');
    final seq = _atomicWriteCounter++;
    final tempFile = File(
      _joinPath(cacheDir, '.tmp_${cacheKey}_${pid}_$seq.shaderbundle'),
    );
    try {
      await Directory(cacheDir).create(recursive: true);
      await tempFile.writeAsBytes(bytes, flush: true);
      await tempFile.rename(finalPath);
    } on FileSystemException {
      await _safeDeleteFile(tempFile);
    }
  }

  String _compilerIdentity(String impellercPath) {
    final file = File(impellercPath);
    String canonicalPath = impellercPath;
    try {
      canonicalPath = file.resolveSymbolicLinksSync();
    } on FileSystemException {
      canonicalPath = impellercPath;
    }
    try {
      final stat = file.statSync();
      return '$_cacheSchemaVersion|$canonicalPath|${stat.size}|'
          '${stat.modified.millisecondsSinceEpoch}';
    } on FileSystemException {
      return '$_cacheSchemaVersion|$canonicalPath';
    }
  }

  String? _resolveBundledHelper() {
    final candidates = bundledHelperCandidatesFor(
      _resolvedExecutablePath,
      operatingSystem: Platform.operatingSystem,
    );
    for (final candidate in candidates) {
      final found = _existingFilePath(candidate);
      if (found != null) return found;
    }
    return null;
  }

  String? _resolveSdkImpellerc() {
    final roots = <String>[];
    final envFlutterRoot = _environment['FLUTTER_ROOT']?.trim();
    if (envFlutterRoot != null && envFlutterRoot.isNotEmpty) {
      roots.add(envFlutterRoot);
    }
    final pathFlutterRoot = _findFlutterRootOnPath();
    if (pathFlutterRoot != null) {
      roots.add(pathFlutterRoot);
    }
    roots.addAll(_fallbackSdkRoots);

    for (final root in roots) {
      final found = _findImpellercInSdkRoot(root);
      if (found != null) return found;
    }
    return null;
  }

  String? _findFlutterRootOnPath() {
    final pathEnv = _environment['PATH'];
    if (pathEnv == null || pathEnv.isEmpty) return null;
    final listSep = Platform.isWindows ? ';' : ':';
    final names = Platform.isWindows
        ? const <String>['flutter.bat', 'flutter.exe', 'flutter']
        : const <String>['flutter'];

    for (final rawDir in pathEnv.split(listSep)) {
      final dir = rawDir.trim();
      if (dir.isEmpty) continue;
      final root = _probeFlutterRootInDir(dir, names);
      if (root != null) return root;
    }
    return null;
  }

  String? _probeFlutterRootInDir(String dir, List<String> names) {
    for (final name in names) {
      final candidate = File(_joinPath(dir, name));
      if (!candidate.existsSync()) continue;
      final resolved = _safeResolveSymlinks(candidate);
      final binDir = File(resolved).parent;
      return binDir.parent.path;
    }
    return null;
  }

  String? _findImpellercInSdkRoot(String flutterRoot) {
    final exeName = Platform.isWindows ? 'impellerc.exe' : 'impellerc';
    for (final archDir in _engineArchDirs()) {
      final candidate = _joinSegments(<String>[
        flutterRoot,
        'bin',
        'cache',
        'artifacts',
        'engine',
        archDir,
        exeName,
      ], Platform.pathSeparator);
      final found = _existingFilePath(candidate);
      if (found != null) return found;
    }
    return null;
  }

  static List<String> _engineArchDirs() {
    final isArm64 = Platform.version.toLowerCase().contains('arm64');
    if (Platform.isMacOS) {
      return isArm64
          ? const <String>['darwin-arm64', 'darwin-x64']
          : const <String>['darwin-x64', 'darwin-arm64'];
    }
    if (Platform.isWindows) {
      return isArm64
          ? const <String>['windows-arm64', 'windows-x64']
          : const <String>['windows-x64', 'windows-arm64'];
    }
    return isArm64
        ? const <String>['linux-arm64', 'linux-x64']
        : const <String>['linux-x64', 'linux-arm64'];
  }

  static int _computeShimPrefixLineCount(
    String impellerFragmentGlsl,
    String normalizedUser,
  ) {
    final idx = impellerFragmentGlsl.indexOf(normalizedUser);
    if (idx <= 0) return 0;
    return '\n'.allMatches(impellerFragmentGlsl.substring(0, idx)).length;
  }

  static int? _extractRawLineNumber(String stderr) {
    for (final pattern in <RegExp>[
      _fragmentLinePattern,
      _glslangErrorPattern,
      _genericFileLinePattern,
    ]) {
      final match = pattern.firstMatch(stderr);
      if (match == null) continue;
      final parsed = int.tryParse(match.group(1) ?? '');
      if (parsed != null && parsed > 0) return parsed;
    }
    return null;
  }

  static void _completeOnce(Completer<void> completer) {
    if (!completer.isCompleted) {
      completer.complete();
    }
  }

  static String _combineProcessOutput(String stderrText, String stdoutText) {
    final err = stderrText.trim();
    final out = stdoutText.trim();
    if (err.isNotEmpty && out.isNotEmpty) return '$err\n$out';
    return err.isNotEmpty ? err : out;
  }

  static String? _existingFilePath(String? rawPath) {
    final trimmed = rawPath?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    final file = File(trimmed);
    return file.existsSync() ? file.path : null;
  }

  static String _safeResolveSymlinks(File file) {
    try {
      return file.resolveSymbolicLinksSync();
    } on FileSystemException {
      return file.path;
    }
  }

  static Future<void> _safeDeleteDirectory(Directory dir) async {
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } on FileSystemException {
      // Best-effort temp cleanup.
    }
  }

  static Future<void> _safeDeleteFile(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // Best-effort temp cleanup.
    }
  }

  static String _joinPath(String a, String b) =>
      _joinSegments(<String>[a, b], Platform.pathSeparator);

  static String _joinSegments(List<String> segments, String sep) {
    final buffer = StringBuffer();
    for (var i = 0; i < segments.length; i++) {
      var part = segments[i];
      if (i > 0) {
        part = _trimLeadingSeparators(part);
        if (buffer.isNotEmpty && !_endsWithSeparator(buffer.toString())) {
          buffer.write(sep);
        }
      }
      buffer.write(part);
    }
    return buffer.toString();
  }

  static String _dirname(String path) {
    var end = path.length;
    while (end > 1 && _isSeparator(path.codeUnitAt(end - 1))) {
      end--;
    }
    final trimmed = path.substring(0, end);
    var idx = -1;
    for (var i = trimmed.length - 1; i >= 0; i--) {
      if (_isSeparator(trimmed.codeUnitAt(i))) {
        idx = i;
        break;
      }
    }
    if (idx < 0) return '';
    return idx == 0 ? trimmed.substring(0, 1) : trimmed.substring(0, idx);
  }

  static String _trimLeadingSeparators(String value) {
    var start = 0;
    while (start < value.length && _isSeparator(value.codeUnitAt(start))) {
      start++;
    }
    return value.substring(start);
  }

  static bool _endsWithSeparator(String value) =>
      value.isNotEmpty && _isSeparator(value.codeUnitAt(value.length - 1));

  static bool _isSeparator(int codeUnit) =>
      codeUnit == 0x2F || codeUnit == 0x5C;
}

/// Pure-Dart FIPS 180-4 SHA-256 implementation without external package
/// dependencies.
abstract final class _Sha256 {
  static final Uint32List _initialState = _computeInitialState();
  static final Uint32List _roundConstants = _computeRoundConstants();

  static String digestHex(Uint8List input) {
    final padded = _padMessage(input);
    final view = ByteData.sublistView(padded);
    final state = Uint32List.fromList(_initialState);
    final schedule = Uint32List(64);

    for (var offset = 0; offset < padded.length; offset += 64) {
      _compressBlock(state, view, offset, schedule);
    }

    final buffer = StringBuffer();
    for (var i = 0; i < 8; i++) {
      buffer.write(state[i].toRadixString(16).padLeft(8, '0'));
    }
    return buffer.toString();
  }

  static Uint8List _padMessage(Uint8List input) {
    final len = input.length;
    final rem = (len + 9) % 64;
    final paddedLen = rem == 0 ? len + 9 : len + 9 + (64 - rem);
    final out = Uint8List(paddedLen);
    out.setRange(0, len, input);
    out[len] = 0x80;

    final bitLen = len * 8;
    final view = ByteData.sublistView(out);
    final highBits = bitLen ~/ 4294967296;
    final lowBits = bitLen & 0xFFFFFFFF;
    view.setUint32(paddedLen - 8, highBits, Endian.big);
    view.setUint32(paddedLen - 4, lowBits, Endian.big);
    return out;
  }

  static void _compressBlock(
    Uint32List state,
    ByteData view,
    int offset,
    Uint32List w,
  ) {
    for (var i = 0; i < 16; i++) {
      w[i] = view.getUint32(offset + i * 4, Endian.big);
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
    }

    var a = state[0];
    var b = state[1];
    var c = state[2];
    var d = state[3];
    var e = state[4];
    var f = state[5];
    var g = state[6];
    var h = state[7];

    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g);
      final t1 = (h + s1 + ch + _roundConstants[i] + w[i]) & 0xFFFFFFFF;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xFFFFFFFF;

      h = g;
      g = f;
      f = e;
      e = (d + t1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xFFFFFFFF;
    }

    state[0] = (state[0] + a) & 0xFFFFFFFF;
    state[1] = (state[1] + b) & 0xFFFFFFFF;
    state[2] = (state[2] + c) & 0xFFFFFFFF;
    state[3] = (state[3] + d) & 0xFFFFFFFF;
    state[4] = (state[4] + e) & 0xFFFFFFFF;
    state[5] = (state[5] + f) & 0xFFFFFFFF;
    state[6] = (state[6] + g) & 0xFFFFFFFF;
    state[7] = (state[7] + h) & 0xFFFFFFFF;
  }

  static int _rotr(int value, int shift) =>
      ((value >>> shift) | (value << (32 - shift))) & 0xFFFFFFFF;

  static Uint32List _computeInitialState() {
    final primes = _firstPrimes(8);
    final result = Uint32List(8);
    for (var i = 0; i < 8; i++) {
      final root = math.sqrt(primes[i]);
      result[i] = ((root - root.floor()) * 4294967296.0).floor() & 0xFFFFFFFF;
    }
    return result;
  }

  static Uint32List _computeRoundConstants() {
    final primes = _firstPrimes(64);
    final result = Uint32List(64);
    for (var i = 0; i < 64; i++) {
      final root = math.pow(primes[i], 1.0 / 3.0).toDouble();
      result[i] = ((root - root.floor()) * 4294967296.0).floor() & 0xFFFFFFFF;
    }
    return result;
  }

  static List<int> _firstPrimes(int count) {
    final primes = <int>[];
    var candidate = 2;
    while (primes.length < count) {
      if (_isPrime(candidate)) {
        primes.add(candidate);
      }
      candidate++;
    }
    return primes;
  }

  static bool _isPrime(int n) {
    for (var d = 2; d * d <= n; d++) {
      if (n % d == 0) return false;
    }
    return n >= 2;
  }
}
