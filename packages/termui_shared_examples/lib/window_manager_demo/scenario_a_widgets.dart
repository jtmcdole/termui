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
  Element createElement() => _SystemDiagnosticsElement(this);
}

class _SystemDiagnosticsElement extends Element {
  _SystemDiagnosticsElement(super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return Size(constraints.maxWidth, constraints.maxHeight);
  }

  @override
  void paint(Buffer buffer, Offset offset) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;
    final target = widget as SystemDiagnosticsWidget;
    final tickCount = target.tickCount;

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
    );

    // Render title block
    final totalCpu =
        19.5 + sin(tickCount * 0.1) * 3 + cos(tickCount * 0.05) * 0.5;
    final progressBarWidth = (w - 18).clamp(5, 40);
    final filledWidth = (progressBarWidth * (totalCpu / 100)).round().clamp(
      0,
      progressBarWidth,
    );
    final progressBar =
        '[${'█' * filledWidth}${'░' * (progressBarWidth - filledWidth)}]';

    final col = Column([
      SizedBox(
        height: 1,
        child: Text(
          ' SYSTEM MONITOR - CPU: ${totalCpu.toStringAsFixed(1)}%',
          style: const Style(
            foreground: Color(0, 255, 0),
            modifiers: Modifier.bold,
          ),
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

    final colEl = col.createElement()..mount(null);
    colEl.layout(BoxConstraints.tight(Size(w, h)));
    colEl.paint(buffer, offset);
    colEl.unmount();
  }
}

/// A widget displaying a scanning radar sweep using sub-pixel Braille canvas.
class RadarWidget extends Widget {
  /// Current animation frame of the radar sweep.
  int frame = 0;

  /// Internal sub-pixel Braille canvas cache.
  Canvas? canvas;

  /// Render mode.
  CanvasRenderMode renderMode;

  /// Anti-aliasing.
  bool antiAliased;

  /// Widget Style.
  final Style style;

  /// Construct the Radar simulation widget.
  RadarWidget({
    this.renderMode = CanvasRenderMode.braille,
    this.antiAliased = false,
    this.style = Style.empty,
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
    final radar = widget as RadarWidget;

    if (radar.canvas == null ||
        radar.canvas!.width != w ||
        radar.canvas!.height != h) {
      radar.canvas = Canvas(
        w,
        h,
        renderMode: radar.renderMode,
        style: radar.style,
      );
    } else {
      radar.canvas!.clear();
    }

    radar.canvas!.renderMode = radar.renderMode;

    final cx = w;
    final cy = h * 2;
    final r = (min(w, h * 2) - 3).clamp(8, 25);

    // Draw static radar face cross-hairs and concentric circles
    radar.canvas!.drawCircle(
      cx,
      cy,
      r,
      antiAliased: false,
      cellStyle: const Style(foreground: CharmColors.spinach),
    );
    radar.canvas!.drawCircle(
      cx,
      cy,
      (r * 0.66).round(),
      antiAliased: false,
      cellStyle: const Style(foreground: CharmColors.spinach),
    );
    radar.canvas!.drawCircle(
      cx,
      cy,
      (r * 0.33).round(),
      antiAliased: false,
      cellStyle: const Style(foreground: CharmColors.spinach),
    );

    // Draw static axes
    radar.canvas!.drawLine(
      cx - r,
      cy,
      cx + r,
      cy,
      cellStyle: const Style(foreground: CharmColors.spinach),
    );
    radar.canvas!.drawLine(
      cx,
      cy - r,
      cx,
      cy + r,
      cellStyle: const Style(foreground: CharmColors.spinach),
    );

    // Draw scanning sweep line
    final sweepAngle = radar.frame * 0.05;
    final sx = (cx + r * cos(sweepAngle)).round();
    final sy = (cy + r * sin(sweepAngle)).round();
    radar.canvas!.drawLine(
      cx,
      cy,
      sx,
      sy,
      cellStyle: const Style(foreground: CharmColors.lichen),
    );

    // Draw sweeping radar cone gradient
    final fadeSteps = 16;
    for (var i = 1; i <= fadeSteps; i++) {
      final angle = sweepAngle - (i * 0.04);
      final ex = (cx + r * cos(angle)).round();
      final ey = (cy + r * sin(angle)).round();
      final greenFadeVal = (120 - (i * 7)).clamp(30, 255);
      radar.canvas!.drawLine(
        cx,
        cy,
        ex,
        ey,
        cellStyle: Style(foreground: Color(0, greenFadeVal, 0)),
      );
    }

    // Dynamic blips
    void drawBlip(int distance, double targetAngle) {
      final difference = (sweepAngle - targetAngle) % (2 * pi);
      if (difference < 1.5) {
        final bx = (cx + distance * cos(targetAngle)).round();
        final by = (cy + distance * sin(targetAngle)).round();
        final brightness = ((1.5 - difference) / 1.5 * 255).round().clamp(
          0,
          255,
        );
        radar.canvas!.fillCircle(
          bx,
          by,
          1,
          antiAliased: false,
          cellStyle: Style(
            foreground: Color(brightness, brightness, 0),
            modifiers: Modifier.bold,
          ),
        );
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

    final canvasEl = radar.canvas!.createElement()..mount(null);
    canvasEl.layout(BoxConstraints.tight(Size(w, h)));
    canvasEl.paint(buffer, offset);
    canvasEl.unmount();
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

  /// Internal canvas cache.
  Canvas? canvas;

  /// Widget style.
  final Style style;

  /// Construct a spinning 3D cube widget.
  SpinningCubeWidget({this.style = Style.empty});

  /// Advance the rotation angles for the next frame simulation.
  void update() {
    rotX += 0.03;
    rotY += 0.04;
    rotZ += 0.02;
  }

  @override
  Element createElement() => _SpinningCubeElement(this);
}

class _SpinningCubeElement extends Element {
  _SpinningCubeElement(super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return Size(constraints.maxWidth, constraints.maxHeight);
  }

  @override
  void paint(Buffer buffer, Offset offset) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;
    final cube = widget as SpinningCubeWidget;

    if (cube.canvas == null ||
        cube.canvas!.width != w ||
        cube.canvas!.height != h) {
      cube.canvas = Canvas(
        w,
        h,
        renderMode: CanvasRenderMode.quadrants,
        style: cube.style,
      );
    } else {
      cube.canvas!.clear();
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
      final y1 = y * cos(cube.rotX) - z * sin(cube.rotX);
      final z1 = y * sin(cube.rotX) + z * cos(cube.rotX);

      // Rotate Y
      final x2 = x * cos(cube.rotY) + z1 * sin(cube.rotY);

      // Rotate Z
      final x3 = x2 * cos(cube.rotZ) - y1 * sin(cube.rotZ);
      final y3 = x2 * sin(cube.rotZ) + y1 * cos(cube.rotZ);

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
      cube.canvas!.drawLine(p1.x, p1.y, p2.x, p2.y, cellStyle: edgeStyle);
    }

    final canvasEl = cube.canvas!.createElement()..mount(null);
    canvasEl.layout(BoxConstraints.tight(Size(w, h)));
    canvasEl.paint(buffer, offset);
    canvasEl.unmount();
  }
}
