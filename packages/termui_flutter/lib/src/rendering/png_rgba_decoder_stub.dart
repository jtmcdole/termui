import 'dart:typed_data';

import 'png_rgba_decoder.dart';

/// Web stub returning `null` so PNG decoding uses the browser codec directly.
Future<DecodedPngRgba?> decodePlatformPngToRgbaAsync(
  Uint8List pngBytes,
) async => null;
