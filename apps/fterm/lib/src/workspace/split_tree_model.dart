import 'dart:math' as math;

/// Direction of binary split division in a [SplitNode].
enum SplitAxis {
  /// Side-by-side panes arranged along the horizontal axis (left | right).
  horizontal,

  /// Stacked panes arranged along the vertical axis (top / bottom).
  vertical,
}

/// Directional focus navigation across leaf panes (`hjkl` / arrow keys).
enum FocusDirection {
  /// Move focus to the nearest leaf left of the active pane.
  left,

  /// Move focus to the nearest leaf below the active pane.
  down,

  /// Move focus to the nearest leaf above the active pane.
  up,

  /// Move focus to the nearest leaf right of the active pane.
  right,
}

/// Normalized `[0.0, 1.0]` bounding box for one leaf pane inside a split tree.
final class NormalizedPaneRect {
  /// Left edge in `[0.0, 1.0]`.
  final double left;

  /// Top edge in `[0.0, 1.0]`.
  final double top;

  /// Width in `(0.0, 1.0]`.
  final double width;

  /// Height in `(0.0, 1.0]`.
  final double height;

  /// Creates an immutable normalized rectangle.
  const NormalizedPaneRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  /// Right edge (`left + width`).
  double get right => left + width;

  /// Bottom edge (`top + height`).
  double get bottom => top + height;

  /// Horizontal center in `[0.0, 1.0]`.
  double get centerX => left + width * 0.5;

  /// Vertical center in `[0.0, 1.0]`.
  double get centerY => top + height * 0.5;

  /// Stereo audio pan derived from [centerX], clamped to `[-1.0, 1.0]`.
  double get stereoPan => ((centerX * 2.0) - 1.0).clamp(-1.0, 1.0).toDouble();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NormalizedPaneRect &&
          other.left == left &&
          other.top == top &&
          other.width == width &&
          other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);
}

/// Immutable binary tree node representing either a split container or a pane.
sealed class SplitTreeNode {
  const SplitTreeNode();

  /// Minimum permitted split ratio.
  static const double minRatio = 0.1;

  /// Maximum permitted split ratio.
  static const double maxRatio = 0.9;

  /// Clamps a candidate split ratio into `[minRatio, maxRatio]`.
  static double clampRatio(double ratio) {
    if (ratio.isNaN) return 0.5;
    return ratio.clamp(minRatio, maxRatio).toDouble();
  }
}

/// Leaf node rendering a single terminal pane identified by [paneId].
final class PaneLeaf extends SplitTreeNode {
  /// Unique pane identifier.
  final String paneId;

  /// Creates a leaf node for [paneId].
  const PaneLeaf(this.paneId);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is PaneLeaf && other.paneId == paneId;

  @override
  int get hashCode => paneId.hashCode;
}

/// Binary split container dividing space along [axis] by [ratio].
final class SplitNode extends SplitTreeNode {
  /// Stable split node identifier used for ratio drag updates.
  final String splitId;

  /// Division axis (`horizontal` = left|right, `vertical` = top/bottom).
  final SplitAxis axis;

  /// Fraction of space allocated to [first] in `[0.1, 0.9]`.
  final double ratio;

  /// Left or top child subtree.
  final SplitTreeNode first;

  /// Right or bottom child subtree.
  final SplitTreeNode second;

  /// Creates an immutable [SplitNode] with clamped [ratio].
  SplitNode({
    required this.splitId,
    required this.axis,
    double ratio = 0.5,
    required this.first,
    required this.second,
  }) : ratio = SplitTreeNode.clampRatio(ratio);

  /// Returns a copy of this node with updated fields.
  SplitNode copyWith({
    String? splitId,
    SplitAxis? axis,
    double? ratio,
    SplitTreeNode? first,
    SplitTreeNode? second,
  }) => SplitNode(
    splitId: splitId ?? this.splitId,
    axis: axis ?? this.axis,
    ratio: ratio ?? this.ratio,
    first: first ?? this.first,
    second: second ?? this.second,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SplitNode &&
          other.splitId == splitId &&
          other.axis == axis &&
          other.ratio == ratio &&
          other.first == first &&
          other.second == second;

  @override
  int get hashCode => Object.hash(splitId, axis, ratio, first, second);
}

/// Immutable per-tab binary split layout, focus, and zoom state.
final class SplitTreeModel {
  static int _splitCounter = 0;

  /// Root node of the tab's binary split tree.
  final SplitTreeNode root;

  /// Currently focused leaf pane identifier.
  final String focusedPaneId;

  /// Currently zoomed leaf pane identifier (`tmux` `z`), if any.
  final String? zoomedPaneId;

  /// Creates an immutable split tree state.
  const SplitTreeModel({
    required this.root,
    required this.focusedPaneId,
    this.zoomedPaneId,
  });

  /// Creates a single-pane layout focused on [paneId].
  factory SplitTreeModel.single(String paneId) =>
      SplitTreeModel(root: PaneLeaf(paneId), focusedPaneId: paneId);

  /// In-order list of leaf pane identifiers from first to last.
  List<String> get paneIds {
    final ids = <String>[];
    _collectPaneIds(root, ids);
    return List<String>.unmodifiable(ids);
  }

  /// Total leaf pane count in this tab.
  int get paneCount => paneIds.length;

  /// Whether a valid leaf pane is currently zoomed fullscreen inside the tab.
  bool get isZoomed => zoomedPaneId != null && containsPane(zoomedPaneId!);

  /// Whether [paneId] exists in [root].
  bool containsPane(String paneId) => paneIds.contains(paneId);

  /// Normalized bounding boxes for every leaf pane in `[0..1]x[0..1]`.
  Map<String, NormalizedPaneRect> normalizedRects() {
    final out = <String, NormalizedPaneRect>{};
    _computeRects(
      root,
      const NormalizedPaneRect(left: 0, top: 0, width: 1, height: 1),
      out,
    );
    return out;
  }

  /// Normalized bounding box for [paneId], or `null` if absent.
  NormalizedPaneRect? rectOf(String paneId) => normalizedRects()[paneId];

  /// Stereo pan in `[-1.0, 1.0]` for [paneId]'s horizontal center.
  double panOf(String paneId) => rectOf(paneId)?.stereoPan ?? 0.0;

  /// Splits [targetPaneId] along [axis], replacing its leaf with a [SplitNode]
  /// holding the original pane and [newPaneId], and focuses [newPaneId].
  SplitTreeModel splitPane({
    required String targetPaneId,
    required String newPaneId,
    required SplitAxis axis,
    String? splitId,
    double ratio = 0.5,
  }) {
    if (!containsPane(targetPaneId) || containsPane(newPaneId)) {
      return this;
    }
    final assignedSplitId = splitId ?? _nextSplitId();
    final nextRoot = _replaceLeaf(
      root,
      targetPaneId,
      SplitNode(
        splitId: assignedSplitId,
        axis: axis,
        ratio: ratio,
        first: PaneLeaf(targetPaneId),
        second: PaneLeaf(newPaneId),
      ),
    );
    return SplitTreeModel(
      root: nextRoot,
      focusedPaneId: newPaneId,
      zoomedPaneId: null,
    );
  }

  /// Removes [paneId], promoting its sibling subtree when present, or returns
  /// `null` when closing the final leaf pane in the tree.
  SplitTreeModel? closePane(String paneId) {
    final beforeIds = paneIds;
    final removedIndex = beforeIds.indexOf(paneId);
    if (removedIndex < 0) return this;
    final nextRoot = _removeLeaf(root, paneId);
    if (nextRoot == null) return null;

    final nextIds = <String>[];
    _collectPaneIds(nextRoot, nextIds);
    final nextFocus = focusedPaneId == paneId
        ? nextIds[math.min(removedIndex, nextIds.length - 1)]
        : focusedPaneId;
    final nextZoom = (zoomedPaneId == paneId || nextIds.length <= 1)
        ? null
        : zoomedPaneId;
    return SplitTreeModel(
      root: nextRoot,
      focusedPaneId: nextFocus,
      zoomedPaneId: nextZoom,
    );
  }

  /// Moves focus to [paneId] (clearing zoom if switching to another pane).
  SplitTreeModel focusPane(String paneId) {
    if (!containsPane(paneId)) return this;
    if (paneId == focusedPaneId) return this;
    return SplitTreeModel(
      root: root,
      focusedPaneId: paneId,
      zoomedPaneId: zoomedPaneId == paneId ? zoomedPaneId : null,
    );
  }

  /// Moves focus geometrically from [focusedPaneId] toward [direction].
  SplitTreeModel focusDirection(FocusDirection direction) {
    final rects = normalizedRects();
    final origin = rects[focusedPaneId];
    if (origin == null || rects.length <= 1) return this;

    final candidateId = _pickDirectionalNeighbor(
      rects: rects,
      originId: focusedPaneId,
      origin: origin,
      direction: direction,
    );
    if (candidateId == null) return this;
    return focusPane(candidateId);
  }

  /// Cycles focus forward or backward through [paneIds].
  SplitTreeModel cycleFocus({bool reverse = false}) {
    final ids = paneIds;
    if (ids.length <= 1) return this;
    final idx = ids.indexOf(focusedPaneId);
    final step = reverse ? -1 : 1;
    final nextIdx = (idx + step + ids.length) % ids.length;
    return focusPane(ids[nextIdx]);
  }

  /// Updates the split [ratio] for [splitId].
  SplitTreeModel setSplitRatio(String splitId, double ratio) {
    final nextRoot = _updateSplitRatio(
      root,
      splitId,
      SplitTreeNode.clampRatio(ratio),
    );
    if (identical(nextRoot, root)) return this;
    return SplitTreeModel(
      root: nextRoot,
      focusedPaneId: focusedPaneId,
      zoomedPaneId: zoomedPaneId,
    );
  }

  /// Toggles `tmux`-style fullscreen zoom on [paneId] (or [focusedPaneId]).
  SplitTreeModel toggleZoom([String? paneId]) {
    if (paneCount <= 1) {
      return zoomedPaneId == null
          ? this
          : SplitTreeModel(root: root, focusedPaneId: focusedPaneId);
    }
    final target = paneId ?? focusedPaneId;
    if (!containsPane(target)) return this;
    final nextZoom = zoomedPaneId == target ? null : target;
    return SplitTreeModel(
      root: root,
      focusedPaneId: target,
      zoomedPaneId: nextZoom,
    );
  }

  static String _nextSplitId() => 'split-${++_splitCounter}';

  static void _collectPaneIds(SplitTreeNode node, List<String> out) {
    switch (node) {
      case PaneLeaf(:final paneId):
        out.add(paneId);
      case SplitNode(:final first, :final second):
        _collectPaneIds(first, out);
        _collectPaneIds(second, out);
    }
  }

  static void _computeRects(
    SplitTreeNode node,
    NormalizedPaneRect bounds,
    Map<String, NormalizedPaneRect> out,
  ) {
    switch (node) {
      case PaneLeaf(:final paneId):
        out[paneId] = bounds;
      case SplitNode(:final axis, :final ratio, :final first, :final second):
        if (axis == SplitAxis.horizontal) {
          final firstWidth = bounds.width * ratio;
          _computeRects(
            first,
            NormalizedPaneRect(
              left: bounds.left,
              top: bounds.top,
              width: firstWidth,
              height: bounds.height,
            ),
            out,
          );
          _computeRects(
            second,
            NormalizedPaneRect(
              left: bounds.left + firstWidth,
              top: bounds.top,
              width: bounds.width - firstWidth,
              height: bounds.height,
            ),
            out,
          );
        } else {
          final firstHeight = bounds.height * ratio;
          _computeRects(
            first,
            NormalizedPaneRect(
              left: bounds.left,
              top: bounds.top,
              width: bounds.width,
              height: firstHeight,
            ),
            out,
          );
          _computeRects(
            second,
            NormalizedPaneRect(
              left: bounds.left,
              top: bounds.top + firstHeight,
              width: bounds.width,
              height: bounds.height - firstHeight,
            ),
            out,
          );
        }
    }
  }

  static SplitTreeNode _replaceLeaf(
    SplitTreeNode node,
    String targetPaneId,
    SplitTreeNode replacement,
  ) {
    switch (node) {
      case PaneLeaf(:final paneId):
        return paneId == targetPaneId ? replacement : node;
      case SplitNode(:final first, :final second):
        final nextFirst = _replaceLeaf(first, targetPaneId, replacement);
        if (!identical(nextFirst, first)) {
          return node.copyWith(first: nextFirst);
        }
        final nextSecond = _replaceLeaf(second, targetPaneId, replacement);
        if (!identical(nextSecond, second)) {
          return node.copyWith(second: nextSecond);
        }
        return node;
    }
  }

  static SplitTreeNode? _removeLeaf(SplitTreeNode node, String targetPaneId) {
    switch (node) {
      case PaneLeaf(:final paneId):
        return paneId == targetPaneId ? null : node;
      case SplitNode(:final first, :final second):
        final nextFirst = _removeLeaf(first, targetPaneId);
        if (nextFirst == null) return second;
        if (!identical(nextFirst, first)) {
          return node.copyWith(first: nextFirst);
        }
        final nextSecond = _removeLeaf(second, targetPaneId);
        if (nextSecond == null) return first;
        if (!identical(nextSecond, second)) {
          return node.copyWith(second: nextSecond);
        }
        return node;
    }
  }

  static SplitTreeNode _updateSplitRatio(
    SplitTreeNode node,
    String splitId,
    double ratio,
  ) {
    switch (node) {
      case PaneLeaf():
        return node;
      case SplitNode(:final first, :final second):
        if (node.splitId == splitId) {
          return node.ratio == ratio ? node : node.copyWith(ratio: ratio);
        }
        final nextFirst = _updateSplitRatio(first, splitId, ratio);
        if (!identical(nextFirst, first)) {
          return node.copyWith(first: nextFirst);
        }
        final nextSecond = _updateSplitRatio(second, splitId, ratio);
        if (!identical(nextSecond, second)) {
          return node.copyWith(second: nextSecond);
        }
        return node;
    }
  }

  static String? _pickDirectionalNeighbor({
    required Map<String, NormalizedPaneRect> rects,
    required String originId,
    required NormalizedPaneRect origin,
    required FocusDirection direction,
  }) {
    String? bestId;
    (double, double, double)? bestScore;
    for (final MapEntry(:key, :value) in rects.entries) {
      if (key == originId) continue;
      final score = _scoreNeighbor(origin, value, direction);
      if (score == null) continue;
      if (bestScore == null || _isBetterScore(score, bestScore)) {
        bestId = key;
        bestScore = score;
      }
    }
    return bestId;
  }

  static (double, double, double)? _scoreNeighbor(
    NormalizedPaneRect origin,
    NormalizedPaneRect candidate,
    FocusDirection direction,
  ) {
    const epsilon = 1e-6;
    final primaryGap = switch (direction) {
      FocusDirection.left => origin.left - candidate.right,
      FocusDirection.right => candidate.left - origin.right,
      FocusDirection.up => origin.top - candidate.bottom,
      FocusDirection.down => candidate.top - origin.bottom,
    };
    if (primaryGap < -epsilon) return null;

    final overlap = _perpendicularOverlap(origin, candidate, direction);
    final secondaryDist = switch (direction) {
      FocusDirection.left ||
      FocusDirection.right => (candidate.centerY - origin.centerY).abs(),
      FocusDirection.up ||
      FocusDirection.down => (candidate.centerX - origin.centerX).abs(),
    };
    final centerDist = switch (direction) {
      FocusDirection.left => origin.centerX - candidate.centerX,
      FocusDirection.right => candidate.centerX - origin.centerX,
      FocusDirection.up => origin.centerY - candidate.centerY,
      FocusDirection.down => candidate.centerY - origin.centerY,
    };
    // Prefer candidates with direct perpendicular overlap first, then minimum
    // primary-axis distance, then nearest perpendicular alignment.
    final nonOverlapping = overlap <= epsilon ? 1.0 : 0.0;
    return (
      nonOverlapping,
      math.max(0.0, primaryGap) + centerDist * 0.01,
      secondaryDist,
    );
  }

  static double _perpendicularOverlap(
    NormalizedPaneRect a,
    NormalizedPaneRect b,
    FocusDirection direction,
  ) {
    final (startA, endA, startB, endB) = switch (direction) {
      FocusDirection.left ||
      FocusDirection.right => (a.top, a.bottom, b.top, b.bottom),
      FocusDirection.up ||
      FocusDirection.down => (a.left, a.right, b.left, b.right),
    };
    return math.min(endA, endB) - math.max(startA, startB);
  }

  static bool _isBetterScore(
    (double, double, double) a,
    (double, double, double) b,
  ) {
    if (a.$1 != b.$1) return a.$1 < b.$1;
    if ((a.$2 - b.$2).abs() > 1e-6) return a.$2 < b.$2;
    return a.$3 < b.$3;
  }
}
