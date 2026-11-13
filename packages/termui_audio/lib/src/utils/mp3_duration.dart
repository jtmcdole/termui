import 'dart:typed_data';

const List<int> _mpeg1SampleRates = [44100, 48000, 32000];
const List<int> _mpeg2SampleRates = [22050, 24000, 16000];
const List<int> _mpeg25SampleRates = [11025, 12000, 8000];

const List<int> _mpeg1Layer3BitratesKbps = [
  0,
  32,
  40,
  48,
  56,
  64,
  80,
  96,
  112,
  128,
  160,
  192,
  224,
  256,
  320,
  0,
];

const List<int> _mpeg2Layer3BitratesKbps = [
  0,
  8,
  16,
  24,
  32,
  40,
  48,
  56,
  64,
  80,
  96,
  112,
  128,
  144,
  160,
  0,
];

typedef _Mp3FrameHeader = ({
  int versionBits,
  int sampleRate,
  int samplesPerFrame,
  int bitrateBps,
  int frameSize,
  bool isMono,
});

/// Estimates the playback duration of an MP3 byte buffer in pure Dart.
///
/// Handles ID3v2 headers/footers, trailing ID3v1 and APEv2 tags, MPEG-1/2/2.5
/// Layer III frame sync (rejecting ADTS AAC frames where `layer == 0`),
/// Xing/Info/VBRI VBR frame counts, and CBR bitrate fallback. Returns
/// [Duration.zero] when no valid MP3 audio frames are found.
Duration estimateMp3Duration(Uint8List bytes) {
  if (bytes.length < 4) return Duration.zero;
  final start = _skipId3v2Headers(bytes);
  if (start >= bytes.length) return Duration.zero;
  final end = _stripTrailingTags(bytes, start);
  if (end - start < 4) return Duration.zero;

  final bd = ByteData.sublistView(bytes);
  for (var pos = start; pos <= end - 4; pos++) {
    final header = _parseMp3FrameHeader(bytes, pos, end);
    if (header == null) continue;

    final vbrFrames = _readVbrFrameCount(bytes, bd, pos, end, header);
    if (vbrFrames != null && vbrFrames > 0) {
      final totalSamples = vbrFrames * header.samplesPerFrame;
      return Duration(
        microseconds: (totalSamples * 1000000.0 / header.sampleRate).round(),
      );
    }

    final nextPos = pos + header.frameSize;
    if (nextPos + 4 <= end &&
        _parseMp3FrameHeader(bytes, nextPos, end) == null) {
      continue;
    }

    final audioBytes = end - pos;
    return Duration(
      microseconds: (audioBytes * 8 * 1000000.0 / header.bitrateBps).round(),
    );
  }
  return Duration.zero;
}

int _skipId3v2Headers(Uint8List bytes) {
  var offset = 0;
  while (offset + 10 <= bytes.length &&
      bytes[offset] == 0x49 &&
      bytes[offset + 1] == 0x44 &&
      bytes[offset + 2] == 0x33) {
    if (bytes[offset + 3] == 0xFF || bytes[offset + 4] == 0xFF) break;
    final b6 = bytes[offset + 6];
    final b7 = bytes[offset + 7];
    final b8 = bytes[offset + 8];
    final b9 = bytes[offset + 9];
    if ((b6 | b7 | b8 | b9) & 0x80 != 0) break;
    final size = (b6 << 21) | (b7 << 14) | (b8 << 7) | b9;
    final hasFooter = (bytes[offset + 5] & 0x10) != 0;
    final next = offset + 10 + size + (hasFooter ? 10 : 0);
    if (next >= bytes.length) return bytes.length;
    offset = next;
  }
  return offset;
}

int _stripTrailingTags(Uint8List bytes, int start) {
  var end = bytes.length;
  if (end - start >= 128 && _matchesAscii(bytes, end - 128, 'TAG')) {
    end -= 128;
  }
  if (end - start >= 32 && _matchesAscii(bytes, end - 32, 'APETAGEX')) {
    final bd = ByteData.sublistView(bytes);
    final tagSize = bd.getUint32(end - 32 + 12, Endian.little);
    final flags = bd.getUint32(end - 32 + 20, Endian.little);
    final hasHeader = (flags & 0x80000000) != 0;
    final totalApeBytes = tagSize + (hasHeader ? 32 : 0);
    if (tagSize >= 32 && totalApeBytes <= end - start) {
      end -= totalApeBytes;
    }
  }
  return end;
}

_Mp3FrameHeader? _parseMp3FrameHeader(Uint8List bytes, int pos, int end) {
  if (pos < 0 || pos + 4 > end) return null;
  final b0 = bytes[pos];
  final b1 = bytes[pos + 1];
  if (b0 != 0xFF || (b1 & 0xE0) != 0xE0) return null;

  final versionBits = (b1 >> 3) & 0x03;
  final layerBits = (b1 >> 1) & 0x03;
  // layerBits == 1 is Layer III; layerBits == 0 is reserved (and matches ADTS AAC).
  if (versionBits == 1 || layerBits != 1) return null;

  final b2 = bytes[pos + 2];
  final bitrateIdx = (b2 >> 4) & 0x0F;
  final srIdx = (b2 >> 2) & 0x03;
  if (bitrateIdx == 0 || bitrateIdx == 15 || srIdx == 3) return null;

  final padding = (b2 >> 1) & 0x01;
  final isMono = ((bytes[pos + 3] >> 6) & 0x03) == 3;
  final isMpeg1 = versionBits == 3;
  final sampleRate = switch (versionBits) {
    3 => _mpeg1SampleRates[srIdx],
    2 => _mpeg2SampleRates[srIdx],
    _ => _mpeg25SampleRates[srIdx],
  };
  final samplesPerFrame = isMpeg1 ? 1152 : 576;
  final bitrateKbps = isMpeg1
      ? _mpeg1Layer3BitratesKbps[bitrateIdx]
      : _mpeg2Layer3BitratesKbps[bitrateIdx];
  final bitrateBps = bitrateKbps * 1000;
  final frameSize =
      ((samplesPerFrame ~/ 8) * bitrateBps) ~/ sampleRate + padding;
  if (frameSize < 4) return null;

  return (
    versionBits: versionBits,
    sampleRate: sampleRate,
    samplesPerFrame: samplesPerFrame,
    bitrateBps: bitrateBps,
    frameSize: frameSize,
    isMono: isMono,
  );
}

int? _readVbrFrameCount(
  Uint8List bytes,
  ByteData bd,
  int pos,
  int end,
  _Mp3FrameHeader header,
) {
  final sideInfoSize = header.versionBits == 3
      ? (header.isMono ? 17 : 32)
      : (header.isMono ? 9 : 17);
  final xingOffset = pos + 4 + sideInfoSize;
  if (xingOffset + 12 <= end &&
      (_matchesAscii(bytes, xingOffset, 'Xing') ||
          _matchesAscii(bytes, xingOffset, 'Info'))) {
    final flags = bd.getUint32(xingOffset + 4, Endian.big);
    if ((flags & 0x01) != 0) {
      return bd.getUint32(xingOffset + 8, Endian.big);
    }
  }
  final vbriOffset = pos + 36;
  if (vbriOffset + 18 <= end && _matchesAscii(bytes, vbriOffset, 'VBRI')) {
    return bd.getUint32(vbriOffset + 14, Endian.big);
  }
  return null;
}

bool _matchesAscii(Uint8List bytes, int offset, String tag) {
  if (offset < 0 || offset + tag.length > bytes.length) return false;
  for (var i = 0; i < tag.length; i++) {
    if (bytes[offset + i] != tag.codeUnitAt(i)) return false;
  }
  return true;
}
