import 'dart:typed_data';

import 'package:termui/termui.dart';

/// A wrapper widget that attaches a scoped [ShaderRegion] to its child's
/// painted bounding rectangle.
///
/// Parallel to [EffectWidget], this widget lays out and paints [child] first,
/// then registers a [ShaderRegion] onto the target [Buffer] covering the
/// child's painted [Rect]. Only glyphs inside the registered rectangle render
/// into the shader's `uGlyphMask`, while [padding] allows visual bleed (such as
/// flames or halos) over adjacent rows.
class ShaderRegionWidget extends Widget {
  /// Optional stable region identifier (`^[A-Za-z0-9_.-]{1,64}$`).
  ///
  /// When omitted, a deterministic fallback ID is derived from [key] (if a
  /// [ValueKey]) or from [shader] and the painted layout position.
  final String? id;

  /// Shader preset or inline custom GLSL fragment shader to execute over this region.
  final ShaderRef shader;

  /// The child widget whose painted cells form the region's source glyph mask.
  final Widget child;

  /// Cell-grid bleed padding around the painted bounds (clamped to `0..8` cells).
  final CellPadding padding;

  /// Compositing stage relative to text glyphs.
  final ShaderRegionStage stage;

  /// Stacking order among active regions (ascending draw order).
  final int zIndex;

  /// Optional previous-frame feedback override (`prevFrameKey: 'region:<id>'`).
  ///
  /// Defaults to `shader.persist` for [CustomGlslShaderRef] and `false` for presets.
  final bool? persist;

  /// Optional user float uniforms (`p0..p7`), clamped to `[-16.0, 16.0]`.
  final Float32List? params;

  /// Whether this region is registered during paint.
  final bool enabled;

  /// Creates a [ShaderRegionWidget] wrapping [child] with [shader].
  const ShaderRegionWidget({
    super.key,
    this.id,
    required this.shader,
    required this.child,
    this.padding = CellPadding.zero,
    this.stage = ShaderRegionStage.overGlyphs,
    this.zIndex = 0,
    this.persist,
    this.params,
    this.enabled = true,
  });

  @override
  int getIntrinsicHeight(int width) => child.getIntrinsicHeight(width);

  @override
  int getIntrinsicWidth(int height) => child.getIntrinsicWidth(height);

  @override
  Element createElement() => ShaderRegionElement(this);
}

/// Element managing a [ShaderRegionWidget] and registering its [ShaderRegion].
class ShaderRegionElement extends SingleChildElement {
  /// Creates a [ShaderRegionElement] for [widget].
  ShaderRegionElement(ShaderRegionWidget super.widget);

  @override
  Widget? get childWidget => (widget as ShaderRegionWidget).child;

  @override
  Size performLayout(BoxConstraints constraints) {
    if (childElement != null) {
      final childSize = childElement!.layout(constraints);
      childElement!.relativeOffset = Offset.zero;
      return childSize;
    }
    return constraints.constrain(Size.zero);
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    super.performPaint(buffer, offset);

    final regionWidget = widget as ShaderRegionWidget;
    if (!regionWidget.enabled) return;

    final bounds = Rect(offset.dx, offset.dy, size.width, size.height);
    if (bounds.width <= 0 || bounds.height <= 0) return;

    final regionId = _resolveRegionId(regionWidget, offset);
    buffer.addShaderRegion(
      ShaderRegion.fromRef(
        id: regionId,
        shader: regionWidget.shader,
        sourceRects: [bounds],
        padding: regionWidget.padding,
        stage: regionWidget.stage,
        zIndex: regionWidget.zIndex,
        persist: regionWidget.persist,
        params: regionWidget.params,
      ),
    );
  }

  static String _resolveRegionId(
    ShaderRegionWidget regionWidget,
    Offset offset,
  ) {
    final explicit = regionWidget.id;
    if (explicit != null && explicit.isNotEmpty) {
      return sanitizeShaderRegionId(explicit, fallback: 'sr');
    }
    if (regionWidget.key case final ValueKey<Object?> vk) {
      return sanitizeShaderRegionId('sr_${vk.value}', fallback: 'sr');
    }
    final shaderSlug = sanitizeShaderRegionId(
      regionWidget.shader.shaderId,
      fallback: 'shader',
    );
    final zSuffix = regionWidget.zIndex != 0 ? '_z${regionWidget.zIndex}' : '';
    return sanitizeShaderRegionId(
      'sr_${shaderSlug}_${offset.dx}_${offset.dy}$zSuffix',
      fallback: 'sr',
    );
  }
}

/// Sanitizes [raw] into a valid `ESC _ S` region identifier matching
/// `^[A-Za-z0-9_.-]{1,64}$`.
String sanitizeShaderRegionId(String raw, {String fallback = 'region'}) {
  final sb = StringBuffer();
  for (var i = 0; i < raw.length && sb.length < 64; i++) {
    final cu = raw.codeUnitAt(i);
    if (_isValidShaderIdUnit(cu)) {
      sb.writeCharCode(cu);
    } else {
      sb.write('_');
    }
  }
  return sb.isEmpty ? fallback : sb.toString();
}

bool _isValidShaderIdUnit(int cu) =>
    (cu >= 0x30 && cu <= 0x39) || // 0-9
    (cu >= 0x41 && cu <= 0x5A) || // A-Z
    (cu >= 0x61 && cu <= 0x7A) || // a-z
    cu == 0x5F || // _
    cu == 0x2E || // .
    cu == 0x2D; // -
