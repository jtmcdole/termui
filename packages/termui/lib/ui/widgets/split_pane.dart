import 'dart:math';
import '../buffer.dart';
import '../layout.dart';
import '../style.dart';
import '../event.dart';

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
    this.direction = LayoutDirection.horizontal,
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
}

/// An element that manages the layout and rendering of a [SplitPane] widget.
class SplitPaneElement extends Element {
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
        childElement1!.widget.runtimeType == split.child1.runtimeType) {
      childElement1!.update(split.child1);
    } else {
      childElement1?.unmount();
      childElement1 = split.child1.createElement();
      childElement1!.mount(this);
    }

    if (childElement2 != null &&
        childElement2!.widget.runtimeType == split.child2.runtimeType) {
      childElement2!.update(split.child2);
    } else {
      childElement2?.unmount();
      childElement2 = split.child2.createElement();
      childElement2!.mount(this);
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement1 != null) visitor(childElement1!);
    if (childElement2 != null) visitor(childElement2!);
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
    final totalSize = split.direction == LayoutDirection.horizontal ? w : h;

    int dividerPos = _calculateDividerPos(totalSize);

    int minW1 = split._origMin1 ?? 0;
    int maxW1 = split._origMax1 ?? (totalSize - 1);
    if (split._origMin2 != null) {
      maxW1 = min(maxW1, totalSize - split._origMin2! - 1);
    }
    if (split._origMax2 != null) {
      minW1 = max(minW1, totalSize - split._origMax2! - 1);
    }
    minW1 = minW1.clamp(0, totalSize - 1);
    maxW1 = maxW1.clamp(0, totalSize - 1);
    if (minW1 > maxW1) minW1 = maxW1;

    dividerPos = dividerPos.clamp(minW1, maxW1);
    split._dividerX = dividerPos;

    if (split.direction == LayoutDirection.horizontal) {
      if (dividerPos > 0 && childElement1 != null) {
        childElement1!.layout(BoxConstraints.tight(Size(dividerPos, h)));
      }
      final child2Width = w - dividerPos - 1;
      if (child2Width > 0 && childElement2 != null) {
        childElement2!.layout(BoxConstraints.tight(Size(child2Width, h)));
      }
    } else {
      if (dividerPos > 0 && childElement1 != null) {
        childElement1!.layout(BoxConstraints.tight(Size(w, dividerPos)));
      }
      final child2Height = h - dividerPos - 1;
      if (child2Height > 0 && childElement2 != null) {
        childElement2!.layout(BoxConstraints.tight(Size(w, child2Height)));
      }
    }

    return constraints.constrain(Size(w, h));
  }

  @override
  void paint(Buffer buffer, Offset offset) {
    final split = widget as SplitPane;
    split._lastArea = Rect(offset.dx, offset.dy, size.width, size.height);
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    final dividerPos = split._dividerX;

    if (split.direction == LayoutDirection.horizontal) {
      if (dividerPos > 0 && childElement1 != null) {
        childElement1!.paint(buffer, offset);
      }

      for (var y = 0; y < h; y++) {
        final cell = buffer.getCell(offset.dx + dividerPos, offset.dy + y);
        if (cell != null) {
          cell.char = split.dividerChar;
          cell.style = split.dividerStyle;
        }
      }

      final child2Width = w - dividerPos - 1;
      if (child2Width > 0 && childElement2 != null) {
        childElement2!.paint(
          buffer,
          Offset(offset.dx + dividerPos + 1, offset.dy),
        );
      }
    } else {
      if (dividerPos > 0 && childElement1 != null) {
        childElement1!.paint(buffer, offset);
      }

      for (var x = 0; x < w; x++) {
        final cell = buffer.getCell(offset.dx + x, offset.dy + dividerPos);
        if (cell != null) {
          cell.char = split.dividerChar;
          cell.style = split.dividerStyle;
        }
      }

      final child2Height = h - dividerPos - 1;
      if (child2Height > 0 && childElement2 != null) {
        childElement2!.paint(
          buffer,
          Offset(offset.dx, offset.dy + dividerPos + 1),
        );
      }
    }
  }

  int _calculateDividerPos(int totalSize) {
    final split = widget as SplitPane;
    final c1 = split.constraint1;
    final c2 = split.constraint2;

    if (c1 is LengthConstraint) {
      return c1.length.clamp(0, totalSize - 1);
    } else if (c1 is PercentageConstraint) {
      return (totalSize * c1.percentage / 100).round().clamp(0, totalSize - 1);
    } else if (c1 is FlexConstraint) {
      final flex2 = c2 is FlexConstraint ? c2.flex : 1;
      final sum = c1.flex + flex2;
      if (sum <= 0) return (totalSize / 2).floor();
      return (totalSize * c1.flex / sum).round().clamp(0, totalSize - 1);
    } else if (c1 is MinMaxConstraint) {
      return c1.min.clamp(0, totalSize - 1);
    }
    return (totalSize / 2).floor().clamp(0, totalSize - 1);
  }

  /// Intercepts mouse drag/press events over the divider.
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    final split = widget as SplitPane;
    if (split._lastArea == null) return;
    split._initLimits();
    final totalSize = split.direction == LayoutDirection.horizontal
        ? split._lastArea!.width
        : split._lastArea!.height;
    if (totalSize <= 0) return;

    final mousePos = split.direction == LayoutDirection.horizontal
        ? localX
        : localY;

    if (event.type == MouseEventType.press) {
      if (mousePos == split._dividerX) {
        split._isDragging = true;
      }
    } else if (event.type == MouseEventType.release) {
      split._isDragging = false;
    } else if (event.type == MouseEventType.drag && split._isDragging) {
      int newDividerPos = mousePos;

      // Solve bounds/limits
      int minW1 = split._origMin1 ?? 0;
      int maxW1 = split._origMax1 ?? (totalSize - 1);
      if (split._origMin2 != null) {
        maxW1 = min(maxW1, totalSize - split._origMin2! - 1);
      }
      if (split._origMax2 != null) {
        minW1 = max(minW1, totalSize - split._origMax2! - 1);
      }
      minW1 = minW1.clamp(0, totalSize - 1);
      maxW1 = maxW1.clamp(0, totalSize - 1);
      if (minW1 > maxW1) minW1 = maxW1;

      newDividerPos = newDividerPos.clamp(minW1, maxW1);

      // Mutate constraints in place
      final c1 = split.constraint1;
      if (c1 is LengthConstraint) {
        split.constraint1 = LengthConstraint(newDividerPos);
        split.constraint2 = LengthConstraint(totalSize - newDividerPos - 1);
      } else if (c1 is PercentageConstraint) {
        final p1 = (newDividerPos * 100 / totalSize).round().clamp(0, 100);
        split.constraint1 = PercentageConstraint(p1);
        split.constraint2 = PercentageConstraint(100 - p1);
      } else if (c1 is FlexConstraint) {
        split.constraint1 = FlexConstraint(newDividerPos);
        split.constraint2 = FlexConstraint(totalSize - newDividerPos - 1);
      } else if (c1 is MinMaxConstraint) {
        // Here we keep the min limits but update the current value via a new MinMaxConstraint.
        // Wait, since MinMaxConstraint uses min to represent the preferred size, we update the min.
        // But the original min limit is stored in _origMin1, so we still clamp correctly.
        split.constraint1 = MinMaxConstraint(
          min: newDividerPos,
          max: split._origMax1 ?? 99999,
        );
        if (split.constraint2 is MinMaxConstraint) {
          split.constraint2 = MinMaxConstraint(
            min: totalSize - newDividerPos - 1,
            max: split._origMax2 ?? 99999,
          );
        } else {
          split.constraint2 = MinMaxConstraint(
            min: totalSize - newDividerPos - 1,
          );
        }
      }
      split._dividerX = newDividerPos;
    }
  }
}
