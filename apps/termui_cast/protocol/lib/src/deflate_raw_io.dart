import 'dart:io';
import 'dart:typed_data';

final ZLibCodec _rawDeflateLevel1 = ZLibCodec(raw: true, level: 1);

/// Compresses [input] with raw RFC 1951 deflate at level 1 using `dart:io`.
Uint8List compressDeflateRawLevel1(Uint8List input) {
  final encoded = _rawDeflateLevel1.encode(input);
  return encoded is Uint8List ? encoded : Uint8List.fromList(encoded);
}
