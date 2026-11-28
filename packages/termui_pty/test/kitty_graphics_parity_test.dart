import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:termui/termui.dart';
import 'package:termui_pty/src/kitty_apc_handler.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:test/test.dart';

typedef _DirectPlaceCall = ({
  int cols,
  int rows,
  int imageId,
  bool advanceCursor,
  int placementId,
});

typedef _ClearAtCall = ({int? col, int? row, int? zIndex});

Uint8List _solidRgba(int width, int height, int r, int g, int b, int a) {
  final out = Uint8List(width * height * 4);
  for (var i = 0; i < out.length; i += 4) {
    out[i] = r;
    out[i + 1] = g;
    out[i + 2] = b;
    out[i + 3] = a;
  }
  return out;
}

final class _HandlerHarness {
  final KittyImageRegistry registry = KittyImageRegistry();
  final List<String> replies = [];
  final List<_DirectPlaceCall> directPlaces = [];
  final List<(int cols, int rows)> cursorAdvances = [];
  final List<_ClearAtCall> clearAtCalls = [];
  final List<(int? imageId, int? placementId, bool directOnly)> clearCalls = [];

  int cursorCol = 0;
  int cursorRow = 0;
  int viewportCols = 80;
  int viewportRows = 24;
  int cellW = 8;
  int cellH = 16;
  bool altScreen = false;

  late final KittyApcHandler handler;

  _HandlerHarness({
    bool allowLocalMedia = false,
    bool allowLocalFiles = false,
  }) {
    handler = KittyApcHandler(
      registry: registry,
      onReply: replies.add,
      onPlaceVirtual: (cols, rows, imageId, advanceCursor, placementId) {
        directPlaces.add((
          cols: cols,
          rows: rows,
          imageId: imageId,
          advanceCursor: advanceCursor,
          placementId: placementId,
        ));
      },
      onClearPlacements: (imageId, {placementId, directOnly = false}) {
        clearCalls.add((imageId, placementId, directOnly));
      },
      cellPixelSize: () => (cellW, cellH),
      cursorPosition: () => (cursorCol, cursorRow),
      viewportSize: () => (viewportCols, viewportRows),
      isAltScreen: () => altScreen,
      onAdvanceCursor: (cols, rows) => cursorAdvances.add((cols, rows)),
      onClearPlacementsAt: ({col, row, zIndex}) {
        clearAtCalls.add((col: col, row: row, zIndex: zIndex));
      },
      allowLocalMedia: allowLocalMedia,
      allowLocalFiles: allowLocalFiles,
    );
  }

  void send(String apcBody) => handler.handleApc('G$apcBody');
}

void main() {
  group('Kitty Graphics source crop & sub-cell offsets', () {
    test('clamps x,y,w,h source crop and X,Y sub-cell offsets on a=T and a=p', () {
      final h = _HandlerHarness()
        ..cursorCol = 3
        ..cursorRow = 2
        ..cellW = 10
        ..cellH = 20;

      final imgBytes = _solidRgba(32, 24, 255, 0, 0, 255);
      final b64 = base64Encode(imgBytes);

      // Standard z=0 direct placement with in-bounds crop and sub-cell offset:
      // must BOTH preserve onPlaceVirtual compatibility AND register KittyPlacement.
      h.send(
        'a=T,i=1,p=1,f=32,s=32,v=24,x=4,y=6,w=20,h=12,X=5,Y=11,c=2,r=1;$b64',
      );
      expect(h.replies, equals(['\x1b_Gi=1,p=1;OK\x1b\\']));
      expect(h.directPlaces, hasLength(1));
      expect(h.directPlaces.single.imageId, equals(1));
      expect(h.directPlaces.single.cols, equals(2));
      expect(h.directPlaces.single.rows, equals(1));

      final p1 = h.registry.lookupPlacement(1, 1);
      expect(p1, isNotNull);
      expect(p1!.gridCol, equals(3));
      expect(p1.gridRow, equals(2));
      expect(p1.srcX, equals(4));
      expect(p1.srcY, equals(6));
      expect(p1.srcWidth, equals(20));
      expect(p1.srcHeight, equals(12));
      expect(p1.cellOffsetX, equals(5));
      expect(p1.cellOffsetY, equals(11));
      expect(p1.zIndex, equals(0));
      expect(p1.isAltScreen, isFalse);

      // Oversized crop (x=28, w=20 -> clamped to 4; y=20, h=50 -> clamped to 4)
      // and oversized sub-cell offsets (X=99 -> 9, Y=99 -> 19) on a=p.
      h.replies.clear();
      h.send('a=p,i=1,p=2,x=28,y=20,w=20,h=50,X=99,Y=99,C=1');
      expect(h.replies, equals(['\x1b_Gi=1,p=2;OK\x1b\\']));

      final p2 = h.registry.lookupPlacement(1, 2);
      expect(p2, isNotNull);
      expect(p2!.srcX, equals(28));
      expect(p2.srcY, equals(20));
      expect(p2.srcWidth, equals(4));
      expect(p2.srcHeight, equals(4));
      expect(p2.cellOffsetX, equals(9));
      expect(p2.cellOffsetY, equals(19));

      // Negative crop/offset values clamp to 0; x beyond width yields srcWidth=0.
      h.send('a=p,i=1,p=3,x=-5,y=-2,w=10,h=10,X=-3,Y=-4,c=1,r=1');
      final p3 = h.registry.lookupPlacement(1, 3)!;
      expect(p3.srcX, equals(0));
      expect(p3.srcY, equals(0));
      expect(p3.srcWidth, equals(10));
      expect(p3.srcHeight, equals(10));
      expect(p3.cellOffsetX, equals(0));
      expect(p3.cellOffsetY, equals(0));

      // Chunked a=T preserves crop/offset/z metadata from chunk 0 to m=0.
      final mid = b64.length ~/ 2;
      h.replies.clear();
      h.send(
        'a=T,i=2,p=4,f=32,s=32,v=24,x=2,y=3,w=10,h=8,X=4,Y=7,z=-1,c=2,r=1,m=1;'
        '${b64.substring(0, mid)}',
      );
      expect(h.registry.lookupPlacement(2, 4), isNull);
      h.send('m=0;${b64.substring(mid)}');
      expect(h.replies, equals(['\x1b_Gi=2,p=4;OK\x1b\\']));
      final p4 = h.registry.lookupPlacement(2, 4)!;
      expect(p4.srcX, equals(2));
      expect(p4.srcY, equals(3));
      expect(p4.srcWidth, equals(10));
      expect(p4.srcHeight, equals(8));
      expect(p4.cellOffsetX, equals(4));
      expect(p4.cellOffsetY, equals(7));
      expect(p4.zIndex, equals(-1));
    });
  });

  group('Kitty Graphics layered z-index placements & cursor advance', () {
    test(
      'z=-1 and z=-1073741825 register without overwriting text cells and honor C=0 / C=1',
      () {
        final h = _HandlerHarness()
          ..cursorCol = 1
          ..cursorRow = 2;
        final b64 = base64Encode(_solidRgba(2, 2, 10, 20, 30, 255));

        // z=-1 (behind text, above bg) with C=0 (default): advances cursor, skips onPlaceVirtual.
        h.send('a=T,i=10,p=1,f=32,s=2,v=2,c=4,r=3,z=-1;$b64');
        expect(h.replies, equals(['\x1b_Gi=10,p=1;OK\x1b\\']));
        expect(h.directPlaces, isEmpty);
        expect(h.cursorAdvances, equals([(4, 3)]));

        final bgPlacement = h.registry.lookupPlacement(10, 1)!;
        expect(bgPlacement.zIndex, equals(-1));
        expect(bgPlacement.gridCol, equals(1));
        expect(bgPlacement.gridRow, equals(2));
        expect(bgPlacement.cols, equals(4));
        expect(bgPlacement.rows, equals(3));
        expect(bgPlacement.isAltScreen, isFalse);

        // z=-1073741825 (< underBackgroundZThreshold) with C=1 on alt screen:
        // does NOT advance cursor and records isAltScreen=true.
        h
          ..altScreen = true
          ..cursorCol = 5
          ..cursorRow = 6
          ..replies.clear()
          ..cursorAdvances.clear();
        h.send('a=p,i=10,p=2,c=3,r=2,z=-1073741825,C=1');
        expect(h.replies, equals(['\x1b_Gi=10,p=2;OK\x1b\\']));
        expect(h.directPlaces, isEmpty);
        expect(h.cursorAdvances, isEmpty);

        final underBg = h.registry.lookupPlacement(10, 2)!;
        expect(underBg.zIndex, equals(-1073741825));
        expect(
          underBg.zIndex,
          lessThan(KittyPlacement.underBackgroundZThreshold),
        );
        expect(underBg.isAltScreen, isTrue);
        expect(underBg.gridCol, equals(5));
        expect(underBg.gridRow, equals(6));
      },
    );
  });

  group('Kitty Graphics relative placements (P,Q,H,V), cycles & cascade delete', () {
    test(
      'resolves P,Q,H,V chains, rejects cycles and missing parents, and cascade-deletes children',
      () {
        final h = _HandlerHarness()
          ..cursorCol = 2
          ..cursorRow = 1;
        final b64 = base64Encode(_solidRgba(1, 1, 255, 255, 0, 255));

        // Upload images 1, 2, 3 and place root parent (1, 1) at (2, 1).
        h.send('a=T,i=1,p=1,f=32,s=1,v=1,c=3,r=2;$b64');
        h.send('a=t,i=2,f=32,s=1,v=1;$b64');
        h.send('a=t,i=3,f=32,s=1,v=1;$b64');
        h
          ..directPlaces.clear()
          ..cursorAdvances.clear()
          ..replies.clear();

        // Missing parent returns ENOENT.
        h.send('a=p,i=2,p=1,P=999,Q=1,H=1,V=1,c=2,r=1');
        expect(
          h.replies.single,
          equals('\x1b_Gi=2,p=1;ENOENT:parent placement not found\x1b\\'),
        );
        expect(h.registry.lookupPlacement(2, 1), isNull);

        // Self-cycle returns EINVAL:relative placement cycle.
        h.replies.clear();
        h.send('a=p,i=1,p=1,P=1,Q=1,H=1,V=0,c=2,r=1');
        expect(
          h.replies.single,
          equals('\x1b_Gi=1,p=1;EINVAL:relative placement cycle\x1b\\'),
        );

        // Valid child (2, 1) relative to (1, 1) with C=0 advances cursor without overwriting cells.
        h.replies.clear();
        h.send('a=p,i=2,p=1,P=1,Q=1,H=4,V=-1,c=2,r=1');
        expect(h.replies.single, equals('\x1b_Gi=2,p=1;OK\x1b\\'));
        expect(h.directPlaces, isEmpty);
        expect(h.cursorAdvances, equals([(2, 1)]));

        final child = h.registry.lookupPlacement(2, 1)!;
        expect(child.isRelative, isTrue);
        expect(child.parentImageId, equals(1));
        expect(child.parentPlacementId, equals(1));
        expect(child.relCols, equals(4));
        expect(child.relRows, equals(-1));
        expect(child.gridCol, equals(6));
        expect(child.gridRow, equals(0));

        // Grandchild (3, 1) relative to (2, 1) with C=1 does NOT advance cursor.
        h
          ..replies.clear()
          ..cursorAdvances.clear();
        h.send('a=p,i=3,p=1,P=2,Q=1,H=1,V=2,c=1,r=1,C=1');
        expect(h.replies.single, equals('\x1b_Gi=3,p=1;OK\x1b\\'));
        expect(h.cursorAdvances, isEmpty);

        // Indirect 3-node cycle: attempting to set (1, 1)'s parent to (3, 1) fails with cycle error.
        h.replies.clear();
        h.send('a=p,i=1,p=1,P=3,Q=1,H=0,V=0,c=3,r=2');
        expect(
          h.replies.single,
          equals('\x1b_Gi=1,p=1;EINVAL:relative placement cycle\x1b\\'),
        );
        expect(h.registry.lookupPlacement(1, 1)?.isRelative, isFalse);

        // Deleting parent (1, 1) with d=I cascades to (2, 1) and (3, 1) and frees all 3 images!
        h.send('a=d,d=I,i=1,p=1');
        expect(h.registry.lookupPlacement(1, 1), isNull);
        expect(h.registry.lookupPlacement(2, 1), isNull);
        expect(h.registry.lookupPlacement(3, 1), isNull);
        expect(h.registry.lookupImage(1), isNull);
        expect(h.registry.lookupImage(2), isNull);
        expect(h.registry.lookupImage(3), isNull);
      },
    );
  });

  group('Kitty Graphics extended deletes (d=c/p/q/x/y/z/f)', () {
    test(
      'deletes by cursor, cell, cell+z, column, row, z-index, and animation frames',
      () {
        final h = _HandlerHarness();
        final b64 = base64Encode(_solidRgba(2, 2, 100, 150, 200, 255));

        for (var id = 1; id <= 6; id++) {
          h.send('a=t,i=$id,f=32,s=2,v=2;$b64');
        }

        // Placement (1,1): cols 0..1, rows 0..1, z=0
        h
          ..cursorCol = 0
          ..cursorRow = 0;
        h.send('a=p,i=1,p=1,c=2,r=2,C=1');
        // Relative child (6,1) of (1,1) at +5 col
        h.send('a=p,i=6,p=1,P=1,Q=1,H=5,V=0,c=1,r=1,C=1');
        // Placement (2,1): cols 0..1, rows 0..1, z=-1
        h.send('a=p,i=2,p=1,c=2,r=2,z=-1,C=1');
        // Placement (3,1): cols 4..5, rows 2..3, z=2
        h
          ..cursorCol = 4
          ..cursorRow = 2;
        h.send('a=p,i=3,p=1,c=2,r=2,z=2,C=1');
        // Placement (4,1): cols 8..9, rows 5..6, z=-1073741825
        h
          ..cursorCol = 8
          ..cursorRow = 5;
        h.send('a=p,i=4,p=1,c=2,r=2,z=-1073741825,C=1');
        // Placement (5,1): alt screen at (0,0), z=-1
        h
          ..altScreen = true
          ..cursorCol = 0
          ..cursorRow = 0;
        h.send('a=p,i=5,p=1,c=2,r=2,z=-1,C=1');
        h.altScreen = false;

        // 1. d=q at 1-based (1,1) with z=-1 removes ONLY (2,1) (not (1,1) z=0 or alt (5,1))
        h.clearAtCalls.clear();
        h.send('a=d,d=q,x=1,y=1,z=-1');
        expect(h.clearAtCalls.single, equals((col: 0, row: 0, zIndex: -1)));
        expect(h.registry.lookupPlacement(2, 1), isNull);
        expect(
          h.registry.lookupImage(2),
          isNotNull,
        ); // lowercase preserves image
        expect(h.registry.lookupPlacement(1, 1), isNotNull);
        expect(h.registry.lookupPlacement(5, 1), isNotNull);

        // 2. d=c at cursor (1, 1) removes (1,1) and cascades to relative child (6,1)
        h
          ..cursorCol = 1
          ..cursorRow = 1
          ..clearAtCalls.clear();
        h.send('a=d,d=c');
        expect(h.clearAtCalls.single, equals((col: 1, row: 1, zIndex: null)));
        expect(h.registry.lookupPlacement(1, 1), isNull);
        expect(h.registry.lookupPlacement(6, 1), isNull);
        expect(h.registry.lookupImage(1), isNotNull);

        // 3. d=P at 1-based (5, 3) -> 0-based (4, 2) removes (3,1) and frees image 3
        h.clearAtCalls.clear();
        h.send('a=d,d=P,x=5,y=3');
        expect(h.clearAtCalls.single, equals((col: 4, row: 2, zIndex: null)));
        expect(h.registry.lookupPlacement(3, 1), isNull);
        expect(h.registry.lookupImage(3), isNull);

        // 4. d=z with z=-1073741825 removes (4,1) while keeping image 4
        h.clearAtCalls.clear();
        h.send('a=d,d=z,z=-1073741825');
        expect(
          h.clearAtCalls.single,
          equals((col: null, row: null, zIndex: -1073741825)),
        );
        expect(h.registry.lookupPlacement(4, 1), isNull);
        expect(h.registry.lookupImage(4), isNotNull);

        // 5. d=X (column) and d=Y (row)
        h
          ..cursorCol = 6
          ..cursorRow = 1;
        h.send('a=p,i=2,p=2,c=2,r=1,z=1,C=1');
        h
          ..cursorCol = 1
          ..cursorRow = 7;
        h.send('a=p,i=4,p=2,c=2,r=2,z=1,C=1');

        h.clearAtCalls.clear();
        h.send('a=d,d=X,x=7'); // 1-based col 7 -> 0-based col 6
        expect(
          h.clearAtCalls.single,
          equals((col: 6, row: null, zIndex: null)),
        );
        expect(h.registry.lookupPlacement(2, 2), isNull);
        expect(h.registry.lookupImage(2), isNull);

        h.clearAtCalls.clear();
        h.send('a=d,d=Y,y=8'); // 1-based row 8 -> 0-based row 7
        expect(
          h.clearAtCalls.single,
          equals((col: null, row: 7, zIndex: null)),
        );
        expect(h.registry.lookupPlacement(4, 2), isNull);
        expect(h.registry.lookupImage(4), isNull);

        // 6. d=f clears per-image animation frames; omitted i= clears all animations
        h.send('a=f,i=1,f=32,s=2,v=2,z=50;$b64');
        h.send('a=f,i=5,f=32,s=2,v=2,z=50;$b64');
        expect(h.registry.lookupAnimation(1), isNotNull);
        expect(h.registry.lookupAnimation(5), isNotNull);

        h.send('a=d,d=f,i=1');
        expect(h.registry.lookupAnimation(1), isNull);
        expect(h.registry.lookupImage(1), isNotNull);
        expect(h.registry.lookupAnimation(5), isNotNull);

        h.send('a=d,d=F');
        expect(h.registry.lookupAnimation(5), isNull);
        expect(h.registry.totalAnimationBytes, equals(0));
      },
    );
  });

  group('Kitty Graphics animations (a=f, a=a, a=c) & caps', () {
    test(
      'supports chunked a=f patching, alpha/overwrite, background fill Y, a=a playback & loop mapping, and a=c composition',
      () {
        final h = _HandlerHarness();
        final rootBytes = _solidRgba(4, 4, 255, 0, 0, 255); // opaque red
        h.send('a=t,i=20,f=32,s=4,v=4;${base64Encode(rootBytes)}');
        h.replies.clear();

        // Chunked a=f: create frame 2 from base frame 1 (c=1) with 2x2 semi-transparent blue patch at (1,1), X=0 alpha blend.
        final patchBlue = _solidRgba(2, 2, 0, 0, 255, 128);
        final patchB64 = base64Encode(patchBlue);
        final mid = patchB64.length ~/ 2;
        h.send(
          'a=f,i=20,c=1,x=1,y=1,s=2,v=2,X=0,z=60,m=1;${patchB64.substring(0, mid)}',
        );
        expect(h.replies, isEmpty);
        h.send('m=0;${patchB64.substring(mid)}');
        expect(h.replies, equals(['\x1b_Gi=20,r=2;OK\x1b\\']));

        final anim = h.registry.lookupAnimation(20)!;
        expect(anim.frames.length, equals(2));
        expect(anim.frames[0].frameNumber, equals(1));
        expect(anim.frames[1].frameNumber, equals(2));
        expect(anim.frames[1].gapMs, equals(60));

        final f2Pixels = anim.frames[1].imageData.rgbaPixels;
        // Pixel (0,0) unchanged (red)
        expect(f2Pixels.sublist(0, 4), equals([255, 0, 0, 255]));
        // Pixel (1,1) = offset (1*4 + 1)*4 = 20: alpha-blended blue over red
        expect(f2Pixels[20], inInclusiveRange(120, 135));
        expect(f2Pixels[21], equals(0));
        expect(f2Pixels[22], inInclusiveRange(120, 135));
        expect(f2Pixels[23], equals(255));

        // Frame 3: fresh canvas with Y=0x00FF00FF (opaque green), 1x1 overwrite patch (X=1) of transparent black at (0,0).
        h.replies.clear();
        final clearPx = base64Encode(Uint8List.fromList([0, 0, 0, 0]));
        final greenRgba = 0x00FF00FF;
        h.send('a=f,i=20,r=3,s=1,v=1,x=0,y=0,X=1,Y=$greenRgba,z=40;$clearPx');
        expect(h.replies, equals(['\x1b_Gi=20,r=3;OK\x1b\\']));
        final f3Pixels = anim.frames[2].imageData.rgbaPixels;
        expect(f3Pixels.sublist(0, 4), equals([0, 0, 0, 0])); // overwritten
        expect(
          f3Pixels.sublist(4, 8),
          equals([0, 255, 0, 255]),
        ); // green Y fill

        // a=c: compose 2x2 from frame 1 (X=0,Y=0) onto frame 3 at (x=2,y=2) with C=1 (overwrite)
        h.replies.clear();
        h.send('a=c,i=20,r=1,c=3,X=0,Y=0,x=2,y=2,w=2,h=2,C=1');
        expect(h.replies, equals(['\x1b_Gi=20;OK\x1b\\']));
        final f3Composed = h.registry.lookupAnimation(20)!.frames[2].imageData;
        // Pixel (2,2) -> (2*4 + 2)*4 = 40 is now opaque red
        expect(f3Composed.rgbaPixels.sublist(40, 44), equals([255, 0, 0, 255]));

        // a=a: v=1 -> loopCount=0 (infinite), s=3 -> running, r=1, z=50 sets frame 1 gap
        h.replies.clear();
        h.send('a=a,i=20,s=3,v=1,r=1,z=50');
        expect(h.replies, equals(['\x1b_Gi=20;OK\x1b\\']));
        expect(anim.playback, equals(KittyAnimationPlayback.running));
        expect(anim.loopCount, equals(0));
        expect(anim.frames[0].gapMs, equals(50));

        // v=3 -> loopCount=2 (v - 1), then v=0 leaves loopCount unchanged at 2, c=2 jumps to frame 2
        h.send('a=a,i=20,v=3');
        expect(anim.loopCount, equals(2));
        h.send('a=a,i=20,v=0,c=2');
        expect(anim.loopCount, equals(2));
        expect(anim.currentFrameNumber, equals(2));
        expect(
          identical(h.registry.activeImageData(20), anim.frames[1].imageData),
          isTrue,
        );

        // s=2 -> loading, s=1 -> stopped
        h.send('a=a,i=20,s=2');
        expect(anim.playback, equals(KittyAnimationPlayback.loading));
        h.send('a=a,i=20,s=1');
        expect(anim.playback, equals(KittyAnimationPlayback.stopped));

        // Advance clock while running and verify stable KittyImageData identity
        h.send('a=a,i=20,s=3,v=1,c=1');
        final f1Ref = anim.frames[0].imageData;
        final f2Ref = anim.frames[1].imageData;
        h.registry.advanceAnimations(1000);
        expect(identical(h.registry.activeImageData(20), f1Ref), isTrue);
        h.registry.advanceAnimations(1055);
        expect(identical(h.registry.activeImageData(20), f2Ref), isTrue);
      },
    );

    test('enforces 64-frame and 32 MiB animation caps with EFBIG', () {
      final h = _HandlerHarness();
      final px1 = base64Encode(_solidRgba(1, 1, 1, 2, 3, 255));
      h.send('a=t,i=30,f=32,s=1,v=1;$px1');

      // Frame 1 is auto-seeded; frames 2..64 succeed (64 total frames).
      for (var f = 2; f <= 64; f++) {
        h.replies.clear();
        h.send('a=f,i=30,r=$f,f=32,s=1,v=1;$px1');
        expect(h.replies, equals(['\x1b_Gi=30,r=$f;OK\x1b\\']));
      }
      // Frame 65 exceeds 64-frame cap -> EFBIG.
      h.replies.clear();
      h.send('a=f,i=30,r=65,f=32,s=1,v=1;$px1');
      expect(h.replies.single, startsWith('\x1b_Gi=30;EFBIG:'));

      // 32 MiB byte cap: 1024x1024 RGBA = 4 MiB per frame.
      // 8 frames = 32 MiB (using empty payload Y= background fill for fast test);
      // 9th frame pushes over 32 MiB -> EFBIG.
      h.send('a=d,d=F');
      final bigRoot = KittyImageData(
        imageId: 31,
        pixelWidth: 1024,
        pixelHeight: 1024,
        rgbaPixels: Uint8List(1024 * 1024 * 4),
        gridCols: 4,
        gridRows: 2,
      );
      h.registry.registerImage(bigRoot);
      for (var f = 2; f <= 9; f++) {
        h.replies.clear();
        h.send('a=f,i=31,r=$f,Y=0;');
        expect(h.replies, equals(['\x1b_Gi=31,r=$f;OK\x1b\\']));
      }
      // 8 charged frames * 4 MiB = 32 MiB; 9th charged frame (r=10) exceeds 32 MiB -> EFBIG.
      h.replies.clear();
      h.send('a=f,i=31,r=10,Y=0;');
      expect(h.replies.single, startsWith('\x1b_Gi=31;EFBIG:'));
    });

    test(
      'validates a=f/a=a/a=c error paths, RGB24/zlib frames, and alpha-blend a=c',
      () {
        final h = _HandlerHarness();
        final root = _solidRgba(2, 2, 200, 0, 0, 255);
        h.send('a=t,i=35,f=32,s=2,v=2;${base64Encode(root)}');

        // Missing image errors
        h.replies.clear();
        h.send('a=f,i=999,f=32,s=2,v=2;${base64Encode(root)}');
        h.send('a=a,i=999,s=3');
        h.send('a=c,i=999,r=1,c=2');
        expect(
          h.replies,
          equals([
            '\x1b_Gi=999;ENOENT:image not found\x1b\\',
            '\x1b_Gi=999;ENOENT:image not found\x1b\\',
            '\x1b_Gi=999;ENOENT:image not found\x1b\\',
          ]),
        );

        // Invalid a=a state / loop count, invalid a=c frame numbers / missing frame
        h.replies.clear();
        h.send('a=a,i=35,s=9');
        h.send('a=a,i=35,v=-2');
        h.send('a=c,i=35,r=0,c=1');
        h.send('a=c,i=35,r=1,c=99');
        expect(
          h.replies,
          equals([
            '\x1b_Gi=35;EINVAL:invalid animation state\x1b\\',
            '\x1b_Gi=35;EINVAL:invalid loop count\x1b\\',
            '\x1b_Gi=35;EINVAL:invalid frame number\x1b\\',
            '\x1b_Gi=35;ENOENT:frame not found\x1b\\',
          ]),
        );

        // RGB24 + zlib compressed frame 2 and alpha-blended a=c (C=0)
        final rgb24 = Uint8List.fromList([
          0,
          255,
          0,
          0,
          255,
          0,
          0,
          255,
          0,
          0,
          255,
          0,
        ]);
        final compressedB64 = base64Encode(zlib.encode(rgb24));
        h.replies.clear();
        h.send('a=f,i=35,r=2,f=24,o=z,s=2,v=2,z=-1;$compressedB64');
        expect(h.replies, equals(['\x1b_Gi=35,r=2;OK\x1b\\']));
        final anim = h.registry.lookupAnimation(35)!;
        expect(anim.frames[1].gapMs, equals(-1));
        expect(
          anim.frames[1].imageData.rgbaPixels.sublist(0, 4),
          equals([0, 255, 0, 255]),
        );

        // Frame 3 semi-transparent blue, then alpha-blend frame 3 onto frame 1 with C=0
        final halfBlue = base64Encode(_solidRgba(2, 2, 0, 0, 255, 128));
        h.send('a=f,i=35,r=3,f=32,s=2,v=2,X=1;$halfBlue');
        h.replies.clear();
        h.send('a=c,i=35,r=3,c=1,X=0,Y=0,x=0,y=0,w=1,h=1,C=0');
        expect(h.replies, equals(['\x1b_Gi=35;OK\x1b\\']));
        final blended = h.registry
            .lookupAnimation(35)!
            .frames[0]
            .imageData
            .rgbaPixels;
        expect(blended[0], inInclusiveRange(95, 105));
        expect(blended[2], inInclusiveRange(125, 135));
        expect(blended[3], equals(255));
      },
    );
  });

  group('Kitty Graphics local regular file medium (t=f)', () {
    test(
      'disabled by default, reads without unlinking when enabled, and rejects symlinks/traversal/UNC/FIFOs',
      () {
        final dir = Directory.systemTemp.createTempSync('kitty_tf_parity_');
        addTearDown(() {
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        });

        final rgba = _solidRgba(2, 2, 42, 84, 126, 255);
        final regularFile = File('${dir.path}/sample_image.rgba')
          ..writeAsBytesSync(rgba);
        final pathB64 = base64Encode(utf8.encode(regularFile.path));

        // 1. Disabled by default (even if allowLocalMedia is true!).
        final disabled = _HandlerHarness(
          allowLocalMedia: true,
          allowLocalFiles: false,
        );
        disabled.send('a=t,i=40,t=f,f=32,s=2,v=2;$pathB64');
        expect(
          disabled.replies.single,
          equals('\x1b_Gi=40;EINVAL:unsupported transmission medium\x1b\\'),
        );
        expect(regularFile.existsSync(), isTrue);

        // 2. Enabled: reads regular file (no tty-graphics-protocol marker required) and NEVER unlinks.
        final enabled = _HandlerHarness(allowLocalFiles: true);
        enabled.send('a=q,i=41,t=f,f=32,s=2,v=2;$pathB64');
        expect(enabled.replies.last, equals('\x1b_Gi=41;OK\x1b\\'));
        expect(regularFile.existsSync(), isTrue);

        enabled.replies.clear();
        enabled.send('a=t,i=42,t=f,f=32,s=2,v=2;$pathB64');
        expect(enabled.replies.single, equals('\x1b_Gi=42;OK\x1b\\'));
        expect(enabled.registry.lookupImage(42)?.rgbaPixels, equals(rgba));
        expect(regularFile.existsSync(), isTrue);

        // 3. O=/S= slicing works without unlinking.
        final padded = Uint8List.fromList([9, 9, ...rgba, 7]);
        final slicedFile = File('${dir.path}/sliced.rgba')
          ..writeAsBytesSync(padded);
        enabled.replies.clear();
        enabled.send(
          'a=t,i=43,t=f,f=32,s=2,v=2,O=2,S=16;'
          '${base64Encode(utf8.encode(slicedFile.path))}',
        );
        expect(enabled.replies.single, equals('\x1b_Gi=43;OK\x1b\\'));
        expect(enabled.registry.lookupImage(43)?.rgbaPixels, equals(rgba));
        expect(slicedFile.existsSync(), isTrue);

        // 4. Rejects missing file (ENOENT), traversal, relative, and UNC paths (EINVAL).
        enabled.replies.clear();
        enabled.send(
          'a=t,i=44,t=f,f=32,s=2,v=2;'
          '${base64Encode(utf8.encode('${dir.path}/does_not_exist.rgba'))}',
        );
        expect(enabled.replies.single, startsWith('\x1b_Gi=44;ENOENT:'));

        for (final badPath in const [
          'relative/image.rgba',
          '/tmp/../etc/passwd',
          r'\\server\share\image.rgba',
          '//server/share/image.rgba',
        ]) {
          enabled.replies.clear();
          enabled.send(
            'a=t,i=45,t=f,f=32,s=2,v=2;'
            '${base64Encode(utf8.encode(badPath))}',
          );
          expect(
            enabled.replies.single,
            startsWith('\x1b_Gi=45;EINVAL:'),
            reason: 'Expected EINVAL for $badPath',
          );
        }

        // 5. Rejects symlinks (O_NOFOLLOW), directories, and FIFOs without unlinking target.
        if (!Platform.isWindows) {
          final linkPath = '${dir.path}/symlink.rgba';
          Link(linkPath).createSync(regularFile.path);
          enabled.replies.clear();
          enabled.send(
            'a=t,i=46,t=f,f=32,s=2,v=2;'
            '${base64Encode(utf8.encode(linkPath))}',
          );
          expect(enabled.replies.single, startsWith('\x1b_Gi=46;EINVAL:'));
          expect(regularFile.existsSync(), isTrue);

          enabled.replies.clear();
          enabled.send(
            'a=t,i=47,t=f,f=32,s=2,v=2;'
            '${base64Encode(utf8.encode(dir.path))}',
          );
          expect(enabled.replies.single, startsWith('\x1b_Gi=47;EINVAL:'));

          final fifoPath = '${dir.path}/named_pipe.rgba';
          if (Process.runSync('mkfifo', [fifoPath]).exitCode == 0) {
            enabled.replies.clear();
            enabled.send(
              'a=t,i=48,t=f,f=32,s=2,v=2;'
              '${base64Encode(utf8.encode(fifoPath))}',
            );
            expect(enabled.replies.single, startsWith('\x1b_Gi=48;EINVAL:'));
            expect(
              FileSystemEntity.typeSync(fifoPath, followLinks: false),
              isNot(FileSystemEntityType.notFound),
            );
          }
        }

        // 6. Rejects > 16 MiB file with EFBIG without unlinking.
        final hugeFile = File('${dir.path}/huge.rgba');
        final raf = hugeFile.openSync(mode: FileMode.write);
        try {
          raf.truncateSync(16 * 1024 * 1024 + 64);
        } finally {
          raf.closeSync();
        }
        enabled.replies.clear();
        enabled.send(
          'a=t,i=49,t=f,f=32,s=2,v=2;'
          '${base64Encode(utf8.encode(hugeFile.path))}',
        );
        expect(enabled.replies.single, startsWith('\x1b_Gi=49;EFBIG:'));
        expect(hugeFile.existsSync(), isTrue);
      },
    );
  });

  group('VirtualTerminal integration sanity', () {
    test(
      'end-to-end layered placement and animation over VirtualTerminal APC stream',
      () {
        final replies = <String>[];
        final vt = VirtualTerminal(width: 20, height: 6, onReply: replies.add);
        vt.writeString('HELLO');
        vt.writeString('\x1b[1;1H');

        final redB64 = base64Encode(_solidRgba(2, 2, 255, 0, 0, 255));
        final blueB64 = base64Encode(_solidRgba(2, 2, 0, 0, 255, 255));
        vt.writeString(
          '\x1b_Ga=T,i=70,p=1,f=32,s=2,v=2,c=3,r=2,z=-1,C=1;$redB64\x1b\\',
        );
        expect(replies, contains('\x1b_Gi=70,p=1;OK\x1b\\'));
        // Layered placement must NOT overwrite existing text cells!
        expect(vt.buffer.getCharacter(0, 0), equals('H'));
        expect(vt.buffer.getCharacter(4, 0), equals('O'));
        expect(vt.imageRegistry.lookupPlacement(70, 1)?.zIndex, equals(-1));

        // Upload frame 2 & start animation.
        replies.clear();
        vt.writeString('\x1b_Ga=f,i=70,f=32,s=2,v=2,z=50;$blueB64\x1b\\');
        vt.writeString('\x1b_Ga=a,i=70,s=3,v=1\x1b\\');
        expect(
          replies,
          equals(['\x1b_Gi=70,r=2;OK\x1b\\', '\x1b_Gi=70;OK\x1b\\']),
        );
        expect(vt.imageRegistry.hasRunningAnimations, isTrue);
      },
    );
  });

  group('Wave 2 adversarial review regressions (M2/M3/M4/M6/M8/m11/Nit13)', () {
    Uint8List minimalPng(int width, int height) {
      final header = BytesBuilder()
        ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        ..add(const [0x00, 0x00, 0x00, 0x0D])
        ..add(const [0x49, 0x48, 0x44, 0x52]);
      final dims = ByteData(8)
        ..setUint32(0, width)
        ..setUint32(4, height);
      header
        ..add(dims.buffer.asUint8List())
        ..add(const [0x08, 0x06, 0x00, 0x00, 0x00])
        ..add(const [0x00, 0x00, 0x00, 0x00]);
      return header.toBytes();
    }

    test(
      'M2: registry single source of truth stays synced across external alt-screen clear and scroll eviction',
      () {
        final h = _HandlerHarness()
          ..altScreen = true
          ..cursorCol = 0
          ..cursorRow = 0;
        final b64 = base64Encode(_solidRgba(1, 1, 10, 20, 30, 255));

        h.send('a=T,i=101,p=1,f=32,s=1,v=1,c=2,r=2,z=-1;$b64');
        expect(h.registry.lookupPlacement(101, 1)?.isAltScreen, isTrue);

        // Simulate VirtualTerminal exiting alt screen and clearing alt placements directly on registry.
        h.registry.clearPlacements(altScreen: true);
        h.altScreen = false;

        // Subsequent d=A must see 0 remaining placements for image 101 and evict it!
        h.send('a=d,d=A');
        expect(h.registry.lookupImage(101), isNull);

        // Simulate scrollback eviction removing primary placement directly on registry.
        h.send('a=T,i=102,p=1,f=32,s=1,v=1,c=2,r=1,z=-1;$b64');
        h.registry.shiftDirectPlacements(
          -5,
          altScreen: false,
          evictAboveRow: 0,
        );
        expect(h.registry.lookupPlacement(102, 1), isNull);
        h.send('a=d,d=A');
        expect(h.registry.lookupImage(102), isNull);
      },
    );

    test(
      'M3: _deleteByFilter on anonymous p=0 passes placementId: 0 (not null) and preserves p>0',
      () {
        final h = _HandlerHarness();
        final b64 = base64Encode(_solidRgba(1, 1, 50, 60, 70, 255));
        h.send('a=t,i=110,f=32,s=1,v=1;$b64');

        // Place anonymous p=0 at (0,0) and named p=5 at (4,0).
        h
          ..cursorCol = 0
          ..cursorRow = 0;
        h.send('a=p,i=110,c=2,r=1,C=1');
        h
          ..cursorCol = 4
          ..cursorRow = 0;
        h.send('a=p,i=110,p=5,c=2,r=1,C=1');

        h.clearCalls.clear();
        h.send('a=d,d=p,x=1,y=1');
        expect(h.clearCalls, equals([(110, 0, true)]));
        expect(h.registry.lookupPlacement(110, 0), isNull);
        expect(h.registry.lookupPlacement(110, 5), isNotNull);
      },
    );

    test(
      'M4: pending-wrap cursorCol >= viewportCols anchors to (vpCols-1, row) for C=1 and (0, row+1) for C=0',
      () {
        final h = _HandlerHarness()
          ..viewportCols = 10
          ..viewportRows = 6
          ..cursorCol = 10
          ..cursorRow = 2;
        final b64 = base64Encode(_solidRgba(1, 1, 1, 2, 3, 255));
        h.send('a=t,i=120,f=32,s=1,v=1;$b64');

        // C=1 at pending wrap stays on current row at vpCols - 1.
        h.send('a=p,i=120,p=1,c=2,r=1,z=-1,C=1');
        final p1 = h.registry.lookupPlacement(120, 1)!;
        expect(p1.gridCol, equals(9));
        expect(p1.gridRow, equals(2));

        // C=0 at pending wrap wraps to (0, curRow + 1).
        h.send('a=p,i=120,p=2,c=2,r=1,z=-1,C=0');
        final p2 = h.registry.lookupPlacement(120, 2)!;
        expect(p2.gridCol, equals(0));
        expect(p2.gridRow, equals(3));
      },
    );

    test(
      'M6: rejects cross-screen and virtual relative parents, and clears stale z=0 cells when replacing with z!=0',
      () {
        final h = _HandlerHarness();
        final b64 = base64Encode(_solidRgba(1, 1, 20, 30, 40, 255));
        h.send('a=t,i=130,f=32,s=1,v=1;$b64');
        h.send('a=t,i=131,f=32,s=1,v=1;$b64');

        // Primary direct parent (130, 1) and virtual parent (130, 2).
        h.send('a=p,i=130,p=1,c=2,r=1,C=1');
        h.send('a=p,i=130,p=2,U=1,c=2,r=1');

        // Cross-screen relative parent rejected with ENOENT.
        h
          ..altScreen = true
          ..replies.clear();
        h.send('a=p,i=131,p=1,P=130,Q=1,H=1,V=0,c=1,r=1');
        expect(
          h.replies.single,
          equals('\x1b_Gi=131,p=1;ENOENT:parent placement not found\x1b\\'),
        );

        // Virtual parent rejected with EINVAL.
        h
          ..altScreen = false
          ..replies.clear();
        h.send('a=p,i=131,p=2,P=130,Q=2,H=1,V=0,c=1,r=1');
        expect(
          h.replies.single,
          equals(
            '\x1b_Gi=131,p=2;EINVAL:cannot place relative to virtual placement\x1b\\',
          ),
        );

        // Replacing z=0 direct placement (130, 1) with z=-1 layered placement clears old placeholder cells.
        h.clearCalls.clear();
        h.send('a=p,i=130,p=1,c=2,r=1,z=-1,C=1');
        expect(h.clearCalls, equals([(130, 1, true)]));
        expect(h.registry.lookupPlacement(130, 1)?.zIndex, equals(-1));
      },
    );

    test(
      'M8 & m11: a=c geometry before EFBIG, a=f preserves gapMs, PNG size/existingTarget checks, and a=a ENOENT frames',
      () {
        final h = _HandlerHarness();
        final root = _solidRgba(4, 4, 255, 0, 0, 255);
        h.send('a=t,i=140,f=32,s=4,v=4;${base64Encode(root)}');
        h.send('a=f,i=140,r=2,f=32,s=4,v=4,z=75;${base64Encode(root)}');

        // M8: patching r=2 without z= preserves gapMs=75!
        final patch = base64Encode(_solidRgba(1, 1, 0, 255, 0, 255));
        h.replies.clear();
        h.send('a=f,i=140,r=2,x=0,y=0,s=1,v=1,X=1;$patch');
        expect(h.replies, equals(['\x1b_Gi=140,r=2;OK\x1b\\']));
        expect(h.registry.lookupAnimation(140)!.frames[1].gapMs, equals(75));

        // m11: a=a returns ENOENT when c= or r= references missing frame.
        h.replies.clear();
        h.send('a=a,i=140,c=99');
        h.send('a=a,i=140,r=99,z=20');
        expect(
          h.replies,
          equals([
            '\x1b_Gi=140;ENOENT:frame not found\x1b\\',
            '\x1b_Gi=140;ENOENT:frame not found\x1b\\',
          ]),
        );

        // m11: a=c rejects negative/non-numeric w/h and invalid C=.
        h.replies.clear();
        h.send('a=c,i=140,r=1,c=2,w=-1');
        h.send('a=c,i=140,r=1,c=2,h=abc');
        h.send('a=c,i=140,r=1,c=2,C=2');
        expect(
          h.replies,
          equals([
            '\x1b_Gi=140;EINVAL:invalid composition geometry\x1b\\',
            '\x1b_Gi=140;EINVAL:invalid composition geometry\x1b\\',
            '\x1b_Gi=140;EINVAL:invalid composition mode\x1b\\',
          ]),
        );

        // M8: a=c bad geometry returns EINVAL even when animation budget is completely full!
        final bigRoot = KittyImageData(
          imageId: 141,
          pixelWidth: 1024,
          pixelHeight: 1024,
          rgbaPixels: Uint8List(1024 * 1024 * 4),
          gridCols: 4,
          gridRows: 2,
        );
        h.registry.registerImage(bigRoot);
        for (var f = 2; f <= 8; f++) {
          h.send('a=f,i=141,r=$f,Y=0;');
        }
        // Fill remaining budget (~4 MiB) with another image so 141 frame 1 compose would exceed 32 MiB.
        final filler = KittyImageData(
          imageId: 142,
          pixelWidth: 1024,
          pixelHeight: 1024,
          rgbaPixels: Uint8List(1024 * 1024 * 4),
          gridCols: 4,
          gridRows: 2,
        );
        h.registry.registerImage(filler);
        h.send('a=f,i=142,r=2,Y=0;');
        expect(h.registry.totalAnimationBytes, greaterThan(28 * 1024 * 1024));

        // Out-of-bounds geometry on 141 frame 1 must return EINVAL, NOT false EFBIG!
        h.replies.clear();
        h.send('a=c,i=141,r=2,c=1,X=2000,Y=0');
        expect(
          h.replies.single,
          equals('\x1b_Gi=141;EINVAL:invalid composition geometry\x1b\\'),
        );
        // Valid geometry on uncharged frame 1 when budget is full returns EFBIG!
        h.replies.clear();
        h.send('a=c,i=141,r=2,c=1,X=0,Y=0,w=4,h=4,C=1');
        expect(
          h.replies.single,
          equals('\x1b_Gi=141;EFBIG:animation frame limit exceeded\x1b\\'),
        );

        // m11: PNG a=f validates root dimensions and existingTarget alpha-blend mode.
        h.send('a=d,d=F');
        final png4x4 = base64Encode(minimalPng(4, 4));
        final png8x8 = base64Encode(minimalPng(8, 8));
        h.send('a=t,i=145,f=100;$png4x4');

        h.replies.clear();
        h.send('a=f,i=145,r=2,f=100;$png8x8'); // mismatched size -> EINVAL
        expect(h.replies.single, startsWith('\x1b_Gi=145;EINVAL:'));

        h.replies.clear();
        h.send('a=f,i=145,r=2,f=100;$png4x4'); // matching new frame -> OK
        expect(h.replies.single, equals('\x1b_Gi=145,r=2;OK\x1b\\'));

        h.replies.clear();
        h.send(
          'a=f,i=145,r=2,f=100,X=0;$png4x4',
        ); // existingTarget + X=0 blend -> EINVAL
        expect(h.replies.single, startsWith('\x1b_Gi=145;EINVAL:'));

        h.replies.clear();
        h.send(
          'a=f,i=145,r=2,f=100,X=1;$png4x4',
        ); // existingTarget + X=1 overwrite -> OK
        expect(h.replies.single, equals('\x1b_Gi=145,r=2;OK\x1b\\'));
      },
    );

    test(
      'Nit 13: new upload with z= metadata does not hijack aborted anonymous m=1 upload',
      () {
        final h = _HandlerHarness();
        h.send('a=T,f=32,s=2,v=2,m=1;AAAA');
        final px = base64Encode(_solidRgba(1, 1, 9, 8, 7, 255));
        h.send('a=T,z=-1,s=1,v=1;$px');
        final layered = [
          for (final p in h.registry.allPlacements)
            if (p.zIndex == -1) p,
        ];
        expect(layered, hasLength(1));
      },
    );
  });
}
