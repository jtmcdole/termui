import 'dart:typed_data';

/// Easing curve applied to a finite-duration [CellTween].
enum CellTweenEasing {
  /// Constant-velocity linear interpolation (`t`).
  linear(0, 'linear'),

  /// Quadratic ease-in (`t^2`).
  easeIn(1, 'in'),

  /// Quadratic ease-out (`1 - (1 - t)^2`).
  easeOut(2, 'out'),

  /// Quadratic ease-in-out.
  easeInOut(3, 'in_out');

  /// 3-bit discriminant encoded in bits `2..4` of the 64-byte wire struct.
  final int code;

  /// Canonical short wire name used in `ESC _ S a=xform,ease=...`.
  final String wireName;

  const CellTweenEasing(this.code, this.wireName);

  /// Evaluates the easing curve for normalized progress [t] clamped to `[0, 1]`.
  double evaluate(double t) {
    final x = t.isFinite ? t.clamp(0.0, 1.0).toDouble() : 1.0;
    return switch (this) {
      linear => x,
      easeIn => x * x,
      easeOut => 1.0 - (1.0 - x) * (1.0 - x),
      easeInOut =>
        x < 0.5
            ? 2.0 * x * x
            : 1.0 - ((-2.0 * x + 2.0) * (-2.0 * x + 2.0)) * 0.5,
    };
  }

  /// Decodes a wire easing code (`0..3`), returning `null` if out of range.
  static CellTweenEasing? fromCode(int code) => switch (code) {
    0 => linear,
    1 => easeIn,
    2 => easeOut,
    3 => easeInOut,
    _ => null,
  };

  /// Parses an APC wire name (`linear`, `in`, `out`, `in_out`, `inout`, etc.).
  static CellTweenEasing? fromWireName(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return switch (raw.trim().toLowerCase()) {
      'linear' || 'lin' => linear,
      'in' || 'easein' || 'ease_in' => easeIn,
      'out' || 'easeout' || 'ease_out' => easeOut,
      'in_out' || 'inout' || 'easeinout' || 'ease_in_out' => easeInOut,
      _ => null,
    };
  }
}

/// Finite-duration host tween attached to a [CellTransform].
///
/// The host interpolates smoothly at up to 120 Hz from the start pose (or the
/// cell's current interpolated pose when [fromCurrent] is `true`) to the target
/// pose over [durationSec] seconds using [easing], keyed by logical
/// [animationId] so unrelated TUI rebuilds never restart motion.
final class CellTween {
  /// Minimum allowed finite tween duration in seconds (`10 ms`).
  static const double minDurationSec = 0.01;

  /// Maximum allowed finite tween duration in seconds (`30 s`).
  static const double maxDurationSec = 30.0;

  /// Maximum logical `uint16` animation identifier (`65535`).
  static const int maxAnimationId = 0xFFFF;

  /// Stable logical identifier preventing unrelated rebuilds from restarting motion.
  final int animationId;

  /// Target fractional horizontal offset in cell widths.
  final double endDx;

  /// Target fractional vertical offset in cell heights.
  final double endDy;

  /// Target horizontal scale factor clamped to `[0.0, 4.0]`.
  final double endScaleX;

  /// Target vertical scale factor clamped to `[0.0, 4.0]`.
  final double endScaleY;

  /// Target rotation in radians around the cell center.
  final double endRotationRad;

  /// Target glyph opacity clamped to `[0.0, 1.0]`.
  final double endAlpha;

  /// Finite tween duration in seconds clamped to `[0.01, 30.0]`.
  final double durationSec;

  /// Interpolation curve between start and end poses.
  final CellTweenEasing easing;

  /// Whether to begin interpolation from the cell's current live animated pose.
  final bool fromCurrent;

  /// Whether to clear the cell transform when the tween completes (`false` holds end pose).
  final bool clearOnFinish;

  /// Creates a finite-duration cell tween.
  const CellTween({
    required this.animationId,
    this.endDx = 0.0,
    this.endDy = 0.0,
    this.endScaleX = 1.0,
    this.endScaleY = 1.0,
    this.endRotationRad = 0.0,
    this.endAlpha = 1.0,
    this.durationSec = 0.3,
    this.easing = CellTweenEasing.linear,
    this.fromCurrent = false,
    this.clearOnFinish = false,
  });

  /// Returns a finite, bounds-clamped copy of this tween.
  CellTween sanitized() => CellTween(
    animationId: animationId.clamp(0, maxAnimationId),
    endDx: _finiteOr(endDx, 0.0),
    endDy: _finiteOr(endDy, 0.0),
    endScaleX: _clampFinite(
      endScaleX,
      CellTransform.minScale,
      CellTransform.maxScale,
      1.0,
    ),
    endScaleY: _clampFinite(
      endScaleY,
      CellTransform.minScale,
      CellTransform.maxScale,
      1.0,
    ),
    endRotationRad: _finiteOr(endRotationRad, 0.0),
    endAlpha: _clampFinite(endAlpha, 0.0, 1.0, 1.0),
    durationSec: _clampFinite(durationSec, minDurationSec, maxDurationSec, 0.3),
    easing: easing,
    fromCurrent: fromCurrent,
    clearOnFinish: clearOnFinish,
  );

  /// Returns a copy with selected fields replaced.
  CellTween copyWith({
    int? animationId,
    double? endDx,
    double? endDy,
    double? endScaleX,
    double? endScaleY,
    double? endRotationRad,
    double? endAlpha,
    double? durationSec,
    CellTweenEasing? easing,
    bool? fromCurrent,
    bool? clearOnFinish,
  }) => CellTween(
    animationId: animationId ?? this.animationId,
    endDx: endDx ?? this.endDx,
    endDy: endDy ?? this.endDy,
    endScaleX: endScaleX ?? this.endScaleX,
    endScaleY: endScaleY ?? this.endScaleY,
    endRotationRad: endRotationRad ?? this.endRotationRad,
    endAlpha: endAlpha ?? this.endAlpha,
    durationSec: durationSec ?? this.durationSec,
    easing: easing ?? this.easing,
    fromCurrent: fromCurrent ?? this.fromCurrent,
    clearOnFinish: clearOnFinish ?? this.clearOnFinish,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CellTween &&
          other.animationId == animationId &&
          other.endDx == endDx &&
          other.endDy == endDy &&
          other.endScaleX == endScaleX &&
          other.endScaleY == endScaleY &&
          other.endRotationRad == endRotationRad &&
          other.endAlpha == endAlpha &&
          other.durationSec == durationSec &&
          other.easing == easing &&
          other.fromCurrent == fromCurrent &&
          other.clearOnFinish == clearOnFinish;

  @override
  int get hashCode => Object.hash(
    animationId,
    endDx,
    endDy,
    endScaleX,
    endScaleY,
    endRotationRad,
    endAlpha,
    durationSec,
    easing,
    fromCurrent,
    clearOnFinish,
  );

  @override
  String toString() =>
      'CellTween(aid=$animationId, end=($endDx,$endDy), '
      'scale=($endScaleX,$endScaleY), rot=$endRotationRad, '
      'alpha=$endAlpha, dur=$durationSec, ease=${easing.wireName}, '
      'fromCurrent=$fromCurrent, clearOnFinish=$clearOnFinish)';
}

/// Visual-only per-cell spatial transform with optional 120 Hz host [CellTween].
///
/// Transforms are rendered clipped to the terminal pane viewport while logical
/// grid coordinates remain unchanged for selection and pointer hit-testing.
final class CellTransform {
  /// Minimum allowed horizontal or vertical scale factor.
  static const double minScale = 0.0;

  /// Maximum allowed horizontal or vertical scale factor.
  static const double maxScale = 4.0;

  /// Minimum signed 8-bit z-layer (`-128`).
  static const int minZLayer = -128;

  /// Maximum signed 8-bit z-layer (`127`).
  static const int maxZLayer = 127;

  /// Identity transform representing an untransformed grid cell.
  static const CellTransform identity = CellTransform();

  /// Fractional horizontal cell offset.
  final double dx;

  /// Fractional vertical cell offset.
  final double dy;

  /// Horizontal scale factor clamped to `[0.0, 4.0]`.
  final double scaleX;

  /// Vertical scale factor clamped to `[0.0, 4.0]`.
  final double scaleY;

  /// Rotation in radians around the cell center.
  final double rotationRad;

  /// Glyph opacity clamped to `[0.0, 1.0]`.
  final double alpha;

  /// Stacking layer (`0` = base grid, `> 0` floats above static UI).
  final int zLayer;

  /// Optional finite host tween interpolating from this pose to a target pose.
  final CellTween? tween;

  /// Creates a per-cell visual transform.
  const CellTransform({
    this.dx = 0.0,
    this.dy = 0.0,
    this.scaleX = 1.0,
    this.scaleY = 1.0,
    this.rotationRad = 0.0,
    this.alpha = 1.0,
    this.zLayer = 0,
    this.tween,
  });

  /// Whether this transform has no visual offset, scale, rotation, opacity, z-layer, or tween.
  bool get isIdentity =>
      dx == 0.0 &&
      dy == 0.0 &&
      scaleX == 1.0 &&
      scaleY == 1.0 &&
      rotationRad == 0.0 &&
      alpha == 1.0 &&
      zLayer == 0 &&
      tween == null;

  /// Returns a finite, bounds-clamped copy of this transform.
  CellTransform sanitized() => CellTransform(
    dx: _finiteOr(dx, 0.0),
    dy: _finiteOr(dy, 0.0),
    scaleX: _clampFinite(scaleX, minScale, maxScale, 1.0),
    scaleY: _clampFinite(scaleY, minScale, maxScale, 1.0),
    rotationRad: _finiteOr(rotationRad, 0.0),
    alpha: _clampFinite(alpha, 0.0, 1.0, 1.0),
    zLayer: zLayer.clamp(minZLayer, maxZLayer),
    tween: tween?.sanitized(),
  );

  /// Returns a copy with selected fields replaced.
  CellTransform copyWith({
    double? dx,
    double? dy,
    double? scaleX,
    double? scaleY,
    double? rotationRad,
    double? alpha,
    int? zLayer,
    CellTween? tween,
    bool clearTween = false,
  }) => CellTransform(
    dx: dx ?? this.dx,
    dy: dy ?? this.dy,
    scaleX: scaleX ?? this.scaleX,
    scaleY: scaleY ?? this.scaleY,
    rotationRad: rotationRad ?? this.rotationRad,
    alpha: alpha ?? this.alpha,
    zLayer: zLayer ?? this.zLayer,
    tween: clearTween ? null : (tween ?? this.tween),
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CellTransform &&
          other.dx == dx &&
          other.dy == dy &&
          other.scaleX == scaleX &&
          other.scaleY == scaleY &&
          other.rotationRad == rotationRad &&
          other.alpha == alpha &&
          other.zLayer == zLayer &&
          other.tween == tween;

  @override
  int get hashCode =>
      Object.hash(dx, dy, scaleX, scaleY, rotationRad, alpha, zLayer, tween);

  @override
  String toString() =>
      'CellTransform(dx=$dx, dy=$dy, scale=($scaleX,$scaleY), '
      'rot=$rotationRad, alpha=$alpha, z=$zLayer, tween=$tween)';
}

/// A cell-grid coordinate paired with an optional [CellTransform] (`null` = remove).
typedef CellTransformEntry = ({int col, int row, CellTransform? transform});

/// Little-endian fixed `64`-byte binary packer/unpacker for `a=xforms` and `0x1C` batches.
abstract final class CellTransformCodec {
  /// Exact byte stride of one packed transform struct.
  static const int strideBytes = 64;

  /// Maximum number of live transforms supported per pane.
  static const int maxLiveTransforms = 4096;

  /// Flag bit `0`: `CellTween` fields are present.
  static const int flagHasTween = 0x01;

  /// Flag bit `1`: clear transform on tween completion.
  static const int flagClearOnFinish = 0x02;

  /// Flag bits `2..4`: `CellTweenEasing.code` (`0..3`).
  static const int flagEasingShift = 2;

  /// Mask covering bits `2..4` for easing.
  static const int flagEasingMask = 0x1C;

  /// Flag bit `5`: interpolate from current live pose (`fromCurrent`).
  static const int flagFromCurrent = 0x20;

  /// Flag bit `6`: explicitly remove transform at `(col, row)`.
  static const int flagRemove = 0x40;

  /// Valid bitmask of all supported flags in the `u8 flags` field.
  static const int validFlagsMask =
      flagHasTween |
      flagClearOnFinish |
      flagEasingMask |
      flagFromCurrent |
      flagRemove;

  /// Packs [entries] into a contiguous little-endian `64 * entries.length` byte buffer.
  static Uint8List packBatch(List<CellTransformEntry> entries) {
    if (entries.length > maxLiveTransforms) {
      throw RangeError.range(
        entries.length,
        0,
        maxLiveTransforms,
        'entries.length',
      );
    }
    final bytes = Uint8List(entries.length * strideBytes);
    final view = ByteData.sublistView(bytes);
    for (var i = 0; i < entries.length; i++) {
      _packEntry(view, i * strideBytes, entries[i]);
    }
    return bytes;
  }

  static void _packEntry(ByteData view, int offset, CellTransformEntry entry) {
    final col = entry.col.clamp(0, 0xFFFF);
    final row = entry.row.clamp(0, 0xFFFF);
    view
      ..setUint16(offset + 0, col, Endian.little)
      ..setUint16(offset + 2, row, Endian.little);
    final raw = entry.transform;
    if (raw == null) {
      view
        ..setUint8(offset + 4, flagRemove)
        ..setInt8(offset + 5, 0)
        ..setUint16(offset + 6, 0, Endian.little);
      return;
    }
    final t = raw.sanitized();
    final tw = t.tween;
    final flags = tw == null
        ? 0
        : flagHasTween |
              (tw.clearOnFinish ? flagClearOnFinish : 0) |
              ((tw.easing.code & 0x07) << flagEasingShift) |
              (tw.fromCurrent ? flagFromCurrent : 0);
    view
      ..setUint8(offset + 4, flags)
      ..setInt8(offset + 5, t.zLayer)
      ..setUint16(offset + 6, tw?.animationId ?? 0, Endian.little)
      ..setFloat32(offset + 8, t.dx, Endian.little)
      ..setFloat32(offset + 12, t.dy, Endian.little)
      ..setFloat32(offset + 16, t.scaleX, Endian.little)
      ..setFloat32(offset + 20, t.scaleY, Endian.little)
      ..setFloat32(offset + 24, t.rotationRad, Endian.little)
      ..setFloat32(offset + 28, t.alpha, Endian.little);
    if (tw != null) {
      view
        ..setFloat32(offset + 32, tw.endDx, Endian.little)
        ..setFloat32(offset + 36, tw.endDy, Endian.little)
        ..setFloat32(offset + 40, tw.endScaleX, Endian.little)
        ..setFloat32(offset + 44, tw.endScaleY, Endian.little)
        ..setFloat32(offset + 48, tw.endRotationRad, Endian.little)
        ..setFloat32(offset + 52, tw.endAlpha, Endian.little)
        ..setFloat32(offset + 56, tw.durationSec, Endian.little);
    }
    view.setUint32(offset + 60, 0, Endian.little);
  }

  /// Unpacks a little-endian `64`-byte-strided [bytes] slice into validated entries.
  ///
  /// Throws [FormatException] when length is not a multiple of `64`, exceeds
  /// [maxLiveTransforms], contains unknown flag bits, non-zero reserved bytes,
  /// invalid easing values, or any `NaN`/non-finite floating-point field.
  static List<CellTransformEntry> unpackBatch(
    Uint8List bytes, {
    int maxEntries = maxLiveTransforms,
  }) {
    if (bytes.length % strideBytes != 0) {
      throw FormatException(
        'CellTransform batch byte length ${bytes.length} is not a multiple of $strideBytes',
      );
    }
    final count = bytes.length ~/ strideBytes;
    if (count > maxEntries || count > maxLiveTransforms) {
      throw FormatException(
        'CellTransform batch count $count exceeds cap $maxEntries',
      );
    }
    final view = ByteData.sublistView(bytes);
    return <CellTransformEntry>[
      for (var i = 0; i < count; i++) _unpackEntry(view, i * strideBytes),
    ];
  }

  static CellTransformEntry _unpackEntry(ByteData view, int offset) {
    final col = view.getUint16(offset + 0, Endian.little);
    final row = view.getUint16(offset + 2, Endian.little);
    final flags = view.getUint8(offset + 4);
    final zLayer = view.getInt8(offset + 5);
    final animId = view.getUint16(offset + 6, Endian.little);
    final reserved = view.getUint32(offset + 60, Endian.little);
    if ((flags & ~validFlagsMask) != 0 || reserved != 0) {
      throw FormatException(
        'Invalid CellTransform flags=0x${flags.toRadixString(16)} reserved=$reserved',
      );
    }
    if ((flags & flagRemove) != 0) {
      return (col: col, row: row, transform: null);
    }
    final dx = _readFiniteFloat32(view, offset + 8, 'dx');
    final dy = _readFiniteFloat32(view, offset + 12, 'dy');
    final sx = _readFiniteFloat32(
      view,
      offset + 16,
      'scaleX',
    ).clamp(CellTransform.minScale, CellTransform.maxScale).toDouble();
    final sy = _readFiniteFloat32(
      view,
      offset + 20,
      'scaleY',
    ).clamp(CellTransform.minScale, CellTransform.maxScale).toDouble();
    final rot = _readFiniteFloat32(view, offset + 24, 'rotationRad');
    final alpha = _readFiniteFloat32(
      view,
      offset + 28,
      'alpha',
    ).clamp(0.0, 1.0).toDouble();
    final tween = (flags & flagHasTween) != 0
        ? _unpackTween(view, offset, flags, animId)
        : null;
    final transform = CellTransform(
      dx: dx,
      dy: dy,
      scaleX: sx,
      scaleY: sy,
      rotationRad: rot,
      alpha: alpha,
      zLayer: zLayer,
      tween: tween,
    );
    return (
      col: col,
      row: row,
      transform: transform.isIdentity ? null : transform,
    );
  }

  static CellTween _unpackTween(
    ByteData view,
    int offset,
    int flags,
    int animId,
  ) {
    final easingCode = (flags & flagEasingMask) >> flagEasingShift;
    final easing = CellTweenEasing.fromCode(easingCode);
    if (easing == null) {
      throw FormatException('Invalid CellTweenEasing code: $easingCode');
    }
    final endDx = _readFiniteFloat32(view, offset + 32, 'endDx');
    final endDy = _readFiniteFloat32(view, offset + 36, 'endDy');
    final endSx = _readFiniteFloat32(
      view,
      offset + 40,
      'endScaleX',
    ).clamp(CellTransform.minScale, CellTransform.maxScale).toDouble();
    final endSy = _readFiniteFloat32(
      view,
      offset + 44,
      'endScaleY',
    ).clamp(CellTransform.minScale, CellTransform.maxScale).toDouble();
    final endRot = _readFiniteFloat32(view, offset + 48, 'endRotationRad');
    final endAlpha = _readFiniteFloat32(
      view,
      offset + 52,
      'endAlpha',
    ).clamp(0.0, 1.0).toDouble();
    final dur = _readFiniteFloat32(
      view,
      offset + 56,
      'durationSec',
    ).clamp(CellTween.minDurationSec, CellTween.maxDurationSec).toDouble();
    return CellTween(
      animationId: animId,
      endDx: endDx,
      endDy: endDy,
      endScaleX: endSx,
      endScaleY: endSy,
      endRotationRad: endRot,
      endAlpha: endAlpha,
      durationSec: dur,
      easing: easing,
      fromCurrent: (flags & flagFromCurrent) != 0,
      clearOnFinish: (flags & flagClearOnFinish) != 0,
    );
  }

  static double _readFiniteFloat32(ByteData view, int offset, String name) {
    final v = view.getFloat32(offset, Endian.little);
    if (!v.isFinite) {
      throw FormatException('Non-finite CellTransform.$name: $v');
    }
    return v;
  }
}

/// Lazy sparse table of active [CellTransform] entries attached to a `Buffer`.
///
/// Allocates zero memory until the first non-identity transform is inserted and
/// enforces the hard cap of [maxEntries] (`4,096`) live transforms per buffer.
final class CellTransformTable {
  /// Hard cap on simultaneous live cell transforms per buffer/pane.
  static const int maxEntries = CellTransformCodec.maxLiveTransforms;

  final Map<int, CellTransform> _entries = <int, CellTransform>{};

  /// Whether no cell transforms are currently active.
  bool get isEmpty => _entries.isEmpty;

  /// Whether at least one cell transform is active.
  bool get isNotEmpty => _entries.isNotEmpty;

  /// Number of active transformed cells.
  int get length => _entries.length;

  /// Read-only view of `(cellIndex, transform)` entries.
  Iterable<MapEntry<int, CellTransform>> get entries => _entries.entries;

  /// Returns the transform at flat [cellIndex], or `null` if untransformed.
  CellTransform? operator [](int cellIndex) => _entries[cellIndex];

  /// Sets [transform] at flat [cellIndex], sanitizing non-finite values and
  /// removing the entry if it reduces to [CellTransform.identity].
  void set(int cellIndex, CellTransform transform) {
    if (cellIndex < 0) return;
    final clean = transform.sanitized();
    if (clean.isIdentity) {
      _entries.remove(cellIndex);
      return;
    }
    if (!_entries.containsKey(cellIndex) && _entries.length >= maxEntries) {
      return;
    }
    _entries[cellIndex] = clean;
  }

  /// Removes any transform at flat [cellIndex].
  void remove(int cellIndex) {
    _entries.remove(cellIndex);
  }

  /// Shifts all entries vertically by [deltaRows] within a `[cols x rows]` grid,
  /// evicting any cells that fall out of bounds.
  ///
  /// Pass a negative [deltaRows] when content scrolls upward (e.g. `-1` on a
  /// newline at the bottom margin) and a positive value when scrolling downward.
  void shiftRows(int deltaRows, int cols, int rows) {
    if (_entries.isEmpty || deltaRows == 0) return;
    if (cols <= 0 || rows <= 0) {
      _entries.clear();
      return;
    }
    final shifted = <int, CellTransform>{};
    for (final entry in _entries.entries) {
      final col = entry.key % cols;
      final newRow = (entry.key ~/ cols) + deltaRows;
      if (col >= 0 && col < cols && newRow >= 0 && newRow < rows) {
        shifted[newRow * cols + col] = entry.value;
      }
    }
    _entries
      ..clear()
      ..addAll(shifted);
  }

  /// Remaps entries from `[oldCols x oldRows]` to `[newCols x newRows]`,
  /// evicting cells outside the new grid bounds.
  void resize(int oldCols, int oldRows, int newCols, int newRows) {
    if (_entries.isEmpty) return;
    if (oldCols <= 0 || oldRows <= 0 || newCols <= 0 || newRows <= 0) {
      _entries.clear();
      return;
    }
    if (oldCols == newCols && oldRows == newRows) return;
    final remapped = <int, CellTransform>{};
    for (final entry in _entries.entries) {
      final col = entry.key % oldCols;
      final row = entry.key ~/ oldCols;
      if (col < newCols && row < newRows) {
        remapped[row * newCols + col] = entry.value;
      }
    }
    _entries
      ..clear()
      ..addAll(remapped);
  }

  /// Removes all entries from this table.
  void clear() {
    _entries.clear();
  }

  /// Creates an independent shallow copy of this table.
  CellTransformTable copy() {
    final clone = CellTransformTable();
    clone._entries.addAll(_entries);
    return clone;
  }
}

double _finiteOr(double value, double fallback) =>
    value.isFinite ? value : fallback;

double _clampFinite(
  double value,
  double minVal,
  double maxVal,
  double fallback,
) {
  if (!value.isFinite) return fallback;
  return value.clamp(minVal, maxVal).toDouble();
}
