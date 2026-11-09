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
/// or returns `null` if [grapheme] is not a valid `U+10EEEE` placeholder cell.
({int row, int col, int? imageIdMsb})? parseKittyPlaceholderCell(
  String grapheme,
) {
  if (grapheme.length < 4 || !grapheme.startsWith(kittyPlaceholderChar)) {
    return null;
  }
  final row = _diacriticToIndex[grapheme.codeUnitAt(2)];
  final col = _diacriticToIndex[grapheme.codeUnitAt(3)];
  if (row == null || col == null) return null;
  int? imageIdMsb;
  if (grapheme.length >= 5) {
    imageIdMsb = _diacriticToIndex[grapheme.codeUnitAt(4)];
  }
  return (row: row, col: col, imageIdMsb: imageIdMsb);
}

/// Extracts the 32-bit Kitty `imageId` from a `U+10EEEE` placeholder [grapheme]
/// and cell [fgArgb] without allocating coordinate records.
int extractKittyCellImageId(String grapheme, int fgArgb) {
  final low24 = fgArgb & 0xFFFFFF;
  if (grapheme.length < 5) return low24;
  final msb = _diacriticToIndex[grapheme.codeUnitAt(4)] ?? 0;
  return ((msb & 0xFF) << 24) | low24;
}

/// Immutable RGBA pixel buffer and grid placement metadata for a Kitty image.
final class KittyImageData {
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

  /// Format flag: 32 for RGBA8888, 100 for PNG.
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
    this.format = 32,
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
    format: 100,
  );

  /// Builds a Kitty Graphics capability query sequence (`a=q`).
  static String buildCapabilityQuery({int queryId = 31}) =>
      '\x1b_Gi=$queryId,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\\x1b[c';

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
  /// When [compress] is `true` (and [format] is 32), the RGBA payload is compressed
  /// with zlib (`o=z`). [chunkSize] must be a positive multiple of 4.
  String toApcSequence({int chunkSize = 4096, bool compress = false}) {
    if (chunkSize <= 0 || chunkSize % 4 != 0) {
      throw ArgumentError.value(
        chunkSize,
        'chunkSize',
        'must be a positive multiple of 4',
      );
    }
    final useZlib = compress && format == 32;
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

/// In-memory registry mapping 32-bit Kitty `imageId`s to [KittyImageData].
///
/// Can be instantiated per terminal pane/session (and bound to a region via
/// [Buffer.registerKittyRegistry]) or accessed via [KittyImageRegistry.global]
/// for host-level [KittyImage] widgets.
class KittyImageRegistry {
  /// Process-wide default registry used by host [KittyImage] widgets.
  static final KittyImageRegistry global = KittyImageRegistry();

  final Map<int, KittyImageData> _images = {};
  int _revision = 0;

  /// Creates an empty [KittyImageRegistry].
  KittyImageRegistry();

  /// Monotonically increasing revision counter incremented whenever images are
  /// registered, updated, unregistered, or cleared.
  int get revision => _revision;

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

  /// Removes the registered [KittyImageData] for [imageId] from this registry.
  void unregisterImage(int imageId) {
    if (_images.remove(imageId & 0xFFFFFFFF) != null) {
      _revision++;
    }
  }

  /// Removes all images from this registry.
  void clearImages() {
    _images.clear();
    _revision++;
  }

  /// Returns all 32-bit image IDs currently stored in this registry.
  Iterable<int> get registeredImageIds => _images.keys;

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
