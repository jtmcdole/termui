import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:termui/ui/widgets/core/geometry.dart' as tui_geo;
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/widgets/display/kitty_image.dart';
import 'package:termui_flutter/src/rendering/atlas.dart';
import 'package:termui_flutter/src/rendering/gpu_atlas_batch.dart';
import 'package:termui_flutter/src/rendering/gpu_atlas_shaders.dart';
import 'package:termui_flutter/src/rendering/painter.dart';
import 'package:termui_flutter/src/rendering/staging_cache.dart';

Future<ui.Image> _makeTestImage(int width, int height) {
  final completer = Completer<ui.Image>();
  final pixels = Uint8List(width * height * 4);
  for (var i = 0; i < pixels.length; i += 4) {
    pixels[i] = 255;
    pixels[i + 1] = 128;
    pixels[i + 2] = 64;
    pixels[i + 3] = 255;
  }
  ui.decodeImageFromPixels(
    pixels,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

List<double> _instanceAt(GpuAtlasQuadBatch batch, int index) {
  final base = index * GpuAtlasQuadBatch.floatsPerInstance;
  return batch.instanceData.sublist(
    base,
    base + GpuAtlasQuadBatch.floatsPerInstance,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TuiAtlasStagingCache.generation', () {
    test(
      'increments on resize, invalidation, and dirty rows; stable on hits',
      () {
        final cache = TuiAtlasStagingCache();
        final internals = stagingCacheInternalsOf(cache);
        final gen0 = cache.generation;

        cache.ensureGridCapacity(10, 4);
        final genAfterResize = cache.generation;
        expect(genAfterResize, greaterThan(gen0));

        // Same dimensions: no generation bump.
        cache.ensureGridCapacity(10, 4);
        expect(cache.generation, equals(genAfterResize));

        // Dirty row commit increments generation.
        internals.commitFrame(4, 3, 1);
        final genAfterMiss = cache.generation;
        expect(genAfterMiss, greaterThan(genAfterResize));

        // All-hit frame does not increment generation.
        internals.recordAllHits(4);
        expect(cache.generation, equals(genAfterMiss));
        internals.commitFrame(4, 4, 0);
        expect(cache.generation, equals(genAfterMiss));

        // Full invalidation increments generation.
        cache.invalidateAllRows();
        expect(cache.generation, greaterThan(genAfterMiss));
      },
    );
  });

  group('GpuAtlasBatchBuilder', () {
    test('packs backdrop, bg, fg, emoji, italic (+bold), deco, and dimming in exact order', () {
      final builder = GpuAtlasBatchBuilder();
      final staged = StagingBufferSet()..ensureGridCapacity(4, 16);
      final buffer = Buffer(10, 4);

      // 1 bg sprite: scale=0.5, tx=8, ty=16, src=(0,0,20,40), color=0x80FF0080 (50% alpha)
      staged.addBgSprite(0.5, 8.0, 16.0, 0.0, 0.0, 20.0, 40.0, 0x80FF0080);
      // 1 fg sprite: scale=0.5, tx=16, ty=16, src=(20,40,40,80), color=0xFF00FF00
      staged.addFgSprite(0.5, 16.0, 16.0, 20.0, 40.0, 40.0, 80.0, 0xFF00FF00);
      // 1 emoji sprite: untinted (1,1,1,1)
      staged.addEmojiSprite(0.5, 24.0, 16.0, 40.0, 0.0, 80.0, 40.0);
      // 1 regular italic (near edge -> no overhang expansion)
      staged.addItalicCell(
        0.0,
        0.0,
        20.0,
        40.0,
        10.0,
        20.0,
        0xFFFF0000,
        isBold: false,
      );
      // 1 bold italic (interior -> expands by overhangFgPhysical=2.0)
      staged.addItalicCell(
        10.0,
        10.0,
        30.0,
        50.0,
        30.0,
        20.0,
        0xFF0000FF,
        isBold: true,
      );
      // 1 deco sprite
      staged.addDecoSprite(0.5, 8.0, 32.0, 0.0, 80.0, 20.0, 84.0, 0xFFFFFFFF);

      final batch = builder.build(
        staged: staged,
        buffer: buffer,
        logicalSize: const ui.Size(100.0, 80.0),
        devicePixelRatio: 2.0,
        cellWidth: 10.0,
        cellHeight: 20.0,
        atlasPhysWidth: 200.0,
        atlasPhysHeight: 200.0,
        fgScaleBlock: 0.5,
        overhangFgPhysical: 2.0,
        overhangFgLogical: 1.0,
        defaultBackgroundArgb: 0xFF102030,
        stagingGeneration: 1,
        kittyImages: const <KittyImageData, ui.Image>{},
        kittyImagesById: const <(KittyImageRegistry, int), ui.Image>{},
        activePtyCols: 6,
        activePtyRows: 2,
        outOfBoundsDimArgb: 0x80000000,
      );

      expect(batch.hasCanvasOnlyContent, isFalse);
      expect(batch.kittyQuads, isEmpty);
      // Indices:
      // 0: backdrop (solid)
      // 1: bg
      // 2: fg
      // 3: emoji
      // 4: regular italic
      // 5: bold italic pass 1
      // 6: bold italic pass 2 (+0.6 logical = +1.2 physical X)
      // 7: deco
      // 8..11: out-of-bounds right scrim, bottom scrim, vertical border, horizontal border
      expect(batch.italicStartInstanceIndex, equals(4));
      expect(batch.kittyInsertInstanceIndex, equals(7));
      expect(batch.instanceCount, equals(12));

      // Backdrop solid quad (10*10*2 = 200, 4*20*2 = 160).
      final backdrop = _instanceAt(batch, 0);
      expect(backdrop[0], closeTo(0.0, 1e-4));
      expect(backdrop[1], closeTo(0.0, 1e-4));
      expect(backdrop[2], closeTo(200.0, 1e-4));
      expect(backdrop[3], closeTo(160.0, 1e-4));
      expect(backdrop[14], equals(GpuAtlasQuadBatch.modeSolid));

      // Background sprite: premultiplied alpha check (0x80 / 255 = 0.50196...).
      final bg = _instanceAt(batch, 1);
      final a50 = 0x80 / 255.0;
      expect(bg[0], closeTo(16.0, 1e-4)); // tx * dpr
      expect(bg[1], closeTo(32.0, 1e-4)); // ty * dpr
      expect(bg[2], closeTo(20.0, 1e-4)); // (20-0)*0.5*2
      expect(bg[3], closeTo(40.0, 1e-4)); // (40-0)*0.5*2
      expect(bg[4], closeTo(0.0, 1e-5));
      expect(bg[6], closeTo(0.1, 1e-5)); // 20/200
      expect(bg[7], closeTo(0.2, 1e-5)); // 40/200
      expect(bg[8], closeTo(1.0 * a50, 1e-4));
      expect(bg[9], closeTo(0.0, 1e-4));
      expect(bg[10], closeTo((0x80 / 255.0) * a50, 1e-4));
      expect(bg[11], closeTo(a50, 1e-4));
      expect(bg[14], equals(GpuAtlasQuadBatch.modeTextured));

      // Emoji sprite: untinted (1, 1, 1, 1).
      final emoji = _instanceAt(batch, 3);
      expect(emoji[8], equals(1.0));
      expect(emoji[9], equals(1.0));
      expect(emoji[10], equals(1.0));
      expect(emoji[11], equals(1.0));

      // Regular italic (at atlas origin -> cannot expand overhang).
      final italic0 = _instanceAt(batch, 4);
      // originX = 10 + 10*0.14 = 11.4 -> *2 = 22.8
      expect(italic0[0], closeTo(22.8, 1e-4));
      expect(italic0[1], closeTo(40.0, 1e-4));
      expect(italic0[2], closeTo(20.0, 1e-4));
      expect(italic0[3], closeTo(40.0, 1e-4));
      expect(italic0[12], closeTo(-0.18, 1e-5));
      expect(italic0[13], closeTo(40.0, 1e-4)); // y * dpr

      // Bold italic: expanded by overhangFgPhysical=2.0, second quad offset by +0.6*2=+1.2.
      final boldItalic1 = _instanceAt(batch, 5);
      final boldItalic2 = _instanceAt(batch, 6);
      // originX = 30 + 1.4 = 31.4; dstX1 = (31.4 - 1.0)*2 = 60.8; dstX2 = (31.4 + 0.6 - 1.0)*2 = 62.0
      expect(boldItalic1[0], closeTo(60.8, 1e-4));
      expect(boldItalic2[0], closeTo(62.0, 1e-4));
      expect(boldItalic1[1], closeTo(38.0, 1e-4)); // (20 - 1.0)*2
      expect(boldItalic1[2], closeTo(24.0, 1e-4)); // (32-8)*0.5*2
      expect(boldItalic1[3], closeTo(44.0, 1e-4)); // (52-8)*0.5*2
      expect(boldItalic1[4], closeTo(8.0 / 200.0, 1e-5));
      expect(boldItalic1[6], closeTo(32.0 / 200.0, 1e-5));
      expect(boldItalic1[12], closeTo(-0.18, 1e-5));
      expect(boldItalic1[13], closeTo(40.0, 1e-4));

      // Deco comes at kittyInsertInstanceIndex (after italic/Kitty).
      final deco = _instanceAt(batch, 7);
      expect(deco[14], equals(GpuAtlasQuadBatch.modeTextured));

      // Out-of-bounds right scrim: activeX=60, activeY=40, logicalSize=100x80, dpr=2.
      final rightScrim = _instanceAt(batch, 8);
      expect(rightScrim[0], closeTo(120.0, 1e-4));
      expect(rightScrim[1], closeTo(0.0, 1e-4));
      expect(rightScrim[2], closeTo(80.0, 1e-4));
      expect(rightScrim[3], closeTo(80.0, 1e-4));
      expect(rightScrim[14], equals(GpuAtlasQuadBatch.modeSolid));

      // Dark default background (0xFF102030) picks light border (0x33FFFFFF).
      final vBorder = _instanceAt(batch, 10);
      final borderAlpha = 0x33 / 255.0;
      expect(vBorder[8], closeTo(borderAlpha, 1e-4));
      expect(vBorder[9], closeTo(borderAlpha, 1e-4));
      expect(vBorder[10], closeTo(borderAlpha, 1e-4));
      expect(vBorder[11], closeTo(borderAlpha, 1e-4));
      expect(vBorder[2], closeTo(2.0, 1e-4)); // 1 logical px * dpr
      expect(vBorder[14], equals(GpuAtlasQuadBatch.modeSolid));
    });

    test(
      'coalesces horizontal Kitty runs without triggering hasCanvasOnlyContent',
      () async {
        final gpuImage = await _makeTestImage(64, 32);
        addTearDown(gpuImage.dispose);

        const imageId = 42;
        final kittyData = KittyImageData(
          imageId: imageId,
          pixelWidth: 64,
          pixelHeight: 32,
          rgbaPixels: Uint8List(64 * 32 * 4),
          gridCols: 4,
          gridRows: 2,
        );
        final registry = KittyImageRegistry()..registerImage(kittyData);
        final buffer = Buffer(6, 2)
          ..registerKittyRegistry(const tui_geo.Rect(0, 0, 6, 2), registry);

        final staged = StagingBufferSet()..ensureGridCapacity(2, 12);
        // Two contiguous horizontal Kitty cells on row 0 (tile cols 1 and 2).
        for (var i = 0; i < 2; i++) {
          staged.addFallbackCell(
            char: kittyPlaceholderCell(0, 1 + i),
            gridCol: 1 + i,
            gridRow: 0,
            modifiers: Modifier.kittyPlaceholder,
            fgArgb: 0xFF000000 | imageId,
            bgArgb: 0xFF000000,
            resolvedFg: 0xFF000000 | imageId,
            x: (1 + i) * 10.0,
            y: 0.0,
            w: 10.0,
            h: 20.0,
          );
        }

        final builder = GpuAtlasBatchBuilder();
        final batch = builder.build(
          staged: staged,
          buffer: buffer,
          logicalSize: const ui.Size(60.0, 40.0),
          devicePixelRatio: 2.0,
          cellWidth: 10.0,
          cellHeight: 20.0,
          atlasPhysWidth: 256.0,
          atlasPhysHeight: 256.0,
          fgScaleBlock: 0.5,
          overhangFgPhysical: 0.0,
          overhangFgLogical: 0.0,
          defaultBackgroundArgb: 0x00000000,
          stagingGeneration: 1,
          kittyImages: <KittyImageData, ui.Image>{kittyData: gpuImage},
          kittyImagesById: const <(KittyImageRegistry, int), ui.Image>{},
        );

        expect(batch.hasCanvasOnlyContent, isFalse);
        expect(batch.kittyQuads, hasLength(1));
        final quad = batch.kittyQuads.single;
        expect(identical(quad.image, gpuImage), isTrue);
        expect(quad.dstX, closeTo(20.0, 1e-4));
        expect(quad.dstY, closeTo(0.0, 1e-4));
        expect(quad.dstWidth, closeTo((2 * 10.0 + 0.25) * 2.0, 1e-4));
        expect(quad.dstHeight, closeTo((20.0 + 0.25) * 2.0, 1e-4));
        expect(quad.u0, closeTo(0.25, 1e-5));
        expect(quad.u1, closeTo(0.75, 1e-5));
        expect(quad.v0, closeTo(0.0, 1e-5));
        expect(quad.v1, closeTo(0.5, 1e-5));
      },
    );

    test('merges 1-diacritic and bare U+10EEEE continuation cells into a full-width Kitty quad', () async {
      final gpuImage = await _makeTestImage(64, 32);
      addTearDown(gpuImage.dispose);

      const imageId = 100;
      final kittyData = KittyImageData(
        imageId: imageId,
        pixelWidth: 64,
        pixelHeight: 32,
        rgbaPixels: Uint8List(64 * 32 * 4),
        gridCols: 4,
        gridRows: 2,
      );
      final registry = KittyImageRegistry()..registerImage(kittyData);
      final buffer = Buffer(6, 2)
        ..registerKittyRegistry(const tui_geo.Rect(0, 0, 6, 2), registry);

      final staged = StagingBufferSet()..ensureGridCapacity(2, 12);
      // Column 0 uses 1-diacritic shorthand (row 0, implicit col 0); columns 1..3 are bare U+10EEEE.
      final row0Shorthand =
          '$kittyPlaceholderChar${String.fromCharCode(kittyDiacritics[0])}';
      for (var i = 0; i < 4; i++) {
        staged.addFallbackCell(
          char: i == 0 ? row0Shorthand : kittyPlaceholderChar,
          gridCol: i,
          gridRow: 0,
          modifiers: Modifier.kittyPlaceholder,
          fgArgb: 0xFF000000 | imageId,
          bgArgb: 0xFF000000,
          resolvedFg: 0xFF000000 | imageId,
          x: i * 10.0,
          y: 0.0,
          w: 10.0,
          h: 20.0,
        );
      }

      final builder = GpuAtlasBatchBuilder();
      final batch = builder.build(
        staged: staged,
        buffer: buffer,
        logicalSize: const ui.Size(60.0, 40.0),
        devicePixelRatio: 1.0,
        cellWidth: 10.0,
        cellHeight: 20.0,
        atlasPhysWidth: 256.0,
        atlasPhysHeight: 256.0,
        fgScaleBlock: 0.5,
        overhangFgPhysical: 0.0,
        overhangFgLogical: 0.0,
        defaultBackgroundArgb: 0x00000000,
        stagingGeneration: 1,
        kittyImages: <KittyImageData, ui.Image>{kittyData: gpuImage},
        kittyImagesById: const <(KittyImageRegistry, int), ui.Image>{},
      );

      expect(batch.hasCanvasOnlyContent, isFalse);
      expect(batch.kittyQuads, hasLength(1));
      final quad = batch.kittyQuads.single;
      expect(quad.dstX, closeTo(0.0, 1e-4));
      expect(quad.dstWidth, closeTo(40.25, 1e-4));
      expect(quad.u0, closeTo(0.0, 1e-5));
      expect(quad.u1, closeTo(1.0, 1e-5));
    });

    test('merges mid-row 1-diacritic continuations and splits runs across distinct underlineColor placement IDs', () async {
      final gpuImage = await _makeTestImage(64, 32);
      addTearDown(gpuImage.dispose);

      const imageId = 0x12000064;
      final kittyData = KittyImageData(
        imageId: imageId,
        pixelWidth: 64,
        pixelHeight: 32,
        rgbaPixels: Uint8List(64 * 32 * 4),
        gridCols: 4,
        gridRows: 2,
      );
      final registry = KittyImageRegistry()..registerImage(kittyData);
      final buffer = Buffer(6, 2)
        ..registerKittyRegistry(const tui_geo.Rect(0, 0, 6, 2), registry);
      buffer.setUnderlineColor(0, 0, 0xFF000001);
      buffer.setUnderlineColor(1, 0, 0xFF000001);
      buffer.setUnderlineColor(2, 0, 0xFF000002);
      buffer.setUnderlineColor(3, 0, 0xFF000002);

      final row0Shorthand =
          '$kittyPlaceholderChar${String.fromCharCode(kittyDiacritics[0])}';
      final staged = StagingBufferSet()..ensureGridCapacity(2, 12);
      final chars = [
        kittyPlaceholderCell(0, 0, imageIdMsb: 0x12),
        row0Shorthand,
        kittyPlaceholderCell(0, 0, imageIdMsb: 0x12),
        kittyPlaceholderChar,
      ];
      for (var i = 0; i < 4; i++) {
        staged.addFallbackCell(
          char: chars[i],
          gridCol: i,
          gridRow: 0,
          modifiers: Modifier.kittyPlaceholder,
          fgArgb: 0xFF000000 | (imageId & 0xFFFFFF),
          bgArgb: 0xFF000000,
          resolvedFg: 0xFF000000 | (imageId & 0xFFFFFF),
          x: i * 10.0,
          y: 0.0,
          w: 10.0,
          h: 20.0,
        );
      }

      final builder = GpuAtlasBatchBuilder();
      final batch = builder.build(
        staged: staged,
        buffer: buffer,
        logicalSize: const ui.Size(60.0, 40.0),
        devicePixelRatio: 1.0,
        cellWidth: 10.0,
        cellHeight: 20.0,
        atlasPhysWidth: 256.0,
        atlasPhysHeight: 256.0,
        fgScaleBlock: 0.5,
        overhangFgPhysical: 0.0,
        overhangFgLogical: 0.0,
        defaultBackgroundArgb: 0x00000000,
        stagingGeneration: 1,
        kittyImages: <KittyImageData, ui.Image>{kittyData: gpuImage},
        kittyImagesById: const <(KittyImageRegistry, int), ui.Image>{},
      );

      expect(batch.kittyQuads, hasLength(2));
      expect(batch.kittyQuads[0].dstWidth, closeTo(20.25, 1e-4));
      expect(batch.kittyQuads[0].u1, closeTo(0.5, 1e-5));
      expect(batch.kittyQuads[1].dstX, closeTo(20.0, 1e-4));
      expect(batch.kittyQuads[1].dstWidth, closeTo(20.25, 1e-4));
    });

    test('flags hasCanvasOnlyContent for non-Kitty fallback, raw subpixel Kitty, ligatures, and composingText', () {
      final buffer = Buffer(4, 2);
      final builder = GpuAtlasBatchBuilder();

      // 1. Non-Kitty fallback glyph.
      final nonKitty = StagingBufferSet()..ensureGridCapacity(2, 8);
      nonKitty.addFallbackCell(
        char: '漢',
        gridCol: 0,
        gridRow: 0,
        modifiers: 0,
        fgArgb: 0xFFFFFFFF,
        bgArgb: 0xFF000000,
        resolvedFg: 0xFFFFFFFF,
        x: 0.0,
        y: 0.0,
        w: 20.0,
        h: 20.0,
      );
      expect(
        builder
            .build(
              staged: nonKitty,
              buffer: buffer,
              logicalSize: const ui.Size(40.0, 40.0),
              devicePixelRatio: 1.0,
              cellWidth: 10.0,
              cellHeight: 20.0,
              atlasPhysWidth: 128.0,
              atlasPhysHeight: 128.0,
              fgScaleBlock: 1.0,
              overhangFgPhysical: 0.0,
              overhangFgLogical: 0.0,
              defaultBackgroundArgb: 0xFF000000,
              stagingGeneration: 1,
              kittyImages: const <KittyImageData, ui.Image>{},
              kittyImagesById: const <(KittyImageRegistry, int), ui.Image>{},
            )
            .hasCanvasOnlyContent,
        isTrue,
      );

      // 2. Raw RGBA Kitty cell with undecoded gpuImage -> subpixel Canvas fallback.
      const rawId = 7;
      final rawData = KittyImageData(
        imageId: rawId,
        pixelWidth: 2,
        pixelHeight: 2,
        rgbaPixels: Uint8List(16),
        gridCols: 1,
        gridRows: 1,
      );
      final registry = KittyImageRegistry()..registerImage(rawData);
      final kittyBuffer = Buffer(4, 2)
        ..registerKittyRegistry(const tui_geo.Rect(0, 0, 4, 2), registry);
      final rawStaged = StagingBufferSet()..ensureGridCapacity(2, 8);
      rawStaged.addFallbackCell(
        char: kittyPlaceholderCell(0, 0),
        gridCol: 0,
        gridRow: 0,
        modifiers: Modifier.kittyPlaceholder,
        fgArgb: 0xFF000000 | rawId,
        bgArgb: 0xFF000000,
        resolvedFg: 0xFF000000 | rawId,
        x: 0.0,
        y: 0.0,
        w: 10.0,
        h: 20.0,
      );
      expect(
        builder
            .build(
              staged: rawStaged,
              buffer: kittyBuffer,
              logicalSize: const ui.Size(40.0, 40.0),
              devicePixelRatio: 1.0,
              cellWidth: 10.0,
              cellHeight: 20.0,
              atlasPhysWidth: 128.0,
              atlasPhysHeight: 128.0,
              fgScaleBlock: 1.0,
              overhangFgPhysical: 0.0,
              overhangFgLogical: 0.0,
              defaultBackgroundArgb: 0xFF000000,
              stagingGeneration: 2,
              kittyImages: const <KittyImageData, ui.Image>{},
              kittyImagesById: const <(KittyImageRegistry, int), ui.Image>{},
            )
            .hasCanvasOnlyContent,
        isTrue,
      );

      // 3. Multi-cell ligature run.
      final ligStaged = StagingBufferSet()..ensureGridCapacity(2, 8);
      ligStaged.addLigatureCell(
        text: '->',
        x: 0.0,
        y: 0.0,
        w: 20.0,
        h: 20.0,
        resolvedFg: 0xFFFFFFFF,
        isBold: false,
        isItalic: false,
      );
      expect(
        builder
            .build(
              staged: ligStaged,
              buffer: buffer,
              logicalSize: const ui.Size(40.0, 40.0),
              devicePixelRatio: 1.0,
              cellWidth: 10.0,
              cellHeight: 20.0,
              atlasPhysWidth: 128.0,
              atlasPhysHeight: 128.0,
              fgScaleBlock: 1.0,
              overhangFgPhysical: 0.0,
              overhangFgLogical: 0.0,
              defaultBackgroundArgb: 0xFF000000,
              stagingGeneration: 3,
              kittyImages: const <KittyImageData, ui.Image>{},
              kittyImagesById: const <(KittyImageRegistry, int), ui.Image>{},
            )
            .hasCanvasOnlyContent,
        isTrue,
      );

      // 4. Inline composing text.
      final cleanStaged = StagingBufferSet()..ensureGridCapacity(2, 8);
      expect(
        builder
            .build(
              staged: cleanStaged,
              buffer: buffer,
              logicalSize: const ui.Size(40.0, 40.0),
              devicePixelRatio: 1.0,
              cellWidth: 10.0,
              cellHeight: 20.0,
              atlasPhysWidth: 128.0,
              atlasPhysHeight: 128.0,
              fgScaleBlock: 1.0,
              overhangFgPhysical: 0.0,
              overhangFgLogical: 0.0,
              defaultBackgroundArgb: 0xFF000000,
              stagingGeneration: 4,
              kittyImages: const <KittyImageData, ui.Image>{},
              kittyImagesById: const <(KittyImageRegistry, int), ui.Image>{},
              composingText: 'あ',
            )
            .hasCanvasOnlyContent,
        isTrue,
      );
    });

    test('reuses cached batch on unchanged generation and grows buffer cleanly beyond 256 instances', () {
      final builder = GpuAtlasBatchBuilder();
      final buffer = Buffer(40, 10);
      final staged = StagingBufferSet()..ensureGridCapacity(10, 400);
      for (var i = 0; i < 320; i++) {
        staged.addFgSprite(
          1.0,
          (i % 40) * 8.0,
          (i ~/ 40) * 16.0,
          0.0,
          0.0,
          8.0,
          16.0,
          0xFFFFFFFF,
        );
      }

      final batch1 = builder.build(
        staged: staged,
        buffer: buffer,
        logicalSize: const ui.Size(320.0, 160.0),
        devicePixelRatio: 1.0,
        cellWidth: 8.0,
        cellHeight: 16.0,
        atlasPhysWidth: 256.0,
        atlasPhysHeight: 256.0,
        fgScaleBlock: 1.0,
        overhangFgPhysical: 0.0,
        overhangFgLogical: 0.0,
        defaultBackgroundArgb: 0xFF000000,
        stagingGeneration: 5,
        kittyImages: const <KittyImageData, ui.Image>{},
        kittyImagesById: const <(KittyImageRegistry, int), ui.Image>{},
      );
      expect(batch1.instanceCount, equals(321)); // 1 backdrop + 320 fg

      final batch2 = builder.build(
        staged: staged,
        buffer: buffer,
        logicalSize: const ui.Size(320.0, 160.0),
        devicePixelRatio: 1.0,
        cellWidth: 8.0,
        cellHeight: 16.0,
        atlasPhysWidth: 256.0,
        atlasPhysHeight: 256.0,
        fgScaleBlock: 1.0,
        overhangFgPhysical: 0.0,
        overhangFgLogical: 0.0,
        defaultBackgroundArgb: 0xFF000000,
        stagingGeneration: 5,
        kittyImages: const <KittyImageData, ui.Image>{},
        kittyImagesById: const <(KittyImageRegistry, int), ui.Image>{},
      );
      expect(identical(batch1, batch2), isTrue);
      expect(batch2.generation, equals(batch1.generation));

      // Bumping stagingGeneration rebuilds and increments batch.generation.
      final batch3 = builder.build(
        staged: staged,
        buffer: buffer,
        logicalSize: const ui.Size(320.0, 160.0),
        devicePixelRatio: 1.0,
        cellWidth: 8.0,
        cellHeight: 16.0,
        atlasPhysWidth: 256.0,
        atlasPhysHeight: 256.0,
        fgScaleBlock: 1.0,
        overhangFgPhysical: 0.0,
        overhangFgLogical: 0.0,
        defaultBackgroundArgb: 0xFF000000,
        stagingGeneration: 6,
        kittyImages: const <KittyImageData, ui.Image>{},
        kittyImagesById: const <(KittyImageRegistry, int), ui.Image>{},
      );
      expect(batch3.generation, greaterThan(batch1.generation));
      expect(identical(batch3.instanceData, batch1.instanceData), isTrue);
    });
  });

  group('GpuAtlasShaders', () {
    test('computeCoverUvRect crops wide and tall images symmetrically', () {
      final wide = GpuAtlasShaders.computeCoverUvRect(
        imageWidth: 200.0,
        imageHeight: 100.0,
        viewportWidth: 100.0,
        viewportHeight: 100.0,
      );
      expect(wide.u0, closeTo(0.25, 1e-6));
      expect(wide.u1, closeTo(0.75, 1e-6));
      expect(wide.v0, equals(0.0));
      expect(wide.v1, equals(1.0));

      final tall = GpuAtlasShaders.computeCoverUvRect(
        imageWidth: 100.0,
        imageHeight: 200.0,
        viewportWidth: 100.0,
        viewportHeight: 100.0,
      );
      expect(tall.u0, equals(0.0));
      expect(tall.u1, equals(1.0));
      expect(tall.v0, closeTo(0.25, 1e-6));
      expect(tall.v1, closeTo(0.75, 1e-6));

      final degenerate = GpuAtlasShaders.computeCoverUvRect(
        imageWidth: 0.0,
        imageHeight: 100.0,
        viewportWidth: 100.0,
        viewportHeight: 100.0,
      );
      expect(degenerate, equals((u0: 0.0, v0: 0.0, u1: 1.0, v1: 1.0)));
    });

    test('writeTexturedQuadInstance packs untinted non-sheared quad', () {
      final scratch = Float32List(GpuAtlasQuadBatch.floatsPerInstance);
      GpuAtlasShaders.writeTexturedQuadInstance(
        scratch,
        dstX: 10.0,
        dstY: 20.0,
        dstWidth: 300.0,
        dstHeight: 200.0,
        u0: 0.1,
        v0: 0.2,
        u1: 0.9,
        v1: 0.8,
      );
      expect(scratch[0], equals(10.0));
      expect(scratch[1], equals(20.0));
      expect(scratch[2], equals(300.0));
      expect(scratch[3], equals(200.0));
      expect(scratch[4], closeTo(0.1, 1e-6));
      expect(scratch[5], closeTo(0.2, 1e-6));
      expect(scratch[6], closeTo(0.9, 1e-6));
      expect(scratch[7], closeTo(0.8, 1e-6));
      expect(scratch[8], equals(1.0));
      expect(scratch[11], equals(1.0));
      expect(scratch[14], equals(GpuAtlasQuadBatch.modeTextured));
    });

    test('contains well-formed WebGL2 and Impeller GLSL sources', () {
      expect(GpuAtlasShaders.unitQuadVertices, hasLength(12));
      expect(GpuAtlasShaders.webgl2VertexSource, contains('#version 300 es'));
      expect(GpuAtlasShaders.webgl2FragmentSource, contains('#version 300 es'));
      expect(
        GpuAtlasShaders.impellerVertexSource,
        contains('#version 460 core'),
      );
      expect(
        GpuAtlasShaders.impellerVertexSource,
        contains('std140) uniform AtlasUniforms'),
      );
      expect(
        GpuAtlasShaders.impellerFragmentSource,
        contains('#version 460 core'),
      );
    });
  });

  group('TuiAtlasPainter.stageForGpu incremental typing', () {
    test('stages every single keystroke (t -> th -> thi -> this) with monotonic generation and instanceCount', () async {
      final atlas = await GlyphAtlasGenerator.generate(
        fontSize: 14.0,
        fontFamily: 'Roboto Mono',
        devicePixelRatio: 2.0,
      );
      addTearDown(atlas.dispose);

      final buffer = Buffer(40, 10)..writeString(0, 2, r'$ ', Style.empty);
      final cache = TuiAtlasStagingCache();
      final builder = GpuAtlasBatchBuilder();
      final logicalSize = ui.Size(40 * atlas.cellWidth, 10 * atlas.cellHeight);

      GpuAtlasQuadBatch stage(int cursorCol) => TuiAtlasPainter(
        buffer: buffer,
        atlas: atlas,
        stagingCache: cache,
        fontFamily: 'Roboto Mono',
        fallbackPainters: const {},
        onMissingGlyphs: null,
        enableBleed: true,
        cursorCol: cursorCol,
        cursorRow: 2,
      ).stageForGpu(logicalSize, 2.0, builder);

      final baseline = stage(2);
      var prevGen = baseline.generation;
      var prevCount = baseline.instanceCount;

      const typed = 'this';
      for (var i = 0; i < typed.length; i++) {
        buffer.writeString(2 + i, 2, typed[i], Style.empty);
        final next = stage(2 + i + 1);
        expect(
          next.generation,
          greaterThan(prevGen),
          reason: 'keystroke "$typed"[0..$i] must advance batch generation',
        );
        expect(
          next.instanceCount,
          equals(prevCount + 1),
          reason: 'keystroke "$typed"[0..$i] must emit new glyph instance',
        );
        prevGen = next.generation;
        prevCount = next.instanceCount;
      }
    });
  });
}
