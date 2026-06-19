/// A controller that manages selection state for selection-based widgets.
class SelectionController<T> {
  /// The options available for selection.
  final List<T> options;

  int _selectedIndex;
  int _focusedIndex;
  final List<void Function()> _listeners = [];

  /// Creates a new [SelectionController].
  SelectionController({required this.options, int initialIndex = 0})
    : _selectedIndex = initialIndex,
      _focusedIndex = initialIndex;

  /// The index of the currently selected option.
  int get selectedIndex => _selectedIndex;
  set selectedIndex(int index) {
    if (_selectedIndex != index) {
      _selectedIndex = index;
      _notify();
    }
  }

  /// The index of the option that has keyboard focus.
  int get focusedIndex => _focusedIndex;
  set focusedIndex(int index) {
    if (_focusedIndex != index) {
      _focusedIndex = index;
      _notify();
    }
  }

  /// The currently selected option value.
  T get selected => options[_selectedIndex];
  set selected(T value) {
    final index = options.indexOf(value);
    if (index != -1) {
      selectedIndex = index;
    }
  }

  /// Adds a listener to be notified of selection changes.
  void addListener(void Function() listener) => _listeners.add(listener);

  /// Removes a previously registered listener.
  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _notify() {
    for (final listener in List<void Function()>.from(_listeners)) {
      listener();
    }
  }
}
