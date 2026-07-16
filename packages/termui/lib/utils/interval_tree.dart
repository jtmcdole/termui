/// Represents an interval with numeric start and end values.
abstract interface class Interval<T extends num> {
  /// The start value of this interval.
  T get start;

  /// The end value of this interval.
  T get end;
}

/// Node in the AVL Interval Tree.
class IntervalNode<T extends num> {
  /// The underlying interval stored in this node.
  final Interval<T> interval;

  /// The maximum end value found in this node's subtree.
  T maxEnd;

  /// The height of this node in the AVL tree.
  int height;

  /// The left child of this node.
  IntervalNode<T>? left;

  /// The right child of this node.
  IntervalNode<T>? right;

  /// Creates a new [IntervalNode] wrapping the given [interval].
  IntervalNode(this.interval) : maxEnd = interval.end, height = 1;

  /// Recalculates height and maxEnd of this node based on its children.
  void update() {
    final leftNode = left;
    final rightNode = right;

    final leftHeight = leftNode?.height ?? 0;
    final rightHeight = rightNode?.height ?? 0;
    height = 1 + (leftHeight > rightHeight ? leftHeight : rightHeight);

    var max = interval.end;
    if (leftNode != null && leftNode.maxEnd.compareTo(max) > 0) {
      max = leftNode.maxEnd;
    }
    if (rightNode != null && rightNode.maxEnd.compareTo(max) > 0) {
      max = rightNode.maxEnd;
    }
    maxEnd = max;
  }
}

/// An AVL-based self-balancing Interval Tree.
class IntervalTree<T extends num> {
  /// The root node of the tree.
  IntervalNode<T>? root;

  /// Inserts a single interval.
  void insert(Interval<T> interval) {
    if (root == null) {
      root = IntervalNode<T>(interval);
      return;
    }

    // 1. Iterative Downward Path
    final path = <IntervalNode<T>>[];
    IntervalNode<T>? current = root;

    while (current != null) {
      path.add(current);
      if (interval.start.compareTo(current.interval.start) < 0) {
        if (current.left == null) {
          current.left = IntervalNode<T>(interval);
          break;
        }
        current = current.left;
      } else {
        if (current.right == null) {
          current.right = IntervalNode<T>(interval);
          break;
        }
        current = current.right;
      }
    }

    // 2. Backtrack & Balance
    for (int i = path.length - 1; i >= 0; i--) {
      final node = path[i];
      node.update();

      final balance = _getBalance(node);
      IntervalNode<T>? newSubtreeRoot;

      if (balance > 1) {
        final leftChild = node.left!;
        if (_getBalance(leftChild) >= 0) {
          newSubtreeRoot = _rotateRight(node);
        } else {
          node.left = _rotateLeft(leftChild);
          newSubtreeRoot = _rotateRight(node);
        }
      } else if (balance < -1) {
        final rightChild = node.right!;
        if (_getBalance(rightChild) <= 0) {
          newSubtreeRoot = _rotateLeft(node);
        } else {
          node.right = _rotateRight(rightChild);
          newSubtreeRoot = _rotateLeft(node);
        }
      }

      if (newSubtreeRoot != null) {
        if (i == 0) {
          root = newSubtreeRoot;
        } else {
          final parent = path[i - 1];
          if (parent.left == node) {
            parent.left = newSubtreeRoot;
          } else {
            parent.right = newSubtreeRoot;
          }
        }
      }
    }
  }

  /// Inserts multiple intervals. Optimized for sorted intervals.
  void insertAll(Iterable<Interval<T>> intervals) {
    final list = intervals.toList();

    // Verify/ensure list is sorted by start time
    bool isSorted = true;
    for (int i = 1; i < list.length; i++) {
      if (list[i].start.compareTo(list[i - 1].start) < 0) {
        isSorted = false;
        break;
      }
    }
    if (!isSorted) {
      list.sort((a, b) => a.start.compareTo(b.start));
    }

    if (root == null) {
      root = _buildBalanced(list, 0, list.length - 1);
    } else {
      // If tree is already populated, fallback to iterative insertion
      for (final interval in list) {
        insert(interval);
      }
    }
  }

  /// Queries all intervals that overlap with [start, end].
  /// Zero-allocation recursive search using callback.
  void query(T start, T end, void Function(Interval<T>) onOverlap) {
    _queryNode(root, start, end, onOverlap);
  }

  int _getBalance(IntervalNode<T>? node) {
    if (node == null) return 0;
    return (node.left?.height ?? 0) - (node.right?.height ?? 0);
  }

  IntervalNode<T> _rotateLeft(IntervalNode<T> x) {
    final y = x.right!;
    final t2 = y.left;

    y.left = x;
    x.right = t2;

    x.update();
    y.update();

    return y;
  }

  IntervalNode<T> _rotateRight(IntervalNode<T> y) {
    final x = y.left!;
    final t2 = x.right;

    x.right = y;
    y.left = t2;

    y.update();
    x.update();

    return x;
  }

  IntervalNode<T>? _buildBalanced(List<Interval<T>> list, int start, int end) {
    if (start > end) return null;

    final mid = start + ((end - start) >> 1);
    final node = IntervalNode<T>(list[mid]);

    node.left = _buildBalanced(list, start, mid - 1);
    node.right = _buildBalanced(list, mid + 1, end);

    node.update();
    return node;
  }

  void _queryNode(
    IntervalNode<T>? node,
    T qStart,
    T qEnd,
    void Function(Interval<T>) onOverlap,
  ) {
    if (node == null) return;

    // Prune branch: if the maximum end time in this subtree is less than the query start,
    // no intervals in this subtree can possibly overlap.
    if (node.maxEnd.compareTo(qStart) < 0) return;

    // Traverse left subtree
    if (node.left != null) {
      _queryNode(node.left, qStart, qEnd, onOverlap);
    }

    // Check overlap of current node
    if (node.interval.start.compareTo(qEnd) <= 0 &&
        node.interval.end.compareTo(qStart) >= 0) {
      onOverlap(node.interval);
    }

    // Traverse right subtree: only if current node's start is not beyond the query end
    if (node.interval.start.compareTo(qEnd) <= 0 && node.right != null) {
      _queryNode(node.right, qStart, qEnd, onOverlap);
    }
  }
}
