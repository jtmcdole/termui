import 'dart:math';
import 'package:termui/termui.dart';
import 'package:termui/ui/event.dart' as ui;
import 'example_base.dart';

/// 3D Vector coordinate representation.
class Vec3 {
  /// The X component.
  final double x;

  /// The Y component.
  final double y;

  /// The Z component.
  final double z;

  /// Creates a [Vec3] coordinate.
  const Vec3(this.x, this.y, this.z);

  /// Computes the difference between this vector and [other].
  Vec3 operator -(Vec3 other) => Vec3(x - other.x, y - other.y, z - other.z);

  @override
  String toString() =>
      'Vec3(${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)}, ${z.toStringAsFixed(3)})';
}

/// A rotating, shaded 3D isometric representation of the McDole Heavy Industries logo.
class McdoleLogoExample extends WidgetBookExample {
  /// Toggle for solid filled rendering vs. wireframe
  bool isSolid = true;

  /// Toggle for showing backface wireframe lines in solid mode
  bool showBackfaces = true;

  /// Whether the rotation animation is active
  bool isAnimated = true;

  /// Shading color mode (0: McDole Gold, 1: Spectrum, 2: Monochrome)
  int colorMode = 0;

  /// The active render mode of the canvas (braille, density, quadrants)
  CanvasRenderMode renderMode = CanvasRenderMode.braille;

  /// The zoom scale factor of the 3D scene
  double zoom = 1.0;

  /// Rotation angle around the Y-axis (yaw)
  double theta = pi / 4;

  /// Rotation angle around the X-axis (pitch) - defaults to exact isometric tilt
  double phi = atan(1 / sqrt(2));

  /// Mouse drag tracking flag
  bool isDragging = false;

  /// Last recorded mouse X coordinate
  int lastMouseX = 0;

  /// Last recorded mouse Y coordinate
  int lastMouseY = 0;

  /// The canvas used to draw the logo
  Canvas? logoCanvas;

  /// The canvas used to draw the backfaces of the logo in solid mode
  Canvas? backfaceCanvas;

  @override
  bool get requiresTick => true;

  @override
  bool tick(Duration duration) {
    if (isAnimated && !isDragging) {
      theta += 0.02; // auto rotate around Y axis
      return true;
    }
    return false;
  }

  @override
  Map<String, String> get helpBindings => {
    'Space / P / p': 'Play/Pause Rotation',
    'F / f': 'Toggle Solid vs Wireframe',
    'B / b': 'Toggle Backfaces',
    'C / c': 'Cycle Colors',
    'M / m': 'Cycle Render Mode',
    '+ / -': 'Zoom In / Out',
    'Mouse Drag': 'Rotate Logo manually',
  };

  @override
  bool handleKeyEvent(ui.KeyEvent event) {
    if (event.key == ' ' ||
        event.key == 'Space' ||
        event.key == 'p' ||
        event.key == 'P') {
      isAnimated = !isAnimated;
      return true;
    }
    if (event.key == 'f' || event.key == 'F') {
      isSolid = !isSolid;
      return true;
    }
    if (event.key == 'b' || event.key == 'B') {
      showBackfaces = !showBackfaces;
      return true;
    }
    if (event.key == 'c' || event.key == 'C') {
      colorMode = (colorMode + 1) % 3;
      return true;
    }
    if (event.key == 'm' || event.key == 'M') {
      final nextIdx = (renderMode.index + 1) % CanvasRenderMode.values.length;
      renderMode = CanvasRenderMode.values[nextIdx];
      return true;
    }
    if (event.key == '+' || event.key == '=') {
      zoom = (zoom + 0.1).clamp(0.1, 4.0);
      return true;
    }
    if (event.key == '-') {
      zoom = (zoom - 0.1).clamp(0.1, 4.0);
      return true;
    }
    return false;
  }

  @override
  void handleMouseEvent(
    ui.MouseEvent event,
    int localX,
    int localY,
    int width,
    int height,
  ) {
    if (event.type == ui.MouseEventType.press) {
      isDragging = true;
      lastMouseX = localX;
      lastMouseY = localY;
    } else if (event.type == ui.MouseEventType.drag && isDragging) {
      final dx = localX - lastMouseX;
      final dy = localY - lastMouseY;
      theta += dx * 0.05;
      phi -= dy * 0.05;
      lastMouseX = localX;
      lastMouseY = localY;
    } else if (event.type == ui.MouseEventType.release) {
      isDragging = false;
    }
  }

  @override
  Widget build({
    required bool focusDemoPane,
    required int width,
    required int height,
  }) {
    // Allocate canvas based on the parent size (clamped)
    final canvasWidth = max(20, width - 2);
    final canvasHeight = max(10, height - 3);

    if (logoCanvas == null ||
        logoCanvas!.width != canvasWidth ||
        logoCanvas!.height != canvasHeight) {
      logoCanvas = Canvas(canvasWidth, canvasHeight, renderMode: renderMode);
    } else {
      logoCanvas!.renderMode = renderMode;
      logoCanvas!.clear();
    }

    if (isSolid && showBackfaces) {
      if (backfaceCanvas == null ||
          backfaceCanvas!.width != canvasWidth ||
          backfaceCanvas!.height != canvasHeight) {
        backfaceCanvas = Canvas(
          canvasWidth,
          canvasHeight,
          renderMode: renderMode,
        );
      } else {
        backfaceCanvas!.renderMode = renderMode;
        backfaceCanvas!.clear();
      }
    }

    // Sub-pixel dimensions
    final subWidth = canvasWidth * 2;
    final subHeight = canvasHeight * 4;
    final cx = subWidth / 2;
    final cy = subHeight / 2;
    final S = min(subWidth, subHeight) * 0.42 * zoom;

    // --- Rotate and project vertices ---
    final cosT = cos(theta);
    final sinT = sin(theta);
    final cosP = cos(phi);
    final sinP = sin(phi);

    final rotated = List<Vec3>.generate(_logoVertices.length, (idx) {
      final v = _logoVertices[idx];
      // 1. Rotate around Y (theta)
      final x1 = v.x * cosT - v.z * sinT;
      final y1 = v.y;
      final z1 = v.x * sinT + v.z * cosT;

      // 2. Rotate around X (phi)
      final x2 = x1;
      final y2 = y1 * cosP - z1 * sinP;
      final z2 = y1 * sinP + z1 * cosP;

      return Vec3(x2, y2, z2);
    });

    int projU(Vec3 v) => (cx + S * v.x).round();
    int projV(Vec3 v) =>
        (cy - S * v.y).round(); // subtract because screen Y increases downward

    // Base color selection
    Color baseColor;
    if (colorMode == 0) {
      baseColor = const Color(0xEA, 0xC0, 0x75); // McDole Gold
    } else if (colorMode == 1) {
      baseColor = const Color(0x7F, 0x90, 0xFF); // Soft Blue-purple
    } else {
      baseColor = const Color(0xCC, 0xCC, 0xCC); // Silver/White
    }

    if (isSolid) {
      // Painter's algorithm: sort faces by average view-space Z depth (back to front)
      final depths = List<double>.generate(_logoFaces.length, (idx) {
        final face = _logoFaces[idx];
        var sumZ = 0.0;
        for (final vIdx in face) {
          sumZ += rotated[vIdx].z;
        }
        return sumZ / face.length;
      });

      final faceIndices = List<int>.generate(_logoFaces.length, (idx) => idx)
        ..sort((a, b) => depths[a].compareTo(depths[b]));

      // Light direction in view space (coming from top-right-front)
      final lightDir = _normalize(const Vec3(0.5, 0.7, 0.5));

      for (final fIdx in faceIndices) {
        final face = _logoFaces[fIdx];
        final v0 = rotated[face[0]];
        final v1 = rotated[face[1]];
        final v2 = rotated[face[2]];
        final v3 = rotated[face[3]];

        // Calculate face normal
        var normal = _normalize(_crossProduct(v1 - v0, v2 - v0));

        final isBackface = normal.z <= 0;

        // If backface culling is enabled (showBackfaces is false) and it's a backface, skip it.
        if (!showBackfaces && isBackface) continue;

        // Two-sided lighting: if the face normal points away from the viewer,
        // we are looking at its backside, so we invert the normal to point towards the viewer.
        if (isBackface) {
          normal = Vec3(-normal.x, -normal.y, -normal.z);
        }

        // Flat shading factor based on dot product with light direction
        final intensity = max(0.0, _dotProduct(normal, lightDir));
        final shadow = 0.25 + 0.75 * intensity;

        // Custom colors for spectrum mode
        Color faceColor;
        if (colorMode == 1) {
          // Palette spectrum mapping based on face index
          final hue = (fIdx / _logoFaces.length) * 2 * pi;
          final r = (128 + 127 * cos(hue)).round();
          final g = (128 + 127 * cos(hue + 2 * pi / 3)).round();
          final b = (128 + 127 * cos(hue + 4 * pi / 3)).round();
          faceColor = Color(
            (r * shadow).round().clamp(0, 255),
            (g * shadow).round().clamp(0, 255),
            (b * shadow).round().clamp(0, 255),
          );
        } else {
          faceColor = Color(
            (baseColor.r * shadow).round().clamp(0, 255),
            (baseColor.g * shadow).round().clamp(0, 255),
            (baseColor.b * shadow).round().clamp(0, 255),
          );
        }

        // Determine which canvas to draw to:
        // If showing backfaces is enabled, backfaces are drawn on logoCanvas, and frontfaces on backfaceCanvas.
        // Otherwise (culling is enabled), frontfaces are drawn directly on logoCanvas.
        final Canvas drawCanvas;
        if (showBackfaces) {
          drawCanvas = isBackface ? logoCanvas! : backfaceCanvas!;
        } else {
          drawCanvas = logoCanvas!;
        }

        // Fill the solid polygon
        drawCanvas.fillQuadColored(
          projU(v0),
          projV(v0),
          projU(v1),
          projV(v1),
          projU(v2),
          projV(v2),
          projU(v3),
          projV(v3),
          faceColor,
          faceColor,
          faceColor,
          faceColor,
          value: true,
          antiAliased: false,
        );
      }

      // If we drew backfaces separately, merge frontfaces (backfaceCanvas) onto backfaces (logoCanvas) with overwrite.
      if (showBackfaces && backfaceCanvas != null) {
        logoCanvas!.merge(backfaceCanvas!, overwrite: true);
      }
    } else {
      // Wireframe Mode: draw outlines of faces
      for (final face in _logoFaces) {
        final v0 = rotated[face[0]];
        final v1 = rotated[face[1]];
        final v2 = rotated[face[2]];

        // Calculate face normal to determine back-facing
        final normal = _normalize(_crossProduct(v1 - v0, v2 - v0));

        // If showBackfaces is false, cull the back-facing lines in wireframe mode
        if (!showBackfaces && normal.z <= 0) continue;

        for (var i = 0; i < face.length; i++) {
          final edgeStart = rotated[face[i]];
          final edgeEnd = rotated[face[(i + 1) % face.length]];
          logoCanvas!.drawLineColored(
            projU(edgeStart),
            projV(edgeStart),
            projU(edgeEnd),
            projV(edgeEnd),
            baseColor,
            baseColor,
            value: true,
            antiAliased: false,
          );
        }
      }
    }

    return Column([
      Row([
        Text(
          ' 3D Isometric Logo (Mcdole Heavy Industries) ',
          style: const Style(
            modifiers: Modifier.bold,
            foreground: CharmColors.mustard,
          ),
        ),
        Text(
          isSolid ? '[Solid Shaded]' : '[Wireframe]',
          style: const Style(foreground: CharmColors.smoke),
        ),
        Text(
          isAnimated ? ' [Running]' : ' [Paused]',
          style: Style(
            foreground: isAnimated ? CharmColors.guac : CharmColors.sriracha,
          ),
        ),
        Text(
          ' [Render: ${renderMode.name.toUpperCase()}]',
          style: const Style(foreground: CharmColors.smoke),
        ),
        Text(
          ' [Zoom: ${zoom.toStringAsFixed(1)}x]',
          style: const Style(foreground: CharmColors.smoke),
        ),
        Text(
          showBackfaces ? ' [Backfaces: Show]' : ' [Backfaces: Hide]',
          style: const Style(foreground: CharmColors.smoke),
        ),
      ]),
      const SizedBox(height: 1),
      Expanded(
        child: DecoratedBox(
          decoration: const BoxDecoration(
            border: Border.all(Style(foreground: CharmColors.smoke)),
          ),
          child: logoCanvas!,
        ),
      ),
    ]);
  }
}

// Helper math operations
Vec3 _crossProduct(Vec3 a, Vec3 b) {
  return Vec3(
    a.y * b.z - a.z * b.y,
    a.z * b.x - a.x * b.z,
    a.x * b.y - a.y * b.x,
  );
}

double _dotProduct(Vec3 a, Vec3 b) {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}

Vec3 _normalize(Vec3 v) {
  final len = sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
  if (len == 0) return const Vec3(0, 0, 0);
  return Vec3(v.x / len, v.y / len, v.z / len);
}

// Reconstructed 3D isometric geometry vertices
const List<Vec3> _logoVertices = [
  Vec3(1.0000, -0.8462, -0.8462), // 0
  Vec3(1.0000, -1.0000, -1.0000), // 1
  Vec3(1.0000, 1.0000, -1.0000), // 2
  Vec3(-1.0000, 1.0000, -1.0000), // 3
  Vec3(-1.0000, 1.0000, 1.0000), // 4
  Vec3(-1.0000, -1.0000, 1.0000), // 5
  Vec3(1.0000, -1.0000, 1.0000), // 6
  Vec3(1.0000, -0.8462, 1.0000), // 7
  Vec3(-0.8462, -0.8462, 1.0000), // 8
  Vec3(-0.8462, 1.0000, 1.0000), // 9
  Vec3(-0.8462, 1.0000, -0.8462), // 10
  Vec3(1.0000, 1.0000, -0.8462), // 11
  Vec3(0.0769, -0.6923, 1.0000), // 12
  Vec3(0.2923, -0.6923, 1.0000), // 13
  Vec3(0.2923, 0.3231, 1.0000), // 14
  Vec3(0.2923, 0.5385, 1.0000), // 15
  Vec3(0.2923, 0.8462, 1.0000), // 16
  Vec3(0.0769, 0.8462, 1.0000), // 17
  Vec3(1.0000, 0.3231, 0.7231), // 18
  Vec3(1.0000, 0.3231, 0.8769), // 19
  Vec3(1.0000, 0.3231, 1.0000), // 20
  Vec3(1.0000, 0.5385, 1.0000), // 21
  Vec3(1.0000, 0.5385, 0.8769), // 22
  Vec3(1.0000, 0.5385, 0.7231), // 23
  Vec3(1.0000, 0.5385, 0.2923), // 24
  Vec3(1.0000, 0.8462, 0.2923), // 25
  Vec3(1.0000, 0.8462, 0.0769), // 26
  Vec3(1.0000, -0.6923, 0.0769), // 27
  Vec3(1.0000, -0.6923, 0.2923), // 28
  Vec3(1.0000, 0.3231, 0.2923), // 29
  Vec3(1.0000, -0.6923, 1.0000), // 30
  Vec3(1.0000, 0.1385, 1.0000), // 31
  Vec3(1.0000, 0.1385, 0.8769), // 32
  Vec3(1.0000, -0.6923, 0.8769), // 33
  Vec3(0.8769, 0.1385, 1.0000), // 34
  Vec3(0.8769, -0.6923, 1.0000), // 35
  Vec3(-0.6923, -0.6923, 1.0000), // 36
  Vec3(-0.3846, -0.6923, 1.0000), // 37
  Vec3(-0.3846, 0.8462, 1.0000), // 38
  Vec3(-0.6923, 0.8462, 1.0000), // 39
  Vec3(1.0000, 1.0000, 1.0000), // 40
  Vec3(-0.6923, 1.0000, 1.0000), // 41
  Vec3(-0.6923, 1.0000, 0.6923), // 42
  Vec3(0.6923, 1.0000, 0.6923), // 43
  Vec3(0.6923, 1.0000, -0.6923), // 44
  Vec3(1.0000, 1.0000, -0.6923), // 45
  Vec3(1.0000, -0.6923, -0.6923), // 46
  Vec3(1.0000, -0.6923, -0.3846), // 47
  Vec3(1.0000, 0.8462, -0.3846), // 48
  Vec3(1.0000, 0.8462, -0.6923), // 49
];

const List<List<int>> _logoFaces = [
  // --- Outer Cube Frame Faces (Solid Outer Borders) ---
  [6, 1, 0, 7],
  [1, 2, 11, 0],
  [2, 3, 10, 11],
  [3, 4, 9, 10],
  [4, 5, 8, 9],
  [5, 6, 7, 8],

  // --- H-Letter: Columns (Vertical Legs) ---
  [46, 49, 48, 47], // Far-Left Column (Left Face)
  [27, 26, 25, 28], // Inner-Left Column (Left Face)
  [12, 13, 16, 17], // Inner-Right Column (Right Face)
  [36, 37, 38, 39], // Far-Right Column (Right Face)
  // --- H-Letter: Crossbars (Horizontal Bars meeting at front-center edge) ---
  [29, 24, 21, 20], // Left Crossbar (Left Face)
  [14, 20, 21, 15], // Right Crossbar (Right Face)
  // --- I-Letter: Vertical column at bottom-center ---
  [30, 33, 32, 31], // Left face of I (Left Face)
  [30, 31, 34, 35], // Right face of I (Right Face)
  // --- M-Letter: Top Chevron ---
  [40, 43, 42, 41], // Top Chevron (Right half on Top Face)
  [40, 45, 44, 43], // Top Chevron (Left half on Top Face)
];
