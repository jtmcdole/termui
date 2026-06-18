import 'dart:async';
import 'package:characters/characters.dart';
import '../buffer.dart';
import '../style.dart';
import '../layout.dart';
import '../event.dart' hide Modifier;
import '../color.dart';
import '../../terminal/terminal.dart' as term;
import 'focus.dart';
import '../window.dart';

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
class TreeWidget<T> extends StatefulWidget
    implements Focusable, KeyEventHandler {
  /// The root node of the tree.
  final TreeNode<T> root;

  /// Callback executed when a node is selected.
  final void Function(TreeNode<T>)? onSelect;

  /// The style applied to the selected active node.
  Style selectedStyle;

  /// The style applied to unselected nodes.
  Style unselectedStyle;

  /// The style applied to the horizontal and vertical guide lines.
  Style lineStyle;

  /// Whether to show the root node in the tree.
  bool showRoot;

  /// Whether the tree currently has keyboard focus.
  @override
  bool focused;

  late List<FlatNode<T>> _flatNodes;
  int _selectedIndex = 0;
  int _scrollOffset = 0;

  /// Creates a [TreeWidget] with the specified [root] node.
  TreeWidget({
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
  }) {
    _updateFlatNodes();
  }

  /// The index of the currently selected node in the flattened tree.
  int get selectedIndex =>
      _state != null ? _state!._selectedIndex : _selectedIndex;

  /// Sets the index of the currently selected node and clamps it to valid bounds.
  set selectedIndex(int val) {
    if (_state != null) {
      if (_state!._flatNodes.isNotEmpty) {
        _state!._selectedIndex = val.clamp(0, _state!._flatNodes.length - 1);
      }
    } else {
      if (_flatNodes.isNotEmpty) {
        _selectedIndex = val.clamp(0, _flatNodes.length - 1);
      }
    }
  }

  /// The scroll offset of the tree.
  int get scrollOffset =>
      _state != null ? _state!._scrollOffset : _scrollOffset;

  /// Sets the scroll offset of the tree.
  set scrollOffset(int val) {
    if (_state != null) {
      _state!._scrollOffset = val;
    } else {
      _scrollOffset = val;
    }
  }

  /// The list of visible flattened nodes in the tree.
  List<FlatNode<T>> get flatNodes =>
      _state != null ? _state!._flatNodes : _flatNodes;

  void _updateFlatNodes() {
    if (_state != null) {
      _state!._flatNodes = [];
      _flatten(root, 0, [], true, _state!._flatNodes);
    } else {
      _flatNodes = [];
      _flatten(root, 0, [], true, _flatNodes);
    }
  }

  void _flatten(
    TreeNode<T> node,
    int depth,
    List<bool> ancestorIsLast,
    bool isLast,
    List<FlatNode<T>> target,
  ) {
    final nextAncestorIsLast = List<bool>.from(ancestorIsLast);
    if (depth > 0) {
      nextAncestorIsLast.add(isLast);
    }

    if (depth > 0 || showRoot) {
      target.add(
        FlatNode(node: node, depth: depth, ancestorIsLast: nextAncestorIsLast),
      );
    }

    if (node.isExpanded && !node.isLeaf) {
      for (var i = 0; i < node.children.length; i++) {
        final child = node.children[i];
        final isLastChild = i == node.children.length - 1;
        _flatten(child, depth + 1, nextAncestorIsLast, isLastChild, target);
      }
    }
  }

  // ignore: must_be_immutable
  TreeWidgetState<T>? _state;

  @override
  bool handleKeyEvent(term.KeyEvent event) {
    if (_state != null) {
      return _state!.handleKeyEvent(event);
    }
    return _handleKeyEventInternal(event);
  }

  bool _handleKeyEventInternal(term.KeyEvent event) {
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
          _updateFlatNodes();
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
        _updateFlatNodes();
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
      if (onSelect != null) {
        onSelect!(nodes[selectedIndex].node);
      }
      handled = true;
    }

    return handled;
  }

  @override
  State<TreeWidget<T>> createState() {
    final state = TreeWidgetState<T>();
    _state = state;
    return state;
  }
}

/// The state for a [TreeWidget] widget.
class TreeWidgetState<T> extends State<TreeWidget<T>>
    implements KeyEventHandler {
  late FocusNode _focusNode;
  late List<FlatNode<T>> _flatNodes;
  int _selectedIndex = 0;
  int _scrollOffset = 0;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget._selectedIndex;
    _scrollOffset = widget._scrollOffset;
    widget._state = this;
    widget._updateFlatNodes();
    _focusNode = FocusNode(id: 'tree_${widget.hashCode}');
    if (widget.focused) {
      scheduleMicrotask(() {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(TreeWidget<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget._state = this;
    if (widget.focused != oldWidget.focused) {
      if (widget.focused) {
        _focusNode.requestFocus();
      } else {
        _focusNode.unfocus();
      }
    }
  }

  @override
  void dispose() {
    if (widget._state == this) {
      widget._state = null;
    }
    _focusNode.dispose();
    super.dispose();
  }

  @override
  bool handleKeyEvent(term.KeyEvent event) {
    final handled = widget._handleKeyEventInternal(event);
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
        widget.focused = hasFocus;
        setState(() {});
      },
      onKeyEvent: (event) {
        return handleKeyEvent(event);
      },
      child: _TreeWidgetRenderWidget(
        widget: widget,
        focused: _focusNode.hasFocus || widget.focused,
      ),
    );
  }
}

class _TreeWidgetRenderWidget extends Widget {
  final TreeWidget widget;
  final bool focused;

  const _TreeWidgetRenderWidget({required this.widget, required this.focused});

  @override
  Element createElement() => _TreeWidgetElement(this);
}

class _TreeWidgetElement extends Element {
  _TreeWidgetElement(_TreeWidgetRenderWidget super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final wWidget = widget as _TreeWidgetRenderWidget;
    wWidget.widget._updateFlatNodes();
    final w = constraints.maxWidth == BoxConstraints.infinity
        ? 20
        : constraints.maxWidth;
    final h = constraints.maxHeight == BoxConstraints.infinity
        ? wWidget.widget.flatNodes.length
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

    tWidget._updateFlatNodes();
    tWidget.adjustScroll(size.height);

    final activeSelectedStyle = wWidget.focused
        ? tWidget.selectedStyle
        : Style(
            foreground: tWidget.selectedStyle.foreground,
            background: CharmColors.char,
            modifiers: tWidget.selectedStyle.modifiers,
          );

    final nodes = tWidget.flatNodes;
    final scrollOffsetVal = tWidget.scrollOffset;
    final selIdx = tWidget.selectedIndex;

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

/// Extension to manage scroll offsets for [TreeWidget].
extension TreeWidgetScrollExtension on TreeWidget {
  /// Adjusts the scroll offset to keep the selected item visible.
  void adjustScroll(int viewportHeight) {
    final nodes = flatNodes;
    if (nodes.isEmpty || viewportHeight <= 0) return;
    selectedIndex = selectedIndex.clamp(0, nodes.length - 1);

    if (selectedIndex < scrollOffset) {
      scrollOffset = selectedIndex;
    } else if (selectedIndex >= scrollOffset + viewportHeight) {
      scrollOffset = selectedIndex - viewportHeight + 1;
    }
    scrollOffset = scrollOffset.clamp(
      0,
      (nodes.length - viewportHeight).clamp(0, nodes.length),
    );
  }
}
