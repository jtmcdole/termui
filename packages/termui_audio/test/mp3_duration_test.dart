import 'dart:typed_data';

import 'package:termui_audio/src/utils/mp3_duration.dart';
import 'package:test/test.dart';

Uint8List _mp3Frame({
  required int versionBits,
  required int layerBits,
  required int bitrateIdx,
  required int srIdx,
  int padding = 0,
  int channelMode = 0,
  int? totalFrameBytesOverride,
}) {
  const sampleRates = {
    3: [44100, 48000, 32000],
    2: [22050, 24000, 16000],
    0: [11025, 12000, 8000],
  };
  const mpeg1Bitrates = [
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
  const mpeg2Bitrates = [
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
  final isMpeg1 = versionBits == 3;
  final samples = isMpeg1 ? 1152 : 576;
  final sr = sampleRates[versionBits]![srIdx];
  final kbps = (isMpeg1 ? mpeg1Bitrates : mpeg2Bitrates)[bitrateIdx];
  final size =
      totalFrameBytesOverride ??
      (((samples ~/ 8) * kbps * 1000) ~/ sr + padding);
  final frame = Uint8List(size);
  frame[0] = 0xFF;
  frame[1] = 0xE0 | ((versionBits & 0x03) << 3) | ((layerBits & 0x03) << 1);
  frame[2] =
      ((bitrateIdx & 0x0F) << 4) | ((srIdx & 0x03) << 2) | ((padding & 1) << 1);
  frame[3] = (channelMode & 0x03) << 6;
  return frame;
}

Uint8List _id3v2Tag(int bodySize, {bool footer = false}) {
  final total = 10 + bodySize + (footer ? 10 : 0);
  final out = Uint8List(total);
  out[0] = 0x49;
  out[1] = 0x44;
  out[2] = 0x33;
  out[3] = 4;
  out[4] = 0;
  out[5] = footer ? 0x10 : 0x00;
  out[6] = (bodySize >> 21) & 0x7F;
  out[7] = (bodySize >> 14) & 0x7F;
  out[8] = (bodySize >> 7) & 0x7F;
  out[9] = bodySize & 0x7F;
  return out;
}

Uint8List _id3v1Tag() {
  final out = Uint8List(128);
  out.setRange(0, 3, 'TAG'.codeUnits);
  return out;
}

Uint8List _apev2Tag({required int itemBytes, bool withHeader = true}) {
  final total = (withHeader ? 32 : 0) + itemBytes + 32;
  final out = Uint8List(total);
  final footerOffset = total - 32;
  out.setRange(footerOffset, footerOffset + 8, 'APETAGEX'.codeUnits);
  final bd = ByteData.sublistView(out);
  bd.setUint32(footerOffset + 12, itemBytes + 32, Endian.little);
  bd.setUint32(footerOffset + 20, withHeader ? 0x80000000 : 0, Endian.little);
  return out;
}

void main() {
  group('estimateMp3Duration', () {
    test(
      'parses MPEG-1 CBR with ID3v2 header/footer and ID3v1/APE trailers',
      () {
        // MPEG-1 Layer III, 128 kbps (idx 9), 44100 Hz (idx 0): 417 bytes/frame.
        // 10 frames = 4170 bytes -> 4170 * 8 / 128000 = 260.625 ms.
        final f = _mp3Frame(
          versionBits: 3,
          layerBits: 1,
          bitrateIdx: 9,
          srIdx: 0,
        );
        expect(f.length, equals(417));
        final bytes = Uint8List.fromList([
          ..._id3v2Tag(64, footer: true),
          for (var i = 0; i < 10; i++) ...f,
          ..._apev2Tag(itemBytes: 40, withHeader: true),
          ..._id3v1Tag(),
        ]);
        final duration = estimateMp3Duration(bytes);
        expect(duration.inMicroseconds, equals(260625));
      },
    );

    test('parses Xing and Info VBR frame counts for MPEG-1 and MPEG-2/2.5', () {
      // MPEG-1 stereo: side info = 32 bytes -> Xing at offset 36.
      final mpeg1Frame = _mp3Frame(
        versionBits: 3,
        layerBits: 1,
        bitrateIdx: 9,
        srIdx: 0,
        channelMode: 0,
      );
      mpeg1Frame.setRange(36, 40, 'Xing'.codeUnits);
      ByteData.sublistView(mpeg1Frame)
        ..setUint32(40, 0x01, Endian.big)
        ..setUint32(44, 100, Endian.big); // 100 * 1152 / 44100 = 2612245 us
      expect(
        estimateMp3Duration(mpeg1Frame).inMicroseconds,
        equals((100 * 1152 * 1000000.0 / 44100).round()),
      );

      // MPEG-2 mono (576 samples/frame, 22050 Hz): side info = 9 -> Info at offset 13.
      final mpeg2Frame = _mp3Frame(
        versionBits: 2,
        layerBits: 1,
        bitrateIdx: 8,
        srIdx: 0,
        channelMode: 3,
      );
      mpeg2Frame.setRange(13, 17, 'Info'.codeUnits);
      ByteData.sublistView(mpeg2Frame)
        ..setUint32(17, 0x01, Endian.big)
        ..setUint32(21, 50, Endian.big); // 50 * 576 / 22050
      expect(
        estimateMp3Duration(mpeg2Frame).inMicroseconds,
        equals((50 * 576 * 1000000.0 / 22050).round()),
      );

      // MPEG-2.5 stereo (576 samples/frame, 11025 Hz): side info = 17 -> Xing at offset 21.
      final mpeg25Frame = _mp3Frame(
        versionBits: 0,
        layerBits: 1,
        bitrateIdx: 8,
        srIdx: 0,
        channelMode: 0,
      );
      mpeg25Frame.setRange(21, 25, 'Xing'.codeUnits);
      ByteData.sublistView(mpeg25Frame)
        ..setUint32(25, 0x01, Endian.big)
        ..setUint32(29, 25, Endian.big);
      expect(
        estimateMp3Duration(mpeg25Frame).inMicroseconds,
        equals((25 * 576 * 1000000.0 / 11025).round()),
      );
    });

    test('parses VBRI frame counts at offset 36', () {
      // MPEG-1 48000 Hz (srIdx 1), 192 kbps (idx 11) -> 576 bytes.
      final frame = _mp3Frame(
        versionBits: 3,
        layerBits: 1,
        bitrateIdx: 11,
        srIdx: 1,
      );
      frame.setRange(36, 40, 'VBRI'.codeUnits);
      ByteData.sublistView(frame).setUint32(50, 200, Endian.big);
      expect(
        estimateMp3Duration(frame).inMicroseconds,
        equals((200 * 1152 * 1000000.0 / 48000).round()),
      );
    });

    test(
      'rejects ADTS AAC (layer == 0), empty/short, and false sync garbage',
      () {
        // ADTS AAC sync: 0xFF 0xF1 (versionBits=2, layerBits=0)
        final adtsAac = Uint8List.fromList([
          0xFF,
          0xF1,
          0x50,
          0x80,
          0x02,
          0x1F,
          0xFC,
          0x00,
          0xFF,
          0xF1,
          0x50,
          0x80,
        ]);
        expect(estimateMp3Duration(adtsAac), equals(Duration.zero));
        expect(estimateMp3Duration(Uint8List(0)), equals(Duration.zero));
        expect(
          estimateMp3Duration(Uint8List.fromList([0x49, 0x44, 0x33, 1, 2, 3])),
          equals(Duration.zero),
        );

        // Single false sync followed by non-sync payload fails next-frame check.
        final falseSync = Uint8List(900);
        falseSync[0] = 0xFF;
        falseSync[1] = 0xFB;
        falseSync[2] = 0x90;
        falseSync[3] = 0x00;
        expect(estimateMp3Duration(falseSync), equals(Duration.zero));
      },
    );
  });
}
