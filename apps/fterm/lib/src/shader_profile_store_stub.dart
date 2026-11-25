import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'shader_profile_store.dart';

/// Creates the fallback no-op [ShaderProfileStore] for unsupported platforms.
ShaderProfileStore createPlatformShaderProfileStore() =>
    const _NoopShaderProfileStore();

/// Canonicalizes [rawPath] lexically on unsupported platforms.
String resolveCanonicalShaderPath(String rawPath) => p.canonicalize(rawPath);

final class _NoopShaderProfileStore implements ShaderProfileStore {
  const _NoopShaderProfileStore();

  @override
  String? get shadersDirectoryPath => null;

  @override
  Future<Uint8List> loadWallpaperBytes(String pathOrKey) => Future.error(
    ShaderAssetException(
      'Shader profile storage is unavailable on this platform.',
      pathOrKey: pathOrKey,
    ),
  );

  @override
  Future<String> loadShaderSource(String pathOrKey) => Future.error(
    ShaderAssetException(
      'Shader profile storage is unavailable on this platform.',
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
