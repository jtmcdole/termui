import 'dart:typed_data';
import 'repository_stub.dart'
    if (dart.library.js_interop) 'repository_web.dart'
    if (dart.library.io) 'repository_io.dart'
    as impl;

/// Cross-platform repository for saving, loading, listing, and deleting asciicasts.
abstract interface class SavedCastsRepository {
  factory SavedCastsRepository({String storeName = 'casts'}) =>
      impl.createRepository(storeName);

  /// Lists the names of all saved casts.
  Future<List<String>> listCasts();

  /// Loads the raw cast data string by name.
  Future<String?> loadCast(String name);

  /// Saves the raw cast data string by name.
  Future<void> saveCast(String name, String content);

  /// Deletes a saved cast by name.
  Future<void> deleteCast(String name);

  /// Loads raw bytes by name.
  Future<Uint8List?> loadBytes(String name);

  /// Saves raw bytes by name.
  Future<void> saveBytes(String name, Uint8List content);
}
