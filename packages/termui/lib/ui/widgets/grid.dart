import '../buffer.dart';
import '../layout.dart';

/// A widget that renders a static 2D grid of customized [Cell]s.
///
/// It acts like a tile map, copying characters and styles from the provided 2D
/// array directly into the local draw buffer up to the active constraints.
///
/// ### Example Usage
///
/// ```dart
/// final map = Grid([
///   [Cell('█', Style(foreground: Color(0xFF00FF00))), Cell(' ', Style.empty)],
///   [Cell(' ', Style.empty), Cell('█', Style(foreground: Color(0xFF00FF00)))],
/// ]);
/// ```
///
/// ### Properties and Settings
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `tiles` | [List]<[List]<[Cell]>> | A 2D list of cells representing rows and columns. |
class Grid extends Widget {
  /// A 2D list of cells representing rows and columns.
  final List<List<Cell>> tiles;

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

    for (var y = 0; y < grid.tiles.length; y++) {
      if (y >= h) break;
      final row = grid.tiles[y];
      for (var x = 0; x < row.length; x++) {
        if (x >= w) break;
        final cell = buffer.getCell(offset.dx + x, offset.dy + y);
        if (cell != null) {
          cell.char = row[x].char;
          cell.style = row[x].style;
        }
      }
    }
  }
}
