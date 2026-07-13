import 'dart:async';
import 'dart:typed_data';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'repository.dart';

class WebSavedCastsRepository implements SavedCastsRepository {
  static const String dbName = 'termui_player_db';
  static const int dbVersion = 1;
  static const String storeName = 'casts';

  Future<web.IDBDatabase> _openDb() {
    final completer = Completer<web.IDBDatabase>();
    final request = web.window.indexedDB.open(dbName, dbVersion);

    request.onupgradeneeded = (web.IDBVersionChangeEvent event) {
      final db = request.result as web.IDBDatabase;
      db.createObjectStore(storeName);
    }.toJS;

    request.onsuccess = (web.Event event) {
      completer.complete(request.result as web.IDBDatabase);
    }.toJS;

    request.onerror = (web.Event event) {
      completer.completeError(Exception('Failed to open IndexedDB'));
    }.toJS;

    return completer.future;
  }

  @override
  Future<List<String>> listCasts() async {
    try {
      final db = await _openDb();
      final completer = Completer<List<String>>();

      final transaction = db.transaction([storeName.toJS].toJS, 'readonly');
      final store = transaction.objectStore(storeName);
      final request = store.getAllKeys();

      request.onsuccess = (web.Event event) {
        final jsArray = request.result as JSArray;
        final keys = jsArray.toDart.map((e) => (e as JSString).toDart).toList();
        completer.complete(keys);
      }.toJS;

      request.onerror = (web.Event event) {
        completer.completeError(
          Exception('Failed to list keys from IndexedDB'),
        );
      }.toJS;

      return completer.future;
    } catch (e) {
      return [];
    }
  }

  @override
  Future<String?> loadCast(String name) async {
    try {
      final db = await _openDb();
      final completer = Completer<String?>();

      final transaction = db.transaction([storeName.toJS].toJS, 'readonly');
      final store = transaction.objectStore(storeName);
      final request = store.get(name.toJS);

      request.onsuccess = (web.Event event) {
        final result = request.result;
        if (result == null) {
          completer.complete(null);
        } else {
          completer.complete((result as JSString).toDart);
        }
      }.toJS;

      request.onerror = (web.Event event) {
        completer.completeError(Exception('Failed to load from IndexedDB'));
      }.toJS;

      return completer.future;
    } catch (e) {
      return null;
    }
  }

  @override
  Future<void> saveCast(String name, String content) async {
    final db = await _openDb();
    final completer = Completer<void>();

    final transaction = db.transaction([storeName.toJS].toJS, 'readwrite');
    final store = transaction.objectStore(storeName);
    final request = store.put(content.toJS, name.toJS);

    request.onsuccess = (web.Event event) {
      completer.complete();
    }.toJS;

    request.onerror = (web.Event event) {
      completer.completeError(Exception('Failed to save to IndexedDB'));
    }.toJS;

    return completer.future;
  }

  @override
  Future<void> deleteCast(String name) async {
    final db = await _openDb();
    final completer = Completer<void>();

    final transaction = db.transaction([storeName.toJS].toJS, 'readwrite');
    final store = transaction.objectStore(storeName);
    final request = store.delete(name.toJS);

    request.onsuccess = (web.Event event) {
      completer.complete();
    }.toJS;

    request.onerror = (web.Event event) {
      completer.completeError(Exception('Failed to delete from IndexedDB'));
    }.toJS;

    return completer.future;
  }

  @override
  Future<Uint8List?> loadBytes(String name) async {
    try {
      final db = await _openDb();
      final completer = Completer<Uint8List?>();

      final transaction = db.transaction([storeName.toJS].toJS, 'readonly');
      final store = transaction.objectStore(storeName);
      final request = store.get(name.toJS);

      request.onsuccess = (web.Event event) {
        final result = request.result;
        if (result == null) {
          completer.complete(null);
        } else {
          if (result.typeofEquals('string')) {
            // Legacy fallback for strings
            final str = (result as JSString).toDart;
            completer.complete(Uint8List.fromList(str.codeUnits));
          } else {
            completer.complete((result as JSUint8Array).toDart);
          }
        }
      }.toJS;

      request.onerror = (web.Event event) {
        completer.completeError(
          Exception('Failed to load bytes from IndexedDB'),
        );
      }.toJS;

      return completer.future;
    } catch (e) {
      return null;
    }
  }

  @override
  Future<void> saveBytes(String name, Uint8List content) async {
    final db = await _openDb();
    final completer = Completer<void>();

    final transaction = db.transaction([storeName.toJS].toJS, 'readwrite');
    final store = transaction.objectStore(storeName);
    final request = store.put(content.toJS, name.toJS);

    request.onsuccess = (web.Event event) {
      completer.complete();
    }.toJS;

    request.onerror = (web.Event event) {
      completer.completeError(Exception('Failed to save bytes to IndexedDB'));
    }.toJS;

    return completer.future;
  }
}

SavedCastsRepository createRepository() => WebSavedCastsRepository();
