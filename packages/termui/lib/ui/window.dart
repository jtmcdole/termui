import 'package:termui/termui.dart';
import 'dart:math';
import 'package:characters/characters.dart';
import 'event.dart' as ev;

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
      if (child.hasFocus) {
        child.unfocus();
      }
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
/// titles, and local content viewports.
class Window extends Widget {
  /// The title text shown in the window border.
  final String title;

  /// The width of the window.
  int width;

  /// The height of the window.
  int height;

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

  /// Whether to show the close button [x] on the top right.
  final bool showCloseButton;

  /// Callback triggered when a mouse event hits this window.
  final void Function(MouseEvent event, int localX, int localY)? onMouseEvent;

  /// Callback triggered when a keyboard event is routed to this window.
  final void Function(KeyEvent event)? onKeyEvent;

  /// Callback triggered when the window is dragged.
  final void Function(int dx, int dy)? onPan;

  /// Callback triggered when the window is resized.
  final void Function(int newWidth, int newHeight)? onResize;

  /// Creates a [Window] with the specified parameters.
  Window({
    required this.title,
    required this.width,
    required this.height,
    required this.child,
    List<String>? borderChars,
    this.borderStyle = Style.empty,
    this.titleStyle = Style.empty,
    this.backgroundStyle = Style.empty,
    FocusNode? focusNode,
    this.showCloseButton = false,
    this.onMouseEvent,
    this.onKeyEvent,
    this.onPan,
    this.onResize,
  }) : borderChars =
           borderChars ?? ['┌', '─', '┐', '│', ' ', '│', '└', '─', '┘'],
       focusNode = focusNode ?? FocusNode(id: title);

  @override
  Element createElement() => WindowElement(this);

  /// Returns true if the local coordinates [localX] and [localY] lie on the title text.
  bool isPositionOnTitle(int localX, int localY) {
    if (localY != 0 || title.isEmpty) return false;
    final w = width;
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
class WindowElement extends Element implements MouseEventHandler {
  /// The element corresponding to the built child widget.
  Element? childElement;

  bool _dragStartedOnTitle = false;
  bool _resizeStartedOnBottomLeft = false;
  bool _resizeStartedOnBottomRight = false;
  int _lastX = 0;
  int _lastY = 0;

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
    final width = win.width;
    final height = win.height;

    if (childElement != null) {
      childElement!.relativeOffset = const Offset(1, 1);
      final childW = max(0, width - 2);
      final childH = max(0, height - 2);
      childElement!.layout(BoxConstraints.tight(Size(childW, childH)));
    }

    return constraints.constrain(Size(width, height));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final win = widget as Window;
    final w = win.width;
    final h = win.height;
    final paintOffset = offset;

    if (w < 2 || h < 2) {
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          if (buffer.getCharacter(paintOffset.dx + x, paintOffset.dy + y) !=
              '') {
            buffer.setAttributes(
              paintOffset.dx + x,
              paintOffset.dy + y,
              char: ' ',
              fg: win.borderStyle.foreground?.argb,
              bg: win.borderStyle.background?.argb,
              modifiers: win.borderStyle.modifiers,
            );
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

    // Draw close button [x] at the top right of the window border, e.g. at w - 4, w - 3, w - 2.
    if (win.showCloseButton && w >= 6) {
      buffer.writeString(
        paintOffset.dx + w - 4,
        paintOffset.dy,
        '[x]',
        win.borderStyle,
      );
    }

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
    contentViewport.fillAttributes(
      char: ' ',
      fg: win.backgroundStyle.foreground?.argb,
      bg: win.backgroundStyle.background?.argb,
      modifiers: win.backgroundStyle.modifiers,
    );

    if (childElement != null) {
      childElement!.paint(contentViewport, Offset.zero);
    }
  }

  @override
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    final win = widget as Window;

    if (event.type == MouseEventType.press) {
      _dragStartedOnTitle = false;
      _resizeStartedOnBottomLeft = false;
      _resizeStartedOnBottomRight = false;

      // Check resize handles at bottom-left or bottom-right corners (with 2-cell tolerance)
      final isAtBottomBorder = localY == win.height - 1;
      final isAtLeftBorder = localX == 0;
      final isAtRightBorder = localX == win.width - 1;

      final isNearBottomLeft =
          (isAtBottomBorder && localX <= 2) ||
          (isAtLeftBorder && localY >= win.height - 3);
      final isNearBottomRight =
          (isAtBottomBorder && localX >= win.width - 3) ||
          (isAtRightBorder && localY >= win.height - 3);

      if (isNearBottomLeft) {
        _resizeStartedOnBottomLeft = true;
        _lastX = event.globalX ?? event.x;
        _lastY = event.globalY ?? event.y;
      } else if (isNearBottomRight) {
        _resizeStartedOnBottomRight = true;
        _lastX = event.globalX ?? event.x;
        _lastY = event.globalY ?? event.y;
      } else if (win.isPositionOnTitle(localX, localY)) {
        _dragStartedOnTitle = true;
        _lastX = event.globalX ?? event.x;
        _lastY = event.globalY ?? event.y;
      }

      if (win.onMouseEvent != null) {
        win.onMouseEvent!(event, localX, localY);
      }
    } else if (event.type == MouseEventType.drag) {
      final mouseX = event.globalX ?? event.x;
      final mouseY = event.globalY ?? event.y;

      if (_dragStartedOnTitle) {
        final dx = mouseX - _lastX;
        final dy = mouseY - _lastY;
        _lastX = mouseX;
        _lastY = mouseY;
        win.onPan?.call(dx, dy);
      } else if (_resizeStartedOnBottomRight) {
        final dx = mouseX - _lastX;
        final dy = mouseY - _lastY;
        _lastX = mouseX;
        _lastY = mouseY;
        final newWidth = max(10, win.width + dx);
        final newHeight = max(5, win.height + dy);
        win.onResize?.call(newWidth, newHeight);
      } else if (_resizeStartedOnBottomLeft) {
        final dx = mouseX - _lastX;
        final dy = mouseY - _lastY;
        _lastX = mouseX;
        _lastY = mouseY;
        final newWidth = max(10, win.width - dx);
        final actualDx = win.width - newWidth;
        final newHeight = max(5, win.height + dy);
        win.onPan?.call(actualDx, 0);
        win.onResize?.call(newWidth, newHeight);
      }

      if (win.onMouseEvent != null) {
        win.onMouseEvent!(event, localX, localY);
      }
    } else {
      if (event.type == MouseEventType.release) {
        _dragStartedOnTitle = false;
        _resizeStartedOnBottomLeft = false;
        _resizeStartedOnBottomRight = false;
      }
      if (win.onMouseEvent != null) {
        win.onMouseEvent!(event, localX, localY);
      }
    }
  }
}
