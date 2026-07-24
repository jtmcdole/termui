import 'dart:math';
import 'dart:typed_data';
import 'package:termui/termui.dart';

/// Defines how pixels are grouped and rasterized.
enum CanvasRenderMode {
  /// Rasterize using Braille patterns.
  braille,

  /// Rasterize using dense shade blocks.
  density,

  /// Rasterize using quadrant characters.
  quadrants,
}

/// A 2D canvas widget for drawing high-resolution pixel graphics in a terminal.
///
/// ### Sub-pixel 2x4 Dot Masks Rendering
/// - Each cell in the terminal grid represents a 2x4 sub-pixel block.
/// - It uses a bitmask mapping system (`_dotMasks`) to target individual
///   sub-pixels (bits 0 to 7 of a byte).
/// - Depending on [renderMode], sub-pixels are rasterized as Braille patterns
///   (using the Unicode Braille block starting at `0x2800`), dense shade blocks
///   (`░`, `▒`, `▓`, `█`), or quadrant characters (`▘`, `▝`, etc.).
///
/// ### Background Snapshot Cache (`saveBackground`)
/// - Calling [saveBackground] copies the active state of the pixel grid,
///   anti-aliasing attributes, and style overrides into background snapshot arrays.
/// - When [clear] is invoked, the canvas is restored to this snapshotted state
///   instead of blanking out entirely, allowing static backgrounds (e.g. axes,
///   borders) to be cached for fast redraws.
///
/// ### Example Usage
///
/// ```dart
/// final canvas = Canvas(40, 20, renderMode: CanvasRenderMode.braille);
/// canvas.drawLine(0, 0, 80, 80, value: true);
///
/// // Save as background:
/// canvas.saveBackground();
///
/// // Draw dynamic elements:
/// canvas.setPixel(10, 10, true);
///
/// // Restore background later:
/// canvas.clear();
/// ```
///
/// ### Properties and Settings
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `width` | [int] | Canvas width in terminal grid columns. |
/// | `height` | [int] | Canvas height in terminal grid rows. |
/// | `style` | [Style] | Base style for the canvas cell blocks. |
/// | `renderMode` | [CanvasRenderMode] | Pixel mapping mode (braille, density, quadrants). |
class Canvas extends Widget {
  static final int _traceCanvasFillTriangleId = Tracer.registerString(
    'Canvas:fillTriangleColored',
  );
  static final int _traceCanvasFillQuadId = Tracer.registerString(
    'Canvas:fillQuadColored',
  );
  static final int _traceCanvasDrawLineColoredId = Tracer.registerString(
    'Canvas:drawLineColored',
  );

  /// Canvas width in terminal grid columns.
  final int width;

  /// Canvas height in terminal grid rows.
  final int height;
  final Uint8List _grid;
  final Uint8List _antiAliased;
  final List<Style?> _styles;

  /// Merges [other] canvas into this canvas.
  /// If [overwrite] is true, cells that are written to in [other] (i.e. grid != 0)
  /// will completely replace the cells in this canvas.
  void merge(Canvas other, {bool overwrite = false}) {
    if (width != other.width || height != other.height) {
      throw ArgumentError(
        'Canvas dimensions must match: ${width}x$height vs ${other.width}x${other.height}',
      );
    }
    final len = width * height;
    for (var i = 0; i < len; i++) {
      final otherDots = other._grid[i];
      if (otherDots != 0) {
        if (overwrite) {
          _grid[i] = otherDots;
          _antiAliased[i] = other._antiAliased[i];
          _styles[i] = other._styles[i];
        } else {
          _grid[i] |= otherDots;
          _antiAliased[i] |= other._antiAliased[i];
          if (other._styles[i] != null) {
            _styles[i] = other._styles[i];
          }
        }
      }
    }
  }

  /// Base style for the canvas cell blocks.
  final Style style;

  /// Pixel mapping mode (braille, density, quadrants).
  CanvasRenderMode renderMode;

  /// Optional callback to check if a specific cell (col, row) is occluded by overlapping elements.
  bool Function(int col, int row)? isOccluded;

  /// If true, the canvas will only paint its cells onto the target buffer where
  /// the target buffer cell currently contains a space (' ').
  final bool onlyDrawOnSpaces;

  /// Creates a canvas widget of given [width] and [height].
  Canvas(
    this.width,
    this.height, {
    this.style = Style.empty,
    this.isOccluded,
    this.renderMode = CanvasRenderMode.braille,
    this.onlyDrawOnSpaces = false,
  }) : _grid = Uint8List(width * height),
       _antiAliased = Uint8List(width * height),
       _styles = List<Style?>.filled(width * height, null);

  Uint8List? _bgGrid;
  Uint8List? _bgAntiAliased;
  List<Style?>? _bgStyles;

  /// Saves the current canvas state as a background snapshot.
  void saveBackground() {
    _bgGrid = Uint8List.fromList(_grid);
    _bgAntiAliased = Uint8List.fromList(_antiAliased);
    _bgStyles = List<Style?>.from(_styles);
  }

  /// Clears the canvas pixels and runtime anti-aliasing flags.
  /// Restores the background snapshot if it exists.
  void clear() {
    final bgGrid = _bgGrid;
    final bgAntiAliased = _bgAntiAliased;
    final bgStyles = _bgStyles;

    if (bgGrid != null && bgAntiAliased != null && bgStyles != null) {
      _grid.setRange(0, _grid.length, bgGrid);
      _antiAliased.setRange(0, _antiAliased.length, bgAntiAliased);
      _styles.setRange(0, _styles.length, bgStyles);
    } else {
      _grid.fillRange(0, _grid.length, 0);
      _antiAliased.fillRange(0, _antiAliased.length, 0);
      _styles.fillRange(0, _styles.length, null);
    }
  }

  /// Sets pixel at (px, py) relative to canvas coordinates.
  ///
  /// px ranges from 0 to width * 2 - 1.
  /// py ranges from 0 to height * 4 - 1.
  void setPixel(
    int px,
    int py,
    bool value, {
    bool antiAliased = false,
    Style? cellStyle,
  }) {
    if (px < 0 || py < 0 || px >= width * 2 || py >= height * 4) return;

    final cx = px ~/ 2;
    final cy = py ~/ 4;

    final dx = px % 2;
    final dy = py % 4;
    final mask = _dotMasks[(dy << 1) | dx];

    final idx = cy * width + cx;
    if (value) {
      _grid[idx] |= mask;
    } else {
      _grid[idx] &= ~mask;
    }

    if (antiAliased) {
      _antiAliased[idx] = 1;
    }

    if (cellStyle != null) {
      _styles[idx] = cellStyle;
    }
  }

  /// Draws a line from (x0, y0) to (x1, y1) in sub-pixel coordinates.
  void drawLine(
    int x0,
    int y0,
    int x1,
    int y1, {
    bool value = true,
    bool antiAliased = false,
    Style? cellStyle,
  }) {
    final dx = (x1 - x0).abs();
    final dy = (y1 - y0).abs();
    final sx = x0 < x1 ? 1 : -1;
    final sy = y0 < y1 ? 1 : -1;
    var err = dx - dy;

    while (true) {
      setPixel(x0, y0, value, antiAliased: antiAliased, cellStyle: cellStyle);
      if (x0 == x1 && y0 == y1) break;
      final e2 = err * 2;
      if (e2 > -dy) {
        err -= dy;
        x0 += sx;
      }
      if (e2 < dx) {
        err += dx;
        y0 += sy;
      }
    }
  }

  /// Draws a line with color interpolated from c0 to c1 in sub-pixel coordinates.
  void drawLineColored(
    int x0,
    int y0,
    int x1,
    int y1,
    Color c0,
    Color c1, {
    bool value = true,
    bool antiAliased = false,
  }) {
    Tracer.record(
      _traceCanvasDrawLineColoredId,
      Phase.begin,
      TraceCategory.paint,
    );
    try {
      drawLineColoredPacked(
        x0,
        y0,
        x1,
        y1,
        c0.argb,
        c1.argb,
        value: value,
        antiAliased: antiAliased,
      );
    } finally {
      Tracer.record(
        _traceCanvasDrawLineColoredId,
        Phase.end,
        TraceCategory.paint,
      );
    }
  }

  /// Draws a line with packed ARGB colors interpolated in sub-pixel coordinates.
  void drawLineColoredPacked(
    int x0,
    int y0,
    int x1,
    int y1,
    int c0argb,
    int c1argb, {
    bool value = true,
    bool antiAliased = false,
  }) {
    final dx = (x1 - x0).abs();
    final dy = (y1 - y0).abs();
    final sx = x0 < x1 ? 1 : -1;
    final sy = y0 < y1 ? 1 : -1;
    var err = dx - dy;

    final double steps = max(dx, dy).toDouble();
    var step = 0;

    int lastCx = -1;
    int lastCy = -1;

    final c0r = (c0argb >> 16) & 0xFF;
    final c0g = (c0argb >> 8) & 0xFF;
    final c0b = c0argb & 0xFF;

    final c1r = (c1argb >> 16) & 0xFF;
    final c1g = (c1argb >> 8) & 0xFF;
    final c1b = c1argb & 0xFF;

    final dr = c1r - c0r;
    final dg = c1g - c0g;
    final db = c1b - c0b;

    while (true) {
      final cx = x0 ~/ 2;
      final cy = y0 ~/ 4;

      Style? cellStyle;
      if (cx != lastCx || cy != lastCy) {
        final t = steps > 0 ? step / steps : 0.0;
        final r = (c0r + dr * t).round().clamp(0, 255);
        final g = (c0g + dg * t).round().clamp(0, 255);
        final b = (c0b + db * t).round().clamp(0, 255);
        cellStyle = Style(foreground: Color(r, g, b));
        lastCx = cx;
        lastCy = cy;
      }

      setPixel(x0, y0, value, antiAliased: antiAliased, cellStyle: cellStyle);
      if (x0 == x1 && y0 == y1) break;
      final e2 = err * 2;
      if (e2 > -dy) {
        err -= dy;
        x0 += sx;
      }
      if (e2 < dx) {
        err += dx;
        y0 += sy;
      }
      step++;
    }
  }

  /// Draws a circle outline at (centerX, centerY) with [radius] in sub-pixel coordinates.
  void drawCircle(
    int centerX,
    int centerY,
    int radius, {
    bool value = true,
    bool antiAliased = false,
    Style? cellStyle,
  }) {
    if (radius < 0) return;
    var x = 0;
    var y = radius;
    var d = 1 - radius;

    _drawCirclePoints(
      centerX,
      centerY,
      x,
      y,
      value,
      antiAliased: antiAliased,
      cellStyle: cellStyle,
    );

    while (x < y) {
      x++;
      if (d < 0) {
        d += 2 * x + 1;
      } else {
        y--;
        d += 2 * (x - y) + 1;
      }
      _drawCirclePoints(
        centerX,
        centerY,
        x,
        y,
        value,
        antiAliased: antiAliased,
        cellStyle: cellStyle,
      );
    }
  }

  void _drawCirclePoints(
    int cx,
    int cy,
    int x,
    int y,
    bool value, {
    required bool antiAliased,
    Style? cellStyle,
  }) {
    setPixel(
      cx + x,
      cy + y,
      value,
      antiAliased: antiAliased,
      cellStyle: cellStyle,
    );
    setPixel(
      cx - x,
      cy + y,
      value,
      antiAliased: antiAliased,
      cellStyle: cellStyle,
    );
    setPixel(
      cx + x,
      cy - y,
      value,
      antiAliased: antiAliased,
      cellStyle: cellStyle,
    );
    setPixel(
      cx - x,
      cy - y,
      value,
      antiAliased: antiAliased,
      cellStyle: cellStyle,
    );
    setPixel(
      cx + y,
      cy + x,
      value,
      antiAliased: antiAliased,
      cellStyle: cellStyle,
    );
    setPixel(
      cx - y,
      cy + x,
      value,
      antiAliased: antiAliased,
      cellStyle: cellStyle,
    );
    setPixel(
      cx + y,
      cy - x,
      value,
      antiAliased: antiAliased,
      cellStyle: cellStyle,
    );
    setPixel(
      cx - y,
      cy - x,
      value,
      antiAliased: antiAliased,
      cellStyle: cellStyle,
    );
  }

  /// Draws an ellipse outline at (centerX, centerY) with [radiusX] and [radiusY] in sub-pixel coordinates.
  void drawEllipse(
    int centerX,
    int centerY,
    int radiusX,
    int radiusY, {
    bool value = true,
    bool antiAliased = false,
    Style? cellStyle,
  }) {
    if (radiusX < 0 || radiusY < 0) return;

    var x = 0;
    var y = radiusY;

    final rx2 = radiusX * radiusX;
    final ry2 = radiusY * radiusY;

    var dx = 2 * ry2 * x;
    var dy = 2 * rx2 * y;

    // Region 1
    var p = (ry2 - rx2 * radiusY + 0.25 * rx2).round();

    while (dx < dy) {
      _drawEllipsePoints(
        centerX,
        centerY,
        x,
        y,
        value,
        antiAliased: antiAliased,
        cellStyle: cellStyle,
      );

      if (p < 0) {
        x++;
        dx += 2 * ry2;
        p += dx + ry2;
      } else {
        x++;
        y--;
        dx += 2 * ry2;
        dy -= 2 * rx2;
        p += dx - dy + ry2;
      }
    }

    // Region 2
    p = (ry2 * (x + 0.5) * (x + 0.5) + rx2 * (y - 1) * (y - 1) - rx2 * ry2)
        .round();

    while (y >= 0) {
      _drawEllipsePoints(
        centerX,
        centerY,
        x,
        y,
        value,
        antiAliased: antiAliased,
        cellStyle: cellStyle,
      );

      if (p > 0) {
        y--;
        dy -= 2 * rx2;
        p += rx2 - dy;
      } else {
        y--;
        x++;
        dx += 2 * ry2;
        dy -= 2 * rx2;
        p += dx - dy + rx2;
      }
    }
  }

  void _drawEllipsePoints(
    int cx,
    int cy,
    int x,
    int y,
    bool value, {
    required bool antiAliased,
    Style? cellStyle,
  }) {
    setPixel(
      cx + x,
      cy + y,
      value,
      antiAliased: antiAliased,
      cellStyle: cellStyle,
    );
    setPixel(
      cx - x,
      cy + y,
      value,
      antiAliased: antiAliased,
      cellStyle: cellStyle,
    );
    setPixel(
      cx + x,
      cy - y,
      value,
      antiAliased: antiAliased,
      cellStyle: cellStyle,
    );
    setPixel(
      cx - x,
      cy - y,
      value,
      antiAliased: antiAliased,
      cellStyle: cellStyle,
    );
  }

  /// Draws a box outline in sub-pixel coordinates.
  void drawBox(
    int x,
    int y,
    int width,
    int height, {
    bool value = true,
    bool antiAliased = false,
    Style? cellStyle,
  }) {
    if (width <= 0 || height <= 0) return;

    // Top & bottom horizontal lines
    for (var px = x; px < x + width; px++) {
      setPixel(px, y, value, antiAliased: antiAliased, cellStyle: cellStyle);
      setPixel(
        px,
        y + height - 1,
        value,
        antiAliased: antiAliased,
        cellStyle: cellStyle,
      );
    }
    // Left & right vertical lines
    for (var py = y + 1; py < y + height - 1; py++) {
      setPixel(x, py, value, antiAliased: antiAliased, cellStyle: cellStyle);
      setPixel(
        x + width - 1,
        py,
        value,
        antiAliased: antiAliased,
        cellStyle: cellStyle,
      );
    }
  }

  /// Fills a circle at (centerX, centerY) with [radius] in sub-pixel coordinates.
  void fillCircle(
    int centerX,
    int centerY,
    int radius, {
    bool value = true,
    bool antiAliased = true,
    Style? cellStyle,
  }) {
    if (radius < 0) return;
    var x = 0;
    var y = radius;
    var d = 1 - radius;

    _drawCircleScanlines(
      centerX,
      centerY,
      x,
      y,
      value,
      antiAliased: antiAliased,
      cellStyle: cellStyle,
    );

    while (x < y) {
      x++;
      if (d < 0) {
        d += 2 * x + 1;
      } else {
        y--;
        d += 2 * (x - y) + 1;
      }
      _drawCircleScanlines(
        centerX,
        centerY,
        x,
        y,
        value,
        antiAliased: antiAliased,
        cellStyle: cellStyle,
      );
    }
  }

  void _drawCircleScanlines(
    int cx,
    int cy,
    int x,
    int y,
    bool value, {
    required bool antiAliased,
    Style? cellStyle,
  }) {
    _drawHorizontalLine(
      cx - x,
      cx + x,
      cy + y,
      value,
      antiAliased: antiAliased,
      cellStyle: cellStyle,
    );
    _drawHorizontalLine(
      cx - x,
      cx + x,
      cy - y,
      value,
      antiAliased: antiAliased,
      cellStyle: cellStyle,
    );
    _drawHorizontalLine(
      cx - y,
      cx + y,
      cy + x,
      value,
      antiAliased: antiAliased,
      cellStyle: cellStyle,
    );
    _drawHorizontalLine(
      cx - y,
      cx + y,
      cy - x,
      value,
      antiAliased: antiAliased,
      cellStyle: cellStyle,
    );
  }

  void _drawHorizontalLine(
    int x0,
    int x1,
    int y,
    bool value, {
    required bool antiAliased,
    Style? cellStyle,
  }) {
    for (var x = x0; x <= x1; x++) {
      setPixel(x, y, value, antiAliased: antiAliased, cellStyle: cellStyle);
    }
  }

  /// Fills a rectangular box in sub-pixel coordinates.
  void fillBox(
    int x,
    int y,
    int width,
    int height, {
    bool value = true,
    bool antiAliased = true,
    Style? cellStyle,
  }) {
    if (width <= 0 || height <= 0) return;
    for (var py = y; py < y + height; py++) {
      for (var px = x; px < x + width; px++) {
        setPixel(px, py, value, antiAliased: antiAliased, cellStyle: cellStyle);
      }
    }
  }

  /// Fills a triangle with vertices (x0, y0), (x1, y1), (x2, y2) and interpolates colors.
  /// Uses a scanline fill algorithm to ensure there are no gaps inside the triangle.
  void fillTriangleColored(
    int x0,
    int y0,
    int x1,
    int y1,
    int x2,
    int y2,
    Color c0,
    Color c1,
    Color c2, {
    bool value = true,
    bool antiAliased = false,
  }) {
    Tracer.record(_traceCanvasFillTriangleId, Phase.begin, TraceCategory.paint);
    try {
      // Sort vertices by Y coordinate so py0 <= py1 <= py2
      var px0 = x0, py0 = y0, pc0 = c0;
      var px1 = x1, py1 = y1, pc1 = c1;
      var px2 = x2, py2 = y2, pc2 = c2;

      if (py0 > py1) {
        var tx = px0;
        px0 = px1;
        px1 = tx;
        var ty = py0;
        py0 = py1;
        py1 = ty;
        var tc = pc0;
        pc0 = pc1;
        pc1 = tc;
      }
      if (py0 > py2) {
        var tx = px0;
        px0 = px2;
        px2 = tx;
        var ty = py0;
        py0 = py2;
        py2 = ty;
        var tc = pc0;
        pc0 = pc2;
        pc2 = tc;
      }
      if (py1 > py2) {
        var tx = px1;
        px1 = px2;
        px2 = tx;
        var ty = py1;
        py1 = py2;
        py2 = ty;
        var tc = pc1;
        pc1 = pc2;
        pc2 = tc;
      }

      if (py0 == py2) {
        // Degenerate flat triangle (horizontal line)
        drawLineColoredPacked(
          px0,
          py0,
          px2,
          py2,
          pc0.argb,
          pc2.argb,
          value: value,
          antiAliased: antiAliased,
        );
        return;
      }

      // Helper to interpolate X and Color at a given Y on a line segment between A and B
      (double, int) interpolateEdge(
        int ax,
        int ay,
        Color ac,
        int bx,
        int by,
        Color bc,
        int y,
      ) {
        if (ay == by) return (ax.toDouble(), ac.argb);
        final t = (y - ay) / (by - ay);
        final x = ax + t * (bx - ax);
        final r = (ac.r + t * (bc.r - ac.r)).round().clamp(0, 255);
        final g = (ac.g + t * (bc.g - ac.g)).round().clamp(0, 255);
        final b = (ac.b + t * (bc.b - ac.b)).round().clamp(0, 255);
        final argb = (255 << 24) | (r << 16) | (g << 8) | b;
        return (x, argb);
      }

      for (var y = py0; y <= py2; y++) {
        // Intersection 1 is on the long edge p0-p2
        final (xa, ca) = interpolateEdge(px0, py0, pc0, px2, py2, pc2, y);

        // Intersection 2 is on p0-p1 (if y < py1) or p1-p2 (if y >= py1)
        final double xb;
        final int cb;
        if (y < py1) {
          final (xbVal, cbVal) = interpolateEdge(
            px0,
            py0,
            pc0,
            px1,
            py1,
            pc1,
            y,
          );
          xb = xbVal;
          cb = cbVal;
        } else {
          final (xbVal, cbVal) = interpolateEdge(
            px1,
            py1,
            pc1,
            px2,
            py2,
            pc2,
            y,
          );
          xb = xbVal;
          cb = cbVal;
        }

        // Draw horizontal span from xa to xb
        drawLineColoredPacked(
          xa.round(),
          y,
          xb.round(),
          y,
          ca,
          cb,
          value: value,
          antiAliased: antiAliased,
        );
      }
    } finally {
      Tracer.record(_traceCanvasFillTriangleId, Phase.end, TraceCategory.paint);
    }
  }

  /// Fills a quadrilateral with vertices p0, p1, p2, p3 (ordered around perimeter) and interpolates colors.
  /// Splits the quad into two triangles and uses the gap-free scanline triangle rasterizer.
  void fillQuadColored(
    int x0,
    int y0,
    int x1,
    int y1,
    int x2,
    int y2,
    int x3,
    int y3,
    Color c0,
    Color c1,
    Color c2,
    Color c3, {
    bool value = true,
    bool antiAliased = false,
  }) {
    Tracer.record(_traceCanvasFillQuadId, Phase.begin, TraceCategory.paint);
    try {
      // Split quad (p0, p1, p2, p3) into two triangles sharing diagonal (p0 -> p2)
      fillTriangleColored(
        x0,
        y0,
        x1,
        y1,
        x2,
        y2,
        c0,
        c1,
        c2,
        value: value,
        antiAliased: antiAliased,
      );
      fillTriangleColored(
        x0,
        y0,
        x2,
        y2,
        x3,
        y3,
        c0,
        c2,
        c3,
        value: value,
        antiAliased: antiAliased,
      );
    } finally {
      Tracer.record(_traceCanvasFillQuadId, Phase.end, TraceCategory.paint);
    }
  }

  @override
  Element createElement() => CanvasElement(this);

  // Pre-computed constants and cache tables for maximum rendering performance
  static const List<int> _dotMasks = [
    0x01, 0x08, // row 0: col 0, col 1
    0x02, 0x10, // row 1: col 0, col 1
    0x04, 0x20, // row 2: col 0, col 1
    0x40, 0x80, // row 3: col 0, col 1
  ];

  static final Uint8List _popcountTable = Uint8List.fromList(
    List.generate(256, (i) {
      var count = 0;
      var temp = i;
      while (temp > 0) {
        if ((temp & 1) != 0) count++;
        temp >>= 1;
      }
      return count;
    }),
  );

  static const List<String> _densityBlocks = [
    ' ',
    '░',
    '░',
    '▒',
    '▒',
    '▒',
    '▓',
    '▓',
    '█',
  ];

  static final List<String> _densityCache = List.generate(256, (i) {
    return _densityBlocks[_popcountTable[i]];
  });

  static final List<String> _brailleCache = List.generate(
    256,
    (i) => String.fromCharCode(0x2800 + i),
  );

  static const List<String> _quadrants = [
    ' ',
    '▘',
    '▝',
    '▀',
    '▖',
    '▌',
    '▞',
    '▛',
    '▗',
    '▚',
    '▐',
    '▜',
    '▄',
    '▙',
    '▟',
    '█',
  ];

  static final List<String> _quadrantCache = List.generate(256, (dots) {
    final tl = (dots & 0x03) != 0;
    final tr = (dots & 0x18) != 0;
    final bl = (dots & 0x44) != 0;
    final br = (dots & 0xA0) != 0;

    final index = (tl ? 1 : 0) | (tr ? 2 : 0) | (bl ? 4 : 0) | (br ? 8 : 0);
    return _quadrants[index];
  });
}

/// Element for high-performance direct flat-buffer rendering in [Canvas].
class CanvasElement extends Element {
  /// Instantiates the rendering element for the given Canvas.
  CanvasElement(Canvas super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final canvas = widget as Canvas;
    final width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : canvas.width;
    final height = constraints.hasBoundedHeight
        ? constraints.maxHeight
        : canvas.height;
    return constraints.constrain(Size(width, height));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final canvas = widget as Canvas;
    var currentBuffer = buffer;
    var startX = offset.dx;
    var startY = offset.dy;
    while (currentBuffer is Viewport) {
      startX += currentBuffer.bounds.x;
      startY += currentBuffer.bounds.y;
      currentBuffer = currentBuffer.parent;
    }
    final targetBuffer = currentBuffer;

    final targetWidth = targetBuffer.width;
    final targetHeight = targetBuffer.height;

    final w = size.width;
    final h = size.height;

    final drawWidth = min(w, canvas.width);
    final drawHeight = min(h, canvas.height);

    final startXInt = startX.toInt();
    final startYInt = startY.toInt();

    final minCx = max(0, -startXInt);
    final maxCx = min(drawWidth, targetWidth - startXInt);
    final minCy = max(0, -startYInt);
    final maxCy = min(drawHeight, targetHeight - startYInt);

    if (minCx >= maxCx || minCy >= maxCy) return;

    for (var cy = minCy; cy < maxCy; cy++) {
      final ty = startYInt + cy;

      for (var cx = minCx; cx < maxCx; cx++) {
        final tx = startXInt + cx;

        if (canvas.onlyDrawOnSpaces &&
            targetBuffer.getCharacter(tx, ty) != ' ') {
          continue;
        }

        if (canvas.isOccluded != null && canvas.isOccluded!(cx, cy)) continue;

        final idx = cy * canvas.width + cx;
        final dots = canvas._grid[idx];
        if (dots == 0 &&
            canvas._styles[idx] == null &&
            canvas.style == Style.empty) {
          continue;
        }

        final String char;
        if (canvas.renderMode == CanvasRenderMode.quadrants) {
          char = Canvas._quadrantCache[dots];
        } else if (canvas.renderMode == CanvasRenderMode.density ||
            canvas._antiAliased[idx] == 1) {
          char = Canvas._densityCache[dots];
        } else {
          char = Canvas._brailleCache[dots];
        }

        final targetIdx = ty * targetWidth + tx;
        targetBuffer.characters[targetIdx] = char;
        final s = canvas._styles[idx];
        final targetAttrIdx = targetIdx * 3;
        if (s != null) {
          targetBuffer.attributes[targetAttrIdx + 0] =
              s.foreground?.argb ?? canvas.style.foreground?.argb ?? 0;
          targetBuffer.attributes[targetAttrIdx + 1] =
              s.background?.argb ?? canvas.style.background?.argb ?? 0;
          targetBuffer.attributes[targetAttrIdx + 2] =
              s.modifiers | canvas.style.modifiers;
        } else {
          targetBuffer.attributes[targetAttrIdx + 0] =
              canvas.style.foreground?.argb ?? 0;
          targetBuffer.attributes[targetAttrIdx + 1] =
              canvas.style.background?.argb ?? 0;
          targetBuffer.attributes[targetAttrIdx + 2] = canvas.style.modifiers;
        }
      }
    }
  }
}
