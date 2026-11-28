import 'dart:typed_data';

import 'package:termui/termui.dart';
import 'package:test/test.dart';

KittyImageData _solidImage(
  int imageId, {
  int width = 2,
  int height = 2,
  int r = 255,
  int g = 0,
  int b = 0,
  int a = 255,
  int version = 0,
}) {
  final pixels = Uint8List(width * height * 4);
  for (var i = 0; i < pixels.length; i += 4) {
    pixels[i] = r;
    pixels[i + 1] = g;
    pixels[i + 2] = b;
    pixels[i + 3] = a;
  }
  return KittyImageData(
    imageId: imageId,
    pixelWidth: width,
    pixelHeight: height,
    rgbaPixels: pixels,
    gridCols: 2,
    gridRows: 1,
    version: version,
  );
}

void main() {
  group('KittyPlacement & KittyImageRegistry placements', () {
    test('registers, looks up, filters alt-screen, and removes placements', () {
      final registry = KittyImageRegistry();
      final rev0 = registry.revision;

      final pPrimary = const KittyPlacement(
        imageId: 7,
        placementId: 1,
        isAltScreen: false,
        gridCol: 3,
        gridRow: 4,
        cols: 5,
        rows: 2,
        srcX: 1,
        srcY: 2,
        srcWidth: 16,
        srcHeight: 8,
        cellOffsetX: 3,
        cellOffsetY: 5,
        zIndex: -1,
      );
      final pAlt = const KittyPlacement(
        imageId: 7,
        placementId: 2,
        isAltScreen: true,
        gridCol: 1,
        gridRow: 1,
        cols: 4,
        rows: 3,
        zIndex: KittyPlacement.underBackgroundZThreshold - 1,
        parentImageId: 7,
        parentPlacementId: 1,
        relCols: 2,
        relRows: -1,
      );

      registry.registerPlacement(pPrimary);
      expect(registry.revision, greaterThan(rev0));
      expect(registry.lookupPlacement(7, 1), equals(pPrimary));
      expect(registry.lookupPlacement(7, 99), isNull);

      registry.registerPlacement(pAlt);
      expect(registry.allPlacements.length, equals(2));
      expect(pPrimary.isRelative, isFalse);
      expect(pAlt.isRelative, isTrue);

      final altRevBefore = registry.revision;
      registry.activeAltScreen = true;
      expect(registry.activeAltScreen, isTrue);
      expect(registry.revision, equals(altRevBefore + 1));
      registry.activeAltScreen = true;
      expect(registry.revision, equals(altRevBefore + 1));

      final scrollRevBefore = registry.revision;
      registry.viewportScrollOffset = 5;
      expect(registry.viewportScrollOffset, equals(5));
      expect(registry.revision, equals(scrollRevBefore + 1));

      expect(registry.removePlacement(7, 1), isTrue);
      expect(registry.lookupPlacement(7, 1), isNull);
      expect(registry.lookupPlacement(7, 2), equals(pAlt));

      registry.clearPlacements(altScreen: true);
      expect(registry.hasPlacements, isFalse);
    });

    test(
      'shiftDirectPlacements moves only non-virtual non-relative matching-screen placements and evicts',
      () {
        final registry = KittyImageRegistry();
        registry
          ..registerPlacement(
            const KittyPlacement(
              imageId: 1,
              placementId: 1,
              gridCol: 0,
              gridRow: 2,
              cols: 4,
              rows: 2,
            ),
          )
          ..registerPlacement(
            const KittyPlacement(
              imageId: 1,
              placementId: 2,
              isVirtual: true,
              gridCol: 0,
              gridRow: 2,
              cols: 4,
              rows: 2,
            ),
          )
          ..registerPlacement(
            const KittyPlacement(
              imageId: 1,
              placementId: 3,
              gridCol: 0,
              gridRow: 2,
              cols: 4,
              rows: 2,
              parentImageId: 1,
              parentPlacementId: 1,
              relCols: 1,
              relRows: 1,
            ),
          )
          ..registerPlacement(
            const KittyPlacement(
              imageId: 2,
              placementId: 1,
              isAltScreen: true,
              gridCol: 0,
              gridRow: 2,
              cols: 4,
              rows: 2,
            ),
          );

        registry.shiftDirectPlacements(-1, altScreen: false);
        expect(registry.lookupPlacement(1, 1)?.gridRow, equals(1));
        expect(registry.lookupPlacement(1, 2)?.gridRow, equals(2));
        expect(registry.lookupPlacement(1, 3)?.gridRow, equals(2));
        expect(registry.lookupPlacement(2, 1)?.gridRow, equals(2));

        // Scrolling further up evicts placements whose bottom edge <= evictAboveRow.
        registry.shiftDirectPlacements(-3, altScreen: false, evictAboveRow: 0);
        expect(registry.lookupPlacement(1, 1), isNull);
        expect(registry.lookupPlacement(2, 1)?.gridRow, equals(2));
      },
    );
  });

  group('KittyAnimationState & KittyImageRegistry animations', () {
    test(
      'keeps stable per-frame KittyImageData identity, steps idempotently, and stops after loopCount',
      () {
        final registry = KittyImageRegistry();
        final frame1Img = _solidImage(10, r: 255);
        final frame2Img = _solidImage(10, g: 255, version: 1);
        registry.registerImage(frame1Img);

        expect(
          registry.registerAnimationFrame(
            10,
            KittyAnimationFrame(
              frameNumber: 1,
              imageData: frame1Img,
              gapMs: 50,
            ),
          ),
          isTrue,
        );
        expect(
          registry.registerAnimationFrame(
            10,
            KittyAnimationFrame(
              frameNumber: 2,
              imageData: frame2Img,
              gapMs: 50,
            ),
          ),
          isTrue,
        );

        expect(registry.hasRunningAnimations, isFalse);
        expect(
          registry.setAnimationPlayback(
            10,
            playback: KittyAnimationPlayback.running,
            loopCount: 1,
          ),
          isTrue,
        );
        expect(registry.hasRunningAnimations, isTrue);

        // Initial clock anchor does not advance.
        final rev0 = registry.revision;
        expect(registry.advanceAnimations(1000), isFalse);
        expect(registry.revision, equals(rev0));
        expect(registry.activeImageData(10), same(frame1Img));

        // Stepping to frame 2 returns the exact stable KittyImageData instance.
        expect(registry.advanceAnimations(1050), isTrue);
        final rev1 = registry.revision;
        expect(rev1, equals(rev0 + 1));
        expect(registry.activeImageData(10), same(frame2Img));

        // Second surface calling advanceAnimations with identical nowMs is a no-op.
        expect(registry.advanceAnimations(1050), isFalse);
        expect(registry.revision, equals(rev1));
        expect(registry.activeImageData(10), same(frame2Img));

        // Completing loop 1 stops playback and clears hasRunningAnimations.
        expect(registry.advanceAnimations(1100), isTrue);
        expect(registry.hasRunningAnimations, isFalse);
        expect(
          registry.lookupAnimation(10)?.playback,
          equals(KittyAnimationPlayback.stopped),
        );
        expect(registry.activeImageData(10), same(frame2Img));
      },
    );

    test(
      'composeAnimationFrame alpha-blends and replaces while producing new stable imageData',
      () {
        final registry = KittyImageRegistry();
        final baseImg = _solidImage(
          11,
          width: 2,
          height: 2,
          r: 0,
          g: 0,
          b: 200,
          a: 255,
        );
        final overlayImg = _solidImage(
          11,
          width: 2,
          height: 2,
          r: 200,
          g: 0,
          b: 0,
          a: 128,
          version: 1,
        );
        registry
          ..registerImage(baseImg)
          ..registerAnimationFrame(
            11,
            KittyAnimationFrame(frameNumber: 2, imageData: overlayImg),
          );

        final revBefore = registry.revision;
        expect(
          registry.composeAnimationFrame(
            11,
            sourceFrameNumber: 2,
            destFrameNumber: 1,
            dstX: 1,
            dstY: 0,
            width: 1,
            height: 1,
          ),
          isTrue,
        );
        expect(registry.revision, equals(revBefore + 1));

        final composed = registry.activeImageData(11)!;
        expect(composed, isNot(same(baseImg)));
        // Unmodified pixel (0, 0) stays pure blue.
        expect(composed.rgbaPixels.sublist(0, 4), equals([0, 0, 200, 255]));
        // Blended pixel (1, 0) mixes red over blue.
        expect(composed.rgbaPixels[4], greaterThan(80));
        expect(composed.rgbaPixels[6], greaterThan(80));
        expect(composed.rgbaPixels[7], equals(255));
        // Repeated reads keep exact same instance.
        expect(registry.activeImageData(11), same(composed));

        // Replace mode overwrites alpha directly.
        expect(
          registry.composeAnimationFrame(
            11,
            sourceFrameNumber: 2,
            destFrameNumber: 1,
            dstX: 0,
            dstY: 0,
            width: 1,
            height: 1,
            replace: true,
          ),
          isTrue,
        );
        final replaced = registry.activeImageData(11)!;
        expect(replaced.rgbaPixels.sublist(0, 4), equals([200, 0, 0, 128]));
      },
    );

    test('enforces maxFramesPerImage (64) and maxAnimationBytes (32 MiB)', () {
      final registry = KittyImageRegistry();
      for (var i = 1; i <= KittyImageRegistry.maxFramesPerImage; i++) {
        expect(
          registry.registerAnimationFrame(
            20,
            KittyAnimationFrame(
              frameNumber: i,
              imageData: _solidImage(20, width: 1, height: 1, version: i),
            ),
          ),
          isTrue,
        );
      }
      expect(
        registry.registerAnimationFrame(
          20,
          KittyAnimationFrame(
            frameNumber: 65,
            imageData: _solidImage(20, width: 1, height: 1, version: 65),
          ),
        ),
        isFalse,
      );

      // 32 MiB byte cap: 4 frames of 9 MiB -> 3 succeed (27 MiB), 4th fails (36 MiB).
      final bigRegistry = KittyImageRegistry();
      final nineMiB = Uint8List(9 * 1024 * 1024);
      for (var i = 1; i <= 3; i++) {
        expect(
          bigRegistry.registerAnimationFrame(
            30,
            KittyAnimationFrame(
              frameNumber: i,
              imageData: KittyImageData(
                imageId: 30,
                pixelWidth: 1536,
                pixelHeight: 1536,
                rgbaPixels: nineMiB,
                gridCols: 4,
                gridRows: 4,
                version: i,
              ),
            ),
          ),
          isTrue,
        );
      }
      expect(
        bigRegistry.registerAnimationFrame(
          30,
          KittyAnimationFrame(
            frameNumber: 4,
            imageData: KittyImageData(
              imageId: 30,
              pixelWidth: 1536,
              pixelHeight: 1536,
              rgbaPixels: nineMiB,
              gridCols: 4,
              gridRows: 4,
              version: 4,
            ),
          ),
        ),
        isFalse,
      );
      expect(bigRegistry.removeAnimationFrames(30), isTrue);
      expect(bigRegistry.totalAnimationBytes, equals(0));
    });

    test(
      'exact animation byte accounting prevents leaks, underflows, cross-image corruption, and phantom states',
      () {
        final registry = KittyImageRegistry();

        // (a) registerImage(f1) + explicit registerAnimationFrame(id, f1) + removeAnimationFrames -> 0.
        final f1 = _solidImage(40, width: 4, height: 4); // 64 bytes
        registry.registerImage(f1);
        expect(
          registry.registerAnimationFrame(
            40,
            KittyAnimationFrame(frameNumber: 1, imageData: f1),
          ),
          isTrue,
        );
        expect(registry.totalAnimationBytes, equals(64));
        expect(registry.removeAnimationFrames(40), isTrue);
        expect(registry.totalAnimationBytes, equals(0));

        // (b) Replacing an auto-seeded frame 1 with a smaller frame never underflows < 0.
        final bigRoot = _solidImage(41, width: 8, height: 8); // 256 bytes
        final f2 = _solidImage(41, width: 4, height: 4, version: 1); // 64 bytes
        final smallF1 = _solidImage(
          41,
          width: 1,
          height: 1,
          version: 2,
        ); // 4 bytes
        registry.registerImage(bigRoot);
        expect(
          registry.registerAnimationFrame(
            41,
            KittyAnimationFrame(frameNumber: 2, imageData: f2),
          ),
          isTrue,
        );
        expect(registry.totalAnimationBytes, equals(64));
        expect(
          registry.registerAnimationFrame(
            41,
            KittyAnimationFrame(frameNumber: 1, imageData: smallF1),
          ),
          isTrue,
        );
        expect(registry.totalAnimationBytes, equals(68));
        expect(registry.removeAnimationFrames(41), isTrue);
        expect(registry.totalAnimationBytes, equals(0));

        // (c) unregisterImage after auto-seeded animation never corrupts another image's budget.
        final imgA = _solidImage(42, width: 8, height: 8); // 256 bytes
        final imgAF2 = _solidImage(
          42,
          width: 4,
          height: 4,
          version: 1,
        ); // 64 bytes
        final imgB = _solidImage(43, width: 4, height: 4); // 64 bytes
        final imgBF2 = _solidImage(
          43,
          width: 4,
          height: 4,
          version: 1,
        ); // 64 bytes
        registry
          ..registerImage(imgA)
          ..registerImage(imgB)
          ..registerAnimationFrame(
            42,
            KittyAnimationFrame(frameNumber: 2, imageData: imgAF2),
          )
          ..registerAnimationFrame(
            43,
            KittyAnimationFrame(frameNumber: 2, imageData: imgBF2),
          );
        expect(registry.totalAnimationBytes, equals(128));
        registry.unregisterImage(42);
        expect(registry.totalAnimationBytes, equals(64));
        registry.clearAnimations();
        expect(registry.totalAnimationBytes, equals(0));
        expect(registry.lookupAnimation(43), isNull);

        // Failed registerAnimationFrame / composeAnimationFrame leave no phantom state.
        final huge = KittyImageData(
          imageId: 44,
          pixelWidth: 4096,
          pixelHeight: 4096,
          rgbaPixels: Uint8List(KittyImageRegistry.maxAnimationBytes + 4),
          gridCols: 4,
          gridRows: 4,
        );
        expect(
          registry.registerAnimationFrame(
            44,
            KittyAnimationFrame(frameNumber: 1, imageData: huge),
          ),
          isFalse,
        );
        expect(registry.lookupAnimation(44), isNull);

        // composeAnimationFrame validates pixel buffer bounds and byte cap without phantom state.
        final malformed = KittyImageData(
          imageId: 45,
          pixelWidth: 4,
          pixelHeight: 4,
          rgbaPixels: Uint8List(4), // too small for 4x4*4
          gridCols: 1,
          gridRows: 1,
        );
        registry.registerImage(malformed);
        expect(
          registry.composeAnimationFrame(
            45,
            sourceFrameNumber: 1,
            destFrameNumber: 1,
          ),
          isFalse,
        );
        expect(registry.lookupAnimation(45), isNull);
      },
    );

    test(
      'out-of-order frame insertion preserves active frame, large nowMs fast-forwards finite loops, and shiftDirectPlacements cascades relative children',
      () {
        final registry = KittyImageRegistry();
        final f1 = _solidImage(50, r: 10);
        final f2 = _solidImage(50, g: 20, version: 1);
        final f3 = _solidImage(50, b: 30, version: 2);

        // Insert frame 3 first, then frame 1 before it: active frame stays frame 3.
        expect(
          registry.registerAnimationFrame(
            50,
            KittyAnimationFrame(frameNumber: 3, imageData: f3, gapMs: 50),
          ),
          isTrue,
        );
        expect(registry.activeImageData(50), same(f3));
        expect(
          registry.registerAnimationFrame(
            50,
            KittyAnimationFrame(frameNumber: 1, imageData: f1, gapMs: 50),
          ),
          isTrue,
        );
        expect(registry.activeImageData(50), same(f3));
        expect(registry.lookupAnimation(50)?.currentFrameIndex, equals(1));
        expect(
          registry.registerAnimationFrame(
            50,
            KittyAnimationFrame(frameNumber: 2, imageData: f2, gapMs: 50),
          ),
          isTrue,
        );
        expect(registry.activeImageData(50), same(f3));
        expect(registry.lookupAnimation(50)?.currentFrameIndex, equals(2));

        // Fast-forward finite loop across long sleep (3 frames * 50ms = 150ms/cycle, loopCount = 2).
        registry.setAnimationPlayback(
          50,
          playback: KittyAnimationPlayback.running,
          loopCount: 2,
          currentFrameNumber: 1,
        );
        expect(registry.advanceAnimations(1000), isFalse);
        expect(registry.advanceAnimations(100_000), isTrue);
        expect(registry.hasRunningAnimations, isFalse);
        expect(
          registry.lookupAnimation(50)?.playback,
          equals(KittyAnimationPlayback.stopped),
        );
        expect(registry.lookupAnimation(50)?.completedLoops, equals(2));

        // Cascade eviction of transitive relative children on shiftDirectPlacements.
        registry
          ..registerPlacement(
            const KittyPlacement(
              imageId: 60,
              placementId: 1,
              gridCol: 0,
              gridRow: 0,
              cols: 2,
              rows: 1,
            ),
          )
          ..registerPlacement(
            const KittyPlacement(
              imageId: 61,
              placementId: 1,
              cols: 2,
              rows: 1,
              parentImageId: 60,
              parentPlacementId: 1,
              relCols: 1,
              relRows: 0,
            ),
          )
          ..registerPlacement(
            const KittyPlacement(
              imageId: 62,
              placementId: 1,
              cols: 2,
              rows: 1,
              parentImageId: 61,
              parentPlacementId: 1,
              relCols: 1,
              relRows: 0,
            ),
          )
          ..registerPlacement(
            const KittyPlacement(
              imageId: 63,
              placementId: 1,
              gridCol: 0,
              gridRow: 5,
              cols: 2,
              rows: 1,
            ),
          );

        registry.shiftDirectPlacements(-1, altScreen: false, evictAboveRow: 0);
        expect(registry.lookupPlacement(60, 1), isNull);
        expect(registry.lookupPlacement(61, 1), isNull);
        expect(registry.lookupPlacement(62, 1), isNull);
        expect(registry.lookupPlacement(63, 1)?.gridRow, equals(4));
      },
    );
  });

  group('KittyTextSizing & Buffer sparse _textSizing', () {
    test('packs and unpacks all 28-bit fields including originDx = 48', () {
      const noneSizing = KittyTextSizing(KittyTextSizing.none);
      expect(noneSizing.isActive, isFalse);
      expect(noneSizing.fontScale, equals(1.0));

      final maxPacked = KittyTextSizing.pack(
        scale: 7,
        explicitWidth: 7,
        numerator: 14,
        denominator: 15,
        vAlign: 2,
        hAlign: 2,
        isContinuation: true,
        originDx: 48,
        originDy: 6,
      );
      expect(maxPacked.isActive, isTrue);
      expect(maxPacked.isAnchor, isFalse);
      expect(maxPacked.isContinuation, isTrue);
      expect(maxPacked.scale, equals(7));
      expect(maxPacked.explicitWidth, equals(7));
      expect(maxPacked.numerator, equals(14));
      expect(maxPacked.denominator, equals(15));
      expect(maxPacked.vAlign, equals(2));
      expect(maxPacked.hAlign, equals(2));
      expect(maxPacked.originDx, equals(48));
      expect(maxPacked.originDy, equals(6));
      expect(maxPacked.boxCols, equals(49));
      expect(maxPacked.boxRows, equals(7));
      expect(maxPacked.fraction, closeTo(14 / 15, 1e-9));
      expect(maxPacked.fontScale, closeTo(7 * 14 / 15, 1e-9));

      final anchor = KittyTextSizing.pack(
        scale: 2,
        explicitWidth: 1,
        numerator: 1,
        denominator: 2,
        vAlign: 1,
        hAlign: 0,
      );
      expect(anchor.isAnchor, isTrue);
      expect(anchor.isContinuation, isFalse);
      expect(anchor.originDx, equals(0));
      expect(anchor.originDy, equals(0));
      expect(anchor.fontScale, closeTo(1.0, 1e-9));
    });

    test(
      'Buffer lazily allocates _textSizing and propagates across clear, clearRect, copyFrom, copyCellAuxRangeFrom, resize, and Compositor',
      () {
        final buf = Buffer.blank(6, 4);
        expect(buf.hasTextSizing, isFalse);
        expect(buf.getTextSizing(0, 0), equals(KittyTextSizing.none));
        expect(buf.getTextSizingAt(0), equals(KittyTextSizing.none));

        // Writing 0 does not allocate.
        buf.setTextSizing(0, 0, KittyTextSizing.none);
        expect(buf.hasTextSizing, isFalse);

        final anchorBits = KittyTextSizing.pack(
          scale: 2,
          explicitWidth: 1,
        ).bits;
        final contBits = KittyTextSizing.pack(
          scale: 2,
          explicitWidth: 1,
          isContinuation: true,
          originDx: 1,
          originDy: 0,
        ).bits;

        buf
          ..setCell(1, 1, 'H', 0xFFFFFFFF, 0, Modifier.none, blend: false)
          ..setTextSizing(1, 1, anchorBits)
          ..setCell(2, 1, ' ', 0xFFFFFFFF, 0, Modifier.none, blend: false)
          ..setTextSizing(2, 1, contBits);
        expect(buf.hasTextSizing, isTrue);
        expect(buf.getTextSizing(1, 1), equals(anchorBits));
        expect(buf.getTextSizing(2, 1), equals(contBits));
        expect(buf.getTextSizingAt(1 * 6 + 1), equals(anchorBits));

        // copyCellAuxRangeFrom copies _textSizing.
        final auxDst = Buffer.blank(6, 4);
        auxDst.copyCellAuxRangeFrom(buf, 1 * 6, 1 * 6, 6);
        expect(auxDst.hasTextSizing, isTrue);
        expect(auxDst.getTextSizing(1, 1), equals(anchorBits));
        expect(auxDst.getTextSizing(2, 1), equals(contBits));

        // copyFrom copies cells and _textSizing with offset.
        final copyDst = Buffer.blank(8, 6);
        copyDst.copyFrom(buf, dx: 1, dy: 1);
        expect(copyDst.getCharacter(2, 2), equals('H'));
        expect(copyDst.getTextSizing(2, 2), equals(anchorBits));
        expect(copyDst.getTextSizing(3, 2), equals(contBits));

        // Compositor preserves both anchor and space-glyph continuation _textSizing.
        final compTarget = Buffer.blank(6, 4);
        Compositor().composite(
          target: compTarget,
          layers: [LayeredBuffer(buffer: buf, x: 0, y: 0, zIndex: 1)],
        );
        expect(compTarget.getTextSizing(1, 1), equals(anchorBits));
        expect(compTarget.getTextSizing(2, 1), equals(contBits));

        // resize preserves overlapping _textSizing.
        buf.resize(4, 3);
        expect(buf.getTextSizing(1, 1), equals(anchorBits));
        expect(buf.getTextSizing(2, 1), equals(contBits));

        // clearRect clears only the target rectangle.
        buf.clearRect(const Rect(2, 1, 1, 1));
        expect(buf.getTextSizing(1, 1), equals(anchorBits));
        expect(buf.getTextSizing(2, 1), equals(KittyTextSizing.none));

        // clear wipes all _textSizing entries.
        buf.clear();
        expect(buf.getTextSizing(1, 1), equals(KittyTextSizing.none));
      },
    );

    test(
      'Viewport delegates textSizing/clearRect/copyFrom and sliceTextSizing/writeTextSizingSlice round-trip',
      () {
        final parent = Buffer.blank(8, 4);
        final vp = Viewport(parent, const Rect(2, 1, 4, 2));
        final bits = KittyTextSizing.pack(scale: 3, explicitWidth: 2).bits;

        vp
          ..setCell(1, 0, 'X', 0xFFFFFFFF, 0, Modifier.none, blend: false)
          ..setTextSizing(1, 0, bits);
        expect(vp.hasTextSizing, isTrue);
        expect(vp.getTextSizing(1, 0), equals(bits));
        expect(parent.getTextSizing(3, 1), equals(bits));

        final slice = parent.sliceTextSizing(1 * 8, 2 * 8);
        expect(slice, isNotNull);
        expect(slice![3], equals(bits));
        expect(parent.sliceTextSizing(0, 8), isNull);

        final restored = Buffer.blank(8, 4);
        restored.writeCellAuxSlices(0, 8, textSizing: slice);
        expect(restored.getTextSizing(3, 0), equals(bits));

        final restored2 = Buffer.blank(8, 4);
        restored2.writeTextSizingSlice(0, 8, slice);
        expect(restored2.getTextSizing(3, 0), equals(bits));

        final regInside = KittyImageRegistry();
        final regOutside = KittyImageRegistry();
        parent
          ..registerKittyRegistry(const Rect(0, 0, 5, 3), regInside)
          ..registerKittyRegistry(const Rect(6, 0, 2, 1), regOutside);
        expect(parent.scopedKittyRegistries.length, equals(2));
        final vpRegs = vp.scopedKittyRegistries;
        expect(vpRegs.length, equals(1));
        expect(vpRegs.first.registry, same(regInside));
        expect(vpRegs.first.bounds, equals(const Rect(0, 0, 3, 2)));

        // Buffer.cellsEqual and Viewport.cellsEqual differentiate symmetrically by textSizing.
        final other = Buffer.blank(8, 4);
        other.copyFrom(parent);
        final otherVp = Viewport(other, const Rect(2, 1, 4, 2));
        expect(parent.cellsEqual(3, 1, other, 3, 1), isTrue);
        expect(vp.cellsEqual(1, 0, other, 3, 1), isTrue);
        expect(vp.cellsEqual(1, 0, otherVp, 1, 0), isTrue);
        other.setTextSizing(3, 1, KittyTextSizing.none);
        expect(parent.cellsEqual(3, 1, other, 3, 1), isFalse);
        expect(vp.cellsEqual(1, 0, other, 3, 1), isFalse);
        expect(otherVp.cellsEqual(1, 0, vp, 1, 0), isFalse);

        // Viewport clearRect clears parent region.
        vp.clearRect(const Rect(1, 0, 1, 1));
        expect(parent.getTextSizing(3, 1), equals(KittyTextSizing.none));
      },
    );

    test(
      'clearImages preserves activeAltScreen and viewportScrollOffset state (PR #501 H2)',
      () {
        final reg = KittyImageRegistry();
        reg
          ..activeAltScreen = true
          ..viewportScrollOffset = 7
          ..registerImage(_solidImage(1));

        reg.clearImages();

        expect(reg.hasImages, isFalse);
        expect(reg.activeAltScreen, isTrue);
        expect(reg.viewportScrollOffset, equals(7));
      },
    );

    test(
      'paused loading animation clears lastStepMs so newly uploaded frames do not skip on resume (PR #501 M1)',
      () {
        final reg = KittyImageRegistry();
        reg.registerImage(_solidImage(50));
        reg.registerAnimationFrame(
          50,
          KittyAnimationFrame(
            frameNumber: 2,
            imageData: _solidImage(50, r: 0x11),
            gapMs: 100,
          ),
        );
        reg.setAnimationPlayback(
          50,
          playback: KittyAnimationPlayback.loading,
          frameGapMs: 100,
        );

        // Initialize timer at t=1000, advance onto frame 2 at t=1100 -> stalls in loading.
        expect(reg.advanceAnimations(1000), isFalse);
        expect(reg.advanceAnimations(1100), isTrue);
        expect(reg.lookupAnimation(50)!.currentFrameNumber, equals(2));
        expect(reg.lookupAnimation(50)!.isActivelyStepping, isFalse);

        // Long idle pause before frames 3 and 4 arrive at t=10000.
        reg.registerAnimationFrame(
          50,
          KittyAnimationFrame(
            frameNumber: 3,
            imageData: _solidImage(50, r: 0x22),
            gapMs: 100,
          ),
        );
        reg.registerAnimationFrame(
          50,
          KittyAnimationFrame(
            frameNumber: 4,
            imageData: _solidImage(50, r: 0x33),
            gapMs: 100,
          ),
        );
        expect(reg.lookupAnimation(50)!.isActivelyStepping, isTrue);

        // First tick after resume should re-anchor lastStepMs at t=10000 instead of skipping frame 3.
        expect(reg.advanceAnimations(10000), isFalse);
        expect(reg.lookupAnimation(50)!.currentFrameNumber, equals(2));

        // After 100ms, steps smoothly to frame 3 (not jumping past it).
        expect(reg.advanceAnimations(10100), isTrue);
        expect(reg.lookupAnimation(50)!.currentFrameNumber, equals(3));
      },
    );
  });
}
