import 'dart:math';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/widget_toolkit.dart';

/// A widget that displays instructions and mock diagnostic data.
class SystemDiagnosticsWidget extends Widget {
  /// Current diagnostics progress value.
  double progress = 0.0;

  /// Total count of animation/physics updates.
  int tickCount = 0;

  /// Advance the progress bar and update simulation tick.
  void update() {
    tickCount++;
    progress = (progress + 0.01) % 1.0;
  }

  @override
  void render(Buffer buffer, Rect area) {
    final w = area.width;
    final h = area.height;
    if (w <= 0 || h <= 0) return;

    final table = Table(
      headers: ['PID', 'Process', 'CPU%', 'Mem'],
      columnWidths: [6, 12, 6, 6],
      rows: [
        [
          '1042',
          'termui_app',
          '${(12.5 + sin(tickCount * 0.1) * 3).toStringAsFixed(1)}%',
          '24MB',
        ],
        [
          '4829',
          'dart_vm',
          '${(2.4 + cos(tickCount * 0.05) * 0.5).toStringAsFixed(1)}%',
          '128MB',
        ],
        ['8920', 'pulse_audio', '0.5%', '12MB'],
        [
          '9011',
          'xorg_server',
          '${(4.1 + sin(tickCount * 0.08) * 1.2).toStringAsFixed(1)}%',
          '76MB',
        ],
      ],
      selectedRowStyle: const Style(
        foreground: Colors.white,
        background: Colors.orange,
        modifiers: Modifier.bold,
      ),
    );

    final progressCols = (w - 2 > 0) ? ((w - 2) * progress).round() : 0;
    final remainingCols = max(0, w - 2 - progressCols);
    final progressBar = '[${'█' * progressCols}${'░' * remainingCols}]';

    final col = Column([
      SizedBox(
        height: 1,
        child: Text(
          'CPU Task Sync Progress:',
          style: const Style(modifiers: Modifier.bold),
        ),
      ),
      SizedBox(
        height: 1,
        child: Text(
          progressBar,
          style: const Style(foreground: Color(0, 255, 255)),
        ),
      ),
      const SizedBox(height: 1, child: Text('')),
      Expanded(child: table),
    ]);

    col.render(buffer, Rect(0, 0, w, h));
  }
}

/// A widget displaying a scanning radar sweep using sub-pixel Braille canvas.
class RadarWidget extends Widget {
  /// Current animation frame of the radar sweep.
  int frame = 0;

  /// The rendering mode used by the canvas.
  CanvasRenderMode renderMode;

  /// Whether anti-aliasing is enabled.
  bool antiAliased;

  /// The base style applied to the canvas cells.
  final Style style;

  /// Cache canvas to avoid allocations on resize.
  Canvas? canvas;

  /// Creates a new [RadarWidget] with the given parameters.
  RadarWidget({
    this.renderMode = CanvasRenderMode.braille,
    this.antiAliased = false,
    this.style = Style.empty,
  });

  @override
  void render(Buffer buffer, Rect area) {
    final w = area.width;
    final h = area.height;
    if (w <= 0 || h <= 0) return;

    if (canvas == null || canvas!.width != w || canvas!.height != h) {
      canvas = Canvas(w, h, renderMode: renderMode, style: style);
    } else {
      canvas!.clear();
    }

    canvas!.renderMode = renderMode;

    final cx = w;
    final cy = h * 2;
    final r = (min(w, h * 2) - 3).clamp(8, 25);

    // Draw static radar face cross-hairs and concentric circles
    canvas!.drawCircle(
      cx,
      cy,
      r,
      antiAliased: false,
      cellStyle: const Style(foreground: CharmColors.spinach),
    );
    canvas!.drawCircle(
      cx,
      cy,
      (r * 0.67).round(),
      antiAliased: false,
      cellStyle: const Style(foreground: CharmColors.spinach),
    );
    canvas!.drawCircle(
      cx,
      cy,
      (r * 0.33).round(),
      antiAliased: false,
      cellStyle: const Style(foreground: CharmColors.spinach),
    );
    canvas!.drawLine(
      cx - r,
      cy,
      cx + r,
      cy,
      antiAliased: false,
      cellStyle: const Style(foreground: CharmColors.spinach),
    );
    canvas!.drawLine(
      cx,
      cy - r,
      cx,
      cy + r,
      antiAliased: false,
      cellStyle: const Style(foreground: CharmColors.spinach),
    );

    final sweepAngle = (frame * 0.03) % (2 * pi);
    final rx = cx + (r * cos(sweepAngle)).round();
    final ry = cy + (r * sin(sweepAngle)).round();
    canvas!.drawLineColored(
      cx,
      cy,
      rx,
      ry,
      CharmColors.spinach,
      CharmColors.julep,
      antiAliased: antiAliased,
    );

    void drawBlip(int blipDist, double blipAngle) {
      final bx = cx + (blipDist * cos(blipAngle)).round();
      final by = cy + (blipDist * sin(blipAngle)).round();

      var diff = sweepAngle - blipAngle;
      while (diff < 0) {
        diff += 2 * pi;
      }
      while (diff > 2 * pi) {
        diff -= 2 * pi;
      }

      double intensity = 0.0;
      if (diff < pi / 2) {
        intensity = 1.0 - (diff / (pi / 2));
      } else if (diff > 2 * pi - 0.05) {
        intensity = 0.2;
      }

      if (intensity > 0.0) {
        final cxCell = bx ~/ 2;
        final cyCell = by ~/ 4;
        if (cxCell >= 0 && cxCell < w && cyCell >= 0 && cyCell < h) {
          int numDots = intensity > 0.75
              ? 8
              : (intensity > 0.5 ? 6 : (intensity > 0.25 ? 4 : 2));
          final blipStyle = Style(
            foreground: intensity > 0.6
                ? CharmColors.mustard
                : CharmColors.paprika,
          );
          for (var i = 0; i < numDots; i++) {
            final dx = i % 2;
            final dy = i ~/ 2;
            canvas!.setPixel(
              cxCell * 2 + dx,
              cyCell * 4 + dy,
              true,
              antiAliased: antiAliased,
              cellStyle: blipStyle,
            );
          }
        }
      }
    }

    final blipDistance1 = r * 0.5;
    final blipAngle1 = 1.05;
    final blipDistance2 = r * 0.8;
    final blipAngle2 = 3.5;
    final blipDistance3 = r * 0.3;
    final blipAngle3 = 5.0;

    drawBlip(blipDistance1.round(), blipAngle1);
    drawBlip(blipDistance2.round(), blipAngle2);
    drawBlip(blipDistance3.round(), blipAngle3);

    canvas!.render(buffer, Rect(0, 0, w, h));
  }
}

/// A widget displaying a spinning 3D wireframe cube using Quadrants mode.
class SpinningCubeWidget extends Widget {
  /// Rotation angle around X axis.
  double rotX = 0.0;

  /// Rotation angle around Y axis.
  double rotY = 0.0;

  /// Rotation angle around Z axis.
  double rotZ = 0.0;

  /// The base style applied to the canvas cells.
  final Style style;

  /// Cache canvas to avoid allocations on resize.
  Canvas? canvas;

  /// Creates a new [SpinningCubeWidget] with the given parameters.
  SpinningCubeWidget({this.style = Style.empty});

  /// Advance the rotation angles for the next frame simulation.
  void update() {
    rotX += 0.03;
    rotY += 0.04;
    rotZ += 0.02;
  }

  @override
  void render(Buffer buffer, Rect area) {
    final w = area.width;
    final h = area.height;
    if (w <= 0 || h <= 0) return;

    if (canvas == null || canvas!.width != w || canvas!.height != h) {
      canvas = Canvas(
        w,
        h,
        renderMode: CanvasRenderMode.quadrants,
        style: style,
      );
    } else {
      canvas!.clear();
    }

    // 8 vertices of a 3D cube
    const vertices = [
      [-1.0, -1.0, -1.0],
      [1.0, -1.0, -1.0],
      [1.0, 1.0, -1.0],
      [-1.0, 1.0, -1.0],
      [-1.0, -1.0, 1.0],
      [1.0, -1.0, 1.0],
      [1.0, 1.0, 1.0],
      [-1.0, 1.0, 1.0],
    ];

    // 12 edges connecting the vertices
    const edges = [
      [0, 1], [1, 2], [2, 3], [3, 0], // back face
      [4, 5], [5, 6], [6, 7], [7, 4], // front face
      [0, 4], [1, 5], [2, 6], [3, 7], // connecting edges
    ];

    final projected = <Point<int>>[];

    final cx = w; // sub-pixel center X (columns * 2)
    final cy = h * 2; // sub-pixel center Y (rows * 4)
    final scale = min(w, h * 2) * 0.65;

    // Rotate and project vertices
    for (final v in vertices) {
      final x = v[0];
      final y = v[1];
      final z = v[2];

      // Rotate X
      final y1 = y * cos(rotX) - z * sin(rotX);
      final z1 = y * sin(rotX) + z * cos(rotX);

      // Rotate Y
      final x2 = x * cos(rotY) + z1 * sin(rotY);

      // Rotate Z
      final x3 = x2 * cos(rotZ) - y1 * sin(rotZ);
      final y3 = x2 * sin(rotZ) + y1 * cos(rotZ);

      // Simple perspective/orthographic projection
      final px = (cx + x3 * scale * 1.6).round(); // aspect ratio adjustment
      final py = (cy + y3 * scale).round();
      projected.add(Point(px, py));
    }

    // Draw edges
    final edgeStyle = const Style(foreground: Color(255, 0, 255));
    for (final edge in edges) {
      final p1 = projected[edge[0]];
      final p2 = projected[edge[1]];
      canvas!.drawLine(p1.x, p1.y, p2.x, p2.y, cellStyle: edgeStyle);
    }

    canvas!.render(buffer, Rect(0, 0, w, h));
  }
}
