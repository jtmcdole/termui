import 'dart:math' as math;

/// Signature for easing functions that transform linear progress `t` in `[0, 1]`
/// into eased progress.
typedef EasingFunction = double Function(double t);

/// A collection of standard easing functions matching easings.net.
class Easing {
  /// Linear easing (no acceleration or deceleration).
  static double linear(double t) => t;

  // --- SINE ---
  /// Sine easing in.
  static double easeInSine(double t) => 1.0 - math.cos((t * math.pi) / 2.0);

  /// Sine easing out.
  static double easeOutSine(double t) => math.sin((t * math.pi) / 2.0);

  /// Sine easing in/out.
  static double easeInOutSine(double t) => -(math.cos(math.pi * t) - 1.0) / 2.0;

  // --- QUADRATIC ---
  /// Quadratic easing in.
  static double easeInQuad(double t) => t * t;

  /// Quadratic easing out.
  static double easeOutQuad(double t) => 1.0 - (1.0 - t) * (1.0 - t);

  /// Quadratic easing in/out.
  static double easeInOutQuad(double t) =>
      t < 0.5 ? 2.0 * t * t : 1.0 - math.pow(-2.0 * t + 2.0, 2) / 2.0;

  // --- CUBIC ---
  /// Cubic easing in.
  static double easeInCubic(double t) => t * t * t;

  /// Cubic easing out.
  static double easeOutCubic(double t) => 1.0 - math.pow(1.0 - t, 3);

  /// Cubic easing in/out.
  static double easeInOutCubic(double t) =>
      t < 0.5 ? 4.0 * t * t * t : 1.0 - math.pow(-2.0 * t + 2.0, 3) / 2.0;

  // --- QUARTIC ---
  /// Quartic easing in.
  static double easeInQuart(double t) => t * t * t * t;

  /// Quartic easing out.
  static double easeOutQuart(double t) => 1.0 - math.pow(1.0 - t, 4);

  /// Quartic easing in/out.
  static double easeInOutQuart(double t) =>
      t < 0.5 ? 8.0 * t * t * t * t : 1.0 - math.pow(-2.0 * t + 2.0, 4) / 2.0;

  // --- QUINTIC ---
  /// Quintic easing in.
  static double easeInQuint(double t) => t * t * t * t * t;

  /// Quintic easing out.
  static double easeOutQuint(double t) => 1.0 - math.pow(1.0 - t, 5);

  /// Quintic easing in/out.
  static double easeInOutQuint(double t) => t < 0.5
      ? 16.0 * t * t * t * t * t
      : 1.0 - math.pow(-2.0 * t + 2.0, 5) / 2.0;

  // --- EXPONENTIAL ---
  /// Exponential easing in.
  static double easeInExpo(double t) =>
      t == 0.0 ? 0.0 : math.pow(2.0, 10.0 * t - 10.0) as double;

  /// Exponential easing out.
  static double easeOutExpo(double t) =>
      t == 1.0 ? 1.0 : 1.0 - math.pow(2.0, -10.0 * t);

  /// Exponential easing in/out.
  static double easeInOutExpo(double t) {
    if (t == 0.0) return 0.0;
    if (t == 1.0) return 1.0;
    return t < 0.5
        ? (math.pow(2.0, 20.0 * t - 10.0) as double) / 2.0
        : (2.0 - math.pow(2.0, -20.0 * t + 10.0)) / 2.0;
  }

  // --- CIRCULAR ---
  /// Circular easing in.
  static double easeInCirc(double t) => 1.0 - math.sqrt(1.0 - math.pow(t, 2));

  /// Circular easing out.
  static double easeOutCirc(double t) => math.sqrt(1.0 - math.pow(t - 1.0, 2));

  /// Circular easing in/out.
  static double easeInOutCirc(double t) => t < 0.5
      ? (1.0 - math.sqrt(1.0 - math.pow(2.0 * t, 2))) / 2.0
      : (math.sqrt(1.0 - math.pow(-2.0 * t + 2.0, 2)) + 1.0) / 2.0;

  // --- BACK ---
  /// Back easing in.
  static double easeInBack(double t) {
    const c1 = 1.70158;
    const c3 = c1 + 1.0;
    return c3 * t * t * t - c1 * t * t;
  }

  /// Back easing out.
  static double easeOutBack(double t) {
    const c1 = 1.70158;
    const c3 = c1 + 1.0;
    return 1.0 + c3 * math.pow(t - 1.0, 3) + c1 * math.pow(t - 1.0, 2);
  }

  /// Back easing in/out.
  static double easeInOutBack(double t) {
    const c1 = 1.70158;
    const c2 = c1 * 1.525;
    return t < 0.5
        ? (math.pow(2.0 * t, 2) * ((c2 + 1.0) * 2.0 * t - c2)) / 2.0
        : (math.pow(2.0 * t - 2.0, 2) * ((c2 + 1.0) * (t * 2.0 - 2.0) + c2) +
                  2.0) /
              2.0;
  }

  // --- ELASTIC ---
  /// Elastic easing in.
  static double easeInElastic(double t) {
    if (t == 0.0) return 0.0;
    if (t == 1.0) return 1.0;
    const c4 = (2.0 * math.pi) / 3.0;
    return -math.pow(2.0, 10.0 * t - 10.0) * math.sin((t * 10.0 - 10.75) * c4);
  }

  /// Elastic easing out.
  static double easeOutElastic(double t) {
    if (t == 0.0) return 0.0;
    if (t == 1.0) return 1.0;
    const c4 = (2.0 * math.pi) / 3.0;
    return math.pow(2.0, -10.0 * t) * math.sin((t * 10.0 - 0.75) * c4) + 1.0;
  }

  /// Elastic easing in/out.
  static double easeInOutElastic(double t) {
    if (t == 0.0) return 0.0;
    if (t == 1.0) return 1.0;
    const c5 = (2.0 * math.pi) / 4.5;
    return t < 0.5
        ? -(math.pow(2.0, 20.0 * t - 10.0) *
                  math.sin((20.0 * t - 11.125) * c5)) /
              2.0
        : (math.pow(2.0, -20.0 * t + 10.0) *
                      math.sin((20.0 * t - 11.125) * c5)) /
                  2.0 +
              1.0;
  }

  // --- BOUNCE ---
  /// Bounce easing out.
  static double easeOutBounce(double t) {
    const n1 = 7.5625;
    const d1 = 2.75;

    if (t < 1.0 / d1) {
      return n1 * t * t;
    } else if (t < 2.0 / d1) {
      final t2 = t - 1.5 / d1;
      return n1 * t2 * t2 + 0.75;
    } else if (t < 2.5 / d1) {
      final t2 = t - 2.25 / d1;
      return n1 * t2 * t2 + 0.9375;
    } else {
      final t2 = t - 2.625 / d1;
      return n1 * t2 * t2 + 0.984375;
    }
  }

  /// Bounce easing in.
  static double easeInBounce(double t) => 1.0 - easeOutBounce(1.0 - t);

  /// Bounce easing in/out.
  static double easeInOutBounce(double t) {
    return t < 0.5
        ? (1.0 - easeOutBounce(1.0 - 2.0 * t)) / 2.0
        : (1.0 + easeOutBounce(2.0 * t - 1.0)) / 2.0;
  }
}
