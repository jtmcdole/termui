import 'dart:math';

/// A controller for discrete cell-based scroll positions in TUI layouts.
class DiscreteScrollController {
  int _scrollOffset = 0;
  int _totalExtent = 0;
  int _viewportExtent = 0;

  final List<void Function()> _listeners = [];

  /// Creates a [DiscreteScrollController] with an optional [initialScrollOffset].
  DiscreteScrollController({int initialScrollOffset = 0})
    : _scrollOffset = initialScrollOffset;

  /// The current scroll offset in terminal lines/cells.
  int get scrollOffset => _scrollOffset;

  set scrollOffset(int value) {
    final maxOffset = max(0, _totalExtent - _viewportExtent);
    final clamped = value.clamp(0, maxOffset);
    if (_scrollOffset != clamped) {
      _scrollOffset = clamped;
      notifyListeners();
    }
  }

  /// The total content length in cells/lines.
  int get totalExtent => _totalExtent;
  set totalExtent(int value) {
    if (_totalExtent != value) {
      _totalExtent = value;
      scrollOffset = _scrollOffset; // trigger clamping
      notifyListeners();
    }
  }

  /// The visible window length in cells/lines.
  int get viewportExtent => _viewportExtent;
  set viewportExtent(int value) {
    if (_viewportExtent != value) {
      _viewportExtent = value;
      scrollOffset = _scrollOffset; // trigger clamping
      notifyListeners();
    }
  }

  /// The maximum valid scroll offset.
  int get maxScrollExtent => max(0, _totalExtent - _viewportExtent);

  /// Instantly jump to the specified [offset].
  void jumpTo(int offset) {
    scrollOffset = offset;
  }

  /// Add a listener to be notified when the scroll state changes.
  void addListener(void Function() listener) {
    _listeners.add(listener);
  }

  /// Remove a registered listener.
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  /// Notify all registered listeners.
  void notifyListeners() {
    for (final listener in List.from(_listeners)) {
      listener();
    }
  }

  /// Clears all listeners.
  void dispose() {
    _listeners.clear();
  }
}
