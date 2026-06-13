import 'package:characters/characters.dart';
import '../buffer.dart';
import '../style.dart';
import '../layout.dart';
import '../event.dart' hide Modifier;
import '../color.dart';
import '../../terminal/terminal.dart' as term;
import 'prompt_runner.dart';

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

  /// Creates a [FlatNode] indicating the [node]'s layout [depth] and [ancestorIsLast] info.
  FlatNode({
    required this.node,
    required this.depth,
    required this.ancestorIsLast,
  });
}

/// An interactive, scrollable tree widget that displays hierarchical node trees.
///
/// It supports custom styles for selected, unselected, and branch connector
/// guide lines.
///
/// ### Keyboard Navigation
/// - **Up Arrow / Down Arrow**: Swaps the selected active node upward or downward
///   in the flattened tree list.
/// - **Right Arrow**:
///   - If the active node is a folder and is collapsed, expands it.
///   - If the active node is already expanded, moves selection down to its first child.
/// - **Left Arrow**:
///   - If the active node is an expanded folder, collapses it.
///   - If the active node is collapsed or a leaf node, shifts selection back
///     to its parent folder.
/// - **Space / Enter**: Triggers the [onSelect] callback with the active node.
///
/// ### Example Usage
///
/// ```dart
/// final rootNode = TreeNode(
///   label: 'Root',
///   value: 'root_val',
///   children: [
///     TreeNode(label: 'Child A', value: 'a_val'),
///     TreeNode(
///       label: 'Child B (Folder)',
///       value: 'b_val',
///       children: [
///         TreeNode(label: 'Leaf B1', value: 'b1_val'),
///       ],
///     ),
///   ],
/// );
///
/// TreeWidget(
///   root: rootNode,
///   onSelect: (node) {
///     print('Node chosen: ${node.value}');
///   },
/// );
/// ```
///
/// ### Properties and Settings
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `root` | [TreeNode] | The top-level root node of the tree hierarchy. |
/// | `onSelect` | `Function(TreeNode)` | Callback executed when a node is activated. |
/// | `selectedStyle` | [Style] | Style applied to the active selected node line. |
/// | `unselectedStyle`| [Style] | Style applied to unselected node labels. |
/// | `lineStyle` | [Style] | Style applied to vertical/horizontal guide lines. |
/// | `showRoot` | [bool] | Whether to display the root node in the tree list. |
/// | `focused` | [bool] | Whether this widget currently has focus. |
class TreeWidget<T> extends Widget implements Focusable, KeyEventHandler {
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
  int get selectedIndex => _selectedIndex;

  /// Sets the index of the currently selected node and clamps it to valid bounds.
  set selectedIndex(int val) {
    if (_flatNodes.isNotEmpty) {
      _selectedIndex = val.clamp(0, _flatNodes.length - 1);
    }
  }

  /// The list of visible flattened nodes in the tree.
  List<FlatNode<T>> get flatNodes => _flatNodes;

  void _updateFlatNodes() {
    _flatNodes = [];
    _flatten(root, 0, [], true);
  }

  void _flatten(
    TreeNode<T> node,
    int depth,
    List<bool> ancestorIsLast,
    bool isLast,
  ) {
    final nextAncestorIsLast = List<bool>.from(ancestorIsLast);
    if (depth > 0) {
      nextAncestorIsLast.add(isLast);
    }

    if (depth > 0 || showRoot) {
      _flatNodes.add(
        FlatNode(node: node, depth: depth, ancestorIsLast: nextAncestorIsLast),
      );
    }

    if (node.isExpanded && !node.isLeaf) {
      for (var i = 0; i < node.children.length; i++) {
        final child = node.children[i];
        final isLastChild = i == node.children.length - 1;
        _flatten(child, depth + 1, nextAncestorIsLast, isLastChild);
      }
    }
  }

  /// Handles incoming key events for navigation and selection.
  @override
  bool handleKeyEvent(term.KeyEvent event) {
    if (_flatNodes.isEmpty) return false;

    if (event.type == KeyType.up) {
      _selectedIndex = (_selectedIndex - 1).clamp(0, _flatNodes.length - 1);
      return true;
    } else if (event.type == KeyType.down) {
      _selectedIndex = (_selectedIndex + 1).clamp(0, _flatNodes.length - 1);
      return true;
    } else if (event.type == KeyType.right) {
      final flat = _flatNodes[_selectedIndex];
      if (!flat.node.isLeaf) {
        if (!flat.node.isExpanded) {
          flat.node.isExpanded = true;
          _updateFlatNodes();
        } else {
          if (_selectedIndex < _flatNodes.length - 1) {
            _selectedIndex++;
          }
        }
      }
      return true;
    } else if (event.type == KeyType.left) {
      final flat = _flatNodes[_selectedIndex];
      if (!flat.node.isLeaf && flat.node.isExpanded) {
        flat.node.isExpanded = false;
        _updateFlatNodes();
      } else {
        final parent = flat.node.parent;
        if (parent != null) {
          final parentIdx = _flatNodes.indexWhere((f) => f.node == parent);
          if (parentIdx != -1) {
            _selectedIndex = parentIdx;
          }
        }
      }
      return true;
    } else if (event.key == ' ' || event.type == KeyType.enter) {
      if (onSelect != null) {
        onSelect!(_flatNodes[_selectedIndex].node);
      }
      return true;
    }
    return false;
  }

  /// Adjusts the scroll offset to keep the selected item visible within the [viewportHeight].
  void adjustScroll(int viewportHeight) {
    if (_flatNodes.isEmpty || viewportHeight <= 0) return;
    _selectedIndex = _selectedIndex.clamp(0, _flatNodes.length - 1);

    if (_selectedIndex < _scrollOffset) {
      _scrollOffset = _selectedIndex;
    } else if (_selectedIndex >= _scrollOffset + viewportHeight) {
      _scrollOffset = _selectedIndex - viewportHeight + 1;
    }
    _scrollOffset = _scrollOffset.clamp(
      0,
      (_flatNodes.length - viewportHeight).clamp(0, _flatNodes.length),
    );
  }

  @override
  void render(Buffer buffer, Rect area) {
    _updateFlatNodes();
    adjustScroll(area.height);

    final activeSelectedStyle = focused
        ? selectedStyle
        : Style(
            foreground: selectedStyle.foreground,
            background: CharmColors.char,
            modifiers: selectedStyle.modifiers,
          );

    for (var i = 0; i < area.height; i++) {
      final nodeIdx = _scrollOffset + i;
      if (nodeIdx >= _flatNodes.length) break;

      final flat = _flatNodes[nodeIdx];
      final isSelected = nodeIdx == _selectedIndex;

      var x = 0;

      // 1. Ancestor guide lines
      for (var depthIdx = 0; depthIdx < flat.depth - 1; depthIdx++) {
        if (x >= area.width) break;
        final isLast = flat.ancestorIsLast[depthIdx];
        final part = isLast ? '   ' : '│  ';
        buffer.writeString(
          area.x + x,
          area.y + i,
          part,
          isSelected ? activeSelectedStyle : lineStyle,
        );
        x += 3;
      }

      // 2. Active node guide line
      if (flat.depth > 0 && x < area.width) {
        final isLast = flat.ancestorIsLast.last;
        final part = isLast ? '└── ' : '├── ';
        buffer.writeString(
          area.x + x,
          area.y + i,
          part,
          isSelected ? activeSelectedStyle : lineStyle,
        );
        x += 4;
      }

      // 3. Expander indicator
      if (x < area.width) {
        final indicator = flat.node.isLeaf
            ? '  '
            : (flat.node.isExpanded ? '▼ ' : '▶ ');
        buffer.writeString(
          area.x + x,
          area.y + i,
          indicator,
          isSelected ? activeSelectedStyle : lineStyle,
        );
        x += 2;
      }

      // 4. Label
      final remainingWidth = area.width - x;
      if (remainingWidth > 0) {
        final labelChars = flat.node.label.characters;
        final labelText = labelChars.length > remainingWidth
            ? labelChars.take(remainingWidth).toString()
            : labelChars.toString() +
                  (' ' * (remainingWidth - labelChars.length));
        buffer.writeString(
          area.x + x,
          area.y + i,
          labelText,
          isSelected ? activeSelectedStyle : unselectedStyle,
        );
      }
    }
  }
}
