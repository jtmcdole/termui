import 'package:termui/termui.dart';

/// Undocumented public member.
abstract class Widget {
  /// The optional key for this widget.
  final Key? key;

  /// Initializes the widget configuration.
  const Widget({this.key});

  /// Creates an [Element] to manage this widget's location in the tree.
  Element createElement() => LeafElement(this);

  /// Computes the intrinsic height of this widget under the given [width] constraint.
  int getIntrinsicHeight(int width) {
    return 1;
  }

  /// Computes the intrinsic width of this widget under the given [height] constraint.
  int getIntrinsicWidth(int height) {
    return 0;
  }
}

/// Instantiated element in the widget tree that keeps track of widget updates and state.
abstract class StatelessWidget extends Widget {
  /// Initializes a stateless widget.
  const StatelessWidget({super.key});

  /// Describes the part of the user interface represented by this widget.
  Widget build(BuildContext context);

  @override
  Element createElement() => StatelessElement(this);

  @override
  int getIntrinsicHeight(int width) {
    final rootContext = StatelessElement(this)..mount(null);
    final h = rootContext.childElement?.widget.getIntrinsicHeight(width) ?? 0;
    rootContext.unmount();
    return h;
  }
}

/// An element that manages a [StatelessWidget].
abstract class StatefulWidget extends Widget {
  /// Initializes a stateful widget.
  const StatefulWidget({super.key});

  /// Creates the mutable state for this widget at a given location in the tree.
  State createState();

  @override
  Element createElement() => StatefulElement(this);

  @override
  int getIntrinsicHeight(int width) {
    final rootContext = StatefulElement(this)..mount(null);
    final h = rootContext.childElement?.widget.getIntrinsicHeight(width) ?? 0;
    rootContext.unmount();
    return h;
  }
}

/// Signature for callbacks that take no arguments and return no data.
typedef VoidCallback = void Function();

/// The logic and internal state for a [StatefulWidget].
abstract class State<T extends StatefulWidget> {
  /// Undocumented public member.
  T? internalWidget;

  /// The current configuration.
  T get widget => internalWidget!;

  /// Undocumented public member.
  BuildContext? internalContext;

  /// The location in the tree where this widget builds.
  BuildContext get context => internalContext!;

  /// Whether this [State] object is currently in a tree.
  bool get mounted => internalContext != null;

  /// Called when this object is inserted into the tree.
  void initState() {}

  /// Called when a dependency of this [State] object changes.
  void didChangeDependencies() {}

  /// Called whenever the widget configuration changes.
  void didUpdateWidget(covariant T oldWidget) {}

  /// Called when this object is removed from the tree permanently.
  void dispose() {}

  /// Notifies the framework that the internal state of this object has changed.
  void setState(VoidCallback fn) {
    fn();
    if (internalContext != null) {
      (internalContext as Element).markNeedsBuild();
    }
  }

  /// Describes the part of the user interface represented by this widget.
  Widget build(BuildContext context);
}

/// An element that manages a [StatefulWidget] and its [State].
abstract class InheritedWidget extends Widget {
  /// The widget below this widget in the tree.
  final Widget child;

  /// Initializes an inherited widget with the given [child].
  const InheritedWidget({required this.child});

  @override
  Element createElement() => InheritedElement(this);

  @override
  int getIntrinsicHeight(int width) {
    return child.getIntrinsicHeight(width);
  }

  /// Whether the framework should notify widgets that inherit from this widget.
  bool updateShouldNotify(covariant InheritedWidget oldWidget);
}

/// An element that manages an [InheritedWidget].
class ElementWidget extends Widget {
  static final int _tracePaintId = Tracer.registerString('ElementWidget:paint');

  /// The child widget.
  final Widget child;

  /// Undocumented public member.
  Element? internalElement;

  /// Creates an element widget bridging the tree.
  ElementWidget(this.child);

  /// The root element of the embedded tree.
  Element? get element => internalElement;

  @override
  Element createElement() => ElementWidgetElement(this);

  /// Resolves the layout of the embedded widget tree.
  void layout(BoxConstraints constraints, [BuildOwner? owner]) {
    if (internalElement == null) {
      internalElement = child.createElement();
      if (owner != null) {
        internalElement!.owner = owner;
      }
      internalElement!.mount(null);
    } else {
      internalElement!.update(child);
    }
    internalElement!.layout(constraints);
  }

  /// Paints the embedded widget tree.
  void paint(Buffer buffer, Offset offset) {
    Tracer.record(_tracePaintId, Phase.begin, TraceCategory.paint);
    try {
      internalElement?.paint(buffer, offset);
    } finally {
      Tracer.record(_tracePaintId, Phase.end, TraceCategory.paint);
    }
  }

  /// Finds a State of type S inside this widget's element tree.
  S? findState<S extends State>() {
    if (internalElement == null) return null;
    return _findStateRecursive<S>(internalElement!);
  }

  static S? _findStateRecursive<S extends State>(Element el) {
    if (el is StatefulElement) {
      if (el.state is S) {
        return el.state as S;
      }
    }
    S? found;
    el.visitChildren((child) {
      if (found != null) return;
      final res = _findStateRecursive<S>(child);
      if (res != null) {
        found = res;
      }
    });
    return found;
  }
}

/// Element for [ElementWidget] that delegates layout, painting, and child lifecycle management.
