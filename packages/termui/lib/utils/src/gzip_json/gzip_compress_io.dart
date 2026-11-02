import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

const int _defaultMaxDecompressedBytes = 256 * 1024 * 1024;

/// Compresses a string into a GZip compressed byte array.
Future<Uint8List> compressString(String input) async {
  return Isolate.run(() => _compressStringSync(input));
}

/// Compresses a byte array into a GZip compressed byte array.
Future<Uint8List> compressBytes(Uint8List input) async {
  return Isolate.run(() => _compressBytesSync(input));
}

/// Decompresses a GZip compressed byte array into a string.
Future<String> decompressString(
  Uint8List input, {
  int maxDecompressedBytes = _defaultMaxDecompressedBytes,
}) async {
  return Isolate.run(() => _decompressStringSync(input, maxDecompressedBytes));
}

/// Decompresses a GZip compressed byte array into a byte array.
Future<Uint8List> decompressBytes(
  Uint8List input, {
  int maxDecompressedBytes = _defaultMaxDecompressedBytes,
}) async {
  return Isolate.run(() => _decompressBytesSync(input, maxDecompressedBytes));
}

/// Decompresses a GZip compressed byte array with a maximum output size cap.
Future<Uint8List> decompressGzip(
  Uint8List input, {
  int maxDecompressedBytes = _defaultMaxDecompressedBytes,
}) => decompressBytes(input, maxDecompressedBytes: maxDecompressedBytes);

Uint8List _compressStringSync(String input) {
  final bytes = utf8.encode(input);
  return Uint8List.fromList(gzip.encode(bytes));
}

Uint8List _compressBytesSync(Uint8List input) {
  return Uint8List.fromList(gzip.encode(input));
}

String _decompressStringSync(Uint8List input, int maxDecompressedBytes) {
  final decompressed = _decompressBytesSync(input, maxDecompressedBytes);
  return utf8.decode(decompressed);
}

Uint8List _decompressBytesSync(Uint8List input, int maxDecompressedBytes) {
  if (maxDecompressedBytes < 0) {
    throw FormatException(
      'GZip decompressed size exceeds limit of $maxDecompressedBytes bytes.',
    );
  }
  final outSink = _BoundedByteSink(maxDecompressedBytes);
  final inSink = gzip.decoder.startChunkedConversion(outSink);
  const chunkSize = 64 * 1024;
  for (var offset = 0; offset < input.length; offset += chunkSize) {
    final end = offset + chunkSize < input.length
        ? offset + chunkSize
        : input.length;
    inSink.addSlice(input, offset, end, false);
  }
  inSink.close();
  return outSink.builder.takeBytes();
}

final class _BoundedByteSink implements Sink<List<int>> {
  final int maxBytes;
  final BytesBuilder builder = BytesBuilder(copy: false);
  int _total = 0;

  _BoundedByteSink(this.maxBytes);

  @override
  void add(List<int> data) {
    _total += data.length;
    if (_total > maxBytes) {
      throw FormatException(
        'GZip decompressed size exceeds limit of $maxBytes bytes.',
      );
    }
    builder.add(data);
  }

  @override
  void close() {}
}
