import 'dart:async';
import '../layout.dart';
import '../window.dart';

/// A widget that manages a [FocusNode] to allow keyboard focus tracking and traversal in the widget tree.
///
/// Automatically mounts the supplied [focusNode] to the closest ancestor focus scope
/// on [State.didChangeDependencies] and unmounts it on [State.dispose] to ensure the keyboard focus tree
/// stays synchronized with the layout.
///
/// ### Example
/// ```dart
/// final node = FocusNode();
/// Focus(
///   focusNode: node,
///   autofocus: true,
///   child: MyInputWidget(),
/// )
/// ```
class Focus extends StatefulWidget {
  /// The child subtree that this focus widget hosts.
  final Widget child;

  /// The focus node that represents the focus handle.
  final FocusNode focusNode;

  /// Whether this focus node should automatically request focus when mounted.
  final bool autofocus;

  /// Creates a new [Focus] widget.
  const Focus({
    required this.child,
    required this.focusNode,
    this.autofocus = false,
  });

  @override
  State createState() => FocusState();

  /// Finds the nearest ancestor [FocusNode] in the widget tree.
  static FocusNode? of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_FocusScopeWidget>();
    return scope?.focusNode;
  }
}

/// The state for a [Focus] widget.
class FocusState extends State<Focus> {
  FocusNode? _parentRegistration;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final parentNode = Focus.of(context);
    if (_parentRegistration != parentNode) {
      _parentRegistration?.children.remove(widget.focusNode);
      widget.focusNode.parent = parentNode;
      parentNode?.addChild(widget.focusNode);
      _parentRegistration = parentNode;
    }
  }

  @override
  void dispose() {
    _parentRegistration?.children.remove(widget.focusNode);
    widget.focusNode.parent = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.autofocus && !widget.focusNode.isFocused) {
      scheduleMicrotask(() {
        if (mounted) {
          widget.focusNode.requestFocus();
        }
      });
    }
    return _FocusScopeWidget(focusNode: widget.focusNode, child: widget.child);
  }
}

class _FocusScopeWidget extends InheritedWidget {
  final FocusNode focusNode;

  const _FocusScopeWidget({required this.focusNode, required super.child});

  @override
  bool updateShouldNotify(_FocusScopeWidget oldWidget) =>
      focusNode != oldWidget.focusNode;
}
