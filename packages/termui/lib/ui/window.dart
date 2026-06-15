import 'dart:math';
import 'package:characters/characters.dart';
import 'buffer.dart';
import 'style.dart';
import 'layout.dart';
import 'event.dart';
import 'event.dart' as ev;
import '../perf/tracer.dart';

/// A node in the keyboard focus tree.
///
/// Represents an interactive leaf or branch in the focus management tree.
/// Key events bubble up the active node path starting from the primary focused leaf
/// up to the root focus scope, until one of the nodes consumes it by returning `true`.
///
/// ### Core API Reference
///
/// | Property / Method | Description |
/// | :--- | :--- |
/// | [isFocused] | Whether this node has keyboard focus. |
/// | [parent] | The ancestor focus node in the tree. |
/// | [children] | Direct descendants of this focus node. |
/// | [onKeyEvent] | Callback to process a key event. Return `true` to stop propagation. |
/// | [onFocusChange] | Callback executed when focus status transitions. |
/// Centralized registry managing active focus paths.
class FocusManager {
  /// The singleton instance of [FocusManager].
  static final FocusManager instance = FocusManager._();
  FocusManager._();

  FocusNode? _primaryFocus;

  /// Returns the currently active focused leaf node in O(1) time.
  FocusNode? get primaryFocus => _primaryFocus;

  /// Sets focus to [node], updating the focus path to the root.
  void setPrimaryFocus(FocusNode? node) {
    if (_primaryFocus == node) return;

    final oldPath = _getPathToRoot(_primaryFocus);
    final newPath = _getPathToRoot(node);

    // Unfocus nodes no longer on the active path
    for (final oldNode in oldPath) {
      if (!newPath.contains(oldNode)) {
        oldNode._setFocused(false);
      }
    }

    // Focus nodes entering the active path
    for (final newNode in newPath) {
      if (!oldPath.contains(newNode)) {
        newNode._setFocused(true);
      }
      if (newNode.parent is FocusScopeNode) {
        (newNode.parent as FocusScopeNode)._focusedChild = newNode;
      }
    }

    _primaryFocus = node;
  }

  List<FocusNode> _getPathToRoot(FocusNode? node) {
    final path = <FocusNode>[];
    var current = node;
    while (current != null) {
      path.add(current);
      current = current.parent;
    }
    return path;
  }
}

/// A representation of a node in the focus tree.
class FocusNode {
  /// Unique identifier of the focus node (useful for debugging).
  final String id;

  /// The parent focus node, if any.
  FocusNode? parent;

  /// The children focus nodes nested under this node.
  final List<FocusNode> children = [];

  /// Whether this node currently holds focus.
  bool _isFocused = false;

  /// Whether this node currently has focus.
  bool get hasFocus => _isFocused;

  /// Whether this node currently holds focus.
  bool get isFocused => _isFocused;

  /// Callback executed when this focus node gains or loses focus.
  void Function(bool hasFocus)? onFocusChange;

  /// Callback executed when a key event hits this node.
  /// Return `true` to consume the keypress and prevent it from bubbling.
  bool Function(KeyEvent event)? onKeyEvent;

  /// Creates a new [FocusNode] with the given [id].
  FocusNode({required this.id});

  /// Whether this node has primary focus, meaning it is focused and none of its children are.
  bool get hasPrimaryFocus =>
      _isFocused && children.every((c) => !c._isFocused);

  /// Request focus for this specific node.
  void requestFocus() {
    FocusManager.instance.setPrimaryFocus(this);
  }

  /// Removes focus from this node.
  void unfocus() {
    if (hasFocus) {
      FocusManager.instance.setPrimaryFocus(parent);
    } else {
      _setFocused(false);
    }
  }

  /// Internal focus state setter. Called by [FocusManager].
  void _setFocused(bool value) {
    if (_isFocused == value) return;
    _isFocused = value;
    onFocusChange?.call(value);
  }

  /// Adds a child focus node to this branch.
  void addChild(FocusNode child) {
    if (child.parent == this) return;
    child.parent?.children.remove(child);
    child.parent = this;
    children.add(child);
    if (child._isFocused) {
      FocusNode? current = this;
      while (current != null) {
        current._setFocused(true);
        if (current.parent is FocusScopeNode) {
          (current.parent as FocusScopeNode)._focusedChild = current;
        }
        current = current.parent;
      }
    }
  }

  /// Removes a child focus node from this branch.
  void removeChild(FocusNode child) {
    if (child.parent == this) {
      children.remove(child);
      child.parent = null;
    }
  }

  /// Bubbles the [event] up the parent chain starting from the focused leaf.
  bool bubbleKeyEvent(KeyEvent event) {
    FocusNode? current = findFocusedLeaf() ?? this;
    while (current != null) {
      if (current.onKeyEvent != null && current.onKeyEvent!(event)) {
        return true; // Consumed
      }
      if (current is FocusScopeNode) {
        if (event.type == KeyType.tab ||
            event.key == '\t' ||
            event.key == 'backtab') {
          final isShift =
              event.modifiers.contains(ev.Modifier.shift) ||
              event.key == 'backtab';
          if (isShift) {
            current.previousFocus();
          } else {
            current.nextFocus();
          }
          return true; // Consumed
        }
      }
      current = current.parent;
    }
    return false; // Propagates to system fallback
  }

  /// Traverses down the focused path to find the deeply focused leaf node.
  FocusNode? findFocusedLeaf() {
    if (!_isFocused) return null;
    for (final child in children) {
      if (child._isFocused) {
        return child.findFocusedLeaf();
      }
    }
    return this;
  }

  /// Disposes of the focus node, detaching it from the tree.
  void dispose() {
    if (hasFocus) {
      FocusNode? nextTarget = parent;
      if (parent != null) {
        final siblings = parent!.children.where((c) => c != this).toList();
        if (siblings.isNotEmpty) {
          nextTarget = siblings.first;
        }
      }
      FocusManager.instance.setPrimaryFocus(nextTarget);
    }
    final p = parent;
    if (p != null) {
      p.children.remove(this);
      if (p is FocusScopeNode && p._focusedChild == this) {
        p._focusedChild = p.children.isNotEmpty ? p.children.first : null;
      }
      parent = null;
    }
  }
}

/// A specialized focus scope node that manages focus traversal.
class FocusScopeNode extends FocusNode {
  FocusNode? _focusedChild;

  /// Creates a [FocusScopeNode] with the given [id].
  FocusScopeNode({required super.id});

  /// The active focused child node inside this scope.
  FocusNode? get focusedChild => _focusedChild;

  @override
  void requestFocus() {
    if (children.isEmpty) {
      super.requestFocus();
      return;
    }
    final target = _focusedChild ?? children.first;
    target.requestFocus();
  }

  /// Cycles keyboard focus forward to the next sibling in the scope's focus list.
  void nextFocus() {
    if (children.isEmpty) return;
    final active = _focusedChild;
    final idx = active != null ? children.indexOf(active) : -1;
    final nextNode = children[(idx + 1) % children.length];
    nextNode.requestFocus();
  }

  /// Cycles keyboard focus backward to the previous sibling in the focus list.
  void previousFocus() {
    if (children.isEmpty) return;
    final active = _focusedChild;
    final idx = active != null ? children.indexOf(active) : -1;
    final prevNode = children[(idx - 1 + children.length) % children.length];
    prevNode.requestFocus();
  }
}

/// A Window widget that acts as an isolated floating frame with borders,
/// titles, Z-indexing, and local content viewports.
class Window extends Widget {
  /// The title text shown in the window border.
  final String title;

  /// The layout boundaries of the window.
  Rect bounds;

  /// The Z-index of the window determining stacking order.
  int zIndex;

  /// The child widget displayed inside the window.
  final Widget child;

  /// The characters used to draw the window borders.
  final List<String> borderChars;

  /// The style applied to the window borders.
  final Style borderStyle;

  /// The style applied to the window title.
  final Style titleStyle;

  /// The background style of the window.
  final Style backgroundStyle;

  /// The focus node representing this window's focus state.
  final FocusNode focusNode;

  /// Callback triggered when a mouse event hits this window.
  final void Function(MouseEvent event, int localX, int localY)? onMouseEvent;

  /// Callback triggered when a keyboard event is routed to this window.
  final void Function(KeyEvent event)? onKeyEvent;

  /// Creates a [Window] with the specified parameters.
  Window({
    required this.title,
    required this.bounds,
    required this.child,
    this.zIndex = 0,
    List<String>? borderChars,
    this.borderStyle = Style.empty,
    this.titleStyle = Style.empty,
    this.backgroundStyle = Style.empty,
    FocusNode? focusNode,
    this.onMouseEvent,
    this.onKeyEvent,
  }) : borderChars =
           borderChars ?? ['┌', '─', '┐', '│', ' ', '│', '└', '─', '┘'],
       focusNode = focusNode ?? FocusNode(id: title);

  @override
  Element createElement() => WindowElement(this);

  /// Returns true if the local coordinates [localX] and [localY] lie on the title text.
  bool isPositionOnTitle(int localX, int localY) {
    if (localY != 0 || title.isEmpty) return false;
    final w = bounds.width;
    if (w < 2) return false;

    final titleChars = title.characters;
    final maxTitleLen = w - 4;
    String displayedTitle;
    if (titleChars.length > maxTitleLen) {
      final cutLen = w - 7;
      if (cutLen > 0) {
        displayedTitle = ' ${titleChars.take(cutLen).toString()}... ';
      } else {
        displayedTitle = '';
      }
    } else {
      displayedTitle = ' $title ';
    }

    if (displayedTitle.isEmpty) return false;
    final dispChars = displayedTitle.characters;
    final titleX = max(1, min(w - 2, ((w - dispChars.length) / 2).floor()));
    return localX >= titleX && localX < titleX + dispChars.length;
  }
}

/// Element class corresponding to [Window], managing child reconciliation, layout and paint.
class WindowElement extends Element {
  /// The element corresponding to the built child widget.
  Element? childElement;

  /// Instantiates the rendering element for the given Window.
  WindowElement(Window super.widget);

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
    final win = widget as Window;
    if (childElement != null &&
        childElement!.widget.runtimeType == win.child.runtimeType) {
      childElement!.update(win.child);
    } else {
      childElement?.unmount();
      childElement = win.child.createElement();
      childElement!.mount(this);
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement != null) visitor(childElement!);
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    final win = widget as Window;
    final width = win.bounds.width;
    final height = win.bounds.height;

    if (childElement != null) {
      childElement!.relativeOffset = const Offset(1, 1);
      final childW = max(0, width - 2);
      final childH = max(0, height - 2);
      childElement!.layout(BoxConstraints.tight(Size(childW, childH)));
    }

    return constraints.constrain(Size(width, height));
  }

  @override
  void paint(Buffer buffer, Offset offset) {
    final win = widget as Window;
    final w = win.bounds.width;
    final h = win.bounds.height;
    final paintOffset = offset + Offset(win.bounds.x, win.bounds.y);

    if (w < 2 || h < 2) {
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final cell = buffer.getCell(paintOffset.dx + x, paintOffset.dy + y);
          if (cell != null) {
            cell.char = ' ';
            cell.style = win.borderStyle;
          }
        }
      }
      return;
    }

    // Draw top border
    final topBorder =
        win.borderChars[0] + win.borderChars[1] * (w - 2) + win.borderChars[2];
    buffer.writeString(
      paintOffset.dx,
      paintOffset.dy,
      topBorder,
      win.borderStyle,
    );

    // Overlay title
    if (win.title.isNotEmpty) {
      final titleChars = win.title.characters;
      final maxTitleLen = w - 4;
      String displayedTitle;
      if (titleChars.length > maxTitleLen) {
        final cutLen = w - 7;
        if (cutLen > 0) {
          displayedTitle = ' ${titleChars.take(cutLen).toString()}... ';
        } else {
          displayedTitle = '';
        }
      } else {
        displayedTitle = ' ${win.title} ';
      }

      if (displayedTitle.isNotEmpty) {
        final dispChars = displayedTitle.characters;
        final titleX = max(1, min(w - 2, ((w - dispChars.length) / 2).floor()));
        buffer.writeString(
          paintOffset.dx + titleX,
          paintOffset.dy,
          displayedTitle,
          win.titleStyle,
        );
      }
    }

    // Side borders
    for (var y = 1; y < h - 1; y++) {
      buffer.writeString(
        paintOffset.dx,
        paintOffset.dy + y,
        win.borderChars[3],
        win.borderStyle,
      );
      buffer.writeString(
        paintOffset.dx + w - 1,
        paintOffset.dy + y,
        win.borderChars[5],
        win.borderStyle,
      );
    }

    // Bottom border
    final bottomBorder =
        win.borderChars[6] + win.borderChars[7] * (w - 2) + win.borderChars[8];
    buffer.writeString(
      paintOffset.dx,
      paintOffset.dy + h - 1,
      bottomBorder,
      win.borderStyle,
    );

    // Render child content viewport
    final contentArea = Rect(
      paintOffset.dx + 1,
      paintOffset.dy + 1,
      w - 2,
      h - 2,
    );
    final contentViewport = Viewport(buffer, contentArea);
    contentViewport.fill(Cell(' ', win.backgroundStyle));

    if (childElement != null) {
      childElement!.paint(contentViewport, Offset.zero);
    }
  }

  @override
  Offset get relativeOffset {
    final win = widget as Window;
    return Offset(win.bounds.x, win.bounds.y);
  }
}

/// A desktop-like window manager to handle routing of mouse/keyboard events.
class WindowManager {
  static final int _traceWindowResizeId = Tracer.registerString(
    'Window:resize',
  );

  /// The list of currently managed windows.
  final List<Window> windows = [];

  /// The size of the screen/viewport to clamp window resizing and dragging.
  Size screenSize = const Size(80, 24);

  /// The root focus node for the window manager.
  final FocusNode rootFocusNode = FocusNode(id: 'root');

  /// Adds a [window] to the manager and registers its focus node.
  void addWindow(Window window) {
    windows.add(window);
    rootFocusNode.addChild(window.focusNode);
  }

  /// Removes a [window] from the manager and its focus node.
  void removeWindow(Window window) {
    windows.remove(window);
    window.focusNode.parent?.children.remove(window.focusNode);
  }

  /// Returns the topmost window that contains the coordinates (gx, gy).
  Window? findWindowAt(int gx, int gy) {
    // Sort windows by Z-Index descending (topmost first)
    final sorted = List<Window>.from(windows)
      ..sort((a, b) => b.zIndex.compareTo(a.zIndex));

    for (final win in sorted) {
      final b = win.bounds;
      if (gx >= b.x && gx < b.x + b.width && gy >= b.y && gy < b.y + b.height) {
        return win;
      }
    }
    return null;
  }

  // Drag state
  Window? _draggingWindow;
  int _dragStartX = 0;
  int _dragStartY = 0;

  // Resize state
  Window? _resizingWindow;
  bool _resizeBottomLeft = false;
  bool _resizeBottomRight = false;

  /// Whether the window manager is currently dragging or resizing a window.
  bool get isDraggingOrResizing =>
      _draggingWindow != null || _resizingWindow != null;

  /// Brings the given window to the front of all windows.
  void bringToFront(Window win) {
    if (windows.isEmpty) return;
    var maxZ = win.zIndex;
    for (final other in windows) {
      if (other != win && other.zIndex > maxZ) {
        maxZ = other.zIndex;
      }
    }
    if (win.zIndex <= maxZ) {
      win.zIndex = maxZ + 1;
    }
  }

  /// Routes a mouse event, performing coordinate translation and triggering click/drag handlers.
  bool handleMouseEvent(MouseEvent event) {
    if (event.type == MouseEventType.release ||
        event.type == MouseEventType.press) {
      _draggingWindow = null;
      _resizingWindow = null;
      _resizeBottomLeft = false;
      _resizeBottomRight = false;
    }

    final sx = event.x - 1;
    final sy = event.y - 1;

    if (event.type == MouseEventType.drag) {
      if (_resizingWindow != null) {
        Tracer.record(_traceWindowResizeId, Phase.begin);
        try {
          final b = _resizingWindow!.bounds;
          final maxW = screenSize.width;
          final maxH = screenSize.height;
          if (_resizeBottomRight) {
            final limitW = (maxW - b.x) < 10 ? 10 : maxW - b.x;
            final limitH = (maxH - b.y) < 5 ? 5 : maxH - b.y;
            final newWidth = (sx - b.x + 1).clamp(10, limitW);
            final newHeight = (sy - b.y + 1).clamp(5, limitH);
            _resizingWindow!.bounds = Rect(b.x, b.y, newWidth, newHeight);
          } else if (_resizeBottomLeft) {
            final rightEdge = b.x + b.width;
            final newX = sx.clamp(0, rightEdge - 10);
            final newWidth = rightEdge - newX;
            final limitH = (maxH - b.y) < 5 ? 5 : maxH - b.y;
            final newHeight = (sy - b.y + 1).clamp(5, limitH);
            _resizingWindow!.bounds = Rect(newX, b.y, newWidth, newHeight);
          }
        } finally {
          Tracer.record(_traceWindowResizeId, Phase.end);
        }
        return true;
      }

      if (_draggingWindow != null) {
        final maxW = screenSize.width;
        final maxH = screenSize.height;
        final width = _draggingWindow!.bounds.width;
        final height = _draggingWindow!.bounds.height;
        final targetX = sx - _dragStartX;
        final targetY = sy - _dragStartY;

        // Clamp so the window title bar remains accessible
        final newX = targetX.clamp(-width + 3, maxW - 3);
        final newY = targetY.clamp(0, maxH - 1);

        _draggingWindow!.bounds = Rect(newX, newY, width, height);
        return true;
      }
    }

    final win = findWindowAt(sx, sy);
    if (win != null) {
      final localX = sx - win.bounds.x;
      final localY = sy - win.bounds.y;

      if (event.type == MouseEventType.press) {
        win.focusNode.requestFocus();
        bringToFront(win);

        // Check resize handles at bottom-left or bottom-right corners (with 2-cell tolerance)
        final isAtBottomBorder = localY == win.bounds.height - 1;
        final isAtLeftBorder = localX == 0;
        final isAtRightBorder = localX == win.bounds.width - 1;

        final isNearBottomLeft =
            (isAtBottomBorder && localX <= 2) ||
            (isAtLeftBorder && localY >= win.bounds.height - 3);
        final isNearBottomRight =
            (isAtBottomBorder && localX >= win.bounds.width - 3) ||
            (isAtRightBorder && localY >= win.bounds.height - 3);

        if (isNearBottomLeft) {
          _resizingWindow = win;
          _resizeBottomLeft = true;
          _resizeBottomRight = false;
          return true;
        } else if (isNearBottomRight) {
          _resizingWindow = win;
          _resizeBottomLeft = false;
          _resizeBottomRight = true;
          return true;
        }

        // Start dragging if clicked on the title
        if (win.isPositionOnTitle(localX, localY)) {
          _draggingWindow = win;
          _dragStartX = localX;
          _dragStartY = localY;
          return true;
        }
      }

      if (win.onMouseEvent != null) {
        win.onMouseEvent!(event, localX, localY);
      }
      return true;
    }
    return false;
  }

  /// A list of global key listeners. If a listener returns true, the event is consumed.
  final List<bool Function(KeyEvent event)> globalKeyListeners = [];

  /// Routes a keyboard event to the currently focused window.
  bool handleKeyEvent(KeyEvent event) {
    for (final listener in globalKeyListeners) {
      if (listener(event)) return true;
    }
    var leaf = rootFocusNode.findFocusedLeaf();
    if (leaf != null) {
      // Trace up parent chain to find immediate child of rootFocusNode
      while (leaf != null && leaf.parent != rootFocusNode) {
        leaf = leaf.parent;
      }
      if (leaf != null) {
        for (final win in windows) {
          if (win.focusNode == leaf) {
            if (win.onKeyEvent != null) {
              win.onKeyEvent!(event);
              return true;
            }
            break;
          }
        }
      }
    }
    return false;
  }
}
