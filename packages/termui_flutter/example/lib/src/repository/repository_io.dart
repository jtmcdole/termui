import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'repository.dart';

class IoSavedCastsRepository implements SavedCastsRepository {
  Directory get _dir => Directory('saved_casts');

  Future<void> _ensureDir() async {
    if (!await _dir.exists()) {
      await _dir.create(recursive: true);
    }
  }

  @override
  Future<List<String>> listCasts() async {
    try {
      await _ensureDir();
      final list = <String>[];
      await for (final entity in _dir.list()) {
        if (entity is File &&
            (entity.path.endsWith('.cast') ||
                entity.path.endsWith('.cast.gz') ||
                entity.path.endsWith('.gz'))) {
          list.add(entity.uri.pathSegments.last);
        }
      }
      // Sort alphabetically
      list.sort();
      return list;
    } catch (_) {
      return [];
    }
  }

  @override
  Future<String?> loadCast(String name) async {
    try {
      await _ensureDir();
      final file = File('${_dir.path}/$name');
      if (await file.exists()) {
        return await file.readAsString();
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<void> saveCast(String name, String content) async {
    await _ensureDir();
    final file = File('${_dir.path}/$name');
    await file.writeAsString(content);
  }

  @override
  Future<void> deleteCast(String name) async {
    try {
      await _ensureDir();
      final file = File('${_dir.path}/$name');
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  @override
  Future<Uint8List?> loadBytes(String name) async {
    try {
      await _ensureDir();
      final file = File('${_dir.path}/$name');
      if (await file.exists()) {
        return await file.readAsBytes();
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<void> saveBytes(String name, Uint8List content) async {
    await _ensureDir();
    final file = File('${_dir.path}/$name');
    await file.writeAsBytes(content);
  }
}

SavedCastsRepository createRepository() => IoSavedCastsRepository();
