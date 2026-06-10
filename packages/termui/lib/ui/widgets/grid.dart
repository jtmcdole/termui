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
  void render(Buffer buffer, Rect area) {
    for (var y = 0; y < tiles.length; y++) {
      if (y >= area.height) break;
      final row = tiles[y];
      for (var x = 0; x < row.length; x++) {
        if (x >= area.width) break;
        final cell = buffer.getCell(x, y);
        if (cell != null) {
          cell.char = row[x].char;
          cell.style = row[x].style;
        }
      }
    }
  }
}
