import 'dart:math';
import 'package:characters/characters.dart';
import 'buffer.dart';
import 'style.dart';
import 'layout.dart';
import 'event.dart';
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
class FocusNode {
  /// Unique identifier of the focus node (useful for debugging).
  final String id;

  /// Whether this node currently holds keyboard focus.
  bool isFocused = false;

  /// The parent focus node, if any.
  FocusNode? parent;

  /// The child nodes nested under this node.
  final List<FocusNode> children = [];

  /// Callback executed when a key event hits this node.
  /// Return `true` to consume the keypress and prevent it from bubbling up the tree.
  bool Function(KeyEvent event)? onKeyEvent;

  /// Callback executed when this focus node gains or loses focus.
  void Function(bool hasFocus)? onFocusChange;

  /// Creates a [FocusNode] with the given [id].
  FocusNode({required this.id});

  /// Whether this node has focus.
  bool get hasFocus => isFocused;

  /// Whether this node has primary focus, meaning it is focused and none of its children are.
  bool get hasPrimaryFocus => isFocused && children.every((c) => !c.isFocused);

  /// Adds a child focus node to this branch.
  void addChild(FocusNode child) {
    child.parent = this;
    children.add(child);
  }

  /// Requests focus for this node, unfocusing other sibling branches recursively.
  void requestFocus() {
    // 1. Find root
    var root = this;
    while (root.parent != null) {
      root = root.parent!;
    }

    // 2. Unfocus everything under root
    root._unfocusRecursive();

    // 3. Focus path from this node to root
    FocusNode? current = this;
    while (current != null) {
      final wasFocused = current.isFocused;
      current.isFocused = true;
      if (!wasFocused) {
        current.onFocusChange?.call(true);
      }
      if (current is FocusScopeNode) {
        FocusNode? childOnPath;
        for (final child in current.children) {
          if (child.isFocused) {
            childOnPath = child;
            break;
          }
        }
        if (childOnPath != null) {
          current._focusedChild = childOnPath;
        }
      }
      current = current.parent;
    }
  }

  /// Removes focus from this node and its descendants.
  void unfocus() {
    if (!isFocused) return;
    _unfocusRecursive();
  }

  void _unfocusRecursive() {
    final wasFocused = isFocused;
    isFocused = false;
    if (wasFocused) {
      onFocusChange?.call(false);
    }
    for (final child in children) {
      child._unfocusRecursive();
    }
  }

  /// Traverses down the focused path to find the deeply focused leaf node.
  FocusNode? findFocusedLeaf() {
    if (!isFocused) return null;
    for (final child in children) {
      if (child.isFocused) {
        return child.findFocusedLeaf();
      }
    }
    return this;
  }

  /// Traverses up from the primary focus node to let nodes consume keypresses.
  bool bubbleKeyEvent(KeyEvent event) {
    final leaf = findFocusedLeaf();
    if (leaf != null) {
      return leaf._bubbleUp(event);
    }
    return false;
  }

  bool _bubbleUp(KeyEvent event) {
    if (onKeyEvent != null && onKeyEvent!(event)) {
      return true; // consumed
    }
    return parent?._bubbleUp(event) ?? false;
  }
}

/// A specialized focus scope node that manages focus traversal.
///
/// Grouping interactive focus nodes inside a [FocusScopeNode] enables cycling focus
/// among its descendants (e.g. by pressing Tab for forward cycles or Shift-Tab for backward cycles).
/// It keeps track of the currently active focused child in the scope.
///
/// ### Traversal APIs
///
/// * [nextFocus()]: Move focus to the next child in [children].
/// * [previousFocus()]: Move focus to the previous child in [children].
class FocusScopeNode extends FocusNode {
  FocusNode? _focusedChild;

  /// Creates a [FocusScopeNode] with the given [id].
  FocusScopeNode({required super.id});

  /// The active focused child node inside this scope.
  FocusNode? get focusedChild => _focusedChild;

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
  void render(Buffer buffer, Rect area) {
    if (bounds.width <= 0 || bounds.height <= 0) return;

    // Render window inside parent buffer at this window's bounds.
    final absoluteBounds = Rect(
      area.x + bounds.x,
      area.y + bounds.y,
      bounds.width,
      bounds.height,
    );

    final windowViewport = Viewport(buffer, absoluteBounds);
    final w = bounds.width;
    final h = bounds.height;

    if (w < 2 || h < 2) {
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final cell = windowViewport.getCell(x, y);
          if (cell != null) {
            cell.char = ' ';
            cell.style = borderStyle;
          }
        }
      }
      return;
    }

    // Draw top border
    final topBorder =
        borderChars[0] + borderChars[1] * (w - 2) + borderChars[2];
    windowViewport.writeString(0, 0, topBorder, borderStyle);

    // Overlay title
    if (title.isNotEmpty) {
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

      if (displayedTitle.isNotEmpty) {
        final dispChars = displayedTitle.characters;
        final titleX = max(1, min(w - 2, ((w - dispChars.length) / 2).floor()));
        windowViewport.writeString(titleX, 0, displayedTitle, titleStyle);
      }
    }

    // Side borders
    for (var y = 1; y < h - 1; y++) {
      windowViewport.writeString(0, y, borderChars[3], borderStyle);
      windowViewport.writeString(w - 1, y, borderChars[5], borderStyle);
    }

    // Bottom border
    final bottomBorder =
        borderChars[6] + borderChars[7] * (w - 2) + borderChars[8];
    windowViewport.writeString(0, h - 1, bottomBorder, borderStyle);

    // Render child content viewport
    final contentArea = Rect(1, 1, w - 2, h - 2);
    final contentViewport = Viewport(windowViewport, contentArea);
    contentViewport.fill(Cell(' ', backgroundStyle));
    child.render(
      contentViewport,
      Rect(0, 0, contentArea.width, contentArea.height),
    );
  }

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

/// A desktop-like window manager to handle routing of mouse/keyboard events.
class WindowManager {
  static final int _traceWindowResizeId = Tracer.registerString(
    'Window:resize',
  );

  /// The list of currently managed windows.
  final List<Window> windows = [];

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
          if (_resizeBottomRight) {
            final newWidth = (sx - b.x + 1).clamp(10, 100);
            final newHeight = (sy - b.y + 1).clamp(5, 40);
            _resizingWindow!.bounds = Rect(b.x, b.y, newWidth, newHeight);
          } else if (_resizeBottomLeft) {
            final rightEdge = b.x + b.width;
            final newX = sx.clamp(0, rightEdge - 10);
            final newWidth = rightEdge - newX;
            final newHeight = (sy - b.y + 1).clamp(5, 40);
            _resizingWindow!.bounds = Rect(newX, b.y, newWidth, newHeight);
          }
        } finally {
          Tracer.record(_traceWindowResizeId, Phase.end);
        }
        return true;
      }

      if (_draggingWindow != null) {
        final newX = sx - _dragStartX;
        final newY = sy - _dragStartY;
        _draggingWindow!.bounds = Rect(
          newX,
          newY,
          _draggingWindow!.bounds.width,
          _draggingWindow!.bounds.height,
        );
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
