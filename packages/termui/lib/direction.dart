/// Represents a 2D cardinal direction.
enum Direction implements Comparable<Direction> {
  /// The upward direction.
  up(character: 'A'),

  /// The downward direction.
  down(character: 'B'),

  /// The leftward direction.
  left(character: 'D'),

  /// The rightward direction.
  right(character: 'C');

  /// Creates a [Direction] with the associated ANSI control character.
  const Direction({required this.character});

  /// The ANSI control character representing this direction.
  final String character;

  @override
  int compareTo(Direction other) => character.compareTo(other.character);
}
