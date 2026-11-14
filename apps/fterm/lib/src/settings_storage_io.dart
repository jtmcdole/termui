import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'settings_storage.dart';

/// Default platform [SettingsStorage] on `dart:io` hosts.
///
/// Remains an isolated no-op store whenever `FLUTTER_TEST` is present in
/// [Platform.environment] so `flutter test` never reads or writes `~/.config`
/// or `%APPDATA%`.
final SettingsStorage platformSettingsStorage = createPlatformSettingsStorage();

/// Creates the `dart:io` [SettingsStorage] for [environment] and OS polarity.
SettingsStorage createPlatformSettingsStorage({
  Map<String, String>? environment,
  bool? isWindows,
}) {
  final env = environment ?? Platform.environment;
  if (env.containsKey('FLUTTER_TEST')) {
    return const _NoopIoSettingsStorage();
  }
  final windows = isWindows ?? Platform.isWindows;
  final path = resolveDesktopSettingsFilePath(
    environment: env,
    isWindows: windows,
  );
  if (path == null) {
    return const _NoopIoSettingsStorage();
  }
  final legacyPath = resolveLegacyDesktopSettingsFilePath(
    environment: env,
    isWindows: windows,
  );
  return FileSettingsStorage(
    File(path),
    legacyFile: legacyPath != null ? File(legacyPath) : null,
    isWindows: windows,
  );
}

/// Resolves `~/.config/fterm/settings.json` on macOS/Linux or
/// `%APPDATA%\fterm\settings.json` on Windows, returning `null` when
/// no home or app-data directory is set in [environment].
String? resolveDesktopSettingsFilePath({
  Map<String, String>? environment,
  bool? isWindows,
}) => _resolveConfigSettingsFilePath(
  appFolder: 'fterm',
  environment: environment,
  isWindows: isWindows,
);

/// Resolves the legacy `~/.config/termui_cast/settings.json` path used for
/// read-fallback migration into `~/.config/fterm/settings.json`.
String? resolveLegacyDesktopSettingsFilePath({
  Map<String, String>? environment,
  bool? isWindows,
}) => _resolveConfigSettingsFilePath(
  appFolder: 'termui_cast',
  environment: environment,
  isWindows: isWindows,
);

String? _resolveConfigSettingsFilePath({
  required String appFolder,
  Map<String, String>? environment,
  bool? isWindows,
}) {
  final env = environment ?? Platform.environment;
  if (isWindows ?? Platform.isWindows) {
    final appData = _nonEmptyPath(env['APPDATA']);
    if (appData != null) {
      return p.windows.join(appData, appFolder, 'settings.json');
    }
    final userProfile = _nonEmptyPath(env['USERPROFILE']);
    if (userProfile != null) {
      return p.windows.join(
        userProfile,
        'AppData',
        'Roaming',
        appFolder,
        'settings.json',
      );
    }
    return null;
  }
  final home = _nonEmptyPath(env['HOME']);
  if (home == null) return null;
  return p.posix.join(home, '.config', appFolder, 'settings.json');
}

String? _nonEmptyPath(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// JSON file-backed [SettingsStorage] for macOS, Linux, and Windows desktops.
///
/// On POSIX systems, creates the parent directory with mode `0700` and writes
/// updates atomically via an `exclusive: true` temp file set to mode `0600`
/// prior to writing payloads and renaming.
final class FileSettingsStorage implements SettingsStorage {
  static const JsonEncoder _prettyEncoder = JsonEncoder.withIndent('  ');
  static int _tempCounter = 0;

  /// Backing `settings.json` file on disk.
  final File file;

  /// Optional legacy `termui_cast/settings.json` file migrated on first write.
  final File? legacyFile;

  final bool? _isWindowsOverride;

  /// Creates a [SettingsStorage] persisted in [file].
  const FileSettingsStorage(this.file, {this.legacyFile, bool? isWindows})
    : _isWindowsOverride = isWindows;

  bool get _isWindows => _isWindowsOverride ?? Platform.isWindows;

  @override
  String? getItem(String key) {
    final entry = _readEntries()[key];
    return switch (entry) {
      final String s => s,
      final Map<Object?, Object?> m => jsonEncode(m),
      _ => null,
    };
  }

  @override
  void setItem(String key, String value) {
    try {
      final entries = _readEntries()..[key] = value;
      final payload = '${_prettyEncoder.convert(entries)}\n';
      _ensurePrivateParentDir();
      final tempFile = _createPrivateTempFile();
      try {
        tempFile.writeAsStringSync(payload, flush: true);
        tempFile.renameSync(file.path);
      } catch (_) {
        _deleteQuietly(tempFile);
        rethrow;
      }
    } on Object {
      // Ignore read-only filesystem, sandbox, or disk-quota errors.
    }
  }

  void _ensurePrivateParentDir() {
    final parent = file.parent;
    if (!parent.existsSync()) {
      parent.createSync(recursive: true);
    }
    if (!_isWindows && (parent.statSync().mode & 0x1FF) != 0x1C0) {
      _chmodStrict(parent.path, '0700');
    }
  }

  File _createPrivateTempFile() {
    final parentPath = file.parent.path;
    final prefix = '.${p.basename(file.path)}.tmp.$pid';
    while (true) {
      final id = ++_tempCounter;
      final candidate = File(p.join(parentPath, '$prefix.$id'));
      try {
        candidate.createSync(exclusive: true);
      } on PathExistsException {
        continue;
      }
      if (!_isWindows) {
        try {
          _chmodStrict(candidate.path, '0600');
        } catch (_) {
          _deleteQuietly(candidate);
          rethrow;
        }
      }
      return candidate;
    }
  }

  void _chmodStrict(String path, String mode) {
    final result = Process.runSync('chmod', [mode, path]);
    if (result.exitCode != 0) {
      throw FileSystemException('chmod $mode failed (${result.stderr})', path);
    }
  }

  void _deleteQuietly(File target) {
    try {
      if (target.existsSync()) {
        target.deleteSync();
      }
    } on Object {
      // Best-effort cleanup of abandoned temp file.
    }
  }

  Map<String, Object?> _readEntries() {
    final source = file.existsSync()
        ? file
        : (legacyFile != null && legacyFile!.existsSync() ? legacyFile! : null);
    if (source == null) return <String, Object?>{};
    try {
      final Object? decoded = jsonDecode(source.readAsStringSync());
      if (decoded is Map<Object?, Object?>) {
        return <String, Object?>{
          for (final MapEntry(:key, :value) in decoded.entries)
            if (key is String) key: value,
        };
      }
    } on Object {
      // Fall back to empty map when missing, unreadable, or malformed.
    }
    return <String, Object?>{};
  }
}

final class _NoopIoSettingsStorage implements SettingsStorage {
  const _NoopIoSettingsStorage();

  @override
  String? getItem(String key) => null;

  @override
  void setItem(String key, String value) {}
}
