import 'dart:async';
import 'package:termui/termui.dart';

/// A widget that manages a [FocusNode] to allow keyboard focus tracking and traversal in the widget tree.
class Focus extends StatefulWidget {
  /// The child subtree that this focus widget hosts.
  final Widget child;

  /// The focus node that represents the focus handle.
  final FocusNode? focusNode;

  /// Whether this focus node should automatically request focus when mounted.
  final bool autofocus;

  /// Callback executed when a key event hits this node.
  final bool Function(KeyEvent event)? onKeyEvent;

  /// Callback executed when this focus node gains or loses focus.
  final void Function(bool hasFocus)? onFocusChange;

  /// Creates a new [Focus] widget.
  const Focus({
    super.key,
    required this.child,
    this.focusNode,
    this.autofocus = false,
    this.onKeyEvent,
    this.onFocusChange,
  });

  @override
  State<Focus> createState() => FocusState();

  /// Finds the nearest ancestor [FocusNode] in the widget tree.
  static FocusNode? of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<FocusMarker>();
    return scope?.focusNode;
  }
}

/// The state for a [Focus] widget.
class FocusState extends State<Focus> {
  late FocusNode _focusNode;

  /// The underlying [FocusNode] managed by this state.
  FocusNode get focusNode => _focusNode;

  /// Factory method to construct the appropriate [FocusNode] instance.
  FocusNode createFocusNode() {
    return FocusNode(id: 'focus_${widget.hashCode}');
  }

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? createFocusNode();
    _updateNodeProperties();
    if (widget.autofocus) {
      // Trigger requestFocus during the next microtask queue
      scheduleMicrotask(() {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final parentScope = Focus.of(context);
    if (_focusNode.parent != parentScope) {
      _focusNode.parent?.children.remove(_focusNode);
      _focusNode.parent = null;
      if (parentScope != null) {
        parentScope.addChild(_focusNode);
      }
    }
  }

  @override
  void didUpdateWidget(Focus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode) {
      final hadPrimaryFocus = FocusManager.instance.primaryFocus == _focusNode;
      _focusNode.dispose();
      _focusNode = widget.focusNode ?? createFocusNode();
      _updateNodeProperties();
      final parentScope = Focus.of(context);
      if (parentScope != null) {
        parentScope.addChild(_focusNode);
      }
      if (hadPrimaryFocus) {
        _focusNode.requestFocus();
      }
    } else {
      _updateNodeProperties();
    }
  }

  void _updateNodeProperties() {
    _focusNode.onKeyEvent = widget.onKeyEvent;
    _focusNode.onFocusChange = widget.onFocusChange;
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FocusMarker(focusNode: _focusNode, child: widget.child);
  }
}

/// A specialized widget to manage focus navigation traversal.
class FocusScope extends Focus {
  /// Creates a new [FocusScope] widget.
  const FocusScope({
    super.key,
    required super.child,
    super.focusNode,
    super.autofocus,
    super.onKeyEvent,
    super.onFocusChange,
  });

  @override
  State<Focus> createState() => FocusScopeState();

  /// Walks up Context to obtain the closest FocusScopeNode.
  static FocusScopeNode? of(BuildContext context) {
    final marker = context.dependOnInheritedWidgetOfExactType<FocusMarker>();
    var node = marker?.focusNode;
    while (node != null) {
      if (node is FocusScopeNode) return node;
      node = node.parent;
    }
    return null;
  }
}

/// The state for a [FocusScope] widget.
class FocusScopeState extends FocusState {
  @override
  FocusNode createFocusNode() {
    return FocusScopeNode(id: 'scope_${widget.hashCode}');
  }
}

/// An InheritedWidget to propagate [FocusNode] down the BuildContext hierarchy.
class FocusMarker extends InheritedWidget {
  /// The [FocusNode] to propagate down the tree.
  final FocusNode focusNode;

  /// Creates a new [FocusMarker].
  const FocusMarker({required this.focusNode, required super.child});

  @override
  bool updateShouldNotify(FocusMarker oldWidget) =>
      focusNode != oldWidget.focusNode;
}
