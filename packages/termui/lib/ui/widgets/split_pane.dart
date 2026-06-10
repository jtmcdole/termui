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
  int _dividerX = 0;
  bool _isDragging = false;
  int? _origMin1;
  int? _origMax1;
  int? _origMin2;
  int? _origMax2;

  /// Gets the current divider position.
  int get dividerPosition => _dividerX;

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
  void render(Buffer buffer, Rect area) {
    _lastArea = area;
    final w = area.width;
    final h = area.height;
    if (w <= 0 || h <= 0) return;

    _initLimits();
    final totalSize = direction == LayoutDirection.horizontal ? w : h;

    // 1. Calculate raw divider position based on constraints
    int dividerPos = _calculateDividerPos(totalSize);

    // 2. Solve min/max limits
    int minW1 = _origMin1 ?? 0;
    int maxW1 = _origMax1 ?? (totalSize - 1);
    if (_origMin2 != null) {
      maxW1 = min(maxW1, totalSize - _origMin2! - 1);
    }
    if (_origMax2 != null) {
      minW1 = max(minW1, totalSize - _origMax2! - 1);
    }
    minW1 = minW1.clamp(0, totalSize - 1);
    maxW1 = maxW1.clamp(0, totalSize - 1);
    if (minW1 > maxW1) minW1 = maxW1;

    dividerPos = dividerPos.clamp(minW1, maxW1);
    _dividerX = dividerPos;

    if (direction == LayoutDirection.horizontal) {
      // Render child1
      final child1Area = Rect(area.x, area.y, dividerPos, h);
      if (dividerPos > 0) {
        final vp1 = Viewport(buffer, child1Area);
        child1.render(vp1, Rect(0, 0, dividerPos, h));
      }

      // Render Divider
      for (var y = 0; y < h; y++) {
        final cell = buffer.getCell(area.x + dividerPos, area.y + y);
        if (cell != null) {
          cell.char = dividerChar;
          cell.style = dividerStyle;
        }
      }

      // Render child2
      final child2Width = w - dividerPos - 1;
      final child2Area = Rect(area.x + dividerPos + 1, area.y, child2Width, h);
      if (child2Width > 0) {
        final vp2 = Viewport(buffer, child2Area);
        child2.render(vp2, Rect(0, 0, child2Width, h));
      }
    } else {
      // Vertical
      // Render child1
      final child1Area = Rect(area.x, area.y, w, dividerPos);
      if (dividerPos > 0) {
        final vp1 = Viewport(buffer, child1Area);
        child1.render(vp1, Rect(0, 0, w, dividerPos));
      }

      // Render Divider
      for (var x = 0; x < w; x++) {
        final cell = buffer.getCell(area.x + x, area.y + dividerPos);
        if (cell != null) {
          cell.char = dividerChar;
          cell.style = dividerStyle;
        }
      }

      // Render child2
      final child2Height = h - dividerPos - 1;
      final child2Area = Rect(area.x, area.y + dividerPos + 1, w, child2Height);
      if (child2Height > 0) {
        final vp2 = Viewport(buffer, child2Area);
        child2.render(vp2, Rect(0, 0, w, child2Height));
      }
    }
  }

  int _calculateDividerPos(int totalSize) {
    final c1 = constraint1;
    final c2 = constraint2;

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
    if (_lastArea == null) return;
    _initLimits();
    final totalSize = direction == LayoutDirection.horizontal
        ? _lastArea!.width
        : _lastArea!.height;
    if (totalSize <= 0) return;

    final mousePos = direction == LayoutDirection.horizontal ? localX : localY;

    if (event.type == MouseEventType.press) {
      if (mousePos == _dividerX) {
        _isDragging = true;
      }
    } else if (event.type == MouseEventType.release) {
      _isDragging = false;
    } else if (event.type == MouseEventType.drag && _isDragging) {
      int newDividerPos = mousePos;

      // Solve bounds/limits
      int minW1 = _origMin1 ?? 0;
      int maxW1 = _origMax1 ?? (totalSize - 1);
      if (_origMin2 != null) {
        maxW1 = min(maxW1, totalSize - _origMin2! - 1);
      }
      if (_origMax2 != null) {
        minW1 = max(minW1, totalSize - _origMax2! - 1);
      }
      minW1 = minW1.clamp(0, totalSize - 1);
      maxW1 = maxW1.clamp(0, totalSize - 1);
      if (minW1 > maxW1) minW1 = maxW1;

      newDividerPos = newDividerPos.clamp(minW1, maxW1);

      // Mutate constraints in place
      final c1 = constraint1;
      if (c1 is LengthConstraint) {
        constraint1 = LengthConstraint(newDividerPos);
        constraint2 = LengthConstraint(totalSize - newDividerPos - 1);
      } else if (c1 is PercentageConstraint) {
        final p1 = (newDividerPos * 100 / totalSize).round().clamp(0, 100);
        constraint1 = PercentageConstraint(p1);
        constraint2 = PercentageConstraint(100 - p1);
      } else if (c1 is FlexConstraint) {
        constraint1 = FlexConstraint(newDividerPos);
        constraint2 = FlexConstraint(totalSize - newDividerPos - 1);
      } else if (c1 is MinMaxConstraint) {
        // Here we keep the min limits but update the current value via a new MinMaxConstraint.
        // Wait, since MinMaxConstraint uses min to represent the preferred size, we update the min.
        // But the original min limit is stored in _origMin1, so we still clamp correctly.
        constraint1 = MinMaxConstraint(
          min: newDividerPos,
          max: _origMax1 ?? 99999,
        );
        if (constraint2 is MinMaxConstraint) {
          constraint2 = MinMaxConstraint(
            min: totalSize - newDividerPos - 1,
            max: _origMax2 ?? 99999,
          );
        } else {
          constraint2 = MinMaxConstraint(min: totalSize - newDividerPos - 1);
        }
      }
      _dividerX = newDividerPos;
    }
  }
}
