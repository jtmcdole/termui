import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:termui/termui.dart';
import 'cell_quantizer.dart';
import 'symbol_map.dart';

typedef TinpotOutputCell = ({
  String character,
  int fgColorArgb,
  int bgColorArgb,
});

final class TermuiTinpot {
  final SymbolMap symbolMap;
  final int workFactor;

  /// When `true`, [convertBuffer] and [buildWidget] emit Kitty Graphics
  /// `U+10EEEE` Unicode placeholders instead of quantized mosaic characters.
  final bool enableKittyPassthrough;

  static final int _traceConvertId = Tracer.registerString('Tinpot:convert');
  static final int _traceResizeId = Tracer.registerString('Tinpot:copyResize');
  static final int _traceRowId = Tracer.registerString('Tinpot:quantizeRow');

  TermuiTinpot({
    SymbolMap? symbolMap,
    this.workFactor = 5,
    this.enableKittyPassthrough = false,
  }) : symbolMap = symbolMap ?? SymbolMap();

  late final List<SymbolCandidate> candidates = [
    for (final s in symbolMap.blockSymbols)
      if (s.character.runes.singleOrNull case final codePoint?)
        if (switch (codePoint) {
          0x0020 => true,
          >= 0x2580 && <= 0x259F => true,
          >= 0x2504 && <= 0x250B => false,
          >= 0x254C && <= 0x254F => false,
          >= 0x2574 && <= 0x257B => false,
          >= 0x2500 && <= 0x257F => true,
          _ => false,
        })
          s,
  ];

  /// Scales the image to match the terminal aspect ratio and grid size.
  /// Each terminal cell is 8x8 pixels.
  img.Image scaleImage(img.Image image, int columns, int rows) {
    if (columns <= 0 || rows <= 0) return img.Image(width: 0, height: 0);

    final targetWidth = columns * 8;
    final targetHeight = rows * 8;

    Tracer.record(_traceResizeId, Phase.begin, TraceCategory.paint);
    final scaled = img.copyResize(
      image,
      width: targetWidth,
      height: targetHeight,
      interpolation: img.Interpolation.linear,
    );
    Tracer.record(_traceResizeId, Phase.end, TraceCategory.paint);

    return scaled;
  }

  /// Quantizes an already-scaled image (sized exactly to columns*8 x rows*8) into a Buffer.
  Buffer quantizeScaledImage(
    img.Image scaled,
    int columns,
    int rows, {
    Buffer? targetBuffer,
    bool useMedian = false,
    bool useDin99d = false,
    int? backgroundColor,
    int? backgroundColorArgb,
  }) {
    if (columns <= 0 || rows <= 0 || scaled.width == 0 || scaled.height == 0) {
      return Buffer.blank(0, 0);
    }

    Tracer.record(_traceConvertId, Phase.begin, TraceCategory.paint);

    final quantizer = CellQuantizer(workFactor: workFactor);
    final pixelsRgb = Uint32List(64);
    final quantizeResult = QuantizeResult();

    final buffer = targetBuffer ?? Buffer.blank(columns, rows);

    final int paintRows = math.min(
      math.min(rows, buffer.height),
      scaled.height ~/ 8,
    );
    final int paintCols = math.min(
      math.min(columns, buffer.width),
      scaled.width ~/ 8,
    );

    final int imgWidth = scaled.width;
    final Uint8List bytes = scaled.getBytes(order: img.ChannelOrder.rgba);

    final int effectiveBg =
        backgroundColorArgb ?? backgroundColor ?? 0xFF000000;
    final int bgR = (effectiveBg >> 16) & 0xFF;
    final int bgG = (effectiveBg >> 8) & 0xFF;
    final int bgB = effectiveBg & 0xFF;

    for (int cellY = 0; cellY < paintRows; cellY++) {
      Tracer.record(_traceRowId, Phase.begin, TraceCategory.paint);
      for (int cellX = 0; cellX < paintCols; cellX++) {
        final transparentCount = _extractCellPixels(
          bytes,
          imgWidth,
          cellX,
          cellY,
          bgR,
          bgG,
          bgB,
          pixelsRgb,
        );

        if (transparentCount == 64) {
          buffer.setCell(
            cellX,
            cellY,
            ' ',
            effectiveBg,
            effectiveBg,
            Modifier.transparent,
          );
        } else {
          // Quantize cell extracting average colors and finding the best block character
          quantizer.quantize(
            pixelsRgb,
            candidates,
            quantizeResult,
            useMedian: useMedian,
            useDin99d: useDin99d,
          );

          buffer.setCell(
            cellX,
            cellY,
            quantizeResult.character,
            quantizeResult.fgColorArgb,
            quantizeResult.bgColorArgb,
            Modifier.none,
          );
        }
      }
      Tracer.record(_traceRowId, Phase.end, TraceCategory.paint);
    }

    Tracer.record(_traceConvertId, Phase.end, TraceCategory.paint);

    return buffer;
  }

  int _extractCellPixels(
    Uint8List bytes,
    int imgWidth,
    int cellX,
    int cellY,
    int bgR,
    int bgG,
    int bgB,
    Uint32List pixelsRgb,
  ) {
    int pIdx = 0;
    int transparentCount = 0;
    final int cellXOffset = (cellX * 8) * 4;

    for (int py = 0; py < 8; py++) {
      int rawIdx = ((cellY * 8 + py) * imgWidth) * 4 + cellXOffset;
      for (int px = 0; px < 8; px++) {
        var r = bytes[rawIdx];
        var g = bytes[rawIdx + 1];
        var b = bytes[rawIdx + 2];
        final a = bytes[rawIdx + 3];
        rawIdx += 4;

        if (a == 0) transparentCount++;
        if (a < 255) {
          final invA = 255 - a;
          r = ((r * a + bgR * invA) * 257) >> 16;
          g = ((g * a + bgG * invA) * 257) >> 16;
          b = ((b * a + bgB * invA) * 257) >> 16;
        }

        pixelsRgb[pIdx++] = (0xFF << 24) | (r << 16) | (g << 8) | b;
      }
    }
    return transparentCount;
  }

  /// Converts an image directly into a native [Buffer] of [columns] by [rows].
  /// If [targetBuffer] is provided, cell values are written into [targetBuffer].
  ///
  /// When [enableKittyPassthrough] (or [this.enableKittyPassthrough]) is `true`,
  /// registers the RGBA pixels in [KittyImageRegistry] under [kittyImageId] and
  /// fills the buffer with `U+10EEEE` Unicode placeholders.
  Buffer convertBuffer(
    img.Image image,
    int columns,
    int rows, {
    Buffer? targetBuffer,
    bool useMedian = false,
    bool useDin99d = false,
    int? backgroundColor,
    int? backgroundColorArgb,
    bool? enableKittyPassthrough,
    int? kittyImageId,
  }) {
    if (enableKittyPassthrough ?? this.enableKittyPassthrough) {
      return _convertKittyPlaceholderBuffer(
        image,
        columns,
        rows,
        targetBuffer: targetBuffer,
        kittyImageId: kittyImageId ?? _defaultKittyImageId(image),
      );
    }
    final scaled = scaleImage(image, columns, rows);
    return quantizeScaledImage(
      scaled,
      columns,
      rows,
      targetBuffer: targetBuffer,
      useMedian: useMedian,
      useDin99d: useDin99d,
      backgroundColor: backgroundColor,
      backgroundColorArgb: backgroundColorArgb,
    );
  }

  /// Builds either a [KittyImage] (when [enableKittyPassthrough] is `true`) or
  /// a mosaic [BufferWidget] (when `false`).
  Widget buildWidget(
    img.Image image,
    int columns,
    int rows, {
    bool useMedian = false,
    bool useDin99d = false,
    bool? enableKittyPassthrough,
    int? kittyImageId,
  }) {
    if (enableKittyPassthrough ?? this.enableKittyPassthrough) {
      final prepared = _prepareKittyImage(image, columns, rows);
      final rgba = prepared.getBytes(order: img.ChannelOrder.rgba);
      return KittyImage(
        imageId: kittyImageId ?? _defaultKittyImageId(image),
        pixelWidth: prepared.width,
        pixelHeight: prepared.height,
        rgbaPixels: rgba,
        columns: columns,
        rows: rows,
      );
    }
    return BufferWidget(
      buffer: convertBuffer(
        image,
        columns,
        rows,
        useMedian: useMedian,
        useDin99d: useDin99d,
        enableKittyPassthrough: false,
      ),
    );
  }

  img.Image _prepareKittyImage(img.Image image, int columns, int rows) {
    final maxW = math.max(1, columns) * 16;
    final maxH = math.max(1, rows) * 32;
    if (image.width <= maxW && image.height <= maxH) return image;
    return img.copyResize(
      image,
      width: math.min(image.width, maxW),
      height: math.min(image.height, maxH),
      interpolation: img.Interpolation.linear,
    );
  }

  static int _defaultKittyImageId(img.Image image) {
    var hash = 0x811C9DC5;
    hash = ((hash ^ image.width) * 0x01000193) & 0x7FFFFFFF;
    hash = ((hash ^ image.height) * 0x01000193) & 0x7FFFFFFF;
    final bytes = image.getBytes(order: img.ChannelOrder.rgba);
    final step = math.max(1, bytes.length ~/ 64);
    for (var i = 0; i < bytes.length; i += step) {
      hash = ((hash ^ bytes[i]) * 0x01000193) & 0x7FFFFFFF;
    }
    final id = hash & 0xFFFFFF;
    return id == 0 ? 1 : id;
  }

  Buffer _convertKittyPlaceholderBuffer(
    img.Image image,
    int columns,
    int rows, {
    Buffer? targetBuffer,
    required int kittyImageId,
  }) {
    if (columns <= 0 || rows <= 0 || image.width == 0 || image.height == 0) {
      return Buffer.blank(0, 0);
    }
    final buffer = targetBuffer ?? Buffer.blank(columns, rows);
    final cols = math.min(
      columns,
      math.min(buffer.width, kittyDiacritics.length),
    );
    final rws = math.min(rows, math.min(buffer.height, kittyDiacritics.length));
    final prepared = _prepareKittyImage(image, cols, rws);
    final validId = (kittyImageId & 0xFFFFFF) == 0
        ? 1
        : (kittyImageId & 0xFFFFFF);
    KittyImageRegistry.register(
      KittyImageData(
        imageId: validId,
        pixelWidth: prepared.width,
        pixelHeight: prepared.height,
        rgbaPixels: prepared.getBytes(order: img.ChannelOrder.rgba),
        gridCols: cols,
        gridRows: rws,
      ),
    );
    buffer.registerKittyRegistry(
      Rect(0, 0, cols, rws),
      KittyImageRegistry.global,
    );
    final fgArgb = 0xFF000000 | validId;
    for (var ry = 0; ry < rws; ry++) {
      for (var rx = 0; rx < cols; rx++) {
        buffer.setAttributes(
          rx,
          ry,
          char: kittyPlaceholderCell(ry, rx),
          fg: fgArgb,
          bg: 0,
          modifiers: Modifier.kittyPlaceholder,
          underlineColor: 0,
          uri: '',
          blend: false,
        );
      }
    }
    return buffer;
  }
}
