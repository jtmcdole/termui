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
  final N = sizes.length;
  final remaining = totalSize - usedSize;

  if (remaining <= 0 || N == 0) {
    var offset = 0;
    for (var i = 0; i < N; i++) {
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
  } else {
    // We have remaining space to distribute
    final sumOfSizes = List<int>.filled(N + 1, 0);
    for (var i = 0; i < N; i++) {
      sumOfSizes[i + 1] = sumOfSizes[i] + sizes[i];
    }

    int getChildOffset(int i) {
      switch (mainAxisAlignment) {
        case MainAxisAlignment.start:
          return sumOfSizes[i];
        case MainAxisAlignment.end:
          return remaining + sumOfSizes[i];
        case MainAxisAlignment.center:
          return (remaining ~/ 2) + sumOfSizes[i];
        case MainAxisAlignment.spaceBetween:
          if (N <= 1) return sumOfSizes[i];
          final numGaps = N - 1;
          final gapOffset = (remaining * i) ~/ numGaps;
          return gapOffset + sumOfSizes[i];
        case MainAxisAlignment.spaceAround:
          final numUnits = N * 2;
          final unitOffset = (remaining * (i * 2 + 1) / numUnits).floor();
          return unitOffset + sumOfSizes[i];
        case MainAxisAlignment.spaceEvenly:
          final numUnits = N + 1;
          final unitOffset = (remaining * (i + 1) / numUnits).floor();
          return unitOffset + sumOfSizes[i];
      }
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
