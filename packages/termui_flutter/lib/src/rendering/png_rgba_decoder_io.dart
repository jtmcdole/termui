import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'png_rgba_decoder.dart';

const int _isolateOffloadThresholdBytes = 64 * 1024;

final class _ZlibOverflowException implements Exception {
  const _ZlibOverflowException();
}

final class _BoundedZlibSink extends ByteConversionSinkBase {
  final int maxBytes;
  final BytesBuilder _builder = BytesBuilder(copy: false);

  _BoundedZlibSink(this.maxBytes);

  @override
  void add(List<int> chunk) {
    if (_builder.length + chunk.length > maxBytes) {
      _builder.clear();
      throw const _ZlibOverflowException();
    }
    _builder.add(chunk);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _builder.takeBytes();
}

Uint8List? _inflateZlibBounded(Uint8List compressed, int maxBytes) {
  try {
    final sink = _BoundedZlibSink(maxBytes);
    zlib.decoder.startChunkedConversion(sink)
      ..add(compressed)
      ..close();
    return sink.takeBytes();
  } on Object {
    return null;
  }
}

DecodedPngRgba? _decodeOnCurrentIsolate(Uint8List pngBytes) =>
    decodePngBytesToRgba(pngBytes, inflateZlib: _inflateZlibBounded);

/// Decodes [pngBytes] into CPU straight RGBA8888 pixels using `dart:io` `zlib`,
/// offloading larger payloads to a background worker isolate.
Future<DecodedPngRgba?> decodePlatformPngToRgbaAsync(Uint8List pngBytes) async {
  if (pngBytes.length >= _isolateOffloadThresholdBytes) {
    return Isolate.run(() => _decodeOnCurrentIsolate(pngBytes));
  }
  return _decodeOnCurrentIsolate(pngBytes);
}
