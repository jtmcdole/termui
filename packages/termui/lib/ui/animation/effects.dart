import 'dart:math';
import 'package:termui/termui.dart';

/// A radial expanding ripple effect that radiates from a click coordinate.
class InkwellRippleEffect extends TuiAnimationEffect {
  /// The color of the ripple wave.
  final Color rippleColor;

  /// Creates an [InkwellRippleEffect] with the specified duration, optional easing,
  /// and ripple color.
  InkwellRippleEffect({
    required super.duration,
    super.easing,
    required this.rippleColor,
  });

  @override
  void paint(Buffer buffer, Rect area, Style baseStyle) {
    final trigger = triggerPoint;
    if (trigger == null || !isVisible) return;

    final p = progress;
    final W = area.width;
    final H = area.height;
    if (W <= 0 || H <= 0) return;

    // Compensate for 2:1 character cell aspect ratio when computing boundaries
    final corners = [
      const Point<double>(0, 0),
      Point<double>(W - 1.0, 0),
      Point<double>(0, H - 1.0),
      Point<double>(W - 1.0, H - 1.0),
    ];

    double maxDistance = 1.0;
    for (final corner in corners) {
      final dx = corner.x - trigger.x;
      final dy = (corner.y - trigger.y) * 2.0;
      final dist = sqrt(dx * dx + dy * dy);
      if (dist > maxDistance) {
        maxDistance = dist;
      }
    }

    final waveRadius = p * maxDistance;

    for (var y = 0; y < H; y++) {
      for (var x = 0; x < W; x++) {
        final dx = x - trigger.x;
        final dy = (y - trigger.y) * 2.0; // Aspect ratio adjustment
        final d = sqrt(dx * dx + dy * dy);

        if (d <= waveRadius) {
          final radialFactor = (1.0 - (d / (maxDistance * 1.2))).clamp(
            0.0,
            1.0,
          );
          final fadeFactor = radialFactor * (1.0 - p) + p;

          final bgArgb = buffer.getBackground(x, y);
          final originalBg = bgArgb == 0
              ? (baseStyle.background ?? Colors.black)
              : Color.argb(bgArgb);

          final blendedBg = interpolateColor(
            originalBg,
            rippleColor,
            fadeFactor,
          );
          buffer.setAttributes(x, y, bg: blendedBg.argb);
        }
      }
    }
  }
}

/// A particle-based sparkle effect that flashes bright icons inside the widget bounds.
class SparkleEffect extends TuiAnimationEffect {
  /// The number of particle generation attempts per frame.
  final int density;

  /// The list of colors to pick particle styles from.
  final List<Color> colors;

  /// The list of characters used to represent sparkles.
  final List<String> sparkleChars;

  final List<_SparkleParticle> _particles = [];
  final _random = Random();

  /// Creates a [SparkleEffect] with config for duration, easing, particle density,
  /// colors, and characters.
  SparkleEffect({
    required super.duration,
    super.easing,
    this.density = 2,
    this.colors = const [Colors.yellow, Colors.white, CharmColors.lichen],
    this.sparkleChars = const ['✦', '✧', '*', '+', '.'],
  });

  @override
  void start(Point<int> clickPoint, VoidCallback onUpdate) {
    super.start(clickPoint, onUpdate);
    _particles.clear();
  }

  @override
  void paint(Buffer buffer, Rect area, Style baseStyle) {
    if (!isVisible) return;

    final W = area.width;
    final H = area.height;
    if (W <= 0 || H <= 0) return;

    // Spawn new particles based on density config
    for (var i = 0; i < density; i++) {
      if (_random.nextDouble() < 0.3) {
        _particles.add(
          _SparkleParticle(
            x: _random.nextInt(W),
            y: _random.nextInt(H),
            char: sparkleChars[_random.nextInt(sparkleChars.length)],
            color: colors[_random.nextInt(colors.length)],
            life: 1.0,
            decay: 0.04 + _random.nextDouble() * 0.08,
          ),
        );
      }
    }

    for (final p in _particles) {
      p.life -= p.decay;
    }

    for (final p in _particles) {
      if (p.life > 0.0) {
        // Dim the character color as life decays
        final dimmedColor = interpolateColor(Colors.black, p.color, p.life);

        final currentModifiers = buffer.getModifiers(p.x, p.y);
        buffer.setAttributes(
          p.x,
          p.y,
          char: p.char,
          fg: dimmedColor.argb,
          modifiers: currentModifiers | Modifier.bold,
        );
      }
    }

    final remainingParticles = [
      for (final p in _particles)
        if (p.life > 0.0) p,
    ];

    _particles.clear();
    _particles.addAll(remainingParticles);
  }
}

class _SparkleParticle {
  final int x;
  final int y;
  final String char;
  final Color color;
  double life;
  final double decay;

  _SparkleParticle({
    required this.x,
    required this.y,
    required this.char,
    required this.color,
    required this.life,
    required this.decay,
  });
}

/// A full-widget background flash pulsation.
class FlashEffect extends TuiAnimationEffect {
  /// The color to flash the background cells with.
  final Color flashColor;

  /// The number of complete sine oscillations (pulses) within the duration.
  final int pulses;

  /// Creates a [FlashEffect] with the specified duration, optional easing,
  /// flash color, and pulse count.
  FlashEffect({
    required super.duration,
    super.easing,
    required this.flashColor,
    this.pulses = 1,
  });

  @override
  void paint(Buffer buffer, Rect area, Style baseStyle) {
    if (!isVisible) return;

    final p = progress;
    // Oscillate brightness intensity using a sine wave
    final intensity = (sin(p * pi * pulses * 2 - pi / 2) + 1.0) / 2.0;

    final W = area.width;
    final H = area.height;

    for (var y = 0; y < H; y++) {
      for (var x = 0; x < W; x++) {
        final bgArgb = buffer.getBackground(x, y);
        final originalBg = bgArgb == 0
            ? (baseStyle.background ?? Colors.black)
            : Color.argb(bgArgb);

        // Cap blending factor at 60% to maintain baseline legibility of text content
        final blendedBg = interpolateColor(
          originalBg,
          flashColor,
          intensity * 0.6,
        );

        buffer.setAttributes(x, y, bg: blendedBg.argb);
      }
    }
  }
}
