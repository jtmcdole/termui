import 'dart:math';
import '../buffer.dart';
import '../layout.dart';
import '../style.dart';
import '../event.dart' hide Modifier;
import 'text.dart';

/// A function that builds a widget given a build context.
typedef WidgetBuilder = Widget Function(BuildContext context);

/// Helper function to traverse the parent chain of a [Buffer] to find its absolute [Rect] boundaries.
Rect getAbsoluteRect(Buffer buffer, Rect localRect) {
  int x = localRect.x;
  int y = localRect.y;
  Buffer current = buffer;
  while (current is Viewport) {
    x += current.bounds.x;
    y += current.bounds.y;
    current = current.parent;
  }
  return Rect(x, y, localRect.width, localRect.height);
}

/// An entry representing a widget that can be inserted into an [Overlay].
///
/// Use [OverlayEntry] to dynamically display floating overlays, tooltips, or
/// menus. An entry is created with a builder function and can be removed
/// by calling [remove].
///
/// ### Example Usage
///
/// ```dart
/// final entry = OverlayEntry(
///   builder: (context) => Positioned(
///     left: 5, top: 2,
///     child: Text('Floating Alert'),
///   ),
/// );
/// Overlay.of(context)?.insert(entry);
///
/// // Later:
/// entry.remove();
/// ```
class OverlayEntry {
  /// The builder function that creates the widget for this entry.
  final WidgetBuilder builder;
  OverlayState? _overlayState;

  /// Creates an overlay entry with the specified [builder].
  OverlayEntry({required this.builder});

  /// Removes this entry from the overlay it was inserted into.
  void remove() {
    _overlayState?.remove(this);
    _overlayState = null;
  }
}

/// A stack-based layout system that manages overlapping floating widgets.
///
/// Each [OverlayEntry] added to the overlay state is rendered on top of the
/// main child widget tree. Widgets retrieve the closest enclosing [OverlayState]
/// from a given [BuildContext] using [Overlay.of].
///
/// ### Example Usage
///
/// ```dart
/// Overlay(
///   initialEntries: [myFloatingEntry],
///   child: MyMainAppWidget(),
/// );
/// ```
class Overlay extends StatefulWidget {
  /// The primary widget displayed below all overlay entries.
  final Widget child;

  /// The list of entries to display initially.
  final List<OverlayEntry> initialEntries;

  /// Creates a new overlay layout.
  const Overlay({required this.child, this.initialEntries = const []});

  @override
  OverlayState createState() => OverlayState();

  /// Retrieves the closest enclosing [OverlayState] from the given [context].
  static OverlayState? of(BuildContext context) {
    Element? current = context as Element?;
    while (current != null) {
      if (current is StatefulElement && current.state is OverlayState) {
        return current.state as OverlayState;
      }
      current = current.parent;
    }
    return null;
  }
}

/// The state for an [Overlay], managing its active entries.
class OverlayState extends State<Overlay> {
  final List<OverlayEntry> _entries = [];

  @override
  void initState() {
    super.initState();
    for (final entry in widget.initialEntries) {
      insert(entry);
    }
  }

  /// Inserts a new [entry] into the overlay.
  void insert(OverlayEntry entry) {
    entry._overlayState = this;
    setState(() {
      _entries.add(entry);
    });
  }

  /// Removes an existing [entry] from the overlay.
  void remove(OverlayEntry entry) {
    setState(() {
      _entries.remove(entry);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack([
      Positioned(left: 0, top: 0, right: 0, bottom: 0, child: widget.child),
      for (final entry in _entries) entry.builder(context),
    ]);
  }
}

/// An item in a [DropdownButton] menu.
class DropdownMenuItem<T> {
  /// The value associated with this item.
  final T value;

  /// The widget displayed for this item.
  final Widget child;

  /// Creates a new dropdown menu item with the given [value] and [child].
  const DropdownMenuItem({required this.value, required this.child});
}

/// An interactive select menu button that opens a dropdown list overlay.
///
/// ### Interaction Modes
/// - **Keyboard**: When focused, opens using Space, Enter, or Down Arrow.
///   Once open, navigate choices using Up/Down arrow keys, select using
///   Enter or Space, and close/cancel using Escape.
/// - **Mouse**: Left-clicking opens the menu; clicking an item selects it.
///
/// ### Absolute Portal Mapping
/// The dropdown uses [getAbsoluteRect] to resolve its button boundaries within
/// nested viewports, ensuring the floating overlay list maps to absolute
/// screen coordinates directly beneath the button, bypassing child clipping.
///
/// ### Example Usage
///
/// ```dart
/// DropdownButton<String>(
///   value: selectedFruit,
///   items: const [
///     DropdownMenuItem(value: 'apple', child: Text('Apple')),
///     DropdownMenuItem(value: 'banana', child: Text('Banana')),
///   ],
///   onChanged: (val) {
///     setState(() => selectedFruit = val);
///   },
/// );
/// ```
///
/// ### Properties Table
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `items` | [List]<[DropdownMenuItem]>| List of options available in the dropdown. |
/// | `value` | `T`? | The currently selected value. |
/// | `onChanged` | `Function(T?)` | Callback fired when a selection is made. |
/// | `focused` | [bool] | Whether this button has keyboard focus. |
/// | `dropdownStyle`| [Style] | Style applied to items in the dropdown menu. |
class DropdownButton<T> extends StatefulWidget {
  /// The list of items to display in the dropdown.
  final List<DropdownMenuItem<T>> items;

  /// The currently selected value.
  final T? value;

  /// Callback triggered when a new value is selected.
  final void Function(T? newValue)? onChanged;

  /// An optional widget to display when no item is selected.
  final Widget? hint;

  /// The base style for the dropdown button.
  final Style style;

  /// The style applied to the dropdown menu items.
  final Style dropdownStyle;

  /// Whether the button is currently focused.
  final bool focused;

  /// Creates a new dropdown button.
  const DropdownButton({
    required this.items,
    this.value,
    this.onChanged,
    this.hint,
    this.style = Style.empty,
    this.dropdownStyle = const Style(modifiers: Modifier.reverse),
    this.focused = false,
  });

  @override
  State<DropdownButton<T>> createState() => DropdownButtonState<T>();
}

/// State for a [DropdownButton].
class DropdownButtonState<T> extends State<DropdownButton<T>> {
  /// Whether the dropdown menu is currently open.
  bool isOpen = false;

  /// The overlay entry representing the open menu.
  OverlayEntry? overlayEntry;

  /// The index of the currently selected or highlighted item.
  int selectedIndex = 0;

  /// The on-screen bounds of the dropdown button.
  Rect buttonBounds = const Rect(0, 0, 0, 0);

  /// Synchronizes the [selectedIndex] with the current [DropdownButton.value].
  void updateSelectedIndex() {
    final idx = widget.items.indexWhere((item) => item.value == widget.value);
    if (idx != -1) {
      selectedIndex = idx;
    } else {
      selectedIndex = 0;
    }
  }

  /// Toggles the dropdown menu open or closed.
  void toggleDropdown() {
    if (isOpen) {
      closeDropdown();
    } else {
      openDropdown();
    }
  }

  /// Opens the dropdown menu.
  void openDropdown() {
    final overlay = Overlay.of(context);
    if (overlay == null) return;

    setState(() {
      isOpen = true;
    });

    overlayEntry = OverlayEntry(
      builder: (context) {
        return Positioned(
          left: buttonBounds.x,
          top: buttonBounds.y + buttonBounds.height,
          width: buttonBounds.width,
          height: widget.items.length,
          child: Column([
            for (var i = 0; i < widget.items.length; i++)
              SizedBox(
                height: 1,
                child: _DropdownMenuItemWidget(
                  child: widget.items[i].child,
                  selected: i == selectedIndex,
                  style: widget.dropdownStyle,
                ),
              ),
          ]),
        );
      },
    );

    overlay.insert(overlayEntry!);
  }

  /// Closes the dropdown menu.
  void closeDropdown() {
    overlayEntry?.remove();
    overlayEntry = null;
    setState(() {
      isOpen = false;
    });
  }

  /// Selects the item at the specified [index] and closes the menu.
  void selectItem(int index) {
    if (index >= 0 && index < widget.items.length) {
      final selectedValue = widget.items[index].value;
      widget.onChanged?.call(selectedValue);
    }
    closeDropdown();
  }

  @override
  void dispose() {
    overlayEntry?.remove();
    super.dispose();
  }

  /// Handles incoming keyboard events to navigate and interact with the menu.
  void handleKeyEvent(KeyEvent event) {
    if (!isOpen) {
      if (event.key == ' ' || event.key == '\n' || event.key == 'down') {
        openDropdown();
      }
      return;
    }

    if (event.key == 'down') {
      setState(() {
        selectedIndex = (selectedIndex + 1) % widget.items.length;
      });
      overlayEntry?._overlayState?.setState(() {});
    } else if (event.key == 'up') {
      setState(() {
        selectedIndex =
            (selectedIndex - 1 + widget.items.length) % widget.items.length;
      });
      overlayEntry?._overlayState?.setState(() {});
    } else if (event.key == 'enter' || event.key == '\n' || event.key == ' ') {
      selectItem(selectedIndex);
    } else if (event.key == 'escape') {
      closeDropdown();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!isOpen) {
      updateSelectedIndex();
    }

    final currentItem = widget.items.firstWhere(
      (item) => item.value == widget.value,
      orElse: () => widget.items.first,
    );

    final displayWidget = widget.value != null
        ? currentItem.child
        : (widget.hint ?? const Text('Select...'));

    return _DropdownButtonRenderWidget(
      displayWidget: displayWidget,
      isOpen: isOpen,
      focused: widget.focused,
      style: widget.style,
      onRender: (bounds) {
        if (buttonBounds != bounds) {
          buttonBounds = bounds;
          if (isOpen && overlayEntry != null) {
            overlayEntry?._overlayState?.setState(() {});
          }
        }
      },
      onAction: toggleDropdown,
      onKey: handleKeyEvent,
    );
  }
}

class _DropdownButtonRenderWidget extends Widget {
  final Widget displayWidget;
  final bool isOpen;
  final bool focused;
  final Style style;
  final void Function(Rect bounds) onRender;
  final void Function() onAction;
  final void Function(KeyEvent event) onKey;

  const _DropdownButtonRenderWidget({
    required this.displayWidget,
    required this.isOpen,
    required this.focused,
    required this.style,
    required this.onRender,
    required this.onAction,
    required this.onKey,
  });

  @override
  void render(Buffer buffer, Rect area) {
    final absBounds = getAbsoluteRect(buffer, area);
    onRender(absBounds);

    final arrow = isOpen ? '▲' : '▼';
    final displayStyle = focused
        ? const Style(modifiers: Modifier.reverse)
        : style;

    if (area.width > 3) {
      final childViewport = Viewport(
        buffer,
        Rect(area.x + 1, area.y, area.width - 4, area.height),
      );
      displayWidget.render(
        childViewport,
        Rect(0, 0, area.width - 4, area.height),
      );

      // Apply the displayStyle (reverse-highlighting when focused) to all cells of childViewport
      for (var y = 0; y < area.height; y++) {
        for (var x = 0; x < area.width - 4; x++) {
          final cell = childViewport.getCell(x, y);
          if (cell != null) {
            cell.style = cell.style.merge(displayStyle);
          }
        }
      }

      buffer.writeString(area.x, area.y, '[', displayStyle);
      buffer.writeString(
        area.x + area.width - 3,
        area.y,
        ' $arrow]',
        displayStyle,
      );
    } else {
      buffer.writeString(area.x, area.y, arrow, displayStyle);
    }
  }

  void handleKeyEvent(KeyEvent event) {
    onKey(event);
  }

  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    if (event.type == MouseEventType.press) {
      onAction();
    }
  }
}

class _DropdownMenuItemWidget extends Widget {
  final Widget child;
  final bool selected;
  final Style style;

  const _DropdownMenuItemWidget({
    required this.child,
    required this.selected,
    required this.style,
  });

  @override
  void render(Buffer buffer, Rect area) {
    final itemStyle = selected ? style : Style.empty;
    for (var y = 0; y < area.height; y++) {
      buffer.writeString(area.x, area.y + y, ' ' * area.width, itemStyle);
    }

    final vp = Viewport(buffer, area);
    child.render(vp, Rect(0, 0, area.width, area.height));

    if (selected) {
      for (var y = 0; y < area.height; y++) {
        for (var x = 0; x < area.width; x++) {
          final cell = vp.getCell(x, y);
          if (cell != null) {
            cell.style = cell.style.merge(itemStyle);
          }
        }
      }
    }
  }
}

/// An item in a popup menu.
class PopupMenuItem<T> {
  /// The value associated with this menu item.
  final T value;

  /// The widget displayed for this menu item.
  final Widget child;

  /// Whether this item is enabled and selectable.
  final bool enabled;

  /// Creates a new popup menu item with the given [value] and [child].
  const PopupMenuItem({
    required this.value,
    required this.child,
    this.enabled = true,
  });
}

/// A button that displays a pop-up option menu when triggered.
///
/// Unlike a dropdown, a popup menu is typically used for general action items.
///
/// ### Interaction Modes
/// - **Keyboard**: Open via Space/Enter/Down. Navigate with Up/Down keys,
///   execute selected action with Enter/Space, and cancel using Escape.
/// - **Mouse**: Click to open, click an item to trigger selection.
///
/// ### Absolute Portal Mapping
/// Resolves its relative layout position via [getAbsoluteRect] to project
/// a menu panel onto the root [Overlay] directly below the trigger child.
///
/// ### Example Usage
///
/// ```dart
/// PopupMenuButton<String>(
///   items: const [
///     PopupMenuItem(value: 'edit', child: Text('Edit')),
///     PopupMenuItem(value: 'delete', child: Text('Delete')),
///   ],
///   onSelected: (action) {
///     print('Action chosen: $action');
///   },
///   onCanceled: () {
///     print('Menu closed without action.');
///   },
///   child: Text('Options'),
/// );
/// ```
///
/// ### Properties Table
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `items` | [List]<[PopupMenuItem]> | List of action choices. |
/// | `onSelected` | `Function(T)` | Callback triggered when an item is selected. |
/// | `onCanceled` | `Function()` | Callback triggered when closed via Escape. |
/// | `child` | [Widget] | The trigger widget displaying on the screen. |
/// | `dropdownStyle`| [Style] | The selection hover style in the menu. |
class PopupMenuButton<T> extends StatefulWidget {
  /// The list of items to display in the popup menu.
  final List<PopupMenuItem<T>> items;

  /// Callback triggered when an item is selected.
  final void Function(T value)? onSelected;

  /// Callback triggered when the menu is dismissed without a selection.
  final void Function()? onCanceled;

  /// The child widget that acts as the trigger for the popup menu.
  final Widget child;

  /// The style applied to the popup menu items.
  final Style dropdownStyle;

  /// Whether the button is currently focused.
  final bool focused;

  /// Creates a new popup menu button.
  const PopupMenuButton({
    required this.items,
    this.onSelected,
    this.onCanceled,
    required this.child,
    this.dropdownStyle = const Style(modifiers: Modifier.reverse),
    this.focused = false,
  });

  @override
  State<PopupMenuButton<T>> createState() => PopupMenuButtonState<T>();
}

/// State for a [PopupMenuButton].
class PopupMenuButtonState<T> extends State<PopupMenuButton<T>> {
  /// Whether the popup menu is currently open.
  bool isOpen = false;

  /// The overlay entry representing the open menu.
  OverlayEntry? overlayEntry;

  /// The index of the currently highlighted menu item.
  int selectedIndex = 0;

  /// The on-screen bounds of the trigger button.
  Rect buttonBounds = const Rect(0, 0, 0, 0);

  /// Toggles the popup menu open or closed.
  void toggleMenu() {
    if (isOpen) {
      closeMenu();
    } else {
      openMenu();
    }
  }

  /// Opens the popup menu.
  void openMenu() {
    final overlay = Overlay.of(context);
    if (overlay == null) return;

    setState(() {
      isOpen = true;
      selectedIndex = 0;
    });

    overlayEntry = OverlayEntry(
      builder: (context) {
        return Positioned(
          left: buttonBounds.x,
          top: buttonBounds.y + buttonBounds.height,
          width: max(12, buttonBounds.width),
          height: widget.items.length,
          child: Column([
            for (var i = 0; i < widget.items.length; i++)
              SizedBox(
                height: 1,
                child: _DropdownMenuItemWidget(
                  child: widget.items[i].child,
                  selected: i == selectedIndex,
                  style: widget.dropdownStyle,
                ),
              ),
          ]),
        );
      },
    );

    overlay.insert(overlayEntry!);
  }

  /// Closes the popup menu.
  void closeMenu() {
    overlayEntry?.remove();
    overlayEntry = null;
    setState(() {
      isOpen = false;
    });
  }

  /// Selects the item at the specified [index] if enabled, and closes the menu.
  void selectItem(int index) {
    if (index >= 0 && index < widget.items.length) {
      final item = widget.items[index];
      if (item.enabled) {
        widget.onSelected?.call(item.value);
      }
    }
    closeMenu();
  }

  @override
  void dispose() {
    overlayEntry?.remove();
    super.dispose();
  }

  /// Handles incoming keyboard events to navigate and interact with the menu.
  void handleKeyEvent(KeyEvent event) {
    if (!isOpen) {
      if (event.key == ' ' || event.key == '\n' || event.key == 'down') {
        openMenu();
      }
      return;
    }

    if (event.key == 'down') {
      setState(() {
        selectedIndex = (selectedIndex + 1) % widget.items.length;
      });
      overlayEntry?._overlayState?.setState(() {});
    } else if (event.key == 'up') {
      setState(() {
        selectedIndex =
            (selectedIndex - 1 + widget.items.length) % widget.items.length;
      });
      overlayEntry?._overlayState?.setState(() {});
    } else if (event.key == 'enter' || event.key == '\n' || event.key == ' ') {
      selectItem(selectedIndex);
    } else if (event.key == 'escape') {
      widget.onCanceled?.call();
      closeMenu();
    }
  }

  @override
  Widget build(BuildContext context) {
    return _DropdownButtonRenderWidget(
      displayWidget: widget.child,
      isOpen: isOpen,
      focused: widget.focused,
      style: Style.empty,
      onRender: (bounds) {
        if (buttonBounds != bounds) {
          buttonBounds = bounds;
          if (isOpen && overlayEntry != null) {
            overlayEntry?._overlayState?.setState(() {});
          }
        }
      },
      onAction: toggleMenu,
      onKey: handleKeyEvent,
    );
  }
}
