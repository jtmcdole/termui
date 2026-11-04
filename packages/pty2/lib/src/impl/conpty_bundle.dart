import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves Microsoft's redistributable `conpty.dll` + `OpenConsole.exe`
/// (`Microsoft.Windows.Console.ConPTY`) side-by-side pair on Windows.
///
/// Inbox `C:\Windows\System32\conhost.exe` (spawned by
/// `kernel32.dll!CreatePseudoConsole`) uses the legacy `VtEngine` screen
/// scraper, which strips `OSC 52` clipboard sequences, quantizes 24-bit RGB
/// colors, and misparses semicolon-delimited `SGR 58;2;R;G;B` underline colors.
/// Loading `conpty.dll` with `OpenConsole.exe` alongside it activates
/// `WriteCharsVT` raw VT passthrough (`microsoft/terminal#17510`).
abstract final class ConPtyBundle {
  /// Returns whether [dir] contains a non-empty `conpty.dll` and
  /// `OpenConsole.exe` side-by-side pair.
  static bool hasValidPair(Directory dir) {
    final dllFile = File(p.join(dir.path, 'conpty.dll'));
    final exeFile = File(p.join(dir.path, 'OpenConsole.exe'));
    try {
      return dllFile.existsSync() &&
          exeFile.existsSync() &&
          dllFile.lengthSync() > 0 &&
          exeFile.lengthSync() > 0;
    } on FileSystemException {
      return false;
    }
  }

  /// Resolves the path to a `conpty.dll` that has `OpenConsole.exe` next to it,
  /// or returns `null` if no valid side-by-side pair is available.
  static String? resolveConPtyDllPath({
    Map<String, String>? environment,
    String? resolvedExecutablePath,
  }) {
    final env = environment ?? Platform.environment;

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

    return null;
  }
}
