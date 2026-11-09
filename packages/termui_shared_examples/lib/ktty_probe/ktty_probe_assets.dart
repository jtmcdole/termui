import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:termui/termui.dart';

/// Probe image ID for the Kitty Graphics `a=q` RGB24 query.
const int kttyProbeQueryId = 901;

/// Probe image ID for the Kitty Graphics raw RGBA (`f=32`) transmit check.
const int kttyProbeRgbaId = 902;

/// Probe image ID for the Kitty Graphics zlib-compressed (`o=z`) transmit check.
const int kttyProbeZlibId = 903;

/// Probe image ID for the Kitty Graphics PNG (`f=100`) transmit check.
const int kttyProbePngId = 904;

/// Visual showcase image ID for 24-bit raw RGBA (`f=32`).
const int kttyVisualRgbaImageId = 0x004B01;

/// Visual showcase image ID exercising 32-bit MSB diacritics (`MSB = 0x42`).
const int kttyVisual32BitImageId = 0x42004B02;

/// Visual showcase image ID exercising PNG (`f=100`) transmission.
const int kttyVisualPngImageId = 0x004B03;

final Uint32List _crc32Table = _buildCrc32Table();

Uint32List _buildCrc32Table() {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table[i] = c;
  }
  return table;
}

int _computeCrc32(List<int> typeBytes, Uint8List data) {
  var crc = 0xFFFFFFFF;
  for (final b in typeBytes) {
    crc = _crc32Table[(crc ^ b) & 0xFF] ^ (crc >>> 8);
  }
  for (final b in data) {
    crc = _crc32Table[(crc ^ b) & 0xFF] ^ (crc >>> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

int _computeAdler32(Uint8List data) {
  var s1 = 1;
  var s2 = 0;
  for (final b in data) {
    s1 = (s1 + b) % 65521;
    s2 = (s2 + s1) % 65521;
  }
  return ((s2 << 16) | s1) & 0xFFFFFFFF;
}

/// Wraps [raw] bytes in a valid RFC 1950 zlib stream using uncompressed
/// DEFLATE stored blocks, avoiding `dart:io` dependencies on Flutter Web.
Uint8List encodeZlibStoredBlocks(Uint8List raw) {
  const maxBlock = 65535;
  final blockCount = raw.isEmpty
      ? 1
      : ((raw.length + maxBlock - 1) ~/ maxBlock);
  final out = BytesBuilder(copy: false)..add(const [0x78, 0x01]);

  var offset = 0;
  for (var b = 0; b < blockCount; b++) {
    final isFinal = b == blockCount - 1;
    final len = math.min(maxBlock, raw.length - offset);
    final nlen = (~len) & 0xFFFF;
    out.add([
      isFinal ? 0x01 : 0x00,
      len & 0xFF,
      (len >>> 8) & 0xFF,
      nlen & 0xFF,
      (nlen >>> 8) & 0xFF,
    ]);
    if (len > 0) {
      out.add(Uint8List.sublistView(raw, offset, offset + len));
      offset += len;
    }
  }

  final adler = _computeAdler32(raw);
  out.add([
    (adler >>> 24) & 0xFF,
    (adler >>> 16) & 0xFF,
    (adler >>> 8) & 0xFF,
    adler & 0xFF,
  ]);
  return out.takeBytes();
}

void _appendPngChunk(BytesBuilder out, String type, Uint8List data) {
  final typeBytes = ascii.encode(type);
  final lenData = ByteData(4)..setUint32(0, data.length);
  final crcData = ByteData(4)..setUint32(0, _computeCrc32(typeBytes, data));
  out
    ..add(lenData.buffer.asUint8List())
    ..add(typeBytes)
    ..add(data)
    ..add(crcData.buffer.asUint8List());
}

/// Encodes raw 8-bit RGBA pixels (`width * height * 4` bytes) into a valid
/// PNG byte buffer (`colorType = 6`) in pure Dart.
Uint8List encodeRgbaPng(int width, int height, Uint8List rgba) {
  final stride = width * 4;
  final scanlines = Uint8List((stride + 1) * height);
  for (var y = 0; y < height; y++) {
    final dstRow = y * (stride + 1);
    final srcRow = y * stride;
    scanlines[dstRow] = 0; // Filter type 0 (None)
    scanlines.setRange(dstRow + 1, dstRow + 1 + stride, rgba, srcRow);
  }

  final ihdr = Uint8List(13);
  ByteData.sublistView(ihdr)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // 8-bit depth
    ..setUint8(9, 6) // Truecolor with alpha (RGBA)
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);

  final out = BytesBuilder(copy: false)
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  _appendPngChunk(out, 'IHDR', ihdr);
  _appendPngChunk(out, 'IDAT', encodeZlibStoredBlocks(scanlines));
  _appendPngChunk(out, 'IEND', Uint8List(0));
  return out.takeBytes();
}

/// Builds the 4 non-visual Kitty Graphics `APC` probe commands (`q=0`).
String buildKittyApcProbeCommands() {
  final sampleRgba = Uint8List.fromList(const [
    40, 210, 255, 255, 255, 110, 190, 255, //
    110, 255, 170, 255, 255, 220, 90, 255,
  ]);
  final rawB64 = base64Encode(sampleRgba);
  final zlibB64 = base64Encode(encodeZlibStoredBlocks(sampleRgba));
  final pngB64 = base64Encode(encodeRgbaPng(2, 2, sampleRgba));

  final sb = StringBuffer()
    ..write('\x1b_Gi=$kttyProbeQueryId,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\')
    ..write('\x1b_Gi=$kttyProbeRgbaId,s=2,v=2,a=t,t=d,f=32,q=0;$rawB64\x1b\\')
    ..write(
      '\x1b_Gi=$kttyProbeZlibId,s=2,v=2,a=t,t=d,f=32,o=z,q=0;$zlibB64\x1b\\',
    )
    ..write('\x1b_Gi=$kttyProbePngId,a=t,t=d,f=100,q=0;$pngB64\x1b\\');
  return sb.toString();
}

double _smoothstep(double edge0, double edge1, double x) {
  final t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

(int r, int g, int b) _rawRadarPixel(int x, int y, int pw, int ph) {
  if (x < 2 || x >= pw - 2 || y < 2 || y >= ph - 2) {
    return (85, 230, 255);
  }
  if (x == pw ~/ 2 || y == ph ~/ 2) {
    return (140, 250, 255);
  }
  final aspect = pw / ph;
  final dx = ((x + 0.5) / pw * 2.0 - 1.0) * aspect;
  final dy = (y + 0.5) / ph * 2.0 - 1.0;
  final dist = math.sqrt(dx * dx + dy * dy);
  final wave = 0.5 + 0.5 * math.cos(dist * 18.0);
  final ringGlow = _smoothstep(0.55, 0.98, wave);
  final u = x / (pw - 1);
  final v = y / (ph - 1);
  final baseR = 28.0 + u * 150.0;
  final baseG = 24.0 + (1.0 - dist.clamp(0.0, 1.2) / 1.2) * 70.0;
  final baseB = 72.0 + v * 155.0;
  final r = (baseR + ringGlow * 95.0).round().clamp(0, 255);
  final g = (baseG + ringGlow * 175.0).round().clamp(0, 255);
  final b = (baseB + ringGlow * 80.0).round().clamp(0, 255);
  return (r, g, b);
}

/// Generates the 24-bit ID raw RGBA (`f=32`) HiDPI visual tile (`144×96`).
KittyImageData buildRawRgbaVisualTile({int cols = 12, int rows = 4}) {
  const pw = 144;
  const ph = 96;
  final rgba = Uint8List(pw * ph * 4);
  for (var y = 0; y < ph; y++) {
    for (var x = 0; x < pw; x++) {
      final (r, g, b) = _rawRadarPixel(x, y, pw, ph);
      final idx = (y * pw + x) * 4;
      rgba[idx] = r;
      rgba[idx + 1] = g;
      rgba[idx + 2] = b;
      rgba[idx + 3] = 255;
    }
  }
  return KittyImageData(
    imageId: kttyVisualRgbaImageId,
    pixelWidth: pw,
    pixelHeight: ph,
    rgbaPixels: rgba,
    gridCols: cols,
    gridRows: rows,
  );
}

(int r, int g, int b) _msbTileColor(int x, int y, int pw, int ph) {
  if (x < 2 || x >= pw - 2 || y < 2 || y >= ph - 2) return (110, 250, 255);
  if (x % 16 == 0 || y % 16 == 0) return (95, 235, 250);
  final cellEven = ((x ~/ 16) + (y ~/ 16)).isEven;
  final u = x / (pw - 1);
  final v = y / (ph - 1);
  if (cellEven) {
    return (
      (22 + u * 45).round(),
      (145 + v * 75).round(),
      (205 + u * 45).round(),
    );
  }
  return (
    (78 + u * 60).round(),
    (40 + v * 45).round(),
    (170 + (1.0 - v) * 65).round(),
  );
}

/// Generates the 32-bit `imageId` (`0x42004B02`, 4th MSB diacritic) HiDPI visual tile (`144×96`).
KittyImageData buildMsb32BitVisualTile({int cols = 12, int rows = 4}) {
  const pw = 144;
  const ph = 96;
  final rgba = Uint8List(pw * ph * 4);
  for (var y = 0; y < ph; y++) {
    for (var x = 0; x < pw; x++) {
      final (r, g, b) = _msbTileColor(x, y, pw, ph);
      final idx = (y * pw + x) * 4;
      rgba[idx] = r;
      rgba[idx + 1] = g;
      rgba[idx + 2] = b;
      rgba[idx + 3] = 255;
    }
  }
  return KittyImageData(
    imageId: kttyVisual32BitImageId,
    pixelWidth: pw,
    pixelHeight: ph,
    rgbaPixels: rgba,
    gridCols: cols,
    gridRows: rows,
  );
}

(int r, int g, int b) _pngRibbonPixel(int x, int y, int pw, int ph) {
  if (x < 2 || x >= pw - 2 || y < 2 || y >= ph - 2) return (255, 215, 110);
  final cx = (x - pw / 2).abs();
  final cy = (y - ph / 2).abs();
  final diamond = cx * 0.75 + cy;
  if (diamond >= 18.0 && diamond <= 21.0) return (255, 248, 220);

  final phase = ((x * 0.85 + y) / 18.0) % 3.0;
  final idx = phase.floor();
  final frac = _smoothstep(0.75, 1.0, phase - idx);
  final c0 = _pngPalette(idx);
  final c1 = _pngPalette((idx + 1) % 3);
  return (
    (c0.$1 + (c1.$1 - c0.$1) * frac).round(),
    (c0.$2 + (c1.$2 - c0.$2) * frac).round(),
    (c0.$3 + (c1.$3 - c0.$3) * frac).round(),
  );
}

(int, int, int) _pngPalette(int band) => switch (band) {
  0 => (245, 145, 55),
  1 => (50, 215, 150),
  _ => (45, 125, 245),
};

/// Generates the PNG (`f=100`) HiDPI visual tile (`144×96`) encoded via [encodeRgbaPng].
KittyImageData buildPngVisualTile({int cols = 12, int rows = 4}) {
  const pw = 144;
  const ph = 96;
  final rgba = Uint8List(pw * ph * 4);
  for (var y = 0; y < ph; y++) {
    for (var x = 0; x < pw; x++) {
      final (r, g, b) = _pngRibbonPixel(x, y, pw, ph);
      final idx = (y * pw + x) * 4;
      rgba[idx] = r;
      rgba[idx + 1] = g;
      rgba[idx + 2] = b;
      rgba[idx + 3] = 255;
    }
  }
  return KittyImageData.fromPng(
    imageId: kttyVisualPngImageId,
    pixelWidth: pw,
    pixelHeight: ph,
    pngBytes: encodeRgbaPng(pw, ph, rgba),
    gridCols: cols,
    gridRows: rows,
  );
}
