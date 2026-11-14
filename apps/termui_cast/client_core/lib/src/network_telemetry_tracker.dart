import 'dart:typed_data';

import 'package:termui_cast_protocol/termui_cast_protocol.dart';

import 'models.dart';

/// Rolling 32-second (`128 x 250ms` buckets) network throughput and frame rate tracker.
final class NetworkTelemetryTracker {
  /// Number of rolling time buckets retained in history.
  static const int bucketCount = 128;

  /// Width of each time bucket in milliseconds.
  static const int bucketMs = 250;

  /// Conversion factor from per-bucket counts to per-second rates.
  static const double bucketsPerSec = 1000.0 / bucketMs;

  final Float64List _rxBytesRateBuckets = Float64List(bucketCount);
  final Float64List _frameRateBuckets = Float64List(bucketCount);

  int? _currentBucketIndex;
  int _lastObservedRepoRxBytes = 0;
  int _totalRxFrames = 0;
  int _snapshotCount = 0;
  int _deltaCount = 0;
  CastNetworkStats? _cachedSnapshot;
  int? _cachedBucketIndex;
  int _cachedRxFrames = -1;
  int _cachedRxBytes = -1;
  int _cachedTxBytes = -1;

  /// Creates a telemetry tracker seeded with [initialRepoRxBytes].
  NetworkTelemetryTracker({int initialRepoRxBytes = 0})
    : _lastObservedRepoRxBytes = initialRepoRxBytes;

  /// Records an inbound [message] and computes wire bytes from [currentRepoRxBytes].
  void recordInbound(
    DateTime now,
    CastMessage message,
    int currentRepoRxBytes,
  ) {
    final wireBytes = currentRepoRxBytes > _lastObservedRepoRxBytes
        ? currentRepoRxBytes - _lastObservedRepoRxBytes
        : 0;
    _lastObservedRepoRxBytes = currentRepoRxBytes;
    recordFrame(now, message, wireBytes);
  }

  /// Records an inbound [message] of [wireBytes] at [now].
  void recordFrame(DateTime now, CastMessage message, int wireBytes) {
    _advanceTo(now);
    _totalRxFrames++;
    if (message is BufferSnapshotFrame) {
      _snapshotCount++;
    } else if (message is BufferDeltaFrame) {
      _deltaCount++;
    }
    const last = bucketCount - 1;
    _rxBytesRateBuckets[last] += wireBytes * bucketsPerSec;
    _frameRateBuckets[last] += bucketsPerSec;
    _cachedSnapshot = null;
  }

  /// Computes or returns a memoized [CastNetworkStats] snapshot at [now].
  CastNetworkStats snapshot(
    DateTime now, {
    required int totalRxBytes,
    required int totalTxBytes,
  }) {
    _advanceTo(now);
    final cached = _cachedSnapshot;
    if (cached != null &&
        _cachedBucketIndex == _currentBucketIndex &&
        _cachedRxFrames == _totalRxFrames &&
        _cachedRxBytes == totalRxBytes &&
        _cachedTxBytes == totalTxBytes) {
      return cached;
    }

    var peakRx = 0.0;
    var peakFps = 0.0;
    for (var i = 0; i < bucketCount; i++) {
      final rx = _rxBytesRateBuckets[i];
      final fps = _frameRateBuckets[i];
      if (rx > peakRx) peakRx = rx;
      if (fps > peakFps) peakFps = fps;
    }

    const last = bucketCount - 1;
    final currentRx = _rxBytesRateBuckets[last] > 0
        ? _rxBytesRateBuckets[last]
        : _rxBytesRateBuckets[last - 1];
    final currentFps = _frameRateBuckets[last] > 0
        ? _frameRateBuckets[last]
        : _frameRateBuckets[last - 1];

    final stats = CastNetworkStats(
      totalRxBytes: totalRxBytes,
      totalTxBytes: totalTxBytes,
      totalRxFrames: _totalRxFrames,
      snapshotCount: _snapshotCount,
      deltaCount: _deltaCount,
      currentRxBytesPerSec: currentRx,
      peakRxBytesPerSec: peakRx,
      currentFramesPerSec: currentFps,
      peakFramesPerSec: peakFps,
      rxBytesPerSecHistory: List<double>.unmodifiable(_rxBytesRateBuckets),
      framesPerSecHistory: List<double>.unmodifiable(_frameRateBuckets),
    );
    _cachedSnapshot = stats;
    _cachedBucketIndex = _currentBucketIndex;
    _cachedRxFrames = _totalRxFrames;
    _cachedRxBytes = totalRxBytes;
    _cachedTxBytes = totalTxBytes;
    return stats;
  }

  void _advanceTo(DateTime now) {
    final targetIdx = now.millisecondsSinceEpoch ~/ bucketMs;
    final prevIdx = _currentBucketIndex;
    if (prevIdx == null || targetIdx < prevIdx) {
      _currentBucketIndex = targetIdx;
      return;
    }
    final delta = targetIdx - prevIdx;
    if (delta == 0) return;
    _currentBucketIndex = targetIdx;
    _cachedSnapshot = null;
    if (delta >= bucketCount) {
      _rxBytesRateBuckets.fillRange(0, bucketCount, 0.0);
      _frameRateBuckets.fillRange(0, bucketCount, 0.0);
      return;
    }
    final keep = bucketCount - delta;
    _rxBytesRateBuckets
      ..setRange(0, keep, _rxBytesRateBuckets, delta)
      ..fillRange(keep, bucketCount, 0.0);
    _frameRateBuckets
      ..setRange(0, keep, _frameRateBuckets, delta)
      ..fillRange(keep, bucketCount, 0.0);
  }
}
