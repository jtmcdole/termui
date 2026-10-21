import 'dart:async';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:termui/termui.dart';

/// Represents a single sub-pixel touch/drop ripple animation state.
class SubpixelRipple {
  /// Center coordinate of the ripple on the terminal grid.
  final Point<int> center;

  /// Epoch millisecond timestamp when the ripple started.
  final int startTime;

  /// Duration of the ripple animation in milliseconds.
  final int durationMs;

  /// The primary color of the ripple.
  final Color color;

  /// Creates a [SubpixelRipple] configuration.
  const SubpixelRipple({
    required this.center,
    required this.startTime,
    required this.color,
    this.durationMs = 500,
  });
}

/// A pure ViewModel/state manager that coordinates multiple expanding sub-pixel Braille touch ripples.
///
/// This class handles addition, lifecycle management, and pruning of active ripples.
/// For rendering in a declarative UI tree, use [SubpixelRippleWidget] with this manager.
class SubpixelRippleManager {
  final List<SubpixelRipple> _ripples = [];
  final List<void Function()> _listeners = [];

  /// Registers a callback to be notified when ripples are added.
  void addListener(void Function() listener) {
    _listeners.add(listener);
  }

  /// Removes a previously registered listener.
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  /// Notifies all registered listeners.
  void notifyListeners() {
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  /// Exposes the list of active ripples.
  List<SubpixelRipple> get ripples => _ripples;

  /// Spawns a new ripple centered at [position].
  void addRipple(
    Point<int> position, {
    Color color = Colors.white,
    int durationMs = 500,
    int? startTime,
  }) {
    _ripples.add(
      SubpixelRipple(
        center: position,
        startTime: startTime ?? clock.now().millisecondsSinceEpoch,
        color: color,
        durationMs: durationMs,
      ),
    );
    notifyListeners();
  }

  /// Prunes completed ripples.
  ///
  /// Optionally accepts [now] to reuse a single timestamp across multiple calls.
  void updateRipples([int? now]) {
    final current = now ?? clock.now().millisecondsSinceEpoch;
    _ripples.removeWhere((r) => current - r.startTime > r.durationMs);
  }

  /// Returns true if there are active ripples undergoing animation.
  bool get hasActiveRipples => _ripples.isNotEmpty;

  /// Composites the expanding sub-pixel circles onto the given target [buffer].
  ///
  /// **NOTE**: Doing rendering directly within a manager violates MVVM boundaries.
  /// For production declarative layouts, place a [SubpixelRippleWidget] in your widget tree.
  void paint(Buffer buffer) {
    final now = clock.now().millisecondsSinceEpoch;
    updateRipples(now);
    if (_ripples.isEmpty) return;

    final canvas = Canvas(buffer.width, buffer.height, onlyDrawOnSpaces: false);
    var hasPainted = false;

    for (final ripple in _ripples) {
      final elapsed = now - ripple.startTime;
      if (elapsed < 0) continue;

      final progress = (elapsed / ripple.durationMs).clamp(0.0, 1.0);
      final radius = (progress * 16).round();

      if (radius > 0) {
        final Color(:r, :g, :b) = ripple.color;
        final fade = (255 * (1.0 - progress)).round().clamp(0, 255);
        final style = Style(
          foreground: Color(
            (r * fade) ~/ 255,
            (g * fade) ~/ 255,
            (b * fade) ~/ 255,
          ),
        );

        // Map 1-based grid coordinates to 2x4 sub-pixel coordinate space
        canvas.drawCircle(
          (ripple.center.x - 1) * 2 + 1,
          (ripple.center.y - 1) * 4 + 2,
          radius,
          cellStyle: style,
        );
        hasPainted = true;
      }
    }

    if (hasPainted) {
      final el = canvas.createElement();
      el.layout(BoxConstraints.tight(Size(buffer.width, buffer.height)));
      el.paint(buffer, Offset.zero);
      el.unmount();
    }
  }
}

/// A declarative Widget that embeds and renders ripples managed by a [SubpixelRippleManager].
///
/// This separates the View/Rendering concerns from the ViewModel state.
class SubpixelRippleWidget extends Widget {
  /// The manager containing the ripple state.
  final SubpixelRippleManager manager;

  /// Creates a [SubpixelRippleWidget].
  const SubpixelRippleWidget({required this.manager, super.key});

  @override
  Element createElement() => SubpixelRippleWidgetElement(this);
}

/// The backing Element for [SubpixelRippleWidget] that handles layout and paint caching.
class SubpixelRippleWidgetElement extends Element {
  Timer? _ticker;
  SubpixelRippleManager? _subscribedManager;

  /// Creates a [SubpixelRippleWidgetElement].
  SubpixelRippleWidgetElement(SubpixelRippleWidget super.widget);

  void _onManagerChanged() {
    if (!mounted) return;
    _ensureTicker();
    markNeedsBuild();
  }

  void _ensureTicker() {
    final manager = (widget as SubpixelRippleWidget).manager;
    if (manager.hasActiveRipples) {
      _ticker ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
        if (!mounted) {
          _stopTicker();
          return;
        }
        manager.updateRipples();
        markNeedsBuild();
        if (!manager.hasActiveRipples) {
          _stopTicker();
        }
      });
    } else {
      _stopTicker();
    }
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  @override
  void mount(Element? parent) {
    super.mount(parent);
    _subscribedManager = (widget as SubpixelRippleWidget).manager;
    _subscribedManager?.addListener(_onManagerChanged);
    _ensureTicker();
  }

  @override
  void update(Widget newWidget) {
    final oldManager = _subscribedManager;
    final newManager = (newWidget as SubpixelRippleWidget).manager;
    super.update(newWidget);
    if (oldManager != newManager) {
      oldManager?.removeListener(_onManagerChanged);
      _subscribedManager = newManager;
      _subscribedManager?.addListener(_onManagerChanged);
    }
    _ensureTicker();
  }

  @override
  void unmount() {
    _stopTicker();
    _subscribedManager?.removeListener(_onManagerChanged);
    _subscribedManager = null;
    super.unmount();
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    final w = constraints.hasBoundedWidth ? constraints.maxWidth : 0;
    final h = constraints.hasBoundedHeight ? constraints.maxHeight : 0;
    return constraints.constrain(Size(w, h));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    final widget = this.widget as SubpixelRippleWidget;
    final manager = widget.manager;

    final now = clock.now().millisecondsSinceEpoch;
    manager.updateRipples(now);
    if (!manager.hasActiveRipples) return;

    final canvas = Canvas(w, h, onlyDrawOnSpaces: true);
    var hasPainted = false;

    for (final ripple in manager.ripples) {
      final elapsed = now - ripple.startTime;
      if (elapsed < 0) continue;

      final progress = (elapsed / ripple.durationMs).clamp(0.0, 1.0);
      final radius = (progress * 16).round();

      if (radius > 0) {
        final Color(:r, :g, :b) = ripple.color;
        final fade = (255 * (1.0 - progress)).round().clamp(0, 255);
        final style = Style(
          foreground: Color(
            (r * fade) ~/ 255,
            (g * fade) ~/ 255,
            (b * fade) ~/ 255,
          ),
        );

        canvas.drawCircle(
          (ripple.center.x - 1) * 2 + 1,
          (ripple.center.y - 1) * 4 + 2,
          radius,
          cellStyle: style,
        );
        hasPainted = true;
      }
    }

    if (hasPainted) {
      final canvasEl = canvas.createElement();
      canvasEl.layout(BoxConstraints.tight(Size(w, h)));
      canvasEl.paint(buffer, offset);
      canvasEl.unmount();
    }
  }
}
