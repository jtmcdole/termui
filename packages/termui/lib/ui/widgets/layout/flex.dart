import 'dart:math';
import 'package:termui/termui.dart';

/// Undocumented public member.
enum CrossAxisAlignment {
  /// Align children to the start of the cross axis.
  start,

  /// Align children to the center of the cross axis.
  center,

  /// Align children to the end of the cross axis.
  end,

  /// Stretch children to fill the cross axis.
  stretch,
}

/// How children are aligned along the main axis.
enum MainAxisAlignment {
  /// Place children as close to the start of the main axis as possible.
  start,

  /// Place children as close to the end of the main axis as possible.
  end,

  /// Place children as close to the center of the main axis as possible.
  center,

  /// Place free space evenly between children.
  spaceBetween,

  /// Place free space evenly between children, and half of that space before the first and after the last child.
  spaceAround,

  /// Place free space evenly between children, and before the first and after the last child.
  spaceEvenly,
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
List<Rect> splitRect(
  Rect area,
  List<Constraint> constraints,
  LayoutDirection direction, {
  MainAxisAlignment mainAxisAlignment = MainAxisAlignment.start,
}) {
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
    switch (constraints[i]) {
      case LengthConstraint(:final length):
        sizes[i] = length;
        usedSize += length;
      case PercentageConstraint(:final percentage):
        final size = (totalSize * percentage / 100).round();
        sizes[i] = size;
        usedSize += size;
      case FlexConstraint(:final flex):
        totalFlex += flex;
        flexIndices.add(i);
      case MinMaxConstraint(:final min):
        sizes[i] = min;
        usedSize += min;
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

  // 3. (Removed: Scale down if used size exceeds total size)
  // We no longer forcefully scale down rigid constraints. This allows layouts
  // to correctly overflow their bounds so the rendering engine can detect it
  // and display a visual warning, rather than silently hiding elements.

  // 4. Respect Max Constraints on MinMax
  for (var i = 0; i < constraints.length; i++) {
    if (constraints[i] case MinMaxConstraint(:final min, :final max)) {
      sizes[i] = sizes[i].clamp(min, max);
    }
    sizes[i] = max(0, sizes[i]);
  }

  // 5. Construct child Rects
  final rects = <Rect>[];
  final N = sizes.length;
  final remaining = totalSize - usedSize;

  if (N == 0) return rects;

  final sumOfSizes = List<int>.filled(N + 1, 0);
  for (var i = 0; i < N; i++) {
    sumOfSizes[i + 1] = sumOfSizes[i] + sizes[i];
  }

  int getChildOffset(int i) {
    if (remaining <= 0) {
      return switch (mainAxisAlignment) {
        .start => sumOfSizes[i],
        .end => remaining + sumOfSizes[i],
        .center => (remaining ~/ 2) + sumOfSizes[i],
        _ =>
          sumOfSizes[i], // Fallback to start for spaced alignments when overflowing
      };
    }
    return switch (mainAxisAlignment) {
      .start => sumOfSizes[i],
      .end => remaining + sumOfSizes[i],
      .center => (remaining ~/ 2) + sumOfSizes[i],
      .spaceBetween =>
        N <= 1 ? sumOfSizes[i] : ((remaining * i) ~/ (N - 1)) + sumOfSizes[i],
      .spaceAround =>
        (remaining * (i * 2 + 1) / (N * 2)).floor() + sumOfSizes[i],
      .spaceEvenly => (remaining * (i + 1) / (N + 1)).floor() + sumOfSizes[i],
    };
  }

  for (var i = 0; i < N; i++) {
    final size = sizes[i];
    final offset = getChildOffset(i);
    if (direction == LayoutDirection.horizontal) {
      rects.add(
        Rect(clampedArea.x + offset, clampedArea.y, size, clampedArea.height),
      );
    } else {
      rects.add(
        Rect(clampedArea.x, clampedArea.y + offset, clampedArea.width, size),
      );
    }
  }

  return rects;
}

/// Undocumented public member.
///
/// Retrieves the layout constraint for the given [widget].
/// If the optional [element] parameter is provided, we query its intrinsic
/// size by calling the element's polymorphic layout getters.
Constraint getConstraint(
  Widget widget,
  LayoutDirection direction, {
  int crossSize = 0,
  Element? element,
}) {
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
  if (direction == LayoutDirection.vertical) {
    final intH = element != null
        ? element.getIntrinsicHeight(crossSize)
        : widget.getIntrinsicHeight(crossSize);
    if (intH > 0) {
      return LengthConstraint(intH);
    }
  } else {
    final intW = element != null
        ? element.getIntrinsicWidth(crossSize)
        : widget.getIntrinsicWidth(crossSize);
    if (intW > 0) {
      return LengthConstraint(intW);
    }
  }
  return const FlexConstraint(1);
}

/// A layout widget that arranges its children horizontally.
