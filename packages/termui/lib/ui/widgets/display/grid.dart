import 'dart:math';
import 'package:termui/termui.dart';

/// A widget that renders a static 2D grid of customized [GridCell]s.
///
/// It acts like a tile map, copying characters and styles from the provided 2D
/// array directly into the local draw buffer up to the active constraints.
///
/// ### Example Usage
///
/// ```dart
/// final map = Grid([
///   [GridCell('█', Style(foreground: Color(0xFF00FF00))), GridCell(' ', Style.empty)],
///   [GridCell(' ', Style.empty), GridCell('█', Style(foreground: Color(0xFF00FF00)))],
/// ]);
/// ```
///
/// ### Properties and Settings
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `tiles` | [List]<[List]<[GridCell]>> | A 2D list of cells representing rows and columns. |
class Grid extends Widget {
  /// A 2D list of cells representing rows and columns.
  final List<List<GridCell>> tiles;

  /// Creates a new [Grid] with the given [tiles].
  Grid(this.tiles);

  @override
  Element createElement() => GridElement(this);
}

/// Element class that manages layout and paint of [Grid].
class GridElement extends Element {
  /// Calculated width of the grid from tiles.
  int calculatedWidth = 0;

  /// Calculated height of the grid from tiles.
  int calculatedHeight = 0;

  /// Instantiates the rendering element for the given Grid.
  GridElement(Grid super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final grid = widget as Grid;
    calculatedHeight = grid.tiles.length;
    calculatedWidth = calculatedHeight > 0 ? grid.tiles[0].length : 0;

    return constraints.constrain(Size(calculatedWidth, calculatedHeight));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final grid = widget as Grid;
    final w = size.width;
    final h = size.height;

    final startY = max(0, -offset.dy);
    final endY = min(h, buffer.height - offset.dy);
    final startX = max(0, -offset.dx);
    final endX = min(w, buffer.width - offset.dx);

    if (startX >= endX || startY >= endY) return;

    for (var y = startY; y < grid.tiles.length && y < endY; y++) {
      final row = grid.tiles[y];
      for (var x = startX; x < row.length && x < endX; x++) {
        buffer.setAttributes(
          offset.dx + x,
          offset.dy + y,
          char: row[x].char,
          fg: row[x].style.foreground?.argb,
          bg: row[x].style.background?.argb,
          modifiers: row[x].style.modifiers,
        );
      }
    }
  }
}

/// A cell inside a [Grid].
class GridCell {
  /// The character.
  final String char;

  /// The style.
  final Style style;

  /// Creates a GridCell.
  const GridCell(this.char, [this.style = Style.empty]);
}
