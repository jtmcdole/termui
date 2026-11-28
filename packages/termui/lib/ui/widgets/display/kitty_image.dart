import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:termui/termui.dart';

/// The Unicode code point (`U+10EEEE`) used by the Kitty Graphics Protocol
/// for Unicode virtual placements (`U=1`).
const int kittyPlaceholderCodePoint = 0x10EEEE;

/// The UTF-16 string representation of `U+10EEEE`.
const String kittyPlaceholderChar = '\u{10EEEE}';

/// Official Kitty Graphics row/column/MSB combining diacritics table (indices `0..296`).
const List<int> kittyDiacritics = [
  0x0305,
  0x030D,
  0x030E,
  0x0310,
  0x0312,
  0x033D,
  0x033E,
  0x033F,
  0x0346,
  0x034A,
  0x034B,
  0x034C,
  0x0350,
  0x0351,
  0x0352,
  0x0357,
  0x035B,
  0x0363,
  0x0364,
  0x0365,
  0x0366,
  0x0367,
  0x0368,
  0x0369,
  0x036A,
  0x036B,
  0x036C,
  0x036D,
  0x036E,
  0x036F,
  0x0483,
  0x0484,
  0x0485,
  0x0486,
  0x0487,
  0x0592,
  0x0593,
  0x0594,
  0x0595,
  0x0597,
  0x0598,
  0x0599,
  0x059C,
  0x059D,
  0x059E,
  0x059F,
  0x05A0,
  0x05A1,
  0x05A8,
  0x05A9,
  0x05AB,
  0x05AC,
  0x05AF,
  0x05C4,
  0x0610,
  0x0611,
  0x0612,
  0x0613,
  0x0614,
  0x0615,
  0x0616,
  0x0617,
  0x0657,
  0x0658,
  0x0659,
  0x065A,
  0x065B,
  0x065D,
  0x065E,
  0x06D6,
  0x06D7,
  0x06D8,
  0x06D9,
  0x06DA,
  0x06DB,
  0x06DC,
  0x06DF,
  0x06E0,
  0x06E1,
  0x06E2,
  0x06E4,
  0x06E7,
  0x06E8,
  0x06EB,
  0x06EC,
  0x0730,
  0x0732,
  0x0733,
  0x0735,
  0x0736,
  0x073A,
  0x073D,
  0x073F,
  0x0740,
  0x0741,
  0x0743,
  0x0745,
  0x0747,
  0x0749,
  0x074A,
  0x07EB,
  0x07EC,
  0x07ED,
  0x07EE,
  0x07EF,
  0x07F0,
  0x07F1,
  0x07F3,
  0x0816,
  0x0817,
  0x0818,
  0x0819,
  0x081B,
  0x081C,
  0x081D,
  0x081E,
  0x081F,
  0x0820,
  0x0821,
  0x0822,
  0x0823,
  0x0825,
  0x0826,
  0x0827,
  0x0829,
  0x082A,
  0x082B,
  0x082C,
  0x082D,
  0x08D4,
  0x08D5,
  0x08D6,
  0x08D7,
  0x08D8,
  0x08D9,
  0x08DA,
  0x08DB,
  0x08DC,
  0x08DD,
  0x08DE,
  0x08DF,
  0x08E0,
  0x08E1,
  0x08E4,
  0x08E5,
  0x08E7,
  0x08E8,
  0x08EA,
  0x08EB,
  0x08EC,
  0x08F3,
  0x08F4,
  0x08F5,
  0x08F7,
  0x08F8,
  0x08FB,
  0x08FC,
  0x08FD,
  0x08FE,
  0x08FF,
  0x0951,
  0x0953,
  0x0954,
  0x09FE,
  0x0F82,
  0x0F83,
  0x0F86,
  0x0F87,
  0x135D,
  0x135E,
  0x135F,
  0x17DD,
  0x193A,
  0x1A17,
  0x1A75,
  0x1A76,
  0x1A77,
  0x1A78,
  0x1A79,
  0x1A7A,
  0x1A7B,
  0x1A7C,
  0x1AB0,
  0x1AB1,
  0x1AB2,
  0x1AB3,
  0x1AB4,
  0x1ABB,
  0x1ABC,
  0x1B6B,
  0x1B6D,
  0x1B6E,
  0x1B6F,
  0x1B70,
  0x1B71,
  0x1B72,
  0x1B73,
  0x1CD0,
  0x1CD1,
  0x1CD2,
  0x1CDA,
  0x1CDB,
  0x1CE0,
  0x1CF4,
  0x1CF8,
  0x1CF9,
  0x1DC0,
  0x1DC1,
  0x1DC3,
  0x1DC4,
  0x1DC5,
  0x1DC6,
  0x1DC7,
  0x1DC8,
  0x1DC9,
  0x1DCB,
  0x1DCC,
  0x1DD1,
  0x1DD2,
  0x1DD3,
  0x1DD4,
  0x1DD5,
  0x1DD6,
  0x1DD7,
  0x1DD8,
  0x1DD9,
  0x1DDA,
  0x1DDB,
  0x1DDC,
  0x1DDD,
  0x1DDE,
  0x1DDF,
  0x1DE0,
  0x1DE1,
  0x1DE2,
  0x1DE3,
  0x1DE4,
  0x1DE5,
  0x1DE6,
  0x1DE7,
  0x1DE8,
  0x1DE9,
  0x1DEA,
  0x1DEB,
  0x1DEC,
  0x1DED,
  0x1DEE,
  0x1DEF,
  0x1DF0,
  0x1DF1,
  0x1DF2,
  0x1DF3,
  0x1DF4,
  0x1DF5,
  0x1DFB,
  0x1DFE,
  0x20D0,
  0x20D1,
  0x20D4,
  0x20D5,
  0x20D6,
  0x20D7,
  0x20DB,
  0x20DC,
  0x20E1,
  0x20E7,
  0x20E9,
  0x20F0,
  0x2CEF,
  0x2CF0,
  0x2CF1,
  0x2DE0,
  0x2DE1,
  0x2DE2,
  0x2DE3,
  0x2DE4,
  0x2DE5,
  0x2DE6,
  0x2DE7,
  0x2DE8,
  0x2DE9,
  0x2DEA,
  0x2DEB,
  0x2DEC,
  0x2DED,
  0x2DEE,
  0x2DEF,
  0x2DF0,
  0x2DF1,
  0x2DF2,
  0x2DF3,
  0x2DF4,
  0x2DF5,
  0x2DF6,
  0x2DF7,
  0x2DF8,
  0x2DF9,
];

final Map<int, int> _diacriticToIndex = {
  for (var i = 0; i < kittyDiacritics.length; i++) kittyDiacritics[i]: i,
};

/// Returns the Kitty Unicode placeholder grapheme for tile ([row], [col]).
///
/// When [imageIdMsb] is greater than 0, a 4th combining diacritic encoding the
/// most-significant 8 bits (`(imageId >> 24) & 0xFF`) is appended, supporting
/// full 32-bit Kitty image IDs.
String kittyPlaceholderCell(int row, int col, {int imageIdMsb = 0}) {
  final rIdx = row.clamp(0, kittyDiacritics.length - 1);
  final cIdx = col.clamp(0, kittyDiacritics.length - 1);
  if (imageIdMsb > 0) {
    final mIdx = imageIdMsb.clamp(0, kittyDiacritics.length - 1);
    return '$kittyPlaceholderChar${String.fromCharCode(kittyDiacritics[rIdx])}${String.fromCharCode(kittyDiacritics[cIdx])}${String.fromCharCode(kittyDiacritics[mIdx])}';
  }
  return '$kittyPlaceholderChar${String.fromCharCode(kittyDiacritics[rIdx])}${String.fromCharCode(kittyDiacritics[cIdx])}';
}

/// Parses a Kitty Unicode placeholder grapheme into its `(row, col, imageIdMsb)` tile coordinates,
/// or returns `null` if [grapheme] is not a valid `U+10EEEE` placeholder cell with at least a row diacritic.
///
/// For 1-diacritic shorthand cells (`U+10EEEE` + row diacritic), `col` defaults to `0`
/// and `imageIdMsb` is `null`.
({int row, int col, int? imageIdMsb})? parseKittyPlaceholderCell(
  String grapheme,
) {
  if (grapheme.length < 3 || !grapheme.startsWith(kittyPlaceholderChar)) {
    return null;
  }
  final row = _diacriticToIndex[grapheme.codeUnitAt(2)];
  if (row == null) return null;
  if (grapheme.length == 3) {
    return (row: row, col: 0, imageIdMsb: null);
  }
  final col = _diacriticToIndex[grapheme.codeUnitAt(3)];
  if (col == null) return null;
  int? imageIdMsb;
  if (grapheme.length >= 5) {
    imageIdMsb = _diacriticToIndex[grapheme.codeUnitAt(4)];
  }
  return (row: row, col: col, imageIdMsb: imageIdMsb);
}

/// Extracts the 32-bit Kitty `imageId` from a `U+10EEEE` placeholder [grapheme]
/// and cell [fgArgb] without allocating coordinate records.
///
/// 24-bit [fgArgb] image IDs must pack `0xFF00_0000 | id` because the
/// `0x0001_0000..0x0001_00FF` range is reserved for `Color.ansi` indexed colors.
int extractKittyCellImageId(String grapheme, int fgArgb) {
  final low24 = fgArgb.isAnsiIndexed ? fgArgb.ansiIndex : (fgArgb & 0xFF_FFFF);
  if (grapheme.length < 5) return low24;
  final msb = _diacriticToIndex[grapheme.codeUnitAt(4)] ?? 0;
  return ((msb & 0xFF) << 24) | low24;
}

/// Immutable RGBA pixel buffer and grid placement metadata for a Kitty image.
final class KittyImageData {
  /// Kitty Graphics `f=` transmission code for 24-bit raw RGB (3 bytes per pixel).
  static const int formatRgb24 = 24;

  /// Kitty Graphics `f=` transmission code for 32-bit raw RGBA (4 bytes per pixel, protocol default).
  static const int formatRgba32 = 32;

  /// Kitty Graphics `f=` transmission code for PNG-encoded image byte streams.
  static const int formatPng = 100;

  /// Unique 32-bit Kitty image ID (`1..0xFFFFFFFF`).
  final int imageId;

  /// Source image width in pixels.
  final int pixelWidth;

  /// Source image height in pixels.
  final int pixelHeight;

  /// Raw RGBA8888 or PNG pixel bytes.
  final Uint8List rgbaPixels;

  /// Target placement width in terminal columns.
  final int gridCols;

  /// Target placement height in terminal rows.
  final int gridRows;

  /// Optional version counter incremented when pixel contents change for the same [imageId].
  final int version;

  /// Format flag (`f=`): [formatRgba32] for 32-bit RGBA or [formatPng] for PNG
  /// in stored [rgbaPixels] buffers; [formatRgb24] is used for 24-bit wire queries/APC.
  final int format;

  /// Creates a [KittyImageData] descriptor.
  const KittyImageData({
    required this.imageId,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.rgbaPixels,
    required this.gridCols,
    required this.gridRows,
    this.version = 0,
    this.format = formatRgba32,
  });

  /// Creates a [KittyImageData] descriptor from pre-compressed PNG bytes (`f=100`).
  factory KittyImageData.fromPng({
    required int imageId,
    required int pixelWidth,
    required int pixelHeight,
    required Uint8List pngBytes,
    required int gridCols,
    required int gridRows,
    int version = 0,
  }) => KittyImageData(
    imageId: imageId,
    pixelWidth: pixelWidth,
    pixelHeight: pixelHeight,
    rgbaPixels: pngBytes,
    gridCols: gridCols,
    gridRows: gridRows,
    version: version,
    format: formatPng,
  );

  /// Builds a Kitty Graphics capability query sequence (`a=q`).
  static String buildCapabilityQuery({int queryId = 31}) =>
      '\x1b_Gi=$queryId,s=1,v=1,a=q,t=d,f=$formatRgb24;AAAA\x1b\\\x1b[c';

  /// Returns whether [other] has identical image metadata, grid size, version,
  /// format, and underlying [rgbaPixels] buffer identity.
  bool isSameContentAs(KittyImageData other) =>
      identical(this, other) ||
      ((imageId & 0xFFFFFFFF) == (other.imageId & 0xFFFFFFFF) &&
          pixelWidth == other.pixelWidth &&
          pixelHeight == other.pixelHeight &&
          gridCols == other.gridCols &&
          gridRows == other.gridRows &&
          version == other.version &&
          format == other.format &&
          identical(rgbaPixels, other.rgbaPixels));

  /// Returns a copy of this [KittyImageData] with updated fields.
  KittyImageData copyWith({
    int? imageId,
    int? pixelWidth,
    int? pixelHeight,
    Uint8List? rgbaPixels,
    int? gridCols,
    int? gridRows,
    int? version,
    int? format,
  }) => KittyImageData(
    imageId: imageId ?? this.imageId,
    pixelWidth: pixelWidth ?? this.pixelWidth,
    pixelHeight: pixelHeight ?? this.pixelHeight,
    rgbaPixels: rgbaPixels ?? this.rgbaPixels,
    gridCols: gridCols ?? this.gridCols,
    gridRows: gridRows ?? this.gridRows,
    version: version ?? this.version,
    format: format ?? this.format,
  );

  /// Encodes the Kitty Graphics `APC` upload (`a=t,f=...`) and virtual placement
  /// (`a=p,U=1`) sequences for CLI terminals.
  ///
  /// When [compress] is `true` (and [format] is [formatRgba32]), the RGBA payload
  /// is compressed with zlib (`o=z`). [chunkSize] must be a positive multiple of 4.
  String toApcSequence({int chunkSize = 4096, bool compress = false}) {
    if (chunkSize <= 0 || chunkSize % 4 != 0) {
      throw ArgumentError.value(
        chunkSize,
        'chunkSize',
        'must be a positive multiple of 4',
      );
    }
    final useZlib = compress && format == formatRgba32;
    final bytesToSend = useZlib
        ? Uint8List.fromList(zlib.encode(rgbaPixels))
        : rgbaPixels;
    final encoded = base64Encode(bytesToSend);
    final compFlag = useZlib ? ',o=z' : '';
    final header =
        'a=t,f=$format$compFlag,s=$pixelWidth,v=$pixelHeight,i=$imageId,q=2';

    final sb = StringBuffer();
    _writeApcChunks(sb, header, encoded, chunkSize);
    sb.write('\x1b_Ga=p,U=1,i=$imageId,c=$gridCols,r=$gridRows,q=2\x1b\\');
    return sb.toString();
  }

  static void _writeApcChunks(
    StringBuffer sb,
    String header,
    String encoded,
    int chunkSize,
  ) {
    if (encoded.length <= chunkSize) {
      sb.write('\x1b_G$header;$encoded\x1b\\');
      return;
    }
    for (var offset = 0; offset < encoded.length; offset += chunkSize) {
      final end = min(offset + chunkSize, encoded.length);
      final more = end < encoded.length ? 1 : 0;
      final chunk = encoded.substring(offset, end);
      final ctrl = offset == 0 ? '$header,m=$more' : 'm=$more,q=2';
      sb.write('\x1b_G$ctrl;$chunk\x1b\\');
    }
  }
}

/// Metadata for a Kitty Graphics Protocol image placement (`a=T` or `a=p`).
final class KittyPlacement {
  /// Z-index threshold below which placements render under non-default cell
  /// background colors (`INT32_MIN ~/ 2`).
  static const int underBackgroundZThreshold = -1073741824;

  /// Unique 32-bit Kitty image ID (`1..0xFFFFFFFF`).
  final int imageId;

  /// Placement ID (`0` for default/anonymous placement, `1..0xFFFFFFFF` explicit).
  final int placementId;

  /// Whether this placement is a Unicode virtual placement (`U=1`).
  final bool isVirtual;

  /// Whether this placement belongs to the alternate screen (`true`) or primary
  /// screen (`false`).
  final bool isAltScreen;

  /// 0-based anchor column in terminal grid coordinates.
  final int gridCol;

  /// 0-based anchor row in terminal grid coordinates (may become negative as
  /// the primary screen scrolls into scrollback).
  final int gridRow;

  /// Placement width in terminal columns.
  final int cols;

  /// Placement height in terminal rows.
  final int rows;

  /// Source crop X offset in image pixels (`x=`, default `0`).
  final int srcX;

  /// Source crop Y offset in image pixels (`y=`, default `0`).
  final int srcY;

  /// Source crop width in image pixels (`w=`, `0` means full remaining width).
  final int srcWidth;

  /// Source crop height in image pixels (`h=`, `0` means full remaining height).
  final int srcHeight;

  /// Sub-cell horizontal pixel offset within the anchor cell (`X=`, default `0`).
  final int cellOffsetX;

  /// Sub-cell vertical pixel offset within the anchor cell (`Y=`, default `0`).
  final int cellOffsetY;

  /// Signed 32-bit layering z-index (`z=`, default `0`).
  final int zIndex;

  /// Relative parent image ID (`P=`, `0` when non-relative).
  final int parentImageId;

  /// Relative parent placement ID (`Q=`, `0` when non-relative).
  final int parentPlacementId;

  /// Horizontal cell offset from the relative parent (`H=`, default `0`).
  final int relCols;

  /// Vertical cell offset from the relative parent (`V=`, default `0`).
  final int relRows;

  /// Creates a [KittyPlacement] descriptor.
  const KittyPlacement({
    required this.imageId,
    this.placementId = 0,
    this.isVirtual = false,
    this.isAltScreen = false,
    this.gridCol = 0,
    this.gridRow = 0,
    required this.cols,
    required this.rows,
    this.srcX = 0,
    this.srcY = 0,
    this.srcWidth = 0,
    this.srcHeight = 0,
    this.cellOffsetX = 0,
    this.cellOffsetY = 0,
    this.zIndex = 0,
    this.parentImageId = 0,
    this.parentPlacementId = 0,
    this.relCols = 0,
    this.relRows = 0,
  });

  /// Whether this placement is positioned relative to another placement (`P > 0`).
  bool get isRelative => parentImageId > 0;

  /// Returns a copy of this placement with updated fields.
  KittyPlacement copyWith({
    int? imageId,
    int? placementId,
    bool? isVirtual,
    bool? isAltScreen,
    int? gridCol,
    int? gridRow,
    int? cols,
    int? rows,
    int? srcX,
    int? srcY,
    int? srcWidth,
    int? srcHeight,
    int? cellOffsetX,
    int? cellOffsetY,
    int? zIndex,
    int? parentImageId,
    int? parentPlacementId,
    int? relCols,
    int? relRows,
  }) => KittyPlacement(
    imageId: imageId ?? this.imageId,
    placementId: placementId ?? this.placementId,
    isVirtual: isVirtual ?? this.isVirtual,
    isAltScreen: isAltScreen ?? this.isAltScreen,
    gridCol: gridCol ?? this.gridCol,
    gridRow: gridRow ?? this.gridRow,
    cols: cols ?? this.cols,
    rows: rows ?? this.rows,
    srcX: srcX ?? this.srcX,
    srcY: srcY ?? this.srcY,
    srcWidth: srcWidth ?? this.srcWidth,
    srcHeight: srcHeight ?? this.srcHeight,
    cellOffsetX: cellOffsetX ?? this.cellOffsetX,
    cellOffsetY: cellOffsetY ?? this.cellOffsetY,
    zIndex: zIndex ?? this.zIndex,
    parentImageId: parentImageId ?? this.parentImageId,
    parentPlacementId: parentPlacementId ?? this.parentPlacementId,
    relCols: relCols ?? this.relCols,
    relRows: relRows ?? this.relRows,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is KittyPlacement &&
          imageId == other.imageId &&
          placementId == other.placementId &&
          isVirtual == other.isVirtual &&
          isAltScreen == other.isAltScreen &&
          gridCol == other.gridCol &&
          gridRow == other.gridRow &&
          cols == other.cols &&
          rows == other.rows &&
          srcX == other.srcX &&
          srcY == other.srcY &&
          srcWidth == other.srcWidth &&
          srcHeight == other.srcHeight &&
          cellOffsetX == other.cellOffsetX &&
          cellOffsetY == other.cellOffsetY &&
          zIndex == other.zIndex &&
          parentImageId == other.parentImageId &&
          parentPlacementId == other.parentPlacementId &&
          relCols == other.relCols &&
          relRows == other.relRows);

  @override
  int get hashCode => Object.hashAll([
    imageId,
    placementId,
    isVirtual,
    isAltScreen,
    gridCol,
    gridRow,
    cols,
    rows,
    srcX,
    srcY,
    srcWidth,
    srcHeight,
    cellOffsetX,
    cellOffsetY,
    zIndex,
    parentImageId,
    parentPlacementId,
    relCols,
    relRows,
  ]);
}

/// Playback mode for a Kitty Graphics animation (`a=a,s=1|2|3`).
enum KittyAnimationPlayback {
  /// Animation is paused (`s=1`).
  stopped,

  /// Animation plays available frames and pauses at the last frame while
  /// waiting for additional frames (`s=2`).
  loading,

  /// Animation plays continuously and loops according to `loopCount` (`s=3`).
  running,
}

/// A single immutable frame in a Kitty Graphics animation (`a=f` / `a=c`).
///
/// Holds a pre-built, stable [imageData] instance created when the frame is
/// uploaded or composed so identity-keyed downstream GPU texture caches keep
/// textures warm without per-tick allocation or flicker.
final class KittyAnimationFrame {
  /// 1-based frame index (`r=`).
  final int frameNumber;

  /// Stable pre-built [KittyImageData] for this frame's pixel buffer.
  final KittyImageData imageData;

  /// Frame delay in milliseconds (`z=`): `< 0` gapless (`0 ms`), `0` default
  /// gap, `> 0` explicit delay in milliseconds.
  final int gapMs;

  /// Creates a [KittyAnimationFrame].
  const KittyAnimationFrame({
    required this.frameNumber,
    required this.imageData,
    this.gapMs = 0,
  });

  /// Returns a copy of this frame with updated fields.
  KittyAnimationFrame copyWith({
    int? frameNumber,
    KittyImageData? imageData,
    int? gapMs,
  }) => KittyAnimationFrame(
    frameNumber: frameNumber ?? this.frameNumber,
    imageData: imageData ?? this.imageData,
    gapMs: gapMs ?? this.gapMs,
  );
}

/// Mutable playback and frame state for an animated Kitty image.
final class KittyAnimationState {
  /// 32-bit Kitty image ID owning this animation.
  final int imageId;

  /// Ordered animation frames (sorted by 1-based [KittyAnimationFrame.frameNumber]).
  final List<KittyAnimationFrame> frames;

  /// 0-based index of the currently active frame in [frames].
  int currentFrameIndex;

  /// Current animation playback mode.
  KittyAnimationPlayback playback;

  /// Maximum loop count (`0` = infinite; `> 0` = stop after `loopCount` loops).
  ///
  /// Kitty wire mapping (`a=a,v=`): `v=1` maps to `loopCount = 0` (infinite),
  /// `v=n` (`n > 1`) maps to `loopCount = n - 1`, and `v=0` leaves `loopCount`
  /// unchanged.
  int loopCount;

  /// Number of completed loops since playback started.
  int completedLoops;

  /// Last monotonic clock timestamp (milliseconds) used by
  /// [KittyImageRegistry.advanceAnimations] for idempotent stepping.
  int? lastStepMs;

  final Map<int, int> _chargedBytesByFrame = {};

  /// Creates a [KittyAnimationState] for [imageId].
  KittyAnimationState({
    required this.imageId,
    List<KittyAnimationFrame>? frames,
    this.currentFrameIndex = 0,
    this.playback = KittyAnimationPlayback.stopped,
    this.loopCount = 0,
    this.completedLoops = 0,
    this.lastStepMs,
  }) : frames = frames ?? [];

  int _chargedBytesFor(int frameNumber) =>
      _chargedBytesByFrame[frameNumber] ?? 0;

  int get _totalChargedBytes {
    var total = 0;
    for (final bytes in _chargedBytesByFrame.values) {
      total += bytes;
    }
    return total;
  }

  /// The currently active [KittyAnimationFrame].
  KittyAnimationFrame get activeFrame =>
      frames[currentFrameIndex.clamp(0, frames.length - 1)];

  /// The 1-based [KittyAnimationFrame.frameNumber] of the active frame, or `1`.
  int get currentFrameNumber => frames.isEmpty ? 1 : activeFrame.frameNumber;

  /// Whether this animation is actively advancing frames on clock ticks.
  bool get isActivelyStepping {
    if (frames.length <= 1) return false;
    return playback == KittyAnimationPlayback.running ||
        (playback == KittyAnimationPlayback.loading &&
            currentFrameIndex < frames.length - 1);
  }

  /// Finds the 0-based index of [frameNumber] in [frames], or `-1`.
  int indexOfFrame(int frameNumber) {
    for (var i = 0; i < frames.length; i++) {
      if (frames[i].frameNumber == frameNumber) return i;
    }
    return -1;
  }

  /// Effective frame delay in milliseconds for [frame].
  static int effectiveGapMs(KittyAnimationFrame frame) {
    if (frame.gapMs < 0) return 0;
    if (frame.gapMs == 0) return KittyImageRegistry.defaultFrameGapMs;
    return frame.gapMs;
  }
}

/// In-memory registry mapping 32-bit Kitty `imageId`s to [KittyImageData],
/// [KittyPlacement] metadata, and [KittyAnimationState] sequences.
///
/// Can be instantiated per terminal pane/session (and bound to a region via
/// [Buffer.registerKittyRegistry]) or accessed via [KittyImageRegistry.global]
/// for host-level [KittyImage] widgets.
class KittyImageRegistry {
  /// Maximum number of animation frames permitted per image (`a=f`).
  static const int maxFramesPerImage = 64;

  /// Maximum aggregate pixel bytes across all animation frames in one registry.
  static const int maxAnimationBytes = 32 * 1024 * 1024;

  /// Default per-frame delay in milliseconds when `gapMs == 0`.
  static const int defaultFrameGapMs = 40;

  /// Process-wide default registry used by host [KittyImage] widgets.
  static final KittyImageRegistry global = KittyImageRegistry();

  final Map<int, KittyImageData> _images = {};
  final Map<(int imageId, int placementId), KittyPlacement> _placements = {};
  final Map<int, KittyAnimationState> _animations = {};
  int _totalAnimationBytes = 0;
  bool _activeAltScreen = false;
  int _viewportScrollOffset = 0;
  int _revision = 0;

  /// Creates an empty [KittyImageRegistry].
  KittyImageRegistry();

  /// Monotonically increasing revision counter incremented whenever images,
  /// placements, screen/scroll state, or animation frames change.
  int get revision => _revision;

  /// Total RGBA/PNG bytes currently retained across animation frames.
  int get totalAnimationBytes => _totalAnimationBytes;

  /// Whether the owning terminal is currently displaying the alternate screen.
  bool get activeAltScreen => _activeAltScreen;

  set activeAltScreen(bool value) {
    if (_activeAltScreen == value) return;
    _activeAltScreen = value;
    _revision++;
  }

  /// Active primary-screen scrollback viewport offset (lines scrolled back).
  int get viewportScrollOffset => _viewportScrollOffset;

  set viewportScrollOffset(int value) {
    if (_viewportScrollOffset == value) return;
    _viewportScrollOffset = value;
    _revision++;
  }

  /// Registers or updates [data] in this registry under its 32-bit `imageId`.
  ///
  /// If an entry with identical dimensions, version, format, and [Uint8List]
  /// pixel reference is already registered, the existing [KittyImageData]
  /// instance is retained so downstream GPU texture caches stay warm.
  void registerImage(KittyImageData data) {
    final key = data.imageId & 0xFFFFFFFF;
    final existing = _images[key];
    if (existing != null && existing.isSameContentAs(data)) {
      return;
    }
    _images[key] = data;
    _revision++;
  }

  /// Looks up the [KittyImageData] for [imageId] in this registry, or `null`.
  KittyImageData? lookupImage(int imageId) => _images[imageId & 0xFFFFFFFF];

  /// Returns the currently active [KittyImageData] for [imageId].
  ///
  /// When [imageId] has registered animation frames, returns the stable
  /// pre-built [KittyImageData] of its active frame; otherwise falls back to
  /// [lookupImage].
  KittyImageData? activeImageData(int imageId) {
    final key = imageId & 0xFFFFFFFF;
    final anim = _animations[key];
    if (anim != null && anim.frames.isNotEmpty) {
      return anim.activeFrame.imageData;
    }
    return _images[key];
  }

  /// Removes the registered [KittyImageData] (plus any placements and animation
  /// frames) for [imageId] from this registry.
  void unregisterImage(int imageId) {
    final key = imageId & 0xFFFFFFFF;
    var changed = _images.remove(key) != null;
    if (_removePlacementsForImage(key)) changed = true;
    if (_removeAnimationInternal(key)) changed = true;
    if (changed) {
      _revision++;
    }
  }

  /// Removes all images, placements, and animations from this registry.
  void clearImages() {
    _images.clear();
    _placements.clear();
    _animations.clear();
    _totalAnimationBytes = 0;
    _activeAltScreen = false;
    _viewportScrollOffset = 0;
    _revision++;
  }

  /// Whether this registry currently holds at least one registered image.
  bool get hasImages => _images.isNotEmpty;

  /// Returns all 32-bit image IDs currently stored in this registry.
  Iterable<int> get registeredImageIds => _images.keys;

  /// Registers or updates a [KittyPlacement] keyed by `(imageId, placementId)`.
  void registerPlacement(KittyPlacement placement) {
    final key = (
      placement.imageId & 0xFFFFFFFF,
      placement.placementId & 0xFFFFFFFF,
    );
    _placements[key] = placement;
    _revision++;
  }

  /// Looks up the [KittyPlacement] for ([imageId], [placementId]), or `null`.
  KittyPlacement? lookupPlacement(int imageId, [int placementId = 0]) =>
      _placements[(imageId & 0xFFFFFFFF, placementId & 0xFFFFFFFF)];

  /// All placements currently stored in this registry.
  Iterable<KittyPlacement> get allPlacements => _placements.values;

  /// Whether this registry holds at least one placement.
  bool get hasPlacements => _placements.isNotEmpty;

  /// Removes a placement for [imageId].
  ///
  /// When [placementId] is `null`, removes all placements for [imageId].
  /// Returns `true` if at least one placement was removed.
  bool removePlacement(int imageId, [int? placementId]) {
    final maskedImageId = imageId & 0xFFFFFFFF;
    final removed = placementId == null
        ? _removePlacementsForImage(maskedImageId)
        : _placements.remove((maskedImageId, placementId & 0xFFFFFFFF)) != null;
    if (removed) {
      _revision++;
    }
    return removed;
  }

  /// Removes all placements satisfying [predicate] and returns the removed count.
  int removePlacementsWhere(bool Function(KittyPlacement placement) predicate) {
    final before = _placements.length;
    _placements.removeWhere((_, placement) => predicate(placement));
    final removed = before - _placements.length;
    if (removed > 0) {
      _revision++;
    }
    return removed;
  }

  /// Shifts non-virtual, non-relative direct placements on [altScreen] by
  /// [deltaRows] (e.g. `-1` when scrolling up by one line).
  ///
  /// When [minRow] or [maxRow] are supplied, only placements whose current
  /// `gridRow` lies within `[minRow, maxRow]` are shifted. When [evictAboveRow]
  /// is supplied, placements whose shifted bottom edge (`gridRow + rows`) is
  /// `<= evictAboveRow` are removed.
  void shiftDirectPlacements(
    int deltaRows, {
    bool altScreen = false,
    int? minRow,
    int? maxRow,
    int? evictAboveRow,
  }) {
    if (deltaRows == 0 || _placements.isEmpty) return;
    final toRemove = <(int, int)>[];
    final toUpdate = <((int, int), KittyPlacement)>[];
    for (final entry in _placements.entries) {
      final p = entry.value;
      if (!_shouldShiftPlacement(p, altScreen, minRow, maxRow)) continue;
      final nextRow = p.gridRow + deltaRows;
      if (evictAboveRow != null && nextRow + p.rows <= evictAboveRow) {
        toRemove.add(entry.key);
      } else {
        toUpdate.add((entry.key, p.copyWith(gridRow: nextRow)));
      }
    }
    if (toRemove.isNotEmpty) {
      for (final key in toRemove) {
        _placements.remove(key);
      }
      _cascadeRemoveRelativeChildren(toRemove.toSet());
    }
    for (final (key, updated) in toUpdate) {
      _placements[key] = updated;
    }
    if (toRemove.isNotEmpty || toUpdate.isNotEmpty) {
      _revision++;
    }
  }

  void _cascadeRemoveRelativeChildren(Set<(int, int)> evicted) {
    var frontier = evicted;
    while (frontier.isNotEmpty && _placements.isNotEmpty) {
      final nextEvicted = <(int, int)>[];
      for (final entry in _placements.entries) {
        final p = entry.value;
        if (p.isRelative &&
            frontier.contains((
              p.parentImageId & 0xFFFFFFFF,
              p.parentPlacementId & 0xFFFFFFFF,
            ))) {
          nextEvicted.add(entry.key);
        }
      }
      if (nextEvicted.isEmpty) break;
      for (final key in nextEvicted) {
        _placements.remove(key);
      }
      frontier = nextEvicted.toSet();
    }
  }

  static bool _shouldShiftPlacement(
    KittyPlacement placement,
    bool altScreen,
    int? minRow,
    int? maxRow,
  ) {
    if (placement.isVirtual || placement.isRelative) return false;
    if (placement.isAltScreen != altScreen) return false;
    if (minRow != null && placement.gridRow < minRow) return false;
    if (maxRow != null && placement.gridRow > maxRow) return false;
    return true;
  }

  /// Clears stored placements, optionally filtered by [altScreen] or [directOnly].
  void clearPlacements({bool? altScreen, bool directOnly = false}) {
    if (altScreen == null && !directOnly) {
      if (_placements.isEmpty) return;
      _placements.clear();
      _revision++;
      return;
    }
    removePlacementsWhere(
      (p) =>
          (altScreen == null || p.isAltScreen == altScreen) &&
          (!directOnly || !p.isVirtual),
    );
  }

  bool _removePlacementsForImage(int maskedImageId) {
    final before = _placements.length;
    _placements.removeWhere((key, _) => key.$1 == maskedImageId);
    return _placements.length != before;
  }

  /// Registers or replaces an animation [frame] for [imageId].
  ///
  /// Enforces [maxFramesPerImage] (`64`) and [maxAnimationBytes] (`32 MiB`).
  /// Returns `false` without mutating registry state if either limit would be
  /// exceeded.
  bool registerAnimationFrame(int imageId, KittyAnimationFrame frame) {
    final key = imageId & 0xFFFFFFFF;
    final existing = _animations[key];
    final existingIdx = existing?.indexOfFrame(frame.frameNumber) ?? -1;
    final newBytes = frame.imageData.rgbaPixels.length;

    if (existing != null && existingIdx >= 0) {
      final oldCharged = existing._chargedBytesFor(frame.frameNumber);
      final delta = newBytes - oldCharged;
      if (_totalAnimationBytes + delta > maxAnimationBytes) return false;
      existing.frames[existingIdx] = frame;
      existing._chargedBytesByFrame[frame.frameNumber] = newBytes;
      _totalAnimationBytes += delta;
      _revision++;
      return true;
    }

    final seedRoot =
        existing == null && frame.frameNumber > 1 && _images[key] != null;
    final projectedCount = (existing?.frames.length ?? 0) + (seedRoot ? 2 : 1);
    if (projectedCount > maxFramesPerImage ||
        _totalAnimationBytes + newBytes > maxAnimationBytes) {
      return false;
    }

    final target = existing ?? _createAnimationState(key, seedRoot: seedRoot);
    final hadFrames = target.frames.isNotEmpty;
    final insertedIdx = _insertSortedFrame(target.frames, frame);
    if (hadFrames && insertedIdx <= target.currentFrameIndex) {
      target.currentFrameIndex++;
    }
    target._chargedBytesByFrame[frame.frameNumber] = newBytes;
    _totalAnimationBytes += newBytes;
    _revision++;
    return true;
  }

  KittyAnimationState _createAnimationState(int key, {required bool seedRoot}) {
    final state = KittyAnimationState(imageId: key);
    if (seedRoot) {
      final root = _images[key];
      if (root != null) {
        state.frames.add(KittyAnimationFrame(frameNumber: 1, imageData: root));
        state._chargedBytesByFrame[1] = 0;
      }
    }
    _animations[key] = state;
    return state;
  }

  static int _insertSortedFrame(
    List<KittyAnimationFrame> frames,
    KittyAnimationFrame frame,
  ) {
    var idx = frames.length;
    while (idx > 0 && frames[idx - 1].frameNumber > frame.frameNumber) {
      idx--;
    }
    frames.insert(idx, frame);
    return idx;
  }

  /// Looks up the [KittyAnimationState] for [imageId], or `null`.
  KittyAnimationState? lookupAnimation(int imageId) =>
      _animations[imageId & 0xFFFFFFFF];

  /// Removes all animation frames for [imageId] and reclaims their byte budget.
  bool removeAnimationFrames(int imageId) {
    if (!_removeAnimationInternal(imageId & 0xFFFFFFFF)) return false;
    _revision++;
    return true;
  }

  /// Removes all animation states across every image in this registry and
  /// resets [totalAnimationBytes] to `0`.
  void clearAnimations() {
    if (_animations.isEmpty) return;
    _animations.clear();
    _totalAnimationBytes = 0;
    _revision++;
  }

  bool _removeAnimationInternal(int maskedImageId) {
    final removed = _animations.remove(maskedImageId);
    if (removed == null) return false;
    _totalAnimationBytes = max(
      0,
      _totalAnimationBytes - removed._totalChargedBytes,
    );
    return true;
  }

  /// Updates animation playback, loop count, active frame, or per-frame gap
  /// (`a=a`) for [imageId].
  ///
  /// For Kitty `a=a,v=`: pass `loopCount: 0` for `v=1` (infinite),
  /// `loopCount: v - 1` for `v > 1`, or omit `loopCount` (`null`) for `v=0`
  /// (unchanged). Returns `false` if [imageId] has neither an animation nor a
  /// registered image.
  bool setAnimationPlayback(
    int imageId, {
    KittyAnimationPlayback? playback,
    int? loopCount,
    int? currentFrameNumber,
    int? frameGapNumber,
    int? frameGapMs,
  }) {
    final key = imageId & 0xFFFFFFFF;
    final state = _obtainAnimationForControl(key);
    if (state == null) return false;
    _applyPlaybackControl(
      state,
      playback: playback,
      loopCount: loopCount,
      currentFrameNumber: currentFrameNumber,
      frameGapNumber: frameGapNumber,
      frameGapMs: frameGapMs,
    );
    _revision++;
    return true;
  }

  KittyAnimationState? _obtainAnimationForControl(int key) {
    final existing = _animations[key];
    if (existing != null) return existing;
    if (!_images.containsKey(key)) return null;
    return _createAnimationState(key, seedRoot: true);
  }

  static void _applyPlaybackControl(
    KittyAnimationState state, {
    KittyAnimationPlayback? playback,
    int? loopCount,
    int? currentFrameNumber,
    int? frameGapNumber,
    int? frameGapMs,
  }) {
    if (frameGapNumber != null && frameGapMs != null) {
      final idx = state.indexOfFrame(frameGapNumber);
      if (idx >= 0) {
        state.frames[idx] = state.frames[idx].copyWith(gapMs: frameGapMs);
      }
    }
    if (currentFrameNumber != null) {
      final idx = state.indexOfFrame(currentFrameNumber);
      if (idx >= 0) {
        state.currentFrameIndex = idx;
        state.lastStepMs = null;
      }
    }
    if (loopCount != null) {
      state.loopCount = max(0, loopCount);
      state.completedLoops = 0;
    }
    if (playback != null) {
      if (state.playback == KittyAnimationPlayback.stopped &&
          playback != KittyAnimationPlayback.stopped) {
        state.completedLoops = 0;
        state.lastStepMs = null;
      }
      state.playback = playback;
    }
  }

  /// Composes a rectangle from [sourceFrameNumber] onto [destFrameNumber]
  /// (`a=c`), producing a new stable [KittyImageData] for the destination frame.
  ///
  /// Both frames must be valid [KittyImageData.formatRgba32] buffers with
  /// positive dimensions and sufficient byte length. When [replace] is `true`,
  /// source pixels overwrite destination pixels; otherwise source pixels are
  /// alpha-blended over destination pixels.
  bool composeAnimationFrame(
    int imageId, {
    required int sourceFrameNumber,
    required int destFrameNumber,
    int srcX = 0,
    int srcY = 0,
    int dstX = 0,
    int dstY = 0,
    int? width,
    int? height,
    bool replace = false,
  }) {
    final key = imageId & 0xFFFFFFFF;
    final existing = _animations[key];
    final srcFrame = _peekAnimationFrame(key, existing, sourceFrameNumber);
    final dstFrame = _peekAnimationFrame(key, existing, destFrameNumber);
    if (srcFrame == null || dstFrame == null) return false;

    final srcData = srcFrame.imageData;
    final dstData = dstFrame.imageData;
    if (!_isValidRgbaBuffer(srcData) || !_isValidRgbaBuffer(dstData)) {
      return false;
    }
    if (srcX < 0 || srcY < 0 || dstX < 0 || dstY < 0) return false;

    final copyW = min(
      width ?? srcData.pixelWidth,
      min(srcData.pixelWidth - srcX, dstData.pixelWidth - dstX),
    );
    final copyH = min(
      height ?? srcData.pixelHeight,
      min(srcData.pixelHeight - srcY, dstData.pixelHeight - dstY),
    );
    if (copyW <= 0 || copyH <= 0) return false;

    final oldCharged = existing?._chargedBytesFor(destFrameNumber) ?? 0;
    final newCharged = dstData.rgbaPixels.length;
    final byteDelta = newCharged - oldCharged;
    if (_totalAnimationBytes + byteDelta > maxAnimationBytes) return false;

    final outPixels = Uint8List.fromList(dstData.rgbaPixels);
    _blitRgbaRect(
      src: srcData.rgbaPixels,
      srcStride: srcData.pixelWidth,
      dst: outPixels,
      dstStride: dstData.pixelWidth,
      srcX: srcX,
      srcY: srcY,
      dstX: dstX,
      dstY: dstY,
      copyW: copyW,
      copyH: copyH,
      replace: replace,
    );
    final updatedData = dstData.copyWith(
      rgbaPixels: outPixels,
      version: dstData.version + 1,
    );
    final state = existing ?? _createAnimationState(key, seedRoot: true);
    final dstIdx = state.indexOfFrame(destFrameNumber);
    state.frames[dstIdx] = dstFrame.copyWith(imageData: updatedData);
    state._chargedBytesByFrame[destFrameNumber] = newCharged;
    _totalAnimationBytes += byteDelta;
    _revision++;
    return true;
  }

  KittyAnimationFrame? _peekAnimationFrame(
    int key,
    KittyAnimationState? existing,
    int frameNumber,
  ) {
    if (existing != null) {
      final idx = existing.indexOfFrame(frameNumber);
      return idx >= 0 ? existing.frames[idx] : null;
    }
    if (frameNumber == 1) {
      final root = _images[key];
      if (root != null) {
        return KittyAnimationFrame(frameNumber: 1, imageData: root);
      }
    }
    return null;
  }

  static bool _isValidRgbaBuffer(KittyImageData data) =>
      data.format == KittyImageData.formatRgba32 &&
      data.pixelWidth > 0 &&
      data.pixelHeight > 0 &&
      data.rgbaPixels.length >= data.pixelWidth * data.pixelHeight * 4;

  static void _blitRgbaRect({
    required Uint8List src,
    required int srcStride,
    required Uint8List dst,
    required int dstStride,
    required int srcX,
    required int srcY,
    required int dstX,
    required int dstY,
    required int copyW,
    required int copyH,
    required bool replace,
  }) {
    for (var row = 0; row < copyH; row++) {
      var sOff = ((srcY + row) * srcStride + srcX) * 4;
      var dOff = ((dstY + row) * dstStride + dstX) * 4;
      for (var col = 0; col < copyW; col++, sOff += 4, dOff += 4) {
        if (replace) {
          dst[dOff] = src[sOff];
          dst[dOff + 1] = src[sOff + 1];
          dst[dOff + 2] = src[sOff + 2];
          dst[dOff + 3] = src[sOff + 3];
        } else {
          _alphaBlendRgbaPixel(src, sOff, dst, dOff);
        }
      }
    }
  }

  static void _alphaBlendRgbaPixel(
    Uint8List src,
    int sOff,
    Uint8List dst,
    int dOff,
  ) {
    final sA = src[sOff + 3];
    if (sA == 0) return;
    if (sA == 255) {
      dst[dOff] = src[sOff];
      dst[dOff + 1] = src[sOff + 1];
      dst[dOff + 2] = src[sOff + 2];
      dst[dOff + 3] = 255;
      return;
    }
    final invA = 255 - sA;
    final dA = dst[dOff + 3];
    final effDstA = (dA * invA) ~/ 255;
    final outA = sA + effDstA;
    if (outA == 0) return;
    dst[dOff] = (src[sOff] * sA + dst[dOff] * effDstA) ~/ outA;
    dst[dOff + 1] = (src[sOff + 1] * sA + dst[dOff + 1] * effDstA) ~/ outA;
    dst[dOff + 2] = (src[sOff + 2] * sA + dst[dOff + 2] * effDstA) ~/ outA;
    dst[dOff + 3] = outA;
  }

  /// Whether at least one animation in this registry is actively stepping.
  bool get hasRunningAnimations {
    for (final state in _animations.values) {
      if (state.isActivelyStepping) return true;
    }
    return false;
  }

  /// Advances all active animations using absolute monotonic clock [nowMs].
  ///
  /// Idempotent for repeated calls with the same [nowMs] across multiple
  /// surfaces sharing this registry. Increments [revision] and returns `true`
  /// if any animation stepped or transitioned playback state.
  bool advanceAnimations(int nowMs) {
    var anyChanged = false;
    for (final state in _animations.values) {
      if (_advanceSingleAnimation(state, nowMs)) {
        anyChanged = true;
      }
    }
    if (anyChanged) {
      _revision++;
    }
    return anyChanged;
  }

  static int _cycleDurationMs(KittyAnimationState state) {
    var total = 0;
    for (final frame in state.frames) {
      total += KittyAnimationState.effectiveGapMs(frame);
    }
    return total;
  }

  static ({int remaining, bool changed, bool stopped}) _fastForwardFiniteLoops(
    KittyAnimationState state,
    int remaining,
  ) {
    if (state.playback != KittyAnimationPlayback.running ||
        state.loopCount <= 0) {
      return (remaining: remaining, changed: false, stopped: false);
    }
    final cycleDuration = _cycleDurationMs(state);
    if (cycleDuration <= 0 || remaining < cycleDuration) {
      return (remaining: remaining, changed: false, stopped: false);
    }
    final skippedLoops = remaining ~/ cycleDuration;
    final remainingLoops = state.loopCount - state.completedLoops;
    if (skippedLoops >= remainingLoops) {
      state.completedLoops = state.loopCount;
      state.currentFrameIndex = state.frames.length - 1;
      state.playback = KittyAnimationPlayback.stopped;
      return (remaining: 0, changed: true, stopped: true);
    }
    state.completedLoops += skippedLoops;
    return (
      remaining: remaining - skippedLoops * cycleDuration,
      changed: true,
      stopped: false,
    );
  }

  static bool _advanceSingleAnimation(KittyAnimationState state, int nowMs) {
    if (!state.isActivelyStepping) return false;
    final last = state.lastStepMs;
    if (last == null) {
      state.lastStepMs = nowMs;
      return false;
    }
    if (nowMs <= last) return false;

    final ff = _fastForwardFiniteLoops(state, nowMs - last);
    if (ff.stopped) {
      state.lastStepMs = nowMs;
      return true;
    }
    var remaining = ff.remaining;
    var changed = ff.changed;
    final maxSteps = state.frames.length;
    for (var steps = 0; steps < maxSteps && state.isActivelyStepping; steps++) {
      final gap = KittyAnimationState.effectiveGapMs(state.activeFrame);
      if (remaining < gap) break;
      remaining -= gap;
      if (!_stepAnimationFrame(state)) {
        changed = true;
        break;
      }
      changed = true;
    }
    if (changed) {
      final nextGap = state.isActivelyStepping
          ? KittyAnimationState.effectiveGapMs(state.activeFrame)
          : 0;
      state.lastStepMs = nextGap > 0 && remaining < nextGap
          ? nowMs - remaining
          : nowMs;
    }
    return changed;
  }

  /// Advances [state] by one frame; returns `false` if playback stopped.
  static bool _stepAnimationFrame(KittyAnimationState state) {
    final nextIndex = state.currentFrameIndex + 1;
    if (nextIndex < state.frames.length) {
      state.currentFrameIndex = nextIndex;
      return true;
    }
    if (state.playback == KittyAnimationPlayback.loading) {
      return false;
    }
    state.completedLoops++;
    if (state.loopCount > 0 && state.completedLoops >= state.loopCount) {
      state.playback = KittyAnimationPlayback.stopped;
      return false;
    }
    state.currentFrameIndex = 0;
    return true;
  }

  /// Registers or updates [data] in [global].
  static void register(KittyImageData data) => global.registerImage(data);

  /// Looks up [imageId] in [global], or returns `null`.
  static KittyImageData? lookup(int imageId) => global.lookupImage(imageId);

  /// Removes [imageId] from [global], if present.
  static void unregister(int imageId) => global.unregisterImage(imageId);

  /// Removes all registered images from [global].
  static void clear() => global.clearImages();
}

/// A widget that renders an RGBA image using Kitty Graphics Unicode Placeholders (`U+10EEEE`).
///
/// Each cell within the widget's layout bounds is populated with `\u{10EEEE}`
/// followed by row and column combining diacritics, `fg = 0xFF000000 | imageId`,
/// and [Modifier.kittyPlaceholder]. Because each cell is a standard 1-column
/// grapheme in [Buffer], overlapping windows in [Compositor] occlude the image
/// cleanly at cell boundaries.
class KittyImage extends Widget {
  /// Unique 32-bit Kitty image identifier (`1..0xFFFFFFFF`).
  final int imageId;

  /// Width of [rgbaPixels] in pixels.
  final int pixelWidth;

  /// Height of [rgbaPixels] in pixels.
  final int pixelHeight;

  /// Raw RGBA8888 pixel buffer (`pixelWidth * pixelHeight * 4` bytes).
  final Uint8List rgbaPixels;

  /// Optional explicit column width (defaults to available constraint width).
  final int? columns;

  /// Optional explicit row height (defaults to available constraint height).
  final int? rows;

  /// Version number incremented when [rgbaPixels] mutates under the same [imageId].
  final int version;

  /// Creates a [KittyImage] widget.
  const KittyImage({
    super.key,
    required this.imageId,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.rgbaPixels,
    this.columns,
    this.rows,
    this.version = 0,
  });

  @override
  int getIntrinsicWidth(int height) => columns ?? max(1, pixelWidth ~/ 8);

  @override
  int getIntrinsicHeight(int width) => rows ?? max(1, pixelHeight ~/ 16);

  @override
  Element createElement() => KittyImageElement(this);
}

/// Element that lays out and paints a [KittyImage] into a [Buffer].
class KittyImageElement extends Element {
  List<String>? _cachedCells;
  int _cachedCols = 0;
  int _cachedRows = 0;
  int _cachedMsb = -1;

  /// Creates a [KittyImageElement].
  KittyImageElement(KittyImage super.widget);

  List<String> _ensureCellTable(int cols, int rows, int msb) {
    final existing = _cachedCells;
    if (existing != null &&
        _cachedCols == cols &&
        _cachedRows == rows &&
        _cachedMsb == msb) {
      return existing;
    }
    final built = List<String>.generate(
      cols * rows,
      (idx) => kittyPlaceholderCell(idx ~/ cols, idx % cols, imageIdMsb: msb),
      growable: false,
    );
    _cachedCells = built;
    _cachedCols = cols;
    _cachedRows = rows;
    _cachedMsb = msb;
    return built;
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    final img = widget as KittyImage;
    final targetW =
        img.columns ??
        (constraints.maxWidth == BoxConstraints.infinity
            ? img.getIntrinsicWidth(constraints.maxHeight)
            : constraints.maxWidth);
    final targetH =
        img.rows ??
        (constraints.maxHeight == BoxConstraints.infinity
            ? img.getIntrinsicHeight(targetW)
            : constraints.maxHeight);
    final clampedW = min(max(1, targetW), kittyDiacritics.length);
    final clampedH = min(max(1, targetH), kittyDiacritics.length);
    return constraints.constrain(Size(clampedW, clampedH));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final img = widget as KittyImage;
    final cols = min(size.width, kittyDiacritics.length);
    final rows = min(size.height, kittyDiacritics.length);
    if (cols <= 0 || rows <= 0) return;

    final validId = (img.imageId & 0xFFFFFFFF) == 0
        ? 1
        : (img.imageId & 0xFFFFFFFF);
    final msb = (validId >>> 24) & 0xFF;
    KittyImageRegistry.register(
      KittyImageData(
        imageId: validId,
        pixelWidth: img.pixelWidth,
        pixelHeight: img.pixelHeight,
        rgbaPixels: img.rgbaPixels,
        gridCols: cols,
        gridRows: rows,
        version: img.version,
      ),
    );
    buffer.registerKittyRegistry(
      Rect(offset.dx, offset.dy, cols, rows),
      KittyImageRegistry.global,
    );

    final cells = _ensureCellTable(cols, rows, msb);
    final fgArgb = 0xFF000000 | (validId & 0xFFFFFF);
    var cellIdx = 0;
    for (var ry = 0; ry < rows; ry++) {
      final by = offset.dy + ry;
      for (var rx = 0; rx < cols; rx++, cellIdx++) {
        buffer.setAttributes(
          offset.dx + rx,
          by,
          char: cells[cellIdx],
          fg: fgArgb,
          bg: 0,
          modifiers: Modifier.kittyPlaceholder,
          blend: false,
        );
      }
    }
  }
}
