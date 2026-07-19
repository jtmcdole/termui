// ignore_for_file: invalid_runtime_check_with_js_interop_types
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'package:idb_shim/idb_browser.dart';
import 'package:web/web.dart' as web;

@JS('self')
external JSObject get globalScopeSelf;

void jsSendMessage(dynamic m) {
  globalContext.callMethod('postMessage'.toJS, (m as Object?).jsify());
}

Stream<T> callbackToStream<J, T>(
  JSObject object,
  String name,
  T Function(J jsValue) unwrapValue,
) {
  final controller = StreamController<T>.broadcast(sync: true);

  void eventFunction(JSAny event) {
    controller.add(unwrapValue(event as J));
  }

  object.setProperty(name.toJS, eventFunction.toJS);
  return controller.stream;
}

class Worker {
  Worker() {
    _outputController = StreamController();
    callbackToStream(globalScopeSelf, 'onmessage', (web.MessageEvent e) {
      final data = e.getProperty('data'.toJS);
      _outputController.add(data);
    });
  }
  late StreamController<dynamic> _outputController;

  Stream<dynamic> onReceive() => _outputController.stream;

  void sendMessage(dynamic message) {
    jsSendMessage(message);
  }
}

void main() async {
  final worker = Worker();

  // Initialize IndexedDB Virtual File System using idb_shim
  final idbFactory = idbFactoryBrowser;
  final db = await idbFactory.open(
    'termui_audio_cache',
    version: 1,
    onUpgradeNeeded: (event) {
      final db = event.database;
      db.createObjectStore('assets');
    },
  );

  worker.onReceive().listen((data) async {
    if (data is Map) {
      final action = data['action'] as String?;
      final path = data['path'] as String?;

      if (action == 'load' && path != null) {
        try {
          // Check IndexedDB cache (Cache Hit check)
          final readTxn = db.transaction('assets', 'readonly');
          final store = readTxn.objectStore('assets');
          final cachedData = await store.getObject(path);
          await readTxn.completed;

          if (cachedData != null && cachedData is Uint8List) {
            // Cache Hit: Send bytes back to main thread
            worker.sendMessage({
              'action': 'loaded',
              'path': path,
              'bytes': cachedData,
              'cached': true,
            });
            return;
          }

          // Cache Miss: Fetch file over HTTP
          final response = await web.window.fetch(path.toJS).toDart;
          if (!response.ok) {
            throw Exception('HTTP error! status: ${response.status}');
          }

          final arrayBuffer = await response.arrayBuffer().toDart;
          final bytes = arrayBuffer.toDart.asUint8List();

          // Write bytes to IndexedDB asynchronously
          final writeTxn = db.transaction('assets', 'readwrite');
          final writeStore = writeTxn.objectStore('assets');
          await writeStore.put(bytes, path);
          await writeTxn.completed;

          // Send fetched bytes back to main thread
          worker.sendMessage({
            'action': 'loaded',
            'path': path,
            'bytes': bytes,
            'cached': false,
          });
        } catch (e) {
          worker.sendMessage({
            'action': 'error',
            'path': path,
            'error': e.toString(),
          });
        }
      }
    }
  });
}
