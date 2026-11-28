import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart' hide Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/widgets/core/geometry.dart' as tui_geo;
import 'package:termui/ui/widgets/display/kitty_image.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/gpu_atlas_batch.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/kitty_run_helper.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/painter.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/shader_backend_gpu.dart';
import 'package:termui_flutter/termui_flutter.dart';

Uint8List _solidRgba(
  int width,
  int height,
  int r,
  int g,
  int b, [
  int a = 255,
]) {
  final pixels = Uint8List(width * height * 4);
  for (var i = 0; i < pixels.length; i += 4) {
    pixels[i] = r;
    pixels[i + 1] = g;
    pixels[i + 2] = b;
    pixels[i + 3] = a;
  }
  return pixels;
}

Future<ui.Image> _decodeRgba(Uint8List pixels, int width, int height) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

KittyImageData _makeSolidKittyData({
  required int imageId,
  required int r,
  required int g,
  required int b,
  int width = 8,
  int height = 8,
  int gridCols = 1,
  int gridRows = 1,
  int version = 0,
}) => KittyImageData(
  imageId: imageId,
  pixelWidth: width,
  pixelHeight: height,
  rgbaPixels: _solidRgba(width, height, r, g, b),
  gridCols: gridCols,
  gridRows: gridRows,
  version: version,
);

Future<Uint8List> _renderPainterRgba(TuiAtlasPainter painter) async {
  final w = (painter.buffer.width * painter.atlas.cellWidth).ceil();
  final h = (painter.buffer.height * painter.atlas.cellHeight).ceil();
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), Size(w.toDouble(), h.toDouble()));
  final picture = recorder.endRecording();
  final image = await picture.toImage(w, h);
  picture.dispose();
  try {
    return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer
        .asUint8List();
  } finally {
    image.dispose();
  }
}

bool _regionContainsColor(
  Uint8List rgba,
  int imgWidth,
  int imgHeight,
  int x0,
  int y0,
  int x1,
  int y1,
  int targetR,
  int targetG,
  int targetB, {
  int tolerance = 4,
}) {
  final cx0 = x0.clamp(0, imgWidth);
  final cx1 = x1.clamp(0, imgWidth);
  final cy0 = y0.clamp(0, imgHeight);
  final cy1 = y1.clamp(0, imgHeight);
  for (var y = cy0; y < cy1; y++) {
    for (var x = cx0; x < cx1; x++) {
      final idx = (y * imgWidth + x) * 4;
      if (rgba[idx + 3] > 200 &&
          (rgba[idx] - targetR).abs() <= tolerance &&
          (rgba[idx + 1] - targetG).abs() <= tolerance &&
          (rgba[idx + 2] - targetB).abs() <= tolerance) {
        return true;
      }
    }
  }
  return false;
}

int _countRegionPixels(
  Uint8List rgba,
  int imgWidth,
  int imgHeight,
  int x0,
  int y0,
  int x1,
  int y1,
  bool Function(int r, int g, int b, int a) predicate,
) {
  final cx0 = x0.clamp(0, imgWidth);
  final cx1 = x1.clamp(0, imgWidth);
  final cy0 = y0.clamp(0, imgHeight);
  final cy1 = y1.clamp(0, imgHeight);
  var count = 0;
  for (var y = cy0; y < cy1; y++) {
    for (var x = cx0; x < cx1; x++) {
      final idx = (y * imgWidth + x) * 4;
      if (predicate(rgba[idx], rgba[idx + 1], rgba[idx + 2], rgba[idx + 3])) {
        count++;
      }
    }
  }
  return count;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    KittyImageRegistry.clear();
    TuiAtlasPainter.debugClearOsc66PainterCache();
  });

  group('Kitty crop UVs and sub-cell offsets', () {
    test('resolveKittySourceUv applies crop and clamps to image bounds', () {
      final full = resolveKittySourceUv(imageWidth: 100, imageHeight: 50);
      expect(full.u0, closeTo(0.0, 1e-6));
      expect(full.v0, closeTo(0.0, 1e-6));
      expect(full.u1, closeTo(1.0, 1e-6));
      expect(full.v1, closeTo(1.0, 1e-6));

      const crop = KittyPlacement(
        imageId: 1,
        cols: 2,
        rows: 1,
        srcX: 25,
        srcY: 10,
        srcWidth: 50,
        srcHeight: 20,
      );
      final cropped = resolveKittySourceUv(
        imageWidth: 100,
        imageHeight: 50,
        placement: crop,
      );
      expect(cropped.u0, closeTo(0.25, 1e-6));
      expect(cropped.v0, closeTo(0.20, 1e-6));
      expect(cropped.u1, closeTo(0.75, 1e-6));
      expect(cropped.v1, closeTo(0.60, 1e-6));

      // Sub-rect interpolation inside the cropped region (right half of crop).
      final rightHalf = resolveKittySourceUv(
        imageWidth: 100,
        imageHeight: 50,
        placement: crop,
        subU0: 0.5,
        subU1: 1.0,
      );
      expect(rightHalf.u0, closeTo(0.50, 1e-6));
      expect(rightHalf.u1, closeTo(0.75, 1e-6));

      // Overflowing crop clamps cleanly to image dimensions.
      const overflow = KittyPlacement(
        imageId: 1,
        cols: 2,
        rows: 1,
        srcX: 80,
        srcY: 40,
        srcWidth: 200,
        srcHeight: 200,
      );
      final clamped = resolveKittySourceUv(
        imageWidth: 100,
        imageHeight: 50,
        placement: overflow,
      );
      expect(clamped.u0, closeTo(0.80, 1e-6));
      expect(clamped.v0, closeTo(0.80, 1e-6));
      expect(clamped.u1, closeTo(1.0, 1e-6));
      expect(clamped.v1, closeTo(1.0, 1e-6));
    });

    test('resolveKittyCellOffset clamps X/Y sub-cell pixel offsets', () {
      expect(
        resolveKittyCellOffset(
          placement: null,
          cellWidth: 10.0,
          cellHeight: 20.0,
        ),
        equals((dx: 0.0, dy: 0.0)),
      );
      const p = KittyPlacement(
        imageId: 1,
        cols: 1,
        rows: 1,
        cellOffsetX: 3,
        cellOffsetY: 7,
      );
      expect(
        resolveKittyCellOffset(placement: p, cellWidth: 10.0, cellHeight: 20.0),
        equals((dx: 3.0, dy: 7.0)),
      );
      const huge = KittyPlacement(
        imageId: 1,
        cols: 1,
        rows: 1,
        cellOffsetX: 50,
        cellOffsetY: -4,
      );
      expect(
        resolveKittyCellOffset(
          placement: huge,
          cellWidth: 10.0,
          cellHeight: 20.0,
        ),
        equals((dx: 10.0, dy: 0.0)),
      );
    });
  });

  group('Layered direct Kitty placements, clipping, occlusion, and relative P,Q,H,V', () {
    test('splits z=-1073741825, z=-1, z=1 in sorted order with X/Y offsets and scrollback', () {
      final reg = KittyImageRegistry();
      reg.registerImage(_makeSolidKittyData(imageId: 1, r: 0, g: 255, b: 0));
      reg.registerImage(_makeSolidKittyData(imageId: 2, r: 255, g: 0, b: 0));
      reg.registerImage(_makeSolidKittyData(imageId: 3, r: 255, g: 255, b: 0));
      reg.registerPlacement(
        const KittyPlacement(
          imageId: 3,
          placementId: 1,
          gridCol: 1,
          gridRow: 1,
          cols: 2,
          rows: 1,
          cellOffsetX: 3,
          cellOffsetY: 4,
          zIndex: 1,
        ),
      );
      reg.registerPlacement(
        const KittyPlacement(
          imageId: 2,
          placementId: 1,
          gridCol: 0,
          gridRow: 0,
          cols: 2,
          rows: 1,
          zIndex: -1,
        ),
      );
      reg.registerPlacement(
        const KittyPlacement(
          imageId: 1,
          placementId: 1,
          gridCol: 0,
          gridRow: -1,
          cols: 2,
          rows: 1,
          zIndex: KittyPlacement.underBackgroundZThreshold - 1,
        ),
      );
      // Alt-screen placement should be filtered out while activeAltScreen is false.
      reg.registerPlacement(
        const KittyPlacement(
          imageId: 2,
          placementId: 9,
          isAltScreen: true,
          gridCol: 0,
          gridRow: 0,
          cols: 1,
          rows: 1,
          zIndex: 2,
        ),
      );

      final buf = Buffer.blank(10, 5);
      buf.registerKittyRegistry(const tui_geo.Rect(0, 0, 10, 5), reg);

      // With viewportScrollOffset=0, gridRow=-1 is above viewport (clipped out).
      final live = collectLayeredDirectKittyPlacements(
        buf,
        cellWidth: 10.0,
        cellHeight: 20.0,
      );
      expect(live.underBgPlacements, isEmpty);
      expect(live.bgPlacements, hasLength(1));
      expect(live.bgPlacements.first.placement.zIndex, equals(-1));
      expect(live.fgPlacements, hasLength(1));
      expect(live.fgPlacements.first.placement.zIndex, equals(1));
      expect(live.fgPlacements.first.dstX, closeTo(13.0, 1e-6));
      expect(live.fgPlacements.first.dstY, closeTo(24.0, 1e-6));

      // Scrolling back 1 line brings gridRow=-1 into row 0.
      reg.viewportScrollOffset = 1;
      final scrolled = collectLayeredDirectKittyPlacements(
        buf,
        cellWidth: 10.0,
        cellHeight: 20.0,
      );
      expect(scrolled.underBgPlacements, hasLength(1));
      expect(scrolled.underBgPlacements.first.dstY, closeTo(0.0, 1e-6));

      // Switching to alt screen shows only the alt-screen placement.
      reg.activeAltScreen = true;
      final alt = collectLayeredDirectKittyPlacements(
        buf,
        cellWidth: 10.0,
        cellHeight: 20.0,
      );
      expect(alt.underBgPlacements, isEmpty);
      expect(alt.bgPlacements, isEmpty);
      expect(alt.fgPlacements, hasLength(1));
      expect(alt.fgPlacements.first.placement.placementId, equals(9));
    });

    test('clips to pane bounds and omits cells occluded by higher-z Compositor registry', () {
      final paneReg = KittyImageRegistry();
      final overlayReg = KittyImageRegistry();
      paneReg.registerImage(
        _makeSolidKittyData(
          imageId: 10,
          r: 0,
          g: 200,
          b: 0,
          width: 40,
          height: 20,
        ),
      );
      // Placement extends past right edge of pane bounds [1..5).
      paneReg.registerPlacement(
        const KittyPlacement(
          imageId: 10,
          placementId: 1,
          gridCol: 0,
          gridRow: 0,
          cols: 6,
          rows: 2,
          zIndex: 1,
        ),
      );

      final paneBuf = Buffer.blank(4, 3);
      paneBuf.registerKittyRegistry(const tui_geo.Rect(0, 0, 4, 3), paneReg);

      final modalBuf = Buffer.blank(2, 1);
      modalBuf.registerKittyRegistry(
        const tui_geo.Rect(0, 0, 2, 1),
        overlayReg,
      );

      final compositor = Compositor();
      final target = Buffer.blank(8, 4);
      compositor.composite(
        target: target,
        layers: [
          LayeredBuffer(buffer: paneBuf, x: 1, y: 1, zIndex: 0),
          LayeredBuffer(buffer: modalBuf, x: 2, y: 1, zIndex: 10),
        ],
      );

      final layered = collectLayeredDirectKittyPlacements(
        target,
        cellWidth: 10.0,
        cellHeight: 20.0,
      );
      expect(layered.fgPlacements, hasLength(3));
      // Row 1 (top of pane): col 1 unoccluded, cols 2..3 occluded by modal, col 4 unoccluded.
      final row1Quads = layered.fgPlacements
          .where((q) => (q.dstY - 20.0).abs() < 1e-6)
          .toList();
      expect(row1Quads, hasLength(2));
      expect(row1Quads[0].dstX, closeTo(10.0, 1e-6));
      expect(row1Quads[0].dstWidth, closeTo(10.0, 1e-6));
      expect(row1Quads[0].u0, closeTo(0.0, 1e-6));
      expect(row1Quads[0].u1, closeTo(1.0 / 6.0, 1e-6));

      expect(row1Quads[1].dstX, closeTo(40.0, 1e-6));
      expect(row1Quads[1].dstWidth, closeTo(10.0, 1e-6));
      expect(row1Quads[1].u0, closeTo(3.0 / 6.0, 1e-6));
      expect(row1Quads[1].u1, closeTo(4.0 / 6.0, 1e-6));

      // Row 2: full unoccluded clipped span cols 1..4 (4 of 6 placement cols).
      final row2Quads = layered.fgPlacements
          .where((q) => (q.dstY - 40.0).abs() < 1e-6)
          .toList();
      expect(row2Quads, hasLength(1));
      expect(row2Quads[0].dstX, closeTo(10.0, 1e-6));
      expect(row2Quads[0].dstWidth, closeTo(40.0, 1e-6));
      expect(row2Quads[0].u0, closeTo(0.0, 1e-6));
      expect(row2Quads[0].u1, closeTo(4.0 / 6.0, 1e-6));
    });

    test(
      'resolves relative P,Q,H,V chains and safely skips cyclic placements',
      () {
        final reg = KittyImageRegistry();
        reg.registerImage(_makeSolidKittyData(imageId: 1, r: 255, g: 0, b: 0));
        reg.registerImage(_makeSolidKittyData(imageId: 2, r: 0, g: 255, b: 0));
        reg.registerImage(_makeSolidKittyData(imageId: 3, r: 0, g: 0, b: 255));

        // Root parent at (2, 1)
        reg.registerPlacement(
          const KittyPlacement(
            imageId: 1,
            placementId: 1,
            gridCol: 2,
            gridRow: 1,
            cols: 1,
            rows: 1,
            zIndex: 1,
          ),
        );
        // Relative child (+3, +1) -> (5, 2) with z=0 (still rendered because isRelative!)
        reg.registerPlacement(
          const KittyPlacement(
            imageId: 2,
            placementId: 2,
            cols: 1,
            rows: 1,
            parentImageId: 1,
            parentPlacementId: 1,
            relCols: 3,
            relRows: 1,
          ),
        );
        // Cyclic pair (3, 1) <-> (3, 2) must be omitted safely.
        reg.registerPlacement(
          const KittyPlacement(
            imageId: 3,
            placementId: 1,
            cols: 1,
            rows: 1,
            parentImageId: 3,
            parentPlacementId: 2,
            relCols: 1,
            zIndex: 2,
          ),
        );
        reg.registerPlacement(
          const KittyPlacement(
            imageId: 3,
            placementId: 2,
            cols: 1,
            rows: 1,
            parentImageId: 3,
            parentPlacementId: 1,
            relCols: 1,
            zIndex: 2,
          ),
        );

        final buf = Buffer.blank(10, 5);
        buf.registerKittyRegistry(const tui_geo.Rect(0, 0, 10, 5), reg);
        final layered = collectLayeredDirectKittyPlacements(
          buf,
          cellWidth: 10.0,
          cellHeight: 20.0,
        );
        expect(layered.fgPlacements, hasLength(2));
        // Sorted by (zIndex, imageId, placementId): z=0 child first, z=1 parent second.
        final child = layered.fgPlacements[0];
        expect(child.placement.imageId, equals(2));
        expect(child.dstX, closeTo(50.0, 1e-6));
        expect(child.dstY, closeTo(40.0, 1e-6));
      },
    );
  });

  group('3-Pass Z-order CPU painter and GPU batch parity', () {
    test('TuiAtlasPainter paints z=-1073741825 under cell bg, z=-1 behind text, and z=1 over text', () async {
      final atlas = await GlyphAtlasGenerator.generate(
        fontFamily: 'monospace',
        fontSize: 14.0,
        devicePixelRatio: 1.0,
      );
      final reg = KittyImageRegistry();
      final greenData = _makeSolidKittyData(
        imageId: 1,
        r: 0,
        g: 255,
        b: 0,
        gridCols: 2,
        gridRows: 1,
      );
      final redData = _makeSolidKittyData(imageId: 2, r: 255, g: 0, b: 0);
      final yellowData = _makeSolidKittyData(imageId: 3, r: 255, g: 255, b: 0);
      reg.registerImage(greenData);
      reg.registerImage(redData);
      reg.registerImage(yellowData);

      // z = -1073741825 across cols 0..1 (under non-default cell bg)
      reg.registerPlacement(
        const KittyPlacement(
          imageId: 1,
          placementId: 1,
          gridCol: 0,
          gridRow: 0,
          cols: 2,
          rows: 1,
          zIndex: KittyPlacement.underBackgroundZThreshold - 1,
        ),
      );
      // z = -1 across cols 2..3 (above blue cell bg, under white 'M' text)
      reg.registerPlacement(
        const KittyPlacement(
          imageId: 2,
          placementId: 1,
          gridCol: 2,
          gridRow: 0,
          cols: 2,
          rows: 1,
          zIndex: -1,
        ),
      );
      // z = 1 at col 4 (above white 'M' text)
      reg.registerPlacement(
        const KittyPlacement(
          imageId: 3,
          placementId: 1,
          gridCol: 4,
          gridRow: 0,
          cols: 1,
          rows: 1,
          zIndex: 1,
        ),
      );

      final buf = Buffer.blank(5, 1);
      buf.registerKittyRegistry(const tui_geo.Rect(0, 0, 5, 1), reg);
      // Col 0: default bg -> green z=-1073741825 shows through.
      // Col 1: opaque blue cell bg -> blue covers green z=-1073741825.
      buf.setCell(1, 0, ' ', 0xFFFFFFFF, 0xFF0000FF, Modifier.none);
      // Col 2: opaque blue bg + space -> red z=-1 covers blue bg.
      buf.setCell(2, 0, ' ', 0xFFFFFFFF, 0xFF0000FF, Modifier.none);
      // Col 3: opaque blue bg + white 'M' -> white 'M' draws on top of red z=-1.
      buf.setCell(3, 0, 'M', 0xFFFFFFFF, 0xFF0000FF, Modifier.none);
      // Col 4: white 'M' -> yellow z=1 covers 'M' completely.
      buf.setCell(4, 0, 'M', 0xFFFFFFFF, 0xFF000000, Modifier.none);

      final greenImg = await _decodeRgba(greenData.rgbaPixels, 8, 8);
      final redImg = await _decodeRgba(redData.rgbaPixels, 8, 8);
      final yellowImg = await _decodeRgba(yellowData.rgbaPixels, 8, 8);
      final kittyImages = <KittyImageData, ui.Image>{
        greenData: greenImg,
        redData: redImg,
        yellowData: yellowImg,
      };

      try {
        final painter = TuiAtlasPainter(
          buffer: buf,
          atlas: atlas,
          fontFamily: 'monospace',
          fallbackPainters: {},
          onMissingGlyphs: null,
          kittyImages: kittyImages,
          defaultBackgroundArgb: 0xFF000000,
        );
        final w = (buf.width * atlas.cellWidth).ceil();
        final h = (buf.height * atlas.cellHeight).ceil();
        final rgba = await _renderPainterRgba(painter);
        final cw = atlas.cellWidth.floor();

        // Col 0: green visible over default black bg.
        expect(
          _regionContainsColor(rgba, w, h, 1, 1, cw - 1, h - 1, 0, 255, 0),
          isTrue,
        );
        // Col 1: opaque blue cell bg covers green z=-1073741825.
        expect(
          _regionContainsColor(
            rgba,
            w,
            h,
            cw + 1,
            1,
            cw * 2 - 1,
            h - 1,
            0,
            0,
            255,
          ),
          isTrue,
        );
        expect(
          _regionContainsColor(
            rgba,
            w,
            h,
            cw + 1,
            1,
            cw * 2 - 1,
            h - 1,
            0,
            255,
            0,
          ),
          isFalse,
        );
        // Col 2: red z=-1 covers opaque blue cell bg.
        expect(
          _regionContainsColor(
            rgba,
            w,
            h,
            cw * 2 + 1,
            1,
            cw * 3 - 1,
            h - 1,
            255,
            0,
            0,
          ),
          isTrue,
        );
        expect(
          _regionContainsColor(
            rgba,
            w,
            h,
            cw * 2 + 1,
            1,
            cw * 3 - 1,
            h - 1,
            0,
            0,
            255,
          ),
          isFalse,
        );
        // Col 3: white 'M' paints on top of red z=-1.
        final whiteInkCol3 = _countRegionPixels(
          rgba,
          w,
          h,
          cw * 3,
          0,
          cw * 4,
          h,
          (r, g, b, a) => a > 200 && r > 180 && g > 180 && b > 180,
        );
        expect(whiteInkCol3, greaterThan(0));
        // Col 4: yellow z=1 covers white 'M' completely.
        expect(
          _regionContainsColor(
            rgba,
            w,
            h,
            cw * 4 + 1,
            1,
            cw * 5 - 1,
            h - 1,
            255,
            255,
            0,
          ),
          isTrue,
        );
        final whiteInkCol4 = _countRegionPixels(
          rgba,
          w,
          h,
          cw * 4 + 1,
          1,
          cw * 5 - 1,
          h - 1,
          (r, g, b, a) => a > 200 && r > 200 && g > 200 && b > 200,
        );
        expect(whiteInkCol4, equals(0));

        // Verify GpuAtlasBatchBuilder produces all 3 quad layers and bumps generation on revision change.
        final builder = GpuAtlasBatchBuilder();
        final batch1 = painter.stageForGpu(
          Size(w.toDouble(), h.toDouble()),
          1.0,
          builder,
        );
        expect(batch1.underBgKittyQuads, hasLength(1));
        expect(batch1.bgKittyQuads, hasLength(1));
        expect(batch1.kittyQuads, hasLength(1));
        expect(batch1.hasCanvasOnlyContent, isFalse);

        // Bump registry revision (e.g. animation step or placement update) -> generation increments.
        reg.registerPlacement(
          const KittyPlacement(
            imageId: 3,
            placementId: 1,
            gridCol: 3,
            gridRow: 0,
            cols: 1,
            rows: 1,
            srcX: 2,
            srcY: 2,
            srcWidth: 4,
            srcHeight: 4,
            zIndex: 1,
          ),
        );
        final batch2 = painter.stageForGpu(
          Size(w.toDouble(), h.toDouble()),
          1.0,
          builder,
        );
        expect(batch2.generation, greaterThan(batch1.generation));
        expect(batch2.kittyQuads.first.u0, closeTo(0.25, 1e-6));
        expect(batch2.kittyQuads.first.u1, closeTo(0.75, 1e-6));
      } finally {
        greenImg.dispose();
        redImg.dispose();
        yellowImg.dispose();
        atlas.dispose();
      }
    });
  });

  group('Kitty animations: stable frame identity and TerminalSurface timer lifecycle', () {
    test(
      'GpuAtlasBatchBuilder tracks active animation frame and bumps generation',
      () async {
        final atlas = await GlyphAtlasGenerator.generate(
          fontFamily: 'monospace',
          fontSize: 14.0,
          devicePixelRatio: 1.0,
        );
        final reg = KittyImageRegistry();
        final frame1Data = _makeSolidKittyData(
          imageId: 7,
          r: 255,
          g: 0,
          b: 0,
          version: 1,
        );
        final frame2Data = _makeSolidKittyData(
          imageId: 7,
          r: 0,
          g: 0,
          b: 255,
          version: 2,
        );
        reg.registerImage(frame1Data);
        reg.registerAnimationFrame(
          7,
          KittyAnimationFrame(frameNumber: 1, imageData: frame1Data, gapMs: 50),
        );
        reg.registerAnimationFrame(
          7,
          KittyAnimationFrame(frameNumber: 2, imageData: frame2Data, gapMs: 50),
        );
        reg.setAnimationPlayback(7, playback: KittyAnimationPlayback.running);
        reg.registerPlacement(
          const KittyPlacement(
            imageId: 7,
            placementId: 1,
            gridCol: 0,
            gridRow: 0,
            cols: 1,
            rows: 1,
            zIndex: 1,
          ),
        );

        final img1 = await _decodeRgba(frame1Data.rgbaPixels, 8, 8);
        final img2 = await _decodeRgba(frame2Data.rgbaPixels, 8, 8);
        final buf = Buffer.blank(4, 2);
        buf.registerKittyRegistry(const tui_geo.Rect(0, 0, 4, 2), reg);

        try {
          final painter = TuiAtlasPainter(
            buffer: buf,
            atlas: atlas,
            fontFamily: 'monospace',
            fallbackPainters: {},
            onMissingGlyphs: null,
            kittyImages: {frame1Data: img1, frame2Data: img2},
          );
          final builder = GpuAtlasBatchBuilder();
          final b1 = painter.stageForGpu(const Size(40, 40), 1.0, builder);
          expect(b1.kittyQuads, hasLength(1));
          expect(identical(b1.kittyQuads.first.image, img1), isTrue);

          // Advance animation past frame 1's 50ms gap -> activeImageData switches to stable frame2Data.
          reg.advanceAnimations(1000);
          expect(reg.advanceAnimations(1060), isTrue);
          expect(identical(reg.activeImageData(7), frame2Data), isTrue);

          final b2 = painter.stageForGpu(const Size(40, 40), 1.0, builder);
          expect(b2.generation, greaterThan(b1.generation));
          expect(identical(b2.kittyQuads.first.image, img2), isTrue);
        } finally {
          img1.dispose();
          img2.dispose();
          atlas.dispose();
        }
      },
    );

    testWidgets(
      'TerminalSurface runs single animation timer only while running and cancels on stop/dispose',
      (tester) async {
        final reg = KittyImageRegistry();
        final frame1Data = _makeSolidKittyData(imageId: 42, r: 255, g: 0, b: 0);
        final frame2Data = _makeSolidKittyData(imageId: 42, r: 0, g: 255, b: 0);
        reg.registerImage(frame1Data);
        reg.registerAnimationFrame(
          42,
          KittyAnimationFrame(frameNumber: 1, imageData: frame1Data, gapMs: 30),
        );
        reg.registerAnimationFrame(
          42,
          KittyAnimationFrame(frameNumber: 2, imageData: frame2Data, gapMs: 30),
        );
        reg.registerPlacement(
          const KittyPlacement(
            imageId: 42,
            placementId: 1,
            gridCol: 0,
            gridRow: 0,
            cols: 2,
            rows: 1,
            zIndex: 1,
          ),
        );

        final buf = Buffer.blank(10, 4);
        buf.registerKittyRegistry(const tui_geo.Rect(0, 0, 10, 4), reg);
        final surfaceKey = GlobalKey<TerminalSurfaceState>();

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 200,
              height: 120,
              child: TerminalSurface(key: surfaceKey, buffer: buf),
            ),
          ),
        );
        await tester.pump();

        // Stopped animation -> timer must NOT be running.
        expect(
          surfaceKey.currentState!.debugIsKittyAnimationTimerActive,
          isFalse,
        );

        // Start a 1-loop finite animation and prepare buffer -> timer activates, steps frame, then stops!
        reg.setAnimationPlayback(
          42,
          playback: KittyAnimationPlayback.running,
          loopCount: 1,
        );
        surfaceKey.currentState!.prepareBuffer(buf);
        expect(
          surfaceKey.currentState!.debugIsKittyAnimationTimerActive,
          isTrue,
        );

        // Step through frames via FakeAsync clock.
        await tester.pump(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 40));
        expect(identical(reg.activeImageData(42), frame2Data), isTrue);

        // Let the single loop finish -> timer stops itself automatically.
        await tester.pump(const Duration(milliseconds: 60));
        expect(reg.hasRunningAnimations, isFalse);
        expect(
          surfaceKey.currentState!.debugIsKittyAnimationTimerActive,
          isFalse,
        );

        // Start infinite loop and unmount -> dispose cancels timer cleanly with zero leaks.
        reg.setAnimationPlayback(
          42,
          playback: KittyAnimationPlayback.running,
          loopCount: 0,
        );
        surfaceKey.currentState!.prepareBuffer(buf);
        expect(
          surfaceKey.currentState!.debugIsKittyAnimationTimerActive,
          isTrue,
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  });

  group(
    'OSC 66 scaled text rendering and row-fingerprint cache invalidation',
    () {
      test('computeRowFingerprint invalidates cleanly when OSC 66 scale or alignment changes', () {
        final cache = TuiAtlasStagingCache();
        final buf = Buffer.blank(8, 2)..writeString(0, 0, 'A', Style.empty);

        final fpNormal = cache.computeRowFingerprint(
          buffer: buf,
          row: 0,
          selectionHash: 0,
          hoveredLinkHash: 0,
          configHash: 1,
        );

        // Attach OSC 66 2x sizing on identical character 'A'.
        buf.setTextSizing(0, 0, KittyTextSizing.pack(scale: 2).bits);
        final fpScale2 = cache.computeRowFingerprint(
          buffer: buf,
          row: 0,
          selectionHash: 0,
          hoveredLinkHash: 0,
          configHash: 1,
        );
        expect(fpScale2, isNot(equals(fpNormal)));

        // Changing fractional numerator/denominator invalidates fingerprint.
        buf.setTextSizing(
          0,
          0,
          KittyTextSizing.pack(scale: 2, numerator: 1, denominator: 2).bits,
        );
        final fpFrac = cache.computeRowFingerprint(
          buffer: buf,
          row: 0,
          selectionHash: 0,
          hoveredLinkHash: 0,
          configHash: 1,
        );
        expect(fpFrac, isNot(equals(fpScale2)));

        // Changing alignment invalidates fingerprint.
        buf.setTextSizing(
          0,
          0,
          KittyTextSizing.pack(
            scale: 2,
            numerator: 1,
            denominator: 2,
            vAlign: 2,
            hAlign: 2,
          ).bits,
        );
        final fpAligned = cache.computeRowFingerprint(
          buffer: buf,
          row: 0,
          selectionHash: 0,
          hoveredLinkHash: 0,
          configHash: 1,
        );
        expect(fpAligned, isNot(equals(fpFrac)));

        // Unmodified row 1 stays identical.
        final fpRow1 = cache.computeRowFingerprint(
          buffer: buf,
          row: 1,
          selectionHash: 0,
          hoveredLinkHash: 0,
          configHash: 1,
        );
        expect(
          cache.computeRowFingerprint(
            buffer: buf,
            row: 1,
            selectionHash: 0,
            hoveredLinkHash: 0,
            configHash: 1,
          ),
          equals(fpRow1),
        );
      });

      test('paints OSC 66 2x and fractional 1/2 anchors, skips continuations, caches painters, and triggers GPU fallback', () async {
        final atlas = await GlyphAtlasGenerator.generate(
          fontFamily: 'monospace',
          fontSize: 14.0,
          devicePixelRatio: 1.0,
        );
        try {
          final buf = Buffer.blank(6, 3);
          // 2x scaled 'H' occupying 2x2 cells at (0,0)..(1,1)
          buf.setCell(0, 0, 'H', 0xFFFFFFFF, 0xFF000000, Modifier.none);
          buf.setTextSizing(0, 0, KittyTextSizing.pack(scale: 2).bits);
          for (var dy = 0; dy < 2; dy++) {
            for (var dx = 0; dx < 2; dx++) {
              if (dx == 0 && dy == 0) continue;
              // Put a stray red char in continuation cell to verify continuations are skipped!
              buf.setCell(dx, dy, 'Z', 0xFFFF0000, 0xFF000000, Modifier.none);
              buf.setTextSizing(
                dx,
                dy,
                KittyTextSizing.pack(
                  scale: 2,
                  isContinuation: true,
                  originDx: dx,
                  originDy: dy,
                ).bits,
              );
            }
          }

          // Fractional 1/2 scaled 'H' at (3,0) centered in 1x1 cell
          buf.setCell(3, 0, 'H', 0xFF00FF00, 0xFF000000, Modifier.none);
          buf.setTextSizing(
            3,
            0,
            KittyTextSizing.pack(
              scale: 1,
              numerator: 1,
              denominator: 2,
              vAlign: 2,
              hAlign: 2,
            ).bits,
          );

          final stagingCache = TuiAtlasStagingCache();
          final painter = TuiAtlasPainter(
            buffer: buf,
            atlas: atlas,
            stagingCache: stagingCache,
            fontFamily: 'monospace',
            fallbackPainters: {},
            onMissingGlyphs: null,
            defaultBackgroundArgb: 0xFF000000,
          );
          final w = (buf.width * atlas.cellWidth).ceil();
          final h = (buf.height * atlas.cellHeight).ceil();
          final rgba = await _renderPainterRgba(painter);
          final cw = atlas.cellWidth.floor();
          final ch = atlas.cellHeight.floor();

          // 2x 'H' draws white ink spanning into row 1 of the 2x2 box.
          final whiteInk2x = _countRegionPixels(
            rgba,
            w,
            h,
            0,
            0,
            cw * 2,
            ch * 2,
            (r, g, b, a) => a > 128 && r > 150 && g > 150 && b > 150,
          );
          expect(whiteInk2x, greaterThan(0));

          // Stray red continuation cells must NOT paint any red ink.
          final redContinuationInk = _countRegionPixels(
            rgba,
            w,
            h,
            0,
            0,
            cw * 2,
            ch * 2,
            (r, g, b, a) => a > 128 && r > 180 && g < 60 && b < 60,
          );
          expect(redContinuationInk, equals(0));

          // Fractional 1/2 green 'H' at col 3 paints fewer green pixels than 2x 'H'.
          final greenInkHalf = _countRegionPixels(
            rgba,
            w,
            h,
            cw * 3,
            0,
            cw * 4,
            ch,
            (r, g, b, a) => a > 100 && g > 120 && r < 80,
          );
          expect(greenInkHalf, greaterThan(0));
          expect(greenInkHalf, lessThan(whiteInk2x));

          // _osc66PainterCache cached both entries (bounded at <= 256).
          expect(TuiAtlasPainter.debugOsc66PainterCacheLength, equals(2));

          // GPU batch marks OSC 66 anchor frame as hasCanvasOnlyContent.
          final builder = GpuAtlasBatchBuilder();
          final batch = painter.stageForGpu(
            Size(w.toDouble(), h.toDouble()),
            1.0,
            builder,
          );
          expect(batch.hasCanvasOnlyContent, isTrue);

          // Row cache hits cleanly on identical second paint, misses only dirty row on scale change.
          await _renderPainterRgba(painter);
          expect(stagingCache.lastRowHits, equals(3));
          expect(stagingCache.lastRowMisses, equals(0));

          buf.setTextSizing(
            3,
            0,
            KittyTextSizing.pack(scale: 1, numerator: 2, denominator: 3).bits,
          );
          await _renderPainterRgba(painter);
          expect(stagingCache.lastRowMisses, equals(1));
          expect(stagingCache.lastRowHits, equals(2));
        } finally {
          atlas.dispose();
        }
      });
    },
  );

  group('Wave 3 review regressions', () {
    test('Major #1: KittyTextureUploadCache retains sibling animation frame slots without eviction (RGBA32 & PNG)', () async {
      final atlas = await GlyphAtlasGenerator.generate(
        fontFamily: 'monospace',
        fontSize: 14.0,
        devicePixelRatio: 1.0,
      );
      final reg = KittyImageRegistry();
      final frame1Data = _makeSolidKittyData(
        imageId: 55,
        r: 255,
        g: 0,
        b: 0,
        version: 1,
      );
      // Frame 2 uses formatPng (rawRgbaPixels == null on GpuKittyQuad) to prove
      // primed non-RGBA animation frames are not evicted by frame 1's slot.
      final frame2Data = KittyImageData.fromPng(
        imageId: 55,
        pixelWidth: 8,
        pixelHeight: 8,
        pngBytes: Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]),
        gridCols: 1,
        gridRows: 1,
        version: 2,
      );
      reg.registerImage(frame1Data);
      reg.registerAnimationFrame(
        55,
        KittyAnimationFrame(frameNumber: 1, imageData: frame1Data, gapMs: 40),
      );
      reg.registerAnimationFrame(
        55,
        KittyAnimationFrame(frameNumber: 2, imageData: frame2Data, gapMs: 40),
      );
      reg.setAnimationPlayback(55, playback: KittyAnimationPlayback.running);
      reg.registerPlacement(
        const KittyPlacement(
          imageId: 55,
          placementId: 1,
          gridCol: 0,
          gridRow: 0,
          cols: 1,
          rows: 1,
          zIndex: 1,
        ),
      );

      final img1 = await _decodeRgba(frame1Data.rgbaPixels, 8, 8);
      final img2 = await _decodeRgba(_solidRgba(8, 8, 0, 0, 255), 8, 8);
      final buf = Buffer.blank(4, 2);
      buf.registerKittyRegistry(const tui_geo.Rect(0, 0, 4, 2), reg);
      // Also place a U+10EEEE cell for the same animated imageId to test both paths.
      buf.setCell(
        2,
        0,
        kittyPlaceholderCell(0, 0),
        0xFF000000 | 55,
        0xFF000000,
        Modifier.kittyPlaceholder,
      );

      try {
        final painter = TuiAtlasPainter(
          buffer: buf,
          atlas: atlas,
          fontFamily: 'monospace',
          fallbackPainters: {},
          onMissingGlyphs: null,
          kittyImages: {frame1Data: img1, frame2Data: img2},
        );
        final builder = GpuAtlasBatchBuilder();
        final cache = KittyTextureUploadCache<String>(initialCapacity: 8);
        // Pre-prime PNG frame 2 texture (which has rawRgbaPixels == null).
        cache.store(img2, 'tex_png_f2');
        var uploadCount = 0;

        // Frame 1: both U+10EEEE and direct placement quads use frame-1 slot.
        final b1 = painter.stageForGpu(const Size(40, 40), 1.0, builder);
        expect(b1.kittyQuads, hasLength(2));
        expect(b1.kittyQuads[0].cacheSlot, equals((reg, 55, 1)));
        expect(b1.kittyQuads[1].cacheSlot, equals((reg, 55, 1)));
        final r1 = cache.resolveQuads(
          b1.kittyQuads,
          uploadRawRgba: (w, h, bytes) => 'tex_rgba_${++uploadCount}',
        );
        expect(r1, equals(['tex_rgba_1', 'tex_rgba_1']));
        expect(uploadCount, equals(1));
        expect(cache.contains(img1), isTrue);
        expect(cache.contains(img2), isTrue);

        // Step to frame 2 (rawRgbaPixels == null): frame 2 hits primed cache and
        // must NOT evict frame 1!
        reg.advanceAnimations(1000);
        expect(reg.advanceAnimations(1050), isTrue);
        final b2 = painter.stageForGpu(const Size(40, 40), 1.0, builder);
        expect(b2.kittyQuads[0].rawRgbaPixels, isNull);
        expect(b2.kittyQuads[0].cacheSlot, equals((reg, 55, 2)));
        expect(b2.kittyQuads[1].cacheSlot, equals((reg, 55, 2)));
        final r2 = cache.resolveQuads(
          b2.kittyQuads,
          uploadRawRgba: (w, h, bytes) => 'tex_rgba_${++uploadCount}',
        );
        expect(r2, equals(['tex_png_f2', 'tex_png_f2']));
        expect(cache.contains(img1), isTrue);
        expect(cache.contains(img2), isTrue);

        // Loop back to frame 1: hits cache with ZERO additional uploads and keeps frame 2!
        expect(reg.advanceAnimations(1100), isTrue);
        final b3 = painter.stageForGpu(const Size(40, 40), 1.0, builder);
        final r3 = cache.resolveQuads(
          b3.kittyQuads,
          uploadRawRgba: (w, h, bytes) => 'tex_rgba_${++uploadCount}',
        );
        expect(r3, equals(['tex_rgba_1', 'tex_rgba_1']));
        expect(uploadCount, equals(1));
        expect(cache.contains(img2), isTrue);
      } finally {
        img1.dispose();
        img2.dispose();
        atlas.dispose();
      }
    });

    testWidgets(
      'Major #2: two TerminalSurface widgets sharing one KittyImageRegistry both repaint across ticks and on final frame',
      (tester) async {
        final reg = KittyImageRegistry();
        final frame1Data = _makeSolidKittyData(imageId: 88, r: 255, g: 0, b: 0);
        final frame2Data = _makeSolidKittyData(imageId: 88, r: 0, g: 255, b: 0);
        reg.registerImage(frame1Data);
        reg.registerAnimationFrame(
          88,
          KittyAnimationFrame(frameNumber: 1, imageData: frame1Data, gapMs: 30),
        );
        reg.registerAnimationFrame(
          88,
          KittyAnimationFrame(frameNumber: 2, imageData: frame2Data, gapMs: 30),
        );
        reg.setAnimationPlayback(
          88,
          playback: KittyAnimationPlayback.running,
          loopCount: 1,
        );
        reg.registerPlacement(
          const KittyPlacement(
            imageId: 88,
            placementId: 1,
            gridCol: 0,
            gridRow: 0,
            cols: 1,
            rows: 1,
            zIndex: 1,
          ),
        );

        final bufA = Buffer.blank(8, 3);
        bufA.registerKittyRegistry(const tui_geo.Rect(0, 0, 8, 3), reg);
        final bufB = Buffer.blank(8, 3);
        bufB.registerKittyRegistry(const tui_geo.Rect(0, 0, 8, 3), reg);

        final keyA = GlobalKey<TerminalSurfaceState>();
        final keyB = GlobalKey<TerminalSurfaceState>();

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Row(
              children: [
                SizedBox(
                  width: 120,
                  height: 80,
                  child: TerminalSurface(key: keyA, buffer: bufA),
                ),
                SizedBox(
                  width: 120,
                  height: 80,
                  child: TerminalSurface(key: keyB, buffer: bufB),
                ),
              ],
            ),
          ),
        );
        await tester.pump();
        keyA.currentState!.prepareBuffer(bufA);
        keyB.currentState!.prepareBuffer(bufB);
        expect(keyA.currentState!.debugIsKittyAnimationTimerActive, isTrue);
        expect(keyB.currentState!.debugIsKittyAnimationTimerActive, isTrue);

        final vA0 = keyA.currentState!.debugPaintNotifyVersion;
        final vB0 = keyB.currentState!.debugPaintNotifyVersion;

        // First step: frame 1 -> frame 2. Both surfaces must repaint!
        await tester.pump(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 40));
        expect(identical(reg.activeImageData(88), frame2Data), isTrue);
        final vA1 = keyA.currentState!.debugPaintNotifyVersion;
        final vB1 = keyB.currentState!.debugPaintNotifyVersion;
        expect(vA1, greaterThan(vA0));
        expect(vB1, greaterThan(vB0));

        // Final step: finite loop completes -> both surfaces repaint final frame and stop timers!
        await tester.pump(const Duration(milliseconds: 60));
        expect(reg.hasRunningAnimations, isFalse);
        expect(keyA.currentState!.debugPaintNotifyVersion, greaterThan(vA1));
        expect(keyB.currentState!.debugPaintNotifyVersion, greaterThan(vB1));
        expect(keyA.currentState!.debugIsKittyAnimationTimerActive, isFalse);
        expect(keyB.currentState!.debugIsKittyAnimationTimerActive, isFalse);
      },
    );

    test('Minor #5: fractional cell widths do not spuriously include adjacent occluded columns', () {
      final paneReg = KittyImageRegistry();
      final neighborReg = KittyImageRegistry();
      paneReg.registerImage(
        _makeSolidKittyData(imageId: 91, r: 0, g: 200, b: 0),
      );
      // Placement covers cols [1, 3) on row 0; neighbor starts at col 3.
      // With cellWidth = 8.4, (3 * 8.4) / 8.4 can incur floating-point drift;
      // epsilon bias prevents col 3 from being checked for occlusion.
      paneReg.registerPlacement(
        const KittyPlacement(
          imageId: 91,
          placementId: 1,
          gridCol: 1,
          gridRow: 0,
          cols: 2,
          rows: 1,
          zIndex: 1,
        ),
      );

      final buf = Buffer.blank(6, 2);
      buf.registerKittyRegistry(const tui_geo.Rect(0, 0, 3, 2), paneReg);
      buf.registerKittyRegistry(const tui_geo.Rect(3, 0, 3, 2), neighborReg);

      final layered = collectLayeredDirectKittyPlacements(
        buf,
        cellWidth: 8.4,
        cellHeight: 16.8,
      );
      // Should emit ONE unoccluded quad (not split by a phantom col 3 check).
      expect(layered.fgPlacements, hasLength(1));
      expect(layered.fgPlacements.first.dstX, closeTo(8.4, 1e-6));
      expect(layered.fgPlacements.first.dstWidth, closeTo(16.8, 1e-6));
    });

    test('Minor #6: pre-decode U+10EEEE RGBA32 subpixel fallback applies KittyPlacement crop and X/Y offset', () async {
      final atlas = await GlyphAtlasGenerator.generate(
        fontFamily: 'monospace',
        fontSize: 14.0,
        devicePixelRatio: 1.0,
      );
      try {
        // 8x8 RGBA32 image: left half (x 0..3) solid red, right half (x 4..7) solid green.
        final pixels = Uint8List(8 * 8 * 4);
        for (var y = 0; y < 8; y++) {
          for (var x = 0; x < 8; x++) {
            final off = (y * 8 + x) * 4;
            if (x < 4) {
              pixels[off] = 255;
              pixels[off + 1] = 0;
              pixels[off + 2] = 0;
              pixels[off + 3] = 255;
            } else {
              pixels[off] = 0;
              pixels[off + 1] = 255;
              pixels[off + 2] = 0;
              pixels[off + 3] = 255;
            }
          }
        }
        final data = KittyImageData(
          imageId: 92,
          pixelWidth: 8,
          pixelHeight: 8,
          rgbaPixels: pixels,
          gridCols: 1,
          gridRows: 1,
        );
        final reg = KittyImageRegistry()..registerImage(data);
        // Crop exclusively to the green right half (srcX=4, srcWidth=4) and shift by X=3, Y=4.
        reg.registerPlacement(
          const KittyPlacement(
            imageId: 92,
            placementId: 5,
            cols: 1,
            rows: 1,
            srcX: 4,
            srcY: 0,
            srcWidth: 4,
            srcHeight: 8,
            cellOffsetX: 3,
            cellOffsetY: 4,
          ),
        );

        final buf = Buffer.blank(3, 2);
        buf.registerKittyRegistry(const tui_geo.Rect(0, 0, 3, 2), reg);
        buf.setCell(
          0,
          0,
          kittyPlaceholderCell(0, 0),
          0xFF000000 | 92,
          0xFF000000,
          Modifier.kittyPlaceholder,
          underlineColor: 0xFF000000 | 5,
        );

        // Empty kittyImages forces the pre-decode RGBA32 subpixel fallback path!
        final painter = TuiAtlasPainter(
          buffer: buf,
          atlas: atlas,
          fontFamily: 'monospace',
          fallbackPainters: {},
          onMissingGlyphs: null,
          kittyImages: const {},
          defaultBackgroundArgb: 0xFF000000,
        );
        final w = (buf.width * atlas.cellWidth).ceil();
        final h = (buf.height * atlas.cellHeight).ceil();
        final rgba = await _renderPainterRgba(painter);

        // Offset (X=3, Y=4): top-left pixels [0..2]x[0..3] must remain black (no ink before offset).
        expect(
          _regionContainsColor(rgba, w, h, 0, 0, 2, 3, 0, 255, 0),
          isFalse,
        );
        // Shifted region inside [3..3+cw) x [4..4+ch) must be GREEN (cropped right half) with ZERO RED!
        expect(
          _regionContainsColor(
            rgba,
            w,
            h,
            3,
            4,
            3 + atlas.cellWidth.floor(),
            4 + atlas.cellHeight.floor(),
            0,
            255,
            0,
          ),
          isTrue,
        );
        expect(
          _regionContainsColor(rgba, w, h, 0, 0, w, h, 255, 0, 0),
          isFalse,
        );
      } finally {
        atlas.dispose();
      }
    });
  });
}
