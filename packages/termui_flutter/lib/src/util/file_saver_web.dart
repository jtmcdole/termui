import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

/// Saves the given [bytes] to a file with the specified [basename].
Future<String?> saveFile(String basename, List<int> bytes) async {
  final uint8Bytes = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  String mimeType = 'application/octet-stream';
  if (basename.endsWith('.png')) {
    mimeType = 'image/png';
  } else if (basename.endsWith('.json') || basename.endsWith('.jsonl')) {
    mimeType = 'application/json';
  } else if (basename.endsWith('.cast')) {
    mimeType = 'text/plain';
  }

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
