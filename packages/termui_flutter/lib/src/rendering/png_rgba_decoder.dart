import 'dart:math' as math;
import 'dart:typed_data';

import 'png_rgba_decoder_stub.dart'
    if (dart.library.io) 'png_rgba_decoder_io.dart'
    as impl;

/// Decoded straight (unpremultiplied) RGBA8888 pixel buffer from a PNG image.
typedef DecodedPngRgba = ({int width, int height, Uint8List rgba});

/// Maximum PNG pixel dimension accepted by Kitty Graphics Protocol decoders.
const int maxKittyPngDimension = 8192;

/// Maximum PNG total pixel count accepted by Kitty Graphics Protocol decoders.
const int maxKittyPngPixels = 16_777_216;

const List<int> _pngMagic = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
];

const List<int> _adam7StartX = <int>[0, 4, 0, 2, 0, 1, 0];
const List<int> _adam7StartY = <int>[0, 0, 4, 0, 2, 0, 1];
const List<int> _adam7StepX = <int>[8, 8, 4, 4, 2, 2, 1];
const List<int> _adam7StepY = <int>[8, 8, 8, 4, 4, 2, 2];

final class _PngHeader {
  final int width;
  final int height;
  final int bitDepth;
  final int colorType;
  final int interlace;

  const _PngHeader({
    required this.width,
    required this.height,
    required this.bitDepth,
    required this.colorType,
    required this.interlace,
  });

  int get channels => switch (colorType) {
    0 => 1,
    2 => 3,
    3 => 1,
    4 => 2,
    6 => 4,
    _ => 0,
  };

  int get bytesPerPixel => math.max(1, (channels * bitDepth) ~/ 8);

  int rowDataBytes(int rowWidth) => (rowWidth * channels * bitDepth + 7) ~/ 8;
}

final class _ParsedPngChunks {
  final _PngHeader header;
  final Uint8List idat;
  final Uint8List? palette;
  final Uint8List? transparency;

  const _ParsedPngChunks({
    required this.header,
    required this.idat,
    required this.palette,
    required this.transparency,
  });
}

/// Decodes [pngBytes] into straight RGBA8888 pixels on platforms with native
/// `dart:io` zlib support, avoiding GPU-to-CPU `ui.Image.toByteData` readbacks.
///
/// Returns `null` on Web or if [pngBytes] is invalid/unsupported so callers can
/// fall back to `ui.instantiateImageCodec`.
Future<DecodedPngRgba?> decodeKittyPngToRgbaAsync(Uint8List pngBytes) =>
    impl.decodePlatformPngToRgbaAsync(pngBytes);

/// Synchronously decodes [pngBytes] into straight RGBA8888 pixels using the
/// supplied bounded [inflateZlib] decoder.
///
/// Returns `null` if [pngBytes] is malformed, exceeds Kitty dimension/pixel
/// caps, or fails bounded decompression.
DecodedPngRgba? decodePngBytesToRgba(
  Uint8List pngBytes, {
  required Uint8List? Function(Uint8List compressed, int maxBytes) inflateZlib,
  int maxWidth = maxKittyPngDimension,
  int maxHeight = maxKittyPngDimension,
  int maxPixels = maxKittyPngPixels,
}) {
  final chunks = _parsePngChunks(
    pngBytes,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
    maxPixels: maxPixels,
  );
  if (chunks == null) return null;

  final expectedBytes = _expectedInflatedBytes(chunks.header);
  if (expectedBytes <= 0) return null;

  final raw = inflateZlib(chunks.idat, expectedBytes);
  if (raw == null || raw.length < expectedBytes) return null;

  final rgba = Uint8List(chunks.header.width * chunks.header.height * 4);
  final ok = chunks.header.interlace == 0
      ? _decodeNonInterlaced(chunks, raw, rgba)
      : _decodeAdam7(chunks, raw, rgba);
  if (!ok) return null;
  return (width: chunks.header.width, height: chunks.header.height, rgba: rgba);
}

bool _hasValidMagic(Uint8List bytes) {
  if (bytes.length < 33) return false;
  for (var i = 0; i < _pngMagic.length; i++) {
    if (bytes[i] != _pngMagic[i]) return false;
  }
  return true;
}

bool _isValidDepthForColorType(int colorType, int bitDepth) =>
    switch (colorType) {
      0 =>
        bitDepth == 1 ||
            bitDepth == 2 ||
            bitDepth == 4 ||
            bitDepth == 8 ||
            bitDepth == 16,
      2 || 4 || 6 => bitDepth == 8 || bitDepth == 16,
      3 => bitDepth == 1 || bitDepth == 2 || bitDepth == 4 || bitDepth == 8,
      _ => false,
    };

_PngHeader? _parseLeadingIhdr(
  Uint8List bytes,
  ByteData view, {
  required int maxWidth,
  required int maxHeight,
  required int maxPixels,
}) {
  // RFC 2083 requires IHDR to be the first chunk immediately after the 8-byte signature.
  final length = view.getUint32(8);
  final type = view.getUint32(12);
  if (type != 0x49484452 || length != 13 || 33 > bytes.length) return null;
  final width = view.getUint32(16);
  final height = view.getUint32(20);
  final bitDepth = view.getUint8(24);
  final colorType = view.getUint8(25);
  final compression = view.getUint8(26);
  final filter = view.getUint8(27);
  final interlace = view.getUint8(28);
  if (width <= 0 ||
      height <= 0 ||
      width > maxWidth ||
      height > maxHeight ||
      width * height > maxPixels) {
    return null;
  }
  if (compression != 0 || filter != 0 || (interlace != 0 && interlace != 1)) {
    return null;
  }
  if (!_isValidDepthForColorType(colorType, bitDepth)) return null;
  return _PngHeader(
    width: width,
    height: height,
    bitDepth: bitDepth,
    colorType: colorType,
    interlace: interlace,
  );
}

_ParsedPngChunks? _parsePngChunks(
  Uint8List bytes, {
  required int maxWidth,
  required int maxHeight,
  required int maxPixels,
}) {
  if (!_hasValidMagic(bytes)) return null;
  final view = ByteData.sublistView(bytes);
  final header = _parseLeadingIhdr(
    bytes,
    view,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
    maxPixels: maxPixels,
  );
  if (header == null) return null;

  Uint8List? palette;
  Uint8List? transparency;
  final idat = BytesBuilder(copy: false);
  var offset = 33; // 8-byte magic + 12-byte chunk framing + 13-byte IHDR

  while (offset + 12 <= bytes.length) {
    final chunkLen = view.getUint32(offset);
    final dataStart = offset + 8;
    final nextOffset = dataStart + chunkLen + 4;
    if (nextOffset > bytes.length) return null;
    final type = view.getUint32(offset + 4);
    offset = nextOffset;

    switch (type) {
      case 0x49484452: // Duplicate IHDR
        return null;
      case 0x504C5445: // PLTE
        if (chunkLen == 0 || chunkLen % 3 != 0) return null;
        palette = Uint8List.sublistView(bytes, dataStart, dataStart + chunkLen);
      case 0x74524E53: // tRNS
        transparency = Uint8List.sublistView(
          bytes,
          dataStart,
          dataStart + chunkLen,
        );
      case 0x49444154: // IDAT
        idat.add(Uint8List.sublistView(bytes, dataStart, dataStart + chunkLen));
      case 0x49454E44: // IEND
        offset = bytes.length;
    }
  }

  if (idat.isEmpty || (header.colorType == 3 && palette == null)) return null;
  return _ParsedPngChunks(
    header: header,
    idat: idat.takeBytes(),
    palette: palette,
    transparency: transparency,
  );
}

int _expectedInflatedBytes(_PngHeader header) {
  if (header.interlace == 0) {
    return header.height * (1 + header.rowDataBytes(header.width));
  }
  var total = 0;
  for (var pass = 0; pass < 7; pass++) {
    final pw = _adam7PassDimension(
      header.width,
      _adam7StartX[pass],
      _adam7StepX[pass],
    );
    final ph = _adam7PassDimension(
      header.height,
      _adam7StartY[pass],
      _adam7StepY[pass],
    );
    if (pw > 0 && ph > 0) {
      total += ph * (1 + header.rowDataBytes(pw));
    }
  }
  return total;
}

int _adam7PassDimension(int full, int start, int step) =>
    full <= start ? 0 : (full - start + step - 1) ~/ step;

int _paethPredictor(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

void _unfilterSub(
  Uint8List raw,
  int srcOffset,
  Uint8List current,
  int rowBytes,
  int bpp,
) {
  final head = math.min(bpp, rowBytes);
  current.setRange(0, head, raw, srcOffset);
  for (var i = head; i < rowBytes; i++) {
    current[i] = (raw[srcOffset + i] + current[i - bpp]) & 0xFF;
  }
}

void _unfilterUp(
  Uint8List raw,
  int srcOffset,
  Uint8List current,
  Uint8List? previous,
  int rowBytes,
) {
  if (previous == null) {
    current.setRange(0, rowBytes, raw, srcOffset);
    return;
  }
  for (var i = 0; i < rowBytes; i++) {
    current[i] = (raw[srcOffset + i] + previous[i]) & 0xFF;
  }
}

void _unfilterAverage(
  Uint8List raw,
  int srcOffset,
  Uint8List current,
  Uint8List? previous,
  int rowBytes,
  int bpp,
) {
  for (var i = 0; i < rowBytes; i++) {
    final left = i >= bpp ? current[i - bpp] : 0;
    final up = previous == null ? 0 : previous[i];
    current[i] = (raw[srcOffset + i] + ((left + up) >>> 1)) & 0xFF;
  }
}

void _unfilterPaeth(
  Uint8List raw,
  int srcOffset,
  Uint8List current,
  Uint8List? previous,
  int rowBytes,
  int bpp,
) {
  for (var i = 0; i < rowBytes; i++) {
    final left = i >= bpp ? current[i - bpp] : 0;
    final up = previous == null ? 0 : previous[i];
    final upLeft = (previous != null && i >= bpp) ? previous[i - bpp] : 0;
    current[i] =
        (raw[srcOffset + i] + _paethPredictor(left, up, upLeft)) & 0xFF;
  }
}

bool _unfilterRow({
  required int filterType,
  required Uint8List raw,
  required int srcOffset,
  required Uint8List current,
  required Uint8List? previous,
  required int rowBytes,
  required int bpp,
}) {
  switch (filterType) {
    case 0:
      current.setRange(0, rowBytes, raw, srcOffset);
      return true;
    case 1:
      _unfilterSub(raw, srcOffset, current, rowBytes, bpp);
      return true;
    case 2:
      _unfilterUp(raw, srcOffset, current, previous, rowBytes);
      return true;
    case 3:
      _unfilterAverage(raw, srcOffset, current, previous, rowBytes, bpp);
      return true;
    case 4:
      _unfilterPaeth(raw, srcOffset, current, previous, rowBytes, bpp);
      return true;
    default:
      return false;
  }
}

bool _decodeNonInterlaced(
  _ParsedPngChunks chunks,
  Uint8List raw,
  Uint8List outRgba,
) {
  final header = chunks.header;
  final rowBytes = header.rowDataBytes(header.width);
  final bpp = header.bytesPerPixel;
  var current = Uint8List(rowBytes);
  var previous = Uint8List(rowBytes);
  var srcOffset = 0;

  for (var y = 0; y < header.height; y++) {
    final filterType = raw[srcOffset++];
    if (!_unfilterRow(
      filterType: filterType,
      raw: raw,
      srcOffset: srcOffset,
      current: current,
      previous: y > 0 ? previous : null,
      rowBytes: rowBytes,
      bpp: bpp,
    )) {
      return false;
    }
    srcOffset += rowBytes;
    _writeScanlineToRgba(
      chunks: chunks,
      scanline: current,
      pixelCount: header.width,
      outRgba: outRgba,
      dstStartPixel: y * header.width,
      dstPixelStep: 1,
    );
    final swap = previous;
    previous = current;
    current = swap;
  }
  return true;
}

bool _decodeAdam7(_ParsedPngChunks chunks, Uint8List raw, Uint8List outRgba) {
  final header = chunks.header;
  final bpp = header.bytesPerPixel;
  var srcOffset = 0;

  for (var pass = 0; pass < 7; pass++) {
    final startX = _adam7StartX[pass];
    final startY = _adam7StartY[pass];
    final stepX = _adam7StepX[pass];
    final stepY = _adam7StepY[pass];
    final pw = _adam7PassDimension(header.width, startX, stepX);
    final ph = _adam7PassDimension(header.height, startY, stepY);
    if (pw == 0 || ph == 0) continue;

    final rowBytes = header.rowDataBytes(pw);
    var current = Uint8List(rowBytes);
    var previous = Uint8List(rowBytes);
    for (var py = 0; py < ph; py++) {
      final filterType = raw[srcOffset++];
      if (!_unfilterRow(
        filterType: filterType,
        raw: raw,
        srcOffset: srcOffset,
        current: current,
        previous: py > 0 ? previous : null,
        rowBytes: rowBytes,
        bpp: bpp,
      )) {
        return false;
      }
      srcOffset += rowBytes;
      final dstY = startY + py * stepY;
      _writeScanlineToRgba(
        chunks: chunks,
        scanline: current,
        pixelCount: pw,
        outRgba: outRgba,
        dstStartPixel: dstY * header.width + startX,
        dstPixelStep: stepX,
      );
      final swap = previous;
      previous = current;
      current = swap;
    }
  }
  return true;
}

int _readSubByteSample(Uint8List scanline, int x, int bitDepth) {
  final bitOffset = x * bitDepth;
  final byteIndex = bitOffset >> 3;
  final shift = 8 - bitDepth - (bitOffset & 7);
  final mask = (1 << bitDepth) - 1;
  return (scanline[byteIndex] >> shift) & mask;
}

int _scaleGraySampleToByte(int sample, int bitDepth) => switch (bitDepth) {
  1 => sample == 0 ? 0 : 255,
  2 => sample * 85,
  4 => sample * 17,
  _ => sample,
};

int? _readSingleTransparentKey(Uint8List? trns) {
  if (trns == null || trns.length < 2) return null;
  return (trns[0] << 8) | trns[1];
}

(int, int, int)? _readRgbTransparentKey(Uint8List? trns) {
  if (trns == null || trns.length < 6) return null;
  return (
    (trns[0] << 8) | trns[1],
    (trns[2] << 8) | trns[3],
    (trns[4] << 8) | trns[5],
  );
}

void _writeScanlineToRgba({
  required _ParsedPngChunks chunks,
  required Uint8List scanline,
  required int pixelCount,
  required Uint8List outRgba,
  required int dstStartPixel,
  required int dstPixelStep,
}) {
  final header = chunks.header;
  switch (header.colorType) {
    case 6:
      _writeRgbaScanline(
        scanline,
        header.bitDepth,
        pixelCount,
        outRgba,
        dstStartPixel,
        dstPixelStep,
      );
    case 2:
      _writeRgbScanline(
        scanline,
        header.bitDepth,
        _readRgbTransparentKey(chunks.transparency),
        pixelCount,
        outRgba,
        dstStartPixel,
        dstPixelStep,
      );
    case 0:
      _writeGrayScanline(
        scanline,
        header.bitDepth,
        _readSingleTransparentKey(chunks.transparency),
        pixelCount,
        outRgba,
        dstStartPixel,
        dstPixelStep,
      );
    case 4:
      _writeGrayAlphaScanline(
        scanline,
        header.bitDepth,
        pixelCount,
        outRgba,
        dstStartPixel,
        dstPixelStep,
      );
    case 3:
      _writeIndexedScanline(
        scanline,
        header.bitDepth,
        chunks.palette!,
        chunks.transparency,
        pixelCount,
        outRgba,
        dstStartPixel,
        dstPixelStep,
      );
  }
}

void _writeRgbaScanline(
  Uint8List scanline,
  int bitDepth,
  int pixelCount,
  Uint8List outRgba,
  int dstStartPixel,
  int dstPixelStep,
) {
  if (bitDepth == 8 && dstPixelStep == 1) {
    final dst = dstStartPixel << 2;
    outRgba.setRange(dst, dst + (pixelCount << 2), scanline);
    return;
  }
  final stepBytes = bitDepth == 16 ? 8 : 4;
  final channelStride = bitDepth == 16 ? 2 : 1;
  for (var x = 0; x < pixelCount; x++) {
    final s = x * stepBytes;
    final d = (dstStartPixel + x * dstPixelStep) << 2;
    outRgba[d] = scanline[s];
    outRgba[d + 1] = scanline[s + channelStride];
    outRgba[d + 2] = scanline[s + channelStride * 2];
    outRgba[d + 3] = scanline[s + channelStride * 3];
  }
}

void _writeRgbScanline(
  Uint8List scanline,
  int bitDepth,
  (int, int, int)? trnsKey,
  int pixelCount,
  Uint8List outRgba,
  int dstStartPixel,
  int dstPixelStep,
) {
  if (bitDepth == 16) {
    _writeRgb16Scanline(
      scanline,
      trnsKey,
      pixelCount,
      outRgba,
      dstStartPixel,
      dstPixelStep,
    );
    return;
  }
  _writeRgb8Scanline(
    scanline,
    trnsKey,
    pixelCount,
    outRgba,
    dstStartPixel,
    dstPixelStep,
  );
}

void _writeRgb8Scanline(
  Uint8List scanline,
  (int, int, int)? trnsKey,
  int pixelCount,
  Uint8List outRgba,
  int dstStartPixel,
  int dstPixelStep,
) {
  for (var x = 0; x < pixelCount; x++) {
    final s = x * 3;
    final d = (dstStartPixel + x * dstPixelStep) << 2;
    final r = scanline[s];
    final g = scanline[s + 1];
    final b = scanline[s + 2];
    final isTransparent =
        trnsKey != null &&
        r == trnsKey.$1 &&
        g == trnsKey.$2 &&
        b == trnsKey.$3;
    outRgba[d] = r;
    outRgba[d + 1] = g;
    outRgba[d + 2] = b;
    outRgba[d + 3] = isTransparent ? 0 : 255;
  }
}

void _writeRgb16Scanline(
  Uint8List scanline,
  (int, int, int)? trnsKey,
  int pixelCount,
  Uint8List outRgba,
  int dstStartPixel,
  int dstPixelStep,
) {
  for (var x = 0; x < pixelCount; x++) {
    final s = x * 6;
    final d = (dstStartPixel + x * dstPixelStep) << 2;
    final rRaw = (scanline[s] << 8) | scanline[s + 1];
    final gRaw = (scanline[s + 2] << 8) | scanline[s + 3];
    final bRaw = (scanline[s + 4] << 8) | scanline[s + 5];
    final isTransparent =
        trnsKey != null &&
        rRaw == trnsKey.$1 &&
        gRaw == trnsKey.$2 &&
        bRaw == trnsKey.$3;
    outRgba[d] = scanline[s];
    outRgba[d + 1] = scanline[s + 2];
    outRgba[d + 2] = scanline[s + 4];
    outRgba[d + 3] = isTransparent ? 0 : 255;
  }
}

void _writeGrayScanline(
  Uint8List scanline,
  int bitDepth,
  int? trnsKey,
  int pixelCount,
  Uint8List outRgba,
  int dstStartPixel,
  int dstPixelStep,
) {
  for (var x = 0; x < pixelCount; x++) {
    final int rawSample;
    final int grayByte;
    if (bitDepth == 16) {
      final s = x << 1;
      rawSample = (scanline[s] << 8) | scanline[s + 1];
      grayByte = scanline[s];
    } else if (bitDepth == 8) {
      rawSample = scanline[x];
      grayByte = rawSample;
    } else {
      rawSample = _readSubByteSample(scanline, x, bitDepth);
      grayByte = _scaleGraySampleToByte(rawSample, bitDepth);
    }
    final d = (dstStartPixel + x * dstPixelStep) << 2;
    outRgba[d] = grayByte;
    outRgba[d + 1] = grayByte;
    outRgba[d + 2] = grayByte;
    outRgba[d + 3] = (trnsKey != null && rawSample == trnsKey) ? 0 : 255;
  }
}

void _writeGrayAlphaScanline(
  Uint8List scanline,
  int bitDepth,
  int pixelCount,
  Uint8List outRgba,
  int dstStartPixel,
  int dstPixelStep,
) {
  final is16 = bitDepth == 16;
  final stepBytes = is16 ? 4 : 2;
  final alphaOffset = is16 ? 2 : 1;
  for (var x = 0; x < pixelCount; x++) {
    final s = x * stepBytes;
    final gray = scanline[s];
    final d = (dstStartPixel + x * dstPixelStep) << 2;
    outRgba[d] = gray;
    outRgba[d + 1] = gray;
    outRgba[d + 2] = gray;
    outRgba[d + 3] = scanline[s + alphaOffset];
  }
}

void _writeIndexedScanline(
  Uint8List scanline,
  int bitDepth,
  Uint8List palette,
  Uint8List? trns,
  int pixelCount,
  Uint8List outRgba,
  int dstStartPixel,
  int dstPixelStep,
) {
  final paletteEntries = palette.length ~/ 3;
  for (var x = 0; x < pixelCount; x++) {
    final idx = bitDepth == 8
        ? scanline[x]
        : _readSubByteSample(scanline, x, bitDepth);
    final d = (dstStartPixel + x * dstPixelStep) << 2;
    if (idx < paletteEntries) {
      final p = idx * 3;
      outRgba[d] = palette[p];
      outRgba[d + 1] = palette[p + 1];
      outRgba[d + 2] = palette[p + 2];
      outRgba[d + 3] = (trns != null && idx < trns.length) ? trns[idx] : 255;
    } else {
      outRgba[d] = 0;
      outRgba[d + 1] = 0;
      outRgba[d + 2] = 0;
      outRgba[d + 3] = 0;
    }
  }
}
