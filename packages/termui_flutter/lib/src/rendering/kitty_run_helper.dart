import 'package:termui/termui.dart';

import 'staging_cache.dart';

/// Sub-pixel overlap added to Kitty tile quads so adjacent tiles never show
/// hairline seams under fractional scaling.
const double kittyTileOverlapLogical = 0.25;

/// Returns whether a cell at [char] / [modifiers] is a Kitty Graphics
/// `U+10EEEE` placeholder cell.
bool isKittyPlaceholderCell(String char, int modifiers) =>
    Modifier.has(modifiers, Modifier.kittyPlaceholder) ||
    (char.length >= 2 && char.startsWith(kittyPlaceholderChar));

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
  return identical(registry.lookupImage(imageId), data);
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
}) {
  if (expectedTileCol >= data.gridCols) return false;
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
      )) {
    lastTileCol++;
    lastGridCol++;
    endIdx++;
  }
  return endIdx;
}
