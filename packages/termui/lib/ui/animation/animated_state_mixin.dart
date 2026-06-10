import 'dart:async';
import 'dart:math';
import '../buffer.dart';
import '../style.dart';
import '../layout.dart';
import 'animation_effect.dart';

/// Mixin for [State] objects that allows registration and execution of TUI animations.
mixin TuiAnimatedStateMixin<T extends StatefulWidget> on State<T> {
  final List<TuiAnimationEffect> _activeEffects = [];
  Timer? _ticker;

  /// Returns whether the periodic vsync ticker is currently running.
  bool get isTickerActive => _ticker != null;

  /// Registers an animation effect to be updated and rendered by this state.
  void registerEffect(TuiAnimationEffect effect) {
    if (!_activeEffects.contains(effect)) {
      _activeEffects.add(effect);
    }
  }

  /// Deregisters an animation effect.
  void deregisterEffect(TuiAnimationEffect effect) {
    _activeEffects.remove(effect);
    if (_activeEffects.isEmpty) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  /// Triggers an effect at a specific local coordinate.
  void triggerEffect(TuiAnimationEffect effect, Point<int> clickPoint) {
    registerEffect(effect);
    effect.start(clickPoint, () {
      setState(() {});
    });
    _ensureTickerRunning();
  }

  /// The vsync interval used by the widget fallback.
  /// Resolves dynamically to [TuiAnimationConfig.vsyncInterval] to support user-tuned frame rates.
  Duration get vsyncInterval => TuiAnimationConfig.vsyncInterval;

  void _ensureTickerRunning() {
    if (_ticker != null) return;
    _ticker = Timer.periodic(vsyncInterval, (timer) {
      var running = false;

      // Update all active animations
      for (final effect in _activeEffects) {
        if (effect.isAnimating) {
          final stillTicking = effect.tick();
          if (stillTicking) {
            running = true;
          }
        }
      }

      if (!running) {
        _ticker?.cancel();
        _ticker = null;
      }
    });
  }

  /// Iterates and applies all active registered animation layers onto the [buffer].
  void paintEffects(Buffer buffer, Rect area, Style baseStyle) {
    for (final effect in _activeEffects) {
      if (effect.isVisible) {
        effect.paint(buffer, area, baseStyle);
      }
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    for (final effect in _activeEffects) {
      effect.reset();
    }
    super.dispose();
  }
}
