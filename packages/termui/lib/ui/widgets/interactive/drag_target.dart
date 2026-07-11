import 'package:termui/termui.dart';

// Dummy context to pass to the builder if calling getIntrinsicHeight/Width
class _DummyBuildContext implements BuildContext {
  @override
  Widget get widget => throw UnimplementedError();

  @override
  T? dependOnInheritedWidgetOfExactType<T extends InheritedWidget>() => null;
}

/// A wrapper widget that accepts dropped data from a Draggable.
class DragTarget<T> extends Widget {
  /// The builder function that describes the widget content based on drag hover state.
  final Widget Function(
    BuildContext context,
    List<T> candidateData,
    List<dynamic> rejectedData,
  )
  builder;

  /// Optional callback to check if a payload will be accepted.
  final bool Function(T data)? onWillAccept;

  /// Triggered when the payload is successfully dropped.
  final void Function(T data)? onAccept;

  /// Triggered when the drag leaves the target boundary.
  final void Function(T? data)? onLeave;

  /// Creates a [DragTarget] widget.
  const DragTarget({
    required this.builder,
    this.onWillAccept,
    this.onAccept,
    this.onLeave,
    super.key,
  });

  @override
  Element createElement() => DragTargetElement<T>(this);

  @override
  int getIntrinsicHeight(int width) {
    final child = builder(_DummyBuildContext(), const [], const []);
    return child.getIntrinsicHeight(width);
  }

  @override
  int getIntrinsicWidth(int height) {
    final child = builder(_DummyBuildContext(), const [], const []);
    return child.getIntrinsicWidth(height);
  }
}

/// The element that manages the candidate list and lifecycle hooks for [DragTarget].
class DragTargetElement<T> extends SingleChildElement {
  final List<T> _candidateData = [];
  final List<dynamic> _rejectedData = [];

  /// Creates a [DragTargetElement].
  DragTargetElement(DragTarget<T> super.widget);

  @override
  Widget? get childWidget =>
      (widget as DragTarget<T>).builder(this, _candidateData, _rejectedData);

  @override
  Size performLayout(BoxConstraints constraints) {
    rebuild();
    if (childElement != null) {
      return childElement!.layout(constraints);
    }
    return Size(constraints.minWidth, constraints.minHeight);
  }

  /// Handles when a drag session enters the target boundaries.
  void handleDragEnter(DragSession session) {
    final dragTarget = widget as DragTarget<T>;
    final data = session.data;
    if (data is T) {
      final castedData = data as T;
      if (dragTarget.onWillAccept == null ||
          dragTarget.onWillAccept!(castedData)) {
        _candidateData.add(castedData);
        markNeedsBuild();
      } else {
        _rejectedData.add(castedData);
      }
    } else {
      _rejectedData.add(data);
    }
  }

  /// Handles when a drag session leaves the target boundaries.
  void handleDragLeave([DragSession? session]) {
    final dragTarget = widget as DragTarget<T>;
    _candidateData.clear();
    _rejectedData.clear();
    markNeedsBuild();
    if (dragTarget.onLeave != null) {
      dragTarget.onLeave!(null);
    }
  }

  @override
  void unmount() {
    DragDropManager.unregisterTarget(this);
    super.unmount();
  }

  /// Handles drag hover coordinate updates.
  void handleDragOver(DragSession session) {
    // Optional extension hook
  }

  /// Handles the drop event.
  void handleDrop(DragSession session) {
    final dragTarget = widget as DragTarget<T>;
    final data = session.data;
    if (data is T) {
      final castedData = data as T;
      if (dragTarget.onAccept != null) {
        dragTarget.onAccept!(castedData);
      }
    }
    _candidateData.clear();
    _rejectedData.clear();
    markNeedsBuild();
  }
}
