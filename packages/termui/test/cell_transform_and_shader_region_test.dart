import 'dart:typed_data';

import 'package:termui/termui.dart';
import 'package:test/test.dart';

void main() {
  group('CellTransform & CellTween', () {
    test('clamps non-finite and out-of-range values on sanitize', () {
      const rawTween = CellTween(
        animationId: 999999,
        endDx: double.nan,
        endDy: double.infinity,
        endScaleX: 10.0,
        endScaleY: -2.0,
        endRotationRad: double.negativeInfinity,
        endAlpha: 5.0,
        durationSec: 120.0,
        easing: CellTweenEasing.easeOut,
        fromCurrent: true,
        clearOnFinish: true,
      );
      const raw = CellTransform(
        dx: double.nan,
        dy: -1.5,
        scaleX: 8.0,
        scaleY: -0.5,
        rotationRad: double.infinity,
        alpha: -1.0,
        zLayer: 999,
        tween: rawTween,
      );

      final clean = raw.sanitized();
      expect(clean.dx, 0.0);
      expect(clean.dy, -1.5);
      expect(clean.scaleX, 4.0);
      expect(clean.scaleY, 0.0);
      expect(clean.rotationRad, 0.0);
      expect(clean.alpha, 0.0);
      expect(clean.zLayer, 127);

      final tw = clean.tween!;
      expect(tw.animationId, 0xFFFF);
      expect(tw.endDx, 0.0);
      expect(tw.endDy, 0.0);
      expect(tw.endScaleX, 4.0);
      expect(tw.endScaleY, 0.0);
      expect(tw.endRotationRad, 0.0);
      expect(tw.endAlpha, 1.0);
      expect(tw.durationSec, 30.0);
      expect(tw.easing, CellTweenEasing.easeOut);
      expect(tw.fromCurrent, isTrue);
      expect(tw.clearOnFinish, isTrue);
    });

    test('easing curves map 0->0, 1->1, and monotonic midpoints', () {
      for (final ease in CellTweenEasing.values) {
        expect(ease.evaluate(0.0), closeTo(0.0, 1e-6));
        expect(ease.evaluate(1.0), closeTo(1.0, 1e-6));
        expect(ease.evaluate(0.5), inInclusiveRange(0.0, 1.0));
      }
      expect(CellTweenEasing.easeIn.evaluate(0.5), lessThan(0.5));
      expect(CellTweenEasing.easeOut.evaluate(0.5), greaterThan(0.5));
      expect(CellTweenEasing.easeInOut.evaluate(0.5), closeTo(0.5, 1e-6));
    });

    test('CellTransformCodec packs and unpacks exact 64-byte stride', () {
      const tween = CellTween(
        animationId: 42,
        endDx: 4.0,
        endDy: 12.5,
        endScaleX: 1.5,
        endScaleY: 0.75,
        endRotationRad: 3.14,
        endAlpha: 0.25,
        durationSec: 0.8,
        easing: CellTweenEasing.easeInOut,
        fromCurrent: true,
        clearOnFinish: true,
      );
      final entries = <CellTransformEntry>[
        (
          col: 10,
          row: 4,
          transform: const CellTransform(
            dx: 0.5,
            dy: -0.25,
            scaleX: 1.25,
            scaleY: 2.0,
            rotationRad: 0.5,
            alpha: 0.8,
            zLayer: -3,
            tween: tween,
          ),
        ),
        (col: 11, row: 4, transform: null),
      ];

      final packed = CellTransformCodec.packBatch(entries);
      expect(packed.length, 128);

      final unpacked = CellTransformCodec.unpackBatch(packed);
      expect(unpacked.length, 2);
      expect(unpacked[0].col, 10);
      expect(unpacked[0].row, 4);
      final t = unpacked[0].transform!;
      expect(t.dx, closeTo(0.5, 1e-5));
      expect(t.dy, closeTo(-0.25, 1e-5));
      expect(t.scaleX, closeTo(1.25, 1e-5));
      expect(t.scaleY, closeTo(2.0, 1e-5));
      expect(t.rotationRad, closeTo(0.5, 1e-5));
      expect(t.alpha, closeTo(0.8, 1e-5));
      expect(t.zLayer, -3);
      expect(t.tween!.animationId, 42);
      expect(t.tween!.endDy, closeTo(12.5, 1e-5));
      expect(t.tween!.easing, CellTweenEasing.easeInOut);
      expect(t.tween!.fromCurrent, isTrue);
      expect(t.tween!.clearOnFinish, isTrue);
      expect(unpacked[1].col, 11);
      expect(unpacked[1].row, 4);
      expect(unpacked[1].transform, isNull);
    });

    test(
      'CellTransformCodec rejects non-multiple stride, NaN, and reserved bytes',
      () {
        expect(
          () => CellTransformCodec.unpackBatch(Uint8List(63)),
          throwsFormatException,
        );

        final badReserved = Uint8List(64);
        ByteData.sublistView(badReserved).setUint32(60, 1, Endian.little);
        expect(
          () => CellTransformCodec.unpackBatch(badReserved),
          throwsFormatException,
        );

        final nanPayload = Uint8List(64);
        ByteData.sublistView(
          nanPayload,
        ).setFloat32(8, double.nan, Endian.little);
        expect(
          () => CellTransformCodec.unpackBatch(nanPayload),
          throwsFormatException,
        );
      },
    );

    test(
      'CellTransformTable supports sparse set, shiftRows, resize, and 4096 cap',
      () {
        final table = CellTransformTable();
        expect(table.isEmpty, isTrue);

        table.set(5, CellTransform.identity);
        expect(table.isEmpty, isTrue);

        table.set(12, const CellTransform(dx: 1.0)); // col 2, row 1 in 10x5
        table.set(2, const CellTransform(dy: 2.0)); // col 2, row 0 in 10x5
        table.shiftRows(
          -1,
          10,
          5,
        ); // scroll up 1 row: row 0 evicted, row 1 -> row 0
        expect(table.length, 1);
        expect(table[2], const CellTransform(dx: 1.0));

        table.resize(10, 5, 2, 5); // col 2 out of bounds in width 2
        expect(table.isEmpty, isTrue);

        for (var i = 0; i < CellTransformTable.maxEntries + 100; i++) {
          table.set(i, const CellTransform(dx: 0.25));
        }
        expect(table.length, CellTransformTable.maxEntries);
      },
    );
  });

  group('ShaderRegion & Buffer metadata propagation', () {
    test('clamps padding and params and enforces max 8 regions', () {
      final region = ShaderRegion(
        id: 'fire_word',
        shaderId: 'fire',
        sourceRects: const [Rect(2, 1, 4, 1)],
        padding: const CellPadding(top: 12, right: -2, bottom: 3, left: 9),
        params: Float32List.fromList([20.0, -25.0, double.nan, 1.5]),
      );
      expect(
        region.padding,
        const CellPadding(top: 8, right: 0, bottom: 3, left: 8),
      );
      expect(region.params.length, 8);
      expect(region.params[0], 16.0);
      expect(region.params[1], -16.0);
      expect(region.params[2], 0.0);
      expect(region.params[3], closeTo(1.5, 1e-5));

      final buf = Buffer(20, 10);
      expect(buf.hasCellTransforms, isFalse);
      expect(buf.cellTransforms, isNull);
      for (var i = 0; i < 12; i++) {
        buf.addShaderRegion(
          ShaderRegion(
            id: 'r$i',
            shaderId: 'fire',
            sourceRects: const [Rect(0, 0, 4, 1)],
          ),
        );
      }
      expect(buf.shaderRegions.length, ShaderRegion.maxRegionsPerPane);
    });

    test(
      'propagates shaderRegions and cellTransforms with offset and clip',
      () {
        final src = Buffer(10, 5);
        src.addShaderRegion(
          ShaderRegion(
            id: 'r1',
            shaderId: 'fire',
            sourceRects: const [Rect(1, 1, 4, 1), Rect(0, 2, 3, 1)],
            padding: const CellPadding(top: 2),
          ),
        );
        src.setCellTransform(
          2,
          1,
          const CellTransform(dx: 0.5, rotationRad: 0.2),
        );
        src.setCellTransform(9, 4, const CellTransform(dx: 1.0));

        final dst = Buffer(20, 10);
        dst.propagateMetadataFrom(
          src,
          dx: 5,
          dy: 3,
          clip: const Rect(5, 3, 6, 3),
        );

        expect(dst.shaderRegions.length, 1);
        expect(dst.shaderRegions.single.sourceRects, const [
          Rect(6, 4, 4, 1),
          Rect(5, 5, 3, 1),
        ]);
        expect(
          dst.getCellTransform(7, 4),
          const CellTransform(dx: 0.5, rotationRad: 0.2),
        );
        // (5+9, 3+4) = (14, 7) is outside clip Rect(5,3,6,3)
        expect(dst.getCellTransform(14, 7), isNull);

        dst.clear();
        expect(dst.hasShaderRegions, isFalse);
        expect(dst.hasCellTransforms, isFalse);
      },
    );

    test(
      'ShaderApcEncoder encodes wrapped rects with / and chunks defines & xforms',
      () {
        final regionWire = ShaderApcEncoder.encodeRegion(
          ShaderRegion(
            id: 'r1',
            shaderId: 'fire',
            sourceRects: const [Rect(10, 4, 4, 1), Rect(0, 5, 6, 1)],
            padding: const CellPadding(top: 2, right: 1, bottom: 0, left: 1),
            params: Float32List.fromList([1.2, 0, 0, 0, 0, 0, 0, 0]),
          ),
        );
        expect(
          regionWire,
          '\x1b_Sa=region,id=r1,s=fire,rects=10:4:4:1/0:5:6:1,pad=2:1:0:1,p0=1.2\x1b\\',
        );
        expect(regionWire.contains(';'), isFalse);

        final bigGlsl =
            '// ${'x' * 9000}\nvoid mainImage(out vec4 c, in vec2 u){c=vec4(1.);}';
        final defineChunks = ShaderApcEncoder.encodeDefine(
          id: 'custom_fire',
          glslSource: bigGlsl,
          persist: true,
          chunkRawBytes: 3000,
        );
        expect(defineChunks.length, greaterThan(2));
        expect(
          defineChunks.first,
          contains('a=define,id=custom_fire,persist=1,m=1;'),
        );
        expect(defineChunks.last, contains('a=define,id=custom_fire,m=0;'));

        final batchEntries = List<CellTransformEntry>.generate(
          1000,
          (i) => (
            col: i % 80,
            row: i ~/ 80,
            transform: const CellTransform(dx: 1.0, dy: 2.0),
          ),
        );
        final batchChunks = ShaderApcEncoder.encodeTransformsBatch(
          batchEntries,
          replace: true,
        );
        expect(batchChunks.length, 2);
        for (final frame in batchChunks) {
          expect(frame.length, lessThanOrEqualTo(64 * 1024));
        }
      },
    );
  });
}
