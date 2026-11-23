import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/widgets/display/kitty_image.dart';

import 'shader_backend.dart';
import 'staging_cache.dart';

/// Instance slice describing the packed glyph quads belonging to one scoped
/// `ShaderRegion`'s `uGlyphMask` texture in [GpuAtlasQuadBatch.regionMaskInstanceData].
final class GpuRegionMaskSlice {
  /// Stable region identifier matching `ShaderRegion.id`.
  final String regionId;

  /// Starting instance index inside [GpuAtlasQuadBatch.regionMaskInstanceData].
  final int startInstance;

  /// Number of packed glyph instances belonging to this region mask.
  final int instanceCount;

  /// Physical destination rectangle of the region output on the terminal pane.
  final ui.Rect outputRectPhysical;

  /// Creates an immutable region mask slice descriptor.
  const GpuRegionMaskSlice({
    required this.regionId,
    required this.startInstance,
    required this.instanceCount,
    required this.outputRectPhysical,
  });
}

/// A single coalesced Kitty graphics textured quad in physical viewport pixels.
final class GpuKittyQuad {
  /// Decoded Kitty GPU image to sample.
  final ui.Image image;

  /// Destination X origin in physical pixels.
  final double dstX;

  /// Destination Y origin in physical pixels.
  final double dstY;

  /// Destination width in physical pixels.
  final double dstWidth;

  /// Destination height in physical pixels.
  final double dstHeight;

  /// Normalized left texture coordinate in `[0, 1]`.
  final double u0;

  /// Normalized top texture coordinate in `[0, 1]`.
  final double v0;

  /// Normalized right texture coordinate in `[0, 1]`.
  final double u1;

  /// Normalized bottom texture coordinate in `[0, 1]`.
  final double v1;

  /// Creates an immutable Kitty textured quad descriptor.
  const GpuKittyQuad({
    required this.image,
    required this.dstX,
    required this.dstY,
    required this.dstWidth,
    required this.dstHeight,
    required this.u0,
    required this.v0,
    required this.u1,
    required this.v1,
  });
}

/// Platform-agnostic packed GPU sprite instance batch built from a staged
/// [StagingBufferSet].
///
/// Instances are packed in exact `TuiAtlasPainter` Z-order:
/// - `[0 .. italicStartInstanceIndex)`: optional default background fill,
///   background cells, foreground glyphs, and color emoji (`NEAREST`).
/// - `[italicStartInstanceIndex .. kittyInsertInstanceIndex)`: synthetic
///   skewed italic and bold-italic (`+0.6` logical px) sprites (`LINEAR`).
/// - [kittyQuads] draw between `kittyInsertInstanceIndex` and post-Kitty quads
///   (`LINEAR`).
/// - `[kittyInsertInstanceIndex .. instanceCount)`: decorations (underlines,
///   curly underlines, strikethrough, overline) and out-of-bounds dim scrims /
///   1 px borders (`NEAREST`).
///
/// Per-instance vertex layout (16 `float32` = 64 bytes, 16-byte aligned):
/// - `loc 1` (`vec4`): `dstRect` `(x, y, width, height)` in physical pixels.
/// - `loc 2` (`vec4`): `uvRect` `(u0, v0, u1, v1)` normalized in `[0, 1]`.
/// - `loc 3` (`vec4`): `color` premultiplied `(r, g, b, a)`.
/// - `loc 4` (`vec4`): `extra` `(shearSlopeX, shearOriginY, modeFlags, rotationRad)`.
final class GpuAtlasQuadBatch {
  /// Number of `float32` scalars packed per instance.
  static const int floatsPerInstance = 16;

  /// Byte stride per instance (`64` bytes).
  static const int bytesPerInstance = floatsPerInstance * 4;

  /// `modeFlags` value selecting modulated atlas texture sampling.
  static const double modeTextured = 0.0;

  /// `modeFlags` value selecting solid-color output (skips atlas sampling).
  static const double modeSolid = 1.0;

  /// Shared empty instance buffer used when dynamic transform or region-mask
  /// slices are inactive.
  static final Float32List emptyInstanceData = Float32List(0);

  /// Reusable backing buffer; active floats are `[0 .. instanceCount * 16)`.
  final Float32List instanceData;

  /// Number of active packed sprite instances in [instanceData].
  final int instanceCount;

  /// End index of background quads (`[0 .. bgEndInstanceIndex)`), allowing
  /// `underGlyphs` shader regions to composite between backgrounds and glyphs.
  final int bgEndInstanceIndex;

  /// Start index of the synthetic-italic (`LINEAR`) instance slice.
  final int italicStartInstanceIndex;

  /// Split index where [kittyQuads] are rendered before post-Kitty instances.
  final int kittyInsertInstanceIndex;

  /// Monotonic generation incremented whenever static packed instance data
  /// changes.
  ///
  /// Backends compare this token to skip `bufferSubData` / `DeviceBuffer`
  /// re-uploads on pure animation (`iTime`) or per-cell transform tween ticks.
  final int generation;

  /// Packed ARGB default terminal background color.
  final int defaultBackgroundArgb;

  /// Coalesced Kitty graphics quads drawn at [kittyInsertInstanceIndex].
  final List<GpuKittyQuad> kittyQuads;

  /// True when the frame contains Canvas-only elements (unbaked non-Kitty
  /// fallback glyphs, raw RGBA subpixel Kitty cells without a decoded GPU
  /// image, multi-cell ligature runs, or inline IME composing text) that
  /// require falling back to `TuiAtlasPainter`.
  final bool hasCanvasOnlyContent;

  /// Separate `zLayer`-sorted transformed-cell instance slice uploaded
  /// independently from the static grid so 120 Hz tweens upload only moving
  /// cells while static [instanceData] stays cached on the GPU.
  final Float32List transformedInstanceData;

  /// Number of active packed instances in [transformedInstanceData].
  final int transformedInstanceCount;

  /// Number of leading instances in [transformedInstanceData] with `zLayer < 0`
  /// drawn behind static foreground glyphs.
  final int transformedUnderGlyphCount;

  /// Monotonic generation incremented whenever [transformedInstanceData] changes.
  final int transformedGeneration;

  /// Separate packed glyph instance buffer feeding tight GPU-to-GPU
  /// `uGlyphMask` textures for active `ShaderRegion` passes.
  final Float32List regionMaskInstanceData;

  /// Number of active packed instances in [regionMaskInstanceData].
  final int regionMaskInstanceCount;

  /// Monotonic generation incremented whenever [regionMaskInstanceData] changes.
  final int regionMaskGeneration;

  /// Per-region ranges inside [regionMaskInstanceData].
  final List<GpuRegionMaskSlice> regionMaskSlices;

  /// Synchronous scoped `ShaderRegion` passes (capped at `<= 8`) executed
  /// inside `DirectTerminalShaderBackend.renderTerminalFrameSync`.
  final List<ShaderRegionPassInvocation> regionPasses;

  /// Optional pane identifier isolating per-pane GPU upload, mask, and static
  /// scene layer caches across split panes sharing one backend.
  final String paneKey;

  /// Creates a packed [GpuAtlasQuadBatch].
  GpuAtlasQuadBatch({
    required this.instanceData,
    required this.instanceCount,
    this.bgEndInstanceIndex = 0,
    required this.italicStartInstanceIndex,
    required this.kittyInsertInstanceIndex,
    required this.generation,
    required this.defaultBackgroundArgb,
    required this.kittyQuads,
    required this.hasCanvasOnlyContent,
    Float32List? transformedInstanceData,
    this.transformedInstanceCount = 0,
    this.transformedUnderGlyphCount = 0,
    this.transformedGeneration = 0,
    Float32List? regionMaskInstanceData,
    this.regionMaskInstanceCount = 0,
    this.regionMaskGeneration = 0,
    this.regionMaskSlices = const <GpuRegionMaskSlice>[],
    this.regionPasses = const <ShaderRegionPassInvocation>[],
    this.paneKey = '',
  }) : transformedInstanceData = transformedInstanceData ?? emptyInstanceData,
       regionMaskInstanceData = regionMaskInstanceData ?? emptyInstanceData;

  /// Returns a view sharing the static [instanceData] and [generation] while
  /// attaching updated dynamic transform and/or region-mask slices.
  GpuAtlasQuadBatch withDynamicSlices({
    Float32List? transformedInstanceData,
    int? transformedInstanceCount,
    int? transformedUnderGlyphCount,
    int? transformedGeneration,
    Float32List? regionMaskInstanceData,
    int? regionMaskInstanceCount,
    int? regionMaskGeneration,
    List<GpuRegionMaskSlice>? regionMaskSlices,
    List<ShaderRegionPassInvocation>? regionPasses,
    bool? hasCanvasOnlyContent,
    String? paneKey,
  }) => GpuAtlasQuadBatch(
    instanceData: instanceData,
    instanceCount: instanceCount,
    bgEndInstanceIndex: bgEndInstanceIndex,
    italicStartInstanceIndex: italicStartInstanceIndex,
    kittyInsertInstanceIndex: kittyInsertInstanceIndex,
    generation: generation,
    defaultBackgroundArgb: defaultBackgroundArgb,
    kittyQuads: kittyQuads,
    hasCanvasOnlyContent: hasCanvasOnlyContent ?? this.hasCanvasOnlyContent,
    transformedInstanceData:
        transformedInstanceData ?? this.transformedInstanceData,
    transformedInstanceCount:
        transformedInstanceCount ?? this.transformedInstanceCount,
    transformedUnderGlyphCount:
        transformedUnderGlyphCount ?? this.transformedUnderGlyphCount,
    transformedGeneration: transformedGeneration ?? this.transformedGeneration,
    regionMaskInstanceData:
        regionMaskInstanceData ?? this.regionMaskInstanceData,
    regionMaskInstanceCount:
        regionMaskInstanceCount ?? this.regionMaskInstanceCount,
    regionMaskGeneration: regionMaskGeneration ?? this.regionMaskGeneration,
    regionMaskSlices: regionMaskSlices ?? this.regionMaskSlices,
    regionPasses: regionPasses ?? this.regionPasses,
    paneKey: paneKey ?? this.paneKey,
  );
}

/// Reusable builder that packs a [StagingBufferSet] into a [GpuAtlasQuadBatch]
/// without per-frame `Float32List` allocations in steady state.
final class GpuAtlasBatchBuilder {
  static const double _italicTranslateXFactor = 0.14;
  static const double _italicSkewSlopeX = -0.18;
  static const double _boldItalicOffsetLogical = 0.6;
  static const double _kittyTileOverlapLogical = 0.25;
  static const int _defaultOutOfBoundsDimArgb = 0x80000000;
  static const int _lightBorderArgb = 0x33FFFFFF;
  static const int _darkBorderArgb = 0x33000000;

  Float32List _buffer = Float32List(0);
  int _capacityInstances = 0;
  int _instanceCount = 0;
  int _batchGeneration = 0;
  int _lastStagingGeneration = -1;
  int _lastConfigSignature = 0;
  int _lastInstanceCount = -1;
  GpuAtlasQuadBatch? _lastBatch;

  /// Packs [staged] into a [GpuAtlasQuadBatch] scaled to physical pixels using
  /// [devicePixelRatio].
  GpuAtlasQuadBatch build({
    required StagingBufferSet staged,
    required Buffer buffer,
    required ui.Size logicalSize,
    required double devicePixelRatio,
    required double cellWidth,
    required double cellHeight,
    required double atlasPhysWidth,
    required double atlasPhysHeight,
    required double fgScaleBlock,
    required double overhangFgPhysical,
    required double overhangFgLogical,
    required int defaultBackgroundArgb,
    required int stagingGeneration,
    required Map<KittyImageData, ui.Image> kittyImages,
    required Map<(KittyImageRegistry, int), ui.Image> kittyImagesById,
    int? activePtyCols,
    int? activePtyRows,
    int? outOfBoundsDimArgb,
    String composingText = '',
  }) {
    final configSignature = Object.hash(
      logicalSize,
      devicePixelRatio,
      cellWidth,
      cellHeight,
      atlasPhysWidth,
      atlasPhysHeight,
      fgScaleBlock,
      overhangFgPhysical,
      defaultBackgroundArgb,
      activePtyCols,
      activePtyRows,
      outOfBoundsDimArgb,
      composingText.isNotEmpty,
      kittyImages.length,
      kittyImagesById.length,
    );

    final cached = _lastBatch;
    if (cached != null &&
        stagingGeneration == _lastStagingGeneration &&
        configSignature == _lastConfigSignature &&
        staged.fallbackCount == 0 &&
        staged.ligatureCount == 0) {
      return cached;
    }

    _instanceCount = 0;
    final invAtlasW = atlasPhysWidth > 0.0 ? 1.0 / atlasPhysWidth : 0.0;
    final invAtlasH = atlasPhysHeight > 0.0 ? 1.0 / atlasPhysHeight : 0.0;
    final gridCols = buffer.width;
    final gridRows = buffer.height;

    final estimatedInstances =
        1 +
        staged.bgCount +
        staged.fgCount +
        staged.emojiCount +
        staged.italicCount * 2 +
        staged.decoCount +
        4;
    _ensureCapacity(estimatedInstances);

    if (gridCols > 0 && gridRows > 0 && (defaultBackgroundArgb >>> 24) != 0) {
      _appendSolidQuad(
        x: 0.0,
        y: 0.0,
        w: gridCols * cellWidth * devicePixelRatio,
        h: gridRows * cellHeight * devicePixelRatio,
        argb: defaultBackgroundArgb,
      );
    }

    _appendSpriteList(
      transforms: staged.bgTransforms,
      rects: staged.bgRects,
      colors: staged.bgColors,
      count: staged.bgCount,
      dpr: devicePixelRatio,
      invAtlasW: invAtlasW,
      invAtlasH: invAtlasH,
    );
    final bgEnd = _instanceCount;
    _appendSpriteList(
      transforms: staged.fgTransforms,
      rects: staged.fgRects,
      colors: staged.fgColors,
      count: staged.fgCount,
      dpr: devicePixelRatio,
      invAtlasW: invAtlasW,
      invAtlasH: invAtlasH,
    );
    _appendSpriteList(
      transforms: staged.emojiTransforms,
      rects: staged.emojiRects,
      colors: null,
      count: staged.emojiCount,
      dpr: devicePixelRatio,
      invAtlasW: invAtlasW,
      invAtlasH: invAtlasH,
    );

    final italicStart = _instanceCount;
    _appendItalicSprites(
      staged: staged,
      dpr: devicePixelRatio,
      cellWidth: cellWidth,
      atlasPhysWidth: atlasPhysWidth,
      atlasPhysHeight: atlasPhysHeight,
      invAtlasW: invAtlasW,
      invAtlasH: invAtlasH,
      fgScaleBlock: fgScaleBlock,
      overhangFgPhysical: overhangFgPhysical,
      overhangFgLogical: overhangFgLogical,
    );

    final kittyInsert = _instanceCount;
    final fallbackResult = _collectKittyQuads(
      staged: staged,
      buffer: buffer,
      dpr: devicePixelRatio,
      kittyImages: kittyImages,
      kittyImagesById: kittyImagesById,
    );

    _appendSpriteList(
      transforms: staged.decoTransforms,
      rects: staged.decoRects,
      colors: staged.decoColors,
      count: staged.decoCount,
      dpr: devicePixelRatio,
      invAtlasW: invAtlasW,
      invAtlasH: invAtlasH,
    );

    if (activePtyCols != null || activePtyRows != null) {
      _appendOutOfBoundsDimming(
        logicalSize: logicalSize,
        dpr: devicePixelRatio,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        activePtyCols: activePtyCols,
        activePtyRows: activePtyRows,
        outOfBoundsDimArgb: outOfBoundsDimArgb,
        defaultBackgroundArgb: defaultBackgroundArgb,
      );
    }

    final hasCanvasOnly =
        fallbackResult.hasCanvasOnlyFallback ||
        staged.ligatureCount > 0 ||
        composingText.isNotEmpty;

    if (stagingGeneration != _lastStagingGeneration ||
        configSignature != _lastConfigSignature ||
        _instanceCount != _lastInstanceCount ||
        staged.fallbackCount > 0) {
      _batchGeneration++;
      _lastStagingGeneration = stagingGeneration;
      _lastConfigSignature = configSignature;
      _lastInstanceCount = _instanceCount;
    }

    final batch = GpuAtlasQuadBatch(
      instanceData: _buffer,
      instanceCount: _instanceCount,
      bgEndInstanceIndex: bgEnd,
      italicStartInstanceIndex: italicStart,
      kittyInsertInstanceIndex: kittyInsert,
      generation: _batchGeneration,
      defaultBackgroundArgb: defaultBackgroundArgb,
      kittyQuads: fallbackResult.kittyQuads,
      hasCanvasOnlyContent: hasCanvasOnly,
    );
    _lastBatch = batch;
    return batch;
  }

  /// Invalidates the cached [GpuAtlasQuadBatch] so the next [build] repacks
  /// and increments [GpuAtlasQuadBatch.generation].
  void invalidate() {
    _lastBatch = null;
    _lastStagingGeneration = -1;
  }

  void _ensureCapacity(int requiredInstances) {
    if (requiredInstances <= _capacityInstances) return;
    var nextCap = _capacityInstances == 0 ? 256 : _capacityInstances;
    while (nextCap < requiredInstances) {
      nextCap <<= 1;
    }
    final next = Float32List(nextCap * GpuAtlasQuadBatch.floatsPerInstance);
    if (_instanceCount > 0) {
      next.setRange(
        0,
        _instanceCount * GpuAtlasQuadBatch.floatsPerInstance,
        _buffer,
      );
    }
    _buffer = next;
    _capacityInstances = nextCap;
  }

  void _appendSpriteList({
    required Float32List transforms,
    required Float32List rects,
    required Int32List? colors,
    required int count,
    required double dpr,
    required double invAtlasW,
    required double invAtlasH,
  }) {
    if (count <= 0) return;
    _ensureCapacity(_instanceCount + count);
    final out = _buffer;
    for (var i = 0; i < count; i++) {
      final base = i << 2;
      final scale = transforms[base];
      final tx = transforms[base + 2];
      final ty = transforms[base + 3];
      final l = rects[base];
      final t = rects[base + 1];
      final r = rects[base + 2];
      final b = rects[base + 3];
      final dstW = (r - l) * scale * dpr;
      final dstH = (b - t) * scale * dpr;

      final outBase = _instanceCount * GpuAtlasQuadBatch.floatsPerInstance;
      out[outBase] = tx * dpr;
      out[outBase + 1] = ty * dpr;
      out[outBase + 2] = dstW;
      out[outBase + 3] = dstH;
      out[outBase + 4] = l * invAtlasW;
      out[outBase + 5] = t * invAtlasH;
      out[outBase + 6] = r * invAtlasW;
      out[outBase + 7] = b * invAtlasH;
      if (colors == null) {
        out[outBase + 8] = 1.0;
        out[outBase + 9] = 1.0;
        out[outBase + 10] = 1.0;
        out[outBase + 11] = 1.0;
      } else {
        _writePremultipliedColor(out, outBase + 8, colors[i]);
      }
      out[outBase + 12] = 0.0;
      out[outBase + 13] = 0.0;
      out[outBase + 14] = GpuAtlasQuadBatch.modeTextured;
      out[outBase + 15] = 0.0;
      _instanceCount++;
    }
  }

  void _appendItalicSprites({
    required StagingBufferSet staged,
    required double dpr,
    required double cellWidth,
    required double atlasPhysWidth,
    required double atlasPhysHeight,
    required double invAtlasW,
    required double invAtlasH,
    required double fgScaleBlock,
    required double overhangFgPhysical,
    required double overhangFgLogical,
  }) {
    final count = staged.italicCount;
    if (count <= 0) return;
    final srcRects = staged.italicSrcRects;
    final positions = staged.italicPositions;
    final colors = staged.italicColors;
    final flags = staged.italicFlags;

    for (var i = 0; i < count; i++) {
      final rBase = i << 2;
      final l = srcRects[rBase];
      final t = srcRects[rBase + 1];
      final r = srcRects[rBase + 2];
      final b = srcRects[rBase + 3];
      final pBase = i << 1;
      final x = positions[pBase];
      final y = positions[pBase + 1];
      final isBold = (flags[i] & 1) != 0;

      final expand =
          overhangFgPhysical > 0.0 &&
          l >= overhangFgPhysical &&
          t >= overhangFgPhysical &&
          r + overhangFgPhysical <= atlasPhysWidth &&
          b + overhangFgPhysical <= atlasPhysHeight;
      final padPhys = expand ? overhangFgPhysical : 0.0;
      final srcL = l - padPhys;
      final srcT = t - padPhys;
      final srcR = r + padPhys;
      final srcB = b + padPhys;
      final padLogical = expand ? overhangFgLogical : 0.0;
      final dstW = (srcR - srcL) * fgScaleBlock * dpr;
      final dstH = (srcB - srcT) * fgScaleBlock * dpr;

      final originX = x + cellWidth * _italicTranslateXFactor;
      final originYPhys = y * dpr;
      final dstY = (y - padLogical) * dpr;
      final u0 = srcL * invAtlasW;
      final v0 = srcT * invAtlasH;
      final u1 = srcR * invAtlasW;
      final v1 = srcB * invAtlasH;
      final argb = colors[i];

      _appendItalicInstance(
        dstX: (originX - padLogical) * dpr,
        dstY: dstY,
        dstW: dstW,
        dstH: dstH,
        u0: u0,
        v0: v0,
        u1: u1,
        v1: v1,
        argb: argb,
        shearOriginYPhys: originYPhys,
      );
      if (isBold) {
        _appendItalicInstance(
          dstX: (originX + _boldItalicOffsetLogical - padLogical) * dpr,
          dstY: dstY,
          dstW: dstW,
          dstH: dstH,
          u0: u0,
          v0: v0,
          u1: u1,
          v1: v1,
          argb: argb,
          shearOriginYPhys: originYPhys,
        );
      }
    }
  }

  void _appendItalicInstance({
    required double dstX,
    required double dstY,
    required double dstW,
    required double dstH,
    required double u0,
    required double v0,
    required double u1,
    required double v1,
    required int argb,
    required double shearOriginYPhys,
  }) {
    _ensureCapacity(_instanceCount + 1);
    final out = _buffer;
    final outBase = _instanceCount * GpuAtlasQuadBatch.floatsPerInstance;
    out[outBase] = dstX;
    out[outBase + 1] = dstY;
    out[outBase + 2] = dstW;
    out[outBase + 3] = dstH;
    out[outBase + 4] = u0;
    out[outBase + 5] = v0;
    out[outBase + 6] = u1;
    out[outBase + 7] = v1;
    _writePremultipliedColor(out, outBase + 8, argb);
    out[outBase + 12] = _italicSkewSlopeX;
    out[outBase + 13] = shearOriginYPhys;
    out[outBase + 14] = GpuAtlasQuadBatch.modeTextured;
    out[outBase + 15] = 0.0;
    _instanceCount++;
  }

  ({List<GpuKittyQuad> kittyQuads, bool hasCanvasOnlyFallback})
  _collectKittyQuads({
    required StagingBufferSet staged,
    required Buffer buffer,
    required double dpr,
    required Map<KittyImageData, ui.Image> kittyImages,
    required Map<(KittyImageRegistry, int), ui.Image> kittyImagesById,
  }) {
    final count = staged.fallbackCount;
    if (count <= 0) {
      return (kittyQuads: const <GpuKittyQuad>[], hasCanvasOnlyFallback: false);
    }

    List<GpuKittyQuad>? quads;
    var hasCanvasOnly = false;
    var index = 0;
    while (index < count) {
      final char = staged.fallbackChars[index];
      final mods = staged.fallbackAttrs[index << 2];
      if (!_isKittyCell(char, mods)) {
        hasCanvasOnly = true;
        index++;
        continue;
      }

      final step = _resolveKittyRun(
        staged: staged,
        buffer: buffer,
        index: index,
        dpr: dpr,
        kittyImages: kittyImages,
        kittyImagesById: kittyImagesById,
      );
      if (step.quad != null) {
        (quads ??= <GpuKittyQuad>[]).add(step.quad!);
      }
      if (step.needsCanvasFallback) {
        hasCanvasOnly = true;
      }
      index = step.nextIndex;
    }

    return (
      kittyQuads: quads ?? const <GpuKittyQuad>[],
      hasCanvasOnlyFallback: hasCanvasOnly,
    );
  }

  ({int nextIndex, GpuKittyQuad? quad, bool needsCanvasFallback})
  _resolveKittyRun({
    required StagingBufferSet staged,
    required Buffer buffer,
    required int index,
    required double dpr,
    required Map<KittyImageData, ui.Image> kittyImages,
    required Map<(KittyImageRegistry, int), ui.Image> kittyImagesById,
  }) {
    final char = staged.fallbackChars[index];
    final coords = parseKittyPlaceholderCell(char);
    if (coords == null) {
      return (nextIndex: index + 1, quad: null, needsCanvasFallback: false);
    }

    final gBase = index << 1;
    final gridCol = staged.fallbackGridCoords[gBase];
    final gridRow = staged.fallbackGridCoords[gBase + 1];
    final aBase = index << 2;
    final fgArgb = staged.fallbackAttrs[aBase + 1];
    final x = staged.fallbackRects[aBase];
    final y = staged.fallbackRects[aBase + 1];
    final w = staged.fallbackRects[aBase + 2];
    final h = staged.fallbackRects[aBase + 3];

    final imageId = extractKittyCellImageId(char, fgArgb);
    final registry = buffer.lookupKittyRegistry(gridCol, gridRow);
    final data = registry.lookupImage(imageId);
    if (data == null ||
        data.gridCols <= 0 ||
        data.gridRows <= 0 ||
        coords.row >= data.gridRows ||
        coords.col >= data.gridCols) {
      return (nextIndex: index + 1, quad: null, needsCanvasFallback: false);
    }

    final gpuImage = kittyImages[data] ?? kittyImagesById[(registry, imageId)];
    if (gpuImage == null) {
      final needsSubpixelCanvas = data.format != KittyImageData.formatPng;
      return (
        nextIndex: index + 1,
        quad: null,
        needsCanvasFallback: needsSubpixelCanvas,
      );
    }

    final count = staged.fallbackCount;
    var endIdx = index + 1;
    var lastTileCol = coords.col;
    var lastGridCol = gridCol;
    while (endIdx < count &&
        _isNextKittyRunCell(
          staged: staged,
          buffer: buffer,
          index: endIdx,
          data: data,
          imageId: imageId,
          expectedGridRow: gridRow,
          expectedGridCol: lastGridCol + 1,
          expectedTileRow: coords.row,
          expectedTileCol: lastTileCol + 1,
        )) {
      lastTileCol++;
      lastGridCol++;
      endIdx++;
    }

    final runCols = lastTileCol - coords.col + 1;
    final u0 = coords.col / data.gridCols;
    final v0 = coords.row / data.gridRows;
    final u1 = (coords.col + runCols) / data.gridCols;
    final v1 = (coords.row + 1) / data.gridRows;

    return (
      nextIndex: endIdx,
      quad: GpuKittyQuad(
        image: gpuImage,
        dstX: x * dpr,
        dstY: y * dpr,
        dstWidth: (runCols * w + _kittyTileOverlapLogical) * dpr,
        dstHeight: (h + _kittyTileOverlapLogical) * dpr,
        u0: u0,
        v0: v0,
        u1: u1,
        v1: v1,
      ),
      needsCanvasFallback: false,
    );
  }

  static bool _isKittyCell(String char, int modifiers) =>
      Modifier.has(modifiers, Modifier.kittyPlaceholder) ||
      (char.length >= 2 && char.startsWith(kittyPlaceholderChar));

  static bool _isNextKittyRunCell({
    required StagingBufferSet staged,
    required Buffer buffer,
    required int index,
    required KittyImageData data,
    required int imageId,
    required int expectedGridRow,
    required int expectedGridCol,
    required int expectedTileRow,
    required int expectedTileCol,
  }) {
    final char = staged.fallbackChars[index];
    final aBase = index << 2;
    if (!_isKittyCell(char, staged.fallbackAttrs[aBase])) return false;
    final gBase = index << 1;
    final gridCol = staged.fallbackGridCoords[gBase];
    final gridRow = staged.fallbackGridCoords[gBase + 1];
    if (gridRow != expectedGridRow || gridCol != expectedGridCol) return false;
    final coords = parseKittyPlaceholderCell(char);
    if (coords == null ||
        coords.row != expectedTileRow ||
        coords.col != expectedTileCol) {
      return false;
    }
    final nextId = extractKittyCellImageId(
      char,
      staged.fallbackAttrs[aBase + 1],
    );
    if (nextId != imageId) return false;
    return identical(buffer.lookupKittyImage(gridCol, gridRow, nextId), data);
  }

  void _appendOutOfBoundsDimming({
    required ui.Size logicalSize,
    required double dpr,
    required double cellWidth,
    required double cellHeight,
    required int? activePtyCols,
    required int? activePtyRows,
    required int? outOfBoundsDimArgb,
    required int defaultBackgroundArgb,
  }) {
    final activeX = activePtyCols != null
        ? (math.max(0, activePtyCols) * cellWidth).clamp(0.0, logicalSize.width)
        : logicalSize.width;
    final activeY = activePtyRows != null
        ? (math.max(0, activePtyRows) * cellHeight).clamp(
            0.0,
            logicalSize.height,
          )
        : logicalSize.height;
    if (activeX >= logicalSize.width && activeY >= logicalSize.height) return;

    final dimArgb = outOfBoundsDimArgb ?? _defaultOutOfBoundsDimArgb;
    if (activeX < logicalSize.width && activeY > 0.0) {
      _appendSolidQuad(
        x: activeX * dpr,
        y: 0.0,
        w: (logicalSize.width - activeX) * dpr,
        h: activeY * dpr,
        argb: dimArgb,
      );
    }
    if (activeY < logicalSize.height) {
      _appendSolidQuad(
        x: 0.0,
        y: activeY * dpr,
        w: logicalSize.width * dpr,
        h: (logicalSize.height - activeY) * dpr,
        argb: dimArgb,
      );
    }

    final borderArgb = _isDarkArgb(defaultBackgroundArgb)
        ? _lightBorderArgb
        : _darkBorderArgb;
    if (activeX < logicalSize.width && activeY > 0.0) {
      final bx = math.min(logicalSize.width - 0.5, activeX + 0.5);
      final bottom = activeY < logicalSize.height
          ? math.min(logicalSize.height, activeY + 1.0)
          : logicalSize.height;
      _appendSolidQuad(
        x: (bx - 0.5) * dpr,
        y: 0.0,
        w: dpr,
        h: bottom * dpr,
        argb: borderArgb,
      );
    }
    if (activeY < logicalSize.height && activeX > 0.0) {
      final by = math.min(logicalSize.height - 0.5, activeY + 0.5);
      _appendSolidQuad(
        x: 0.0,
        y: (by - 0.5) * dpr,
        w: activeX * dpr,
        h: dpr,
        argb: borderArgb,
      );
    }
  }

  void _appendSolidQuad({
    required double x,
    required double y,
    required double w,
    required double h,
    required int argb,
  }) {
    if (w <= 0.0 || h <= 0.0) return;
    _ensureCapacity(_instanceCount + 1);
    final out = _buffer;
    final outBase = _instanceCount * GpuAtlasQuadBatch.floatsPerInstance;
    out[outBase] = x;
    out[outBase + 1] = y;
    out[outBase + 2] = w;
    out[outBase + 3] = h;
    out[outBase + 4] = 0.0;
    out[outBase + 5] = 0.0;
    out[outBase + 6] = 0.0;
    out[outBase + 7] = 0.0;
    _writePremultipliedColor(out, outBase + 8, argb);
    out[outBase + 12] = 0.0;
    out[outBase + 13] = 0.0;
    out[outBase + 14] = GpuAtlasQuadBatch.modeSolid;
    out[outBase + 15] = 0.0;
    _instanceCount++;
  }

  @pragma('vm:prefer-inline')
  static void _writePremultipliedColor(Float32List out, int offset, int argb) {
    final a = ((argb >>> 24) & 0xFF) / 255.0;
    out[offset] = (((argb >>> 16) & 0xFF) / 255.0) * a;
    out[offset + 1] = (((argb >>> 8) & 0xFF) / 255.0) * a;
    out[offset + 2] = ((argb & 0xFF) / 255.0) * a;
    out[offset + 3] = a;
  }

  static bool _isDarkArgb(int argb) {
    final r = (argb >>> 16) & 0xFF;
    final g = (argb >>> 8) & 0xFF;
    final b = argb & 0xFF;
    return (0.299 * r + 0.587 * g + 0.114 * b) < 128.0;
  }
}
