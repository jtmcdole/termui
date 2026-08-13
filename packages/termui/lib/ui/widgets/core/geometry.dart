/// Undocumented public member.
final class Size {
  /// The horizontal dimension.
  final int width;

  /// The vertical dimension.
  final int height;

  /// Creates a [Size] with the given [width] and [height].
  const Size(this.width, this.height);

  /// A size with zero width and height.
  static const Size zero = Size(0, 0);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Size && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'Size($width, $height)';
}

/// Represents an offset on the terminal cell grid coordinate space.
final class Offset {
  /// The horizontal offset.
  final int dx;

  /// The vertical offset.
  final int dy;

  /// Creates an [Offset] with the given [dx] and [dy].
  const Offset(this.dx, this.dy);

  /// An offset with zero horizontal and vertical values.
  static const Offset zero = Offset(0, 0);

  /// Adds [other] offset to this offset.
  Offset operator +(Offset other) => Offset(dx + other.dx, dy + other.dy);

  /// Subtracts [other] offset from this offset.
  Offset operator -(Offset other) => Offset(dx - other.dx, dy - other.dy);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Offset && other.dx == dx && other.dy == dy;

  @override
  int get hashCode => Object.hash(dx, dy);

  @override
  String toString() => 'Offset($dx, $dy)';
}

/// Defines layout boundaries inside terminal cell limits.
final class BoxConstraints {
  /// The minimum width allowed.
  final int minWidth;

  /// The maximum width allowed.
  final int maxWidth;

  /// The minimum height allowed.
  final int minHeight;

  /// The maximum height allowed.
  final int maxHeight;

  /// The default maximum value indicating unbounded constraints.
  static const int infinity = 999999;

  /// Creates box constraints with the given limits.
  const BoxConstraints({
    this.minWidth = 0,
    this.maxWidth = infinity,
    this.minHeight = 0,
    this.maxHeight = infinity,
  });

  /// Creates box constraints that require the given size exactly.
  BoxConstraints.tight(Size size)
    : minWidth = size.width,
      maxWidth = size.width,
      minHeight = size.height,
      maxHeight = size.height;

  /// Creates box constraints that forbid sizes larger than the given size.
  BoxConstraints.loose(Size size)
    : minWidth = 0,
      maxWidth = size.width,
      minHeight = 0,
      maxHeight = size.height;

  /// Creates box constraints that require the given width or height.
  const BoxConstraints.tightFor({int? width, int? height})
    : minWidth = width ?? 0,
      maxWidth = width ?? infinity,
      minHeight = height ?? 0,
      maxHeight = height ?? infinity;

  /// Clamps the input [Size] within these constraints.
  Size constrain(Size size) {
    return Size(
      size.width.clamp(minWidth, maxWidth),
      size.height.clamp(minHeight, maxHeight),
    );
  }

  /// Whether the maximum width is bounded.
  bool get hasBoundedWidth => maxWidth < infinity;

  /// Whether the maximum height is bounded.
  bool get hasBoundedHeight => maxHeight < infinity;

  /// Whether the constraints are tight (min and max match for both width and height).
  bool get isTight => minWidth == maxWidth && minHeight == maxHeight;

  /// Creates a copy of this [BoxConstraints] with updated values.
  BoxConstraints copyWith({
    int? minWidth,
    int? maxWidth,
    int? minHeight,
    int? maxHeight,
  }) {
    return BoxConstraints(
      minWidth: minWidth ?? this.minWidth,
      maxWidth: maxWidth ?? this.maxWidth,
      minHeight: minHeight ?? this.minHeight,
      maxHeight: maxHeight ?? this.maxHeight,
    );
  }

  /// Enforces the given [constraints] on this constraint.
  BoxConstraints enforce(BoxConstraints constraints) {
    return BoxConstraints(
      minWidth: minWidth.clamp(constraints.minWidth, constraints.maxWidth),
      maxWidth: maxWidth.clamp(constraints.minWidth, constraints.maxWidth),
      minHeight: minHeight.clamp(constraints.minHeight, constraints.maxHeight),
      maxHeight: maxHeight.clamp(constraints.minHeight, constraints.maxHeight),
    );
  }

  /// Tightens the constraints with the given width and height.
  BoxConstraints tighten({int? width, int? height}) {
    return BoxConstraints(
      minWidth: width == null ? minWidth : width.clamp(minWidth, maxWidth),
      maxWidth: width == null ? maxWidth : width.clamp(minWidth, maxWidth),
      minHeight: height == null
          ? minHeight
          : height.clamp(minHeight, maxHeight),
      maxHeight: height == null
          ? maxHeight
          : height.clamp(minHeight, maxHeight),
    );
  }

  @override
  String toString() {
    return 'BoxConstraints(minWidth: $minWidth, maxWidth: $maxWidth, minHeight: $minHeight, maxHeight: $maxHeight)';
  }
}

/// A 2D rectangle representing bounds in terminal space.
final class Rect {
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

  /// The left edge x-coordinate.
  int get left => x;

  /// The top edge y-coordinate.
  int get top => y;

  /// The right edge x-coordinate (exclusive).
  int get right => x + width;

  /// The bottom edge y-coordinate (exclusive).
  int get bottom => y + height;

  /// Whether ([cellX], [cellY]) is inside this rectangle.
  bool contains(int cellX, int cellY) {
    return cellX >= left && cellX < right && cellY >= top && cellY < bottom;
  }

  /// Calculates the intersection rectangle between this and [other].
  Rect intersect(Rect other) {
    final newLeft = left > other.left ? left : other.left;
    final newTop = top > other.top ? top : other.top;
    final newRight = right < other.right ? right : other.right;
    final newBottom = bottom < other.bottom ? bottom : other.bottom;
    final newWidth = (newRight - newLeft) < 0 ? 0 : newRight - newLeft;
    final newHeight = (newBottom - newTop) < 0 ? 0 : newBottom - newTop;
    return Rect(newLeft, newTop, newWidth, newHeight);
  }

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
final class EdgeInsets {
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
sealed class Constraint {
  /// Creates a new constraint.
  const Constraint();
}

/// A fixed length layout constraint.
final class LengthConstraint extends Constraint {
  /// The fixed layout length.
  final int length;

  /// Creates a constraint with a fixed [length].
  const LengthConstraint(this.length);
}

/// A percentage-based layout constraint relative to parent size.
final class PercentageConstraint extends Constraint {
  /// The percentage of the parent size (0 to 100).
  final int percentage;

  /// Creates a constraint based on a [percentage] of the parent size.
  const PercentageConstraint(this.percentage);
}

/// A proportional flexible space constraint.
final class FlexConstraint extends Constraint {
  /// The flex factor to determine the proportional size.
  final int flex;

  /// Creates a constraint with the specified [flex] factor.
  const FlexConstraint(this.flex);
}

/// A constraint with min and max bounds.
final class MinMaxConstraint extends Constraint {
  /// The minimum size bound.
  final int min;

  /// The maximum size bound.
  final int max;

  /// Creates a constraint with the specified [min] and [max] bounds.
  const MinMaxConstraint({this.min = 0, this.max = 999999});
}

/// A handle to a location in the widget tree.
final class Alignment {
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
