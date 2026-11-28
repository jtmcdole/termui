import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:termui/termui.dart';
import 'package:termui_flutter/src/rendering/gpu_atlas_batch.dart';
import 'package:termui_flutter/src/rendering/png_rgba_decoder.dart';
import 'package:termui_flutter/src/rendering/shader_backend_gpu.dart';
import 'package:termui_flutter/src/rendering/staging_cache.dart';
import 'package:termui_shared_examples/ktty_probe/ktty_probe_assets.dart';

Uint8List _buildPng({
  required int width,
  required int height,
  required int bitDepth,
  required int colorType,
  required Uint8List rawScanlines,
  int interlace = 0,
  Uint8List? plte,
  Uint8List? trns,
}) {
  final out = BytesBuilder(copy: false)
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  void addChunk(String type, Uint8List payload) {
    final len = ByteData(4)..setUint32(0, payload.length);
    out
      ..add(len.buffer.asUint8List())
      ..add(ascii.encode(type))
      ..add(payload)
      ..add(const [0, 0, 0, 0]); // CRC ignored by decoder
  }

  final ihdr = Uint8List(13);
  ByteData.sublistView(ihdr)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, bitDepth)
    ..setUint8(9, colorType)
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, interlace);
  addChunk('IHDR', ihdr);
  if (plte != null) addChunk('PLTE', plte);
  if (trns != null) addChunk('tRNS', trns);
  addChunk('IDAT', Uint8List.fromList(zlib.encode(rawScanlines)));
  addChunk('IEND', Uint8List(0));
  return out.takeBytes();
}

Future<ui.Image> _solidImage(int width, int height) {
  final completer = Completer<ui.Image>();
  final pixels = Uint8List(width * height * 4)
    ..fillRange(0, width * height * 4, 255);
  ui.decodeImageFromPixels(
    pixels,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

void main() {
  group('decodeKittyPngToRgbaAsync', () {
    test(
      'decodes ktty_probe 144x96 PNG tile identically to source RGBA',
      () async {
        final tile = buildPngVisualTile();
        final decoded = await decodeKittyPngToRgbaAsync(tile.rgbaPixels);
        expect(decoded, isNotNull);
        expect(decoded!.width, equals(144));
        expect(decoded.height, equals(96));
        expect(decoded.rgba.length, equals(144 * 96 * 4));
        // Border pixel at (0, 0) is golden (255, 215, 110, 255).
        expect(decoded.rgba.sublist(0, 4), equals(const [255, 215, 110, 255]));
      },
    );

    test(
      'supports all 5 PNG scanline filters (None, Sub, Up, Average, Paeth)',
      () async {
        // 2x5 RGBA image exercising filter 0..4 on rows 0..4.
        final expected = Uint8List.fromList([
          // row 0: (10,20,30,255), (40,50,60,255)
          10, 20, 30, 255, 40, 50, 60, 255,
          // row 1 (Sub): (15,25,35,255), (50,60,70,255)
          15, 25, 35, 255, 50, 60, 70, 255,
          // row 2 (Up): (25,35,45,255), (60,70,80,255)
          25, 35, 45, 255, 60, 70, 80, 255,
          // row 3 (Average): (30,40,50,255), (70,80,90,255)
          30, 40, 50, 255, 70, 80, 90, 255,
          // row 4 (Paeth): (35,45,55,200), (80,90,100,128)
          35, 45, 55, 200, 80, 90, 100, 128,
        ]);

        int paeth(int a, int b, int c) {
          final p = a + b - c;
          final pa = (p - a).abs();
          final pb = (p - b).abs();
          final pc = (p - c).abs();
          if (pa <= pb && pa <= pc) return a;
          if (pb <= pc) return b;
          return c;
        }

        const rowBytes = 8;
        final scanlines = BytesBuilder();
        for (var y = 0; y < 5; y++) {
          scanlines.addByte(y); // filter type = y
          for (var i = 0; i < rowBytes; i++) {
            final cur = expected[y * rowBytes + i];
            final left = i >= 4 ? expected[y * rowBytes + i - 4] : 0;
            final up = y > 0 ? expected[(y - 1) * rowBytes + i] : 0;
            final upLeft = (y > 0 && i >= 4)
                ? expected[(y - 1) * rowBytes + i - 4]
                : 0;
            final pred = switch (y) {
              0 => 0,
              1 => left,
              2 => up,
              3 => (left + up) >>> 1,
              _ => paeth(left, up, upLeft),
            };
            scanlines.addByte((cur - pred) & 0xFF);
          }
        }

        final png = _buildPng(
          width: 2,
          height: 5,
          bitDepth: 8,
          colorType: 6,
          rawScanlines: scanlines.takeBytes(),
        );
        final decoded = await decodeKittyPngToRgbaAsync(png);
        expect(decoded, isNotNull);
        expect(decoded!.rgba, equals(expected));
      },
    );

    test('decodes RGB+tRNS, Indexed+PLTE+tRNS, Grayscale 1-bit, GrayAlpha, and Adam7', () async {
      // 1. RGB 8-bit with tRNS key (1, 2, 3) -> alpha 0.
      final rgbPng = _buildPng(
        width: 2,
        height: 1,
        bitDepth: 8,
        colorType: 2,
        trns: Uint8List.fromList([0, 1, 0, 2, 0, 3]),
        rawScanlines: Uint8List.fromList([0, 1, 2, 3, 10, 20, 30]),
      );
      final rgb = await decodeKittyPngToRgbaAsync(rgbPng);
      expect(rgb!.rgba, equals(const [1, 2, 3, 0, 10, 20, 30, 255]));

      // 2. Indexed 4-bit with PLTE and tRNS.
      final idxPng = _buildPng(
        width: 2,
        height: 1,
        bitDepth: 4,
        colorType: 3,
        plte: Uint8List.fromList([255, 0, 0, 0, 255, 0]),
        trns: Uint8List.fromList([128]),
        rawScanlines: Uint8List.fromList([0, 0x01]),
      );
      final idx = await decodeKittyPngToRgbaAsync(idxPng);
      expect(idx!.rgba, equals(const [255, 0, 0, 128, 0, 255, 0, 255]));

      // 3. Grayscale 1-bit.
      final gray1Png = _buildPng(
        width: 2,
        height: 1,
        bitDepth: 1,
        colorType: 0,
        rawScanlines: Uint8List.fromList([0, 0x40]), // bits: 0, 1
      );
      final gray1 = await decodeKittyPngToRgbaAsync(gray1Png);
      expect(gray1!.rgba, equals(const [0, 0, 0, 255, 255, 255, 255, 255]));

      // 4. Grayscale + Alpha 8-bit.
      final gaPng = _buildPng(
        width: 1,
        height: 1,
        bitDepth: 8,
        colorType: 4,
        rawScanlines: Uint8List.fromList([0, 99, 180]),
      );
      final ga = await decodeKittyPngToRgbaAsync(gaPng);
      expect(ga!.rgba, equals(const [99, 99, 99, 180]));

      // 5. Adam7 interlaced 2x2 RGBA (passes present: 0=(0,0), 5=(1,0), 6=(0,1),(1,1)).
      final adam7Scanlines = Uint8List.fromList([
        // pass 0 (1x1 -> (0,0)): red
        0, 255, 0, 0, 255,
        // pass 5 (1x1 -> (1,0)): green
        0, 0, 255, 0, 255,
        // pass 6 (2x1 -> (0,1), (1,1)): blue, white
        0, 0, 0, 255, 255, 255, 255, 255, 255,
      ]);
      final adam7Png = _buildPng(
        width: 2,
        height: 2,
        bitDepth: 8,
        colorType: 6,
        interlace: 1,
        rawScanlines: adam7Scanlines,
      );
      final adam7 = await decodeKittyPngToRgbaAsync(adam7Png);
      expect(
        adam7!.rgba,
        equals(const [
          255, 0, 0, 255, 0, 255, 0, 255, // row 0
          0, 0, 255, 255, 255, 255, 255, 255, // row 1
        ]),
      );
    });

    test(
      'returns null cleanly on malformed PNGs or excessive dimensions',
      () async {
        expect(await decodeKittyPngToRgbaAsync(Uint8List(8)), isNull);
        expect(
          await decodeKittyPngToRgbaAsync(Uint8List.fromList([1, 2, 3, 4])),
          isNull,
        );
        final hugeHeader = _buildPng(
          width: 9000,
          height: 1,
          bitDepth: 8,
          colorType: 6,
          rawScanlines: Uint8List(1),
        );
        expect(await decodeKittyPngToRgbaAsync(hugeHeader), isNull);
      },
    );
  });

  group('PNG Kitty quad direct CPU upload (no toByteData readback)', () {
    test('GpuAtlasBatchBuilder attaches decoded PNG RGBA and uploads via KittyTextureUploadCache', () async {
      final pngTile = buildPngVisualTile(cols: 2, rows: 1);
      final decoded = (await decodeKittyPngToRgbaAsync(pngTile.rgbaPixels))!;
      final gpuImage = await _solidImage(decoded.width, decoded.height);
      addTearDown(gpuImage.dispose);

      final registry = KittyImageRegistry()..registerImage(pngTile);
      final buffer = Buffer(2, 1)
        ..registerKittyRegistry(const Rect(0, 0, 2, 1), registry);
      final staged = StagingBufferSet()..ensureGridCapacity(1, 2);
      for (var c = 0; c < 2; c++) {
        staged.addFallbackCell(
          char: kittyPlaceholderCell(0, c),
          gridCol: c,
          gridRow: 0,
          modifiers: Modifier.kittyPlaceholder,
          fgArgb: 0xFF000000 | (pngTile.imageId & 0xFFFFFF),
          bgArgb: 0xFF000000,
          resolvedFg: 0xFF000000 | (pngTile.imageId & 0xFFFFFF),
          x: c * 10.0,
          y: 0.0,
          w: 10.0,
          h: 20.0,
        );
      }

      final builder = GpuAtlasBatchBuilder();
      final batch = builder.build(
        staged: staged,
        buffer: buffer,
        logicalSize: const ui.Size(20.0, 20.0),
        devicePixelRatio: 1.0,
        cellWidth: 10.0,
        cellHeight: 20.0,
        atlasPhysWidth: 256.0,
        atlasPhysHeight: 256.0,
        fgScaleBlock: 0.5,
        overhangFgPhysical: 0.0,
        overhangFgLogical: 0.0,
        defaultBackgroundArgb: 0xFF000000,
        stagingGeneration: 1,
        kittyImages: <KittyImageData, ui.Image>{pngTile: gpuImage},
        kittyImagesById: const <(KittyImageRegistry, int), ui.Image>{},
        kittyDecodedRgba: <KittyImageData, Uint8List>{pngTile: decoded.rgba},
      );

      expect(batch.kittyQuads, hasLength(1));
      expect(batch.kittyQuads.first.rawRgbaPixels, same(decoded.rgba));

      var uploadCalls = 0;
      final cache = KittyTextureUploadCache<String>(initialCapacity: 4);
      final resolved = cache.resolveQuads(
        batch.kittyQuads,
        uploadRawRgba: (w, h, bytes) {
          uploadCalls++;
          expect(w, equals(144));
          expect(h, equals(96));
          expect(bytes.lengthInBytes, equals(144 * 96 * 4));
          return 'tex-$uploadCalls';
        },
      );
      expect(resolved, equals(const <String>['tex-1']));
      expect(uploadCalls, equals(1));
    });
  });
}
