import 'dart:math' as math;
import 'dart:typed_data';
import 'package:termui/termui.dart';
import 'package:termui/ui/event.dart' as ui;
import 'example_base.dart';

/// Interactive demonstration of the Kitty Terminal Protocol (`KTTY`):
/// - `KittyImage` using `U+10EEEE` Unicode Placeholders (`a=t` + `a=p,U=1`).
/// - Cell-granularity window occlusion over `KittyImage` via `Stack` / `Compositor`.
/// - Live toggle between `enableKittyPassthrough: true` (`U+10EEEE` subpixels)
///   and `enableKittyPassthrough: false` (Unicode half-block `▀` mosaic).
/// - Live inspector for `U+10EEEE` cell diacritic encoding and key events.
final class KittyProtocolExample extends WidgetBookExample {
  /// Kitty image identifier encoded into the 24-bit foreground RGB (`"KTY"`).
  static const int kDemoImageId = 0x4B5459;

  /// Whether to render using `KittyImage` (`U+10EEEE` placeholders) or Unicode mosaic.
  ///
  /// Defaults to `false` on CLI/TTY (`shouldRenderToTerminal == true`) so
  /// terminals like Windows Terminal / SSH / `tmux` render clean half-block
  /// mosaic cells out-of-the-box, and `true` on `termui_flutter`.
  bool enableKittyPassthrough = false;

  /// Whether the floating TUI occlusion window is visible over the image.
  bool showOcclusionWindow = true;

  /// Floating occlusion window X offset in cells.
  int overlayX = 6;

  /// Floating occlusion window Y offset in cells.
  int overlayY = 2;

  /// Last observed key event summary for the protocol inspector.
  String lastKeySummary = 'Press M, O, or WASD';

  int _cachedPixW = 0;
  int _cachedPixH = 0;
  Uint8List? _cachedRgba;
  Buffer? _cachedMosaic;
  int _grabOffsetX = 12;
  int _grabOffsetY = 2;

  @override
  bool get requiresTick => true;

  @override
  bool tick(Duration duration) => false;

  @override
  Map<String, String> get helpBindings => {
    'M': 'Toggle Kitty / Mosaic',
    'O': 'Toggle Occlusion Box',
    'WASD': 'Move Occlusion Box',
    'Mouse': 'Drag Occlusion Box',
  };

  @override
  bool handleKeyEvent(ui.KeyEvent event) {
    final mods = event.modifiers.map((m) => m.name).join('+');
    final modPrefix = mods.isEmpty ? '' : '$mods+';
    lastKeySummary = '${event.type.name}: $modPrefix${event.key}';

    switch (event.key) {
      case 'm' || 'M':
        enableKittyPassthrough = !enableKittyPassthrough;
        return true;
      case 'o' || 'O':
        showOcclusionWindow = !showOcclusionWindow;
        return true;
      case 'w' || 'W' || 'i' || 'I':
        overlayY = math.max(0, overlayY - 1);
        return true;
      case 's' || 'S' || 'k' || 'K':
        overlayY += 1;
        return true;
      case 'a' || 'A' || 'j' || 'J':
        overlayX = math.max(0, overlayX - 2);
        return true;
      case 'd' || 'D' || 'l' || 'L':
        overlayX += 2;
        return true;
      default:
        return true;
    }
  }

  @override
  void handleMouseEvent(
    ui.MouseEvent event,
    int localX,
    int localY,
    int width,
    int height,
  ) {
    final canvasX = localX - 1;
    final canvasY = localY - 3;
    if (event.type == ui.MouseEventType.press) {
      final hitModal =
          showOcclusionWindow &&
          canvasX >= overlayX &&
          canvasX < overlayX + 24 &&
          canvasY >= overlayY &&
          canvasY < overlayY + 5;
      if (hitModal) {
        _grabOffsetX = canvasX - overlayX;
        _grabOffsetY = canvasY - overlayY;
      } else {
        _grabOffsetX = 12;
        _grabOffsetY = 2;
        overlayX = math.max(0, canvasX - _grabOffsetX);
        overlayY = math.max(0, canvasY - _grabOffsetY);
      }
    } else if (event.type == ui.MouseEventType.drag) {
      overlayX = math.max(0, canvasX - _grabOffsetX);
      overlayY = math.max(0, canvasY - _grabOffsetY);
    }
  }

  @override
  Widget build({
    required bool focusDemoPane,
    required int width,
    required int height,
  }) {
    final gridCols = math.max(16, width - 4);
    final gridRows = math.max(6, height - 7);
    final int clampedX = overlayX.clamp(0, math.max(0, gridCols - 22));
    final int clampedY = overlayY.clamp(0, math.max(0, gridRows - 5));
    overlayX = clampedX;
    overlayY = clampedY;

    final pixW = gridCols * 4;
    final pixH = gridRows * 8;
    if (_cachedRgba == null || _cachedPixW != pixW || _cachedPixH != pixH) {
      _cachedPixW = pixW;
      _cachedPixH = pixH;
      _cachedRgba = _generatePlasmaRgba(pixW, pixH, 0.4);
      _cachedMosaic = _buildHalfBlockMosaic(
        _cachedRgba!,
        pixW,
        pixH,
        gridCols,
        gridRows,
      );
    }

    final Widget surfaceWidget = enableKittyPassthrough
        ? KittyImage(
            imageId: kDemoImageId,
            pixelWidth: pixW,
            pixelHeight: pixH,
            rgbaPixels: _cachedRgba!,
            columns: gridCols,
            rows: gridRows,
          )
        : BufferWidget(buffer: _cachedMosaic!);

    return Column([
      _buildStatusBar(gridCols, gridRows, pixW, pixH),
      const SizedBox(height: 1, child: Text('')),
      Expanded(
        child: DecoratedBox(
          decoration: const BoxDecoration(
            border: Border.all(Style(foreground: CharmColors.charple)),
          ),
          child: Stack([
            Positioned(
              left: 0,
              top: 0,
              right: 0,
              bottom: 0,
              child: surfaceWidget,
            ),
            if (showOcclusionWindow)
              Positioned(
                left: clampedX,
                top: clampedY,
                width: math.min(24, gridCols),
                height: math.min(5, gridRows),
                child: _buildOcclusionOverlay(clampedX, clampedY),
              ),
          ]),
        ),
      ),
      const SizedBox(height: 1, child: Text('')),
      _buildInspectorFooter(clampedX, clampedY),
    ]);
  }

  Widget _buildStatusBar(int cols, int rows, int pixW, int pixH) {
    final modeLabel = enableKittyPassthrough
        ? 'KTTY U+10EEEE Placeholders (4x8 subpixels/cell)'
        : 'Unicode Half-Block Mosaic Fallback (1x2/cell)';
    final modeColor = enableKittyPassthrough
        ? CharmColors.julep
        : CharmColors.zest;

    return SizedBox(
      height: 1,
      child: RichText(
        wrap: false,
        text: TextSpan(
          children: [
            const TextSpan(
              text: 'Mode [M]: ',
              style: Style(
                foreground: CharmColors.salt,
                modifiers: Modifier.bold,
              ),
            ),
            TextSpan(
              text: '$modeLabel ',
              style: Style(
                foreground: modeColor,
                modifiers: Modifier.bold,
                underlineStyle: UnderlineStyle.single,
                underlineColor: modeColor,
              ),
            ),
            TextSpan(
              text: ' │ Grid: ${cols}x$rows (${pixW}x${pixH}px)',
              style: const Style(foreground: CharmColors.smoke),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOcclusionOverlay(int x, int y) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border.all(
          Style(
            foreground: CharmColors.butter,
            background: CharmColors.pepper,
            modifiers: Modifier.bold,
          ),
        ),
      ),
      child: Column([
        const SizedBox(
          height: 1,
          child: Text(
            ' TUI Occlusion Layer ',
            style: Style(
              foreground: CharmColors.butter,
              background: CharmColors.pepper,
              modifiers: Modifier.bold,
            ),
          ),
        ),
        SizedBox(
          height: 1,
          child: Text(
            ' Cell ($x, $y) [WASD]   ',
            style: const Style(
              foreground: CharmColors.salt,
              background: CharmColors.pepper,
            ),
          ),
        ),
        const SizedBox(
          height: 1,
          child: Text(
            ' Overwrites U+10EEEE  ',
            style: Style(
              foreground: CharmColors.malibu,
              background: CharmColors.pepper,
              modifiers: Modifier.italic,
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildInspectorFooter(int sampleCol, int sampleRow) {
    final rowDia = sampleRow < kittyDiacritics.length
        ? kittyDiacritics[sampleRow]
        : 0x0305;
    final colDia = sampleCol < kittyDiacritics.length
        ? kittyDiacritics[sampleCol]
        : 0x0305;
    final hexRow = rowDia.toRadixString(16).toUpperCase().padLeft(4, '0');
    final hexCol = colDia.toRadixString(16).toUpperCase().padLeft(4, '0');

    return Column([
      SizedBox(
        height: 1,
        child: RichText(
          wrap: false,
          text: TextSpan(
            children: [
              const TextSpan(
                text: 'Placeholder Cell: ',
                style: Style(
                  foreground: CharmColors.salt,
                  modifiers: Modifier.bold,
                ),
              ),
              TextSpan(
                text:
                    'U+10EEEE + U+$hexRow (row $sampleRow) + U+$hexCol (col $sampleCol) ',
                style: const Style(foreground: CharmColors.malibu),
              ),
              const TextSpan(
                text: 'fg=#4B5459 (id=4936793)',
                style: Style(
                  foreground: CharmColors.dolly,
                  modifiers: Modifier.dim,
                ),
              ),
            ],
          ),
        ),
      ),
      SizedBox(
        height: 1,
        child: RichText(
          wrap: false,
          text: TextSpan(
            children: [
              const TextSpan(
                text: 'Controls: ',
                style: Style(
                  foreground: CharmColors.salt,
                  modifiers: Modifier.bold,
                ),
              ),
              const TextSpan(
                text:
                    '[M] Toggle KTTY/Mosaic  [O] Toggle Overlay  [WASD/Drag] Move  │ ',
                style: Style(foreground: CharmColors.smoke),
              ),
              TextSpan(
                text: 'Input: $lastKeySummary',
                style: const Style(
                  foreground: CharmColors.julep,
                  underlineStyle: UnderlineStyle.dotted,
                  underlineColor: CharmColors.julep,
                ),
              ),
            ],
          ),
        ),
      ),
    ]);
  }

  Uint8List _generatePlasmaRgba(int width, int height, double t) {
    final bytes = Uint8List(width * height * 4);
    var idx = 0;
    for (var y = 0; y < height; y++) {
      final ny = y / math.max(1, height);
      final sy = math.sin(ny * 6.0 + t);
      for (var x = 0; x < width; x++) {
        final nx = x / math.max(1, width);
        final v =
            math.sin(nx * 8.0 + t) + sy + math.sin((nx + ny) * 6.0 - t * 0.7);
        final r = ((math.sin(v) * 0.5 + 0.5) * 230 + 25).round().clamp(0, 255);
        final g = ((math.sin(v + 2.1) * 0.5 + 0.5) * 210 + 20).round().clamp(
          0,
          255,
        );
        final b = ((math.sin(v + 4.2) * 0.5 + 0.5) * 245 + 10).round().clamp(
          0,
          255,
        );
        bytes[idx++] = r;
        bytes[idx++] = g;
        bytes[idx++] = b;
        bytes[idx++] = 255;
      }
    }
    return bytes;
  }

  Buffer _buildHalfBlockMosaic(
    Uint8List rgba,
    int pixW,
    int pixH,
    int cols,
    int rows,
  ) {
    final buf = Buffer(cols, rows);
    for (var cy = 0; cy < rows; cy++) {
      final topPy = ((cy * 2 + 0.5) * pixH / (rows * 2)).floor().clamp(
        0,
        pixH - 1,
      );
      final botPy = ((cy * 2 + 1.5) * pixH / (rows * 2)).floor().clamp(
        0,
        pixH - 1,
      );
      for (var cx = 0; cx < cols; cx++) {
        final px = ((cx + 0.5) * pixW / cols).floor().clamp(0, pixW - 1);
        final topIdx = (topPy * pixW + px) * 4;
        final botIdx = (botPy * pixW + px) * 4;
        final fg =
            0xFF000000 |
            (rgba[topIdx] << 16) |
            (rgba[topIdx + 1] << 8) |
            rgba[topIdx + 2];
        final bg =
            0xFF000000 |
            (rgba[botIdx] << 16) |
            (rgba[botIdx + 1] << 8) |
            rgba[botIdx + 2];
        buf.setCell(cx, cy, '▀', fg, bg, Modifier.none);
      }
    }
    return buf;
  }
}
