import 'dart:async';
import 'dart:math';
import 'package:characters/characters.dart';
import 'buffer.dart';
import 'style.dart';

/// A 2D rectangle representing bounds in terminal space.
class Rect {
  /// The horizontal x-coordinate of the rectangle's top-left corner.
  final int x;

  /// The vertical y-coordinate of the rectangle's top-left corner.
  final int y;

  /// The width of the rectangle.
  final int width;

  /// The height of the rectangle.
  final int height;

  /// Creates a new [Rect] with the specified [x], [y], [width], and [height].
  const Rect(this.x, this.y, this.width, this.height);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Rect &&
          x == other.x &&
          y == other.y &&
          width == other.width &&
          height == other.height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() => 'Rect($x, $y, $width, $height)';
}

/// An immutable set of offsets in each of the four cardinal directions in terminal space.
class EdgeInsets {
  /// The left edge offset.
  final int left;

  /// The top edge offset.
  final int top;

  /// The right edge offset.
  final int right;

  /// The bottom edge offset.
  final int bottom;

  /// Creates insets from specific [left], [top], [right], and [bottom] offsets.
  const EdgeInsets.fromLTRB(this.left, this.top, this.right, this.bottom);

  /// Creates insets where all edges have the same [value].
  const EdgeInsets.all(int value)
    : left = value,
      top = value,
      right = value,
      bottom = value;

  /// Creates insets with symmetrical [vertical] and [horizontal] offsets.
  const EdgeInsets.symmetric({int vertical = 0, int horizontal = 0})
    : left = horizontal,
      top = vertical,
      right = horizontal,
      bottom = vertical;

  /// Creates insets with only the specified edges provided.
  const EdgeInsets.only({
    this.left = 0,
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
  });

  /// An [EdgeInsets] with zero offsets for all edges.
  static const EdgeInsets zero = EdgeInsets.only();
}

/// Abstract base class for all layout constraints.
class Constraint {
  /// Creates a new constraint.
  const Constraint();
}

/// A fixed length layout constraint.
class LengthConstraint extends Constraint {
  /// The fixed layout length.
  final int length;

  /// Creates a constraint with a fixed [length].
  const LengthConstraint(this.length);
}

/// A percentage-based layout constraint relative to parent size.
class PercentageConstraint extends Constraint {
  /// The percentage of the parent size (0 to 100).
  final int percentage;

  /// Creates a constraint based on a [percentage] of the parent size.
  const PercentageConstraint(this.percentage);
}

/// A proportional flexible space constraint.
class FlexConstraint extends Constraint {
  /// The flex factor to determine the proportional size.
  final int flex;

  /// Creates a constraint with the specified [flex] factor.
  const FlexConstraint(this.flex);
}

/// A constraint with min and max bounds.
class MinMaxConstraint extends Constraint {
  /// The minimum size bound.
  final int min;

  /// The maximum size bound.
  final int max;

  /// Creates a constraint with the specified [min] and [max] bounds.
  const MinMaxConstraint({this.min = 0, this.max = 999999});
}

/// A handle to a location in the widget tree.
abstract class BuildContext {
  /// The widget associated with this context.
  Widget get widget;

  /// Obtains the nearest inherited widget of the given type [T].
  T? dependOnInheritedWidgetOfExactType<T extends InheritedWidget>();

  /// Accesses the active build context from the current Zone.
  static BuildContext? get current =>
      Zone.current[#buildContext] as BuildContext?;
}

/// Abstract base class for all renderable widgets.
abstract class Widget {
  /// Initializes the widget configuration.
  const Widget();

  /// Creates an [Element] to manage this widget's location in the tree.
  Element createElement() => LeafElement(this);

  /// Renders the widget onto the provided [buffer] within the specified [area].
  void render(Buffer buffer, Rect area);
}

/// Instantiated element in the widget tree that keeps track of widget updates and state.
abstract class Element implements BuildContext {
  @override
  /// The widget that this element represents.
  Widget widget;

  /// The parent element in the widget tree.
  Element? parent;

  /// Creates an element that uses the given [widget] as its configuration.
  Element(this.widget);

  /// Adds this element to the tree as a child of [parent].
  void mount(Element? parent) {
    this.parent = parent;
  }

  /// Removes this element from the tree.
  void unmount() {
    parent = null;
  }

  /// Updates this element to use a new [Widget] configuration.
  void update(Widget newWidget) {
    widget = newWidget;
  }

  /// Renders the underlying widget to the provided [buffer] within the [area].
  void render(Buffer buffer, Rect area);

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
}

/// Default element for leaf widgets that do not build children.
class LeafElement extends Element {
  /// Creates a leaf element for the given [widget].
  LeafElement(super.widget);

  @override
  void render(Buffer buffer, Rect area) {
    runZoned(() {
      widget.render(buffer, area);
    }, zoneValues: {#buildContext: this});
  }
}

/// A widget that has configuration but delegates rendering to its built child.
abstract class StatelessWidget extends Widget {
  /// Initializes a stateless widget.
  const StatelessWidget();

  /// Describes the part of the user interface represented by this widget.
  Widget build(BuildContext context);

  @override
  Element createElement() => StatelessElement(this);

  @override
  void render(Buffer buffer, Rect area) {
    // Statelessly build and render child directly if called outside of an active element tree.
    final rootContext = StatelessElement(this)..mount(null);
    rootContext.render(buffer, area);
  }
}

/// An element that manages a [StatelessWidget].
class StatelessElement extends Element {
  /// The element corresponding to the built child widget.
  Element? childElement;

  /// Creates a stateless element to manage a [StatelessWidget].
  StatelessElement(StatelessWidget super.widget);

  @override
  /// Adds this element to the tree and builds the child element.
  void mount(Element? parent) {
    this.parent = parent;
    rebuild();
  }

  @override
  /// Removes this element and its child from the tree.
  void unmount() {
    childElement?.unmount();
    super.unmount();
  }

  /// Rebuilds the child widget configuration and updates the child element.
  void rebuild() {
    final builtWidget = runZoned(() {
      return (widget as StatelessWidget).build(this);
    }, zoneValues: {#buildContext: this});

    if (childElement != null &&
        childElement!.widget.runtimeType == builtWidget.runtimeType) {
      childElement!.update(builtWidget);
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
  void render(Buffer buffer, Rect area) {
    runZoned(() {
      childElement?.render(buffer, area);
    }, zoneValues: {#buildContext: this});
  }
}

/// A widget that has mutable state.
abstract class StatefulWidget extends Widget {
  /// Initializes a stateful widget.
  const StatefulWidget();

  /// Creates the mutable state for this widget at a given location in the tree.
  State createState();

  @override
  Element createElement() => StatefulElement(this);

  @override
  void render(Buffer buffer, Rect area) {
    // Lazily run stateful loop if rendered without app container.
    final rootContext = StatefulElement(this)..mount(null);
    rootContext.render(buffer, area);
  }
}

/// Signature for callbacks that take no arguments and return no data.
typedef VoidCallback = void Function();

/// The logic and internal state for a [StatefulWidget].
abstract class State<T extends StatefulWidget> {
  T? _widget;

  /// The current configuration.
  T get widget => _widget!;

  BuildContext? _context;

  /// The location in the tree where this widget builds.
  BuildContext get context => _context!;

  /// Whether this [State] object is currently in a tree.
  bool get mounted => _context != null;

  /// Optional callback invoked when the tree needs repainting.
  static VoidCallback? onNeedRepaint;

  /// Called when this object is inserted into the tree.
  void initState() {}

  /// Called when a dependency of this [State] object changes.
  void didChangeDependencies() {}

  /// Called when this object is removed from the tree permanently.
  void dispose() {}

  /// Notifies the framework that the internal state of this object has changed.
  void setState(VoidCallback fn) {
    fn();
    (_context as StatefulElement).rebuild();
    if (onNeedRepaint != null) {
      onNeedRepaint!();
    }
  }

  /// Describes the part of the user interface represented by this widget.
  Widget build(BuildContext context);
}

/// An element that manages a [StatefulWidget] and its [State].
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
    this.parent = parent;
    state = (widget as StatefulWidget).createState();
    state._widget = widget as StatefulWidget;
    state._context = this;
    state.initState();
    state.didChangeDependencies();
    rebuild();
  }

  @override
  /// Removes this element and disposes of the state.
  void unmount() {
    state.dispose();
    state._context = null;
    childElement?.unmount();
    super.unmount();
  }

  /// Rebuilds the child widget configuration and updates the child element.
  void rebuild() {
    final builtWidget = runZoned(() {
      return state.build(this);
    }, zoneValues: {#buildContext: this});

    if (childElement != null &&
        childElement!.widget.runtimeType == builtWidget.runtimeType) {
      childElement!.update(builtWidget);
    } else {
      childElement?.unmount();
      childElement = builtWidget.createElement();
      childElement!.mount(this);
    }
  }

  @override
  /// Updates the element with a new [Widget] and triggers a state update.
  void update(Widget newWidget) {
    super.update(newWidget);
    state._widget = newWidget as StatefulWidget;
    state.didChangeDependencies();
    rebuild();
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement != null) visitor(childElement!);
  }

  @override
  void render(Buffer buffer, Rect area) {
    runZoned(() {
      childElement?.render(buffer, area);
    }, zoneValues: {#buildContext: this});
  }
}

/// A widget that propagates information down the tree.
abstract class InheritedWidget extends Widget {
  /// The widget below this widget in the tree.
  final Widget child;

  /// Initializes an inherited widget with the given [child].
  const InheritedWidget({required this.child});

  @override
  Element createElement() => InheritedElement(this);

  @override
  void render(Buffer buffer, Rect area) {
    final rootContext = InheritedElement(this)..mount(null);
    rootContext.render(buffer, area);
  }

  /// Whether the framework should notify widgets that inherit from this widget.
  bool updateShouldNotify(covariant InheritedWidget oldWidget);
}

/// An element that manages an [InheritedWidget].
class InheritedElement extends Element {
  /// The element corresponding to the built child widget.
  Element? childElement;

  /// Creates an element to manage an [InheritedWidget].
  InheritedElement(InheritedWidget super.widget);

  @override
  /// Adds this element to the tree and builds the child element.
  void mount(Element? parent) {
    this.parent = parent;
    rebuild();
  }

  /// Rebuilds the child widget configuration and updates the child element.
  void rebuild() {
    final inheritedWidget = widget as InheritedWidget;
    if (childElement != null &&
        childElement!.widget.runtimeType == inheritedWidget.child.runtimeType) {
      childElement!.update(inheritedWidget.child);
    } else {
      childElement = inheritedWidget.child.createElement();
      childElement!.mount(this);
    }
  }

  @override
  void update(Widget newWidget) {
    final oldWidget = widget as InheritedWidget;
    super.update(newWidget);
    final nextWidget = newWidget as InheritedWidget;
    if (nextWidget.updateShouldNotify(oldWidget)) {
      rebuild();
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement != null) visitor(childElement!);
  }

  @override
  void render(Buffer buffer, Rect area) {
    runZoned(() {
      childElement?.render(buffer, area);
    }, zoneValues: {#buildContext: this});
  }
}

/// Layout direction for box splitting.
enum LayoutDirection {
  /// Split horizontally.
  horizontal,

  /// Split vertically.
  vertical,
}

/// A Viewport wraps a parent buffer, translating and clipping drawing operations
/// to a relative local coordinate space within [bounds].
class Viewport implements Buffer {
  /// The underlying parent buffer.
  final Buffer parent;

  /// The rectangular bounds within the parent buffer.
  final Rect bounds;

  /// Creates a viewport wrapping [parent] constrained to [bounds].
  Viewport(this.parent, Rect bounds)
    : bounds = Rect(
        bounds.x,
        bounds.y,
        max(0, bounds.width),
        max(0, bounds.height),
      );

  @override
  int get width => bounds.width;
  @override
  set width(int val) =>
      throw UnsupportedError('Cannot set width of a Viewport');

  @override
  int get height => bounds.height;
  @override
  set height(int val) =>
      throw UnsupportedError('Cannot set height of a Viewport');

  @override
  List<Cell> get cells =>
      throw UnsupportedError('Flat cells access not supported on Viewport');
  @override
  set cells(List<Cell> val) =>
      throw UnsupportedError('Flat cells access not supported on Viewport');

  @override
  Cell? getCell(int x, int y) {
    if (x < 0 || x >= bounds.width || y < 0 || y >= bounds.height) return null;
    return parent.getCell(bounds.x + x, bounds.y + y);
  }

  @override
  void setCell(int x, int y, Cell cell) {
    if (x < 0 || x >= bounds.width || y < 0 || y >= bounds.height) return;
    parent.setCell(bounds.x + x, bounds.y + y, cell);
  }

  @override
  void clear() {
    for (var y = 0; y < bounds.height; y++) {
      for (var x = 0; x < bounds.width; x++) {
        final cell = parent.getCell(bounds.x + x, bounds.y + y);
        if (cell != null) {
          if (cell.char != ' ' || cell.style != Style.transparent) {
            cell.char = ' ';
            cell.style = Style.transparent;
          }
        }
      }
    }
  }

  @override
  void fill(Cell cell) {
    for (var y = 0; y < bounds.height; y++) {
      for (var x = 0; x < bounds.width; x++) {
        final targetCell = parent.getCell(bounds.x + x, bounds.y + y);
        if (targetCell != null) {
          targetCell.char = cell.char;
          targetCell.style = cell.style;
        }
      }
    }
  }

  @override
  void resize(int newWidth, int newHeight) {
    throw UnsupportedError('Cannot resize a Viewport');
  }

  @override
  void writeString(int x, int y, String text, Style style) {
    final startX = x;
    final chars = text.characters;
    var currentX = x;
    var currentY = y;

    for (final char in chars) {
      if (char == '\n') {
        currentX = startX;
        currentY++;
        continue;
      }
      if (currentX >= 0 &&
          currentX < bounds.width &&
          currentY >= 0 &&
          currentY < bounds.height) {
        // Clear potential wide char we are about to overwrite
        final cell = parent.getCell(bounds.x + currentX, bounds.y + currentY);
        if (cell != null) {
          if (cell.char == '') {
            if (currentX - 1 >= 0) {
              final prevCell = parent.getCell(
                bounds.x + currentX - 1,
                bounds.y + currentY,
              );
              if (prevCell != null && isWideGrapheme(prevCell.char)) {
                prevCell.char = ' ';
              }
            }
          } else if (isWideGrapheme(cell.char)) {
            if (currentX + 1 < bounds.width) {
              final nextCell = parent.getCell(
                bounds.x + currentX + 1,
                bounds.y + currentY,
              );
              if (nextCell != null && nextCell.char == '') {
                nextCell.char = ' ';
              }
            }
          }
        }

        final isWide = isWideGrapheme(char);
        if (isWide && currentX == bounds.width - 1) {
          // Can't fit wide character in the last column, write a space instead
          final cell = parent.getCell(bounds.x + currentX, bounds.y + currentY);
          if (cell != null) {
            cell.char = ' ';
            cell.style = Style(
              foreground: style.foreground,
              background: style.background ?? cell.style.background,
              modifiers: style.modifiers,
            );
          }
          currentX += 1;
        } else {
          final cell = parent.getCell(bounds.x + currentX, bounds.y + currentY);
          if (cell != null) {
            cell.char = char;
            cell.style = Style(
              foreground: style.foreground,
              background: style.background ?? cell.style.background,
              modifiers: style.modifiers,
            );
          }
          if (isWide) {
            if (currentX + 1 < bounds.width) {
              // Clear potential wide char we are overwriting in the next cell
              final nextCell = parent.getCell(
                bounds.x + currentX + 1,
                bounds.y + currentY,
              );
              if (nextCell != null) {
                if (isWideGrapheme(nextCell.char) &&
                    currentX + 2 < bounds.width) {
                  final nextNextCell = parent.getCell(
                    bounds.x + currentX + 2,
                    bounds.y + currentY,
                  );
                  if (nextNextCell != null && nextNextCell.char == '') {
                    nextNextCell.char = ' ';
                  }
                }
                nextCell.char = '';
                nextCell.style = Style(
                  foreground: style.foreground,
                  background: style.background ?? nextCell.style.background,
                  modifiers: style.modifiers,
                );
              }
            }
            currentX += 2;
          } else {
            currentX += 1;
          }
        }
      } else {
        currentX += 1;
      }
    }
  }
}

/// Splits a [Rect] area into multiple sub-rectangles according to layout constraints.
List<Rect> splitRect(
  Rect area,
  List<Constraint> constraints,
  LayoutDirection direction,
) {
  final clampedArea = Rect(
    area.x,
    area.y,
    max(0, area.width),
    max(0, area.height),
  );
  final totalSize = direction == LayoutDirection.horizontal
      ? clampedArea.width
      : clampedArea.height;
  final sizes = List<int>.filled(constraints.length, 0);

  var usedSize = 0;
  var totalFlex = 0;
  final flexIndices = <int>[];

  // 1. Calculate fixed sizes, percentages, and min constraints
  for (var i = 0; i < constraints.length; i++) {
    final c = constraints[i];
    if (c is LengthConstraint) {
      sizes[i] = c.length;
      usedSize += c.length;
    } else if (c is PercentageConstraint) {
      final size = (totalSize * c.percentage / 100).round();
      sizes[i] = size;
      usedSize += size;
    } else if (c is FlexConstraint) {
      totalFlex += c.flex;
      flexIndices.add(i);
    } else if (c is MinMaxConstraint) {
      sizes[i] = c.min;
      usedSize += c.min;
    }
  }

  // 2. Distribute remaining space among Flex constraints
  if (totalFlex > 0 && usedSize < totalSize) {
    final remaining = totalSize - usedSize;
    var distributed = 0;
    for (var j = 0; j < flexIndices.length; j++) {
      final idx = flexIndices[j];
      final flex = (constraints[idx] as FlexConstraint).flex;
      final size = j == flexIndices.length - 1
          ? remaining - distributed
          : (remaining * flex / totalFlex).floor();
      sizes[idx] = size;
      distributed += size;
    }
    usedSize += distributed;
  }

  // 3. Scale down if used size exceeds total size
  if (usedSize > totalSize) {
    var currentSum = 0;
    for (var i = 0; i < sizes.length; i++) {
      sizes[i] = (sizes[i] * totalSize / usedSize).floor();
      currentSum += sizes[i];
    }
    if (currentSum < totalSize) {
      for (var i = sizes.length - 1; i >= 0; i--) {
        if (sizes[i] > 0) {
          sizes[i] += (totalSize - currentSum);
          break;
        }
      }
    }
  }

  // 4. Respect Max Constraints on MinMax
  for (var i = 0; i < constraints.length; i++) {
    final c = constraints[i];
    if (c is MinMaxConstraint) {
      sizes[i] = sizes[i].clamp(c.min, c.max);
    }
    sizes[i] = max(0, sizes[i]);
  }

  // 5. Construct child Rects
  final rects = <Rect>[];
  var offset = 0;
  for (var i = 0; i < sizes.length; i++) {
    final size = sizes[i];
    if (direction == LayoutDirection.horizontal) {
      rects.add(
        Rect(clampedArea.x + offset, clampedArea.y, size, clampedArea.height),
      );
    } else {
      rects.add(
        Rect(clampedArea.x, clampedArea.y + offset, clampedArea.width, size),
      );
    }
    offset += size;
  }

  return rects;
}

Constraint _getConstraint(Widget widget, LayoutDirection direction) {
  if (widget is Flexible) {
    return FlexConstraint(widget.flex);
  }
  if (widget is SizedBox) {
    final size = direction == LayoutDirection.horizontal
        ? widget.width
        : widget.height;
    if (size != null) {
      return LengthConstraint(size);
    }
  }
  return const FlexConstraint(1);
}

Widget _getRealWidget(Widget widget) {
  if (widget is Flexible) {
    return widget.child;
  }
  if (widget is SizedBox) {
    return widget.child ?? const SizedBox.shrink();
  }
  return widget;
}

/// A layout widget that arranges its children horizontally.
class Row extends Widget {
  /// The children widgets to align horizontally.
  final List<Widget> children;

  /// Creates a horizontal layout for [children].
  const Row(this.children);

  @override
  Element createElement() => RowElement(this);

  @override
  void render(Buffer buffer, Rect area) {
    if (area.width <= 0 || area.height <= 0) return;
    final constraints = children
        .map((c) => _getConstraint(c, LayoutDirection.horizontal))
        .toList();
    final rects = splitRect(area, constraints, LayoutDirection.horizontal);
    for (var i = 0; i < children.length; i++) {
      final child = _getRealWidget(children[i]);
      final childArea = rects[i];
      final viewport = Viewport(buffer, childArea);
      child.render(viewport, Rect(0, 0, childArea.width, childArea.height));
    }
  }
}

/// An element that manages a [Row] widget.
class RowElement extends Element {
  /// The list of managed child elements.
  List<Element> childElements = [];

  /// Creates a row element for a [Row] widget.
  RowElement(Row super.widget);

  @override
  void unmount() {
    for (final child in childElements) {
      child.unmount();
    }
    super.unmount();
  }

  @override
  void render(Buffer buffer, Rect area) {
    final row = widget as Row;
    if (area.width <= 0 || area.height <= 0) return;

    final constraints = row.children
        .map((c) => _getConstraint(c, LayoutDirection.horizontal))
        .toList();
    final rects = splitRect(area, constraints, LayoutDirection.horizontal);

    final newElements = <Element>[];
    for (var i = 0; i < row.children.length; i++) {
      final childWidget = row.children[i];
      if (i < childElements.length &&
          childElements[i].widget.runtimeType == childWidget.runtimeType) {
        childElements[i].update(childWidget);
        newElements.add(childElements[i]);
      } else {
        if (i < childElements.length) {
          childElements[i].unmount();
        }
        final newEl = childWidget.createElement();
        newEl.mount(this);
        newElements.add(newEl);
      }
    }
    for (var i = row.children.length; i < childElements.length; i++) {
      childElements[i].unmount();
    }
    childElements = newElements;

    for (var i = 0; i < childElements.length; i++) {
      final childEl = childElements[i];
      final childArea = rects[i];
      final viewport = Viewport(buffer, childArea);
      childEl.render(viewport, Rect(0, 0, childArea.width, childArea.height));
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    childElements.forEach(visitor);
  }
}

/// A layout widget that arranges its children vertically.
class Column extends Widget {
  /// The children widgets to align vertically.
  final List<Widget> children;

  /// Creates a vertical layout for [children].
  const Column(this.children);

  @override
  Element createElement() => ColumnElement(this);

  @override
  void render(Buffer buffer, Rect area) {
    if (area.width <= 0 || area.height <= 0) return;
    final constraints = children
        .map((c) => _getConstraint(c, LayoutDirection.vertical))
        .toList();
    final rects = splitRect(area, constraints, LayoutDirection.vertical);
    for (var i = 0; i < children.length; i++) {
      final child = _getRealWidget(children[i]);
      final childArea = rects[i];
      final viewport = Viewport(buffer, childArea);
      child.render(viewport, Rect(0, 0, childArea.width, childArea.height));
    }
  }
}

/// An element that manages a [Column] widget.
class ColumnElement extends Element {
  /// The list of managed child elements.
  List<Element> childElements = [];

  /// Creates a column element for a [Column] widget.
  ColumnElement(Column super.widget);

  @override
  void unmount() {
    for (final child in childElements) {
      child.unmount();
    }
    super.unmount();
  }

  @override
  void render(Buffer buffer, Rect area) {
    final column = widget as Column;
    if (area.width <= 0 || area.height <= 0) return;

    final constraints = column.children
        .map((c) => _getConstraint(c, LayoutDirection.vertical))
        .toList();
    final rects = splitRect(area, constraints, LayoutDirection.vertical);

    final newElements = <Element>[];
    for (var i = 0; i < column.children.length; i++) {
      final childWidget = column.children[i];
      if (i < childElements.length &&
          childElements[i].widget.runtimeType == childWidget.runtimeType) {
        childElements[i].update(childWidget);
        newElements.add(childElements[i]);
      } else {
        if (i < childElements.length) {
          childElements[i].unmount();
        }
        final newEl = childWidget.createElement();
        newEl.mount(this);
        newElements.add(newEl);
      }
    }
    for (var i = column.children.length; i < childElements.length; i++) {
      childElements[i].unmount();
    }
    childElements = newElements;

    for (var i = 0; i < childElements.length; i++) {
      final childEl = childElements[i];
      final childArea = rects[i];
      final viewport = Viewport(buffer, childArea);
      childEl.render(viewport, Rect(0, 0, childArea.width, childArea.height));
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    childElements.forEach(visitor);
  }
}

/// A layout widget that stacks its children on top of each other.
class Stack extends Widget {
  /// The children widgets to stack.
  final List<Widget> children;

  /// Creates a stack layout for [children].
  const Stack(this.children);

  @override
  Element createElement() => StackElement(this);

  @override
  void render(Buffer buffer, Rect area) {
    if (area.width <= 0 || area.height <= 0) return;
    for (final child in children) {
      if (child is Positioned) {
        int childX = area.x;
        int childY = area.y;
        int childWidth = area.width;
        int childHeight = area.height;

        if (child.left != null) {
          childX = area.x + child.left!;
          if (child.right != null) {
            childWidth = area.width - child.left! - child.right!;
          } else if (child.width != null) {
            childWidth = child.width!;
          } else {
            childWidth = area.width - child.left!;
          }
        } else if (child.right != null) {
          if (child.width != null) {
            childWidth = child.width!;
            childX = area.x + area.width - child.right! - childWidth;
          } else {
            childWidth = area.width - child.right!;
          }
        } else if (child.width != null) {
          childWidth = child.width!;
        }

        if (child.top != null) {
          childY = area.y + child.top!;
          if (child.bottom != null) {
            childHeight = area.height - child.top! - child.bottom!;
          } else if (child.height != null) {
            childHeight = child.height!;
          } else {
            childHeight = area.height - child.top!;
          }
        } else if (child.bottom != null) {
          if (child.height != null) {
            childHeight = child.height!;
            childY = area.y + area.height - child.bottom! - childHeight;
          } else {
            childHeight = area.height - child.bottom!;
          }
        } else if (child.height != null) {
          childHeight = child.height!;
        }

        if (childWidth <= 0 || childHeight <= 0) continue;

        final childArea = Rect(childX, childY, childWidth, childHeight);
        final viewport = Viewport(buffer, childArea);
        child.child.render(viewport, Rect(0, 0, childWidth, childHeight));
      } else {
        final viewport = Viewport(buffer, area);
        child.render(viewport, Rect(0, 0, area.width, area.height));
      }
    }
  }
}

/// An element that manages a [Stack] widget.
class StackElement extends Element {
  /// The list of managed child elements.
  List<Element> childElements = [];

  /// Creates a stack element for a [Stack] widget.
  StackElement(Stack super.widget);

  @override
  void render(Buffer buffer, Rect area) {
    final stack = widget as Stack;
    if (area.width <= 0 || area.height <= 0) return;

    final newElements = <Element>[];
    for (var i = 0; i < stack.children.length; i++) {
      final childWidget = stack.children[i];
      if (i < childElements.length &&
          childElements[i].widget.runtimeType == childWidget.runtimeType) {
        childElements[i].update(childWidget);
        newElements.add(childElements[i]);
      } else {
        final newEl = childWidget.createElement();
        newEl.mount(this);
        newElements.add(newEl);
      }
    }
    childElements = newElements;

    for (var i = 0; i < childElements.length; i++) {
      final childEl = childElements[i];
      final childWidget = childEl.widget;

      if (childWidget is Positioned) {
        int childX = area.x;
        int childY = area.y;
        int childWidth = area.width;
        int childHeight = area.height;

        if (childWidget.left != null) {
          childX = area.x + childWidget.left!;
          if (childWidget.right != null) {
            childWidth = area.width - childWidget.left! - childWidget.right!;
          } else if (childWidget.width != null) {
            childWidth = childWidget.width!;
          } else {
            childWidth = area.width - childWidget.left!;
          }
        } else if (childWidget.right != null) {
          if (childWidget.width != null) {
            childWidth = childWidget.width!;
            childX = area.x + area.width - childWidget.right! - childWidth;
          } else {
            childWidth = area.width - childWidget.right!;
          }
        } else if (childWidget.width != null) {
          childWidth = childWidget.width!;
        }

        if (childWidget.top != null) {
          childY = area.y + childWidget.top!;
          if (childWidget.bottom != null) {
            childHeight = area.height - childWidget.top! - childWidget.bottom!;
          } else if (childWidget.height != null) {
            childHeight = childWidget.height!;
          } else {
            childHeight = area.height - childWidget.top!;
          }
        } else if (childWidget.bottom != null) {
          if (childWidget.height != null) {
            childHeight = childWidget.height!;
            childY = area.y + area.height - childWidget.bottom! - childHeight;
          } else {
            childHeight = area.height - childWidget.bottom!;
          }
        } else if (childWidget.height != null) {
          childHeight = childWidget.height!;
        }

        if (childWidth <= 0 || childHeight <= 0) continue;

        final childArea = Rect(childX, childY, childWidth, childHeight);
        final viewport = Viewport(buffer, childArea);
        childEl.render(viewport, Rect(0, 0, childWidth, childHeight));
      } else {
        final viewport = Viewport(buffer, area);
        childEl.render(viewport, Rect(0, 0, area.width, area.height));
      }
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    childElements.forEach(visitor);
  }
}

/// Places a widget inside a [Stack] at specific coordinate offsets.
class Positioned extends Widget {
  /// The distance from the left edge.
  final int? left;

  /// The distance from the top edge.
  final int? top;

  /// The distance from the right edge.
  final int? right;

  /// The distance from the bottom edge.
  final int? bottom;

  /// The constrained width.
  final int? width;

  /// The constrained height.
  final int? height;

  /// The child widget.
  final Widget child;

  /// Creates a positioned widget to place a [child] inside a [Stack].
  const Positioned({
    this.left,
    this.top,
    this.right,
    this.bottom,
    this.width,
    this.height,
    required this.child,
  });

  @override
  Element createElement() => PositionedElement(this);

  @override
  void render(Buffer buffer, Rect area) {
    child.render(buffer, area);
  }
}

/// An element that manages a [Positioned] widget.
class PositionedElement extends Element {
  /// The child element.
  Element? childElement;

  /// Creates a positioned element for a [Positioned] widget.
  PositionedElement(Positioned super.widget);

  @override
  void render(Buffer buffer, Rect area) {
    final pos = widget as Positioned;
    if (childElement != null &&
        childElement!.widget.runtimeType == pos.child.runtimeType) {
      childElement!.update(pos.child);
    } else {
      childElement = pos.child.createElement();
      childElement!.mount(this);
    }
    childElement!.render(buffer, area);
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement != null) visitor(childElement!);
  }
}

/// A widget that imposes tight constraints on its child.
class SizedBox extends Widget {
  /// The constrained width.
  final int? width;

  /// The constrained height.
  final int? height;

  /// The child widget.
  final Widget? child;

  /// Creates a sized box to enforce [width] and [height].
  const SizedBox({this.width, this.height, this.child});

  /// Creates a sized box with 0 width and height.
  const SizedBox.shrink({this.child}) : width = 0, height = 0;

  @override
  Element createElement() => SizedBoxElement(this);

  @override
  void render(Buffer buffer, Rect area) {
    final targetWidth = width ?? area.width;
    final targetHeight = height ?? area.height;

    if (targetWidth <= 0 || targetHeight <= 0) return;

    if (child != null) {
      final childArea = Rect(area.x, area.y, targetWidth, targetHeight);
      final viewport = Viewport(buffer, childArea);
      child!.render(viewport, Rect(0, 0, targetWidth, targetHeight));
    }
  }
}

/// An element that manages a [SizedBox] widget.
class SizedBoxElement extends Element {
  /// The child element.
  Element? childElement;

  /// Creates a sized box element for a [SizedBox] widget.
  SizedBoxElement(SizedBox super.widget);

  @override
  void render(Buffer buffer, Rect area) {
    final sb = widget as SizedBox;
    final targetWidth = sb.width ?? area.width;
    final targetHeight = sb.height ?? area.height;

    if (targetWidth <= 0 || targetHeight <= 0) return;

    if (sb.child != null) {
      if (childElement != null &&
          childElement!.widget.runtimeType == sb.child.runtimeType) {
        childElement!.update(sb.child!);
      } else {
        childElement = sb.child!.createElement();
        childElement!.mount(this);
      }

      final childArea = Rect(area.x, area.y, targetWidth, targetHeight);
      final viewport = Viewport(buffer, childArea);
      childElement!.render(viewport, Rect(0, 0, targetWidth, targetHeight));
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement != null) visitor(childElement!);
  }
}

/// Immutable box layout constraints.
class BoxConstraints {
  /// The minimum width allowed.
  final int minWidth;

  /// The maximum width allowed.
  final int maxWidth;

  /// The minimum height allowed.
  final int minHeight;

  /// The maximum height allowed.
  final int maxHeight;

  /// Creates box constraints with the given limits.
  const BoxConstraints({
    this.minWidth = 0,
    this.maxWidth = 999999,
    this.minHeight = 0,
    this.maxHeight = 999999,
  });

  /// Creates box constraints that require the given width or height.
  const BoxConstraints.tightFor({int? width, int? height})
    : minWidth = width ?? 0,
      maxWidth = width ?? 999999,
      minHeight = height ?? 0,
      maxHeight = height ?? 999999;
}

/// A widget that imposes [BoxConstraints] on its child.
class ConstrainedBox extends Widget {
  /// The additional constraints to impose on the child.
  final BoxConstraints constraints;

  /// The child widget.
  final Widget child;

  /// Creates a widget that imposes additional constraints on its child.
  const ConstrainedBox({required this.constraints, required this.child});

  @override
  Element createElement() => ConstrainedBoxElement(this);

  @override
  void render(Buffer buffer, Rect area) {
    final clampedWidth = area.width.clamp(
      constraints.minWidth,
      constraints.maxWidth,
    );
    final clampedHeight = area.height.clamp(
      constraints.minHeight,
      constraints.maxHeight,
    );

    if (clampedWidth <= 0 || clampedHeight <= 0) return;

    final childArea = Rect(area.x, area.y, clampedWidth, clampedHeight);
    final viewport = Viewport(buffer, childArea);
    child.render(viewport, Rect(0, 0, clampedWidth, clampedHeight));
  }
}

/// An element that manages a [ConstrainedBox] widget.
class ConstrainedBoxElement extends Element {
  /// The child element.
  Element? childElement;

  /// Creates a constrained box element for a [ConstrainedBox] widget.
  ConstrainedBoxElement(ConstrainedBox super.widget);

  @override
  void render(Buffer buffer, Rect area) {
    final cb = widget as ConstrainedBox;
    final clampedWidth = area.width.clamp(
      cb.constraints.minWidth,
      cb.constraints.maxWidth,
    );
    final clampedHeight = area.height.clamp(
      cb.constraints.minHeight,
      cb.constraints.maxHeight,
    );

    if (clampedWidth <= 0 || clampedHeight <= 0) return;

    if (childElement != null &&
        childElement!.widget.runtimeType == cb.child.runtimeType) {
      childElement!.update(cb.child);
    } else {
      childElement = cb.child.createElement();
      childElement!.mount(this);
    }

    final childArea = Rect(area.x, area.y, clampedWidth, clampedHeight);
    final viewport = Viewport(buffer, childArea);
    childElement!.render(viewport, Rect(0, 0, clampedWidth, clampedHeight));
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement != null) visitor(childElement!);
  }
}

/// Controls how a child widget of a [Row] or [Column] scales.
class Flexible extends Widget {
  /// The flex factor to use for this child.
  final int flex;

  /// The child widget.
  final Widget child;

  /// Creates a widget that controls how a child of a [Row] or [Column] flexes.
  const Flexible({this.flex = 1, required this.child});

  @override
  Element createElement() => FlexibleElement(this);

  @override
  void render(Buffer buffer, Rect area) {
    child.render(buffer, area);
  }
}

/// An element that manages a [Flexible] widget.
class FlexibleElement extends Element {
  /// The child element.
  Element? childElement;

  /// Creates a flexible element for a [Flexible] widget.
  FlexibleElement(Flexible super.widget);

  @override
  void render(Buffer buffer, Rect area) {
    final flex = widget as Flexible;
    if (childElement != null &&
        childElement!.widget.runtimeType == flex.child.runtimeType) {
      childElement!.update(flex.child);
    } else {
      childElement = flex.child.createElement();
      childElement!.mount(this);
    }
    childElement!.render(buffer, area);
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement != null) visitor(childElement!);
  }
}

/// An [Expanded] widget forces its child to consume all remaining space in a [Row] or [Column].
class Expanded extends Flexible {
  /// Creates an expanded widget.
  const Expanded({super.flex = 1, required super.child});
}

/// Represents a relative alignment in 2D space.
class Alignment {
  /// The distance fraction in the horizontal direction.
  final double x;

  /// The distance fraction in the vertical direction.
  final double y;

  /// Creates an alignment with the given [x] and [y] fractions.
  const Alignment(this.x, this.y);

  /// The top left corner.
  static const Alignment topLeft = Alignment(-1.0, -1.0);

  /// The center point along the top edge.
  static const Alignment topCenter = Alignment(0.0, -1.0);

  /// The top right corner.
  static const Alignment topRight = Alignment(1.0, -1.0);

  /// The center point along the left edge.
  static const Alignment centerLeft = Alignment(-1.0, 0.0);

  /// The center point, both horizontally and vertically.
  static const Alignment center = Alignment(0.0, 0.0);

  /// The center point along the right edge.
  static const Alignment centerRight = Alignment(1.0, 0.0);

  /// The bottom left corner.
  static const Alignment bottomLeft = Alignment(-1.0, 1.0);

  /// The center point along the bottom edge.
  static const Alignment bottomCenter = Alignment(0.0, 1.0);

  /// The bottom right corner.
  static const Alignment bottomRight = Alignment(1.0, 1.0);
}

/// A widget that aligns its child within itself.
class Align extends Widget {
  /// How to align the child.
  final Alignment alignment;

  /// The child widget.
  final Widget child;

  /// If non-null, sets its width to the child's width multiplied by this factor.
  final double? widthFactor;

  /// If non-null, sets its height to the child's height multiplied by this factor.
  final double? heightFactor;

  /// Creates an alignment widget.
  const Align({
    this.alignment = Alignment.center,
    this.widthFactor,
    this.heightFactor,
    required this.child,
  });

  @override
  Element createElement() => AlignElement(this);

  @override
  void render(Buffer buffer, Rect area) {
    int childWidth = area.width;
    int childHeight = area.height;

    if (child is SizedBox) {
      final sb = child as SizedBox;
      childWidth = sb.width ?? area.width;
      childHeight = sb.height ?? area.height;
    } else if (child is ConstrainedBox) {
      final cb = child as ConstrainedBox;
      childWidth = area.width.clamp(
        cb.constraints.minWidth,
        cb.constraints.maxWidth,
      );
      childHeight = area.height.clamp(
        cb.constraints.minHeight,
        cb.constraints.maxHeight,
      );
    }

    if (widthFactor != null) {
      childWidth = (childWidth * widthFactor!).round();
    }
    if (heightFactor != null) {
      childHeight = (childHeight * heightFactor!).round();
    }

    childWidth = childWidth.clamp(0, area.width);
    childHeight = childHeight.clamp(0, area.height);

    final double remainingWidth = (area.width - childWidth).toDouble();
    final int offsetX = (remainingWidth * (alignment.x + 1.0) / 2.0).round();

    final double remainingHeight = (area.height - childHeight).toDouble();
    final int offsetY = (remainingHeight * (alignment.y + 1.0) / 2.0).round();

    final childArea = Rect(
      area.x + offsetX,
      area.y + offsetY,
      childWidth,
      childHeight,
    );

    final childViewport = Viewport(buffer, childArea);
    child.render(childViewport, Rect(0, 0, childWidth, childHeight));
  }
}

/// An element that manages an [Align] widget.
class AlignElement extends Element {
  /// The child element.
  Element? childElement;

  /// Creates an align element for an [Align] widget.
  AlignElement(Align super.widget);

  @override
  void render(Buffer buffer, Rect area) {
    final align = widget as Align;
    int childWidth = area.width;
    int childHeight = area.height;

    final childWidget = align.child;
    if (childWidget is SizedBox) {
      childWidth = childWidget.width ?? area.width;
      childHeight = childWidget.height ?? area.height;
    } else if (childWidget is ConstrainedBox) {
      childWidth = area.width.clamp(
        childWidget.constraints.minWidth,
        childWidget.constraints.maxWidth,
      );
      childHeight = area.height.clamp(
        childWidget.constraints.minHeight,
        childWidget.constraints.maxHeight,
      );
    }

    if (align.widthFactor != null) {
      childWidth = (childWidth * align.widthFactor!).round();
    }
    if (align.heightFactor != null) {
      childHeight = (childHeight * align.heightFactor!).round();
    }

    childWidth = childWidth.clamp(0, area.width);
    childHeight = childHeight.clamp(0, area.height);

    final double remainingWidth = (area.width - childWidth).toDouble();
    final int offsetX = (remainingWidth * (align.alignment.x + 1.0) / 2.0)
        .round();

    final double remainingHeight = (area.height - childHeight).toDouble();
    final int offsetY = (remainingHeight * (align.alignment.y + 1.0) / 2.0)
        .round();

    if (childElement != null &&
        childElement!.widget.runtimeType == childWidget.runtimeType) {
      childElement!.update(childWidget);
    } else {
      childElement = childWidget.createElement();
      childElement!.mount(this);
    }

    final childArea = Rect(
      area.x + offsetX,
      area.y + offsetY,
      childWidth,
      childHeight,
    );

    final childViewport = Viewport(buffer, childArea);
    childElement!.render(childViewport, Rect(0, 0, childWidth, childHeight));
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement != null) visitor(childElement!);
  }
}

/// A widget that centers its child within itself.
class Center extends Align {
  /// Creates a widget that centers its child.
  const Center({super.widthFactor, super.heightFactor, required super.child})
    : super(alignment: Alignment.center);
}

/// A bridge widget that maintains a persistent [Element] tree for its child.
///
/// Use this to embed reactive widgets (like [StatefulWidget]s or [InheritedWidget]s)
/// inside immediate-mode rendering loops that reconstruct the widget tree on every frame.
class ElementWidget extends Widget {
  /// The child widget.
  final Widget child;
  Element? _element;

  /// Creates an element widget bridging the tree.
  ElementWidget(this.child);

  /// The root element of the embedded tree.
  Element? get element => _element;

  @override
  void render(Buffer buffer, Rect area) {
    if (_element == null) {
      _element = child.createElement();
      _element!.mount(null);
    } else {
      _element!.update(child);
    }
    _element!.render(buffer, area);
  }

  /// Finds a State of type S inside this widget's element tree.
  S? findState<S extends State>() {
    if (_element == null) return null;
    return _findStateRecursive<S>(_element!);
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
