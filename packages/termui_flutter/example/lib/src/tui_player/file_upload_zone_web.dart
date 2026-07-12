import 'dart:async';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'package:cross_file/cross_file.dart';

void Function() setupWebDropZone({
  required void Function(bool isDragging) onDragStateChanged,
  required void Function(Map<String, XFile> files) onFilesSelected,
}) {
  // Prevent defaults for drag/drop
  void preventDefaults(web.Event e) {
    e.preventDefault();
    e.stopPropagation();
  }

  final dragEnterListener = (web.Event e) {
    preventDefaults(e);
    onDragStateChanged(true);
  }.toJS;

  final dragOverListener = (web.Event e) {
    preventDefaults(e);
  }.toJS;

  final dragLeaveListener = (web.Event e) {
    preventDefaults(e);
    final dragEvent = e as web.MouseEvent;
    if (dragEvent.relatedTarget == null) {
      onDragStateChanged(false);
    }
  }.toJS;

  final dropListener = (web.Event e) {
    preventDefaults(e);
    onDragStateChanged(false);

    final dragEvent = e as web.DragEvent;
    final dataTransfer = dragEvent.dataTransfer;
    if (dataTransfer == null) return;

    final files = dataTransfer.files;
    final count = files.length;
    if (count == 0) return;

    final futures = <Future<(String, XFile)>>[];

    for (var i = 0; i < count; i++) {
      final file = files.item(i);
      if (file == null) continue;

      final completer = Completer<(String, XFile)>();
      final reader = web.FileReader();

      reader.onload = (web.Event ev) {
        final result = reader.result;
        if (result != null) {
          final arrayBuffer = result as JSArrayBuffer;
          final uint8List = arrayBuffer.toDart.asUint8List();
          completer.complete((
            file.name,
            XFile.fromData(uint8List, name: file.name),
          ));
        } else {
          completer.completeError(
            StateError('Failed to read file contents: ${file.name}'),
          );
        }
      }.toJS;

      reader.onerror = (web.Event ev) {
        completer.completeError(
          StateError('FileReader error occurred for: ${file.name}'),
        );
      }.toJS;

      reader.readAsArrayBuffer(file);
      futures.add(completer.future);
    }

    Future.wait(futures)
        .then((entries) {
          final filesMap = <String, XFile>{
            for (final (name, xFile) in entries) name: xFile,
          };
          onFilesSelected(filesMap);
        })
        .catchError((Object error) {
          // ignore: avoid_print
          print('[FileUploadZone] Error reading dropped files: $error');
        });
  }.toJS;

  // Register listeners on window
  web.window.addEventListener('dragenter', dragEnterListener);
  web.window.addEventListener('dragover', dragOverListener);
  web.window.addEventListener('dragleave', dragLeaveListener);
  web.window.addEventListener('drop', dropListener);

  return () {
    web.window.removeEventListener('dragenter', dragEnterListener);
    web.window.removeEventListener('dragover', dragOverListener);
    web.window.removeEventListener('dragleave', dragLeaveListener);
    web.window.removeEventListener('drop', dropListener);
  };
}
