import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'shader_profile_store.dart';

/// Creates the `dart:io` [ShaderProfileStore] for [environment] and OS
/// polarity.
///
/// When [shadersDirectoryOverride] is omitted and `FLUTTER_TEST` is present in
/// [environment] (or [Platform.environment]), returns a safe no-op store so
/// `flutter test` never reads or writes `~/.config/fterm/shaders` or
/// `%APPDATA%\fterm\shaders`.
ShaderProfileStore createPlatformShaderProfileStore({
  Map<String, String>? environment,
  bool? isWindows,
  Directory? shadersDirectoryOverride,
  Duration watchDebounce = defaultShaderWatchDebounce,
}) {
  if (shadersDirectoryOverride != null) {
    return IoShaderProfileStore(
      shadersDirectoryOverride,
      watchDebounce: watchDebounce,
    );
  }
  final env = environment ?? Platform.environment;
  if (env.containsKey('FLUTTER_TEST')) {
    return const _NoopIoShaderProfileStore();
  }
  final resolved = resolveDesktopShadersDirectoryPath(
    environment: env,
    isWindows: isWindows,
  );
  if (resolved == null) {
    return const _NoopIoShaderProfileStore();
  }
  return IoShaderProfileStore(
    Directory(resolved),
    watchDebounce: watchDebounce,
  );
}

/// Canonicalizes [rawPath] and resolves symbolic links along the path or its
/// parent directory when present on disk.
String resolveCanonicalShaderPath(String rawPath) {
  final normalized = p.canonicalize(rawPath);
  try {
    return File(normalized).resolveSymbolicLinksSync();
  } on FileSystemException {
    final parent = p.dirname(normalized);
    final base = p.basename(normalized);
    try {
      return p.join(Directory(parent).resolveSymbolicLinksSync(), base);
    } on FileSystemException {
      return normalized;
    }
  }
}

/// Resolves `~/.config/fterm/shaders` on macOS/Linux or
/// `%APPDATA%\fterm\shaders` on Windows, returning `null` when no home or
/// app-data directory is set in [environment].
String? resolveDesktopShadersDirectoryPath({
  Map<String, String>? environment,
  bool? isWindows,
}) {
  final env = environment ?? Platform.environment;
  if (isWindows ?? Platform.isWindows) {
    final appData = _nonEmptyPath(env['APPDATA']);
    if (appData != null) {
      return p.windows.join(appData, 'fterm', 'shaders');
    }
    final userProfile = _nonEmptyPath(env['USERPROFILE']);
    if (userProfile != null) {
      return p.windows.join(
        userProfile,
        'AppData',
        'Roaming',
        'fterm',
        'shaders',
      );
    }
    return null;
  }
  final home = _nonEmptyPath(env['HOME']);
  if (home == null) return null;
  return p.posix.join(home, '.config', 'fterm', 'shaders');
}

String? _nonEmptyPath(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Asynchronous filesystem-backed [ShaderProfileStore] for desktop platforms.
///
/// Rejects symlinks on target files and the shaders directory, enforces byte
/// size limits before reading files into memory, and coalesces rapid
/// `Directory.watch` edits into debounced [ShaderDirectoryChange] events.
final class IoShaderProfileStore implements ShaderProfileStore {
  /// Root directory scanned and watched for user `.glsl` / `.frag` shaders.
  final Directory shadersDirectory;

  /// Debounce interval applied to filesystem watch events.
  final Duration watchDebounce;

  final Set<_DirectoryWatchSession> _activeWatchers =
      <_DirectoryWatchSession>{};
  bool _disposed = false;

  /// Creates an [IoShaderProfileStore] rooted at [shadersDirectory].
  IoShaderProfileStore(
    this.shadersDirectory, {
    this.watchDebounce = defaultShaderWatchDebounce,
  });

  @override
  String get shadersDirectoryPath => shadersDirectory.path;

  @override
  Future<Uint8List> loadWallpaperBytes(String pathOrKey) async {
    final targetPath = _normalizeNonEmptyPath(pathOrKey);
    final file = await _resolveReadableFile(targetPath);
    final size = await file.length();
    if (size > maxWallpaperBytes) {
      throw ShaderAssetException(
        'Wallpaper image exceeds the $maxWallpaperBytes-byte (16 MiB) limit '
        '($size bytes).',
        pathOrKey: targetPath,
      );
    }
    final bytes = await file.readAsBytes();
    validateWallpaperBytes(bytes, pathOrKey: targetPath);
    return bytes;
  }

  @override
  Future<String> loadShaderSource(String pathOrKey) async {
    final targetPath = _resolveShaderTargetPath(pathOrKey);
    final file = await _resolveReadableFile(targetPath);
    final size = await file.length();
    if (size > maxShaderSourceBytes) {
      throw ShaderAssetException(
        'Shader source exceeds the $maxShaderSourceBytes-byte (64 KiB) limit '
        '($size bytes).',
        pathOrKey: targetPath,
      );
    }
    final bytes = await file.readAsBytes();
    validateShaderSourceBytes(bytes, pathOrKey: targetPath);
    try {
      return utf8.decode(bytes);
    } on FormatException catch (error) {
      throw ShaderAssetException(
        'Shader source is not valid UTF-8: ${error.message}',
        pathOrKey: targetPath,
      );
    }
  }

  @override
  Future<List<String>> listShaderFiles() async {
    final dirType = await FileSystemEntity.type(
      shadersDirectory.path,
      followLinks: false,
    );
    if (dirType == FileSystemEntityType.notFound) {
      return const <String>[];
    }
    if (dirType == FileSystemEntityType.link) {
      throw ShaderAssetException(
        'Refusing to list symlinked shaders directory.',
        pathOrKey: shadersDirectory.path,
      );
    }
    if (dirType != FileSystemEntityType.directory) {
      throw ShaderAssetException(
        'Shaders path is not a directory.',
        pathOrKey: shadersDirectory.path,
      );
    }
    final files = <String>[];
    await for (final entity in shadersDirectory.list(followLinks: false)) {
      if (entity is File && isSupportedShaderFilename(entity.path)) {
        files.add(entity.path);
      }
    }
    files.sort();
    return files.isEmpty ? const <String>[] : List<String>.unmodifiable(files);
  }

  @override
  Future<void> saveShaderSource(String name, String glslSource) async {
    validateShaderSource(glslSource, pathOrKey: name);
    final safeName = _validateChildFilename(name);
    if (!isSupportedShaderFilename(safeName)) {
      throw ShaderAssetException(
        'Unsupported shader filename extension; expected .glsl or .frag.',
        pathOrKey: name,
      );
    }
    await _ensureShadersDirectoryAsync();
    final targetPath = p.join(shadersDirectory.path, safeName);
    await _rejectSymlinkAsync(targetPath);
    await File(targetPath).writeAsString(glslSource, flush: true);
  }

  @override
  Future<void> saveWallpaperBytes(String key, Uint8List bytes) async {
    validateWallpaperBytes(bytes, pathOrKey: key);
    final trimmed = _normalizeNonEmptyPath(key);
    final String targetPath;
    if (p.isAbsolute(trimmed)) {
      await _rejectSymlinkAsync(p.dirname(trimmed));
      await Directory(p.dirname(trimmed)).create(recursive: true);
      targetPath = trimmed;
    } else {
      final safeName = _validateChildFilename(trimmed);
      await _ensureShadersDirectoryAsync();
      targetPath = p.join(shadersDirectory.path, safeName);
    }
    await _rejectSymlinkAsync(targetPath);
    await File(targetPath).writeAsBytes(bytes, flush: true);
  }

  @override
  Stream<ShaderDirectoryChange> watchShaderDirectory() {
    if (_disposed) {
      return const Stream<ShaderDirectoryChange>.empty();
    }
    late final _DirectoryWatchSession session;
    session = _DirectoryWatchSession(
      directory: shadersDirectory,
      debounce: watchDebounce,
      ensureDirectory: _ensureShadersDirectoryAsync,
      onClosed: () => _activeWatchers.remove(session),
    );
    _activeWatchers.add(session);
    return session.stream;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final sessions = _activeWatchers.toList(growable: false);
    _activeWatchers.clear();
    for (final session in sessions) {
      unawaited(session.close());
    }
  }

  String _normalizeNonEmptyPath(String pathOrKey) {
    final trimmed = pathOrKey.trim();
    if (trimmed.isEmpty) {
      throw ShaderAssetException(
        'Asset path must not be empty.',
        pathOrKey: pathOrKey,
      );
    }
    return trimmed;
  }

  String _resolveShaderTargetPath(String pathOrKey) {
    final trimmed = _normalizeNonEmptyPath(pathOrKey);
    if (p.isAbsolute(trimmed)) {
      return trimmed;
    }
    final safeName = _validateChildFilename(trimmed);
    return p.join(shadersDirectory.path, safeName);
  }

  String _validateChildFilename(String raw) {
    final trimmed = _normalizeNonEmptyPath(raw);
    if (trimmed == '.' ||
        trimmed == '..' ||
        trimmed.contains('/') ||
        trimmed.contains('\\')) {
      throw ShaderAssetException(
        'Asset filename must not contain path separators or traversal.',
        pathOrKey: raw,
      );
    }
    return trimmed;
  }

  Future<File> _resolveReadableFile(String targetPath) async {
    await _rejectSymlinkAsync(p.dirname(targetPath));
    final entityType = await FileSystemEntity.type(
      targetPath,
      followLinks: false,
    );
    if (entityType == FileSystemEntityType.link) {
      throw ShaderAssetException(
        'Refusing to read symlinked shader asset.',
        pathOrKey: targetPath,
      );
    }
    if (entityType != FileSystemEntityType.file) {
      throw ShaderAssetException(
        'Shader asset file does not exist.',
        pathOrKey: targetPath,
      );
    }
    return File(targetPath);
  }

  Future<void> _ensureShadersDirectoryAsync() async {
    final dirType = await FileSystemEntity.type(
      shadersDirectory.path,
      followLinks: false,
    );
    if (dirType == FileSystemEntityType.link) {
      throw ShaderAssetException(
        'Refusing to use symlinked shaders directory.',
        pathOrKey: shadersDirectory.path,
      );
    }
    if (dirType == FileSystemEntityType.notFound) {
      await shadersDirectory.create(recursive: true);
    } else if (dirType != FileSystemEntityType.directory) {
      throw ShaderAssetException(
        'Shaders path exists and is not a directory.',
        pathOrKey: shadersDirectory.path,
      );
    }
  }

  static Future<void> _rejectSymlinkAsync(String path) async {
    final entityType = await FileSystemEntity.type(path, followLinks: false);
    if (entityType == FileSystemEntityType.link) {
      throw ShaderAssetException(
        'Refusing to access symlinked path.',
        pathOrKey: path,
      );
    }
  }
}

final class _DirectoryWatchSession {
  final Directory directory;
  final Duration debounce;
  final Future<void> Function() ensureDirectory;
  final void Function() onClosed;

  late final StreamController<ShaderDirectoryChange> _controller =
      StreamController<ShaderDirectoryChange>(
        onListen: _start,
        onCancel: close,
      );

  StreamSubscription<FileSystemEvent>? _subscription;
  Timer? _debounceTimer;
  final Set<String> _pendingPaths = <String>{};
  bool _closed = false;

  _DirectoryWatchSession({
    required this.directory,
    required this.debounce,
    required this.ensureDirectory,
    required this.onClosed,
  });

  Stream<ShaderDirectoryChange> get stream => _controller.stream;

  void _start() {
    unawaited(_startAsync());
  }

  Future<void> _startAsync() async {
    try {
      await ensureDirectory();
      if (_closed) return;
      _subscription = directory.watch().listen(
        _handleEvent,
        onError: (Object error, StackTrace stackTrace) {
          if (!_closed && !_controller.isClosed) {
            _controller.addError(error, stackTrace);
          }
        },
      );
    } on Object catch (error, stackTrace) {
      if (!_closed && !_controller.isClosed) {
        _controller.addError(error, stackTrace);
        await close();
      }
    }
  }

  void _handleEvent(FileSystemEvent event) {
    if (_closed) return;
    var matched = false;
    if (isSupportedShaderFilename(event.path)) {
      _pendingPaths.add(event.path);
      matched = true;
    }
    if (event case FileSystemMoveEvent(:final String? destination)
        when destination != null && isSupportedShaderFilename(destination)) {
      _pendingPaths.add(destination);
      matched = true;
    }
    if (!matched) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, _flushPending);
  }

  void _flushPending() {
    _debounceTimer = null;
    if (_closed || _pendingPaths.isEmpty || _controller.isClosed) return;
    final paths = _pendingPaths.toList()..sort();
    _pendingPaths.clear();
    _controller.add(ShaderDirectoryChange(paths: paths));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _pendingPaths.clear();
    final sub = _subscription;
    _subscription = null;
    if (sub != null) {
      await sub.cancel();
    }
    onClosed();
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }
}

final class _NoopIoShaderProfileStore implements ShaderProfileStore {
  const _NoopIoShaderProfileStore();

  @override
  String? get shadersDirectoryPath => null;

  @override
  Future<Uint8List> loadWallpaperBytes(String pathOrKey) => Future.error(
    ShaderAssetException(
      'Shader profile storage is disabled in test or headless mode.',
      pathOrKey: pathOrKey,
    ),
  );

  @override
  Future<String> loadShaderSource(String pathOrKey) => Future.error(
    ShaderAssetException(
      'Shader profile storage is disabled in test or headless mode.',
      pathOrKey: pathOrKey,
    ),
  );

  @override
  Future<List<String>> listShaderFiles() =>
      Future<List<String>>.value(const <String>[]);

  @override
  Future<void> saveShaderSource(String name, String glslSource) async {
    validateShaderSource(glslSource, pathOrKey: name);
  }

  @override
  Future<void> saveWallpaperBytes(String key, Uint8List bytes) async {
    validateWallpaperBytes(bytes, pathOrKey: key);
  }

  @override
  Stream<ShaderDirectoryChange> watchShaderDirectory() =>
      const Stream<ShaderDirectoryChange>.empty();

  @override
  void dispose() {}
}
