import 'dart:async';
import 'dart:math';
import '../buffer.dart';
import '../layout.dart';
import '../style.dart';
import '../event.dart' hide Modifier;
import 'text.dart';
import '../../terminal/terminal.dart' as term;
import 'focus.dart';
import '../window.dart';

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
class DropdownButton<T> extends StatefulWidget implements Focusable {
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
  @override
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
class DropdownButtonState<T> extends State<DropdownButton<T>>
    implements KeyEventHandler {
  /// Whether the dropdown menu is currently open.
  bool isOpen = false;

  /// The overlay entry representing the open menu.
  OverlayEntry? overlayEntry;

  /// The index of the currently selected or highlighted item.
  int selectedIndex = 0;

  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(id: 'dropdown_${widget.hashCode}');
    if (widget.focused) {
      scheduleMicrotask(() {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(DropdownButton<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focused != oldWidget.focused) {
      if (widget.focused) {
        _focusNode.requestFocus();
      } else {
        _focusNode.unfocus();
      }
    }
  }

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
    _focusNode.dispose();
    overlayEntry?.remove();
    super.dispose();
  }

  /// Handles incoming keyboard events to navigate and interact with the menu.
  @override
  bool handleKeyEvent(term.KeyEvent event) {
    if (!isOpen) {
      if (event.key == ' ' ||
          event.key == 'space' ||
          event.key == '\n' ||
          event.key == '\r' ||
          event.key == 'enter' ||
          event.type == term.KeyType.enter ||
          event.key == 'down') {
        openDropdown();
        return true;
      }
      return false;
    }

    if (event.key == 'down') {
      setState(() {
        selectedIndex = (selectedIndex + 1) % widget.items.length;
      });
      overlayEntry?._overlayState?.setState(() {});
      return true;
    } else if (event.key == 'up') {
      setState(() {
        selectedIndex =
            (selectedIndex - 1 + widget.items.length) % widget.items.length;
      });
      overlayEntry?._overlayState?.setState(() {});
      return true;
    } else if (event.key == 'enter' ||
        event.key == '\n' ||
        event.key == '\r' ||
        event.type == term.KeyType.enter ||
        event.key == ' ' ||
        event.key == 'space') {
      selectItem(selectedIndex);
      return true;
    } else if (event.key == 'escape') {
      closeDropdown();
      return true;
    }
    return false;
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

    return Focus(
      focusNode: _focusNode,
      onFocusChange: (hasFocus) {
        if (mounted) setState(() {});
      },
      onKeyEvent: (event) {
        return handleKeyEvent(event);
      },
      child: _DropdownButtonRenderWidget(
        displayWidget: displayWidget,
        isOpen: isOpen,
        focused: _focusNode.hasFocus || widget.focused,
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
      ),
    );
  }
}

class _DropdownButtonRenderWidget extends Widget
    implements Focusable, KeyEventHandler, MouseEventHandler {
  final Widget displayWidget;
  final bool isOpen;
  @override
  final bool focused;
  final Style style;
  final void Function(Rect bounds) onRender;
  final void Function() onAction;
  final bool Function(KeyEvent event) onKey;

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
  Element createElement() => _DropdownButtonRenderWidgetElement(this);

  @override
  bool handleKeyEvent(term.KeyEvent event) {
    return onKey(event);
  }

  @override
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    if (event.type == MouseEventType.press) {
      onAction();
    }
  }
}

class _DropdownButtonRenderWidgetElement extends Element {
  Element? displayWidgetElement;

  _DropdownButtonRenderWidgetElement(_DropdownButtonRenderWidget super.widget);

  @override
  void mount(Element? parent) {
    super.mount(parent);
    rebuild();
  }

  @override
  void unmount() {
    displayWidgetElement?.unmount();
    super.unmount();
  }

  @override
  void update(Widget newWidget) {
    super.update(newWidget);
    rebuild();
  }

  @override
  void rebuild() {
    final dButton = widget as _DropdownButtonRenderWidget;
    if (displayWidgetElement != null &&
        displayWidgetElement!.widget.runtimeType ==
            dButton.displayWidget.runtimeType) {
      displayWidgetElement!.update(dButton.displayWidget);
    } else {
      displayWidgetElement?.unmount();
      displayWidgetElement = dButton.displayWidget.createElement();
      displayWidgetElement!.mount(this);
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (displayWidgetElement != null) visitor(displayWidgetElement!);
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    final width = constraints.hasBoundedWidth ? constraints.maxWidth : 80;
    final height = constraints.hasBoundedHeight ? constraints.maxHeight : 1;

    if (displayWidgetElement != null && width > 3) {
      displayWidgetElement!.layout(
        BoxConstraints.tight(Size(width - 4, height)),
      );
    }

    return constraints.constrain(Size(width, height));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final dButton = widget as _DropdownButtonRenderWidget;
    final w = size.width;
    final h = size.height;

    final absBounds = getAbsoluteRect(buffer, Rect(offset.dx, offset.dy, w, h));
    dButton.onRender(absBounds);

    final arrow = dButton.isOpen ? '▲' : '▼';
    final displayStyle = dButton.focused
        ? const Style(modifiers: Modifier.reverse)
        : dButton.style;

    if (w > 3) {
      final childViewport = Viewport(
        buffer,
        Rect(offset.dx + 1, offset.dy, w - 4, h),
      );
      if (displayWidgetElement != null) {
        displayWidgetElement!.paint(childViewport, Offset.zero);
      }

      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w - 4; x++) {
          final cell = childViewport.getCell(x, y);
          if (cell != null) {
            cell.style = cell.style.merge(displayStyle);
          }
        }
      }

      buffer.writeString(offset.dx, offset.dy, '[', displayStyle);
      buffer.writeString(
        offset.dx + w - 3,
        offset.dy,
        ' $arrow]',
        displayStyle,
      );
    } else {
      buffer.writeString(offset.dx, offset.dy, arrow, displayStyle);
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
  Element createElement() => _DropdownMenuItemWidgetElement(this);
}

class _DropdownMenuItemWidgetElement extends Element {
  Element? childElement;

  _DropdownMenuItemWidgetElement(_DropdownMenuItemWidget super.widget);

  @override
  void mount(Element? parent) {
    super.mount(parent);
    rebuild();
  }

  @override
  void unmount() {
    childElement?.unmount();
    super.unmount();
  }

  @override
  void update(Widget newWidget) {
    super.update(newWidget);
    rebuild();
  }

  @override
  void rebuild() {
    final item = widget as _DropdownMenuItemWidget;
    if (childElement != null &&
        childElement!.widget.runtimeType == item.child.runtimeType) {
      childElement!.update(item.child);
    } else {
      childElement?.unmount();
      childElement = item.child.createElement();
      childElement!.mount(this);
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement != null) visitor(childElement!);
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    final width = constraints.hasBoundedWidth ? constraints.maxWidth : 80;
    final height = constraints.hasBoundedHeight ? constraints.maxHeight : 1;

    if (childElement != null) {
      childElement!.layout(BoxConstraints.tight(Size(width, height)));
    }

    return constraints.constrain(Size(width, height));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final item = widget as _DropdownMenuItemWidget;
    final w = size.width;
    final h = size.height;

    final itemStyle = item.selected ? item.style : Style.empty;
    for (var y = 0; y < h; y++) {
      buffer.writeString(offset.dx, offset.dy + y, ' ' * w, itemStyle);
    }

    final vp = Viewport(buffer, Rect(offset.dx, offset.dy, w, h));
    if (childElement != null) {
      childElement!.paint(vp, Offset.zero);
    }

    if (item.selected) {
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
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
class PopupMenuButton<T> extends StatefulWidget implements Focusable {
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
  @override
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
class PopupMenuButtonState<T> extends State<PopupMenuButton<T>>
    implements KeyEventHandler {
  /// Whether the popup menu is currently open.
  bool isOpen = false;

  /// The overlay entry representing the open menu.
  OverlayEntry? overlayEntry;

  /// The index of the currently highlighted menu item.
  int selectedIndex = 0;

  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(id: 'popup_${widget.hashCode}');
    if (widget.focused) {
      scheduleMicrotask(() {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(PopupMenuButton<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focused != oldWidget.focused) {
      if (widget.focused) {
        _focusNode.requestFocus();
      } else {
        _focusNode.unfocus();
      }
    }
  }

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
    _focusNode.dispose();
    overlayEntry?.remove();
    super.dispose();
  }

  /// Handles incoming keyboard events to navigate and interact with the menu.
  @override
  bool handleKeyEvent(term.KeyEvent event) {
    if (!isOpen) {
      if (event.key == ' ' ||
          event.key == 'space' ||
          event.key == '\n' ||
          event.key == '\r' ||
          event.key == 'enter' ||
          event.type == term.KeyType.enter ||
          event.key == 'down') {
        openMenu();
        return true;
      }
      return false;
    }

    if (event.key == 'down') {
      setState(() {
        selectedIndex = (selectedIndex + 1) % widget.items.length;
      });
      overlayEntry?._overlayState?.setState(() {});
      return true;
    } else if (event.key == 'up') {
      setState(() {
        selectedIndex =
            (selectedIndex - 1 + widget.items.length) % widget.items.length;
      });
      overlayEntry?._overlayState?.setState(() {});
      return true;
    } else if (event.key == 'enter' ||
        event.key == '\n' ||
        event.key == '\r' ||
        event.type == term.KeyType.enter ||
        event.key == ' ' ||
        event.key == 'space') {
      selectItem(selectedIndex);
      return true;
    } else if (event.key == 'escape') {
      widget.onCanceled?.call();
      closeMenu();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      onFocusChange: (hasFocus) {
        if (mounted) setState(() {});
      },
      onKeyEvent: (event) {
        return handleKeyEvent(event);
      },
      child: _DropdownButtonRenderWidget(
        displayWidget: widget.child,
        isOpen: isOpen,
        focused: _focusNode.hasFocus || widget.focused,
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
      ),
    );
  }
}
