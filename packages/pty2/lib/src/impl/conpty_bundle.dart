import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Supported Windows target architectures for the `Microsoft.Windows.Console.ConPTY`
/// NuGet package.
enum ConPtyArch {
  /// 64-bit x86 (`win-x64`).
  x64,

  /// 64-bit ARM (`win-arm64`).
  arm64,

  /// 32-bit x86 (`win-x86`).
  ia32,
}

/// Metadata for a single Windows target architecture inside the
/// `Microsoft.Windows.Console.ConPTY` NuGet package.
final class ConPtyArchSpec {
  /// Target Windows architecture.
  final ConPtyArch arch;

  /// Relative ZIP entry path for `conpty.dll`.
  final String dllEntryPath;

  /// Expected lowercase hex SHA-256 digest of `conpty.dll`.
  final String dllSha256;

  /// Expected byte length of `conpty.dll`.
  final int dllSize;

  /// Relative ZIP entry path for `OpenConsole.exe`.
  final String exeEntryPath;

  /// Expected lowercase hex SHA-256 digest of `OpenConsole.exe`.
  final String exeSha256;

  /// Expected byte length of `OpenConsole.exe`.
  final int exeSize;

  /// Creates an architecture specification for a ConPTY redistributable pair.
  const ConPtyArchSpec({
    required this.arch,
    required this.dllEntryPath,
    required this.dllSha256,
    required this.dllSize,
    required this.exeEntryPath,
    required this.exeSha256,
    required this.exeSize,
  });
}

/// Manages cryptographic SHA-256 verification, ZIP extraction, atomic cache
/// staging, and runtime resolution of Microsoft's redistributable `conpty.dll`
/// + `OpenConsole.exe` (`Microsoft.Windows.Console.ConPTY`).
///
/// Inbox `C:\Windows\System32\conhost.exe` (spawned by
/// `kernel32.dll!CreatePseudoConsole`) uses the legacy `VtEngine` screen
/// scraper, which strips `OSC 52` clipboard sequences, quantizes 24-bit RGB
/// colors, and misparses semicolon-delimited `SGR 58;2;R;G;B` underline colors.
/// Loading `conpty.dll` with `OpenConsole.exe` alongside it activates
/// `WriteCharsVT` raw VT passthrough (`microsoft/terminal#17510`).
abstract final class ConPtyBundle {
  /// Pinned `Microsoft.Windows.Console.ConPTY` NuGet release version.
  static const String version = '1.25.260930003';

  /// NuGet v3 flat-container download URL for [version].
  static final Uri nupkgUri = Uri.parse(
    'https://api.nuget.org/v3-flatcontainer/microsoft.windows.console.conpty/$version/microsoft.windows.console.conpty.$version.nupkg',
  );

  /// Expected lowercase hex SHA-256 digest of the `.nupkg` archive.
  static const String nupkgSha256 =
      '02b07b349af66d801159bdf9e440d4a1ce78bb951f37fc8609731665afdae7ee';

  /// Maximum allowed `.nupkg` response payload size (8 MiB).
  static const int maxNupkgBytes = 8 * 1024 * 1024;

  static const int _maxEntryBytes = 2 * 1024 * 1024;

  /// Per-architecture binary specifications for [version].
  static const Map<ConPtyArch, ConPtyArchSpec> specs = {
    .x64: ConPtyArchSpec(
      arch: .x64,
      dllEntryPath: 'runtimes/win-x64/native/conpty.dll',
      dllSha256:
          'feeef341d891643c62d30b6b07800bc70f0bc148f44cb8c3bee84aa557ae805a',
      dllSize: 119608,
      exeEntryPath: 'build/native/runtimes/x64/OpenConsole.exe',
      exeSha256:
          '3d66b23d0a71bb8eed2b77edc8b9df9bf54ce6c8fb74c863a30e760997f80586',
      exeSize: 1089376,
    ),
    .arm64: ConPtyArchSpec(
      arch: .arm64,
      dllEntryPath: 'runtimes/win-arm64/native/conpty.dll',
      dllSha256:
          '151a02355227710c20c9f8f1eaf68ac4668aa09cdc921adc7ec661804d8eb1bf',
      dllSize: 116024,
      exeEntryPath: 'build/native/runtimes/arm64/OpenConsole.exe',
      exeSha256:
          '4313825a3ba634d113cc6ed3bc8ce735e3c19d360cecd985794787479469f91f',
      exeSize: 1149752,
    ),
    .ia32: ConPtyArchSpec(
      arch: .ia32,
      dllEntryPath: 'runtimes/win-x86/native/conpty.dll',
      dllSha256:
          'd145f621bf64a9da3b7395587ddef9831ca404805d8987ec8c9903d0c4603d93',
      dllSize: 98616,
      exeEntryPath: 'build/native/runtimes/x86/OpenConsole.exe',
      exeSha256:
          'e3e475547d57da0689dc9fc5e0101d10390e2a4719a6eb5dcad569f6cb33c1a3',
      exeSize: 1046880,
    ),
  };

  /// Returns the host Windows target architecture.
  static ConPtyArch hostArch() => switch (Abi.current()) {
    .windowsArm64 => .arm64,
    .windowsIA32 => .ia32,
    _ => .x64,
  };

  /// Returns the per-user cache directory for [arch], or `null` when neither
  /// `LOCALAPPDATA` nor `USERPROFILE` is configured in [environment].
  static Directory? defaultCacheDirectory({
    required ConPtyArch arch,
    Map<String, String>? environment,
  }) {
    final env = environment ?? Platform.environment;
    final localAppData = env['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      return Directory(
        p.join(localAppData, 'pty2', 'conpty', version, arch.name),
      );
    }
    final userProfile = env['USERPROFILE'];
    if (userProfile != null && userProfile.isNotEmpty) {
      return Directory(
        p.join(
          userProfile,
          'AppData',
          'Local',
          'pty2',
          'conpty',
          version,
          arch.name,
        ),
      );
    }
    return null;
  }

  /// Returns whether [dir] contains both `conpty.dll` and `OpenConsole.exe`.
  ///
  /// When [verifySpec] is provided, both files must also match the expected
  /// byte lengths and SHA-256 digests in [verifySpec].
  static bool hasValidPair(Directory dir, {ConPtyArchSpec? verifySpec}) {
    final dllFile = File(p.join(dir.path, 'conpty.dll'));
    final exeFile = File(p.join(dir.path, 'OpenConsole.exe'));
    try {
      if (!dllFile.existsSync() || !exeFile.existsSync()) {
        return false;
      }
      if (verifySpec == null) {
        return dllFile.lengthSync() > 0 && exeFile.lengthSync() > 0;
      }
      if (dllFile.lengthSync() != verifySpec.dllSize ||
          exeFile.lengthSync() != verifySpec.exeSize) {
        return false;
      }
      final dllBytes = dllFile.readAsBytesSync();
      final exeBytes = exeFile.readAsBytesSync();
      return sha256Hex(dllBytes) == verifySpec.dllSha256 &&
          sha256Hex(exeBytes) == verifySpec.exeSha256;
    } on FileSystemException {
      return false;
    }
  }

  /// Resolves the path to a `conpty.dll` that has `OpenConsole.exe` next to it,
  /// or returns `null` if no valid side-by-side pair is available.
  static String? resolveConPtyDllPath({
    ConPtyArch? arch,
    Map<String, String>? environment,
    String? resolvedExecutablePath,
    Map<ConPtyArch, ConPtyArchSpec>? customSpecs,
  }) {
    final env = environment ?? Platform.environment;
    final activeArch = arch ?? hostArch();
    final spec = (customSpecs ?? specs)[activeArch];

    // 1. Explicit environment override (for custom deployments or tests).
    final customDir = env['PTY2_CONPTY_DIR'];
    if (customDir != null && customDir.isNotEmpty) {
      final dir = Directory(customDir);
      if (hasValidPair(dir)) {
        return p.join(dir.path, 'conpty.dll');
      }
    }

    // 2. Side-by-side with the running executable.
    final exePath = resolvedExecutablePath ?? Platform.resolvedExecutable;
    if (exePath.isNotEmpty) {
      final exeDir = File(exePath).parent;
      if (hasValidPair(exeDir)) {
        return p.join(exeDir.path, 'conpty.dll');
      }
    }

    // 3. Staged NuGet cache directory (verified against pinned SHA-256).
    final cacheDir = defaultCacheDirectory(arch: activeArch, environment: env);
    if (cacheDir != null &&
        spec != null &&
        hasValidPair(cacheDir, verifySpec: spec)) {
      return p.join(cacheDir.path, 'conpty.dll');
    }

    return null;
  }

  /// Reads [nupkg], verifies its SHA-256 digest, and atomically stages
  /// `conpty.dll` and `OpenConsole.exe` into the per-user cache directory.
  static Future<String> installFromNupkgFile(
    File nupkg, {
    ConPtyArch? arch,
    Map<String, String>? environment,
    String? expectedNupkgSha256,
    Map<ConPtyArch, ConPtyArchSpec>? customSpecs,
  }) async {
    final activeArch = arch ?? hostArch();
    final cacheDir = defaultCacheDirectory(
      arch: activeArch,
      environment: environment,
    );
    if (cacheDir == null) {
      throw StateError(
        'Cannot resolve ConPTY cache directory: neither LOCALAPPDATA nor USERPROFILE is set',
      );
    }
    final bytes = await nupkg.readAsBytes();
    stageFromNupkgBytes(
      bytes,
      arch: activeArch,
      targetDir: cacheDir,
      expectedNupkgSha256: expectedNupkgSha256,
      customSpecs: customSpecs,
    );
    return p.join(cacheDir.path, 'conpty.dll');
  }

  /// Ensures `conpty.dll` + `OpenConsole.exe` are staged and returns the path
  /// to `conpty.dll`, or `null` if unavailable.
  ///
  /// When [download] is `true` (default `false` for offline safety) and no
  /// local or cached binary is present, downloads the pinned NuGet package from
  /// [downloadUri] (defaults to [nupkgUri]), verifies its SHA-256 digest, and
  /// stages the binaries into the per-user cache via [stageFromNupkgBytes].
  static Future<String?> ensureReady({
    ConPtyArch? arch,
    Map<String, String>? environment,
    String? resolvedExecutablePath,
    bool download = false,
    Uri? downloadUri,
    String? expectedNupkgSha256,
    Map<ConPtyArch, ConPtyArchSpec>? customSpecs,
    int maxBytes = maxNupkgBytes,
    void Function(String message)? onWarning,
  }) async {
    final env = environment ?? Platform.environment;
    final activeArch = arch ?? hostArch();
    final existing = resolveConPtyDllPath(
      arch: activeArch,
      environment: env,
      resolvedExecutablePath: resolvedExecutablePath,
      customSpecs: customSpecs,
    );
    if (existing != null || !download) {
      return existing;
    }

    final cacheDir = defaultCacheDirectory(arch: activeArch, environment: env);
    if (cacheDir == null) {
      return null;
    }

    try {
      final nupkgBytes = await _downloadNupkgBytes(
        downloadUri ?? nupkgUri,
        maxBytes: maxBytes,
      );
      stageFromNupkgBytes(
        nupkgBytes,
        arch: activeArch,
        targetDir: cacheDir,
        expectedNupkgSha256: expectedNupkgSha256,
        customSpecs: customSpecs,
      );
      return resolveConPtyDllPath(
        arch: activeArch,
        environment: env,
        resolvedExecutablePath: resolvedExecutablePath,
        customSpecs: customSpecs,
      );
    } on Object catch (e) {
      onWarning?.call('ConPTY NuGet download/staging failed: $e');
      return null;
    }
  }

  static Future<Uint8List> _downloadNupkgBytes(
    Uri uri, {
    required int maxBytes,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 15));
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException(
          'Unexpected HTTP ${response.statusCode} fetching ConPTY NuGet package',
          uri: uri,
        );
      }
      if (response.contentLength > maxBytes) {
        await response.drain<void>();
        throw FormatException(
          'ConPTY NuGet content-length ${response.contentLength} exceeds $maxBytes bytes',
        );
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        if (builder.length + chunk.length > maxBytes) {
          throw FormatException(
            'ConPTY NuGet stream exceeded $maxBytes bytes limit',
          );
        }
        builder.add(chunk);
      }
      return builder.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  /// Verifies [nupkgBytes] against [nupkgSha256], extracts `conpty.dll` and
  /// `OpenConsole.exe` for [arch], verifies their SHA-256 digests and sizes,
  /// and writes them atomically to [targetDir].
  static void stageFromNupkgBytes(
    Uint8List nupkgBytes, {
    required ConPtyArch arch,
    required Directory targetDir,
    String? expectedNupkgSha256,
    Map<ConPtyArch, ConPtyArchSpec>? customSpecs,
  }) {
    final spec = (customSpecs ?? specs)[arch]!;
    final expectedHash = expectedNupkgSha256 ?? nupkgSha256;
    final actualHash = sha256Hex(nupkgBytes);
    if (actualHash != expectedHash) {
      throw FormatException(
        'ConPTY NuGet SHA-256 mismatch: expected $expectedHash, got $actualHash',
      );
    }

    final extracted = extractZipEntries(nupkgBytes, {
      spec.dllEntryPath,
      spec.exeEntryPath,
    });
    final dll = extracted[spec.dllEntryPath];
    final exe = extracted[spec.exeEntryPath];
    if (dll == null || exe == null) {
      throw FormatException(
        'ConPTY NuGet archive missing ${spec.dllEntryPath} or ${spec.exeEntryPath}',
      );
    }
    _verifyEntry(
      'conpty.dll (${arch.name})',
      dll,
      spec.dllSize,
      spec.dllSha256,
    );
    _verifyEntry(
      'OpenConsole.exe (${arch.name})',
      exe,
      spec.exeSize,
      spec.exeSha256,
    );

    targetDir.createSync(recursive: true);
    // Write OpenConsole.exe before conpty.dll so conpty.dll never observes a
    // directory without OpenConsole.exe alongside it.
    _writeFileAtomically(
      p.join(targetDir.path, 'OpenConsole.exe'),
      exe,
      spec.exeSha256,
    );
    _writeFileAtomically(
      p.join(targetDir.path, 'conpty.dll'),
      dll,
      spec.dllSha256,
    );
  }

  static void _verifyEntry(String label, Uint8List b, int size, String sha) {
    final actual = sha256Hex(b);
    if (b.length != size || actual != sha) {
      throw FormatException(
        '$label SHA-256 mismatch: expected $sha, got $actual',
      );
    }
  }

  static bool _matchesDigest(File file, int length, String sha) {
    try {
      return file.existsSync() &&
          file.lengthSync() == length &&
          sha256Hex(file.readAsBytesSync()) == sha;
    } on FileSystemException {
      return false;
    }
  }

  static void _writeFileAtomically(String path, Uint8List bytes, String sha) {
    final target = File(path);
    if (_matchesDigest(target, bytes.length, sha)) return;
    final tmp = File(
      '$path.tmp.${pid}_${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      tmp.writeAsBytesSync(bytes, flush: true);
      tmp.renameSync(path);
    } on FileSystemException {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } on FileSystemException {
        // Best-effort cleanup.
      }
      if (!_matchesDigest(target, bytes.length, sha)) rethrow;
    }
  }

  /// Extracts [wantedEntries] from a standard ZIP archive ([zipBytes]).
  static Map<String, Uint8List> extractZipEntries(
    Uint8List zipBytes,
    Set<String> wantedEntries,
  ) {
    final view = ByteData.sublistView(zipBytes);
    final results = <String, Uint8List>{};
    var offset = 0;

    while (offset + 30 <= zipBytes.length &&
        results.length < wantedEntries.length) {
      if (view.getUint32(offset, Endian.little) != 0x04034b50) break;
      if ((view.getUint16(offset + 6, Endian.little) & 0x0008) != 0) {
        throw const FormatException(
          'ZIP data descriptor streaming flag (bit 3) is not supported',
        );
      }
      final method = view.getUint16(offset + 8, Endian.little);
      final compSize = view.getUint32(offset + 18, Endian.little);
      final uncompSize = view.getUint32(offset + 22, Endian.little);
      final nameLen = view.getUint16(offset + 26, Endian.little);
      final extraLen = view.getUint16(offset + 28, Endian.little);
      final nameStart = offset + 30;
      final dataStart = nameStart + nameLen + extraLen;
      final dataEnd = dataStart + compSize;
      if (dataEnd > zipBytes.length) {
        throw const FormatException('Truncated ZIP entry payload');
      }
      final name = utf8
          .decode(
            Uint8List.sublistView(zipBytes, nameStart, nameStart + nameLen),
            allowMalformed: true,
          )
          .replaceAll(r'\', '/');
      if (wantedEntries.contains(name)) {
        results[name] = _decodeZipPayload(
          Uint8List.sublistView(zipBytes, dataStart, dataEnd),
          method,
          uncompSize,
        );
      }
      offset = dataEnd;
    }
    return results;
  }

  static Uint8List _decodeZipPayload(Uint8List data, int method, int size) {
    if (size > _maxEntryBytes) {
      throw FormatException(
        'ZIP entry uncompressed size $size exceeds $_maxEntryBytes',
      );
    }
    final out = switch (method) {
      0 => Uint8List.fromList(data),
      8 => Uint8List.fromList(ZLibCodec(raw: true).decode(data)),
      _ => throw FormatException('Unsupported ZIP compression method $method'),
    };
    if (out.length != size) {
      throw FormatException(
        'Uncompressed size mismatch: expected $size, got ${out.length}',
      );
    }
    return out;
  }

  /// Computes the lowercase hexadecimal FIPS 180-4 SHA-256 digest of [data].
  static String sha256Hex(Uint8List data) => '${sha256.convert(data)}';
}
