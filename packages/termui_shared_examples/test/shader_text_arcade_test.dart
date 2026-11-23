import 'dart:math' as math;

import 'package:termui/termui.dart';
import 'package:termui/ui/event.dart' as ui;
import 'package:termui_shared_examples/widget_book/shader_text_arcade_demo.dart';
import 'package:termui_shared_examples/widget_book/widget_book_platform.dart';
import 'package:termui_shared_examples/widget_book/widget_book_runner.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

String _bufferText(Buffer buffer) {
  final out = StringBuffer();
  for (var y = 0; y < buffer.height; y++) {
    for (var x = 0; x < buffer.width; x++) {
      out.write(buffer.characters[y * buffer.width + x]);
    }
    if (y + 1 < buffer.height) out.writeln();
  }
  return out.toString();
}

String _bufferRow(Buffer buffer, int y) {
  final out = StringBuffer();
  for (var x = 0; x < buffer.width; x++) {
    out.write(buffer.characters[y * buffer.width + x]);
  }
  return out.toString();
}

({int x, int y, int fg, int bg, int mod})? _findCell(
  Buffer buffer,
  String ch, {
  int minY = 0,
  int maxY = -1,
  int minX = 0,
}) {
  final endY = maxY < 0 ? buffer.height : math.min(maxY, buffer.height);
  for (var y = minY; y < endY; y++) {
    for (var x = minX; x < buffer.width; x++) {
      final idx = y * buffer.width + x;
      if (buffer.characters[idx] == ch) {
        return (
          x: x,
          y: y,
          fg: buffer.attributes[idx * 3],
          bg: buffer.attributes[idx * 3 + 1],
          mod: buffer.attributes[idx * 3 + 2],
        );
      }
    }
  }
  return null;
}

final class _NoopWidgetBookPlatform implements WidgetBookPlatform {
  @override
  bool get shouldRenderToTerminal => true;

  @override
  String? get initialPage => DemoPage.shaderArcade.name;

  @override
  void onFrameRedrawn(Buffer buffer) {}

  @override
  void startTicker(void Function(Duration elapsed) onTick) {}

  @override
  void stopTicker() {}

  @override
  bool handleKeyEvent(Terminal terminal, ui.KeyEvent event) => false;

  @override
  void onExit() {}

  @override
  Future<void> saveFile(String basename, List<int> bytes) async {}
}

Buffer _renderArcade(
  ShaderTextArcadeController controller, {
  int width = 84,
  int height = 26,
}) {
  final widget = ShaderTextArcadeWidget(controller: controller);
  final element = widget.createElement();
  element.mount(null);
  element.layout(BoxConstraints.tight(Size(width, height)));
  final buffer = Buffer(width, height);
  element.paint(buffer, Offset.zero);
  element.unmount();
  return buffer;
}

Set<String> _shaderIdsIn(Buffer buffer) => {
  for (final region in buffer.shaderRegions) region.shaderId,
};

bool _hasNonIdentityTransform(Buffer buffer) {
  final table = buffer.cellTransforms;
  if (table == null || table.isEmpty) return false;
  for (final entry in table.entries) {
    if (!entry.value.isIdentity) return true;
  }
  return false;
}

ui.KeyEvent _charKey(String ch) => ui.KeyEvent(ch, ui.KeyType.character);

ui.KeyEvent _specialKey(ui.KeyType type) => ui.KeyEvent('', type);

void main() {
  setUp(() {
    FocusManager.instance.setPrimaryFocus(null);
  });

  group('ShaderTextArcade scenes & shader regions (GPU mode)', () {
    test('all 5 scenes render cleanly and emit expected shader presets', () {
      final controller = ShaderTextArcadeController(gpuShadersSupported: true);
      addTearDown(controller.dispose);

      final expectedPresets = <ShaderArcadeScene, Set<String>>{
        ShaderArcadeScene.oneRing: {'one_ring'},
        ShaderArcadeScene.vortext: {'vortex'},
        ShaderArcadeScene.frostShatter: {'ice_frost'},
        ShaderArcadeScene.neonGlitch: {'neon_pulse', 'glitch_tear'},
        ShaderArcadeScene.forge: {'forge_spark'},
      };

      for (final entry in expectedPresets.entries) {
        controller.selectScene(entry.key);
        controller.stepPhysics();
        final buf = _renderArcade(controller);
        final ids = _shaderIdsIn(buf);
        expect(
          ids,
          containsAll(entry.value),
          reason: 'Scene ${entry.key.name} missing expected presets',
        );
        if (entry.key == ShaderArcadeScene.forge) {
          expect(ids, isNot(contains('water_ripple')));
        }
        expect(_bufferRow(buf, 0), contains('[GPU]'));
      }
    });

    test('renders cleanly inside TerminalTester PromptRunner', () {
      final tester = TerminalTester();
      tester.run(() async {
        final controller = ShaderTextArcadeController(
          gpuShadersSupported: true,
        );
        addTearDown(controller.dispose);
        final runner = PromptRunner<void>(
          terminal: tester.terminal,
          widget: ShaderTextArcadeWidget(controller: controller),
          alternateScreen: true,
        );
        final future = tester.runPrompt(runner, () async {
          await tester.pump();
          expect(_shaderIdsIn(tester.backend.buffer!), contains('one_ring'));
          controller.selectScene(ShaderArcadeScene.vortext);
          controller.stepPhysics();
          await tester.pump();
          expect(_shaderIdsIn(tester.backend.buffer!), contains('vortex'));
          expect(_hasNonIdentityTransform(tester.backend.buffer!), isTrue);
          runner.dispose();
        });
        await future;
      });
    });

    test(
      'One Ring fits verse without clipping, keeps border outside region, pauses autoTorch on drag, and pulses reset on R',
      () {
        final controller = ShaderTextArcadeController(
          gpuShadersSupported: true,
        );
        addTearDown(controller.dispose);

        final buf = _renderArcade(controller);
        final ringRegion = buf.shaderRegions.singleWhere(
          (r) => r.shaderId == 'one_ring',
        );
        final rect = ringRegion.sourceRects.single;
        final bandArgb = ShaderTextArcadeController.oneRingBandBackground.argb;

        // Every non-space glyph inside the One Ring region must have fg == bg
        // and must NOT contain box-drawing border glyphs.
        var runeCellCount = 0;
        const borderChars = {'┌', '┐', '└', '┘', '─', '│'};
        final renderedRows = <String>[];
        for (var y = rect.y; y < rect.y + rect.height; y++) {
          final rowBuf = StringBuffer();
          for (var x = rect.x; x < rect.x + rect.width; x++) {
            final idx = y * buf.width + x;
            final ch = buf.characters[idx];
            rowBuf.write(ch);
            expect(
              borderChars.contains(ch),
              isFalse,
              reason: 'Border glyph "$ch" leaked into one_ring region',
            );
            if (ch != ' ' && ch.isNotEmpty) {
              runeCellCount++;
              expect(buf.attributes[idx * 3], equals(bandArgb));
              expect(buf.attributes[idx * 3 + 1], equals(bandArgb));
            }
          }
          renderedRows.add(rowBuf.toString());
        }
        expect(runeCellCount, greaterThan(40));
        final regionText = renderedRows.join('\n');
        for (final line in ShaderTextArcadeController.ringVerse.split('\n')) {
          expect(
            regionText,
            contains(line),
            reason: 'One Ring verse line "$line" was clipped inside the band',
          );
        }

        // Enter editing mode (sets uParams1.y == 1.0), type, delete, and exit.
        expect(
          controller.handleKeyEvent(_specialKey(ui.KeyType.enter)),
          isTrue,
        );
        expect(controller.isEditingRingPrompt, isTrue);
        expect(controller.oneRingParams()[5], equals(1.0));
        expect(controller.handleKeyEvent(_charKey('!')), isTrue);
        expect(controller.ringPrompt, endsWith('!'));
        expect(
          controller.handleKeyEvent(_specialKey(ui.KeyType.backspace)),
          isTrue,
        );
        expect(controller.ringPrompt, 'speak friend and enter...');
        expect(
          controller.handleKeyEvent(_specialKey(ui.KeyType.escape)),
          isTrue,
        );
        expect(controller.isEditingRingPrompt, isFalse);
        expect(controller.oneRingParams()[5], equals(0.0));

        // Dragging pauses autoTorch and leaves uParams0.xy == (0, 0) so native
        // iMouse is the single exclusive flame source (no second stage torch).
        expect(controller.autoTorch, isTrue);
        controller.handleStagePointer(
          const ui.MouseEvent(
            type: ui.MouseEventType.drag,
            button: ui.MouseButton.left,
            x: 15,
            y: 3,
          ),
          15,
          3,
          60,
          16,
        );
        expect(controller.autoTorch, isFalse);
        final params = controller.oneRingParams();
        expect(params[0], equals(0.0));
        expect(params[1], equals(0.0));
        expect(params[3], closeTo(0.85, 0.01));

        // Pressing R sets the uParams1.x reset pulse to clear latched runes,
        // then clears back to 0.0 after a few frames.
        expect(controller.handleKeyEvent(_charKey('r')), isTrue);
        expect(controller.oneRingParams()[4], equals(1.0));
        for (var i = 0; i < 6; i++) {
          controller.stepPhysics();
        }
        expect(controller.oneRingParams()[4], equals(0.0));
      },
    );
  });

  group('ShaderTextArcade physics & cell transforms', () {
    test(
      'Vortext Black Hole permanently swallows letters until Reset and flares photon ring',
      () {
        final controller = ShaderTextArcadeController(
          initialScene: ShaderArcadeScene.vortext,
          gpuShadersSupported: true,
        );
        addTearDown(controller.dispose);

        final baseIntensity = controller.vortexParams()[2];
        expect(controller.vortexParams()[0], closeTo(0.5, 1e-4));
        expect(controller.vortexParams()[1], closeTo(0.5, 1e-4));
        expect(baseIntensity, greaterThanOrEqualTo(1.15));

        // Even when paused before any mouse click, the vortex region stays
        // centered with strong visible intensity.
        expect(controller.handleKeyEvent(_charKey(' ')), isTrue);
        expect(controller.vortextRunning, isFalse);
        final pausedBuf = _renderArcade(controller);
        final pausedRegion = pausedBuf.shaderRegions.singleWhere(
          (r) => r.shaderId == 'vortex',
        );
        expect(pausedRegion.params[0], closeTo(0.5, 1e-4));
        expect(pausedRegion.params[1], closeTo(0.5, 1e-4));
        expect(pausedRegion.params[2], closeTo(0.9, 1e-4));
        expect(controller.handleKeyEvent(_charKey(' ')), isTrue);
        expect(controller.vortextRunning, isTrue);

        var peakIntensity = baseIntensity;
        var prevSwallowed = 0;

        // Advance long enough for inner letters to cross the event horizon.
        for (var i = 0; i < 80; i++) {
          controller.stepPhysics();
          final nowSwallowed = controller.swallowedParticleCount;
          // Swallowed count must be monotonically non-decreasing (never pops back out!).
          expect(nowSwallowed, greaterThanOrEqualTo(prevSwallowed));
          prevSwallowed = nowSwallowed;
          final intensity = controller.vortexParams()[2];
          if (intensity > peakIntensity) peakIntensity = intensity;
        }

        expect(controller.swallowedParticleCount, greaterThan(0));
        expect(peakIntensity, greaterThan(baseIntensity));

        final bhBuf = _renderArcade(controller);
        expect(_shaderIdsIn(bhBuf), contains('vortex'));
        expect(controller.vortexParams()[3], 0.0);
        final swallowedTransforms = bhBuf.cellTransforms!.entries
            .where((e) => e.value.alpha == 0.0 && e.value.scaleX == 0.0)
            .length;
        expect(swallowedTransforms, equals(controller.swallowedParticleCount));

        // Stepping further never revives swallowed letters.
        final swallowedBefore = controller.swallowedParticleCount;
        for (var i = 0; i < 20; i++) {
          controller.stepPhysics();
        }
        expect(
          controller.swallowedParticleCount,
          greaterThanOrEqualTo(swallowedBefore),
        );

        // Reset snaps all letters back to unswallowed identity.
        expect(controller.handleKeyEvent(_charKey('r')), isTrue);
        expect(controller.swallowedParticleCount, equals(0));
        final resetBuf = _renderArcade(controller);
        expect(_hasNonIdentityTransform(resetBuf), isFalse);
      },
    );

    test(
      'Vortext Hurricane mode swirls letters counter-clockwise and steers eye via mouse',
      () {
        final controller = ShaderTextArcadeController(
          initialScene: ShaderArcadeScene.vortext,
          gpuShadersSupported: true,
        );
        addTearDown(controller.dispose);

        // Toggle to Hurricane mode with 'M' (`uParams0.w == 1.0`).
        expect(controller.handleKeyEvent(_charKey('m')), isTrue);
        expect(controller.vortextMode, VortextMode.hurricane);
        for (var i = 0; i < 8; i++) {
          controller.stepPhysics();
        }
        final hurricaneBuf = _renderArcade(controller);
        expect(controller.vortexParams()[3], 1.0);
        expect(_hasNonIdentityTransform(hurricaneBuf), isTrue);
        expect(controller.swallowedParticleCount, equals(0));

        // Dragging steers the hurricane eye in region-relative UV coordinates.
        controller.handleStagePointer(
          const ui.MouseEvent(
            type: ui.MouseEventType.drag,
            button: ui.MouseButton.left,
            x: 37,
            y: 4,
          ),
          37,
          4,
          80,
          24,
        );
        final expectedU =
            (37 - ShaderTextArcadeController.vortexRegionLeft) /
            (ShaderTextArcadeController.vortexRegionCols - 1);
        final expectedV =
            1.0 -
            (4 - ShaderTextArcadeController.vortexRegionTop) /
                (ShaderTextArcadeController.vortexRegionRows - 1);
        expect(controller.vortexCenterU, closeTo(expectedU, 0.02));
        expect(controller.vortexCenterV, closeTo(expectedV, 0.02));
      },
    );

    test(
      'moving Black Hole or Hurricane center never teleports particles (Cartesian physics)',
      () {
        for (final mode in VortextMode.values) {
          final controller = ShaderTextArcadeController(
            initialScene: ShaderArcadeScene.vortext,
          );
          addTearDown(controller.dispose);
          if (mode == VortextMode.hurricane) {
            controller.toggleVortextMode();
          }

          // Advance several ticks so particles are actively in motion.
          for (var i = 0; i < 12; i++) {
            controller.stepPhysics();
          }
          final before = <int, (double, double)>{};
          for (var i = 0; i < controller.totalVortexParticleCount; i++) {
            final t = controller.vortextTransformForChar(i, 'x', 1);
            if (t != null && t.alpha > 0.0 && t.scaleX > 0.0) {
              before[i] = (t.dx, t.dy);
            }
          }
          expect(before, isNotEmpty);

          // Abruptly drag the vortex center across to the far right corner.
          controller.handleStagePointer(
            const ui.MouseEvent(
              type: ui.MouseEventType.drag,
              button: ui.MouseButton.left,
              x: 42,
              y: 2,
            ),
            42,
            2,
            84,
            24,
          );
          controller.stepPhysics();

          var maxDelta = 0.0;
          for (final entry in before.entries) {
            final t = controller.vortextTransformForChar(entry.key, 'x', 2);
            if (t == null || t.alpha == 0.0 || t.scaleX == 0.0) continue;
            final delta = math.sqrt(
              math.pow(t.dx - entry.value.$1, 2) +
                  math.pow(t.dy - entry.value.$2, 2),
            );
            if (delta > maxDelta) maxDelta = delta;
          }
          expect(
            maxDelta,
            lessThan(2.0),
            reason:
                'Moving ${mode.label} center teleported a particle by $maxDelta cells',
          );
        }
      },
    );

    test(
      'Frost & Shatter runs 2-stage Warm -> Freezing -> Frozen shiver -> Shattering -> Warm',
      () {
        final controller = ShaderTextArcadeController(
          initialScene: ShaderArcadeScene.frostShatter,
          gpuShadersSupported: true,
        );
        addTearDown(controller.dispose);

        // Starts warm (frostIntensity == 0.0) with no cell transforms.
        expect(controller.frostPhase, FrostPhase.warm);
        expect(controller.frostIntensity, equals(0.0));
        final warmBuf = _renderArcade(controller);
        final frostRegion = warmBuf.shaderRegions.singleWhere(
          (r) => r.shaderId == 'ice_frost',
        );
        expect(frostRegion.stage, ShaderRegionStage.overGlyphs);
        expect(_hasNonIdentityTransform(warmBuf), isFalse);

        // First Space -> Freezing, creeps 0.0 -> 1.25 over ~1.4s into Frozen.
        expect(controller.handleKeyEvent(_charKey(' ')), isTrue);
        expect(controller.frostPhase, FrostPhase.freezing);
        for (var i = 0; i < 40; i++) {
          controller.stepPhysics();
        }
        expect(controller.frostPhase, FrostPhase.frozen);
        expect(controller.frostIntensity, closeTo(1.25, 0.01));
        final frozenBuf = _renderArcade(controller);
        // Frozen state applies subtle cryo shiver transforms.
        expect(_hasNonIdentityTransform(frozenBuf), isTrue);

        // Second Space while Frozen -> Shattering.
        expect(controller.handleKeyEvent(_charKey(' ')), isTrue);
        expect(controller.frostPhase, FrostPhase.shattering);
        expect(controller.frostShattered, isTrue);
        controller.stepPhysics();
        final shatterBuf = _renderArcade(controller);
        expect(_shaderIdsIn(shatterBuf), contains('ice_frost'));
        expect(_hasNonIdentityTransform(shatterBuf), isTrue);

        // R resets cleanly to Warm.
        expect(controller.handleKeyEvent(_charKey('r')), isTrue);
        expect(controller.frostPhase, FrostPhase.warm);
        expect(controller.frostIntensity, equals(0.0));
        final resetBuf = _renderArcade(controller);
        expect(_hasNonIdentityTransform(resetBuf), isFalse);
      },
    );

    test('Neon & Glitch burst drives glitch strength and slice jitter', () {
      final controller = ShaderTextArcadeController(
        initialScene: ShaderArcadeScene.neonGlitch,
        gpuShadersSupported: true,
      );
      addTearDown(controller.dispose);

      final calmStrength = controller.glitchParams()[0];
      expect(controller.handleKeyEvent(_charKey(' ')), isTrue);
      expect(controller.glitchParams()[0], greaterThan(calmStrength));

      final burstBuf = _renderArcade(controller);
      expect(
        _shaderIdsIn(burstBuf),
        containsAll({'neon_pulse', 'glitch_tear'}),
      );
      expect(_hasNonIdentityTransform(burstBuf), isTrue);
    });

    test(
      'Forge strikes single typed character sparks, auto-strikes phrase, and omits water_ripple',
      () {
        final controller = ShaderTextArcadeController(
          initialScene: ShaderArcadeScene.forge,
          gpuShadersSupported: true,
        );
        addTearDown(controller.dispose);

        // R clears the forge line.
        expect(controller.handleKeyEvent(_charKey('r')), isTrue);
        expect(controller.forgePrompt, isEmpty);
        expect(controller.strikeAgeSec, equals(0.0));

        // Mouse clicks and drags in Forge must NEVER trigger sparks.
        for (final type in const [
          ui.MouseEventType.press,
          ui.MouseEventType.drag,
          ui.MouseEventType.release,
        ]) {
          controller.handleStagePointer(
            ui.MouseEvent(type: type, button: ui.MouseButton.left, x: 20, y: 5),
            20,
            5,
            80,
            24,
          );
          expect(
            controller.strikeAgeSec,
            equals(0.0),
            reason: 'Mouse $type must not trigger forge sparks',
          );
        }

        // Typing a printable character appends it, triggers forge_spark centered
        // on that exact cell, and bounces ONLY that single letter.
        expect(controller.handleKeyEvent(_charKey('S')), isTrue);
        expect(controller.forgePrompt, 'S');
        expect(controller.strikeAgeSec, greaterThan(0.0));
        final uAfterS = controller.strikeOriginU;

        expect(controller.handleKeyEvent(_charKey('T')), isTrue);
        expect(controller.forgePrompt, 'ST');
        expect(controller.strikeOriginU, greaterThan(uAfterS));

        final typedBuf = _renderArcade(controller);
        expect(_shaderIdsIn(typedBuf), equals({'forge_spark'}));
        final bouncedCells = typedBuf.cellTransforms!.entries
            .where((e) => !e.value.isIdentity)
            .toList();
        expect(bouncedCells.length, equals(1));
        expect(bouncedCells.single.value.scaleX, closeTo(1.22, 0.01));
        expect(bouncedCells.single.value.dy, closeTo(-0.15, 0.01));

        // Space starts letter-by-letter Auto-Strike of "STRIKE THE ANVIL".
        expect(controller.handleKeyEvent(_charKey(' ')), isTrue);
        expect(controller.forgeAutoStrike, isTrue);
        expect(controller.forgePrompt, 'S');
        for (var i = 0; i < 5; i++) {
          controller.stepPhysics(); // 200ms > 180ms interval -> strikes 'T'
        }
        expect(controller.forgePrompt, 'ST');
      },
    );
  });

  group('ShaderTextArcade navigation, toggles & lifecycle', () {
    test('1-5, [, ] switch scenes and A/H/Space/R toggle scene modes', () {
      final controller = ShaderTextArcadeController();
      addTearDown(controller.dispose);

      expect(controller.autoTorch, isTrue);
      expect(controller.handleKeyEvent(_charKey('a')), isTrue);
      expect(controller.autoTorch, isFalse);

      expect(controller.hoverIgnite, isTrue);
      expect(controller.oneRingParams()[3], closeTo(0.85, 0.01));
      expect(controller.handleKeyEvent(_charKey('h')), isTrue);
      expect(controller.hoverIgnite, isFalse);
      expect(controller.oneRingParams()[3], 0.0);

      expect(controller.handleKeyEvent(_charKey('2')), isTrue);
      expect(controller.activeScene, ShaderArcadeScene.vortext);
      expect(controller.handleKeyEvent(_charKey(' ')), isTrue);
      expect(controller.vortextRunning, isFalse);

      expect(controller.handleKeyEvent(_charKey(']')), isTrue);
      expect(controller.activeScene, ShaderArcadeScene.frostShatter);
      expect(controller.handleKeyEvent(_charKey('[')), isTrue);
      expect(controller.activeScene, ShaderArcadeScene.vortext);
      expect(controller.handleKeyEvent(_charKey('5')), isTrue);
      expect(controller.activeScene, ShaderArcadeScene.forge);
      expect(controller.activeScene.tabLabel, 'Forge');
    });

    test('listener disposal stops further notifications cleanly', () {
      final controller = ShaderTextArcadeController();
      var calls = 0;
      void listener() => calls++;
      controller.addListener(listener);
      controller.stepPhysics();
      expect(calls, 1);

      controller.dispose();
      controller.stepPhysics();
      expect(calls, 1);
    });

    test('WidgetBook example wrapper ticks and routes input cleanly', () {
      final example = ShaderTextArcadeExample();
      expect(example.controller.gpuShadersSupported, isFalse);
      example.setGpuShadersSupported(true);
      expect(example.controller.gpuShadersSupported, isTrue);
      expect(example.requiresTick, isTrue);
      expect(example.tick(const Duration(milliseconds: 16)), isFalse);
      expect(example.tick(const Duration(milliseconds: 16)), isFalse);
      expect(example.tick(const Duration(milliseconds: 16)), isTrue);
      expect(example.handleKeyEvent(_charKey('3')), isTrue);
      expect(example.controller.activeScene, ShaderArcadeScene.frostShatter);
    });
  });

  group('ShaderTextArcade ANSI Fallback mode (gpuShadersSupported == false)', () {
    test('defaults to ANSI fallback chip and switches to GPU chip on caps', () {
      final controller = ShaderTextArcadeController();
      addTearDown(controller.dispose);

      expect(controller.gpuShadersSupported, isFalse);
      final ansiBuf = _renderArcade(controller);
      expect(_bufferRow(ansiBuf, 0), contains('[ANSI Fallback]'));
      expect(ansiBuf.shaderRegions, isEmpty);

      controller.setGpuShadersSupported(true);
      final gpuBuf = _renderArcade(controller);
      expect(_bufferRow(gpuBuf, 0), contains('[GPU]'));
      expect(_shaderIdsIn(gpuBuf), contains('one_ring'));
    });

    test(
      'WidgetBookApp sends ShaderApcEncoder.encodeQuery() and toggles GPU support on ShaderCapabilitiesEvent',
      () async {
        final backend = MockTerminalBackend(size: const math.Point(120, 30));
        final terminal = Terminal(backend);
        final app = WidgetBookApp(
          terminal: terminal,
          platform: _NoopWidgetBookPlatform(),
          isInline: false,
        );
        final element = app.createElement();
        element.mount(null);
        addTearDown(() {
          element.unmount();
          terminal.dispose();
        });

        expect(backend.writes.join(), contains(ShaderApcEncoder.encodeQuery()));

        // Initial frame shows ANSI fallback before host replies.
        element.layout(BoxConstraints.tight(const Size(120, 30)));
        final beforeBuf = Buffer(120, 30);
        element.paint(beforeBuf, Offset.zero);
        expect(_bufferText(beforeBuf), contains('[ANSI Fallback]'));

        // Simulate host GPU capability response (`ESC _ S a=caps,... ST`).
        backend.pushBytes(
          '\x1b_Sa=caps,backend=flutter_gpu,glsl=1,xform=1,region=1\x1b\\'
              .codeUnits,
        );
        await Future<void>.delayed(Duration.zero);
        element.rebuild();
        element.layout(BoxConstraints.tight(const Size(120, 30)));
        final afterBuf = Buffer(120, 30);
        element.paint(afterBuf, Offset.zero);
        expect(_bufferText(afterBuf), contains('[GPU]'));
      },
    );

    test(
      'One Ring ANSI fallback hides cold runes as spaces, latches on drag, flickers across ticks, and resets on R',
      () {
        final controller = ShaderTextArcadeController(
          initialScene: ShaderArcadeScene.oneRing,
          gpuShadersSupported: false,
        );
        addTearDown(controller.dispose);
        // Disable auto-torch to verify cold band is 100% hidden spaces.
        controller.toggleAutoTorch();

        // Band text begins at widget Y = 2 (tab+gap) + 5 (title+gap+border+pad) = 7, X = 5.
        const bandTopY = 7;
        const bandLeftX = 5;
        final coldBuf = _renderArcade(controller);
        expect(coldBuf.shaderRegions, isEmpty);
        for (
          var row = 0;
          row < ShaderTextArcadeController.oneRingBandRows;
          row++
        ) {
          for (
            var col = 0;
            col < ShaderTextArcadeController.oneRingContentWidth;
            col++
          ) {
            final idx = (bandTopY + row) * coldBuf.width + (bandLeftX + col);
            expect(
              coldBuf.characters[idx],
              equals(' '),
              reason: 'Cold One Ring cell ($col,$row) must render as space',
            );
          }
        }

        // Hovering once warms without latching (dim ember red), and moving away cools back to hidden.
        controller.handleStagePointer(
          const ui.MouseEvent(
            type: ui.MouseEventType.move,
            button: ui.MouseButton.none,
            x: 5,
            y: 5,
          ),
          ShaderTextArcadeController.oneRingBandTextLeft,
          ShaderTextArcadeController.oneRingBandTextTop,
          84,
          24,
        );
        expect(controller.oneRingCellLatched(0, 0), isFalse);
        expect(controller.oneRingCellHeat(0, 0), greaterThanOrEqualTo(0.08));
        final warmBuf = _renderArcade(controller);
        final warmIdx = bandTopY * warmBuf.width + bandLeftX;
        expect(warmBuf.characters[warmIdx], equals('O'));
        expect(
          warmBuf.attributes[warmIdx * 3],
          equals(const Color(135, 45, 12).argb),
        );

        // Dragging on empty gap row (row 4) renders flame ember indicator '*' or '~'.
        controller.handleStagePointer(
          const ui.MouseEvent(
            type: ui.MouseEventType.press,
            button: ui.MouseButton.left,
            x: 15,
            y: 9,
          ),
          ShaderTextArcadeController.oneRingBandTextLeft + 10,
          ShaderTextArcadeController.oneRingBandTextTop + 4,
          84,
          24,
        );
        final torchBuf = _renderArcade(controller);
        final torchIdx = (bandTopY + 4) * torchBuf.width + (bandLeftX + 10);
        expect(torchBuf.characters[torchIdx], anyOf(equals('*'), equals('~')));

        // Dragging across the start of line 0 ("One Ring") heats & latches letters.
        for (var step = 0; step < 3; step++) {
          controller.handleStagePointer(
            const ui.MouseEvent(
              type: ui.MouseEventType.drag,
              button: ui.MouseButton.left,
              x: 5,
              y: 5,
            ),
            ShaderTextArcadeController.oneRingBandTextLeft,
            ShaderTextArcadeController.oneRingBandTextTop,
            84,
            24,
          );
        }
        expect(controller.oneRingCellLatched(0, 0), isTrue);

        // Release pointer and advance ticks: latched 'O' stays revealed and flickers color.
        controller.handleStagePointer(
          const ui.MouseEvent(
            type: ui.MouseEventType.release,
            button: ui.MouseButton.left,
            x: 5,
            y: 5,
          ),
          ShaderTextArcadeController.oneRingBandTextLeft,
          ShaderTextArcadeController.oneRingBandTextTop,
          84,
          24,
        );
        final observedFgs = <int>{};
        for (var tick = 0; tick < 20; tick++) {
          controller.stepPhysics();
          final buf = _renderArcade(controller);
          final idx = bandTopY * buf.width + bandLeftX;
          expect(buf.characters[idx], equals('O'));
          observedFgs.add(buf.attributes[idx * 3]);
        }
        expect(
          observedFgs.length,
          greaterThan(1),
          reason: 'Latched One Ring rune should flicker across molten colors',
        );

        // Editing prompt works cleanly even in ANSI fallback mode.
        expect(
          controller.handleKeyEvent(_specialKey(ui.KeyType.enter)),
          isTrue,
        );
        expect(controller.isEditingRingPrompt, isTrue);
        final editBuf = _renderArcade(controller);
        expect(_bufferRow(editBuf, bandTopY + 5), contains('> speak friend'));
        expect(
          controller.handleKeyEvent(_specialKey(ui.KeyType.escape)),
          isTrue,
        );

        // Pressing R clears all ANSI heat & latches back to hidden spaces.
        expect(controller.handleKeyEvent(_charKey('r')), isTrue);
        expect(controller.hasAnyLatchedOneRingRune, isFalse);
        final resetBuf = _renderArcade(controller);
        final resetIdx = bandTopY * resetBuf.width + bandLeftX;
        expect(resetBuf.characters[resetIdx], equals(' '));
      },
    );

    test(
      'Vortext ANSI fallback renders notice and stanza cleanly without shaders',
      () {
        final controller = ShaderTextArcadeController(
          initialScene: ShaderArcadeScene.vortext,
          gpuShadersSupported: false,
        );
        addTearDown(controller.dispose);

        controller.stepPhysics();
        final buf = _renderArcade(controller);
        final text = _bufferText(buf);
        expect(buf.shaderRegions, isEmpty);
        expect(buf.hasCellTransforms, isFalse);
        expect(
          text,
          contains(
            'ANSI Fallback: Sub-pixel Black Hole & Hurricane VFX require a GPU shader',
          ),
        );
        expect(text, contains('host (run inside fterm).'));
        for (final line in ShaderTextArcadeController.vortextStanza.split(
          '\n',
        )) {
          expect(text, contains(line));
        }
        expect(controller.handleKeyEvent(_charKey('3')), isTrue);
        expect(controller.activeScene, ShaderArcadeScene.frostShatter);
      },
    );

    test(
      'Frost & Shatter ANSI fallback freezes to bold icy cyan and shatters characters across integer cells off-screen',
      () {
        final controller = ShaderTextArcadeController(
          initialScene: ShaderArcadeScene.frostShatter,
          gpuShadersSupported: false,
        );
        addTearDown(controller.dispose);

        // Warm state: headline rendered in warm white without bold.
        final warmBuf = _renderArcade(controller);
        expect(warmBuf.shaderRegions, isEmpty);
        final warmA = _findCell(warmBuf, 'A', minY: 4);
        expect(warmA, isNotNull);
        expect(warmA!.fg, equals(const Color(225, 232, 242).argb));
        expect(warmA.mod & Modifier.bold, equals(0));

        // Freeze -> Frozen: headline turns icy cyan/white + Modifier.bold.
        expect(controller.handleKeyEvent(_charKey(' ')), isTrue);
        for (var i = 0; i < 40; i++) {
          controller.stepPhysics();
        }
        expect(controller.frostPhase, FrostPhase.frozen);
        final frozenBuf = _renderArcade(controller);
        final frozenA = _findCell(frozenBuf, 'A', minY: 4);
        expect(frozenA, isNotNull);
        expect(frozenA!.mod & Modifier.bold, equals(Modifier.bold));
        expect(
          frozenA.fg,
          anyOf(
            equals(const Color(215, 250, 255).argb),
            equals(const Color(255, 255, 255).argb),
          ),
        );

        // Shatter: characters physically relocate across integer (x, y) coordinates.
        expect(controller.handleKeyEvent(_charKey(' ')), isTrue);
        expect(controller.frostPhase, FrostPhase.shattering);
        for (var i = 0; i < 6; i++) {
          controller.stepPhysics();
        }
        final midShatterBuf = _renderArcade(controller);
        expect(midShatterBuf.hasCellTransforms, isFalse);
        expect(
          _bufferRow(midShatterBuf, warmA.y),
          isNot(contains(ShaderTextArcadeController.frostHeadline)),
        );
        // At least some headline shards moved off the original headline row.
        var shardsOffHomeRow = 0;
        for (var i = 0; i < controller.frostShardCount; i++) {
          final snap = controller.frostShardSnapshot(i);
          if (snap.dy.round() != 0 || snap.dx.round() != 0) {
            shardsOffHomeRow++;
          }
        }
        expect(shardsOffHomeRow, greaterThan(10));

        // After falling further, shards leave viewport bounds cleanly without crashing.
        for (var i = 0; i < 35; i++) {
          controller.stepPhysics();
        }
        final lateShatterBuf = _renderArcade(controller);
        expect(lateShatterBuf.height, equals(26));
        var visibleInStage = 0;
        for (var y = 4; y < 24; y++) {
          for (var x = 0; x < lateShatterBuf.width; x++) {
            if (lateShatterBuf.characters[y * lateShatterBuf.width + x] !=
                ' ') {
              visibleInStage++;
            }
          }
        }
        expect(visibleInStage, lessThan(controller.frostShardCount));
      },
    );

    test(
      'Forge transitions newly struck character from white-hot bold -> gold bold -> amber -> cooled metal',
      () {
        final controller = ShaderTextArcadeController(
          initialScene: ShaderArcadeScene.forge,
          gpuShadersSupported: false,
        );
        addTearDown(controller.dispose);

        expect(controller.handleKeyEvent(_charKey('r')), isTrue);
        expect(controller.handleKeyEvent(_charKey('X')), isTrue);

        // t = 0.00s: White-hot + Bold.
        final t0Buf = _renderArcade(controller);
        expect(t0Buf.shaderRegions, isEmpty);
        expect(t0Buf.hasCellTransforms, isFalse);
        final x0 = _findCell(t0Buf, 'X', minY: 4);
        expect(x0, isNotNull);
        expect(x0!.fg, equals(const Color(255, 252, 235).argb));
        expect(x0.mod & Modifier.bold, equals(Modifier.bold));

        // t = 0.16s (4 ticks): Molten Gold + Bold.
        for (var i = 0; i < 4; i++) {
          controller.stepPhysics();
        }
        final t1Buf = _renderArcade(controller);
        final x1 = _findCell(t1Buf, 'X', minY: 4);
        expect(x1, isNotNull);
        expect(x1!.fg, equals(const Color(255, 200, 48).argb));
        expect(x1.mod & Modifier.bold, equals(Modifier.bold));

        // t = 0.32s (+4 ticks): Cooling Amber (Regular).
        for (var i = 0; i < 4; i++) {
          controller.stepPhysics();
        }
        final t2Buf = _renderArcade(controller);
        final x2 = _findCell(t2Buf, 'X', minY: 4);
        expect(x2, isNotNull);
        expect(x2!.fg, equals(const Color(220, 128, 36).argb));
        expect(x2.mod & Modifier.bold, equals(0));

        // t = 0.48s (+4 ticks): Cooled Forged Metal (Regular).
        for (var i = 0; i < 4; i++) {
          controller.stepPhysics();
        }
        final t3Buf = _renderArcade(controller);
        final x3 = _findCell(t3Buf, 'X', minY: 4);
        expect(x3, isNotNull);
        expect(x3!.fg, equals(const Color(210, 218, 228).argb));
        expect(x3.mod & Modifier.bold, equals(0));
      },
    );
  });
}
