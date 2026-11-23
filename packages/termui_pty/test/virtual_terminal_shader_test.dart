import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:test/test.dart';

final class _FakeRoutedBackend implements RoutedPtyBackend {
  final StreamController<Uint8List> _output = StreamController<Uint8List>(
    sync: true,
  );
  final Completer<int> _exit = Completer<int>();
  final List<String> writtenReplies = <String>[];

  void emitString(String text) =>
      _output.add(Uint8List.fromList(utf8.encode(text)));

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  void write(Uint8List bytes) {
    writtenReplies.add(utf8.decode(bytes));
  }

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}

  @override
  void kill() {
    if (!_exit.isCompleted) _exit.complete(0);
  }

  @override
  Future<void> dispose() async {
    kill();
    if (!_output.isClosed) await _output.close();
  }
}

void main() {
  group('VirtualTerminal ESC _ S lifecycle', () {
    test('replies to a=query with default disabled caps and custom caps', () {
      final replies = <String>[];
      final events = <TerminalShaderApcEvent>[];
      final vt = VirtualTerminal(
        width: 40,
        height: 12,
        onReply: replies.add,
        onShaderEvent: events.add,
      );

      vt.writeString(ShaderApcEncoder.encodeQuery());
      expect(replies, [
        '\x1b_Sa=caps,backend=disabled,glsl=0,xform=1,region=0,max_slots=16,max_regions=8\x1b\\',
      ]);
      expect(events, [const TerminalShaderQueryEvent()]);

      vt.setShaderCapabilities((
        backend: 'flutter_gpu',
        glsl: true,
        xform: true,
        region: true,
        maxSlots: 16,
        maxRegions: 8,
      ));
      vt.writeString(ShaderApcEncoder.encodeQuery());
      expect(
        replies.last,
        '\x1b_Sa=caps,backend=flutter_gpu,glsl=1,xform=1,region=1,max_slots=16,max_regions=8\x1b\\',
      );
    });

    test('applies region, uniform, and transform updates to active buffer', () {
      final events = <TerminalShaderApcEvent>[];
      final vt = VirtualTerminal(
        width: 20,
        height: 10,
        onShaderEvent: events.add,
      );

      final region = ShaderRegion(
        id: 'fire_word',
        shaderId: 'fire',
        sourceRects: const [Rect(2, 3, 5, 1)],
        padding: const CellPadding(top: 2, right: 1, bottom: 0, left: 1),
        stage: .overGlyphs,
        params: Float32List.fromList([1.5, 0, 0, 0, 0, 0, 0, 0]),
      );
      const transform = CellTransform(dx: 0.5, dy: -1.0, rotationRad: 0.25);

      vt.writeString(ShaderApcEncoder.encodeRegion(region));
      vt.writeString(
        ShaderApcEncoder.encodeUniform(
          id: 'fire_word',
          params: {0: 2.25, 2: 0.5},
        ),
      );
      vt.writeString(
        ShaderApcEncoder.encodeTransform(col: 4, row: 3, transform: transform),
      );

      expect(vt.buffer.shaderRegions, hasLength(1));
      final liveRegion = vt.buffer.shaderRegions.single;
      expect(liveRegion.id, 'fire_word');
      expect(liveRegion.params[0], 2.25);
      expect(liveRegion.params[2], 0.5);
      expect(vt.buffer.getCellTransform(4, 3), transform);
      expect(events, hasLength(3));
    });

    test(
      'isolates primary vs alt-screen shader metadata and cleans up on ?47/?1047/?1049 exit',
      () {
        for (final mode in const [47, 1047, 1049]) {
          final events = <TerminalShaderApcEvent>[];
          final vt = VirtualTerminal(
            width: 20,
            height: 8,
            onShaderEvent: events.add,
          );

          final primaryRegion = ShaderRegion(
            id: 'primary_r',
            shaderId: 'fire',
            sourceRects: const [Rect(1, 1, 4, 1)],
          );
          const primaryXform = CellTransform(dx: 1.0, dy: 0.5);
          vt.writeString(ShaderApcEncoder.encodeRegion(primaryRegion));
          vt.writeString(
            ShaderApcEncoder.encodeTransform(
              col: 2,
              row: 1,
              transform: primaryXform,
            ),
          );

          // Enter alt-screen: primary overlays do not bleed into alt buffer.
          vt.writeString('\x1b[?${mode}h');
          expect(vt.isUsingAlternateScreen, isTrue);
          expect(vt.buffer.shaderRegions, isEmpty);
          expect(vt.buffer.hasCellTransforms, isFalse);

          final altRegion = ShaderRegion(
            id: 'alt_r',
            shaderId: 'neon_pulse',
            sourceRects: const [Rect(3, 2, 6, 1)],
          );
          const altXform = CellTransform(dy: 2.0, rotationRad: 1.5);
          vt.writeString(ShaderApcEncoder.encodeRegion(altRegion));
          vt.writeString(
            ShaderApcEncoder.encodeTransform(
              col: 3,
              row: 2,
              transform: altXform,
            ),
          );
          expect(vt.buffer.shaderRegions.map((r) => r.id), ['alt_r']);
          expect(vt.buffer.getCellTransform(3, 2), altXform);

          events.clear();
          // Exit alt-screen: alt shaders cleared, reset emitted, primary restored cleanly.
          vt.writeString('\x1b[?${mode}l');
          expect(vt.isUsingAlternateScreen, isFalse);
          expect(events, [
            const TerminalResetShaderEvent(target: .all, altScreenExit: true),
          ]);
          expect(vt.buffer.shaderRegions.map((r) => r.id), ['primary_r']);
          expect(vt.buffer.getCellTransform(2, 1), primaryXform);
          expect(vt.buffer.getCellTransform(3, 2), isNull);
        }
      },
    );

    test(
      'shifts and evicts transforms and regions on full-screen and DECSTBM scroll',
      () {
        final vt = VirtualTerminal(width: 20, height: 6);
        const topXform = CellTransform(dx: 0.25);
        const midXform = CellTransform(dx: 0.5);
        const bottomXform = CellTransform(dx: 0.75);

        vt.writeString(
          ShaderApcEncoder.encodeTransform(col: 1, row: 0, transform: topXform),
        );
        vt.writeString(
          ShaderApcEncoder.encodeTransform(col: 2, row: 2, transform: midXform),
        );
        vt.writeString(
          ShaderApcEncoder.encodeTransform(
            col: 3,
            row: 5,
            transform: bottomXform,
          ),
        );
        vt.writeString(
          ShaderApcEncoder.encodeRegion(
            ShaderRegion(
              id: 'top_region',
              shaderId: 'fire',
              sourceRects: const [Rect(0, 0, 4, 1)],
            ),
          ),
        );
        vt.writeString(
          ShaderApcEncoder.encodeRegion(
            ShaderRegion(
              id: 'mid_region',
              shaderId: 'ice_frost',
              sourceRects: const [Rect(1, 2, 5, 2)],
            ),
          ),
        );

        // Full-screen scroll up by 1 row (CSI 1 S).
        vt.writeString('\x1b[1S');
        expect(vt.buffer.getCellTransform(1, 0), isNull);
        expect(vt.buffer.getCellTransform(2, 1), midXform);
        expect(vt.buffer.getCellTransform(3, 4), bottomXform);
        expect(vt.buffer.shaderRegions.map((r) => r.id), ['mid_region']);
        expect(vt.buffer.shaderRegions.single.sourceRects, [
          const Rect(1, 1, 5, 2),
        ]);

        // Scroll down by 1 row (CSI 1 T) moves mid back down to row 2.
        vt.writeString('\x1b[1T');
        expect(vt.buffer.getCellTransform(2, 2), midXform);
        expect(vt.buffer.getCellTransform(3, 5), bottomXform);
        expect(vt.buffer.shaderRegions.single.sourceRects, [
          const Rect(1, 2, 5, 2),
        ]);

        // Set DECSTBM rows 2..5 (1-based) => 0-based [1..4], scroll up 1 row:
        // row 2 shifts to row 1, while row 5 (outside scroll band) stays put!
        vt.writeString('\x1b[2;5r\x1b[1S');
        expect(vt.buffer.getCellTransform(2, 1), midXform);
        expect(vt.buffer.getCellTransform(3, 5), bottomXform);
      },
    );

    test('remaps transforms and clips/evicts regions on resize', () {
      final vt = VirtualTerminal(width: 20, height: 10);
      const keepXform = CellTransform(scaleX: 1.5, scaleY: 1.5);
      const dropXform = CellTransform(dx: 2.0);
      vt.writeString(
        ShaderApcEncoder.encodeTransform(col: 2, row: 1, transform: keepXform),
      );
      vt.writeString(
        ShaderApcEncoder.encodeTransform(col: 15, row: 8, transform: dropXform),
      );
      vt.writeString(
        ShaderApcEncoder.encodeRegion(
          ShaderRegion(
            id: 'partial',
            shaderId: 'fire',
            sourceRects: const [Rect(4, 2, 10, 4)],
          ),
        ),
      );
      vt.writeString(
        ShaderApcEncoder.encodeRegion(
          ShaderRegion(
            id: 'outside',
            shaderId: 'fire',
            sourceRects: const [Rect(12, 7, 4, 2)],
          ),
        ),
      );

      vt.resize(8, 4);
      expect(vt.buffer.getCellTransform(2, 1), keepXform);
      expect(vt.buffer.cellTransforms!.length, 1);
      expect(vt.buffer.shaderRegions.map((r) => r.id), ['partial']);
      expect(vt.buffer.shaderRegions.single.sourceRects, [
        const Rect(4, 2, 4, 2),
      ]);
    });

    test(
      'hides shader regions and transforms while viewportOffset != 0 and restores at live bottom',
      () {
        final vt = VirtualTerminal(
          width: 20,
          height: 4,
          maxScrollbackLines: 50,
        );
        for (var i = 0; i < 10; i++) {
          vt.writeString('line $i\r\n');
        }
        final region = ShaderRegion(
          id: 'live_fire',
          shaderId: 'fire',
          sourceRects: const [Rect(0, 1, 6, 1)],
        );
        const xform = CellTransform(rotationRad: 0.5);
        vt.writeString(ShaderApcEncoder.encodeRegion(region));
        vt.writeString(
          ShaderApcEncoder.encodeTransform(col: 1, row: 1, transform: xform),
        );

        expect(vt.buffer.shaderRegions, hasLength(1));
        expect(vt.buffer.getCellTransform(1, 1), xform);
        final liveRendered = vt.renderBuffer();
        expect(liveRendered.shaderRegions, hasLength(1));
        expect(liveRendered.getCellTransform(1, 1), xform);

        // Scroll back into history: overlays hidden on both buffer and renderBuffer.
        vt.viewportOffset = 3;
        expect(vt.buffer.shaderRegions, isEmpty);
        expect(vt.buffer.hasCellTransforms, isFalse);
        final scrolledRendered = vt.renderBuffer();
        expect(scrolledRendered.shaderRegions, isEmpty);
        expect(scrolledRendered.hasCellTransforms, isFalse);

        // Return to live bottom: overlays restored cleanly.
        vt.resetViewport();
        expect(vt.buffer.shaderRegions, hasLength(1));
        expect(vt.buffer.getCellTransform(1, 1), xform);
        final restoredRendered = vt.renderBuffer();
        expect(restoredRendered.shaderRegions, hasLength(1));
        expect(restoredRendered.getCellTransform(1, 1), xform);
      },
    );

    test(
      'RIS (ESC c) and DECSTR (ESC [!p) reset parser, metadata, and emit reset',
      () {
        for (final seq in const ['\x1bc', '\x1b[!p']) {
          final events = <TerminalShaderApcEvent>[];
          final vt = VirtualTerminal(
            width: 20,
            height: 6,
            onShaderEvent: events.add,
          );
          vt.writeString(
            ShaderApcEncoder.encodeRegion(
              ShaderRegion(
                id: 'r1',
                shaderId: 'fire',
                sourceRects: const [Rect(0, 0, 5, 1)],
              ),
            ),
          );
          vt.writeString(
            ShaderApcEncoder.encodeTransform(
              col: 1,
              row: 1,
              transform: const CellTransform(dx: 1.0),
            ),
          );
          // Start an incomplete chunked define that should be discarded by reset.
          vt.writeString('\x1b_Sa=define,id=partial,m=1;dGVzdA==\x1b\\');
          events.clear();

          vt.writeString(seq);
          expect(vt.buffer.shaderRegions, isEmpty);
          expect(vt.buffer.hasCellTransforms, isFalse);
          expect(events, [const TerminalResetShaderEvent(target: .all)]);
        }
      },
    );
  });

  group('PtyRouter and TerminalPort shader forwarding', () {
    test(
      'forwards shader events across session/ports with isolation and updates a=query caps',
      () async {
        final router = PtyRouter();
        final backend = _FakeRoutedBackend();
        addTearDown(() async {
          await router.dispose();
          await backend.dispose();
        });

        final session = router.createSession(
          id: 'shader-sess',
          backend: backend,
          initialCols: 30,
          initialRows: 10,
        );
        final port1 = session.openPort(portId: 'p1');
        final port2 = session.openPort(portId: 'p2');

        final sessionEvents = <TerminalShaderApcEvent>[];
        final port1Events = <TerminalShaderApcEvent>[];
        final port2Events = <TerminalShaderApcEvent>[];

        session.addShaderListener(sessionEvents.add);
        port1
          ..addShaderListener((_) => throw StateError('boom'))
          ..addShaderListener(port1Events.add);
        port2.addShaderListener(port2Events.add);

        port1.setShaderCapabilities((
          backend: 'webgl2',
          glsl: true,
          xform: true,
          region: true,
          maxSlots: 16,
          maxRegions: 8,
        ));

        final prevRender = port1.renderRevision;
        final prevFullSync = port1.fullSyncRevision;
        backend.emitString(ShaderApcEncoder.encodeQuery());
        expect(
          backend.writtenReplies.single,
          '\x1b_Sa=caps,backend=webgl2,glsl=1,xform=1,region=1,max_slots=16,max_regions=8\x1b\\',
        );

        backend.emitString(
          ShaderApcEncoder.encodeTransform(
            col: 2,
            row: 3,
            transform: const CellTransform(dy: 1.5),
          ),
        );
        expect(port1.renderRevision, greaterThan(prevRender));
        expect(port1.fullSyncRevision, equals(prevFullSync));
        expect(sessionEvents, hasLength(2));
        expect(port1Events, hasLength(2));
        expect(port2Events, hasLength(2));
        expect(port1Events.last, isA<TerminalShaderTransformBatchEvent>());

        port2.removeShaderListener(port2Events.add);
        backend.emitString(ShaderApcEncoder.encodeReset(target: 'xforms'));
        expect(port1Events, hasLength(3));
        expect(port2Events, hasLength(2));

        await port1.dispose();
        await port2.dispose();
      },
    );
  });
}
