import 'dart:async';
import 'dart:math';
import 'package:termui/termui.dart';

/// Undocumented public member.
abstract class Element implements BuildContext {
  @override
  /// The widget that this element represents.
  Widget widget;

  /// The parent element in the widget tree.
  Element? parent;

  BoxConstraints? _cachedConstraints;
  Size? _cachedSize;

  /// The cached local position assigned by the parent during layout.
  Offset relativeOffset = Offset.zero;

  /// The cached constraints from the last layout pass.
  BoxConstraints? get constraints => _cachedConstraints;

  /// The resolved size of the element from the last layout pass.
  Size get size => _cachedSize ?? Size.zero;

  bool _mounted = false;

  /// Whether this element is currently mounted in the tree.
  bool get mounted => _mounted;

  /// Undocumented public member.
  int treeDepth = 0;

  /// The depth of this element in the widget tree.
  int get depth => treeDepth;
  set depth(int value) => treeDepth = value;

  /// Undocumented public member.
  bool isDirty = false;

  BuildOwner? _owner;

  /// The BuildOwner managing this element, resolving up the parent chain.
  BuildOwner? get owner => _owner ?? parent?.owner;
  set owner(BuildOwner? value) => _owner = value;

  int? _rebuildTraceId;

  /// Cached tracer ID for rebuilding this element.
  int get rebuildTraceId => _rebuildTraceId ??= Tracer.registerString(
    '${widget.runtimeType}:rebuild',
  );

  int? _paintTraceId;

  /// Cached tracer ID for painting this element.
  int get paintTraceId =>
      _paintTraceId ??= Tracer.registerString('${widget.runtimeType}:paint');

  int? _layoutTraceId;

  /// Cached tracer ID for layout of this element.
  int get layoutTraceId =>
      _layoutTraceId ??= Tracer.registerString('${widget.runtimeType}:layout');

  /// Creates an element that uses the given [widget] as its configuration.
  Element(this.widget);

  /// Adds this element to the tree as a child of [parent].
  void mount(Element? parent) {
    this.parent = parent;
    if (parent != null) {
      _owner = parent.owner;
    }
    treeDepth = parent != null ? parent.treeDepth + 1 : 0;
    _mounted = true;
    final k = widget.key;
    // Skip GlobalKey registration if we are measuring intrinsics in a temporary
    // subtree. Registering here would overwrite the real active element's key
    // mapping and prematurely remove it from the registry during unmount.
    if (k is GlobalKey && Zone.current[#isMeasuringIntrinsics] != true) {
      GlobalKey.registry[k] = this;
    }
  }

  /// Marks this element as needing a build.
  void markNeedsBuild() {
    final activeOwner = owner;
    if (activeOwner != null) {
      activeOwner.scheduleBuildFor(this);
    } else {
      performRebuild();
    }
  }

  /// Removes this element from the tree.
  void unmount() {
    final k = widget.key;
    if (k is GlobalKey && GlobalKey.registry[k] == this) {
      GlobalKey.registry.remove(k);
    }
    _mounted = false;
    parent = null;
  }

  /// Updates this element to use a new [Widget] configuration.
  void update(Widget newWidget) {
    widget = newWidget;
    _rebuildTraceId = null;
    _paintTraceId = null;
  }

  /// Performs the actual rebuild and clears the dirty flag.
  void performRebuild() {
    isDirty = false;
    final isTracing =
        Tracer.isEnabled &&
        Tracer.activeCategories.contains(TraceCategory.build);
    Map<String, String>? meta;
    if (isTracing) {
      Tracer.record(
        rebuildTraceId,
        Phase.begin,
        TraceCategory.build,
        metadata: meta,
      );
    }
    try {
      rebuild();
    } finally {
      if (isTracing) {
        Tracer.record(
          rebuildTraceId,
          Phase.end,
          TraceCategory.build,
          metadata: meta,
        );
      }
    }
  }

  /// Calculates the size of the element based on the given constraints.
  Size layout(BoxConstraints constraints) {
    final isTracing =
        Tracer.isEnabled &&
        Tracer.activeCategories.contains(TraceCategory.build);
    if (isTracing) {
      Tracer.record(
        layoutTraceId,
        Phase.begin,
        TraceCategory.build,
        metadata: null,
      );
    }
    try {
      _cachedConstraints = constraints;
      final resolvedSize = performLayout(constraints);
      _cachedSize = constraints.constrain(resolvedSize);
      return _cachedSize!;
    } finally {
      if (isTracing) {
        Tracer.record(layoutTraceId, Phase.end, TraceCategory.build);
      }
    }
  }

  /// Hook for subclasses to perform layout within the given constraints.
  Size performLayout(BoxConstraints constraints) {
    final width = constraints.maxWidth == BoxConstraints.infinity
        ? 0
        : constraints.maxWidth;
    final height = widget.getIntrinsicHeight(width);
    return constraints.constrain(Size(width, height));
  }

  /// Custom metadata for paint tracing.
  Map<String, String>? get paintTraceMetadata => null;

  /// Hook for subclasses to implement actual painting.
  void performPaint(Buffer buffer, Offset offset) {}

  /// Paints the element and records tracing metrics.
  void paint(Buffer buffer, Offset offset) {
    final isTracing =
        Tracer.isEnabled &&
        Tracer.activeCategories.contains(TraceCategory.paint);
    if (isTracing) {
      final customMeta = paintTraceMetadata;
      final meta = customMeta;
      Tracer.record(
        paintTraceId,
        Phase.begin,
        TraceCategory.paint,
        metadata: meta,
      );
      try {
        performPaint(buffer, offset);
      } finally {
        Tracer.record(
          paintTraceId,
          Phase.end,
          TraceCategory.paint,
          metadata: meta,
        );
      }
    } else {
      performPaint(buffer, offset);
    }
  }

  /// Invokes [visitor] on each child element of this node.
  void visitChildren(void Function(Element child) visitor) {}

  @override
  T? dependOnInheritedWidgetOfExactType<T extends InheritedWidget>() {
    var ancestor = parent;
    while (ancestor != null) {
      if (ancestor.widget is T) {
        return ancestor.widget as T;
      }
      ancestor = ancestor.parent;
    }
    return null;
  }

  /// Returns the intrinsic height of this element.
  int getIntrinsicHeight(int width) => widget.getIntrinsicHeight(width);

  /// Returns the intrinsic width of this element.
  int getIntrinsicWidth(int height) => widget.getIntrinsicWidth(height);

  /// Rebuilds the element.
  void rebuild() {}

  /// Called during hot reload to invalidate the element and trigger a rebuild.
  void reassemble() {
    markNeedsBuild();
    visitChildren((Element child) {
      child.reassemble();
    });
  }
}

/// Default element for leaf widgets that do not build children.
class LeafElement extends Element {
  /// Creates a leaf element for the given [widget].
  LeafElement(super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final width = constraints.maxWidth == BoxConstraints.infinity
        ? 0
        : constraints.maxWidth;
    final height = widget.getIntrinsicHeight(width);
    return constraints.constrain(Size(width, height));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {}
}

/// A widget that has configuration but delegates rendering to its built child.
class StatelessElement extends Element {
  /// The element corresponding to the built child widget.
  Element? childElement;

  /// Creates a stateless element to manage a [StatelessWidget].
  StatelessElement(StatelessWidget super.widget);

  @override
  /// Adds this element to the tree and builds the child element.
  void mount(Element? parent) {
    super.mount(parent);
    rebuild();
  }

  @override
  /// Removes this element and its child from the tree.
  void unmount() {
    childElement?.unmount();
    super.unmount();
  }

  @override
  /// Rebuilds the child widget configuration and updates the child element.
  void rebuild() {
    final builtWidget = runZoned(() {
      return (widget as StatelessWidget).build(this);
    }, zoneValues: {#buildContext: this});

    if (childElement != null &&
        Widget.canUpdate(childElement!.widget, builtWidget)) {
      if (!identical(childElement!.widget, builtWidget)) {
        childElement!.update(builtWidget);
      }
    } else {
      childElement?.unmount();
      childElement = builtWidget.createElement();
      childElement!.mount(this);
    }
  }

  @override
  void update(Widget newWidget) {
    super.update(newWidget);
    rebuild();
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement != null) visitor(childElement!);
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    if (childElement != null) {
      childElement!.relativeOffset = Offset.zero;
      return childElement!.layout(constraints);
    }
    return constraints.constrain(Size.zero);
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    if (childElement != null) {
      childElement!.paint(buffer, offset + childElement!.relativeOffset);
    }
  }

  @override
  int getIntrinsicHeight(int width) =>
      childElement?.getIntrinsicHeight(width) ?? 0;

  @override
  int getIntrinsicWidth(int height) =>
      childElement?.getIntrinsicWidth(height) ?? 0;
}

/// A widget that has mutable state.
class StatefulElement extends Element {
  /// The state associated with this element.
  late final State state;

  /// The child element.
  Element? childElement;

  /// Creates a stateful element to manage a [StatefulWidget].
  StatefulElement(StatefulWidget super.widget);

  @override
  /// Adds this element to the tree, creates the state, and builds the child.
  void mount(Element? parent) {
    super.mount(parent);
    state = (widget as StatefulWidget).createState();
    state.internalWidget = widget as StatefulWidget;
    state.internalContext = this;
    state.initState();
    state.didChangeDependencies();
    rebuild();
  }

  @override
  /// Removes this element and disposes of the state.
  void unmount() {
    state.dispose();
    state.internalContext = null;
    childElement?.unmount();
    super.unmount();
  }

  @override
  /// Rebuilds the child widget configuration and updates the child element.
  void rebuild() {
    final builtWidget = runZoned(() {
      return state.build(this);
    }, zoneValues: {#buildContext: this});

    if (childElement != null &&
        Widget.canUpdate(childElement!.widget, builtWidget)) {
      if (!identical(childElement!.widget, builtWidget)) {
        childElement!.update(builtWidget);
      }
    } else {
      childElement?.unmount();
      childElement = builtWidget.createElement();
      childElement!.mount(this);
    }
  }

  @override
  /// Updates the element with a new [Widget] and triggers a state update.
  void update(Widget newWidget) {
    final oldWidget = state.widget;
    super.update(newWidget);
    state.internalWidget = newWidget as StatefulWidget;
    state.didUpdateWidget(oldWidget);
    state.didChangeDependencies();
    rebuild();
  }

  @override
  void reassemble() {
    state.reassemble();
    super.reassemble();
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement != null) visitor(childElement!);
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    if (childElement != null) {
      childElement!.relativeOffset = Offset.zero;
      return childElement!.layout(constraints);
    }
    return constraints.constrain(Size.zero);
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    if (childElement != null) {
      childElement!.paint(buffer, offset + childElement!.relativeOffset);
    }
  }

  @override
  int getIntrinsicHeight(int width) =>
      childElement?.getIntrinsicHeight(width) ?? 0;

  @override
  int getIntrinsicWidth(int height) =>
      childElement?.getIntrinsicWidth(height) ?? 0;
}

/// A widget that propagates information down the tree.
class InheritedElement extends Element {
  /// The element corresponding to the built child widget.
  Element? childElement;

  /// Creates an element to manage an [InheritedWidget].
  InheritedElement(InheritedWidget super.widget);

  @override
  /// Adds this element to the tree and builds the child element.
  void mount(Element? parent) {
    super.mount(parent);
    rebuild();
  }

  @override
  /// Rebuilds the child widget configuration and updates the child element.
  void rebuild() {
    final inheritedWidget = widget as InheritedWidget;
    if (childElement != null &&
        Widget.canUpdate(childElement!.widget, inheritedWidget.child)) {
      if (!identical(childElement!.widget, inheritedWidget.child)) {
        childElement!.update(inheritedWidget.child);
      }
    } else {
      childElement?.unmount();
      childElement = inheritedWidget.child.createElement();
      childElement!.mount(this);
    }
  }

  @override
  void update(Widget newWidget) {
    super.update(newWidget);
    rebuild();
  }

  @override
  void unmount() {
    childElement?.unmount();
    super.unmount();
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement != null) visitor(childElement!);
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    if (childElement != null) {
      childElement!.relativeOffset = Offset.zero;
      return childElement!.layout(constraints);
    }
    return constraints.constrain(Size.zero);
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    if (childElement != null) {
      childElement!.paint(buffer, offset + childElement!.relativeOffset);
    }
  }

  @override
  int getIntrinsicHeight(int width) =>
      childElement?.getIntrinsicHeight(width) ?? 0;

  @override
  int getIntrinsicWidth(int height) =>
      childElement?.getIntrinsicWidth(height) ?? 0;
}

/// How children are aligned along the cross axis.
class ElementWidgetElement extends Element {
  /// Creates a new [ElementWidgetElement].
  ElementWidgetElement(ElementWidget super.widget);

  @override
  void mount(Element? parent) {
    super.mount(parent);
    final w = widget as ElementWidget;
    w.internalElement ??= w.child.createElement();
    w.internalElement!.mount(this);
  }

  @override
  void update(Widget newWidget) {
    super.update(newWidget);
    final w = widget as ElementWidget;
    w.internalElement?.update(w.child);
  }

  @override
  void unmount() {
    final w = widget as ElementWidget;
    w.internalElement?.unmount();
    w.internalElement = null;
    super.unmount();
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    final w = widget as ElementWidget;
    if (w.internalElement != null) {
      w.internalElement!.relativeOffset = Offset.zero;
      return w.internalElement!.layout(constraints);
    }
    return Size.zero;
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final w = widget as ElementWidget;
    if (w.internalElement != null) {
      w.internalElement!.paint(
        buffer,
        offset + w.internalElement!.relativeOffset,
      );
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    final w = widget as ElementWidget;
    if (w.internalElement != null) visitor(w.internalElement!);
  }

  @override
  int getIntrinsicHeight(int width) {
    final w = widget as ElementWidget;
    return w.internalElement?.getIntrinsicHeight(width) ?? 0;
  }

  @override
  int getIntrinsicWidth(int height) {
    final w = widget as ElementWidget;
    return w.internalElement?.getIntrinsicWidth(height) ?? 0;
  }
}

/// Extension providing recursive spatial hit testing down the mounted Element tree.
extension HitTestExtension on Element {
  /// Recursively finds all elements containing the given global coordinate.
  List<Element> hitTest(
    Point<int> globalPosition, [
    Offset parentOffset = Offset.zero,
  ]) {
    final absOffset = parentOffset + relativeOffset;
    final sx = globalPosition.x - 1;
    final sy = globalPosition.y - 1;
    final inside =
        sx >= absOffset.dx &&
        sx < absOffset.dx + size.width &&
        sy >= absOffset.dy &&
        sy < absOffset.dy + size.height;
    if (!inside) return [];

    final results = <Element>[];
    visitChildren((child) {
      results.addAll(child.hitTest(globalPosition, absOffset));
    });
    results.add(this);
    return results;
  }
}

/// Manages the build lifecycle and dirty element queue.
