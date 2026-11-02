import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'repository.dart';

final class IoSavedCastsRepository implements SavedCastsRepository {
  final String storeName;

  IoSavedCastsRepository(this.storeName) {
    _validateFileName(storeName, 'storeName');
  }

  Directory get _dir => Directory('saved_$storeName');

  static void _validateFileName(String name, [String paramName = 'name']) {
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains(r'\')) {
      throw ArgumentError.value(name, paramName, 'Invalid file name');
    }
  }

  static bool _isSupportedCastPath(String path) =>
      path.endsWith('.cast') ||
      path.endsWith('.cast.gz') ||
      path.endsWith('.json') ||
      path.endsWith('.json.gz') ||
      path.endsWith('.gz');

  File _resolveFile(String name) {
    _validateFileName(name);
    return File('${_dir.path}/$name');
  }

  Future<void> _ensureDir() async {
    if (!await _dir.exists()) {
      await _dir.create(recursive: true);
    }
  }

  @override
  Future<List<String>> listCasts() async {
    if (!await _dir.exists()) return [];
    try {
      final list = <String>[];
      await for (final entity in _dir.list()) {
        if (entity is File && _isSupportedCastPath(entity.path)) {
          list.add(entity.uri.pathSegments.last);
        }
      }
      list.sort();
      return list;
    } on PathNotFoundException {
      return [];
    }
  }

  @override
  Future<String?> loadCast(String name) async {
    final file = _resolveFile(name);
    if (!await file.exists()) return null;
    try {
      return await file.readAsString();
    } on PathNotFoundException {
      return null;
    }
  }

  @override
  Future<void> saveCast(String name, String content) async {
    final file = _resolveFile(name);
    await _ensureDir();
    await file.writeAsString(content);
  }

  @override
  Future<void> deleteCast(String name) async {
    final file = _resolveFile(name);
    if (!await file.exists()) return;
    try {
      await file.delete();
    } on PathNotFoundException {
      // Already deleted concurrently.
    }
  }

  @override
  Future<Uint8List?> loadBytes(String name) async {
    final file = _resolveFile(name);
    if (!await file.exists()) return null;
    try {
      return await file.readAsBytes();
    } on PathNotFoundException {
      return null;
    }
  }

  @override
  Future<void> saveBytes(String name, Uint8List content) async {
    final file = _resolveFile(name);
    await _ensureDir();
    await file.writeAsBytes(content);
  }
}

SavedCastsRepository createRepository([String storeName = 'casts']) =>
    IoSavedCastsRepository(storeName);
