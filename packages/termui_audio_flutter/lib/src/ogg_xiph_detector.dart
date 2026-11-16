import 'dart:math' as math;
import 'dart:typed_data';

const int _oggCaptureHeaderSize = 27;
const int _minOggXiphHeaderBytes = 35;

/// Maximum prefix length scanned when probing Ogg page headers for Xiph codecs.
const int oggXiphProbeMaxBytes = 64 * 1024;

/// Returns whether [bytes] begins an Ogg container carrying an Opus (`OpusHead`)
/// or Ogg FLAC (`\x7fFLAC` / `fLaC`) stream within the first 64 KiB.
///
/// Ogg Vorbis streams (`\x01vorbis`) and non-Ogg payloads return `false`.
bool isOggXiphBytes(Uint8List bytes) {
  if (bytes.length < _minOggXiphHeaderBytes ||
      !_matchesAscii(bytes, 0, 'OggS')) {
    return false;
  }

  final scanLimit = math.min(bytes.length, oggXiphProbeMaxBytes);
  var scanOffset = 0;
  while (scanOffset + _oggCaptureHeaderSize < scanLimit) {
    if (!_matchesAscii(bytes, scanOffset, 'OggS')) {
      scanOffset += 1;
      continue;
    }

    final span = _parseOggPagePayloadSpan(bytes, scanOffset, scanLimit);
    if (span == null) {
      return false;
    }

    final (payloadOffset, payloadSize) = span;
    if (_isXiphIdentificationPayload(bytes, payloadOffset, payloadSize)) {
      return true;
    }

    scanOffset = payloadOffset + payloadSize;
  }

  return false;
}

(int, int)? _parseOggPagePayloadSpan(
  Uint8List bytes,
  int pageOffset,
  int scanLimit,
) {
  final segmentCount = bytes[pageOffset + 26];
  final segmentTableOffset = pageOffset + _oggCaptureHeaderSize;
  if (segmentTableOffset + segmentCount > scanLimit) {
    return null;
  }

  var payloadSize = 0;
  for (var i = 0; i < segmentCount; i++) {
    payloadSize += bytes[segmentTableOffset + i];
  }

  final payloadOffset = segmentTableOffset + segmentCount;
  if (payloadOffset + payloadSize > bytes.length) {
    return null;
  }

  return (payloadOffset, payloadSize);
}

bool _isXiphIdentificationPayload(
  Uint8List bytes,
  int payloadOffset,
  int payloadSize,
) {
  if (payloadSize >= 8 && _matchesAscii(bytes, payloadOffset, 'OpusHead')) {
    return true;
  }

  return payloadSize >= 13 &&
      _matchesAscii(bytes, payloadOffset + 1, 'FLAC') &&
      _matchesAscii(bytes, payloadOffset + 9, 'fLaC');
}

bool _matchesAscii(Uint8List bytes, int offset, String ascii) {
  if (offset < 0 || offset + ascii.length > bytes.length) {
    return false;
  }
  for (var i = 0; i < ascii.length; i++) {
    if (bytes[offset + i] != ascii.codeUnitAt(i)) {
      return false;
    }
  }
  return true;
}
