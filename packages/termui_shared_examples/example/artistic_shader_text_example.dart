import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/termui.dart';

/// Custom Ghostty Shadertoy GLSL flame shader uploaded once by content hash via
/// `ESC _ S a=define` and attached to `"this word is on fire"` via
/// [ShaderRegion] / [TextSpan].
const String _customFireGlsl = '''
float _demoHash(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

float _demoNoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(
    mix(_demoHash(i), _demoHash(i + vec2(1.0, 0.0)), u.x),
    mix(_demoHash(i + vec2(0.0, 1.0)), _demoHash(i + vec2(1.0, 1.0)), u.x),
    u.y
  );
}

float _demoFbm(vec2 p) {
  float v = 0.0;
  float a = 0.55;
  for (int i = 0; i < 4; i++) {
    v += a * _demoNoise(p);
    p = p * 2.02 + vec2(3.1, 7.4);
    a *= 0.5;
  }
  return v;
}

float _demoMask(vec2 uv) {
  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return 0.0;
  return texture(iChannel0, uv).a;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 res = max(iResolution.xy, vec2(1.0));
  vec2 uv = fragCoord / res;
  vec2 cellUv = max(iCellSize / res, vec2(1.0 / res));
  float intensity = uParams0.x > 0.0 ? uParams0.x : 1.25;
  float t = iTime;

  vec2 flow = vec2(uv.x * 8.5, uv.y * 5.0 - t * 3.8);
  vec2 warp = vec2(
    _demoFbm(flow + vec2(1.9, 4.2)),
    _demoFbm(flow + vec2(6.3, -t * 1.6))
  ) - 0.5;

  float fuel = 0.0;
  for (int i = 0; i < 9; i++) {
    float s = float(i) / 8.0;
    float sway = (warp.x + warp.y * s) * cellUv.x * (0.25 + 2.0 * s * s);
    float m = _demoMask(vec2(uv.x - sway, uv.y - s * cellUv.y * 2.65));
    fuel += m * (1.0 - s * 0.82) * (1.0 - s * 0.55);
  }
  fuel = fuel * 0.44 + _demoMask(uv) * 0.45;

  float tongues = _demoFbm(vec2(uv.x * 13.0, uv.y * 7.5 - t * 5.2) + warp * 1.8);
  float edgeFade =
      smoothstep(1.0, 0.76, uv.y) *
      smoothstep(0.0, 0.03, uv.x) *
      smoothstep(1.0, 0.97, uv.x);
  float plasma = clamp(
    (fuel * 1.28 + (tongues - 0.42) * 1.05 * smoothstep(0.03, 0.40, fuel)) *
        intensity *
        edgeFade,
    0.0,
    1.0
  );
  float alpha = smoothstep(0.06, 0.50, plasma);

  // Electric cobalt -> cyan -> incandescent white plasma flames (contrasts with built-in fire).
  vec3 deepBlue = vec3(0.05, 0.16, 0.92);
  vec3 cyan = vec3(0.08, 0.82, 1.0);
  vec3 core = vec3(0.88, 0.98, 1.0);
  vec3 col = mix(deepBlue, cyan, smoothstep(0.10, 0.55, plasma));
  col = mix(col, core, smoothstep(0.58, 0.94, plasma));

  // Frame-rate-normalized subtle persistence glow via iPrevFrame.
  float decay = pow(0.35, clamp(iTimeDelta, 0.004, 0.05) * 60.0);
  vec4 prev = texture(iPrevFrame, uv);
  fragColor = vec4(max(col * alpha, prev.rgb * decay), max(alpha, prev.a * decay));
}
''';

/// Interactive Step 3 showcase demonstrating:
/// 1. Inline [RichText] `"this word is on fire"` with a scoped [ShaderRegion]
///    (toggling between built-in `'fire'` preset and CLI-uploaded custom GLSL).
/// 2. `Space` to trigger a CLI-side ~25 Hz explosion/gravity simulation that
///    streams [CellTween] keyframes (`fromCurrent: true`) so headline letters
///    shatter and tumble smoothly at 120 Hz across the pane.
Future<void> main() async {
  await term.Terminal.runGuarded((terminal) async {
    terminal
      ..enterAlternateScreen()
      ..hideCursor();

    final controller = _ArtisticDemoController();
    final sceneManager = SceneManager(
      terminal,
      renderingMode: RenderingMode.alternateScreen,
    );
    final runner = PromptRunner<void>(
      terminal: terminal,
      widget: _ArtisticDemoWidget(controller: controller),
      alternateScreen: false,
      mode: ExecutionMode.managed,
      exitConditions: const {},
      onFramePainted: (_) => sceneManager.scheduleRender(),
    );
    final layer = SceneLayer(
      renderer: runner,
      sizing: LayerSizing.fullscreen,
      zIndex: 10,
    );
    sceneManager.layers.add(layer);
    sceneManager.focusedLayer = layer;
    unawaited(runner.run().catchError((Object _) {}));
    terminal.backend.write(ShaderApcEncoder.encodeQuery());

    final completer = Completer<void>();
    sceneManager.onKeyEvent = (event) =>
        _handleKeyEvent(event, controller: controller, completer: completer);

    final physicsTimer = Timer.periodic(
      const Duration(milliseconds: 40),
      (_) => controller.stepPhysics(),
    );
    final eventsSub = terminal.events.listen(
      null,
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
    );

    try {
      await completer.future;
    } finally {
      unawaited(eventsSub.cancel());
      physicsTimer.cancel();
      runner.abort();
      sceneManager.dispose();
      terminal
        ..exitAlternateScreen()
        ..showCursor();
    }
  });
  exit(0);
}

bool _handleKeyEvent(
  KeyEvent event, {
  required _ArtisticDemoController controller,
  required Completer<void> completer,
}) => switch (event) {
  KeyEvent(key: 'q' || 'Q' || '\x03') ||
  KeyEvent(logicalKey: TermKey.controlC || TermKey.escape) => () {
    if (!completer.isCompleted) completer.complete();
    return true;
  }(),
  KeyEvent(key: ' ') => () {
    controller.triggerExplosion();
    return true;
  }(),
  KeyEvent(key: 'c' || 'C') => () {
    controller.toggleCustomGlsl();
    return true;
  }(),
  KeyEvent(key: 'r' || 'R') => () {
    controller.resetParticles();
    return true;
  }(),
  _ => false,
};

final class _LetterParticle {
  double dx = 0.0;
  double dy = 0.0;
  double vx = 0.0;
  double vy = 0.0;
  double rot = 0.0;
  double vRot = 0.0;
  double scale = 1.0;
  double alpha = 1.0;
}

final class _ArtisticDemoController {
  static const String headline = 'SHATTER & TUMBLE';
  static const double stepSec = 0.04; // 25 Hz CLI physics -> 120 Hz host tweens
  static const double gravity = 32.0;

  final math.Random _rng = math.Random(364);
  final List<_LetterParticle> particles = List<_LetterParticle>.generate(
    headline.length,
    (_) => _LetterParticle(),
  );
  final List<void Function()> _listeners = <void Function()>[];

  bool useCustomGlsl = false;
  bool exploding = false;
  int keyframeEpoch = 1;
  double elapsedSec = 0.0;

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _notify() {
    for (final fn in [..._listeners]) {
      fn();
    }
  }

  void toggleCustomGlsl() {
    useCustomGlsl = !useCustomGlsl;
    _notify();
  }

  void triggerExplosion() {
    exploding = true;
    elapsedSec = 0.0;
    keyframeEpoch = (keyframeEpoch + 1) & 0xFF;
    final center = particles.length * 0.5;
    for (var i = 0; i < particles.length; i++) {
      particles[i]
        ..dx = 0.0
        ..dy = 0.0
        ..vx = (i - center) * 1.8 + (_rng.nextDouble() - 0.5) * 6.0
        ..vy = -9.0 - _rng.nextDouble() * 8.0
        ..rot = 0.0
        ..vRot = (_rng.nextDouble() - 0.5) * 12.0
        ..scale = 0.9 + _rng.nextDouble() * 0.5
        ..alpha = 1.0;
    }
    _notify();
  }

  void resetParticles() {
    exploding = false;
    elapsedSec = 0.0;
    for (final p in particles) {
      p
        ..dx = 0.0
        ..dy = 0.0
        ..vx = 0.0
        ..vy = 0.0
        ..rot = 0.0
        ..vRot = 0.0
        ..scale = 1.0
        ..alpha = 1.0;
    }
    _notify();
  }

  void stepPhysics() {
    if (!exploding) return;
    elapsedSec += stepSec;
    keyframeEpoch = (keyframeEpoch + 1) & 0xFF;
    for (final p in particles) {
      p
        ..dx += p.vx * stepSec
        ..dy += p.vy * stepSec + 0.5 * gravity * stepSec * stepSec
        ..vy += gravity * stepSec
        ..rot += p.vRot * stepSec
        ..alpha = (1.0 - elapsedSec / 2.2).clamp(0.0, 1.0);
    }
    if (elapsedSec >= 2.2) {
      resetParticles();
      return;
    }
    _notify();
  }

  CellTransform? transformForChar(int charIndex, String _, int animId) {
    if (!exploding || charIndex < 0 || charIndex >= particles.length) {
      return null;
    }
    final p = particles[charIndex];
    const tweenDurationSec = stepSec * 1.35;
    final nextDx = p.dx + p.vx * tweenDurationSec;
    final nextDy =
        p.dy +
        p.vy * tweenDurationSec +
        0.5 * gravity * tweenDurationSec * tweenDurationSec;
    final nextRot = p.rot + p.vRot * tweenDurationSec;
    final nextAlpha = (1.0 - (elapsedSec + tweenDurationSec) / 2.2).clamp(
      0.0,
      1.0,
    );
    return CellTransform(
      dx: p.dx,
      dy: p.dy,
      scaleX: p.scale,
      scaleY: p.scale,
      rotationRad: p.rot,
      alpha: p.alpha,
      zLayer: 2,
      tween: CellTween(
        animationId: animId,
        endDx: nextDx,
        endDy: nextDy,
        endScaleX: p.scale,
        endScaleY: p.scale,
        endRotationRad: nextRot,
        endAlpha: nextAlpha,
        durationSec: tweenDurationSec,
        easing: CellTweenEasing.linear,
        fromCurrent: true,
        clearOnFinish: nextAlpha <= 0.01,
      ),
    );
  }
}

final class _ArtisticDemoWidget extends StatefulWidget {
  final _ArtisticDemoController controller;

  const _ArtisticDemoWidget({required this.controller});

  @override
  State<_ArtisticDemoWidget> createState() => _ArtisticDemoState();
}

final class _ArtisticDemoState extends State<_ArtisticDemoWidget> {
  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final shaderRef = ctrl.useCustomGlsl
        ? const ShaderRef.glsl(
            id: 'demo_fire',
            source: _customFireGlsl,
            persist: true,
          )
        : const ShaderRef.preset('fire');
    final modeText = ctrl.useCustomGlsl ? 'custom GLSL' : 'built-in preset';

    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 4, 2, 2),
      child: Column([
        RichText(
          text: TextSpan(
            style: const Style(foreground: Colors.white),
            children: [
              const TextSpan(text: 'Scoped region shaders let '),
              TextSpan(
                text: 'this word is on fire',
                style: const Style(
                  foreground: Colors.yellow,
                  modifiers: Modifier.bold,
                ),
                shader: shaderRef,
                shaderRegionId: 'burning_phrase',
                shaderPadding: const CellPadding(
                  top: 3,
                  right: 1,
                  bottom: 0,
                  left: 1,
                ),
                shaderStage: ShaderRegionStage.underGlyphs,
                shaderParams: Float32List.fromList([
                  1.25,
                  1.0,
                  1.0,
                  0,
                  0,
                  0,
                  0,
                  0,
                ]),
              ),
              const TextSpan(
                text:
                    ' rise in flames across wrapped lines without affecting neighbors.',
              ),
            ],
          ),
        ),
        const SizedBox(height: 2),
        TweenText(
          _ArtisticDemoController.headline,
          style: const Style(
            foreground: Color(255, 80, 220),
            modifiers: Modifier.bold,
          ),
          perCharacter: true,
          animationId: (ctrl.keyframeEpoch * 64) & 0xFFFF,
          characterTransform: ctrl.transformForChar,
        ),
        const SizedBox(height: 2),
        Text(
          '[Space] Shatter/Explode  [C] Toggle Shader ($modeText)  [R] Reset  [Q] Quit',
          style: const Style(foreground: Color(80, 220, 255)),
        ),
      ], crossAxisAlignment: CrossAxisAlignment.start),
    );
  }
}
