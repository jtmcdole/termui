import 'dart:async';
import 'package:characters/characters.dart';
import 'package:termui/termui.dart';
import 'package:termui/terminal/terminal.dart' as term;

/// A node in the hierarchical tree structure.
class TreeNode<T> {
  /// The label displayed for this node in the tree.
  final String label;

  /// The underlying value associated with this node.
  final T value;

  /// The child nodes nested under this node.
  final List<TreeNode<T>> children;

  /// The parent node of this node, if any.
  TreeNode<T>? parent;

  /// Whether this folder node is currently expanded to show its children.
  bool isExpanded;

  /// Creates a new [TreeNode] with the specified [label] and [value].
  TreeNode({
    required this.label,
    required this.value,
    this.children = const [],
    this.isExpanded = false,
  }) {
    for (final child in children) {
      child.parent = this;
    }
  }

  /// Returns `true` if this node has no children.
  bool get isLeaf => children.isEmpty;
}

/// Helper info for rendering a flattened tree node.
class FlatNode<T> {
  /// The tree node being flattened.
  final TreeNode<T> node;

  /// The depth level of the node in the tree hierarchy.
  final int depth;

  /// A boolean list representing whether each ancestor of this node is the last child in its respective parent.
  final List<bool> ancestorIsLast;

  /// Creates a new [FlatNode] helper.
  FlatNode({
    required this.node,
    required this.depth,
    required this.ancestorIsLast,
  });
}

/// A tree widget that displays nested TreeNode hierarchies.
class TreeWidget<T> extends StatefulWidget {
  /// The root node of the tree.
  final TreeNode<T> root;

  /// Callback executed when a node is selected.
  final void Function(TreeNode<T>)? onSelect;

  /// The style applied to the selected active node.
  final Style selectedStyle;

  /// The style applied to unselected nodes.
  final Style unselectedStyle;

  /// The style applied to the horizontal and vertical guide lines.
  final Style lineStyle;

  /// Whether to show the root node in the tree.
  final bool showRoot;

  /// Whether the tree currently has keyboard focus.
  final bool focused;

  /// Creates a [TreeWidget] with the specified [root] node.
  const TreeWidget({
    super.key,
    required this.root,
    this.onSelect,
    this.selectedStyle = const Style(
      foreground: CharmColors.pepper,
      background: CharmColors.charple,
      modifiers: Modifier.bold,
    ),
    this.unselectedStyle = const Style(foreground: CharmColors.soda),
    this.lineStyle = const Style(foreground: CharmColors.bbq),
    this.showRoot = true,
    this.focused = true,
  });

  @override
  State<TreeWidget<T>> createState() => TreeWidgetState<T>();
}

/// The state for a [TreeWidget] widget.
class TreeWidgetState<T> extends State<TreeWidget<T>>
    implements KeyEventHandler {
  late FocusNode _focusNode;

  /// The list of visible nodes after flattening the tree based on expansion state.
  List<FlatNode<T>> flatNodes = [];

  /// The currently selected node index within the [flatNodes] list.
  int selectedIndex = 0;

  /// The current vertical scroll offset.
  int scrollOffset = 0;

  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _isFocused = widget.focused;
    updateFlatNodes();
    _focusNode = FocusNode(id: 'tree_${widget.hashCode}');
    if (_isFocused) {
      scheduleMicrotask(() {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  /// Rebuilds the [flatNodes] list by traversing the tree starting from the root.
  void updateFlatNodes() {
    flatNodes = [];
    _flatten(widget.root, 0, [], true, flatNodes);
    if (flatNodes.isNotEmpty) {
      selectedIndex = selectedIndex.clamp(0, flatNodes.length - 1);
    } else {
      selectedIndex = 0;
    }
  }

  void _flatten(
    TreeNode<T> node,
    int depth,
    List<bool> ancestorIsLast,
    bool isLast,
    List<FlatNode<T>> target,
  ) {
    if (depth > 0 || widget.showRoot) {
      target.add(
        FlatNode(
          node: node,
          depth: widget.showRoot ? depth : depth - 1,
          ancestorIsLast: depth == 0
              ? []
              : widget.showRoot
              ? [...ancestorIsLast, isLast]
              : ancestorIsLast,
        ),
      );
    }

    if (node.isExpanded) {
      final nextAncestorIsLast = widget.showRoot
          ? [...ancestorIsLast, isLast]
          : <bool>[];
      if (!widget.showRoot && depth > 0) {
        nextAncestorIsLast.addAll([...ancestorIsLast, isLast]);
      }
      for (var i = 0; i < node.children.length; i++) {
        final child = node.children[i];
        final isLastChild = i == node.children.length - 1;
        _flatten(child, depth + 1, nextAncestorIsLast, isLastChild, target);
      }
    }
  }

  /// Adjusts the scroll offset so that the [selectedIndex] item is visible.
  void adjustScroll(int viewportHeight) {
    if (flatNodes.isEmpty || viewportHeight <= 0) return;
    selectedIndex = selectedIndex.clamp(0, flatNodes.length - 1);

    if (selectedIndex < scrollOffset) {
      scrollOffset = selectedIndex;
    } else if (selectedIndex >= scrollOffset + viewportHeight) {
      scrollOffset = selectedIndex - viewportHeight + 1;
    }
    scrollOffset = scrollOffset.clamp(
      0,
      (flatNodes.length - viewportHeight).clamp(0, flatNodes.length),
    );
  }

  @override
  void didUpdateWidget(TreeWidget<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focused != oldWidget.focused) {
      _isFocused = widget.focused;
      if (_isFocused) {
        _focusNode.requestFocus();
      } else {
        _focusNode.unfocus();
      }
    }
    updateFlatNodes();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  bool handleKeyEvent(term.KeyEvent event) {
    final nodes = flatNodes;
    if (nodes.isEmpty) return false;

    bool handled = false;

    if (event.type == KeyType.up) {
      selectedIndex = selectedIndex - 1;
      handled = true;
    } else if (event.type == KeyType.down) {
      selectedIndex = selectedIndex + 1;
      handled = true;
    } else if (event.type == KeyType.right) {
      final flat = nodes[selectedIndex];
      if (!flat.node.isLeaf) {
        if (!flat.node.isExpanded) {
          flat.node.isExpanded = true;
          updateFlatNodes();
        } else {
          if (selectedIndex < nodes.length - 1) {
            selectedIndex = selectedIndex + 1;
          }
        }
      }
      handled = true;
    } else if (event.type == KeyType.left) {
      final flat = nodes[selectedIndex];
      if (!flat.node.isLeaf && flat.node.isExpanded) {
        flat.node.isExpanded = false;
        updateFlatNodes();
      } else {
        // Move to parent
        final parent = flat.node.parent;
        if (parent != null) {
          final parentIdx = nodes.indexWhere((f) => f.node == parent);
          if (parentIdx != -1) {
            selectedIndex = parentIdx;
          }
        }
      }
      handled = true;
    } else if (event.key == ' ' || event.type == KeyType.enter) {
      if (widget.onSelect != null) {
        widget.onSelect!(nodes[selectedIndex].node);
      }
      handled = true;
    }

    if (handled) {
      setState(() {});
    }
    return handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      onFocusChange: (hasFocus) {
        if (_isFocused != hasFocus) {
          _isFocused = hasFocus;
          setState(() {});
        }
      },
      onKeyEvent: (event) {
        return handleKeyEvent(event);
      },
      child: _TreeWidgetRenderWidget(
        widget: widget,
        state: this,
        focused: _focusNode.hasFocus || _isFocused,
      ),
    );
  }
}

class _TreeWidgetRenderWidget extends Widget {
  final TreeWidget widget;
  final TreeWidgetState state;
  final bool focused;

  const _TreeWidgetRenderWidget({
    required this.widget,
    required this.state,
    required this.focused,
  });

  @override
  Element createElement() => _TreeWidgetElement(this);
}

class _TreeWidgetElement extends Element {
  _TreeWidgetElement(_TreeWidgetRenderWidget super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final wWidget = widget as _TreeWidgetRenderWidget;
    wWidget.state.updateFlatNodes();
    final w = constraints.maxWidth == BoxConstraints.infinity
        ? 20
        : constraints.maxWidth;
    final h = constraints.maxHeight == BoxConstraints.infinity
        ? wWidget.state.flatNodes.length
        : constraints.maxHeight;
    return constraints.constrain(Size(w, h));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final viewport = Viewport(
      buffer,
      Rect(offset.dx, offset.dy, size.width, size.height),
    );
    final wWidget = widget as _TreeWidgetRenderWidget;
    final tWidget = wWidget.widget;
    final state = wWidget.state;

    state.updateFlatNodes();
    state.adjustScroll(size.height);

    final activeSelectedStyle = wWidget.focused
        ? tWidget.selectedStyle
        : Style(
            foreground: tWidget.selectedStyle.foreground,
            background: CharmColors.char,
            modifiers: tWidget.selectedStyle.modifiers,
          );

    final nodes = state.flatNodes;
    final scrollOffsetVal = state.scrollOffset;
    final selIdx = state.selectedIndex;

    for (var i = 0; i < size.height; i++) {
      final nodeIdx = scrollOffsetVal + i;
      if (nodeIdx >= nodes.length) break;

      final flat = nodes[nodeIdx];
      final isSelected = nodeIdx == selIdx;

      var x = 0;

      // 1. Ancestor guide lines
      for (var depthIdx = 0; depthIdx < flat.depth - 1; depthIdx++) {
        if (x >= size.width) break;
        final isLast = flat.ancestorIsLast[depthIdx];
        final part = isLast ? '   ' : '│  ';
        viewport.writeString(
          x,
          i,
          part,
          isSelected ? activeSelectedStyle : tWidget.lineStyle,
        );
        x += 3;
      }

      // 2. Active node guide line
      if (flat.depth > 0 && x < size.width) {
        final isLast = flat.ancestorIsLast.last;
        final part = isLast ? '└── ' : '├── ';
        viewport.writeString(
          x,
          i,
          part,
          isSelected ? activeSelectedStyle : tWidget.lineStyle,
        );
        x += 4;
      }

      // 3. Expander indicator
      if (x < size.width) {
        final indicator = flat.node.isLeaf
            ? '  '
            : (flat.node.isExpanded ? '▼ ' : '▶ ');
        viewport.writeString(
          x,
          i,
          indicator,
          isSelected ? activeSelectedStyle : tWidget.lineStyle,
        );
        x += 2;
      }

      // 4. Label
      final remainingWidth = size.width - x;
      if (remainingWidth > 0) {
        final labelChars = flat.node.label.characters;
        final labelText = labelChars.length > remainingWidth
            ? labelChars.take(remainingWidth).toString()
            : labelChars.toString() +
                  (' ' * (remainingWidth - labelChars.length));
        viewport.writeString(
          x,
          i,
          labelText,
          isSelected ? activeSelectedStyle : tWidget.unselectedStyle,
        );
      }
    }
  }
}
