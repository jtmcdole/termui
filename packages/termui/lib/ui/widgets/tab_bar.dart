import 'package:characters/characters.dart';
import '../buffer.dart';
import '../layout.dart';
import '../style.dart';
import '../color.dart';
import '../event.dart' hide Modifier;
import '../event.dart' as ev show Modifier;
import '../window.dart';

/// A controller that coordinates the active tab index across TabBar and TabPanel.
class TabController {
  /// The total number of tabs.
  final int length;
  int _index;
  final List<void Function()> _listeners = [];

  /// Creates a [TabController] with the given [length] and [initialIndex].
  TabController({required this.length, int initialIndex = 0})
    : _index = initialIndex.clamp(0, length - 1);

  /// The currently active tab index.
  int get index => _index;

  /// Sets the currently active tab index and notifies listeners.
  set index(int value) {
    final clamped = value.clamp(0, length - 1);
    if (clamped != _index) {
      _index = clamped;
      _notify();
    }
  }

  /// Adds a listener to be notified when the active index changes.
  void addListener(void Function() listener) {
    _listeners.add(listener);
  }

  /// Removes a previously added listener.
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  void _notify() {
    for (final listener in List.from(_listeners)) {
      listener();
    }
  }
}

/// A horizontal tab bar widget to select active views from a tab set.
///
/// ### Keyboard Bindings
/// - `[`: Swaps the active tab index backward (decreases index, wraps around).
/// - `]`: Swaps the active tab index forward (increases index, wraps around).
/// - `Shift + Tab` (or `backtab`): Swaps the active tab index backward.
///
/// ### Lifecycle and Listener Cleanup
/// If a [WindowManager] is provided to bind global keys, this widget adds a
/// listener to intercept tab commands. To prevent memory leaks, you must
/// call [dispose] when this widget is removed from the tree to clean up the key
/// listener registration.
///
/// ### Example Usage
///
/// ```dart
/// final controller = TabController(length: 3);
/// final tabBar = TabBar(
///   controller: controller,
///   labels: const ['General', 'Settings', 'About'],
///   windowManager: myWindowManager,
/// );
///
/// // Clean up later when the view changes:
/// tabBar.dispose();
/// ```
///
/// ### Properties and Settings
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `controller` | [TabController] | Coordinates the active tab index. |
/// | `labels` | [List]<[String]> | Text labels for each tab. |
/// | `windowManager` | [WindowManager]? | Window manager to bind global hotkeys. |
/// | `activeStyle` | [Style] | Style of the selected tab. |
/// | `inactiveStyle` | [Style] | Style of the unselected tabs. |
class TabBar extends Widget {
  /// Coordinates the active tab index.
  final TabController controller;

  /// Text labels for each tab.
  final List<String> labels;

  /// Window manager to bind global hotkeys.
  final WindowManager? windowManager;

  /// Style of the selected tab.
  final Style activeStyle;

  /// Style of the unselected tabs.
  final Style inactiveStyle;

  /// Creates a [TabBar].
  TabBar({
    required this.controller,
    required this.labels,
    this.windowManager,
    this.activeStyle = const Style(
      foreground: CharmColors.charple,
      modifiers: Modifier.bold,
    ),
    this.inactiveStyle = const Style(
      foreground: CharmColors.squid,
      modifiers: Modifier.dim,
    ),
  }) {
    assert(labels.length == controller.length);
    windowManager?.globalKeyListeners.add(_globalKeyListener);
  }

  bool _globalKeyListener(KeyEvent event) {
    if (event.key == ']' ||
        (event.type == KeyType.character && event.key == ']')) {
      controller.index = (controller.index + 1) % controller.length;
      return true;
    } else if (event.key == '[' ||
        (event.type == KeyType.character && event.key == '[')) {
      controller.index =
          (controller.index - 1 + controller.length) % controller.length;
      return true;
    } else if (event.key == 'backtab' ||
        (event.type == KeyType.tab &&
            event.modifiers.contains(ev.Modifier.shift))) {
      controller.index =
          (controller.index - 1 + controller.length) % controller.length;
      return true;
    }
    return false;
  }

  /// Cleans up registered global key listeners from the [windowManager].
  ///
  /// Must be invoked when the tab bar is removed from the active layout context.
  void dispose() {
    windowManager?.globalKeyListeners.remove(_globalKeyListener);
  }

  @override
  void render(Buffer buffer, Rect area) {
    if (area.width <= 0 || area.height <= 0) return;

    var currentX = 0;
    for (var i = 0; i < labels.length; i++) {
      final label = labels[i];
      final isActive = (i == controller.index);
      final style = isActive ? activeStyle : inactiveStyle;
      final text = ' [ $label ] ';
      buffer.writeString(currentX, 0, text, style);
      currentX += text.characters.length;
    }
  }
}

/// A container that renders only the widget of the active tab.
class TabPanel extends Widget {
  /// The controller that dictates which tab is active.
  final TabController controller;

  /// The list of widgets corresponding to each tab.
  final List<Widget> children;

  /// The focus nodes corresponding to each tab.
  final List<FocusNode> tabFocusNodes;

  /// Creates a [TabPanel].
  TabPanel({
    required this.controller,
    required this.children,
    required this.tabFocusNodes,
  }) {
    assert(children.length == controller.length);
    assert(tabFocusNodes.length == controller.length);
    controller.addListener(_handleTabChange);
  }

  void _handleTabChange() {
    final node = tabFocusNodes[controller.index];
    if (node.children.isNotEmpty) {
      node.children.first.requestFocus();
    } else {
      node.requestFocus();
    }
  }

  @override
  void render(Buffer buffer, Rect area) {
    if (area.width <= 0 || area.height <= 0) return;

    final activeWidget = children[controller.index];
    activeWidget.render(buffer, area);
  }
}
