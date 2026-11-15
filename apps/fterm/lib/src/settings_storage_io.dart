import 'dart:async';
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
/// Caches the decoded root JSON map in memory and persists mutations
/// asynchronously through a coalescing writer without blocking the Flutter UI
/// isolate. Rejects symlinks on the settings directory, target file, and temp
/// staging files. On POSIX systems, applies mode `0700` on directory creation
/// and `0600` on temp file creation; on Windows, restricts directory ACLs to
/// the current user once on directory creation.
final class FileSettingsStorage implements BatchSettingsStorage {
  static const JsonEncoder _prettyEncoder = JsonEncoder.withIndent('  ');
  static int _tempCounter = 0;

  /// Backing `settings.json` file on disk.
  final File file;

  /// Optional legacy `termui_cast/settings.json` file migrated on first write.
  final File? legacyFile;

  final bool? _isWindowsOverride;
  final Map<String, String>? _environmentOverride;

  Map<String, Object?>? _cachedEntries;
  bool _dirSecured = false;
  String? _pendingPayload;
  Future<void>? _activeWrite;
  Object? _lastError;

  /// Creates a [SettingsStorage] persisted in [file].
  FileSettingsStorage(
    this.file, {
    this.legacyFile,
    bool? isWindows,
    Map<String, String>? environment,
  }) : _isWindowsOverride = isWindows,
       _environmentOverride = environment;

  bool get _isWindows => _isWindowsOverride ?? Platform.isWindows;

  /// Last filesystem or symlink rejection error encountered during an async write.
  Object? get lastError => _lastError;

  @override
  String? getItem(String key) {
    final entry = _ensureEntriesLoaded()[key];
    return switch (entry) {
      final String s => s,
      final Map<Object?, Object?> m => jsonEncode(m),
      _ => null,
    };
  }

  @override
  void setItem(String key, String value) =>
      setItems(<String, String>{key: value});

  @override
  void setItems(Map<String, String> entries) {
    if (entries.isEmpty) return;
    final current = _ensureEntriesLoaded();
    current.addAll(entries);
    _pendingPayload = '${_prettyEncoder.convert(current)}\n';
    _activeWrite ??= Zone.root.run(_drainWrites);
  }

  @override
  void invalidateCache() {
    _cachedEntries = null;
    _pendingPayload = null;
  }

  @override
  Future<void> flush() async {
    while (_activeWrite != null) {
      await _activeWrite;
    }
  }

  Future<void> _drainWrites() async {
    try {
      while (_pendingPayload != null) {
        final payload = _pendingPayload!;
        _pendingPayload = null;
        try {
          await _writePayloadAsync(payload);
          _lastError = null;
        } on Object catch (e) {
          _lastError = e;
        }
      }
    } finally {
      _activeWrite = null;
    }
  }

  Future<void> _writePayloadAsync(String payload) async {
    await _ensurePrivateParentDirAsync();
    if (await _isSymlinkAsync(file.path)) {
      throw FileSystemException(
        'Refusing to overwrite symlinked settings file',
        file.path,
      );
    }
    final tempFile = await _createPrivateTempFileAsync();
    try {
      await tempFile.writeAsString(payload, flush: true);
      if (await _isSymlinkAsync(file.path)) {
        throw FileSystemException(
          'Refusing to overwrite symlinked settings file',
          file.path,
        );
      }
      await tempFile.rename(file.path);
    } catch (_) {
      await _deleteQuietlyAsync(tempFile);
      rethrow;
    }
  }

  Future<void> _ensurePrivateParentDirAsync() async {
    final parent = file.parent;
    final parentType = await FileSystemEntity.type(
      parent.path,
      followLinks: false,
    );
    if (parentType == .link) {
      _dirSecured = false;
      throw FileSystemException(
        'Refusing to use symlinked settings directory',
        parent.path,
      );
    }
    if (_dirSecured && parentType == .directory) return;

    if (parentType == .notFound) {
      await parent.create(recursive: true);
      if (_isWindows) {
        await _restrictWindowsDirAclOnceAsync(parent.path);
      } else if (!Platform.isWindows) {
        await _chmodStrictAsync(parent.path, '0700');
      }
    } else if (!_isWindows &&
        !Platform.isWindows &&
        ((await parent.stat()).mode & 0x1FF) != 0x1C0) {
      await _chmodStrictAsync(parent.path, '0700');
    }
    _dirSecured = true;
  }

  Future<File> _createPrivateTempFileAsync() async {
    final parentPath = file.parent.path;
    final prefix = '.${p.basename(file.path)}.tmp.$pid';
    while (true) {
      final id = ++_tempCounter;
      final candidate = File(p.join(parentPath, '$prefix.$id'));
      if (await _isSymlinkAsync(candidate.path)) {
        throw FileSystemException(
          'Refusing to write symlinked temp settings file',
          candidate.path,
        );
      }
      try {
        await candidate.create(exclusive: true);
      } on PathExistsException {
        continue;
      }
      if (!_isWindows && !Platform.isWindows) {
        try {
          await _chmodStrictAsync(candidate.path, '0600');
        } catch (_) {
          await _deleteQuietlyAsync(candidate);
          rethrow;
        }
      }
      return candidate;
    }
  }

  Future<void> _chmodStrictAsync(String path, String mode) async {
    final result = await Process.run('chmod', [mode, path]);
    if (result.exitCode != 0) {
      throw FileSystemException('chmod $mode failed (${result.stderr})', path);
    }
  }

  Future<void> _restrictWindowsDirAclOnceAsync(String dirPath) async {
    final env = _environmentOverride ?? Platform.environment;
    final user = env['USERNAME']?.trim();
    if (user == null || user.isEmpty) return;
    final domain = env['USERDOMAIN']?.trim();
    final principal = (domain != null && domain.isNotEmpty)
        ? '$domain\\$user'
        : user;
    try {
      await Process.run('icacls', [
        dirPath,
        '/inheritance:r',
        '/grant:r',
        '$principal:(OI)(CI)F',
      ]);
    } on Object {
      // Best-effort ACL restriction on hosts without icacls on PATH.
    }
  }

  Future<void> _deleteQuietlyAsync(File target) async {
    try {
      if (await FileSystemEntity.type(target.path, followLinks: false) !=
          .notFound) {
        await target.delete();
      }
    } on Object {
      // Best-effort cleanup of abandoned temp file.
    }
  }

  static Future<bool> _isSymlinkAsync(String path) async =>
      await FileSystemEntity.type(path, followLinks: false) == .link;

  static bool _isSymlinkSync(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) == .link;

  Map<String, Object?> _ensureEntriesLoaded() =>
      _cachedEntries ??= _readEntriesFromDisk();

  Map<String, Object?> _readEntriesFromDisk() {
    if (_isSymlinkSync(file.parent.path) || _isSymlinkSync(file.path)) {
      return <String, Object?>{};
    }
    final File? source;
    if (file.existsSync()) {
      source = file;
    } else if (legacyFile != null &&
        !_isSymlinkSync(legacyFile!.path) &&
        legacyFile!.existsSync()) {
      source = legacyFile!;
    } else {
      source = null;
    }
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
