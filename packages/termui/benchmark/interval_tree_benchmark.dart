import 'dart:io';
import 'dart:math';
import 'package:termui/utils/interval_tree.dart';

class BenchmarkSpan implements Interval<int> {
  @override
  final int start;
  @override
  final int end;
  final int depth;
  final String name;

  BenchmarkSpan(this.start, this.end, this.depth, this.name);

  @override
  String toString() => '$name[$start, $end]';
}

class Query {
  final int start;
  final int end;
  Query(this.start, this.end);
}

void main() {
  print('========================================================');
  print('INTERVAL TREE MICROBENCHMARK');
  print('========================================================');

  // 1. Generate Dataset (200,000 trace spans)
  print('Generating 200,000 trace spans...');
  final rand = Random(42);
  int currentStart = 0;
  final spans = <BenchmarkSpan>[];

  for (int i = 0; i < 200000; i++) {
    // Average 10 us increment between span starts
    currentStart += rand.nextInt(20);

    // Duration distribution following realistic trace viewer characteristics:
    // - 60% short spans (< 100 us)
    // - 30% medium spans (100 us to 10,000 us)
    // - 9% long spans (10,000 us to 1,000,000 us)
    // - 1% very long spans (up to 900,000,000 us)
    int duration;
    final roll = rand.nextDouble();
    if (roll < 0.60) {
      duration = 1 + rand.nextInt(99);
    } else if (roll < 0.90) {
      duration = 100 + rand.nextInt(9900);
    } else if (roll < 0.99) {
      duration = 10000 + rand.nextInt(990000);
    } else {
      duration = 1000000 + rand.nextInt(900000000);
    }

    final end = currentStart + duration;
    final depth = rand.nextInt(20);
    spans.add(BenchmarkSpan(currentStart, end, depth, 'span_$i'));
  }

  final totalDuration = currentStart;
  print(
    'Dataset generated. Total trace duration: $totalDuration us (~${(totalDuration / 1000000).toStringAsFixed(2)}s).',
  );

  // 2. Prepare Viewport Queries (1,000 sequential & 1,000 random queries)
  // We'll benchmark query widths representing different zoom levels
  final queryWidths = [2000, 20000, 100000]; // 0.1%, 1%, 5% of trace duration

  // 3. Build IntervalTree
  print('Building IntervalTree...');
  final stopwatch = Stopwatch()..start();
  final tree = IntervalTree<int>();
  tree.insertAll(spans);
  stopwatch.stop();
  print('IntervalTree built in ${stopwatch.elapsedMilliseconds} ms.');

  // 4. Build Buckets for the Bucketed approaches
  print('Building Bucketed layout buckets...');
  stopwatch
    ..reset()
    ..start();
  final bucketMaxDurations = [
    100,
    500,
    2500,
    10000,
    50000,
    250000,
    1000000,
    5000000,
    25000000,
    1000000000,
  ];
  final buckets = List.generate(10, (_) => <BenchmarkSpan>[]);
  for (final s in spans) {
    final dur = s.end - s.start;
    if (dur < 100) {
      buckets[0].add(s);
    } else if (dur < 500) {
      buckets[1].add(s);
    } else if (dur < 2500) {
      buckets[2].add(s);
    } else if (dur < 10000) {
      buckets[3].add(s);
    } else if (dur < 50000) {
      buckets[4].add(s);
    } else if (dur < 250000) {
      buckets[5].add(s);
    } else if (dur < 1000000) {
      buckets[6].add(s);
    } else if (dur < 5000000) {
      buckets[7].add(s);
    } else if (dur < 25000000) {
      buckets[8].add(s);
    } else {
      buckets[9].add(s);
    }
  }
  stopwatch.stop();
  print('Buckets built in ${stopwatch.elapsedMilliseconds} ms.');

  // 5. Run Benchmarks for each query width
  for (final width in queryWidths) {
    print('\n--------------------------------------------------------');
    print('QUERY WIDTH: $width us');
    print('--------------------------------------------------------');

    // Generate queries
    final seqQueries = <Query>[];
    final seqStep = (totalDuration - width) > 0
        ? (totalDuration - width) / 1000
        : 1.0;
    for (int i = 0; i < 1000; i++) {
      final qStart = (i * seqStep).toInt();
      final qEnd = qStart + width;
      seqQueries.add(Query(qStart, qEnd));
    }

    final randQueries = <Query>[];
    final randLimit = (totalDuration - width) > 0 ? (totalDuration - width) : 1;
    for (int i = 0; i < 1000; i++) {
      final qStart = rand.nextInt(randLimit);
      final qEnd = qStart + width;
      randQueries.add(Query(qStart, qEnd));
    }

    // Verify Correctness (on a sample of 100 queries)
    _verifyCorrectness(
      spans,
      tree,
      buckets,
      bucketMaxDurations,
      seqQueries.take(100).toList(),
    );

    // Benchmark Sequential Queries
    print('Running Sequential Queries (1,000 iterations)...');
    _benchmarkSuite(spans, tree, buckets, bucketMaxDurations, seqQueries);

    // Benchmark Random Queries
    print('Running Random Queries (1,000 iterations)...');
    _benchmarkSuite(spans, tree, buckets, bucketMaxDurations, randQueries);
  }
}

void _verifyCorrectness(
  List<BenchmarkSpan> spans,
  IntervalTree<int> tree,
  List<List<BenchmarkSpan>> buckets,
  List<int> bucketMaxDurations,
  List<Query> queries,
) {
  for (final q in queries) {
    final linearMatches = <BenchmarkSpan>[];
    for (final s in spans) {
      if (s.start <= q.end && s.end >= q.start) {
        linearMatches.add(s);
      }
    }

    final treeMatches = <BenchmarkSpan>[];
    tree.query(q.start, q.end, (interval) {
      treeMatches.add(interval as BenchmarkSpan);
    });

    final bucketCorrectedMatches = <BenchmarkSpan>[];
    _queryBucketedCorrected(
      buckets,
      bucketMaxDurations,
      q,
      bucketCorrectedMatches.add,
    );

    final bucketOriginalMatches = <BenchmarkSpan>[];
    _queryBucketedOriginal(
      buckets,
      bucketMaxDurations,
      q,
      bucketOriginalMatches.add,
    );

    // Compare tree and corrected bucketed matches
    final linearSet = linearMatches.toSet();
    final treeSet = treeMatches.toSet();
    final correctedSet = bucketCorrectedMatches.toSet();

    if (linearSet.length != treeSet.length || !linearSet.containsAll(treeSet)) {
      print(
        'ERROR: IntervalTree correctness mismatch for query [${q.start}, ${q.end}]',
      );
      print('Linear matches count: ${linearSet.length}');
      print('Tree matches count: ${treeSet.length}');
      exit(1);
    }

    if (linearSet.length != correctedSet.length ||
        !linearSet.containsAll(correctedSet)) {
      print(
        'ERROR: BucketedCorrected correctness mismatch for query [${q.start}, ${q.end}]',
      );
      print('Linear matches count: ${linearSet.length}');
      print('BucketedCorrected matches count: ${correctedSet.length}');
      exit(1);
    }

    // Original bucketed matches will contain duplicates or false positives
    // because it passes non-overlapping spans starting before qStart to the callback.
    final falsePositives = bucketOriginalMatches.toSet().difference(linearSet);
    if (falsePositives.isNotEmpty) {
      // Log this finding, but don't exit, as we want to highlight the overhead difference.
    }
  }
}

void _benchmarkSuite(
  List<BenchmarkSpan> spans,
  IntervalTree<int> tree,
  List<List<BenchmarkSpan>> buckets,
  List<int> bucketMaxDurations,
  List<Query> queries,
) {
  const warmups = 3;
  const runs = 5;

  // WARMUPS
  for (int i = 0; i < warmups; i++) {
    _runLinear(spans, queries);
    _runTree(tree, queries);
    _runBucketedOriginal(buckets, bucketMaxDurations, queries);
    _runBucketedCorrected(buckets, bucketMaxDurations, queries);
  }

  // MEASURED RUNS
  double linearTime = double.infinity;
  double treeTime = double.infinity;
  double bucketedOriginalTime = double.infinity;
  double bucketedCorrectedTime = double.infinity;

  int linearTotal = 0;
  int treeTotal = 0;
  int bucketedOriginalTotal = 0;
  int bucketedCorrectedTotal = 0;

  for (int i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    linearTotal = _runLinear(spans, queries);
    sw.stop();
    if (sw.elapsedMicroseconds < linearTime) {
      linearTime = sw.elapsedMicroseconds.toDouble();
    }

    sw
      ..reset()
      ..start();
    treeTotal = _runTree(tree, queries);
    sw.stop();
    if (sw.elapsedMicroseconds < treeTime) {
      treeTime = sw.elapsedMicroseconds.toDouble();
    }

    sw
      ..reset()
      ..start();
    bucketedOriginalTotal = _runBucketedOriginal(
      buckets,
      bucketMaxDurations,
      queries,
    );
    sw.stop();
    if (sw.elapsedMicroseconds < bucketedOriginalTime) {
      bucketedOriginalTime = sw.elapsedMicroseconds.toDouble();
    }

    sw
      ..reset()
      ..start();
    bucketedCorrectedTotal = _runBucketedCorrected(
      buckets,
      bucketMaxDurations,
      queries,
    );
    sw.stop();
    if (sw.elapsedMicroseconds < bucketedCorrectedTime) {
      bucketedCorrectedTime = sw.elapsedMicroseconds.toDouble();
    }
  }

  final numQueries = queries.length;

  print(
    '  Flat Linear Scan   : ${linearTime / 1000} ms (avg ${(linearTime / numQueries).toStringAsFixed(2)} us/query, processed $linearTotal elements)',
  );
  print(
    '  Interval Tree      : ${treeTime / 1000} ms (avg ${(treeTime / numQueries).toStringAsFixed(2)} us/query, processed $treeTotal elements)',
  );
  print(
    '  Bucketed (Original): ${bucketedOriginalTime / 1000} ms (avg ${(bucketedOriginalTime / numQueries).toStringAsFixed(2)} us/query, processed $bucketedOriginalTotal elements)',
  );
  print(
    '  Bucketed (Corrected): ${bucketedCorrectedTime / 1000} ms (avg ${(bucketedCorrectedTime / numQueries).toStringAsFixed(2)} us/query, processed $bucketedCorrectedTotal elements)',
  );
}

int _runLinear(List<BenchmarkSpan> spans, List<Query> queries) {
  int totalMatches = 0;
  for (int qIdx = 0; qIdx < queries.length; qIdx++) {
    final q = queries[qIdx];
    for (int i = 0; i < spans.length; i++) {
      final s = spans[i];
      if (s.start <= q.end && s.end >= q.start) {
        totalMatches++;
      }
    }
  }
  return totalMatches;
}

int _runTree(IntervalTree<int> tree, List<Query> queries) {
  int totalMatches = 0;
  for (int qIdx = 0; qIdx < queries.length; qIdx++) {
    final q = queries[qIdx];
    tree.query(q.start, q.end, (interval) {
      totalMatches++;
    });
  }
  return totalMatches;
}

int _runBucketedOriginal(
  List<List<BenchmarkSpan>> buckets,
  List<int> bucketMaxDurations,
  List<Query> queries,
) {
  int totalMatches = 0;
  for (int qIdx = 0; qIdx < queries.length; qIdx++) {
    final q = queries[qIdx];
    for (int i = 0; i < buckets.length; i++) {
      final bucket = buckets[i];
      if (bucket.isEmpty) continue;

      final maxSpanDuration = bucketMaxDurations[i];
      int idx = 0;
      int low = 0;
      int high = bucket.length - 1;
      while (low <= high) {
        int mid = (low + high) >> 1;
        if (bucket[mid].start >= q.start) {
          idx = mid;
          high = mid - 1;
        } else {
          low = mid + 1;
        }
      }

      for (int j = idx - 1; j >= 0; j--) {
        final s = bucket[j];
        if (s.end >= q.start) {
          totalMatches++;
        }
        if (s.start < q.start - maxSpanDuration) {
          break;
        }
      }
      for (int j = idx; j < bucket.length; j++) {
        final s = bucket[j];
        if (s.start <= q.end) {
          totalMatches++;
        } else {
          break;
        }
      }
    }
  }
  return totalMatches;
}

int _runBucketedCorrected(
  List<List<BenchmarkSpan>> buckets,
  List<int> bucketMaxDurations,
  List<Query> queries,
) {
  int totalMatches = 0;
  for (int qIdx = 0; qIdx < queries.length; qIdx++) {
    final q = queries[qIdx];
    for (int i = 0; i < buckets.length; i++) {
      final bucket = buckets[i];
      if (bucket.isEmpty) continue;

      final maxSpanDuration = bucketMaxDurations[i];
      int idx = bucket.length;
      int low = 0;
      int high = bucket.length - 1;
      while (low <= high) {
        int mid = (low + high) >> 1;
        if (bucket[mid].start >= q.start) {
          idx = mid;
          high = mid - 1;
        } else {
          low = mid + 1;
        }
      }

      for (int j = idx - 1; j >= 0; j--) {
        final s = bucket[j];
        if (s.end >= q.start) {
          totalMatches++;
        }
        if (s.start < q.start - maxSpanDuration) {
          break;
        }
      }
      for (int j = idx; j < bucket.length; j++) {
        final s = bucket[j];
        if (s.start <= q.end) {
          totalMatches++;
        } else {
          break;
        }
      }
    }
  }
  return totalMatches;
}

void _queryBucketedOriginal(
  List<List<BenchmarkSpan>> buckets,
  List<int> bucketMaxDurations,
  Query q,
  void Function(BenchmarkSpan) onMatch,
) {
  for (int i = 0; i < buckets.length; i++) {
    final bucket = buckets[i];
    if (bucket.isEmpty) continue;

    final maxSpanDuration = bucketMaxDurations[i];
    int idx = 0;
    int low = 0;
    int high = bucket.length - 1;
    while (low <= high) {
      int mid = (low + high) >> 1;
      if (bucket[mid].start >= q.start) {
        idx = mid;
        high = mid - 1;
      } else {
        low = mid + 1;
      }
    }

    for (int j = idx - 1; j >= 0; j--) {
      final s = bucket[j];
      if (s.end >= q.start) {
        onMatch(s);
      }
      if (s.start < q.start - maxSpanDuration) {
        break;
      }
    }
    for (int j = idx; j < bucket.length; j++) {
      final s = bucket[j];
      if (s.start <= q.end) {
        onMatch(s);
      } else {
        break;
      }
    }
  }
}

void _queryBucketedCorrected(
  List<List<BenchmarkSpan>> buckets,
  List<int> bucketMaxDurations,
  Query q,
  void Function(BenchmarkSpan) onMatch,
) {
  for (int i = 0; i < buckets.length; i++) {
    final bucket = buckets[i];
    if (bucket.isEmpty) continue;

    final maxSpanDuration = bucketMaxDurations[i];
    int idx = bucket.length;
    int low = 0;
    int high = bucket.length - 1;
    while (low <= high) {
      int mid = (low + high) >> 1;
      if (bucket[mid].start >= q.start) {
        idx = mid;
        high = mid - 1;
      } else {
        low = mid + 1;
      }
    }

    for (int j = idx - 1; j >= 0; j--) {
      final s = bucket[j];
      if (s.end >= q.start) {
        onMatch(s);
      }
      if (s.start < q.start - maxSpanDuration) {
        break;
      }
    }
    for (int j = idx; j < bucket.length; j++) {
      final s = bucket[j];
      if (s.start <= q.end) {
        onMatch(s);
      } else {
        break;
      }
    }
  }
}
