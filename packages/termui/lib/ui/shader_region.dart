import 'dart:typed_data';

import 'widgets/core/geometry.dart';

/// Blend stage at which a [ShaderRegion] composites into the terminal frame.
enum ShaderRegionStage {
  /// Draw after background passes and before text glyphs.
  underGlyphs(0, 'under'),

  /// Hide source glyphs via `cellOverrideMask` and draw shader output instead.
  replaceGlyphs(1, 'replace'),

  /// Draw after text glyphs and before full-pane foreground shaders.
  overGlyphs(2, 'over');

  /// Wire discriminant byte (`0..2`).
  final int code;

  /// Canonical short wire name used in `ESC _ S a=region,stage=...`.
  final String wireName;

  const ShaderRegionStage(this.code, this.wireName);

  /// Decodes a wire stage discriminant (`0..2`), returning `null` if invalid.
  static ShaderRegionStage? fromCode(int code) => switch (code) {
    0 => underGlyphs,
    1 => replaceGlyphs,
    2 => overGlyphs,
    _ => null,
  };

  /// Parses an APC wire stage name (`under`, `replace`, `over`, or enum names).
  static ShaderRegionStage? fromWireName(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return switch (raw.trim().toLowerCase()) {
      'under' || 'underglyphs' || 'under_glyphs' => underGlyphs,
      'replace' || 'replaceglyphs' || 'replace_glyphs' => replaceGlyphs,
      'over' || 'overglyphs' || 'over_glyphs' => overGlyphs,
      _ => null,
    };
  }
}

/// Cell-grid bleed padding around a [ShaderRegion]'s source glyph mask.
///
/// Each edge is clamped to `0..8` cells so region shaders (such as rising
/// flames or halos) can bleed cleanly onto adjacent rows without affecting
/// unrelated neighboring text inside `uGlyphMask`.
final class CellPadding {
  /// Maximum bleed padding permitted per edge in terminal cells.
  static const int maxPadding = 8;

  /// Zero padding on all edges.
  static const CellPadding zero = CellPadding();

  /// Top bleed padding in rows.
  final int top;

  /// Right bleed padding in columns.
  final int right;

  /// Bottom bleed padding in rows.
  final int bottom;

  /// Left bleed padding in columns.
  final int left;

  /// Creates cell padding with optional per-edge extents.
  const CellPadding({
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
    this.left = 0,
  });

  /// Creates uniform padding of [value] cells on all four edges.
  const CellPadding.all(int value)
    : top = value,
      right = value,
      bottom = value,
      left = value;

  /// Creates symmetrical vertical and horizontal cell padding.
  const CellPadding.symmetric({int vertical = 0, int horizontal = 0})
    : top = vertical,
      right = horizontal,
      bottom = vertical,
      left = horizontal;

  /// Returns a copy with every edge clamped to `[0, maxPadding]`.
  CellPadding clamped() => CellPadding(
    top: top.clamp(0, maxPadding),
    right: right.clamp(0, maxPadding),
    bottom: bottom.clamp(0, maxPadding),
    left: left.clamp(0, maxPadding),
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CellPadding &&
          other.top == top &&
          other.right == right &&
          other.bottom == bottom &&
          other.left == left;

  @override
  int get hashCode => Object.hash(top, right, bottom, left);

  @override
  String toString() => 'CellPadding($top:$right:$bottom:$left)';
}

/// Reference to either a built-in host shader preset or an inline CLI GLSL shader.
sealed class ShaderRef {
  /// Creates a shader reference.
  const ShaderRef();

  /// References a host built-in preset (e.g. `'fire'`, `'ice_frost'`,
  /// `'neon_pulse'`, `'glitch_tear'`, `'one_ring'`, `'vortex'`,
  /// `'forge_spark'`, `'water_ripple'`).
  const factory ShaderRef.preset(String presetId) = PresetShaderRef;

  /// References an inline CLI-uploaded Ghostty Shadertoy GLSL fragment shader.
  const factory ShaderRef.glsl({
    required String id,
    required String source,
    bool persist,
  }) = CustomGlslShaderRef;

  /// Logical shader identifier (`presetId` or custom GLSL `id`).
  String get shaderId;
}

/// Built-in host shader preset reference.
final class PresetShaderRef extends ShaderRef {
  /// Built-in preset identifier (e.g. `'fire'`, `'ice_frost'`, `'neon_pulse'`,
  /// `'glitch_tear'`, `'one_ring'`, `'vortex'`, `'forge_spark'`,
  /// `'water_ripple'`).
  final String presetId;

  /// Creates a built-in preset shader reference.
  const PresetShaderRef(this.presetId);

  @override
  String get shaderId => presetId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PresetShaderRef && other.presetId == presetId;

  @override
  int get hashCode => presetId.hashCode;

  @override
  String toString() => 'ShaderRef.preset($presetId)';
}

/// Inline CLI-defined Ghostty Shadertoy GLSL shader reference.
final class CustomGlslShaderRef extends ShaderRef {
  /// Logical slot identifier (`<= 64` identifier chars).
  final String id;

  /// Ghostty Shadertoy GLSL source code (`<= 32 KiB` UTF-8).
  final String source;

  /// Whether this shader requests a previous-frame feedback texture (`prevFrameKey`).
  final bool persist;

  /// Creates an inline custom GLSL shader reference.
  const CustomGlslShaderRef({
    required this.id,
    required this.source,
    this.persist = false,
  });

  @override
  String get shaderId => id;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CustomGlslShaderRef &&
          other.id == id &&
          other.source == source &&
          other.persist == persist;

  @override
  int get hashCode => Object.hash(id, source, persist);

  @override
  String toString() =>
      'ShaderRef.glsl(id=$id, len=${source.length}, persist=$persist)';
}

/// Scoped region shader descriptor attached to a `Buffer` or terminal pane.
///
/// Only glyphs located inside [sourceRects] render into the shader's tight
/// `uGlyphMask` texture, while the output draw quad expands by [padding] so
/// visual effects (such as rising flames) bleed cleanly over neighboring rows.
final class ShaderRegion {
  /// Maximum simultaneous active shader regions allowed per pane.
  static const int maxRegionsPerPane = 8;

  /// Fixed count of user float uniforms (`p0..p7` -> `uParams0`, `uParams1`).
  static const int paramCount = 8;

  /// Minimum clamped value for user float parameters `p0..p7`.
  static const double minParamValue = -16.0;

  /// Maximum clamped value for user float parameters `p0..p7`.
  static const double maxParamValue = 16.0;

  /// Stable region identifier (used for diffing and `prevFrameKey: 'region:$id'`).
  final String id;

  /// Built-in preset name (e.g. `'fire'`) or CLI-defined GLSL slot ID.
  final String shaderId;

  /// Optional inline [ShaderRef] attached by declarative widgets for automatic `a=define` upload.
  final ShaderRef? shaderRef;

  /// Cell-grid rectangles whose glyphs render into `uGlyphMask`.
  final List<Rect> sourceRects;

  /// Output quad bleed padding in cells (clamped to `0..8` per edge).
  final CellPadding padding;

  /// Compositing stage relative to text glyphs.
  final ShaderRegionStage stage;

  /// Stacking order among active regions (ascending draw order).
  final int zIndex;

  /// Whether previous-frame feedback is enabled (`prevFrameKey: 'region:$id'`).
  final bool persist;

  /// Eight user uniform floats (`uParams0.xyzw`, `uParams1.xyzw`), clamped to `[-16.0, 16.0]`.
  final Float32List params;

  /// Creates a [ShaderRegion] with sanitized [padding] and length-8 [params].
  ShaderRegion({
    required this.id,
    required this.shaderId,
    this.shaderRef,
    required List<Rect> sourceRects,
    CellPadding padding = CellPadding.zero,
    this.stage = ShaderRegionStage.overGlyphs,
    this.zIndex = 0,
    this.persist = false,
    Float32List? params,
  }) : sourceRects = List<Rect>.unmodifiable(sourceRects),
       padding = padding.clamped(),
       params = sanitizeParams(params);

  /// Creates a [ShaderRegion] from a declarative [ShaderRef].
  factory ShaderRegion.fromRef({
    required String id,
    required ShaderRef shader,
    required List<Rect> sourceRects,
    CellPadding padding = CellPadding.zero,
    ShaderRegionStage stage = ShaderRegionStage.overGlyphs,
    int zIndex = 0,
    bool? persist,
    Float32List? params,
  }) => ShaderRegion(
    id: id,
    shaderId: shader.shaderId,
    shaderRef: shader,
    sourceRects: sourceRects,
    padding: padding,
    stage: stage,
    zIndex: zIndex,
    persist: persist ?? (shader is CustomGlslShaderRef && shader.persist),
    params: params,
  );

  /// Returns a fresh length-8 [Float32List] with finite values clamped to `[-16.0, 16.0]`.
  static Float32List sanitizeParams(List<double>? input) {
    final out = Float32List(paramCount);
    if (input == null) return out;
    final len = input.length < paramCount ? input.length : paramCount;
    for (var i = 0; i < len; i++) {
      final v = input[i];
      out[i] = v.isFinite
          ? v.clamp(minParamValue, maxParamValue).toDouble()
          : 0.0;
    }
    return out;
  }

  /// Translates all [sourceRects] by ([dx], [dy]) and clips them to [clip].
  ///
  /// Returns `null` when no non-empty source rectangle remains inside [clip].
  ShaderRegion? translatedAndClipped(int dx, int dy, Rect clip) {
    final clipped = <Rect>[];
    for (final rect in sourceRects) {
      final next = Rect(
        rect.x + dx,
        rect.y + dy,
        rect.width,
        rect.height,
      ).intersect(clip);
      if (next.width > 0 && next.height > 0) {
        clipped.add(next);
      }
    }
    if (clipped.isEmpty) return null;
    return ShaderRegion(
      id: id,
      shaderId: shaderId,
      shaderRef: shaderRef,
      sourceRects: clipped,
      padding: padding,
      stage: stage,
      zIndex: zIndex,
      persist: persist,
      params: params,
    );
  }

  /// Returns a copy with selected fields replaced.
  ShaderRegion copyWith({
    String? id,
    String? shaderId,
    ShaderRef? shaderRef,
    List<Rect>? sourceRects,
    CellPadding? padding,
    ShaderRegionStage? stage,
    int? zIndex,
    bool? persist,
    Float32List? params,
  }) => ShaderRegion(
    id: id ?? this.id,
    shaderId: shaderId ?? this.shaderId,
    shaderRef: shaderRef ?? this.shaderRef,
    sourceRects: sourceRects ?? this.sourceRects,
    padding: padding ?? this.padding,
    stage: stage ?? this.stage,
    zIndex: zIndex ?? this.zIndex,
    persist: persist ?? this.persist,
    params: params ?? this.params,
  );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ShaderRegion) return false;
    return other.id == id &&
        other.shaderId == shaderId &&
        other.shaderRef == shaderRef &&
        other.padding == padding &&
        other.stage == stage &&
        other.zIndex == zIndex &&
        other.persist == persist &&
        _rectsEqual(other.sourceRects, sourceRects) &&
        _paramsEqual(other.params, params);
  }

  @override
  int get hashCode => Object.hash(
    id,
    shaderId,
    shaderRef,
    padding,
    stage,
    zIndex,
    persist,
    Object.hashAll(sourceRects),
    Object.hashAll(params),
  );

  static bool _rectsEqual(List<Rect> a, List<Rect> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _paramsEqual(Float32List a, Float32List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() =>
      'ShaderRegion(id=$id, shaderId=$shaderId, rects=$sourceRects, '
      'pad=$padding, stage=${stage.wireName}, z=$zIndex, persist=$persist)';
}
