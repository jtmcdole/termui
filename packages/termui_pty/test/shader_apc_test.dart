import 'dart:convert';
import 'dart:typed_data';

import 'package:termui/termui.dart';
import 'package:termui_pty/src/shader_apc_handler.dart';
import 'package:test/test.dart';

String _stripApcEnvelope(String wire) {
  expect(wire.startsWith('\x1b_'), isTrue);
  expect(wire.endsWith('\x1b\\'), isTrue);
  return wire.substring(2, wire.length - 2);
}

void main() {
  group('ShaderApcParser round-trip & bounds', () {
    test(
      'round-trips query, chunked define, wrapped region, xform, chunked xforms, set, uniform, reset',
      () {
        final events = <TerminalShaderApcEvent>[];
        final parser = ShaderApcParser(onShaderEvent: events.add);

        parser.handleApc(_stripApcEnvelope(ShaderApcEncoder.encodeQuery()));
        expect(events.removeLast(), const TerminalShaderQueryEvent());

        // Caps echo must be ignored to prevent TTY echo loops.
        parser.handleApc(
          _stripApcEnvelope(
            ShaderApcEncoder.encodeCapsReply(
              backend: 'flutter_gpu',
              glsl: true,
              region: true,
            ),
          ),
        );
        expect(events, isEmpty);

        const glsl =
            'void mainImage(out vec4 fragColor, in vec2 fragCoord) { fragColor = vec4(1.0); }';
        for (final frame in ShaderApcEncoder.encodeDefine(
          id: 'fire_custom',
          glslSource: glsl,
          persist: true,
          chunkRawBytes: 24,
        )) {
          parser.handleApc(_stripApcEnvelope(frame));
        }
        expect(
          events.removeLast(),
          const TerminalShaderDefineEvent(
            id: 'fire_custom',
            glslSource: glsl,
            persist: true,
          ),
        );

        final region = ShaderRegion(
          id: 'r1',
          shaderId: 'fire_custom',
          sourceRects: const [Rect(10, 4, 4, 1), Rect(0, 5, 6, 1)],
          padding: const CellPadding(top: 2, right: 1, bottom: 0, left: 1),
          stage: ShaderRegionStage.overGlyphs,
          zIndex: 2,
          persist: true,
          params: Float32List.fromList([1.2, 0, -0.5, 0, 0, 0, 0, 0]),
        );
        parser.handleApc(
          _stripApcEnvelope(ShaderApcEncoder.encodeRegion(region)),
        );
        final regionEvent = events.removeLast() as TerminalShaderRegionEvent;
        expect(regionEvent.remove, isFalse);
        expect(regionEvent.region, region);

        final singleTransform = const CellTransform(
          dx: 0.25,
          dy: -0.5,
          scaleX: 1.5,
          scaleY: 0.75,
          rotationRad: 1.25,
          alpha: 0.8,
          zLayer: 3,
          tween: CellTween(
            animationId: 7,
            endDx: 4.0,
            endDy: 12.0,
            endRotationRad: 3.14,
            endAlpha: 0.0,
            durationSec: 0.8,
            easing: CellTweenEasing.easeOut,
            fromCurrent: true,
            clearOnFinish: true,
          ),
        );
        parser.handleApc(
          _stripApcEnvelope(
            ShaderApcEncoder.encodeTransform(
              col: 10,
              row: 4,
              transform: singleTransform,
            ),
          ),
        );
        final singleEvent =
            events.removeLast() as TerminalShaderTransformBatchEvent;
        expect(singleEvent.entries.length, 1);
        expect(singleEvent.entries.single.col, 10);
        expect(singleEvent.entries.single.row, 4);
        expect(singleEvent.entries.single.transform, singleTransform);

        // Chunked a=xforms across > 64 KiB total (1200 entries -> 2 wire frames)
        final batchEntries = List<CellTransformEntry>.generate(
          1200,
          (i) => (
            col: i % 80,
            row: i ~/ 80,
            transform: CellTransform(
              dx: (i % 5) * 0.25,
              dy: 0.5,
              tween: CellTween(animationId: i, endDy: 3.0, durationSec: 0.5),
            ),
          ),
        );
        for (final frame in ShaderApcEncoder.encodeTransformsBatch(
          batchEntries,
          replace: true,
        )) {
          parser.handleApc(_stripApcEnvelope(frame));
        }
        final batchEvent =
            events.removeLast() as TerminalShaderTransformBatchEvent;
        expect(batchEvent.replace, isTrue);
        expect(batchEvent.entries.length, 1200);
        expect(parser.liveTransformCount, 1200);

        parser.handleApc(
          _stripApcEnvelope(
            ShaderApcEncoder.encodeSet(
              stage: 'post',
              presetId: 'crt_lottes',
              params: Float32List.fromList([0.4, 0, 0, 0, 0, 0, 0, 0]),
            ),
          ),
        );
        final setEvent = events.removeLast() as TerminalShaderSetEvent;
        expect(setEvent.presetId, 'crt_lottes');
        expect(setEvent.params[0], closeTo(0.4, 1e-4));

        parser.handleApc(
          _stripApcEnvelope(
            ShaderApcEncoder.encodeUniform(id: 'r1', params: {0: 2.5, 3: -1.0}),
          ),
        );
        final uniformEvent = events.removeLast() as TerminalShaderUniformEvent;
        expect(uniformEvent.id, 'r1');
        expect(uniformEvent.paramMask, (1 << 0) | (1 << 3));
        expect(uniformEvent.params[0], closeTo(2.5, 1e-4));
        expect(uniformEvent.params[3], closeTo(-1.0, 1e-4));

        parser.handleApc(_stripApcEnvelope(ShaderApcEncoder.encodeReset()));
        expect(
          events.removeLast(),
          const TerminalResetShaderEvent(target: ShaderResetTarget.all),
        );
        expect(parser.liveSlotCount, 0);
        expect(parser.activeRegionCount, 0);
        expect(parser.liveTransformCount, 0);
      },
    );

    test(
      'accepts one_ring, vortex, forge_spark, water_ripple region presets and retro_phosphor full-pane preset',
      () {
        final events = <TerminalShaderApcEvent>[];
        final parser = ShaderApcParser(onShaderEvent: events.add);

        const newRegionPresets = <String>[
          'one_ring',
          'vortex',
          'forge_spark',
          'water_ripple',
        ];
        for (var i = 0; i < newRegionPresets.length; i++) {
          final preset = newRegionPresets[i];
          parser.handleApc(
            _stripApcEnvelope(
              ShaderApcEncoder.encodeRegion(
                ShaderRegion(
                  id: 'r_$preset',
                  shaderId: preset,
                  sourceRects: <Rect>[Rect(i * 4, 0, 4, 1)],
                ),
              ),
            ),
          );
          final ev = events.removeLast() as TerminalShaderRegionEvent;
          expect(ev.remove, isFalse);
          expect(ev.region?.shaderId, preset);
        }

        parser.handleApc(
          _stripApcEnvelope(
            ShaderApcEncoder.encodeSet(
              stage: 'post',
              presetId: 'retro_phosphor',
              params: Float32List.fromList(<double>[
                0.18,
                0.35,
                1,
                0,
                0,
                0,
                0,
                0,
              ]),
            ),
          ),
        );
        final setEv = events.removeLast() as TerminalShaderSetEvent;
        expect(setEv.presetId, 'retro_phosphor');
        expect(setEv.params[2], closeTo(1.0, 1e-4));
      },
    );

    test(
      'enforces <= 32 KiB GLSL, <= 16 slots, <= 8 regions, and rejects NaN/malformed fuzz',
      () {
        final events = <TerminalShaderApcEvent>[];
        final parser = ShaderApcParser(onShaderEvent: events.add);

        // Oversized GLSL (> 32 KiB) split into chunks must emit nothing.
        final oversized = utf8.encode('a' * (32 * 1024 + 1));
        final b64Part1 = base64Encode(oversized.sublist(0, 18000));
        final b64Part2 = base64Encode(oversized.sublist(18000));
        parser.handleApc('Sa=define,id=huge,m=1;$b64Part1');
        parser.handleApc('Sa=define,id=huge,m=0;$b64Part2');
        expect(events, isEmpty);
        expect(parser.liveSlotCount, 0);

        // Slot cap <= 16
        final tinyB64 = base64Encode(utf8.encode('void mainImage(){}'));
        for (var i = 0; i < 20; i++) {
          parser.handleApc('Sa=define,id=s$i,m=0;$tinyB64');
        }
        expect(parser.liveSlotCount, 16);
        expect(events.length, 16);
        events.clear();

        // Region cap <= 8
        for (var i = 0; i < 12; i++) {
          parser.handleApc('Sa=region,id=r$i,s=fire,rects=0:0:2:1');
        }
        expect(parser.activeRegionCount, 8);
        expect(events.length, 8);
        events.clear();

        // Reject NaN / Infinity / malformed payloads cleanly (10,000 adversarial frames)
        for (var i = 0; i < 2000; i++) {
          parser.handleApc('Sa=xform,c=0,r=0,dx=NaN');
          parser.handleApc('Sa=xform,c=0,r=0,dur=Infinity');
          parser.handleApc('Sa=xform,c=0,r=0,dur=-1');
          parser.handleApc('Sa=region,id=bad,s=fire,rects=0:0:0:1');
          parser.handleApc('Sa=xforms,m=0;!!!not_base64!!!');
        }
        expect(events, isEmpty);
      },
    );
  });
}
