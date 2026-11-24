import 'dart:math';
import 'package:termui/termui.dart';

/// A widget that divides a viewport into two side-by-side or stacked children.
///
/// The two child widgets are separated by an interactive divider bar.
///
/// ### Resizing Behavior via Divider Dragging
/// - When a mouse press occurs on the divider's cell coordinates, the widget
///   enters dragging mode.
/// - During a mouse drag event, the split pane recalculates the divider position
///   based on the mouse coordinates.
/// - It clamps the new position to respect the min/max limits of both children.
/// - Finally, it dynamically mutates the constraints of [child1] and [child2]
///   in place (e.g. updating a [LengthConstraint] or [PercentageConstraint]),
///   causing the layout solver to adjust child viewports on subsequent frames.
///
/// ### Example Usage
///
/// ```dart
/// SplitPane(
///   direction: LayoutDirection.horizontal,
///   dividerChar: '│',
///   child1: LeftPanel(),
///   constraint1: const LengthConstraint(20),
///   child2: RightPanel(),
///   constraint2: const FlexConstraint(1),
/// );
/// ```
///
/// ### Properties and Settings
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `child1` | [Widget] | The first child widget. |
/// | `child2` | [Widget] | The second child widget. |
/// | `constraint1` | [Constraint] | The layout constraint for child1. |
/// | `constraint2` | [Constraint] | The layout constraint for child2. |
/// | `direction` | [LayoutDirection] | Split direction (horizontal or vertical). |
/// | `dividerChar` | [String] | The character character representing the divider line. |
/// | `dividerStyle` | [Style] | Rendering style attributes for the divider cells. |
class SplitPane extends Widget {
  /// The first child widget.
  final Widget child1;

  /// The second child widget.
  final Widget child2;

  /// The layout constraint for child1.
  Constraint constraint1;

  /// The layout constraint for child2.
  Constraint constraint2;

  /// Split direction (horizontal or vertical).
  final LayoutDirection direction;

  /// The character representing the divider line.
  final String dividerChar;

  /// Rendering style attributes for the divider cells.
  final Style dividerStyle;

  /// Creates a [SplitPane] widget.
  SplitPane({
    required this.child1,
    required this.child2,
    required this.constraint1,
    required this.constraint2,
    this.direction = .horizontal,
    this.dividerChar = '│',
    this.dividerStyle = Style.empty,
  });

  Rect? _lastArea;

  /// The bounds of the split pane in the last paint pass.
  Rect? get lastArea => _lastArea;

  int _dividerX = 0;
  bool _isDragging = false;
  int? _origMin1;
  int? _origMax1;
  int? _origMin2;
  int? _origMax2;

  /// Gets the current divider position.
  int get dividerPosition => _dividerX;

  /// Whether the divider is currently being dragged.
  bool get isDragging => _isDragging;

  void _initLimits() {
    if (_origMin1 != null) return;
    final c1 = constraint1;
    final c2 = constraint2;
    if (c1 is MinMaxConstraint) {
      _origMin1 = c1.min;
      _origMax1 = c1.max;
    }
    if (c2 is MinMaxConstraint) {
      _origMin2 = c2.min;
      _origMax2 = c2.max;
    }
  }

  @override
  Element createElement() => SplitPaneElement(this);

  @override
  int getIntrinsicHeight(int width) {
    final h1 = child1.getIntrinsicHeight(width);
    final h2 = child2.getIntrinsicHeight(width);
    if (direction == .vertical) {
      return h1 + h2 + 1;
    } else {
      return max(h1, h2);
    }
  }

  @override
  int getIntrinsicWidth(int height) {
    final w1 = child1.getIntrinsicWidth(height);
    final w2 = child2.getIntrinsicWidth(height);
    if (direction == LayoutDirection.horizontal) {
      return w1 + w2 + 1;
    } else {
      return max(w1, w2);
    }
  }
}

/// An element that manages the layout and rendering of a [SplitPane] widget.
class SplitPaneElement extends Element implements MouseEventHandler {
  /// The element for the first pane child widget.
  Element? childElement1;

  /// The element for the second pane child widget.
  Element? childElement2;

  /// Creates a [SplitPaneElement] for the given [widget].
  SplitPaneElement(SplitPane super.widget);

  @override
  void mount(Element? parent) {
    super.mount(parent);
    rebuild();
  }

  @override
  void update(Widget newWidget) {
    super.update(newWidget);
    rebuild();
  }

  @override
  void rebuild() {
    final split = widget as SplitPane;
    if (childElement1 != null &&
        Widget.canUpdate(childElement1!.widget, split.child1)) {
      childElement1!.update(split.child1);
    } else {
      childElement1?.unmount();
      childElement1 = split.child1.createElement();
      childElement1!.mount(this);
    }

    if (childElement2 != null &&
        Widget.canUpdate(childElement2!.widget, split.child2)) {
      childElement2!.update(split.child2);
    } else {
      childElement2?.unmount();
      childElement2 = split.child2.createElement();
      childElement2!.mount(this);
    }
  }

  @override
  void unmount() {
    childElement1?.unmount();
    childElement2?.unmount();
    super.unmount();
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement1 != null) visitor(childElement1!);
    if (childElement2 != null) visitor(childElement2!);
  }

  @override
  int getIntrinsicHeight(int width) {
    final split = widget as SplitPane;
    final h1 = childElement1?.getIntrinsicHeight(width) ?? 0;
    final h2 = childElement2?.getIntrinsicHeight(width) ?? 0;
    if (split.direction == LayoutDirection.vertical) {
      return h1 + h2 + 1;
    } else {
      return max(h1, h2);
    }
  }

  @override
  int getIntrinsicWidth(int height) {
    final split = widget as SplitPane;
    final w1 = childElement1?.getIntrinsicWidth(height) ?? 0;
    final w2 = childElement2?.getIntrinsicWidth(height) ?? 0;
    if (split.direction == LayoutDirection.horizontal) {
      return w1 + w2 + 1;
    } else {
      return max(w1, w2);
    }
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    final split = widget as SplitPane;
    final w = constraints.maxWidth == BoxConstraints.infinity
        ? 20
        : constraints.maxWidth;
    final h = constraints.maxHeight == BoxConstraints.infinity
        ? 10
        : constraints.maxHeight;

    split._initLimits();
    final isHorizontal = split.direction == LayoutDirection.horizontal;
    final totalSize = isHorizontal ? w : h;
    if (totalSize <= 0) {
      split._dividerX = 0;
      return Size(w, h);
    }

    final dividerPos = _clampDividerPos(
      split,
      totalSize,
      _calculateDividerPos(totalSize),
    );
    split._dividerX = dividerPos;

    final secondSize = totalSize - dividerPos - 1;
    _layoutPaneChild(
      childElement1,
      Offset.zero,
      isHorizontal ? Size(dividerPos, h) : Size(w, dividerPos),
      dividerPos,
    );
    _layoutPaneChild(
      childElement2,
      isHorizontal ? Offset(dividerPos + 1, 0) : Offset(0, dividerPos + 1),
      isHorizontal ? Size(secondSize, h) : Size(w, secondSize),
      secondSize,
    );

    return constraints.constrain(Size(w, h));
  }

  static void _layoutPaneChild(
    Element? child,
    Offset offset,
    Size paneSize,
    int primaryExtent,
  ) {
    if (child == null) return;
    child.relativeOffset = offset;
    if (primaryExtent > 0) {
      child.layout(BoxConstraints.tight(paneSize));
    }
  }

  static int _clampDividerPos(SplitPane split, int totalSize, int desired) {
    var minW1 = split._origMin1 ?? 0;
    var maxW1 = split._origMax1 ?? (totalSize - 1);
    if (split._origMin2 != null) {
      maxW1 = min(maxW1, totalSize - split._origMin2! - 1);
    }
    if (split._origMax2 != null) {
      minW1 = max(minW1, totalSize - split._origMax2! - 1);
    }
    minW1 = minW1.clamp(0, totalSize - 1);
    maxW1 = maxW1.clamp(0, totalSize - 1);
    if (minW1 > maxW1) minW1 = maxW1;
    return desired.clamp(minW1, maxW1);
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final split = widget as SplitPane;
    split._lastArea = Rect(offset.dx, offset.dy, size.width, size.height);
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    final dividerPos = split._dividerX;
    if (dividerPos > 0 && childElement1 != null) {
      childElement1!.paint(buffer, offset + childElement1!.relativeOffset);
    }

    _paintDivider(buffer, offset, split, dividerPos, w, h);

    final secondSize =
        (split.direction == LayoutDirection.horizontal ? w : h) -
        dividerPos -
        1;
    if (secondSize > 0 && childElement2 != null) {
      childElement2!.paint(buffer, offset + childElement2!.relativeOffset);
    }
  }

  static void _paintDivider(
    Buffer buffer,
    Offset offset,
    SplitPane split,
    int dividerPos,
    int width,
    int height,
  ) {
    final fg = split.dividerStyle.foreground?.argb ?? 0;
    final bg = split.dividerStyle.background?.argb ?? 0;
    final isHorizontal = split.direction == LayoutDirection.horizontal;
    final length = isHorizontal ? height : width;
    for (var i = 0; i < length; i++) {
      buffer.setAttributes(
        offset.dx + (isHorizontal ? dividerPos : i),
        offset.dy + (isHorizontal ? i : dividerPos),
        char: split.dividerChar,
        fg: fg,
        bg: bg,
        modifiers: split.dividerStyle.modifiers,
      );
    }
  }

  int _calculateDividerPos(int totalSize) {
    final split = widget as SplitPane;
    final c1 = split.constraint1;
    final c2 = split.constraint2;

    switch (c1) {
      case LengthConstraint(:final length):
        return length.clamp(0, totalSize - 1);
      case PercentageConstraint(:final percentage):
        return (totalSize * percentage / 100).round().clamp(0, totalSize - 1);
      case FlexConstraint(:final flex):
        final flex2 = switch (c2) {
          FlexConstraint(:final flex) => flex,
          _ => 1,
        };
        final sum = flex + flex2;
        if (sum <= 0) return (totalSize / 2).floor();
        return (totalSize * flex / sum).round().clamp(0, totalSize - 1);
      case MinMaxConstraint(:final min):
        return min.clamp(0, totalSize - 1);
    }
  }

  /// Intercepts mouse drag/press events over the divider.
  @override
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    final split = widget as SplitPane;
    final lastArea = split._lastArea;
    if (lastArea == null) return;
    split._initLimits();
    final isHorizontal = split.direction == LayoutDirection.horizontal;
    final totalSize = isHorizontal ? lastArea.width : lastArea.height;
    if (totalSize <= 0) return;

    final mousePos = isHorizontal ? localX : localY;

    switch (event.type) {
      case MouseEventType.press:
        if (mousePos == split._dividerX) split._isDragging = true;
      case MouseEventType.release:
        split._isDragging = false;
      case MouseEventType.drag when split._isDragging:
        final newDividerPos = _clampDividerPos(split, totalSize, mousePos);
        _updateDraggedConstraints(split, totalSize, newDividerPos);
        split._dividerX = newDividerPos;
      default:
        break;
    }
  }

  static void _updateDraggedConstraints(
    SplitPane split,
    int totalSize,
    int newDividerPos,
  ) {
    final remaining = totalSize - newDividerPos - 1;
    switch (split.constraint1) {
      case LengthConstraint():
        split.constraint1 = LengthConstraint(newDividerPos);
        split.constraint2 = LengthConstraint(remaining);
      case PercentageConstraint():
        final p1 = (newDividerPos * 100 / totalSize).round().clamp(0, 100);
        split.constraint1 = PercentageConstraint(p1);
        split.constraint2 = PercentageConstraint(100 - p1);
      case FlexConstraint():
        split.constraint1 = FlexConstraint(newDividerPos);
        split.constraint2 = FlexConstraint(remaining);
      case MinMaxConstraint():
        split.constraint1 = MinMaxConstraint(
          min: newDividerPos,
          max: split._origMax1 ?? 99999,
        );
        split.constraint2 = split.constraint2 is MinMaxConstraint
            ? MinMaxConstraint(min: remaining, max: split._origMax2 ?? 99999)
            : MinMaxConstraint(min: remaining);
    }
  }
}
