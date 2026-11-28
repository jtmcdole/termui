import 'dart:math' as math;

import 'package:termui/termui.dart';

import 'staging_cache.dart';

/// Sub-pixel overlap added to Kitty tile quads so adjacent tiles never show
/// hairline seams under fractional scaling.
const double kittyTileOverlapLogical = 0.25;

/// Normalized `[0.0, 1.0]` source texture coordinates for a Kitty image quad.
typedef KittySourceUv = ({double u0, double v0, double u1, double v1});

/// A single clipped, non-occluded quad produced from a direct layered or
/// relative [KittyPlacement].
final class ResolvedKittyDirectPlacement {
  /// Owning [KittyImageRegistry] for GPU image cache lookup.
  final KittyImageRegistry registry;

  /// Stable active [KittyImageData] (animation frame or root image).
  final KittyImageData imageData;

  /// Originating [KittyPlacement] metadata.
  final KittyPlacement placement;

  /// Clipped logical X coordinate in buffer space.
  final double dstX;

  /// Clipped logical Y coordinate in buffer space.
  final double dstY;

  /// Clipped logical width in buffer space.
  final double dstWidth;

  /// Clipped logical height in buffer space.
  final double dstHeight;

  /// Normalized left texture coordinate in `[0.0, 1.0]`.
  final double u0;

  /// Normalized top texture coordinate in `[0.0, 1.0]`.
  final double v0;

  /// Normalized right texture coordinate in `[0.0, 1.0]`.
  final double u1;

  /// Normalized bottom texture coordinate in `[0.0, 1.0]`.
  final double v1;

  /// Creates a [ResolvedKittyDirectPlacement].
  const ResolvedKittyDirectPlacement({
    required this.registry,
    required this.imageData,
    required this.placement,
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

/// Layered direct Kitty placements partitioned into Kitty's three Z-order
/// passes and sorted by `(zIndex, imageId, placementId)`.
typedef LayeredDirectKittyPlacements = ({
  List<ResolvedKittyDirectPlacement> underBgPlacements,
  List<ResolvedKittyDirectPlacement> bgPlacements,
  List<ResolvedKittyDirectPlacement> fgPlacements,
});

/// Returns whether a cell at [char] / [modifiers] is a Kitty Graphics
/// `U+10EEEE` placeholder cell.
bool isKittyPlaceholderCell(String char, int modifiers) =>
    Modifier.has(modifiers, Modifier.kittyPlaceholder) ||
    (char.length >= 2 && char.startsWith(kittyPlaceholderChar));

/// Extracts the 24-bit Kitty `placementId` encoded in a placeholder cell's
/// `underlineColor` (`0` when unset).
int extractKittyCellPlacementId(int underlineColor) {
  if (underlineColor == 0) return 0;
  if (underlineColor.isAnsiIndexed) return underlineColor.ansiIndex;
  return underlineColor & 0xFF_FFFF;
}

/// Computes normalized `[0.0, 1.0]` source texture UVs for an image of size
/// `[imageWidth] x [imageHeight]`, applying optional [placement] source crop
/// (`srcX`, `srcY`, `srcWidth`, `srcHeight`) cleanly clamped to image bounds
/// and interpolating an optional normalized sub-rect (`subU0..subV1`).
KittySourceUv resolveKittySourceUv({
  required int imageWidth,
  required int imageHeight,
  KittyPlacement? placement,
  double subU0 = 0.0,
  double subV0 = 0.0,
  double subU1 = 1.0,
  double subV1 = 1.0,
}) {
  final sU0 = subU0.clamp(0.0, 1.0);
  final sV0 = subV0.clamp(0.0, 1.0);
  final sU1 = subU1.clamp(sU0, 1.0);
  final sV1 = subV1.clamp(sV0, 1.0);
  if (imageWidth <= 0 || imageHeight <= 0) {
    return (u0: sU0, v0: sV0, u1: sU1, v1: sV1);
  }
  final cropX = (placement?.srcX ?? 0).clamp(0, imageWidth);
  final cropY = (placement?.srcY ?? 0).clamp(0, imageHeight);
  final remW = imageWidth - cropX;
  final remH = imageHeight - cropY;
  final rawW = placement?.srcWidth ?? 0;
  final rawH = placement?.srcHeight ?? 0;
  final cropW = rawW > 0 ? rawW.clamp(0, remW) : remW;
  final cropH = rawH > 0 ? rawH.clamp(0, remH) : remH;

  final baseU0 = cropX / imageWidth;
  final baseV0 = cropY / imageHeight;
  final spanU = cropW / imageWidth;
  final spanV = cropH / imageHeight;
  return (
    u0: baseU0 + spanU * sU0,
    v0: baseV0 + spanV * sV0,
    u1: baseU0 + spanU * sU1,
    v1: baseV0 + spanV * sV1,
  );
}

/// Resolves logical sub-cell `(dx, dy)` pixel offsets from [placement]'s
/// physical `X`/`Y` fields, dividing by [devicePixelRatio] and clamping cleanly
/// within `[0.0, cellWidth]` x `[0.0, cellHeight]`.
({double dx, double dy}) resolveKittyCellOffset({
  required KittyPlacement? placement,
  required double cellWidth,
  required double cellHeight,
  double devicePixelRatio = 1.0,
}) {
  if (placement == null) return (dx: 0.0, dy: 0.0);
  final scale = devicePixelRatio > 0.0 ? devicePixelRatio : 1.0;
  final maxDx = math.max(0.0, cellWidth);
  final maxDy = math.max(0.0, cellHeight);
  return (
    dx: (placement.cellOffsetX / scale).clamp(0.0, maxDx),
    dy: (placement.cellOffsetY / scale).clamp(0.0, maxDy),
  );
}

/// Computes a combined revision hash across [KittyImageRegistry.global] and all
/// scoped registries registered on [buffer].
int computeScopedKittyRevisionHash(Buffer buffer) {
  var hash = KittyImageRegistry.global.revision;
  for (final entry in buffer.scopedKittyRegistries) {
    hash = Object.hash(
      hash,
      identityHashCode(entry.registry),
      entry.registry.revision,
    );
  }
  return hash;
}

const LayeredDirectKittyPlacements _emptyLayeredDirectPlacements = (
  underBgPlacements: <ResolvedKittyDirectPlacement>[],
  bgPlacements: <ResolvedKittyDirectPlacement>[],
  fgPlacements: <ResolvedKittyDirectPlacement>[],
);

/// Collects direct layered (`z != 0`) and relative (`P > 0`) Kitty placements
/// from [buffer]'s scoped registries (plus [KittyImageRegistry.global] when
/// active), resolving relative anchors with cycle safety, applying
/// `activeAltScreen` and `viewportScrollOffset`, clipping to pane `bounds`,
/// omitting cells occluded by higher-z `Compositor` registries, and splitting
/// into three `(zIndex, imageId, placementId)`-ordered lists.
LayeredDirectKittyPlacements collectLayeredDirectKittyPlacements(
  Buffer buffer, {
  required double cellWidth,
  required double cellHeight,
  double devicePixelRatio = 1.0,
}) {
  if (buffer.width <= 0 ||
      buffer.height <= 0 ||
      cellWidth <= 0.0 ||
      cellHeight <= 0.0) {
    return _emptyLayeredDirectPlacements;
  }
  final sources = _collectPlacementSources(buffer);
  if (sources.isEmpty) return _emptyLayeredDirectPlacements;

  final underBg = <ResolvedKittyDirectPlacement>[];
  final bg = <ResolvedKittyDirectPlacement>[];
  final fg = <ResolvedKittyDirectPlacement>[];

  for (final source in sources) {
    _appendSourcePlacements(
      buffer: buffer,
      bounds: source.bounds,
      registry: source.registry,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      devicePixelRatio: devicePixelRatio,
      underBg: underBg,
      bg: bg,
      fg: fg,
    );
  }

  underBg.sort(_compareResolvedPlacements);
  bg.sort(_compareResolvedPlacements);
  fg.sort(_compareResolvedPlacements);
  return (underBgPlacements: underBg, bgPlacements: bg, fgPlacements: fg);
}

List<({Rect bounds, KittyImageRegistry registry})> _collectPlacementSources(
  Buffer buffer,
) {
  final scoped = buffer.scopedKittyRegistries;
  final sources = <({Rect bounds, KittyImageRegistry registry})>[];
  var sawGlobal = false;
  for (final entry in scoped) {
    if (identical(entry.registry, KittyImageRegistry.global)) {
      sawGlobal = true;
    }
    if (entry.registry.hasPlacements) {
      sources.add(entry);
    }
  }
  if (!sawGlobal && KittyImageRegistry.global.hasPlacements) {
    sources.add((
      bounds: Rect(0, 0, buffer.width, buffer.height),
      registry: KittyImageRegistry.global,
    ));
  }
  return sources;
}

void _appendSourcePlacements({
  required Buffer buffer,
  required Rect bounds,
  required KittyImageRegistry registry,
  required double cellWidth,
  required double cellHeight,
  required double devicePixelRatio,
  required List<ResolvedKittyDirectPlacement> underBg,
  required List<ResolvedKittyDirectPlacement> bg,
  required List<ResolvedKittyDirectPlacement> fg,
}) {
  final activeAlt = registry.activeAltScreen;
  for (final placement in registry.allPlacements) {
    if (!_isRenderableLayeredDirectPlacement(placement, activeAlt)) continue;
    final data = registry.activeImageData(placement.imageId);
    if (data == null || data.pixelWidth <= 0 || data.pixelHeight <= 0) continue;
    final anchor = _resolvePlacementAnchor(registry, placement);
    if (anchor == null) continue;

    final scrollShift = placement.isAltScreen
        ? 0
        : registry.viewportScrollOffset;
    final target = _selectLayerBucket(placement.zIndex, underBg, bg, fg);
    _emitClippedVisiblePlacementQuads(
      buffer: buffer,
      bounds: bounds,
      registry: registry,
      imageData: data,
      placement: placement,
      bufCol: bounds.x + anchor.col,
      bufRow: bounds.y + anchor.row + scrollShift,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      devicePixelRatio: devicePixelRatio,
      out: target,
    );
  }
}

bool _isRenderableLayeredDirectPlacement(
  KittyPlacement placement,
  bool activeAltScreen,
) =>
    !placement.isVirtual &&
    (placement.zIndex != 0 || placement.isRelative) &&
    placement.isAltScreen == activeAltScreen &&
    placement.cols > 0 &&
    placement.rows > 0;

List<ResolvedKittyDirectPlacement> _selectLayerBucket(
  int zIndex,
  List<ResolvedKittyDirectPlacement> underBg,
  List<ResolvedKittyDirectPlacement> bg,
  List<ResolvedKittyDirectPlacement> fg,
) {
  if (zIndex < KittyPlacement.underBackgroundZThreshold) return underBg;
  if (zIndex < 0) return bg;
  return fg;
}

({int col, int row})? _resolvePlacementAnchor(
  KittyImageRegistry registry,
  KittyPlacement placement,
) {
  if (!placement.isRelative) {
    return (col: placement.gridCol, row: placement.gridRow);
  }
  var totalCol = 0;
  var totalRow = 0;
  var current = placement;
  final visited = <(int, int)>{
    (placement.imageId & 0xFFFFFFFF, placement.placementId & 0xFFFFFFFF),
  };
  while (current.isRelative) {
    totalCol += current.relCols;
    totalRow += current.relRows;
    final parentKey = (
      current.parentImageId & 0xFFFFFFFF,
      current.parentPlacementId & 0xFFFFFFFF,
    );
    if (!visited.add(parentKey)) return null;
    final parent = registry.lookupPlacement(parentKey.$1, parentKey.$2);
    if (parent == null || parent.isAltScreen != placement.isAltScreen) {
      return null;
    }
    current = parent;
  }
  return (col: current.gridCol + totalCol, row: current.gridRow + totalRow);
}

void _emitClippedVisiblePlacementQuads({
  required Buffer buffer,
  required Rect bounds,
  required KittyImageRegistry registry,
  required KittyImageData imageData,
  required KittyPlacement placement,
  required int bufCol,
  required int bufRow,
  required double cellWidth,
  required double cellHeight,
  required double devicePixelRatio,
  required List<ResolvedKittyDirectPlacement> out,
}) {
  final offset = resolveKittyCellOffset(
    placement: placement,
    cellWidth: cellWidth,
    cellHeight: cellHeight,
    devicePixelRatio: devicePixelRatio,
  );
  final fullLeft = bufCol * cellWidth + offset.dx;
  final fullTop = bufRow * cellHeight + offset.dy;
  final fullW = placement.cols * cellWidth;
  final fullH = placement.rows * cellHeight;

  final clipLeft = math.max(fullLeft, bounds.x * cellWidth);
  final clipTop = math.max(fullTop, bounds.y * cellHeight);
  final clipRight = math.min(
    fullLeft + fullW,
    math.min(buffer.width, bounds.x + bounds.width) * cellWidth,
  );
  final clipBottom = math.min(
    fullTop + fullH,
    math.min(buffer.height, bounds.y + bounds.height) * cellHeight,
  );
  if (clipRight <= clipLeft || clipBottom <= clipTop) return;

  const eps = 1e-6;
  final visColStart = ((clipLeft / cellWidth) + eps).floor().clamp(
    0,
    buffer.width,
  );
  final visColEnd = ((clipRight / cellWidth) - eps).ceil().clamp(
    0,
    buffer.width,
  );
  final visRowStart = ((clipTop / cellHeight) + eps).floor().clamp(
    0,
    buffer.height,
  );
  final visRowEnd = ((clipBottom / cellHeight) - eps).ceil().clamp(
    0,
    buffer.height,
  );
  if (visColStart >= visColEnd || visRowStart >= visRowEnd) return;

  if (_isEntireRectOwnedByRegistry(
    buffer,
    registry,
    visColStart,
    visColEnd,
    visRowStart,
    visRowEnd,
  )) {
    out.add(
      _buildResolvedDirectQuad(
        registry: registry,
        imageData: imageData,
        placement: placement,
        fullLeft: fullLeft,
        fullTop: fullTop,
        fullW: fullW,
        fullH: fullH,
        dstLeft: clipLeft,
        dstTop: clipTop,
        dstRight: clipRight,
        dstBottom: clipBottom,
      ),
    );
    return;
  }

  _emitUnoccludedRowRuns(
    buffer: buffer,
    registry: registry,
    imageData: imageData,
    placement: placement,
    visColStart: visColStart,
    visColEnd: visColEnd,
    visRowStart: visRowStart,
    visRowEnd: visRowEnd,
    fullLeft: fullLeft,
    fullTop: fullTop,
    fullW: fullW,
    fullH: fullH,
    clipLeft: clipLeft,
    clipTop: clipTop,
    clipRight: clipRight,
    clipBottom: clipBottom,
    cellWidth: cellWidth,
    cellHeight: cellHeight,
    out: out,
  );
}

bool _isEntireRectOwnedByRegistry(
  Buffer buffer,
  KittyImageRegistry registry,
  int colStart,
  int colEnd,
  int rowStart,
  int rowEnd,
) {
  for (var r = rowStart; r < rowEnd; r++) {
    for (var c = colStart; c < colEnd; c++) {
      if (!identical(buffer.lookupKittyRegistry(c, r), registry)) {
        return false;
      }
    }
  }
  return true;
}

void _emitUnoccludedRowRuns({
  required Buffer buffer,
  required KittyImageRegistry registry,
  required KittyImageData imageData,
  required KittyPlacement placement,
  required int visColStart,
  required int visColEnd,
  required int visRowStart,
  required int visRowEnd,
  required double fullLeft,
  required double fullTop,
  required double fullW,
  required double fullH,
  required double clipLeft,
  required double clipTop,
  required double clipRight,
  required double clipBottom,
  required double cellWidth,
  required double cellHeight,
  required List<ResolvedKittyDirectPlacement> out,
}) {
  for (var r = visRowStart; r < visRowEnd; r++) {
    final rowTop = math.max(clipTop, r * cellHeight);
    final rowBottom = math.min(clipBottom, (r + 1) * cellHeight);
    if (rowBottom <= rowTop) continue;
    var c = visColStart;
    while (c < visColEnd) {
      if (!identical(buffer.lookupKittyRegistry(c, r), registry)) {
        c++;
        continue;
      }
      final runStart = c;
      while (c < visColEnd &&
          identical(buffer.lookupKittyRegistry(c, r), registry)) {
        c++;
      }
      final runLeft = math.max(clipLeft, runStart * cellWidth);
      final runRight = math.min(clipRight, c * cellWidth);
      if (runRight > runLeft) {
        out.add(
          _buildResolvedDirectQuad(
            registry: registry,
            imageData: imageData,
            placement: placement,
            fullLeft: fullLeft,
            fullTop: fullTop,
            fullW: fullW,
            fullH: fullH,
            dstLeft: runLeft,
            dstTop: rowTop,
            dstRight: runRight,
            dstBottom: rowBottom,
          ),
        );
      }
    }
  }
}

ResolvedKittyDirectPlacement _buildResolvedDirectQuad({
  required KittyImageRegistry registry,
  required KittyImageData imageData,
  required KittyPlacement placement,
  required double fullLeft,
  required double fullTop,
  required double fullW,
  required double fullH,
  required double dstLeft,
  required double dstTop,
  required double dstRight,
  required double dstBottom,
}) {
  final uv = resolveKittySourceUv(
    imageWidth: imageData.pixelWidth,
    imageHeight: imageData.pixelHeight,
    placement: placement,
    subU0: (dstLeft - fullLeft) / fullW,
    subV0: (dstTop - fullTop) / fullH,
    subU1: (dstRight - fullLeft) / fullW,
    subV1: (dstBottom - fullTop) / fullH,
  );
  return ResolvedKittyDirectPlacement(
    registry: registry,
    imageData: imageData,
    placement: placement,
    dstX: dstLeft,
    dstY: dstTop,
    dstWidth: dstRight - dstLeft,
    dstHeight: dstBottom - dstTop,
    u0: uv.u0,
    v0: uv.v0,
    u1: uv.u1,
    v1: uv.v1,
  );
}

int _compareResolvedPlacements(
  ResolvedKittyDirectPlacement a,
  ResolvedKittyDirectPlacement b,
) {
  final zCmp = a.placement.zIndex.compareTo(b.placement.zIndex);
  if (zCmp != 0) return zCmp;
  final idCmp = a.placement.imageId.compareTo(b.placement.imageId);
  if (idCmp != 0) return idCmp;
  return a.placement.placementId.compareTo(b.placement.placementId);
}

bool _matchesRunRegistry(
  Buffer buffer,
  KittyImageRegistry startRegistry,
  int gridCol,
  int gridRow,
  int imageId,
  KittyImageData data,
) {
  final registry = buffer.lookupKittyRegistry(gridCol, gridRow);
  if (identical(registry, startRegistry)) return true;
  return identical(registry.activeImageData(imageId), data);
}

bool _matchesInheritedImageId(
  Buffer buffer,
  KittyImageRegistry startRegistry,
  int gridCol,
  int gridRow,
  String char,
  int fgArgb,
  int imageId,
  KittyImageData data,
) =>
    extractKittyCellImageId(char, fgArgb) == (imageId & 0xFFFFFF) &&
    _matchesRunRegistry(buffer, startRegistry, gridCol, gridRow, imageId, data);

/// Returns whether staged fallback cell [index] continues a contiguous
/// horizontal Kitty placeholder run for [data] / [imageId].
///
/// Supports explicit row/col diacritic cells, 1-diacritic row-only shorthand,
/// and bare `U+10EEEE` continuation cells (which inherit row and imageId MSB
/// from the run start while matching the low 24-bit foreground color and
/// `underlineColor` placement ID).
bool isNextKittyRunCell({
  required StagingBufferSet staged,
  required Buffer buffer,
  required KittyImageRegistry startRegistry,
  required int index,
  required KittyImageData data,
  required int imageId,
  required int expectedGridRow,
  required int expectedGridCol,
  required int expectedTileRow,
  required int expectedTileCol,
  required int expectedUnderlineColor,
  int? maxTileCols,
}) {
  if (expectedTileCol >= (maxTileCols ?? data.gridCols)) return false;
  final char = staged.fallbackChars[index];
  final aBase = index << 2;
  if (!isKittyPlaceholderCell(char, staged.fallbackAttrs[aBase])) return false;
  final gBase = index << 1;
  final gridCol = staged.fallbackGridCoords[gBase];
  final gridRow = staged.fallbackGridCoords[gBase + 1];
  if (gridRow != expectedGridRow || gridCol != expectedGridCol) return false;
  if (buffer.getUnderlineColor(gridCol, gridRow) != expectedUnderlineColor) {
    return false;
  }

  final fgArgb = staged.fallbackAttrs[aBase + 1];
  if (char == kittyPlaceholderChar) {
    return _matchesInheritedImageId(
      buffer,
      startRegistry,
      gridCol,
      gridRow,
      char,
      fgArgb,
      imageId,
      data,
    );
  }

  final coords = parseKittyPlaceholderCell(char);
  if (coords == null || coords.row != expectedTileRow) return false;
  if (char.length == 3) {
    return _matchesInheritedImageId(
      buffer,
      startRegistry,
      gridCol,
      gridRow,
      char,
      fgArgb,
      imageId,
      data,
    );
  }
  if (coords.col != expectedTileCol) return false;
  final nextId = extractKittyCellImageId(char, fgArgb);
  if (nextId != imageId) return false;
  return _matchesRunRegistry(
    buffer,
    startRegistry,
    gridCol,
    gridRow,
    nextId,
    data,
  );
}

/// Scans contiguous horizontal Kitty placeholder cells starting after
/// [startIndex] and returns the exclusive end index into [staged].
int measureKittyRunEnd({
  required StagingBufferSet staged,
  required Buffer buffer,
  required int startIndex,
  required KittyImageData data,
  required int imageId,
  required int gridRow,
  required int startGridCol,
  required int tileRow,
  required int startTileCol,
  int? maxTileCols,
}) {
  final count = staged.fallbackCount;
  final startRegistry = buffer.lookupKittyRegistry(startGridCol, gridRow);
  final startUnderlineColor = buffer.getUnderlineColor(startGridCol, gridRow);
  var endIdx = startIndex + 1;
  var lastTileCol = startTileCol;
  var lastGridCol = startGridCol;
  while (endIdx < count &&
      isNextKittyRunCell(
        staged: staged,
        buffer: buffer,
        startRegistry: startRegistry,
        index: endIdx,
        data: data,
        imageId: imageId,
        expectedGridRow: gridRow,
        expectedGridCol: lastGridCol + 1,
        expectedTileRow: tileRow,
        expectedTileCol: lastTileCol + 1,
        expectedUnderlineColor: startUnderlineColor,
        maxTileCols: maxTileCols,
      )) {
    lastTileCol++;
    lastGridCol++;
    endIdx++;
  }
  return endIdx;
}
