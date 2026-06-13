import 'dart:math';
import 'package:termui/termui.dart';

/// A blip on the radar screen.
class RadarBlip {
  /// Distance from the center (0.0 to 1.0).
  final double distance;

  /// Angle in radians (0 to 2*pi).
  final double angle;

  /// Intensity or color of the blip.
  final Color color;

  /// Creates a new [RadarBlip].
  RadarBlip({
    required this.distance,
    required this.angle,
    this.color = Colors.green,
  });
}

/// A widget that draws a circular radar or sonar screen.
class Radar extends Widget {
  /// The list of blips to display.
  final List<RadarBlip> blips;

  /// The current angle of the scanner arm in radians.
  final double scannerAngle;

  /// The style of the radar grid/circles.
  final Style gridStyle;

  /// Creates a new [Radar] widget.
  Radar({
    this.blips = const [],
    this.scannerAngle = 0.0,
    this.gridStyle = const Style(foreground: Color(0, 100, 0)),
  });

  @override
  Element createElement() => _RadarElement(this);
}

class _RadarElement extends Element {
  _RadarElement(super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return Size(constraints.maxWidth, constraints.maxHeight);
  }

  @override
  void paint(Buffer buffer, Offset offset) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;
    final rWidget = widget as Radar;

    // Use a Canvas to draw the radar
    final canvas = Canvas(w, h);

    // Calculate center in sub-pixel coordinates
    final cx = w; // area.width * 2 / 2
    final cy = h * 2; // area.height * 4 / 2

    final radius = min(cx, cy) - 1;

    if (radius > 0) {
      // Draw outer circle
      canvas.drawCircle(cx, cy, radius, cellStyle: rWidget.gridStyle);

      // Draw inner circles
      canvas.drawCircle(cx, cy, radius ~/ 2, cellStyle: rWidget.gridStyle);
      canvas.drawCircle(cx, cy, radius ~/ 4, cellStyle: rWidget.gridStyle);

      // Draw crosshairs
      canvas.drawLine(
        cx - radius,
        cy,
        cx + radius,
        cy,
        cellStyle: rWidget.gridStyle,
      );
      canvas.drawLine(
        cx,
        cy - radius,
        cx,
        cy + radius,
        cellStyle: rWidget.gridStyle,
      );

      // Draw scanner arm
      final armX = cx + (cos(rWidget.scannerAngle) * radius).round();
      final armY = cy + (sin(rWidget.scannerAngle) * radius).round();
      canvas.drawLineColored(cx, cy, armX, armY, Colors.white, Colors.green);

      // Draw blips
      for (final blip in rWidget.blips) {
        final blipR = blip.distance * radius;
        final blipX = cx + (cos(blip.angle) * blipR).round();
        final blipY = cy + (sin(blip.angle) * blipR).round();

        // Draw a small block or cluster for the blip
        final blipStyle = Style(foreground: blip.color);
        canvas.setPixel(blipX, blipY, true, cellStyle: blipStyle);
        canvas.setPixel(blipX - 1, blipY, true, cellStyle: blipStyle);
        canvas.setPixel(blipX + 1, blipY, true, cellStyle: blipStyle);
        canvas.setPixel(blipX, blipY - 1, true, cellStyle: blipStyle);
        canvas.setPixel(blipX, blipY + 1, true, cellStyle: blipStyle);
      }
    }

    // Render the canvas onto the buffer
    final canvasEl = canvas.createElement()..mount(null);
    canvasEl.layout(BoxConstraints.tight(Size(w, h)));
    canvasEl.paint(buffer, offset);
    canvasEl.unmount();
  }
}
