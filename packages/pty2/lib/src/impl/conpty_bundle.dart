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

/// Resolves and verifies Microsoft's redistributable `conpty.dll` +
/// `OpenConsole.exe` (`Microsoft.Windows.Console.ConPTY`) side-by-side pair.
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

  /// Computes the lowercase hexadecimal FIPS 180-4 SHA-256 digest of [data].
  static String sha256Hex(Uint8List data) => '${sha256.convert(data)}';
}
