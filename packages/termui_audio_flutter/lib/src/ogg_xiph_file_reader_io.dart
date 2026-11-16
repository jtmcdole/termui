import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'ogg_xiph_detector.dart';

/// Probes [path] for an Ogg Opus or Ogg FLAC header and returns the full file
/// bytes only when detected, or `null` otherwise.
Future<Uint8List?> readOggXiphFileBytes(String path) async {
  RandomAccessFile? raf;
  try {
    raf = await File(path).open();
    final length = await raf.length();
    if (length < 35) {
      return null;
    }

    final headerLength = math.min(length, oggXiphProbeMaxBytes);
    final header = await raf.read(headerLength);
    if (!isOggXiphBytes(header)) {
      return null;
    }
    if (header.length == length) {
      return header;
    }

    final full = Uint8List(length)..setRange(0, header.length, header);
    var offset = header.length;
    while (offset < length) {
      final read = await raf.readInto(full, offset, length);
      if (read <= 0) {
        return null;
      }
      offset += read;
    }
    return full;
  } on FileSystemException {
    return null;
  } finally {
    await raf?.close();
  }
}
