// ignore_for_file: invalid_runtime_check_with_js_interop_types
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'package:idb_shim/idb_browser.dart';
import 'package:web/web.dart' as web;

@JS('self')
external JSObject get globalScopeSelf;

void main() async {
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

  globalScopeSelf.setProperty(
    'onmessage'.toJS,
    ((web.MessageEvent e) {
      // async wrapper
      Future<void> handleMessage() async {
        final jsData = e.getProperty('data'.toJS) as JSObject?;
        if (jsData == null) return;

        final action = jsData.getProperty('action'.toJS).dartify() as String?;
        final path = jsData.getProperty('path'.toJS).dartify() as String?;

        if (action == 'load' && path != null) {
          try {
            // Check IndexedDB cache first
            final readTxn = db.transaction('assets', 'readonly');
            final store = readTxn.objectStore('assets');
            final cachedData = await store.getObject(path);
            await readTxn.completed;

            if (cachedData != null && cachedData is Uint8List) {
              final obj = JSObject();
              obj['action'] = 'loaded'.toJS;
              obj['path'] = path.toJS;
              obj['bytes'] =
                  cachedData.buffer.toJS; // Send underlying JSArrayBuffer
              globalContext.callMethod('postMessage'.toJS, obj);
              return;
            }

            // Cache Miss: Fetch file over HTTP
            final fetchPromise = globalScopeSelf.callMethod(
              'fetch'.toJS,
              path.toJS,
            );
            final response =
                (await (fetchPromise as JSPromise).toDart) as web.Response;
            if (response.status != 200) {
              throw Exception('HTTP error! status: ${response.status}');
            }

            final arrayBufferPromise = response.arrayBuffer();
            final arrayBuffer = await arrayBufferPromise.toDart;

            final obj = JSObject();
            obj['action'] = 'loaded'.toJS;
            obj['path'] = path.toJS;
            obj['bytes'] = arrayBuffer; // Send JSArrayBuffer directly!

            globalContext.callMethod('postMessage'.toJS, obj);

            // Also save to indexeddb
            final bytes = arrayBuffer.toDart.asUint8List();

            final writeTxn = db.transaction('assets', 'readwrite');
            final writeStore = writeTxn.objectStore('assets');
            await writeStore.put(bytes, path);
            await writeTxn.completed;
          } catch (err) {
            print('Worker error: $err');
            final errObj = JSObject();
            errObj['action'] = 'error'.toJS;
            errObj['path'] = path.toJS;
            errObj['error'] = err.toString().toJS;
            globalContext.callMethod('postMessage'.toJS, errObj);
          }
        }
      }

      handleMessage();
    }).toJS,
  );
}
