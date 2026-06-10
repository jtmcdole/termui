import 'dart:math';
import '../buffer.dart';
import '../style.dart';
import '../layout.dart';
import '../color.dart';
import '../easing.dart';

/// The status of an animation transition.
enum AnimationStatus {
  /// The animation is stopped at the beginning (progress 0.0) and not visible.
  dismissed,

  /// The animation is running from beginning to end.
  forward,

  /// The animation is running from end to beginning.
  reverse,

  /// The animation is stopped at the end (progress 1.0) but remains visible.
  completed,
}

/// Global configuration for the TUI animation framework.
class TuiAnimationConfig {
  /// The global refresh rate fallback (vsync equivalent).
  /// Defaults to 60Hz (16.6ms intervals) in standard console environments.
  /// Can be tuned dynamically at runtime by the user/developer (e.g. 8ms for 120Hz).
  static Duration vsyncInterval = const Duration(milliseconds: 16);
}

/// Base abstract class for all terminal user interface (TUI) animation effects.
abstract class TuiAnimationEffect {
  /// Total duration of the animation lifecycle.
  final Duration duration;

  /// Easing curve applied to progress over time.
  final EasingFunction easing;

  /// The target frame interval (e.g. Duration(milliseconds: 33) for 30 FPS).
  /// If set, the effect will throttle its repaint triggers to this interval.
  /// Defaults to Duration.zero (render on every tick/vsync).
  final Duration targetFrameInterval;

  /// The local coordinate where the animation was triggered.
  Point<int>? triggerPoint;

  /// The callback to trigger widget repaints.
  VoidCallback? onUpdate;

  /// The current status of the animation.
  AnimationStatus status = AnimationStatus.dismissed;

  Stopwatch? _stopwatch;
  int _lastFrameTimeMs = 0;
  int _transitionStartTimeMs = 0;
  double _startProgress = 0.0;

  /// Creates a [TuiAnimationEffect] with the required [duration], [easing],
  /// and optional [targetFrameInterval].
  TuiAnimationEffect({
    required this.duration,
    this.easing = Easing.linear,
    this.targetFrameInterval = Duration.zero,
  });

  /// The raw (uneased) progress of the animation, bounded strictly between `0.0` and `1.0`.
  double get rawProgress {
    if (status == AnimationStatus.dismissed) return 0.0;
    if (status == AnimationStatus.completed) return 1.0;

    final stopwatch = _stopwatch;
    if (stopwatch == null) return _startProgress;

    final elapsed = stopwatch.elapsedMilliseconds - _transitionStartTimeMs;
    if (status == AnimationStatus.forward) {
      if (duration.inMilliseconds <= 0) return 1.0;
      return (_startProgress + (elapsed / duration.inMilliseconds)).clamp(
        0.0,
        1.0,
      );
    } else if (status == AnimationStatus.reverse) {
      if (duration.inMilliseconds <= 0) return 0.0;
      return (_startProgress - (elapsed / duration.inMilliseconds)).clamp(
        0.0,
        1.0,
      );
    }

    return _startProgress;
  }

  /// The eased progress of the animation, bounded strictly between `0.0` and `1.0`.
  double get progress => easing(rawProgress);

  /// Sets the raw (uneased) progress of the animation, clamped between `0.0` and `1.0`.
  set progress(double val) {
    final clamped = val.clamp(0.0, 1.0);
    _startProgress = clamped;
    if (_stopwatch != null) {
      _transitionStartTimeMs = _stopwatch!.elapsedMilliseconds;
    } else {
      _transitionStartTimeMs = 0;
    }
  }

  /// Whether the animation is currently running/animating (status is forward or reverse).
  bool get isAnimating =>
      status == AnimationStatus.forward || status == AnimationStatus.reverse;

  /// Whether the animation is currently active (for backward compatibility).
  bool get isActive => isAnimating;

  /// Whether the animation is visible (status is not dismissed).
  bool get isVisible => status != AnimationStatus.dismissed;

  /// Starts the animation forward from the beginning.
  void start(Point<int> clickPoint, VoidCallback onUpdate) {
    reset();
    triggerPoint = clickPoint;
    this.onUpdate = onUpdate;
    forward();
  }

  /// Starts running this animation forward.
  void forward() {
    final currentRaw = rawProgress;
    status = AnimationStatus.forward;
    if (_stopwatch == null) {
      _stopwatch = Stopwatch()..start();
      _transitionStartTimeMs = 0;
      _lastFrameTimeMs = 0;
    } else {
      _stopwatch!.start();
      _transitionStartTimeMs = _stopwatch!.elapsedMilliseconds;
    }
    _startProgress = currentRaw;
  }

  /// Starts running this animation in reverse.
  void reverse() {
    final currentRaw = rawProgress;
    status = AnimationStatus.reverse;
    if (_stopwatch == null) {
      _stopwatch = Stopwatch()..start();
      _transitionStartTimeMs = 0;
      _lastFrameTimeMs = 0;
    } else {
      _stopwatch!.start();
      _transitionStartTimeMs = _stopwatch!.elapsedMilliseconds;
    }
    _startProgress = currentRaw;
  }

  /// Stops the animation and freezes it at the current progress.
  void stop() {
    _startProgress = rawProgress;
    _stopwatch?.stop();
    if (status == AnimationStatus.forward ||
        status == AnimationStatus.reverse) {
      status = AnimationStatus.completed;
    }
  }

  /// Resets the animation to its default dormant/dismissed state.
  void reset() {
    status = AnimationStatus.dismissed;
    _startProgress = 0.0;
    _transitionStartTimeMs = 0;
    _stopwatch?.stop();
    _stopwatch = null;
    triggerPoint = null;
    onUpdate = null;
    _lastFrameTimeMs = 0;
  }

  /// Advances the animation tick frame. Returns true if ticking should continue.
  bool tick() {
    if (!isAnimating) return false;

    final stopwatch = _stopwatch;
    if (stopwatch == null) return false;

    final currentRaw = rawProgress;
    final elapsed = stopwatch.elapsedMilliseconds;

    if (status == AnimationStatus.forward && currentRaw >= 1.0) {
      status = AnimationStatus.completed;
      stopwatch.stop();
      onUpdate?.call();
      return false;
    } else if (status == AnimationStatus.reverse && currentRaw <= 0.0) {
      status = AnimationStatus.dismissed;
      stopwatch.stop();
      _stopwatch = null;
      onUpdate?.call();
      return false;
    }

    final elapsedSinceLastFrame = elapsed - _lastFrameTimeMs;
    if (elapsedSinceLastFrame >= targetFrameInterval.inMilliseconds) {
      _lastFrameTimeMs = elapsed;
      onUpdate?.call();
    }

    return true;
  }

  /// Performs direct rendering modifications to the relative [buffer].
  void paint(Buffer buffer, Rect area, Style baseStyle);

  /// Helper utility to interpolate between two discrete [Color] properties.
  Color interpolateColor(Color c1, Color c2, double t) {
    t = t.clamp(0.0, 1.0);
    final r = (c1.r + (c2.r - c1.r) * t).round();
    final g = (c1.g + (c2.g - c1.g) * t).round();
    final b = (c1.b + (c2.b - c1.b) * t).round();
    return Color(r, g, b);
  }
}
