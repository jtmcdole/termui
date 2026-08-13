import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

/// Saves the given [bytes] to a file with the specified [basename].
Future<String?> saveFile(String basename, List<int> bytes) async {
  final uint8Bytes = switch (bytes) {
    Uint8List u => u,
    _ => Uint8List.fromList(bytes),
  };
  final mimeType = switch (basename) {
    _ when basename.endsWith('.png') => 'image/png',
    _ when basename.endsWith('.json') || basename.endsWith('.jsonl') =>
      'application/json',
    _ when basename.endsWith('.cast') => 'text/plain',
    _ => 'application/octet-stream',
  };

  // Convert Dart Uint8List to JS Uint8Array
  final jsBytes = uint8Bytes.toJS;

  // Create Blob
  final blobParts = [jsBytes].toJS;
  final blobOptions = web.BlobPropertyBag(type: mimeType);
  final blob = web.Blob(blobParts, blobOptions);

  final url = web.URL.createObjectURL(blob);

  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = basename
    ..style.display = 'none';

  web.document.body?.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);

  return basename;
}
