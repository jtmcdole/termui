import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'shader_profile_store.dart';

/// Maximum raw wallpaper byte size persisted in browser `localStorage`
/// (`2 MiB`, keeping base64 encoding safely within typical `5 MiB` origin
/// storage quotas).
const int maxWebWallpaperBytes = 2 * 1024 * 1024;

const String _wallpaperKeyPrefix = 'fterm.shader_profile.wallpaper.v1.';
const String _shaderKeyPrefix = 'fterm.shader_profile.glsl.v1.';
const String _shaderIndexKey = 'fterm.shader_profile.glsl_index.v1';

/// Creates the Web `window.localStorage`-backed [ShaderProfileStore].
ShaderProfileStore createPlatformShaderProfileStore() =>
    _WebShaderProfileStore();

final class _WebShaderProfileStore implements ShaderProfileStore {
  final StreamController<ShaderDirectoryChange> _changes =
      StreamController<ShaderDirectoryChange>.broadcast();
  bool _disposed = false;

  @override
  String? get shadersDirectoryPath => null;

  @override
  Future<Uint8List> loadWallpaperBytes(String pathOrKey) async {
    final normalizedKey = _normalizeKey(pathOrKey);
    final raw = _safeGetItem('$_wallpaperKeyPrefix$normalizedKey');
    if (raw == null || raw.isEmpty) {
      throw ShaderAssetException(
        'Wallpaper not found in browser storage.',
        pathOrKey: normalizedKey,
      );
    }
    try {
      final bytes = base64Decode(raw);
      validateWallpaperBytes(bytes, pathOrKey: normalizedKey);
      return bytes;
    } on FormatException catch (error) {
      throw ShaderAssetException(
        'Corrupt base64 wallpaper in browser storage: ${error.message}',
        pathOrKey: normalizedKey,
      );
    }
  }

  @override
  Future<String> loadShaderSource(String pathOrKey) async {
    final normalizedKey = _normalizeKey(pathOrKey);
    final raw = _safeGetItem('$_shaderKeyPrefix$normalizedKey');
    if (raw == null) {
      throw ShaderAssetException(
        'Shader source not found in browser storage.',
        pathOrKey: normalizedKey,
      );
    }
    validateShaderSource(raw, pathOrKey: normalizedKey);
    return raw;
  }

  @override
  Future<List<String>> listShaderFiles() async {
    final names = _readShaderIndex()..sort();
    return names.isEmpty ? const <String>[] : List<String>.unmodifiable(names);
  }

  @override
  Future<void> saveShaderSource(String name, String glslSource) async {
    final normalizedName = _normalizeKey(name);
    validateShaderSource(glslSource, pathOrKey: normalizedName);
    _safeSetItem('$_shaderKeyPrefix$normalizedName', glslSource);
    final index = _readShaderIndex();
    if (!index.contains(normalizedName)) {
      index
        ..add(normalizedName)
        ..sort();
      _safeSetItem(_shaderIndexKey, jsonEncode(index));
    }
    if (!_disposed && !_changes.isClosed) {
      _changes.add(ShaderDirectoryChange(paths: <String>[normalizedName]));
    }
  }

  @override
  Future<void> saveWallpaperBytes(String key, Uint8List bytes) async {
    final normalizedKey = _normalizeKey(key);
    validateWallpaperBytes(bytes, pathOrKey: normalizedKey);
    if (bytes.length > maxWebWallpaperBytes) {
      throw ShaderAssetException(
        'Wallpaper image exceeds the $maxWebWallpaperBytes-byte (2 MiB) '
        'browser storage limit (${bytes.length} bytes).',
        pathOrKey: normalizedKey,
      );
    }
    _safeSetItem('$_wallpaperKeyPrefix$normalizedKey', base64Encode(bytes));
  }

  @override
  Stream<ShaderDirectoryChange> watchShaderDirectory() =>
      _disposed ? const Stream<ShaderDirectoryChange>.empty() : _changes.stream;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (!_changes.isClosed) {
      unawaited(_changes.close());
    }
  }

  String _normalizeKey(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw ShaderAssetException(
        'Asset key must not be empty.',
        pathOrKey: raw,
      );
    }
    return trimmed;
  }

  List<String> _readShaderIndex() {
    final raw = _safeGetItem(_shaderIndexKey);
    if (raw == null || raw.isEmpty) return <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List<Object?>) return <String>[];
      return <String>[
        for (final item in decoded)
          if (item case final String name when name.trim().isNotEmpty)
            name.trim(),
      ];
    } on Object {
      return <String>[];
    }
  }

  String? _safeGetItem(String key) {
    try {
      return web.window.localStorage.getItem(key);
    } on Object {
      return null;
    }
  }

  void _safeSetItem(String key, String value) {
    try {
      web.window.localStorage.setItem(key, value);
    } on Object {
      // Ignore SecurityError / QuotaExceededError in restricted browsing modes.
    }
  }
}
