import 'package:characters/characters.dart';
import '../buffer.dart';
import '../layout.dart';
import '../style.dart';
import '../color.dart';
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
/// ### Example Usage
///
/// ```dart
/// final controller = TabController(length: 3);
/// final tabBar = TabBar(
///   controller: controller,
///   labels: const ['General', 'Settings', 'About'],
/// );
/// ```
///
/// ### Properties and Settings
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `controller` | [TabController] | Coordinates the active tab index. |
/// | `labels` | [List]<[String]> | Text labels for each tab. |
/// | `activeStyle` | [Style] | Style of the selected tab. |
/// | `inactiveStyle` | [Style] | Style of the unselected tabs. |
class TabBar extends Widget {
  /// Coordinates the active tab index.
  final TabController controller;

  /// Text labels for each tab.
  final List<String> labels;

  /// Style of the selected tab.
  final Style activeStyle;

  /// Style of the unselected tabs.
  final Style inactiveStyle;

  /// Creates a [TabBar].
  TabBar({
    required this.controller,
    required this.labels,
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
  }

  /// Cleans up resources.
  void dispose() {}

  @override
  Element createElement() => TabBarElement(this);
}

/// An element that manages the rendering and layout of a [TabBar] widget.
class TabBarElement extends Element {
  /// Creates a [TabBarElement] for the given [widget].
  TabBarElement(TabBar super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final tabBar = widget as TabBar;
    var w = 0;
    for (var i = 0; i < tabBar.labels.length; i++) {
      final label = tabBar.labels[i];
      final text = ' [ $label ] ';
      w += text.characters.length;
    }
    return constraints.constrain(Size(w, 1));
  }

  @override
  void paint(Buffer buffer, Offset offset) {
    final viewport = Viewport(
      buffer,
      Rect(offset.dx, offset.dy, size.width, size.height),
    );
    final tabBar = widget as TabBar;
    if (size.width <= 0 || size.height <= 0) return;

    var currentX = 0;
    for (var i = 0; i < tabBar.labels.length; i++) {
      final label = tabBar.labels[i];
      final isActive = (i == tabBar.controller.index);
      final style = isActive ? tabBar.activeStyle : tabBar.inactiveStyle;
      final text = ' [ $label ] ';
      if (currentX + text.characters.length > size.width) break;
      viewport.writeString(currentX, 0, text, style);
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
  Element createElement() => TabPanelElement(this);
}

/// An element that manages the active panel rendering and layout of a [TabPanel] widget.
class TabPanelElement extends Element {
  Element? _activeChildElement;
  int _lastActiveIndex = -1;

  /// Creates a [TabPanelElement] for the given [widget].
  TabPanelElement(TabPanel super.widget);

  @override
  void mount(Element? parent) {
    super.mount(parent);
    rebuild();
  }

  @override
  void update(Widget newWidget) {
    super.update(newWidget);
    rebuild();
  }

  @override
  void rebuild() {
    final panel = widget as TabPanel;
    final activeIndex = panel.controller.index;
    final activeWidget = panel.children[activeIndex];

    if (_activeChildElement != null &&
        _lastActiveIndex == activeIndex &&
        _activeChildElement!.widget.runtimeType == activeWidget.runtimeType) {
      _activeChildElement!.update(activeWidget);
    } else {
      _activeChildElement?.unmount();
      _activeChildElement = activeWidget.createElement();
      _activeChildElement!.mount(this);
      _lastActiveIndex = activeIndex;
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (_activeChildElement != null) visitor(_activeChildElement!);
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    rebuild();
    if (_activeChildElement != null) {
      return _activeChildElement!.layout(constraints);
    }
    return constraints.constrain(Size.zero);
  }

  @override
  void paint(Buffer buffer, Offset offset) {
    if (_activeChildElement != null) {
      _activeChildElement!.paint(buffer, offset);
    }
  }
}
