import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart'
    show Canvas, Color, Offset, Paint, PaintingStyle, Rect, Size;

/// Drawing mode available in the feedback screenshot editor.
enum ScreenshotAnnotationTool {
  /// Solid opaque black box to redact tokens, paths, hostnames, or secrets.
  redact(label: 'Black Out'),

  /// Translucent yellow highlight with amber border to call out an issue.
  highlight(label: 'Highlight');

  /// Human-readable label shown in the editor toolbar.
  final String label;

  const ScreenshotAnnotationTool({required this.label});
}

/// Immutable rectangular annotation stored in normalized `[0.0, 1.0]` image
/// coordinates so edits stay aligned across window resizes and full-res export.
final class ScreenshotAnnotation {
  /// Whether this region blacks out or highlights pixels.
  final ScreenshotAnnotationTool tool;

  /// Normalized bounding rectangle within `[0.0, 1.0] x [0.0, 1.0]`.
  final Rect normalizedRect;

  /// Creates a [ScreenshotAnnotation] with pre-normalized [normalizedRect].
  const ScreenshotAnnotation({
    required this.tool,
    required this.normalizedRect,
  });

  /// Creates an annotation from two arbitrary normalized points, normalizing
  /// direction and clamping into `[0.0, 1.0]`.
  factory ScreenshotAnnotation.fromNormalizedPoints({
    required ScreenshotAnnotationTool tool,
    required Offset start,
    required Offset end,
  }) {
    final left = (start.dx < end.dx ? start.dx : end.dx).clamp(0.0, 1.0);
    final right = (start.dx > end.dx ? start.dx : end.dx).clamp(0.0, 1.0);
    final top = (start.dy < end.dy ? start.dy : end.dy).clamp(0.0, 1.0);
    final bottom = (start.dy > end.dy ? start.dy : end.dy).clamp(0.0, 1.0);
    return ScreenshotAnnotation(
      tool: tool,
      normalizedRect: Rect.fromLTRB(left, top, right, bottom),
    );
  }

  /// Whether this annotation has zero area.
  bool get isEmpty => normalizedRect.width <= 0 || normalizedRect.height <= 0;

  /// Projects [normalizedRect] into pixel/logical coordinates inside [bounds].
  Rect toCanvasRect(Rect bounds) => Rect.fromLTRB(
    bounds.left + normalizedRect.left * bounds.width,
    bounds.top + normalizedRect.top * bounds.height,
    bounds.left + normalizedRect.right * bounds.width,
    bounds.top + normalizedRect.bottom * bounds.height,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScreenshotAnnotation &&
          tool == other.tool &&
          normalizedRect == other.normalizedRect;

  @override
  int get hashCode => Object.hash(tool, normalizedRect);
}

/// Computes the centered `BoxFit.contain` destination rect for [imageSize]
/// inside [viewportSize].
Rect computeFittedImageRect(Size viewportSize, Size imageSize) {
  if (viewportSize.width <= 0 ||
      viewportSize.height <= 0 ||
      imageSize.width <= 0 ||
      imageSize.height <= 0) {
    return Rect.zero;
  }
  final scaleX = viewportSize.width / imageSize.width;
  final scaleY = viewportSize.height / imageSize.height;
  final scale = scaleX < scaleY ? scaleX : scaleY;
  final width = imageSize.width * scale;
  final height = imageSize.height * scale;
  final left = (viewportSize.width - width) / 2.0;
  final top = (viewportSize.height - height) / 2.0;
  return Rect.fromLTWH(left, top, width, height);
}

/// Converts a drag-start [localPosition] into normalized `[0.0, 1.0]` image
/// coordinates, or `null` if outside [imageBounds] beyond [hitSlop].
Offset? pointerToNormalizedImagePoint(
  Offset localPosition,
  Rect imageBounds, {
  double hitSlop = 8.0,
}) {
  if (imageBounds.width <= 0 || imageBounds.height <= 0) return null;
  if (!imageBounds.inflate(hitSlop).contains(localPosition)) return null;
  return clampPointerToNormalizedImagePoint(localPosition, imageBounds);
}

/// Clamps any [localPosition] into normalized `[0.0, 1.0]` coordinates relative
/// to [imageBounds].
Offset clampPointerToNormalizedImagePoint(
  Offset localPosition,
  Rect imageBounds,
) {
  if (imageBounds.width <= 0 || imageBounds.height <= 0) return Offset.zero;
  final nx = ((localPosition.dx - imageBounds.left) / imageBounds.width).clamp(
    0.0,
    1.0,
  );
  final ny = ((localPosition.dy - imageBounds.top) / imageBounds.height).clamp(
    0.0,
    1.0,
  );
  return Offset(nx, ny);
}

/// Paints [annotations] (plus optional in-progress [activeDraft]) onto [canvas]
/// within [imageBounds].
///
/// When [showRedactOutline] is true (live editor preview), blackout boxes draw
/// a subtle border so redactions remain visible against dark terminal themes.
/// Exported PNGs pass `showRedactOutline: false` for pure opaque `#000000`.
void paintScreenshotAnnotations(
  Canvas canvas,
  Rect imageBounds,
  List<ScreenshotAnnotation> annotations, {
  ScreenshotAnnotation? activeDraft,
  bool showRedactOutline = false,
}) {
  final items = [...annotations, ?activeDraft];
  if (items.isEmpty || imageBounds.isEmpty) return;

  final redactFill = Paint()
    ..color = const Color(0xFF000000)
    ..style = PaintingStyle.fill
    ..isAntiAlias = false;
  final redactOutline = Paint()
    ..color = const Color(0xAAFF5252)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.25;
  final highlightFill = Paint()
    ..color = const Color(0x4DFFE600)
    ..style = PaintingStyle.fill;
  final highlightStroke = Paint()
    ..color = const Color(0xFFFFC400)
    ..style = PaintingStyle.stroke
    ..strokeWidth = (imageBounds.shortestSide * 0.004).clamp(2.0, 5.0);

  for (final annotation in items) {
    if (annotation.isEmpty) continue;
    final rect = annotation.toCanvasRect(imageBounds);
    switch (annotation.tool) {
      case ScreenshotAnnotationTool.redact:
        // Snap outward to whole pixels without anti-aliasing so zero text bleeds
        // at redaction boundaries.
        final snapped = Rect.fromLTRB(
          rect.left.floorToDouble().clamp(imageBounds.left, imageBounds.right),
          rect.top.floorToDouble().clamp(imageBounds.top, imageBounds.bottom),
          rect.right.ceilToDouble().clamp(imageBounds.left, imageBounds.right),
          rect.bottom.ceilToDouble().clamp(imageBounds.top, imageBounds.bottom),
        );
        canvas.drawRect(snapped, redactFill);
        if (showRedactOutline) {
          canvas.drawRect(snapped, redactOutline);
        }
      case ScreenshotAnnotationTool.highlight:
        canvas.drawRect(rect, highlightFill);
        canvas.drawRect(rect, highlightStroke);
    }
  }
}

/// Composites [annotations] onto [source] at full native resolution and encodes
/// the result as PNG bytes.
///
/// Does not dispose [source]; callers retain ownership of [source].
Future<Uint8List?> renderAnnotatedScreenshotPng(
  ui.Image source,
  List<ScreenshotAnnotation> annotations,
) async {
  if (annotations.isEmpty) {
    final byteData = await source.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }

  final size = Size(source.width.toDouble(), source.height.toDouble());
  final bounds = Offset.zero & size;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, bounds);
  canvas.drawImage(source, Offset.zero, Paint());
  paintScreenshotAnnotations(
    canvas,
    bounds,
    annotations,
    showRedactOutline: false,
  );
  final picture = recorder.endRecording();
  ui.Image? composited;
  try {
    composited = await picture.toImage(source.width, source.height);
    final byteData = await composited.toByteData(
      format: ui.ImageByteFormat.png,
    );
    return byteData?.buffer.asUint8List();
  } finally {
    composited?.dispose();
    picture.dispose();
  }
}

/// Formats a concise footer summary of the current [annotations].
String formatAnnotationSummary(List<ScreenshotAnnotation> annotations) {
  var blackouts = 0;
  var highlights = 0;
  for (final item in annotations) {
    switch (item.tool) {
      case ScreenshotAnnotationTool.redact:
        blackouts++;
      case ScreenshotAnnotationTool.highlight:
        highlights++;
    }
  }
  final parts = [
    if (blackouts > 0)
      '$blackouts ${blackouts == 1 ? 'blackout' : 'blackouts'}',
    if (highlights > 0)
      '$highlights ${highlights == 1 ? 'highlight' : 'highlights'}',
  ];
  return parts.isEmpty ? 'No edits — raw pane capture' : parts.join(' · ');
}
