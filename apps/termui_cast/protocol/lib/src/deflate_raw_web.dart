import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Compresses [input] with raw RFC 1951 deflate at level 1 on web/WASM.
Uint8List compressDeflateRawLevel1(Uint8List input) =>
    Deflate(input, level: 1).getBytes();
