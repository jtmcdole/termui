import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/cell_transform.dart';
import 'package:termui/ui/glyph_cell_list.dart';
import 'package:termui/ui/shader_region.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/terminal_palette.dart';
import 'package:termui/ui/widgets/display/kitty_image.dart';

import 'atlas.dart';
import 'atlas_quad_table.dart';
import 'gpu_atlas_batch.dart';
import 'painter.dart';

/// Instantaneous evaluated visual pose for a single transformed terminal cell.
final class EvaluatedCellTransform {
  /// Identity pose with no displacement, scaling, rotation, or fade.
  static const EvaluatedCellTransform identity = EvaluatedCellTransform();

  /// Horizontal cell displacement in fractional cell widths.
  final double dx;

  /// Vertical cell displacement in fractional cell heights.
  final double dy;

  /// Horizontal scale factor in `[0.0, 4.0]`.
  final double scaleX;

  /// Vertical scale factor in `[0.0, 4.0]`.
  final double scaleY;

  /// Clockwise rotation in radians around the cell center.
  final double rotationRad;

  /// Opacity multiplier in `[0.0, 1.0]`.
  final double alpha;

  /// Ascending stacking layer (`0` = base grid, `> 0` floats above static UI).
  final int zLayer;

  /// Creates an evaluated per-cell visual pose.
  const EvaluatedCellTransform({
    this.dx = 0.0,
    this.dy = 0.0,
    this.scaleX = 1.0,
    this.scaleY = 1.0,
    this.rotationRad = 0.0,
    this.alpha = 1.0,
    this.zLayer = 0,
  });

  /// Whether this pose produces a visible quad.
  bool get isVisible => alpha > 0.0 && scaleX > 0.0 && scaleY > 0.0;

  /// Uniform scale approximation used by the Canvas `drawRawAtlas` fallback.
  double get uniformScale => (scaleX + scaleY) * 0.5;

  /// Linearly interpolates between [a] and [b] at eased progress [t].
  static EvaluatedCellTransform lerp(
    EvaluatedCellTransform a,
    EvaluatedCellTransform b,
    double t, {
    required int zLayer,
  }) => EvaluatedCellTransform(
    dx: a.dx + (b.dx - a.dx) * t,
    dy: a.dy + (b.dy - a.dy) * t,
    scaleX: a.scaleX + (b.scaleX - a.scaleX) * t,
    scaleY: a.scaleY + (b.scaleY - a.scaleY) * t,
    rotationRad: a.rotationRad + (b.rotationRad - a.rotationRad) * t,
    alpha: (a.alpha + (b.alpha - a.alpha) * t).clamp(0.0, 1.0),
    zLayer: zLayer,
  );
}

/// Active transformed cell coordinate paired with its evaluated visual pose.
typedef EvaluatedCellEntry = ({
  int cellIndex,
  int col,
  int row,
  EvaluatedCellTransform pose,
});

/// Host-side 120 Hz evaluator for `CellTransform` and finite `CellTween` poses.
///
/// Keyed by `(cellIndex, animationId)` so unrelated TUI rebuilds never restart
/// in-flight motion, supporting `fromCurrent` continuity for 20-30 Hz CLI
/// keyframe updates and reporting [hasActiveTweens] so host tickers stop
/// automatically once all tweens finish.
final class CellTransformAnimator {
  final Map<int, _TrackedCellTween> _tracked = <int, _TrackedCellTween>{};
  final Map<int, EvaluatedCellTransform> _activePoses =
      <int, EvaluatedCellTransform>{};
  final Map<int, EvaluatedCellTransform> _lastEvaluated =
      <int, EvaluatedCellTransform>{};
  final List<EvaluatedCellEntry> _sortedEntries = <EvaluatedCellEntry>[];

  bool _hasActiveTweens = false;

  /// Whether at least one finite [CellTween] is currently still in progress.
  bool get hasActiveTweens => _hasActiveTweens;

  /// Active transformed poses keyed by flat `row * cols + col` cell index.
  Map<int, EvaluatedCellTransform> get activePoses => _activePoses;

  /// Active transformed entries sorted in ascending `(zLayer, cellIndex)` order.
  List<EvaluatedCellEntry> get sortedEntries => _sortedEntries;

  /// Number of currently active (non-cleared) transformed cells.
  int get activeCount => _sortedEntries.length;

  /// Synchronizes active transforms from [table] and evaluates all poses at
  /// monotonic timestamp [nowSec] (in seconds).
  void evaluate({
    required CellTransformTable? table,
    required int cols,
    required int rows,
    required double nowSec,
  }) {
    _activePoses.clear();
    _sortedEntries.clear();
    _hasActiveTweens = false;

    if (table == null || table.isEmpty || cols <= 0 || rows <= 0) {
      _tracked.clear();
      _lastEvaluated.clear();
      return;
    }

    final maxIndex = cols * rows;
    _pruneRemovedEntries(table);

    for (final entry in table.entries) {
      final cellIdx = entry.key;
      if (cellIdx < 0 || cellIdx >= maxIndex) continue;
      final pose = _evaluateSingleCell(cellIdx, entry.value, nowSec);
      if (pose == null) continue;
      _activePoses[cellIdx] = pose;
      _lastEvaluated[cellIdx] = pose;
      _sortedEntries.add((
        cellIndex: cellIdx,
        col: cellIdx % cols,
        row: cellIdx ~/ cols,
        pose: pose,
      ));
    }

    if (_sortedEntries.length > 1) {
      _sortedEntries.sort(_compareEntries);
    }
  }

  /// Clears all tracked tween timelines and evaluated poses.
  void reset() {
    _tracked.clear();
    _activePoses.clear();
    _lastEvaluated.clear();
    _sortedEntries.clear();
    _hasActiveTweens = false;
  }

  void _pruneRemovedEntries(CellTransformTable table) {
    _tracked.removeWhere((cellIdx, _) => table[cellIdx] == null);
    _lastEvaluated.removeWhere((cellIdx, _) => table[cellIdx] == null);
  }

  EvaluatedCellTransform? _evaluateSingleCell(
    int cellIdx,
    CellTransform transform,
    double nowSec,
  ) {
    final tween = transform.tween;
    if (tween == null) {
      _tracked.remove(cellIdx);
      return _poseFromTransform(transform);
    }
    return _evaluateTweenedCell(cellIdx, transform, tween, nowSec);
  }

  EvaluatedCellTransform? _evaluateTweenedCell(
    int cellIdx,
    CellTransform transform,
    CellTween tween,
    double nowSec,
  ) {
    final state = _resolveTweenState(cellIdx, transform, tween, nowSec);
    final duration = tween.durationSec.clamp(
      CellTween.minDurationSec,
      CellTween.maxDurationSec,
    );
    final elapsed = math.max(0.0, nowSec - state.startTimeSec);
    final rawT = (elapsed / duration).clamp(0.0, 1.0);
    if (rawT < 1.0) {
      _hasActiveTweens = true;
    } else if (tween.clearOnFinish) {
      _lastEvaluated.remove(cellIdx);
      return null;
    }

    final easedT = tween.easing.evaluate(rawT);
    final endPose = EvaluatedCellTransform(
      dx: tween.endDx,
      dy: tween.endDy,
      scaleX: tween.endScaleX,
      scaleY: tween.endScaleY,
      rotationRad: tween.endRotationRad,
      alpha: tween.endAlpha,
      zLayer: transform.zLayer,
    );
    final evaluated = EvaluatedCellTransform.lerp(
      state.startPose,
      endPose,
      easedT,
      zLayer: transform.zLayer,
    );
    state.lastPose = evaluated;
    return evaluated;
  }

  _TrackedCellTween _resolveTweenState(
    int cellIdx,
    CellTransform transform,
    CellTween tween,
    double nowSec,
  ) {
    final existing = _tracked[cellIdx];
    if (existing != null && existing.animationId == tween.animationId) {
      return existing;
    }
    final basePose = _poseFromTransform(transform);
    final startPose = tween.fromCurrent
        ? (existing?.lastPose ?? _lastEvaluated[cellIdx] ?? basePose)
        : basePose;
    final created = _TrackedCellTween(
      animationId: tween.animationId,
      startTimeSec: nowSec,
      startPose: startPose,
      lastPose: startPose,
    );
    _tracked[cellIdx] = created;
    return created;
  }

  static EvaluatedCellTransform _poseFromTransform(CellTransform t) =>
      EvaluatedCellTransform(
        dx: t.dx,
        dy: t.dy,
        scaleX: t.scaleX,
        scaleY: t.scaleY,
        rotationRad: t.rotationRad,
        alpha: t.alpha,
        zLayer: t.zLayer,
      );

  static int _compareEntries(EvaluatedCellEntry a, EvaluatedCellEntry b) {
    final zCmp = a.pose.zLayer.compareTo(b.pose.zLayer);
    return zCmp != 0 ? zCmp : a.cellIndex.compareTo(b.cellIndex);
  }
}

final class _TrackedCellTween {
  final int animationId;
  final double startTimeSec;
  final EvaluatedCellTransform startPose;
  EvaluatedCellTransform lastPose;

  _TrackedCellTween({
    required this.animationId,
    required this.startTimeSec,
    required this.startPose,
    required this.lastPose,
  });
}

/// Reusable per-frame builder for Step 1's `TuiAtlasPainter.cellOverrideMask`.
///
/// Marks active transformed cells and `ShaderRegionStage.replaceGlyphs` source
/// cells with non-zero bytes so static row caches stay valid across 120 Hz
/// animations without drawing duplicate static glyphs.
final class CellOverrideMaskBuilder {
  Uint8List _mask = Uint8List(0);
  final List<int> _markedIndices = <int>[];
  int _lastMaskHash = 0;

  /// Order-independent FNV-1a hash of the currently marked override cell
  /// indices (`0` when no cells are masked).
  int get lastMaskHash => _lastMaskHash;

  /// Builds or returns `null` when no cell overrides are active.
  Uint8List? build({
    required int cols,
    required int rows,
    required Map<int, EvaluatedCellTransform> activeTransforms,
    required Iterable<ShaderRegion> replaceRegions,
  }) {
    if (cols <= 0 || rows <= 0) {
      _clearMarkedCells();
      _lastMaskHash = 0;
      return null;
    }
    final hasReplace = replaceRegions.isNotEmpty;
    if (activeTransforms.isEmpty && !hasReplace) {
      _clearMarkedCells();
      _lastMaskHash = 0;
      return null;
    }

    final cellCount = cols * rows;
    if (_mask.length != cellCount) {
      _mask = Uint8List(cellCount);
      _markedIndices.clear();
    } else {
      _clearMarkedCells();
    }

    for (final cellIdx in activeTransforms.keys) {
      if (cellIdx >= 0 && cellIdx < cellCount) {
        _markCell(cellIdx);
      }
    }
    for (final region in replaceRegions) {
      _markRegionRects(region, cols, rows);
    }
    if (_markedIndices.isEmpty) {
      _lastMaskHash = 0;
      return null;
    }
    _lastMaskHash = _computeSparseHash();
    return _mask;
  }

  void _clearMarkedCells() {
    for (final idx in _markedIndices) {
      if (idx < _mask.length) {
        _mask[idx] = 0;
      }
    }
    _markedIndices.clear();
  }

  void _markCell(int cellIdx) {
    if (_mask[cellIdx] != 0) return;
    _mask[cellIdx] = 1;
    _markedIndices.add(cellIdx);
  }

  int _computeSparseHash() {
    if (_markedIndices.length > 1) {
      _markedIndices.sort();
    }
    var hash = 0x811C9DC5;
    for (final idx in _markedIndices) {
      hash = ((hash ^ ((idx << 8) | 1)) * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  void _markRegionRects(ShaderRegion region, int cols, int rows) {
    for (final rect in region.sourceRects) {
      final minX = rect.x.clamp(0, cols);
      final maxX = (rect.x + rect.width).clamp(0, cols);
      final minY = rect.y.clamp(0, rows);
      final maxY = (rect.y + rect.height).clamp(0, rows);
      for (var y = minY; y < maxY; y++) {
        final rowBase = y * cols;
        for (var x = minX; x < maxX; x++) {
          _markCell(rowBase + x);
        }
      }
    }
  }
}

/// Packed GPU transformed-slice result returned by [CellTransformGpuStager].
typedef StagedTransformGpuSlice = ({
  Float32List data,
  int count,
  int underGlyphCount,
  int generation,
  bool hasCanvasOnlyFallback,
});

/// Packs evaluated transformed cells (and scoped `ShaderRegion` mask glyphs)
/// into 64-byte-strided `GpuAtlasQuadBatch` instance buffers with full
/// non-uniform `(scaleX, scaleY)` and `a_extra.w` `rotationRad` fidelity.
final class CellTransformGpuStager {
  static const double _italicTranslateXFactor = 0.14;
  static const double _italicSkewSlopeX = -0.18;
  static const double _boldOffsetLogical = 0.6;
  static const int _decorationMask =
      Modifier.underline | Modifier.crossedOut | Modifier.overline;

  Float32List _buffer = Float32List(0);
  int _capacityInstances = 0;
  int _count = 0;
  int _generation = 0;
  int _lastHash = 0;
  int _lastCount = -1;

  /// Stages [entries] in ascending `zLayer` order into a reusable GPU instance
  /// buffer, incrementing [generation] only when packed instance data changes.
  StagedTransformGpuSlice stageTransformedCells({
    required Buffer buffer,
    required GlyphAtlas atlas,
    required List<EvaluatedCellEntry> entries,
    required double devicePixelRatio,
    required int defaultForegroundArgb,
    required int defaultBackgroundArgb,
    required double faintOpacity,
    required TerminalColorTheme palette,
  }) {
    _count = 0;
    if (entries.isEmpty) {
      if (_lastCount != 0) {
        _generation++;
        _lastCount = 0;
        _lastHash = 0;
      }
      return (
        data: _buffer,
        count: 0,
        underGlyphCount: 0,
        generation: _generation,
        hasCanvasOnlyFallback: false,
      );
    }

    var underGlyphCount = 0;
    var hasCanvasFallback = false;
    final invAtlasW = atlas.image.width > 0 ? 1.0 / atlas.image.width : 0.0;
    final invAtlasH = atlas.image.height > 0 ? 1.0 / atlas.image.height : 0.0;

    for (final entry in entries) {
      if (!entry.pose.isVisible) continue;
      final beforeCount = _count;
      final ok = appendCellInstances(
        buffer: buffer,
        atlas: atlas,
        col: entry.col,
        row: entry.row,
        pose: entry.pose,
        originOffsetPhysX: 0.0,
        originOffsetPhysY: 0.0,
        devicePixelRatio: devicePixelRatio,
        invAtlasW: invAtlasW,
        invAtlasH: invAtlasH,
        defaultForegroundArgb: defaultForegroundArgb,
        defaultBackgroundArgb: defaultBackgroundArgb,
        faintOpacity: faintOpacity,
        palette: palette,
      );
      if (!ok) {
        hasCanvasFallback = true;
      }
      if (entry.pose.zLayer < 0) {
        underGlyphCount += _count - beforeCount;
      }
    }

    final hash = _hashActiveInstances();
    if (_count != _lastCount || hash != _lastHash) {
      _generation++;
      _lastCount = _count;
      _lastHash = hash;
    }
    return (
      data: _buffer,
      count: _count,
      underGlyphCount: underGlyphCount,
      generation: _generation,
      hasCanvasOnlyFallback: hasCanvasFallback,
    );
  }

  /// Resets the write cursor to `0` so callers can pack custom batches (such
  /// as tight region `uGlyphMask` glyph slices) using [appendCellInstances].
  void resetWriteCursor() {
    _count = 0;
  }

  /// Current active packed buffer.
  Float32List get buffer => _buffer;

  /// Current number of packed instances since [resetWriteCursor].
  int get count => _count;

  /// Commits the current write cursor and returns the monotonic generation
  /// (incrementing only when the packed float payload changed).
  int commitGeneration() {
    final hash = _hashActiveInstances();
    if (_count != _lastCount || hash != _lastHash) {
      _generation++;
      _lastCount = _count;
      _lastHash = hash;
    }
    return _generation;
  }

  /// Appends GPU atlas instance(s) for a single cell at `(col, row)` with
  /// [pose], shifted by `(-originOffsetPhysX, -originOffsetPhysY)`.
  ///
  /// Returns `false` if the cell requires a Canvas-only fallback glyph not
  /// present in [atlas].
  bool appendCellInstances({
    required Buffer buffer,
    required GlyphAtlas atlas,
    required int col,
    required int row,
    required EvaluatedCellTransform pose,
    required double originOffsetPhysX,
    required double originOffsetPhysY,
    required double devicePixelRatio,
    required double invAtlasW,
    required double invAtlasH,
    required int defaultForegroundArgb,
    required int defaultBackgroundArgb,
    required double faintOpacity,
    required TerminalColorTheme palette,
  }) {
    if (!pose.isVisible ||
        col < 0 ||
        col >= buffer.width ||
        row < 0 ||
        row >= buffer.height) {
      return true;
    }
    final cellIdx = row * buffer.width + col;
    final code = buffer.glyphCodes[cellIdx];
    if (code == GlyphCellList.wideContinuationCode) return true;

    final attrBase = cellIdx * 3;
    final fgArgb = buffer.attributes[attrBase];
    final bgArgb = buffer.attributes[attrBase + 1];
    final modifiers = buffer.attributes[attrBase + 2];
    if (Modifier.has(modifiers, Modifier.hidden) ||
        Modifier.has(modifiers, Modifier.kittyPlaceholder) ||
        code == kittyPlaceholderCodePoint) {
      return true;
    }

    final isReverse = Modifier.has(modifiers, Modifier.reverse);
    final baseFg = TuiAtlasPainter.resolveCellForegroundArgb(
      fgArgb,
      bgArgb,
      modifiers: modifiers,
      isReverse: isReverse,
      defaultForegroundArgb: defaultForegroundArgb,
      defaultBackgroundArgb: defaultBackgroundArgb,
      faintOpacity: faintOpacity,
      palette: palette,
    );
    final resolvedFg = _applyAlpha(baseFg, pose.alpha);

    var supported = true;
    if (code != GlyphCellList.spaceCode) {
      supported = _appendGlyphInstances(
        buffer: buffer,
        atlas: atlas,
        code: code,
        col: col,
        row: row,
        modifiers: modifiers,
        resolvedFg: resolvedFg,
        pose: pose,
        originOffsetPhysX: originOffsetPhysX,
        originOffsetPhysY: originOffsetPhysY,
        dpr: devicePixelRatio,
        invAtlasW: invAtlasW,
        invAtlasH: invAtlasH,
      );
    }
    if ((modifiers & _decorationMask) != 0) {
      _appendDecorationInstances(
        buffer: buffer,
        atlas: atlas,
        code: code,
        cellIdx: cellIdx,
        col: col,
        row: row,
        modifiers: modifiers,
        resolvedFg: resolvedFg,
        pose: pose,
        originOffsetPhysX: originOffsetPhysX,
        originOffsetPhysY: originOffsetPhysY,
        dpr: devicePixelRatio,
        invAtlasW: invAtlasW,
        invAtlasH: invAtlasH,
        palette: palette,
      );
    }
    return supported;
  }

  bool _appendGlyphInstances({
    required Buffer buffer,
    required GlyphAtlas atlas,
    required int code,
    required int col,
    required int row,
    required int modifiers,
    required int resolvedFg,
    required EvaluatedCellTransform pose,
    required double originOffsetPhysX,
    required double originOffsetPhysY,
    required double dpr,
    required double invAtlasW,
    required double invAtlasH,
  }) {
    final isBold = Modifier.has(modifiers, Modifier.bold);
    final isItalic = Modifier.has(modifiers, Modifier.italic);
    final resolved = _lookupAtlasGlyph(
      buffer: buffer,
      atlas: atlas,
      code: code,
      isBold: isBold,
      isItalic: isItalic,
    );
    if (resolved == null) return false;

    final cellW = atlas.cellWidth;
    final cellH = atlas.cellHeight;
    final fgScale = 1.0 / atlas.devicePixelRatio;
    final overhangPhys = (GlyphAtlas.overhang * atlas.devicePixelRatio)
        .floorToDouble();
    final canExpand =
        overhangPhys > 0.0 &&
        resolved.l >= overhangPhys &&
        resolved.t >= overhangPhys &&
        resolved.r + overhangPhys <= atlas.image.width &&
        resolved.b + overhangPhys <= atlas.image.height;
    final expand = canExpand && (resolved.isEmoji || isItalic || isBold);
    final padPhys = expand ? overhangPhys : 0.0;
    final padLogical = expand ? overhangPhys * fgScale : 0.0;

    final srcL = resolved.l - padPhys;
    final srcT = resolved.t - padPhys;
    final srcR = resolved.r + padPhys;
    final srcB = resolved.b + padPhys;
    final baseW = (srcR - srcL) * fgScale;
    final baseH = (srcB - srcT) * fgScale;

    final cxLogical = (col + 0.5 + pose.dx) * cellW;
    final cyLogical = (row + 0.5 + pose.dy) * cellH;
    final italicShift = resolved.syntheticItalic
        ? cellW * _italicTranslateXFactor
        : 0.0;
    final shearSlope = resolved.syntheticItalic ? _italicSkewSlopeX : 0.0;
    final dstWPhys = baseW * pose.scaleX * dpr;
    final dstHPhys = baseH * pose.scaleY * dpr;
    final dstXPhys =
        (cxLogical + (-cellW * 0.5 - padLogical + italicShift) * pose.scaleX) *
            dpr -
        originOffsetPhysX;
    final dstYPhys =
        (cyLogical + (-cellH * 0.5 - padLogical) * pose.scaleY) * dpr -
        originOffsetPhysY;
    final shearOriginYPhys =
        (cyLogical - cellH * 0.5 * pose.scaleY) * dpr - originOffsetPhysY;
    final colorArgb = resolved.isEmoji
        ? _applyAlpha(0xFFFFFFFF, pose.alpha)
        : resolvedFg;

    _appendInstance(
      dstX: dstXPhys,
      dstY: dstYPhys,
      dstW: dstWPhys,
      dstH: dstHPhys,
      u0: srcL * invAtlasW,
      v0: srcT * invAtlasH,
      u1: srcR * invAtlasW,
      v1: srcB * invAtlasH,
      argb: colorArgb,
      shearSlopeX: shearSlope,
      shearOriginY: shearOriginYPhys,
      rotationRad: pose.rotationRad,
    );

    if (resolved.syntheticBold) {
      _appendInstance(
        dstX: dstXPhys + _boldOffsetLogical * pose.scaleX * dpr,
        dstY: dstYPhys,
        dstW: dstWPhys,
        dstH: dstHPhys,
        u0: srcL * invAtlasW,
        v0: srcT * invAtlasH,
        u1: srcR * invAtlasW,
        v1: srcB * invAtlasH,
        argb: colorArgb,
        shearSlopeX: shearSlope,
        shearOriginY: shearOriginYPhys,
        rotationRad: pose.rotationRad,
      );
    }
    return true;
  }

  void _appendDecorationInstances({
    required Buffer buffer,
    required GlyphAtlas atlas,
    required int code,
    required int cellIdx,
    required int col,
    required int row,
    required int modifiers,
    required int resolvedFg,
    required EvaluatedCellTransform pose,
    required double originOffsetPhysX,
    required double originOffsetPhysY,
    required double dpr,
    required double invAtlasW,
    required double invAtlasH,
    required TerminalColorTheme palette,
  }) {
    final isWide = (code & GlyphCellList.clusterFlag) == 0
        ? isWideCodePoint(code)
        : isWideGrapheme(buffer.glyphCellList.decodeCode(code));
    if (Modifier.has(modifiers, Modifier.overline)) {
      _appendSingleDecoration(
        atlas: atlas,
        kind: AtlasDecorationKind.overline,
        isWide: isWide,
        col: col,
        row: row,
        argb: resolvedFg,
        pose: pose,
        originOffsetPhysX: originOffsetPhysX,
        originOffsetPhysY: originOffsetPhysY,
        dpr: dpr,
        invAtlasW: invAtlasW,
        invAtlasH: invAtlasH,
      );
    }
    if (Modifier.has(modifiers, Modifier.crossedOut)) {
      _appendSingleDecoration(
        atlas: atlas,
        kind: AtlasDecorationKind.strikethrough,
        isWide: isWide,
        col: col,
        row: row,
        argb: resolvedFg,
        pose: pose,
        originOffsetPhysX: originOffsetPhysX,
        originOffsetPhysY: originOffsetPhysY,
        dpr: dpr,
        invAtlasW: invAtlasW,
        invAtlasH: invAtlasH,
      );
    }
    if (!Modifier.has(modifiers, Modifier.underline)) return;
    final kind = _decorationKindForUnderline(
      Modifier.getUnderlineStyle(modifiers),
    );
    if (kind == null) return;
    final ulRaw = buffer.hasUnderlineColors
        ? buffer.getUnderlineColorAt(cellIdx)
        : 0;
    final ulColor = ulRaw != 0
        ? _applyAlpha(palette.resolvePackedColor(ulRaw), pose.alpha)
        : resolvedFg;
    _appendSingleDecoration(
      atlas: atlas,
      kind: kind,
      isWide: isWide,
      col: col,
      row: row,
      argb: ulColor,
      pose: pose,
      originOffsetPhysX: originOffsetPhysX,
      originOffsetPhysY: originOffsetPhysY,
      dpr: dpr,
      invAtlasW: invAtlasW,
      invAtlasH: invAtlasH,
    );
  }

  void _appendSingleDecoration({
    required GlyphAtlas atlas,
    required AtlasDecorationKind kind,
    required bool isWide,
    required int col,
    required int row,
    required int argb,
    required EvaluatedCellTransform pose,
    required double originOffsetPhysX,
    required double originOffsetPhysY,
    required double dpr,
    required double invAtlasW,
    required double invAtlasH,
  }) {
    final quadOffset = atlas.quadTable.decorationQuadOffset(
      kind,
      isWide: isWide,
    );
    if (quadOffset < 0) return;
    final quads = atlas.quadTable.ltrbQuads;
    final l = quads[quadOffset];
    final t = quads[quadOffset + 1];
    final r = quads[quadOffset + 2];
    final b = quads[quadOffset + 3];
    final fgScale = 1.0 / atlas.devicePixelRatio;
    final baseW = (r - l) * fgScale;
    final baseH = (b - t) * fgScale;
    final cellW = atlas.cellWidth;
    final cellH = atlas.cellHeight;
    final cxLogical = (col + 0.5 + pose.dx) * cellW;
    final cyLogical = (row + 0.5 + pose.dy) * cellH;
    _appendInstance(
      dstX: (cxLogical - cellW * 0.5 * pose.scaleX) * dpr - originOffsetPhysX,
      dstY: (cyLogical - cellH * 0.5 * pose.scaleY) * dpr - originOffsetPhysY,
      dstW: baseW * pose.scaleX * dpr,
      dstH: baseH * pose.scaleY * dpr,
      u0: l * invAtlasW,
      v0: t * invAtlasH,
      u1: r * invAtlasW,
      v1: b * invAtlasH,
      argb: argb,
      shearSlopeX: 0.0,
      shearOriginY: 0.0,
      rotationRad: pose.rotationRad,
    );
  }

  void _appendInstance({
    required double dstX,
    required double dstY,
    required double dstW,
    required double dstH,
    required double u0,
    required double v0,
    required double u1,
    required double v1,
    required int argb,
    required double shearSlopeX,
    required double shearOriginY,
    required double rotationRad,
  }) {
    _ensureCapacity(_count + 1);
    final out = _buffer;
    final base = _count * GpuAtlasQuadBatch.floatsPerInstance;
    final a = ((argb >>> 24) & 0xFF) / 255.0;
    out[base] = dstX;
    out[base + 1] = dstY;
    out[base + 2] = dstW;
    out[base + 3] = dstH;
    out[base + 4] = u0;
    out[base + 5] = v0;
    out[base + 6] = u1;
    out[base + 7] = v1;
    out[base + 8] = (((argb >>> 16) & 0xFF) / 255.0) * a;
    out[base + 9] = (((argb >>> 8) & 0xFF) / 255.0) * a;
    out[base + 10] = ((argb & 0xFF) / 255.0) * a;
    out[base + 11] = a;
    out[base + 12] = shearSlopeX;
    out[base + 13] = shearOriginY;
    out[base + 14] = GpuAtlasQuadBatch.modeTextured;
    out[base + 15] = rotationRad;
    _count++;
  }

  void _ensureCapacity(int requiredInstances) {
    if (requiredInstances <= _capacityInstances) return;
    var nextCap = _capacityInstances == 0 ? 64 : _capacityInstances;
    while (nextCap < requiredInstances) {
      nextCap <<= 1;
    }
    final next = Float32List(nextCap * GpuAtlasQuadBatch.floatsPerInstance);
    if (_count > 0) {
      next.setRange(0, _count * GpuAtlasQuadBatch.floatsPerInstance, _buffer);
    }
    _buffer = next;
    _capacityInstances = nextCap;
  }

  int _hashActiveInstances() {
    final activeFloats = _count * GpuAtlasQuadBatch.floatsPerInstance;
    if (activeFloats == 0) return 0;
    final words = Uint32List.view(_buffer.buffer, 0, activeFloats);
    var hash = 0x811C9DC5;
    for (var i = 0; i < activeFloats; i++) {
      hash = ((hash ^ words[i]) * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }
}

/// Uniform-scale `Canvas.drawRawAtlas` and `Canvas.save`/`transform`/`restore`
/// fallback painter for transformed terminal cells when `DisabledShaderBackend`
/// or Canvas-only fallback is active.
///
/// Strictly clips all output to the terminal pane viewport and never invokes
/// `Canvas.drawVertices`.
final class CellTransformPainter {
  static final Paint _atlasPaint = Paint()..filterQuality = FilterQuality.low;
  static final Paint _emojiPaint = Paint()..filterQuality = FilterQuality.low;
  static final Paint _italicPaint = Paint()..filterQuality = FilterQuality.low;

  Float32List _transforms = Float32List(0);
  Float32List _rects = Float32List(0);
  Int32List _colors = Int32List(0);
  int _batchCap = 0;
  int _batchCount = 0;

  Float32List _emojiTransforms = Float32List(0);
  Float32List _emojiRects = Float32List(0);
  int _emojiCap = 0;
  int _emojiCount = 0;

  /// Paints all [entries] clipped strictly to `Offset.zero & viewportSize`.
  void paintCanvas({
    required Canvas canvas,
    required Size viewportSize,
    required Buffer buffer,
    required GlyphAtlas atlas,
    required List<EvaluatedCellEntry> entries,
    required int defaultForegroundArgb,
    required int defaultBackgroundArgb,
    required double faintOpacity,
    required TerminalColorTheme palette,
    required String fontFamily,
    required List<String>? fontFamilyFallback,
    required Map<(String, bool, bool, bool, Color), TextPainter>
    fallbackPainters,
  }) {
    if (entries.isEmpty || viewportSize.isEmpty) return;

    canvas.save();
    try {
      canvas.clipRect(Offset.zero & viewportSize);
      _paintClippedEntries(
        canvas: canvas,
        buffer: buffer,
        atlas: atlas,
        entries: entries,
        defaultForegroundArgb: defaultForegroundArgb,
        defaultBackgroundArgb: defaultBackgroundArgb,
        faintOpacity: faintOpacity,
        palette: palette,
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
        fallbackPainters: fallbackPainters,
      );
    } finally {
      canvas.restore();
    }
  }

  void _paintClippedEntries({
    required Canvas canvas,
    required Buffer buffer,
    required GlyphAtlas atlas,
    required List<EvaluatedCellEntry> entries,
    required int defaultForegroundArgb,
    required int defaultBackgroundArgb,
    required double faintOpacity,
    required TerminalColorTheme palette,
    required String fontFamily,
    required List<String>? fontFamilyFallback,
    required Map<(String, bool, bool, bool, Color), TextPainter>
    fallbackPainters,
  }) {
    _batchCount = 0;
    _emojiCount = 0;
    var currentZ = entries.first.pose.zLayer;

    for (final entry in entries) {
      if (!entry.pose.isVisible) continue;
      if (entry.pose.zLayer != currentZ) {
        _flushAtlasBatches(canvas, atlas.image);
        currentZ = entry.pose.zLayer;
      }
      _stageOrPaintSingleCanvasCell(
        canvas: canvas,
        buffer: buffer,
        atlas: atlas,
        entry: entry,
        defaultForegroundArgb: defaultForegroundArgb,
        defaultBackgroundArgb: defaultBackgroundArgb,
        faintOpacity: faintOpacity,
        palette: palette,
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
        fallbackPainters: fallbackPainters,
      );
    }
    _flushAtlasBatches(canvas, atlas.image);
  }

  void _stageOrPaintSingleCanvasCell({
    required Canvas canvas,
    required Buffer buffer,
    required GlyphAtlas atlas,
    required EvaluatedCellEntry entry,
    required int defaultForegroundArgb,
    required int defaultBackgroundArgb,
    required double faintOpacity,
    required TerminalColorTheme palette,
    required String fontFamily,
    required List<String>? fontFamilyFallback,
    required Map<(String, bool, bool, bool, Color), TextPainter>
    fallbackPainters,
  }) {
    final col = entry.col;
    final row = entry.row;
    if (col < 0 || col >= buffer.width || row < 0 || row >= buffer.height) {
      return;
    }
    final cellIdx = entry.cellIndex;
    final code = buffer.glyphCodes[cellIdx];
    if (code == GlyphCellList.wideContinuationCode ||
        code == GlyphCellList.spaceCode) {
      return;
    }

    final attrBase = cellIdx * 3;
    final fgArgb = buffer.attributes[attrBase];
    final bgArgb = buffer.attributes[attrBase + 1];
    final modifiers = buffer.attributes[attrBase + 2];
    if (Modifier.has(modifiers, Modifier.hidden) ||
        Modifier.has(modifiers, Modifier.kittyPlaceholder) ||
        code == kittyPlaceholderCodePoint) {
      return;
    }

    final isReverse = Modifier.has(modifiers, Modifier.reverse);
    final baseFg = TuiAtlasPainter.resolveCellForegroundArgb(
      fgArgb,
      bgArgb,
      modifiers: modifiers,
      isReverse: isReverse,
      defaultForegroundArgb: defaultForegroundArgb,
      defaultBackgroundArgb: defaultBackgroundArgb,
      faintOpacity: faintOpacity,
      palette: palette,
    );
    final resolvedFg = _applyAlpha(baseFg, entry.pose.alpha);
    final isBold = Modifier.has(modifiers, Modifier.bold);
    final isItalic = Modifier.has(modifiers, Modifier.italic);

    final glyph = _lookupAtlasGlyph(
      buffer: buffer,
      atlas: atlas,
      code: code,
      isBold: isBold,
      isItalic: isItalic,
    );
    if (glyph == null) {
      _flushAtlasBatches(canvas, atlas.image);
      _paintFallbackCanvasGlyph(
        canvas: canvas,
        atlas: atlas,
        char: buffer.glyphCellList.decodeCode(code),
        col: col,
        row: row,
        pose: entry.pose,
        resolvedFg: resolvedFg,
        modifiers: modifiers,
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
        fallbackPainters: fallbackPainters,
      );
      return;
    }
    if (glyph.syntheticItalic) {
      _flushAtlasBatches(canvas, atlas.image);
      _paintSyntheticItalicCanvasGlyph(
        canvas: canvas,
        atlas: atlas,
        glyph: glyph,
        col: col,
        row: row,
        pose: entry.pose,
        resolvedFg: resolvedFg,
      );
      return;
    }

    _appendRawAtlasGlyph(
      atlas: atlas,
      glyph: glyph,
      col: col,
      row: row,
      pose: entry.pose,
      resolvedFg: resolvedFg,
    );
  }

  void _appendRawAtlasGlyph({
    required GlyphAtlas atlas,
    required _ResolvedAtlasGlyph glyph,
    required int col,
    required int row,
    required EvaluatedCellTransform pose,
    required int resolvedFg,
  }) {
    final cx = (col + 0.5 + pose.dx) * atlas.cellWidth;
    final cy = (row + 0.5 + pose.dy) * atlas.cellHeight;
    final scale = (1.0 / atlas.devicePixelRatio) * pose.uniformScale;
    final cosR = math.cos(pose.rotationRad) * scale;
    final sinR = math.sin(pose.rotationRad) * scale;
    final anchorX = (glyph.r - glyph.l) * 0.5;
    final anchorY = (glyph.b - glyph.t) * 0.5;
    final tx = cx - cosR * anchorX + sinR * anchorY;
    final ty = cy - sinR * anchorX - cosR * anchorY;

    if (glyph.isEmoji) {
      _pushEmojiSprite(cosR, sinR, tx, ty, glyph.l, glyph.t, glyph.r, glyph.b);
      return;
    }
    _pushTextSprite(
      cosR,
      sinR,
      tx,
      ty,
      glyph.l,
      glyph.t,
      glyph.r,
      glyph.b,
      resolvedFg,
    );
    if (glyph.syntheticBold) {
      final boldDx = math.cos(pose.rotationRad) * 0.6 * pose.uniformScale;
      final boldDy = math.sin(pose.rotationRad) * 0.6 * pose.uniformScale;
      _pushTextSprite(
        cosR,
        sinR,
        tx + boldDx,
        ty + boldDy,
        glyph.l,
        glyph.t,
        glyph.r,
        glyph.b,
        resolvedFg,
      );
    }
  }

  void _paintSyntheticItalicCanvasGlyph({
    required Canvas canvas,
    required GlyphAtlas atlas,
    required _ResolvedAtlasGlyph glyph,
    required int col,
    required int row,
    required EvaluatedCellTransform pose,
    required int resolvedFg,
  }) {
    final cx = (col + 0.5 + pose.dx) * atlas.cellWidth;
    final cy = (row + 0.5 + pose.dy) * atlas.cellHeight;
    final fgScale = 1.0 / atlas.devicePixelRatio;
    final srcRect = Rect.fromLTRB(glyph.l, glyph.t, glyph.r, glyph.b);
    final dstW = srcRect.width * fgScale;
    final dstH = srcRect.height * fgScale;

    _italicPaint.colorFilter = ColorFilter.mode(
      Color(resolvedFg),
      BlendMode.modulate,
    );
    canvas.save();
    try {
      canvas.translate(cx, cy);
      if (pose.rotationRad != 0.0) canvas.rotate(pose.rotationRad);
      if (pose.scaleX != 1.0 || pose.scaleY != 1.0) {
        canvas.scale(pose.scaleX, pose.scaleY);
      }
      canvas.translate(
        -atlas.cellWidth * 0.5 + atlas.cellWidth * 0.14,
        -atlas.cellHeight * 0.5,
      );
      canvas.skew(-0.18, 0.0);
      canvas.drawImageRect(
        atlas.image,
        srcRect,
        Rect.fromLTWH(0.0, 0.0, dstW, dstH),
        _italicPaint,
      );
      if (glyph.syntheticBold) {
        canvas.drawImageRect(
          atlas.image,
          srcRect,
          Rect.fromLTWH(0.6, 0.0, dstW, dstH),
          _italicPaint,
        );
      }
    } finally {
      canvas.restore();
    }
  }

  void _paintFallbackCanvasGlyph({
    required Canvas canvas,
    required GlyphAtlas atlas,
    required String char,
    required int col,
    required int row,
    required EvaluatedCellTransform pose,
    required int resolvedFg,
    required int modifiers,
    required String fontFamily,
    required List<String>? fontFamilyFallback,
    required Map<(String, bool, bool, bool, Color), TextPainter>
    fallbackPainters,
  }) {
    final isBold = Modifier.has(modifiers, Modifier.bold);
    final isItalic = Modifier.has(modifiers, Modifier.italic);
    final isDim = Modifier.has(modifiers, Modifier.dim);
    final color = Color(resolvedFg);
    final cached = fallbackPainters[(char, isBold, isItalic, isDim, color)];
    final tp =
        cached ??
        (TextPainter(
          text: TextSpan(
            text: char,
            style: TextStyle(
              fontFamily: fontFamily,
              fontFamilyFallback: fontFamilyFallback,
              fontSize: atlas.fontSize,
              color: color,
              fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
              fontStyle: isItalic ? FontStyle.italic : FontStyle.normal,
              letterSpacing: 0.0,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout());
    final cellW = isWideGrapheme(char) ? atlas.cellWidth * 2 : atlas.cellWidth;
    final cellH = atlas.cellHeight;
    final cx = (col + 0.5 + pose.dx) * atlas.cellWidth;
    final cy = (row + 0.5 + pose.dy) * cellH;
    final dx = (cellW - tp.width) * 0.5;
    final dy =
        atlas.standardBaseline -
        tp.computeDistanceToActualBaseline(TextBaseline.alphabetic);

    canvas.save();
    try {
      canvas.translate(cx, cy);
      if (pose.rotationRad != 0.0) canvas.rotate(pose.rotationRad);
      if (pose.scaleX != 1.0 || pose.scaleY != 1.0) {
        canvas.scale(pose.scaleX, pose.scaleY);
      }
      tp.paint(canvas, Offset(-atlas.cellWidth * 0.5 + dx, -cellH * 0.5 + dy));
    } finally {
      canvas.restore();
      if (cached == null) tp.dispose();
    }
  }

  void _flushAtlasBatches(Canvas canvas, ui.Image atlasImage) {
    if (_batchCount > 0) {
      canvas.drawRawAtlas(
        atlasImage,
        Float32List.sublistView(_transforms, 0, _batchCount * 4),
        Float32List.sublistView(_rects, 0, _batchCount * 4),
        Int32List.sublistView(_colors, 0, _batchCount),
        BlendMode.modulate,
        null,
        _atlasPaint,
      );
      _batchCount = 0;
    }
    if (_emojiCount > 0) {
      canvas.drawRawAtlas(
        atlasImage,
        Float32List.sublistView(_emojiTransforms, 0, _emojiCount * 4),
        Float32List.sublistView(_emojiRects, 0, _emojiCount * 4),
        null,
        BlendMode.srcOver,
        null,
        _emojiPaint,
      );
      _emojiCount = 0;
    }
  }

  void _pushTextSprite(
    double scos,
    double ssin,
    double tx,
    double ty,
    double l,
    double t,
    double r,
    double b,
    int argb,
  ) {
    if (_batchCount >= _batchCap) {
      final nextCap = _batchCap == 0 ? 64 : _batchCap * 2;
      _transforms = _growF32(_transforms, nextCap * 4, _batchCount * 4);
      _rects = _growF32(_rects, nextCap * 4, _batchCount * 4);
      _colors = _growI32(_colors, nextCap, _batchCount);
      _batchCap = nextCap;
    }
    final base = _batchCount * 4;
    _transforms[base] = scos;
    _transforms[base + 1] = ssin;
    _transforms[base + 2] = tx;
    _transforms[base + 3] = ty;
    _rects[base] = l;
    _rects[base + 1] = t;
    _rects[base + 2] = r;
    _rects[base + 3] = b;
    _colors[_batchCount] = argb;
    _batchCount++;
  }

  void _pushEmojiSprite(
    double scos,
    double ssin,
    double tx,
    double ty,
    double l,
    double t,
    double r,
    double b,
  ) {
    if (_emojiCount >= _emojiCap) {
      final nextCap = _emojiCap == 0 ? 16 : _emojiCap * 2;
      _emojiTransforms = _growF32(
        _emojiTransforms,
        nextCap * 4,
        _emojiCount * 4,
      );
      _emojiRects = _growF32(_emojiRects, nextCap * 4, _emojiCount * 4);
      _emojiCap = nextCap;
    }
    final base = _emojiCount * 4;
    _emojiTransforms[base] = scos;
    _emojiTransforms[base + 1] = ssin;
    _emojiTransforms[base + 2] = tx;
    _emojiTransforms[base + 3] = ty;
    _emojiRects[base] = l;
    _emojiRects[base + 1] = t;
    _emojiRects[base + 2] = r;
    _emojiRects[base + 3] = b;
    _emojiCount++;
  }

  static Float32List _growF32(Float32List old, int nextLen, int copyLen) {
    final next = Float32List(nextLen);
    if (copyLen > 0) next.setRange(0, copyLen, old);
    return next;
  }

  static Int32List _growI32(Int32List old, int nextLen, int copyLen) {
    final next = Int32List(nextLen);
    if (copyLen > 0) next.setRange(0, copyLen, old);
    return next;
  }
}

final class _ResolvedAtlasGlyph {
  final double l;
  final double t;
  final double r;
  final double b;
  final bool isEmoji;
  final bool syntheticBold;
  final bool syntheticItalic;

  const _ResolvedAtlasGlyph({
    required this.l,
    required this.t,
    required this.r,
    required this.b,
    required this.isEmoji,
    required this.syntheticBold,
    required this.syntheticItalic,
  });
}

_ResolvedAtlasGlyph? _lookupAtlasGlyph({
  required Buffer buffer,
  required GlyphAtlas atlas,
  required int code,
  required bool isBold,
  required bool isItalic,
}) {
  if ((code & GlyphCellList.clusterFlag) != 0) {
    final char = buffer.glyphCellList.decodeCode(code);
    final rect = atlas.rectFor(char, isBold: isBold, isItalic: isItalic);
    if (rect == null) return null;
    final variant = GlyphStyleVariant.fromFlags(
      isBold: isBold,
      isItalic: isItalic,
    );
    final hasNative =
        variant == GlyphStyleVariant.regular ||
        atlas.hasNativeVariant(char, variant);
    final emoji = isColorEmoji(char);
    return _ResolvedAtlasGlyph(
      l: rect.left,
      t: rect.top,
      r: rect.right,
      b: rect.bottom,
      isEmoji: emoji,
      syntheticBold: !emoji && isBold && !hasNative,
      syntheticItalic: !emoji && isItalic && !hasNative,
    );
  }

  final variantBits = (isBold ? 1 : 0) | (isItalic ? 2 : 0);
  final quadTable = atlas.quadTable;
  final quadOffset = quadTable.quadOffsetForCode(
    code,
    variantBits: variantBits,
  );
  if (quadOffset < 0) return null;
  final quads = quadTable.ltrbQuads;
  final emoji = code == 0xFE0F || (code >= 0x1F300 && code <= 0x1FAFF);
  final isBlock = code >= 0x2580 && code <= 0x2590;
  final hasNative =
      variantBits == 0 ||
      quadOffset != quadTable.quadOffsetForCode(code, variantBits: 0);
  return _ResolvedAtlasGlyph(
    l: quads[quadOffset],
    t: quads[quadOffset + 1],
    r: quads[quadOffset + 2],
    b: quads[quadOffset + 3],
    isEmoji: emoji,
    syntheticBold: !emoji && !isBlock && isBold && !hasNative,
    syntheticItalic: !emoji && !isBlock && isItalic && !hasNative,
  );
}

int _applyAlpha(int argb, double alpha) {
  final clamped = alpha.clamp(0.0, 1.0);
  if (clamped >= 1.0) return argb;
  final baseA = (argb >>> 24) & 0xFF;
  final outA = (baseA * clamped).round().clamp(0, 255);
  return (outA << 24) | (argb & 0x00FFFFFF);
}

AtlasDecorationKind? _decorationKindForUnderline(UnderlineStyle style) =>
    switch (style) {
      UnderlineStyle.none => null,
      UnderlineStyle.single => AtlasDecorationKind.underlineSingle,
      UnderlineStyle.doubleLine => AtlasDecorationKind.underlineDouble,
      UnderlineStyle.curly => AtlasDecorationKind.underlineCurly,
      UnderlineStyle.dotted => AtlasDecorationKind.underlineDotted,
      UnderlineStyle.dashed => AtlasDecorationKind.underlineDashed,
    };
