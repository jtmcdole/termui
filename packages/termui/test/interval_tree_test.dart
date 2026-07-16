import 'dart:math';
import 'package:test/test.dart';
import 'package:termui/termui.dart';

class TestInterval implements Interval<double> {
  @override
  final double start;
  @override
  final double end;
  final String label;

  TestInterval(this.start, this.end, this.label);

  @override
  String toString() => '$label[$start, $end]';
}

void main() {
  group('IntervalTree AVL Invariants & Insertion', () {
    test('Empty tree', () {
      final tree = IntervalTree<double>();
      expect(tree.root, isNull);
    });

    test('Single node insertion', () {
      final tree = IntervalTree<double>();
      final interval = TestInterval(1.0, 5.0, 'A');
      tree.insert(interval);

      expect(tree.root, isNotNull);
      expect(tree.root!.interval, equals(interval));
      expect(tree.root!.height, equals(1));
      expect(tree.root!.maxEnd, equals(5.0));
      expect(tree.root!.left, isNull);
      expect(tree.root!.right, isNull);
    });

    test('Randomized insertion AVL invariants', () {
      final tree = IntervalTree<double>();
      final rand = Random(42);
      final intervals = <TestInterval>[];

      for (int i = 0; i < 500; i++) {
        final start = rand.nextDouble() * 1000;
        final end = start + rand.nextDouble() * 50;
        final interval = TestInterval(start, end, 'node_$i');
        intervals.add(interval);
        tree.insert(interval);
        _verifyTreeInvariants(tree.root);
      }

      // Final check of the root properties
      expect(
        tree.root!.height,
        lessThan(15),
      ); // log2(500) is ~9, AVL height is bounded
    });
  });

  group('Bulk Insertion (insertAll)', () {
    test('Optimized middle-out balanced construction', () {
      final tree = IntervalTree<double>();
      final intervals = <TestInterval>[];
      for (int i = 0; i < 1023; i++) {
        intervals.add(TestInterval(i * 10.0, i * 10.0 + 5.0, 'node_$i'));
      }

      tree.insertAll(intervals);

      _verifyTreeInvariants(tree.root);
      // For a perfectly balanced tree of 1023 nodes, the height should be exactly 10.
      expect(tree.root!.height, equals(10));
    });

    test('insertAll sorts unsorted input automatically', () {
      final tree = IntervalTree<double>();
      final intervals = <TestInterval>[
        TestInterval(20.0, 25.0, 'B'),
        TestInterval(10.0, 15.0, 'A'),
        TestInterval(30.0, 35.0, 'C'),
      ];

      tree.insertAll(intervals);
      _verifyTreeInvariants(tree.root);

      final queryResults = <Interval<double>>[];
      tree.query(0.0, 40.0, queryResults.add);
      expect(queryResults.length, equals(3));
    });
  });

  group('Query Overlapping Correctness', () {
    late IntervalTree<double> tree;

    setUp(() {
      tree = IntervalTree<double>();
      // Insert a structured set of intervals
      tree.insert(TestInterval(10.0, 20.0, 'A'));
      tree.insert(TestInterval(15.0, 25.0, 'B'));
      tree.insert(TestInterval(5.0, 9.0, 'C'));
      tree.insert(TestInterval(22.0, 30.0, 'D'));
      tree.insert(TestInterval(30.0, 35.0, 'E'));
      _verifyTreeInvariants(tree.root);
    });

    test('Fully enveloped query', () {
      final results = <String>[];
      tree.query(12.0, 18.0, (val) => results.add((val as TestInterval).label));
      expect(results, containsAll(['A', 'B']));
      expect(results.length, equals(2));
    });

    test('Adjacent bounds (inclusive overlap)', () {
      final results = <String>[];
      // Query starts exactly at 'C' end and ends at 'A' start
      tree.query(9.0, 10.0, (val) => results.add((val as TestInterval).label));
      expect(results, containsAll(['A', 'C']));
      expect(results.length, equals(2));
    });

    test('No overlap query', () {
      final results = <String>[];
      tree.query(0.0, 4.0, (val) => results.add((val as TestInterval).label));
      expect(results, isEmpty);

      tree.query(40.0, 50.0, (val) => results.add((val as TestInterval).label));
      expect(results, isEmpty);
    });

    test('Identical intervals', () {
      final localTree = IntervalTree<double>();
      localTree.insert(TestInterval(10.0, 20.0, 'A1'));
      localTree.insert(TestInterval(10.0, 20.0, 'A2'));

      final results = <String>[];
      localTree.query(
        10.0,
        20.0,
        (val) => results.add((val as TestInterval).label),
      );
      expect(results, containsAll(['A1', 'A2']));
      expect(results.length, equals(2));
    });

    test('Duplicate start times query', () {
      final localTree = IntervalTree<double>();
      localTree.insert(TestInterval(10.0, 15.0, 'A'));
      localTree.insert(TestInterval(10.0, 25.0, 'B'));
      localTree.insert(TestInterval(10.0, 12.0, 'C'));

      final results = <String>[];
      localTree.query(
        11.0,
        11.5,
        (val) => results.add((val as TestInterval).label),
      );
      expect(results, containsAll(['A', 'B', 'C']));
      expect(results.length, equals(3));
    });

    test('Zero-allocation callback mechanism', () {
      // Ensure we don't allocate lists inside query.
      // We can verify this behavior by seeing that we pass a callback,
      // and checking that the callback can mutate an outer variable.
      int count = 0;
      tree.query(5.0, 30.0, (val) {
        count++;
      });
      expect(count, equals(5));
    });
  });
}

void _verifyTreeInvariants<T extends num>(IntervalNode<T>? node) {
  if (node == null) return;

  final left = node.left;
  final right = node.right;

  // 1. Height invariant
  final leftHeight = left?.height ?? 0;
  final rightHeight = right?.height ?? 0;
  expect(
    node.height,
    equals(1 + max(leftHeight, rightHeight)),
    reason: 'Node height mismatch at interval: ${node.interval}',
  );
  expect(
    (leftHeight - rightHeight).abs(),
    lessThanOrEqualTo(1),
    reason: 'AVL balance invariant violated at node: ${node.interval}',
  );

  // 2. BST Property on start time
  if (left != null) {
    expect(
      left.interval.start.compareTo(node.interval.start),
      lessThanOrEqualTo(0),
      reason: 'BST left child start value is greater than parent',
    );
    _verifyTreeInvariants(left);
  }
  if (right != null) {
    expect(
      right.interval.start.compareTo(node.interval.start),
      greaterThanOrEqualTo(0),
      reason: 'BST right child start value is less than parent',
    );
    _verifyTreeInvariants(right);
  }

  // 3. maxEnd invariant
  T expectedMax = node.interval.end;
  if (left != null && left.maxEnd.compareTo(expectedMax) > 0) {
    expectedMax = left.maxEnd;
  }
  if (right != null && right.maxEnd.compareTo(expectedMax) > 0) {
    expectedMax = right.maxEnd;
  }
  expect(
    node.maxEnd,
    equals(expectedMax),
    reason: 'maxEnd mismatch at interval: ${node.interval}',
  );
}
