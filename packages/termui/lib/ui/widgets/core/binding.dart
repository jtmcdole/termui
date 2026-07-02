/// Interface for objects that can be globally reassembled during a hot reload.
abstract interface class Reassemblable {
  /// Called during hot reload to invalidate internal state and trigger a rebuild.
  void reassemble();
}

/// A global registry of active termui engines (like SceneManager and PromptRunner)
/// that should respond to hot reloads.
class TermuiBinding {
  static final Set<Reassemblable> _activeTargets = {};

  /// Registers a [Reassemblable] target to receive hot reload events.
  static void register(Reassemblable target) {
    _activeTargets.add(target);
  }

  /// Unregisters a [Reassemblable] target.
  static void unregister(Reassemblable target) {
    _activeTargets.remove(target);
  }

  /// Triggers a hot reload reassemble across all active scene managers and runners.
  static void reassembleAll() {
    // Convert to list to avoid concurrent modification during iteration
    final targets = _activeTargets.toList();
    for (final target in targets) {
      target.reassemble();
    }
  }
}
