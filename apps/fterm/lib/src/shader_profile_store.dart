import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:path/path.dart' as p;

import 'shader_profile_store_stub.dart'
    if (dart.library.js_interop) 'shader_profile_store_web.dart'
    if (dart.library.io) 'shader_profile_store_io.dart'
    as impl;

/// Maximum permitted raw wallpaper file size in bytes (`16 MiB`).
const int maxWallpaperBytes = 16 * 1024 * 1024;

/// Maximum permitted custom `.glsl` / `.frag` source size in UTF-8 bytes
/// (`64 KiB`).
const int maxShaderSourceBytes = 64 * 1024;

/// Default debounce window used when coalescing rapid shader directory edits.
const Duration defaultShaderWatchDebounce = Duration(milliseconds: 150);

/// Supported custom fragment shader filename extensions (lowercase).
const Set<String> supportedShaderExtensions = <String>{'.glsl', '.frag'};

/// Typed error thrown when validating, loading, or persisting a wallpaper or
/// custom shader asset fails.
final class ShaderAssetException implements Exception {
  /// Human-readable description of the validation or I/O failure.
  final String message;

  /// Optional filesystem path or Web storage key associated with the failure.
  final String? pathOrKey;

  /// Creates a [ShaderAssetException].
  const ShaderAssetException(this.message, {this.pathOrKey});

  @override
  String toString() => pathOrKey == null
      ? 'ShaderAssetException: $message'
      : 'ShaderAssetException($pathOrKey): $message';
}

/// Debounced notification emitted when one or more custom shader files in the
/// user's shaders directory change.
final class ShaderDirectoryChange {
  /// Sorted, deduplicated paths or keys of affected `.glsl` / `.frag` files.
  final List<String> paths;

  /// UTC timestamp when this debounced change batch was emitted.
  final DateTime timestamp;

  /// Creates an immutable [ShaderDirectoryChange] event.
  ShaderDirectoryChange({required List<String> paths, DateTime? timestamp})
    : paths = List<String>.unmodifiable(paths),
      timestamp = (timestamp ?? clock.now()).toUtc();
}

/// Platform seam for loading, saving, listing, and watching user-authored
/// fragment shaders and wallpaper images without blocking the UI isolate.
abstract interface class ShaderProfileStore {
  /// Absolute path to the desktop shaders directory, or `null` on Web/no-op
  /// stores.
  String? get shadersDirectoryPath;

  /// Asynchronously loads and validates wallpaper bytes (PNG, JPEG, or WebP,
  /// `<= 16 MiB`) from [pathOrKey].
  Future<Uint8List> loadWallpaperBytes(String pathOrKey);

  /// Asynchronously loads and validates UTF-8 GLSL source (`<= 64 KiB`) from
  /// [pathOrKey].
  Future<String> loadShaderSource(String pathOrKey);

  /// Lists available `.glsl` / `.frag` shader paths or keys in sorted order.
  Future<List<String>> listShaderFiles();

  /// Validates and persists custom shader [glslSource] under [name].
  Future<void> saveShaderSource(String name, String glslSource);

  /// Validates and persists wallpaper [bytes] under [key].
  Future<void> saveWallpaperBytes(String key, Uint8List bytes);

  /// Emits debounced [ShaderDirectoryChange] events whenever custom shader
  /// files are created, modified, moved, or deleted.
  Stream<ShaderDirectoryChange> watchShaderDirectory();

  /// Releases any active filesystem watchers, timers, or stream controllers.
  void dispose();
}

/// Creates the default platform [ShaderProfileStore] for the active runtime
/// (`~/.config/fterm/shaders/` or `%APPDATA%\fterm\shaders\` on desktop,
/// `window.localStorage` on Web, or a no-op store under `flutter test`).
ShaderProfileStore createPlatformShaderProfileStore() =>
    impl.createPlatformShaderProfileStore();

/// Canonicalizes [rawPath], resolving existing filesystem symlinks on desktop
/// platforms and falling back to lexical normalization when [rawPath] does not
/// exist on disk or when running on Web.
String resolveCanonicalShaderPath(String rawPath) =>
    impl.resolveCanonicalShaderPath(rawPath);

/// Returns whether [pathOrName] has a supported custom shader extension
/// (`.glsl` or `.frag`, case-insensitive).
bool isSupportedShaderFilename(String pathOrName) =>
    supportedShaderExtensions.contains(p.extension(pathOrName).toLowerCase());

/// Validates that [bytes] is non-empty, `<= 16 MiB`, and starts with a valid
/// PNG, JPEG, or WebP magic-byte header.
///
/// Throws [ShaderAssetException] when validation fails.
void validateWallpaperBytes(Uint8List bytes, {String? pathOrKey}) {
  if (bytes.isEmpty) {
    throw ShaderAssetException(
      'Wallpaper image data is empty.',
      pathOrKey: pathOrKey,
    );
  }
  if (bytes.length > maxWallpaperBytes) {
    throw ShaderAssetException(
      'Wallpaper image exceeds the $maxWallpaperBytes-byte (16 MiB) limit '
      '(${bytes.length} bytes).',
      pathOrKey: pathOrKey,
    );
  }
  if (_hasPngHeader(bytes) || _hasJpegHeader(bytes) || _hasWebpHeader(bytes)) {
    return;
  }
  throw ShaderAssetException(
    'Unsupported wallpaper image format; expected PNG, JPEG, or WebP.',
    pathOrKey: pathOrKey,
  );
}

/// Validates that raw UTF-8 shader source [bytes] does not exceed `64 KiB`.
///
/// Throws [ShaderAssetException] when [bytes] exceeds [maxShaderSourceBytes].
void validateShaderSourceBytes(Uint8List bytes, {String? pathOrKey}) {
  if (bytes.length > maxShaderSourceBytes) {
    throw ShaderAssetException(
      'Shader source exceeds the $maxShaderSourceBytes-byte (64 KiB) limit '
      '(${bytes.length} bytes).',
      pathOrKey: pathOrKey,
    );
  }
}

/// Validates that [glslSource] encodes to `<= 64 KiB` of UTF-8 bytes.
///
/// Throws [ShaderAssetException] when [glslSource] exceeds
/// [maxShaderSourceBytes].
void validateShaderSource(String glslSource, {String? pathOrKey}) {
  final encodedLength = utf8.encode(glslSource).length;
  if (encodedLength > maxShaderSourceBytes) {
    throw ShaderAssetException(
      'Shader source exceeds the $maxShaderSourceBytes-byte (64 KiB) limit '
      '($encodedLength bytes).',
      pathOrKey: pathOrKey,
    );
  }
}

bool _hasPngHeader(Uint8List bytes) {
  if (bytes.length < 8) return false;
  return bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0D &&
      bytes[5] == 0x0A &&
      bytes[6] == 0x1A &&
      bytes[7] == 0x0A;
}

bool _hasJpegHeader(Uint8List bytes) =>
    bytes.length >= 3 &&
    bytes[0] == 0xFF &&
    bytes[1] == 0xD8 &&
    bytes[2] == 0xFF;

bool _hasWebpHeader(Uint8List bytes) {
  if (bytes.length < 12) return false;
  return bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50;
}
