import 'dart:math';
import 'package:termui/termui.dart';
import 'package:termui/ui/event.dart' as ui;
import 'example_base.dart';
import '../window_manager_demo/scenario_a_widgets.dart';

/// Example demonstrating vector graphics drawing using [Canvas].
class VectorGraphicsExample extends WidgetBookExample {
  /// Whether anti-aliasing is enabled for drawing operations.
  bool antiAliased = false;

  /// The rendering mode used by the canvases.
  CanvasRenderMode renderMode = CanvasRenderMode.braille;

  /// Whether the vector graphics animations are paused.
  bool vectorGraphicsPaused = false;

  /// The current frame count used for rotation animations.
  int rotationFrameCount = 0;

  /// The canvas used to draw the clock face.
  Canvas? clockCanvas;

  /// The widget displaying the radar animation.
  RadarWidget? radarWidget;

  /// The canvas used to draw rotating triangles.
  Canvas? triangleCanvas;

  /// The canvas used to draw rotating squares.
  Canvas? squareCanvas;

  @override
  bool get requiresTick => true;

  @override
  bool tick(Duration duration) {
    if (!vectorGraphicsPaused) {
      rotationFrameCount++;
      return true;
    }
    return false;
  }

  @override
  Widget build({
    required bool focusDemoPane,
    required int width,
    required int height,
  }) {
    final qWidth = width ~/ 2;
    final qHeight = (height - 2) ~/ 2;
    final qWidthOdd = width - qWidth;
    final qHeightOdd = (height - 2) - qHeight;

    if (clockCanvas == null ||
        clockCanvas!.width != qWidth ||
        clockCanvas!.height != qHeight) {
      clockCanvas = Canvas(qWidth, qHeight, renderMode: renderMode);
      radarWidget = RadarWidget(
        renderMode: renderMode,
        antiAliased: antiAliased,
      );
      triangleCanvas = Canvas(qWidth, qHeightOdd, renderMode: renderMode);
      squareCanvas = Canvas(qWidthOdd, qHeightOdd, renderMode: renderMode);

      // Draw static clock face outline and hour marks once on creation/resize
      final rClock = (min(qWidth, qHeight * 2) - 3).clamp(8, 25);
      final cx = qWidth;
      final cy = qHeight * 2;
      clockCanvas!.drawCircle(
        cx,
        cy,
        rClock,
        antiAliased: false,
        cellStyle: const Style(foreground: CharmColors.smoke),
      );
      clockCanvas!.drawCircle(
        cx,
        cy,
        2,
        antiAliased: false,
        cellStyle: const Style(foreground: CharmColors.chili),
      );
      for (var h = 1; h <= 12; h++) {
        final angle = h * (2 * pi / 12) - pi / 2;
        final x0 = cx + (rClock * 0.82 * cos(angle)).round();
        final y0 = cy + (rClock * 0.82 * sin(angle)).round();
        final x1 = cx + (rClock * 0.95 * cos(angle)).round();
        final y1 = cy + (rClock * 0.95 * sin(angle)).round();
        clockCanvas!.drawLine(
          x0,
          y0,
          x1,
          y1,
          antiAliased: false,
          cellStyle: const Style(foreground: CharmColors.mustard),
        );
      }
      clockCanvas!.saveBackground();
    } else {
      clockCanvas!.clear();
      triangleCanvas!.clear();
      squareCanvas!.clear();
    }

    clockCanvas!.renderMode = renderMode;
    triangleCanvas!.renderMode = renderMode;
    squareCanvas!.renderMode = renderMode;

    // Clock (Quadrant 1)
    final q1Height = clockCanvas!.height * 4;
    final q1Width = clockCanvas!.width * 2;
    final q1x = q1Width ~/ 2;
    final q1y = q1Height ~/ 2;
    final rClock1 = (min(clockCanvas!.width, clockCanvas!.height * 2) - 3)
        .clamp(8, 25);

    final now = DateTime.now();
    final secAngle =
        (now.second + now.millisecond / 1000.0) * (2 * pi / 60) - pi / 2;
    final minAngle = (now.minute + now.second / 60.0) * (2 * pi / 60) - pi / 2;
    final hourAngle =
        (now.hour % 12 + now.minute / 60.0) * (2 * pi / 12) - pi / 2;

    // Hour hand
    final hx = q1x + (rClock1 * 0.5 * cos(hourAngle)).round();
    final hy = q1y + (rClock1 * 0.5 * sin(hourAngle)).round();
    clockCanvas!.drawLine(
      q1x,
      q1y,
      hx,
      hy,
      antiAliased: antiAliased,
      cellStyle: const Style(foreground: CharmColors.charple),
    );

    // Minute hand
    final mx = q1x + (rClock1 * 0.72 * cos(minAngle)).round();
    final my = q1y + (rClock1 * 0.72 * sin(minAngle)).round();
    clockCanvas!.drawLine(
      q1x,
      q1y,
      mx,
      my,
      antiAliased: antiAliased,
      cellStyle: const Style(foreground: CharmColors.malibu),
    );

    // Second hand
    final sx = q1x + (rClock1 * 0.88 * cos(secAngle)).round();
    final sy = q1y + (rClock1 * 0.88 * sin(secAngle)).round();
    clockCanvas!.drawLine(
      q1x,
      q1y,
      sx,
      sy,
      antiAliased: antiAliased,
      cellStyle: const Style(foreground: CharmColors.sriracha),
    );

    // Radar (Quadrant 2)
    radarWidget!.frame = rotationFrameCount;
    radarWidget!.renderMode = renderMode;
    radarWidget!.antiAliased = antiAliased;

    // Rotating Shapes (Quadrants 3 & 4)
    final rShape = (min(triangleCanvas!.width, triangleCanvas!.height * 2) - 4)
        .clamp(6, 16);
    final shapeAngle = rotationFrameCount * 0.03;

    // Quadrant 3: Rotating Triangles
    final q3x = triangleCanvas!.width;
    final q3y = triangleCanvas!.height * 2;

    // Left: Outline Triangle
    final t1cx = q3x - rShape - 2;
    final t1cy = q3y;
    final t1angles = [
      shapeAngle,
      shapeAngle + 2 * pi / 3,
      shapeAngle + 4 * pi / 3,
    ];
    final t1px = List.generate(
      3,
      (i) => (t1cx + rShape * cos(t1angles[i])).round(),
    );
    final t1py = List.generate(
      3,
      (i) => (t1cy + rShape * sin(t1angles[i])).round(),
    );
    final colorsTriangle = [Colors.red, Colors.green, Colors.blue];
    for (var i = 0; i < 3; i++) {
      final next = (i + 1) % 3;
      triangleCanvas!.drawLineColored(
        t1px[i],
        t1py[i],
        t1px[next],
        t1py[next],
        colorsTriangle[i],
        colorsTriangle[next],
        antiAliased: antiAliased,
      );
    }

    // Right: Filled Triangle
    final t2cx = q3x + rShape + 2;
    final t2cy = q3y;
    final t2angles = [
      shapeAngle,
      shapeAngle + 2 * pi / 3,
      shapeAngle + 4 * pi / 3,
    ];
    final t2px = List.generate(
      3,
      (i) => (t2cx + rShape * cos(t2angles[i])).round(),
    );
    final t2py = List.generate(
      3,
      (i) => (t2cy + rShape * sin(t2angles[i])).round(),
    );
    triangleCanvas!.fillTriangleColored(
      t2px[0],
      t2py[0],
      t2px[1],
      t2py[1],
      t2px[2],
      t2py[2],
      Colors.red,
      Colors.green,
      Colors.blue,
      antiAliased: antiAliased,
    );

    // Quadrant 4: Rotating Squares
    final q4x = squareCanvas!.width;
    final q4y = squareCanvas!.height * 2;

    // Left: Outline Square
    final s1cx = q4x - rShape - 2;
    final s1cy = q4y;
    final s1angles = [
      shapeAngle + pi / 4,
      shapeAngle + 3 * pi / 4,
      shapeAngle + 5 * pi / 4,
      shapeAngle + 7 * pi / 4,
    ];
    final s1px = List.generate(
      4,
      (i) => (s1cx + rShape * cos(s1angles[i])).round(),
    );
    final s1py = List.generate(
      4,
      (i) => (s1cy + rShape * sin(s1angles[i])).round(),
    );
    final colorsSquare = [
      CharmColors.ice,
      CharmColors.flamingo,
      CharmColors.mustard,
      CharmColors.julep,
    ];
    for (var i = 0; i < 4; i++) {
      final next = (i + 1) % 4;
      squareCanvas!.drawLineColored(
        s1px[i],
        s1py[i],
        s1px[next],
        s1py[next],
        colorsSquare[i],
        colorsSquare[next],
        antiAliased: antiAliased,
      );
    }

    // Right: Filled Square
    final s2cx = q4x + rShape + 2;
    final s2cy = q4y;
    final s2angles = [
      shapeAngle + pi / 4,
      shapeAngle + 3 * pi / 4,
      shapeAngle + 5 * pi / 4,
      shapeAngle + 7 * pi / 4,
    ];
    final s2px = List.generate(
      4,
      (i) => (s2cx + rShape * cos(s2angles[i])).round(),
    );
    final s2py = List.generate(
      4,
      (i) => (s2cy + rShape * sin(s2angles[i])).round(),
    );
    squareCanvas!.fillQuadColored(
      s2px[0],
      s2py[0],
      s2px[1],
      s2py[1],
      s2px[2],
      s2py[2],
      s2px[3],
      s2py[3],
      Colors.red,
      Colors.orange,
      Colors.blue,
      Colors.green,
      antiAliased: antiAliased,
    );

    final modeName = renderMode.name.toUpperCase();
    final statusName = vectorGraphicsPaused ? "PAUSED" : "RUNNING";
    return Column([
      SizedBox(
        height: 1,
        child: Text(
          '   Clock & Radar (Top)          Rotating Shapes (Bottom)   [AA: ${antiAliased ? "ON" : "OFF"}] [Mode: $modeName] [$statusName] [P: Pause]',
          style: const Style(
            foreground: CharmColors.squid,
            modifiers: Modifier.bold,
          ),
        ),
      ),
      const SizedBox(height: 1, child: Text('')),
      Expanded(
        child: Column([
          Expanded(
            child: Row([
              Expanded(child: clockCanvas!),
              Expanded(child: radarWidget!),
            ]),
          ),
          Expanded(
            child: Row([
              Expanded(child: triangleCanvas!),
              Expanded(child: squareCanvas!),
            ]),
          ),
        ]),
      ),
    ]);
  }

  @override
  bool handleKeyEvent(ui.KeyEvent event) {
    if (event.key == 'a' || event.key == 'A') {
      antiAliased = !antiAliased;
      return true;
    } else if (event.key == 'm' || event.key == 'M') {
      final nextIdx = (renderMode.index + 1) % CanvasRenderMode.values.length;
      renderMode = CanvasRenderMode.values[nextIdx];
      return true;
    } else if (event.key == 'p' || event.key == 'P') {
      vectorGraphicsPaused = !vectorGraphicsPaused;
      return true;
    }
    return false;
  }

  @override
  Map<String, String> get helpBindings => {
    'A': 'Toggle Anti-Aliasing',
    'M': 'Cycle Render Mode',
  };
}
