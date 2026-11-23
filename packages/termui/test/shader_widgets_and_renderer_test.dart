import 'dart:convert';
import 'dart:typed_data';

import 'package:termui/terminal/input_parser.dart';
import 'package:termui/termui.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

const String _sampleGlsl =
    'void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n'
    '  fragColor = vec4(1.0, 0.4, 0.1, 1.0);\n'
    '}';

const String _updatedGlsl =
    'void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n'
    '  fragColor = vec4(0.1, 0.7, 1.0, 1.0);\n'
    '}';

void main() {
  group('ShaderRegionWidget', () {
    test(
      'registers painted bounds, padding, stage, zIndex, persist, params',
      () {
        final buffer = Buffer.blank(20, 6);
        final params = Float32List.fromList([1.5, 0.25, 0, 0, 0, 0, 0, 0]);
        final widget = ShaderRegionWidget(
          id: 'fire_badge',
          shader: const ShaderRef.preset('fire'),
          padding: const CellPadding(top: 2, right: 1, bottom: 0, left: 1),
          stage: ShaderRegionStage.underGlyphs,
          zIndex: 3,
          persist: true,
          params: params,
          child: const Text('BURN', wrap: false),
        );

        ElementWidget(widget)
          ..layout(const BoxConstraints(maxWidth: 20, maxHeight: 6))
          ..paint(buffer, const Offset(4, 2));

        expect(buffer.shaderRegions, hasLength(1));
        final region = buffer.shaderRegions.single;
        expect(region.id, 'fire_badge');
        expect(region.shaderId, 'fire');
        expect(region.shaderRef, const ShaderRef.preset('fire'));
        expect(region.sourceRects, const [Rect(4, 2, 4, 1)]);
        expect(
          region.padding,
          const CellPadding(top: 2, right: 1, bottom: 0, left: 1),
        );
        expect(region.stage, ShaderRegionStage.underGlyphs);
        expect(region.zIndex, 3);
        expect(region.persist, isTrue);
        expect(region.params[0], closeTo(1.5, 1e-5));
        expect(region.params[1], closeTo(0.25, 1e-5));
      },
    );

    test('derives deterministic fallback id and honors enabled=false', () {
      final buf1 = Buffer.blank(20, 4);
      final buf2 = Buffer.blank(20, 4);

      const keyed = ShaderRegionWidget(
        key: ValueKey<String>('hero title!'),
        shader: ShaderRef.preset('neon_pulse'),
        child: Text('Hi', wrap: false),
      );
      ElementWidget(keyed)
        ..layout(const BoxConstraints(maxWidth: 20, maxHeight: 4))
        ..paint(buf1, const Offset(2, 1));
      expect(buf1.shaderRegions.single.id, 'sr_hero_title_');
      expect(
        () => ShaderApcEncoder.encodeRegion(buf1.shaderRegions.single),
        returnsNormally,
      );

      const unkeyed = ShaderRegionWidget(
        shader: CustomGlslShaderRef(
          id: 'my_fire',
          source: _sampleGlsl,
          persist: true,
        ),
        child: Text('Hot', wrap: false),
      );
      ElementWidget(unkeyed)
        ..layout(const BoxConstraints(maxWidth: 20, maxHeight: 4))
        ..paint(buf1, const Offset(5, 2));
      ElementWidget(unkeyed)
        ..layout(const BoxConstraints(maxWidth: 20, maxHeight: 4))
        ..paint(buf2, const Offset(5, 2));

      expect(buf1.shaderRegions.last.id, buf2.shaderRegions.single.id);
      expect(buf2.shaderRegions.single.persist, isTrue);

      final disabledBuf = Buffer.blank(10, 2);
      const disabled = ShaderRegionWidget(
        id: 'off',
        shader: ShaderRef.preset('fire'),
        enabled: false,
        child: Text('Off', wrap: false),
      );
      ElementWidget(disabled)
        ..layout(const BoxConstraints(maxWidth: 10, maxHeight: 2))
        ..paint(disabledBuf, Offset.zero);
      expect(disabledBuf.shaderRegions, isEmpty);
    });
  });

  group('CellTransformWidget & TweenText', () {
    test('CellTransformWidget transforms non-empty painted cells only', () {
      final buffer = Buffer.blank(12, 2);
      const xform = CellTransform(dx: 0.5, dy: -0.25, rotationRad: 0.3);
      const widget = CellTransformWidget(
        transform: xform,
        child: Text('A B', wrap: false),
      );

      ElementWidget(widget)
        ..layout(const BoxConstraints(maxWidth: 12, maxHeight: 2))
        ..paint(buffer, const Offset(2, 1));

      expect(buffer.getCellTransform(2, 1), xform); // 'A'
      expect(buffer.getCellTransform(3, 1), isNull); // ' ' skipped by default
      expect(buffer.getCellTransform(4, 1), xform); // 'B'
      expect(buffer.getCellTransform(5, 1), isNull); // outside child width

      final withSpaces = Buffer.blank(10, 2);
      const includeSpacesWidget = CellTransformWidget(
        transform: xform,
        includeSpaces: true,
        child: Text('A B', wrap: false),
      );
      ElementWidget(includeSpacesWidget)
        ..layout(const BoxConstraints(maxWidth: 10, maxHeight: 2))
        ..paint(withSpaces, Offset.zero);
      expect(withSpaces.getCellTransform(1, 0), xform);
    });

    test('CellTransformWidget supports per-cell transformBuilder', () {
      final buffer = Buffer.blank(10, 2);
      final widget = CellTransformWidget(
        transformBuilder: (lx, ly, ch) =>
            CellTransform(dy: lx * 0.5, zLayer: lx + 1),
        child: const Text('XYZ', wrap: false),
      );

      ElementWidget(widget)
        ..layout(const BoxConstraints(maxWidth: 10, maxHeight: 2))
        ..paint(buffer, const Offset(1, 0));

      expect(buffer.getCellTransform(1, 0), const CellTransform(zLayer: 1));
      expect(
        buffer.getCellTransform(2, 0),
        const CellTransform(dy: 0.5, zLayer: 2),
      );
      expect(
        buffer.getCellTransform(3, 0),
        const CellTransform(dy: 1.0, zLayer: 3),
      );
    });

    test(
      'TweenText keeps logical animationId stable across unrelated rebuilds and advances on fromCurrent keyframe change',
      () {
        final step1 = const TweenText(
          'BOOM',
          key: ValueKey<String>('headline'),
          perCharacter: true,
          tween: CellTween(
            animationId: 0,
            endDy: 4.0,
            durationSec: 0.4,
            easing: CellTweenEasing.easeOut,
            fromCurrent: true,
          ),
        );

        final host = ElementWidget(step1);
        final buf1 = Buffer.blank(10, 2);
        host
          ..layout(const BoxConstraints(maxWidth: 10, maxHeight: 2))
          ..paint(buf1, Offset.zero);

        final aid0Frame1 = buf1.getCellTransform(0, 0)!.tween!.animationId;
        final aid1Frame1 = buf1.getCellTransform(1, 0)!.tween!.animationId;
        final aid2Frame1 = buf1.getCellTransform(2, 0)!.tween!.animationId;
        final aid3Frame1 = buf1.getCellTransform(3, 0)!.tween!.animationId;
        expect(aid0Frame1, greaterThan(0));
        expect(aid1Frame1, aid0Frame1 + 1);
        expect(aid2Frame1, aid0Frame1 + 2);
        expect(aid3Frame1, aid0Frame1 + 3);

        // Unrelated rebuild with identical tween parameters must NOT change animationId.
        final rebuildSame = ElementWidget(step1);
        rebuildSame.internalElement = host.internalElement;
        final buf2 = Buffer.blank(10, 2);
        rebuildSame
          ..layout(const BoxConstraints(maxWidth: 10, maxHeight: 2))
          ..paint(buf2, Offset.zero);

        expect(buf2.getCellTransform(0, 0)!.tween!.animationId, aid0Frame1);
        expect(buf2.getCellTransform(3, 0)!.tween!.animationId, aid3Frame1);

        // Multi-step keyframe update (fromCurrent: true, new target endDy) advances animationId.
        final step2 = const TweenText(
          'BOOM',
          key: ValueKey<String>('headline'),
          perCharacter: true,
          tween: CellTween(
            animationId: 0,
            endDy: 9.0,
            endRotationRad: 1.5,
            durationSec: 0.4,
            easing: CellTweenEasing.easeIn,
            fromCurrent: true,
          ),
        );
        final nextHost = ElementWidget(step2);
        nextHost.internalElement = host.internalElement;
        final buf3 = Buffer.blank(10, 2);
        nextHost
          ..layout(const BoxConstraints(maxWidth: 10, maxHeight: 2))
          ..paint(buf3, Offset.zero);

        final aid0Frame3 = buf3.getCellTransform(0, 0)!.tween!.animationId;
        expect(aid0Frame3, aid0Frame1 + 1);
        expect(buf3.getCellTransform(0, 0)!.tween!.fromCurrent, isTrue);
        expect(buf3.getCellTransform(0, 0)!.tween!.endDy, 9.0);
        expect(buf3.getCellTransform(1, 0)!.tween!.animationId, aid0Frame3 + 1);
      },
    );

    test(
      'TweenText supports explicit animationId, characterTransform, alignment, and wide chars',
      () {
        final buf = Buffer.blank(12, 2);
        final widget = TweenText(
          'A🔥B',
          textAlign: TextAlign.right,
          wrap: false,
          perCharacter: true,
          animationId: 500,
          characterTransform: (i, ch, aid) => CellTransform(
            dx: i.toDouble(),
            tween: CellTween(animationId: aid, endDy: 2.0, durationSec: 0.5),
          ),
        );

        ElementWidget(widget)
          ..layout(BoxConstraints.tight(const Size(12, 1)))
          ..paint(buf, Offset.zero);

        // Width of 'A🔥B' is 1 + 2 + 1 = 4 -> right aligned at startX = 8.
        expect(buf.getCharacter(8, 0), 'A');
        expect(buf.getCharacter(9, 0), '🔥');
        expect(buf.getCharacter(11, 0), 'B');
        expect(buf.getCellTransform(8, 0)!.tween!.animationId, 500);
        expect(buf.getCellTransform(9, 0)!.tween!.animationId, 501);
        expect(buf.getCellTransform(10, 0), isNull); // wide continuation cell
        expect(buf.getCellTransform(11, 0)!.tween!.animationId, 502);
      },
    );
  });

  group('RichText / TextSpan ShaderRegion & CellTransform', () {
    test(
      'wrapped phrase "this word is on fire" emits ONE unified ShaderRegion across lines',
      () {
        final buffer = Buffer.blank(12, 4);
        final params = Float32List.fromList([1.2, 0.5, 0, 0, 0, 0, 0, 0]);
        final rich = RichText(
          text: TextSpan(
            children: [
              const TextSpan(text: 'Watch: '),
              TextSpan(
                text: 'this word is on fire',
                style: const Style(foreground: Colors.yellow),
                shader: const ShaderRef.preset('fire'),
                shaderRegionId: 'word_fire',
                shaderPadding: const CellPadding(
                  top: 2,
                  right: 1,
                  bottom: 0,
                  left: 1,
                ),
                shaderStage: ShaderRegionStage.overGlyphs,
                shaderParams: params,
              ),
              const TextSpan(text: ' now'),
            ],
          ),
        );

        ElementWidget(rich)
          ..layout(BoxConstraints.tight(const Size(12, 4)))
          ..paint(buffer, const Offset(0, 0));

        // Width 12 wrap:
        // Line 0: "Watch: this" -> 'this' at x=7, w=4
        // Line 1: "word is on"  -> 'word is on' at x=0, w=10
        // Line 2: "fire now"    -> 'fire' at x=0, w=4
        expect(buffer.shaderRegions, hasLength(1));
        final region = buffer.shaderRegions.single;
        expect(region.id, 'word_fire');
        expect(region.shaderId, 'fire');
        expect(region.sourceRects, const [
          Rect(7, 0, 4, 1),
          Rect(0, 1, 10, 1),
          Rect(0, 2, 4, 1),
        ]);
        expect(
          region.padding,
          const CellPadding(top: 2, right: 1, bottom: 0, left: 1),
        );
        expect(region.params[0], closeTo(1.2, 1e-5));

        final wire = ShaderApcEncoder.encodeRegion(region);
        expect(wire, contains('rects=7:0:4:1/0:1:10:1/0:2:4:1'));
        expect(wire.contains(';'), isFalse);
      },
    );

    test(
      'TextSpan applies CellTransform to tagged spans and inherits parent shader across nested children',
      () {
        final buffer = Buffer.blank(20, 2);
        const dropTransform = CellTransform(
          dy: 0.5,
          rotationRad: 0.25,
          tween: CellTween(animationId: 77, endDy: 6.0, durationSec: 0.6),
        );
        const rich = RichText(
          wrap: false,
          text: TextSpan(
            children: [
              TextSpan(text: 'OK '),
              TextSpan(
                shader: ShaderRef.preset('ice_frost'),
                shaderRegionId: 'frost_grp',
                children: [
                  TextSpan(text: 'cold '),
                  TextSpan(
                    text: 'ice',
                    style: Style(modifiers: Modifier.bold),
                    transform: dropTransform,
                  ),
                ],
              ),
            ],
          ),
        );

        ElementWidget(rich)
          ..layout(BoxConstraints.tight(const Size(20, 1)))
          ..paint(buffer, const Offset(1, 0));

        // 'OK ' -> cols 1..3 (untagged)
        // 'cold ice' -> cols 4..11 (unified shader region)
        expect(buffer.shaderRegions, hasLength(1));
        expect(buffer.shaderRegions.single.id, 'frost_grp');
        expect(buffer.shaderRegions.single.sourceRects, const [
          Rect(4, 0, 8, 1),
        ]);

        // Only 'ice' (cols 9, 10, 11) gets dropTransform.
        expect(buffer.getCellTransform(4, 0), isNull);
        expect(buffer.getCellTransform(8, 0), isNull);
        expect(buffer.getCellTransform(9, 0), dropTransform);
        expect(buffer.getCellTransform(10, 0), dropTransform);
        expect(buffer.getCellTransform(11, 0), dropTransform);
      },
    );
  });

  group('InputParser ShaderCapabilitiesEvent decoding', () {
    test('decodes enabled flutter_gpu and webgl2 caps replies', () {
      final parser = InputParser();
      final wire = ShaderApcEncoder.encodeCapsReply(
        backend: 'flutter_gpu',
        glsl: true,
        xform: true,
        region: true,
        maxSlots: 16,
        maxRegions: 8,
      );

      final events = parser.parse(utf8.encode(wire));
      expect(events, const [
        ShaderCapabilitiesEvent(
          backend: 'flutter_gpu',
          glsl: true,
          xform: true,
          region: true,
          maxSlots: 16,
          maxRegions: 8,
        ),
      ]);

      // Chunked APC delivery (including split ST terminator \x1b + \\).
      final streamed = <InputEvent>[
        ...parser.parse(utf8.encode('\x1b_Sa=caps,backend=webgl2,')),
        ...parser.parse(utf8.encode('glsl=1,xform=1,region=1,')),
        ...parser.parse(utf8.encode('max_slots=12,max_regions=6\x1b')),
        ...parser.parse(utf8.encode('\\')),
      ];
      expect(streamed, const [
        ShaderCapabilitiesEvent(
          backend: 'webgl2',
          glsl: true,
          xform: true,
          region: true,
          maxSlots: 12,
          maxRegions: 6,
        ),
      ]);

      // BEL terminator is also accepted.
      final belEvents = parser.parse(
        utf8.encode(
          '\x1b_Sa=caps,backend=flutter_gpu,glsl=1,xform=1,region=1\x07',
        ),
      );
      expect(belEvents, const [
        ShaderCapabilitiesEvent(
          backend: 'flutter_gpu',
          glsl: true,
          xform: true,
          region: true,
          maxSlots: 16,
          maxRegions: 8,
        ),
      ]);
    });

    test(
      'decodes negative glsl=0,backend=disabled reports and ignores non-caps S APC',
      () {
        final parser = InputParser();

        final disabledWire = ShaderApcEncoder.encodeCapsReply(
          backend: 'disabled',
          glsl: false,
          xform: true,
          region: false,
          maxSlots: 0,
          maxRegions: 0,
        );
        expect(parser.parse(utf8.encode(disabledWire)), const [
          ShaderCapabilitiesEvent(
            backend: 'disabled',
            glsl: false,
            xform: true,
            region: false,
            maxSlots: 0,
            maxRegions: 0,
          ),
        ]);

        final minimalDisabled = parser.parse(
          utf8.encode('\x1b_Sa=caps,glsl=0,backend=disabled\x1b\\'),
        );
        expect(minimalDisabled, const [
          ShaderCapabilitiesEvent(
            backend: 'disabled',
            glsl: false,
            xform: false,
            region: false,
            maxSlots: 0,
            maxRegions: 0,
          ),
        ]);
        expect(
          (minimalDisabled.single as ShaderCapabilitiesEvent).isAnySupported,
          isFalse,
        );

        // Non-caps ESC _ S payloads produce no events.
        expect(
          parser.parse(utf8.encode('\x1b_Sa=reset,target=all\x1b\\')),
          isEmpty,
        );
      },
    );
  });

  group('Renderer ESC _ S APC diffing & capability fallbacks', () {
    test(
      'emits ZERO ESC _ S sequences on plain terminals (shaderCapabilities == null)',
      () {
        final renderer = Renderer(20, 4);
        final buf = Buffer.blank(20, 4);
        buf.writeString(0, 0, 'fire', Style.empty);
        buf.addShaderRegion(
          ShaderRegion.fromRef(
            id: 'r1',
            shader: const ShaderRef.glsl(
              id: 'custom_fire',
              source: _sampleGlsl,
            ),
            sourceRects: const [Rect(0, 0, 4, 1)],
          ),
        );
        buf.setCellTransform(0, 0, const CellTransform(dy: 1.5));

        final out = StringBuffer();
        renderer.render(buf, out);
        expect(out.toString().contains('\x1b_S'), isFalse);
      },
    );

    test(
      'skips a=define and a=region when glsl=0,region=0,backend=disabled, while emitting a=xform if xform=1',
      () {
        final renderer = Renderer(
          20,
          4,
          shaderCapabilities: const ShaderCapabilitiesEvent(
            backend: 'disabled',
            glsl: false,
            xform: true,
            region: false,
            maxSlots: 0,
            maxRegions: 0,
          ),
        );

        final buf = Buffer.blank(20, 4);
        buf.writeString(0, 0, 'fall', Style.empty);
        buf.addShaderRegion(
          ShaderRegion.fromRef(
            id: 'r1',
            shader: const ShaderRef.glsl(id: 'my_glsl', source: _sampleGlsl),
            sourceRects: const [Rect(0, 0, 4, 1)],
          ),
        );
        buf.setCellTransform(
          0,
          0,
          const CellTransform(
            dy: 2.0,
            tween: CellTween(animationId: 5, endDy: 8.0, durationSec: 0.5),
          ),
        );

        final out = StringBuffer();
        renderer.render(buf, out);
        final wire = out.toString();
        expect(wire, isNot(contains('a=define')));
        expect(wire, isNot(contains('a=region')));
        expect(
          wire,
          contains('\x1b_Sa=xform,c=0,r=0,dy=2,aid=5,edy=8,dur=0.5\x1b\\'),
        );
      },
    );

    test(
      'deduplicates custom GLSL uploads by content hash and re-uploads on source change',
      () {
        final renderer = Renderer(
          20,
          4,
          shaderCapabilities: const ShaderCapabilitiesEvent(
            backend: 'flutter_gpu',
            glsl: true,
            xform: true,
            region: true,
          ),
        );

        final buf1 = Buffer.blank(20, 4);
        buf1.addShaderRegion(
          ShaderRegion.fromRef(
            id: 'r1',
            shader: const ShaderRef.glsl(
              id: 'flame',
              source: _sampleGlsl,
              persist: true,
            ),
            sourceRects: const [Rect(0, 0, 4, 1)],
          ),
        );
        buf1.addShaderRegion(
          ShaderRegion.fromRef(
            id: 'r2',
            shader: const ShaderRef.glsl(
              id: 'flame',
              source: _sampleGlsl,
              persist: true,
            ),
            sourceRects: const [Rect(0, 1, 4, 1)],
          ),
        );

        final out1 = StringBuffer();
        renderer.render(buf1, out1);
        final wire1 = out1.toString();
        expect('a=define'.allMatches(wire1).length, 1);
        expect(wire1, contains('a=region,id=r1,s=flame'));
        expect(wire1, contains('a=region,id=r2,s=flame'));

        // Frame 2: identical buffer -> ZERO ESC _ S emitted.
        final out2 = StringBuffer();
        renderer.render(buf1, out2);
        expect(out2.toString().contains('\x1b_S'), isFalse);

        // Frame 3: move r1 only -> emits only r1 region update, NO re-define!
        final buf3 = Buffer.blank(20, 4);
        buf3.addShaderRegion(
          ShaderRegion.fromRef(
            id: 'r1',
            shader: const ShaderRef.glsl(
              id: 'flame',
              source: _sampleGlsl,
              persist: true,
            ),
            sourceRects: const [Rect(2, 0, 4, 1)],
          ),
        );
        buf3.addShaderRegion(
          ShaderRegion.fromRef(
            id: 'r2',
            shader: const ShaderRef.glsl(
              id: 'flame',
              source: _sampleGlsl,
              persist: true,
            ),
            sourceRects: const [Rect(0, 1, 4, 1)],
          ),
        );
        final out3 = StringBuffer();
        renderer.render(buf3, out3);
        final wire3 = out3.toString();
        expect(wire3, isNot(contains('a=define')));
        expect(wire3, contains('a=region,id=r1,s=flame,rects=2:0:4:1'));
        expect(wire3, isNot(contains('id=r2')));

        // Frame 4: update GLSL source -> re-uploads a=define once.
        final buf4 = Buffer.blank(20, 4);
        buf4.addShaderRegion(
          ShaderRegion.fromRef(
            id: 'r1',
            shader: const ShaderRef.glsl(
              id: 'flame',
              source: _updatedGlsl,
              persist: true,
            ),
            sourceRects: const [Rect(2, 0, 4, 1)],
          ),
        );
        final out4 = StringBuffer();
        renderer.render(buf4, out4);
        final wire4 = out4.toString();
        expect('a=define'.allMatches(wire4).length, 1);
        expect(wire4, contains('\x1b_Sa=region,id=r2,del=1\x1b\\'));
        expect(wire4, contains('a=region,id=r1,s=flame'));

        // Frame 5: clear remaining region -> emits del=1.
        final buf5 = Buffer.blank(20, 4);
        final out5 = StringBuffer();
        renderer.render(buf5, out5);
        expect(out5.toString(), contains('\x1b_Sa=region,id=r1,del=1\x1b\\'));
      },
    );

    test(
      'diffs CellTransforms minimally across rebuilds, batches multi-cell updates via a=xforms, and resets cleanly',
      () {
        final renderer = Renderer(
          20,
          4,
          shaderCapabilities: const ShaderCapabilitiesEvent(
            backend: 'webgl2',
            glsl: true,
            xform: true,
            region: true,
          ),
        );

        final widget = const TweenText(
          'HI',
          perCharacter: true,
          animationId: 10,
          tween: CellTween(
            animationId: 0,
            endDy: 5.0,
            durationSec: 0.6,
            fromCurrent: true,
          ),
        );

        final buf1 = Buffer.blank(20, 4);
        ElementWidget(widget)
          ..layout(const BoxConstraints(maxWidth: 20, maxHeight: 4))
          ..paint(buf1, Offset.zero);

        final out1 = StringBuffer();
        renderer.render(buf1, out1);
        final wire1 = out1.toString();
        // Two transformed cells -> packed a=xforms batch.
        expect(wire1, contains('\x1b_Sa=xforms,m=0;'));

        // Unrelated rebuild with identical animationId -> ZERO ESC _ S!
        final buf2 = Buffer.blank(20, 4);
        ElementWidget(widget)
          ..layout(const BoxConstraints(maxWidth: 20, maxHeight: 4))
          ..paint(buf2, Offset.zero);
        final out2 = StringBuffer();
        renderer.render(buf2, out2);
        expect(out2.toString().contains('\x1b_S'), isFalse);

        // Clearing multiple transforms emits a=reset,target=xforms.
        final buf3 = Buffer.blank(20, 4);
        final out3 = StringBuffer();
        renderer.render(buf3, out3);
        expect(out3.toString(), contains('\x1b_Sa=reset,target=xforms\x1b\\'));

        // Explicit resetShaders emits a=reset,target=all.
        final resetOut = StringBuffer();
        renderer.resetShaders(resetOut);
        expect(resetOut.toString(), '\x1b_Sa=reset,target=all\x1b\\');
      },
    );

    test(
      'supports late shaderCapabilities arrival and preset-only glsl=0,region=1 mode',
      () {
        final renderer = Renderer(20, 4);
        final buf = Buffer.blank(20, 4);
        buf.addShaderRegion(
          ShaderRegion.fromRef(
            id: 'preset_r',
            shader: const ShaderRef.preset('fire'),
            sourceRects: const [Rect(0, 0, 4, 1)],
          ),
        );
        buf.addShaderRegion(
          ShaderRegion.fromRef(
            id: 'custom_r',
            shader: const ShaderRef.glsl(id: 'custom', source: _sampleGlsl),
            sourceRects: const [Rect(0, 1, 4, 1)],
          ),
        );

        // Frame 1 on plain terminal: emits nothing.
        final out1 = StringBuffer();
        renderer.render(buf, out1);
        expect(out1.toString(), isNot(contains('\x1b_S')));

        // Capabilities arrive with glsl=0, region=1 (presets allowed, custom GLSL blocked).
        renderer.shaderCapabilities = const ShaderCapabilitiesEvent(
          backend: 'disabled',
          glsl: false,
          xform: true,
          region: true,
          maxSlots: 0,
          maxRegions: 8,
        );
        final out2 = StringBuffer();
        renderer.render(buf, out2);
        final wire2 = out2.toString();
        expect(wire2, contains('a=region,id=preset_r,s=fire'));
        expect(wire2, isNot(contains('a=define')));
        expect(wire2, isNot(contains('id=custom_r')));

        // Packed a=xforms round-trip verification.
        buf.setCellTransform(1, 0, const CellTransform(dx: 0.5, dy: -1.0));
        buf.setCellTransform(
          2,
          0,
          const CellTransform(
            rotationRad: 0.5,
            tween: CellTween(
              animationId: 99,
              endDy: 3.0,
              durationSec: 0.4,
              fromCurrent: true,
            ),
          ),
        );
        final out3 = StringBuffer();
        renderer.render(buf, out3);
        final wire3 = out3.toString();
        final match = RegExp(
          r'\x1b_Sa=xforms,m=0;([A-Za-z0-9+/=]+)\x1b\\',
        ).firstMatch(wire3);
        expect(match, isNotNull);
        final decoded = CellTransformCodec.unpackBatch(
          base64Decode(match!.group(1)!),
        );
        expect(decoded, hasLength(2));
        expect(decoded[1].transform!.tween!.animationId, 99);
        expect(decoded[1].transform!.tween!.fromCurrent, isTrue);
      },
    );

    test(
      'SceneManager forwards ShaderCapabilitiesEvent to its Renderer',
      () async {
        final backend = MockTerminalBackend();
        final terminal = MockTerminal(backend);
        final manager = SceneManager(terminal);
        addTearDown(() {
          manager.dispose();
          terminal.dispose();
        });

        const caps = ShaderCapabilitiesEvent(
          backend: 'flutter_gpu',
          glsl: true,
          xform: true,
          region: true,
        );
        terminal.injectTestEvent(caps);
        await Future<void>.delayed(Duration.zero);

        manager.render();
        expect(manager.renderer?.shaderCapabilities, caps);
      },
    );
  });
}
