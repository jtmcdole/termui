import 'dart:async';
import 'dart:typed_data';
import 'package:clock/clock.dart';
import 'package:file/file.dart';
import 'fs_locator.dart';
import 'tracer_sink.dart';
import 'sink_creator.dart';

/// Categories for surgical profiling of the framework's subsystems.
enum TraceCategory {
  /// Traces related to building widgets.
  build,

  /// Traces related to layout.
  layout,

  /// Traces related to painting/drawing.
  paint,

  /// Traces related to user input events.
  events,

  /// Traces related to the compositor.
  compositor,

  /// Traces related to GPU shader rendering and presentation.
  gpu,
}

/// Represents event phases in the trace log.
class Phase {
  /// A begin phase event.
  static const int begin = 1;

  /// An end phase event.
  static const int end = 2;

  /// An instant phase event.
  static const int instant = 3;

  /// A numeric counter phase event (`ph: "C"` in Chrome Trace Event Format).
  static const int counter = 4;
}

/// A high-performance, low-overhead event tracer.
class Tracer {
  /// Active configuration of trace categories to record.
  static Set<TraceCategory> activeCategories = {...TraceCategory.values};

  /// Whether the tracer is currently enabled and recording events.
  static bool isEnabled = false;

  static const int _bufferSize = 262144; // Must be power of 2 (256k events)
  static const int _eventSize = 2; // 2 words (16 bytes) per event
  static const int _bufferLength = _bufferSize * _eventSize;
  static const int _bufferMask = _bufferLength - 1;

  static List<int> _activeBuffer = _createBuffer(_bufferLength);
  static Map<int, Map<String, String>> _activeMetadata = {};
  static List<int> _backupBuffer = _createBuffer(_bufferLength);
  static int _writeIndex = 0;

  static final Map<String, int> _stringTable = {};
  static final List<String> _idToStringList = [];
  static int _nextStringId = 1;

  static final Stopwatch _stopwatch = Stopwatch();
  static int _baseEpochUs = 0;
  static int _isolateId = 1;

  static TracerSink? _sink;

  static List<int> _createBuffer(int length) {
    try {
      return Int64List(length);
    } catch (_) {
      return List<int>.filled(length, 0);
    }
  }

  /// Initialize the tracer subsystem.
  static Future<void> initialize() async {
    _activeBuffer = _createBuffer(_bufferLength);
    _backupBuffer = _createBuffer(_bufferLength);
    _writeIndex = 0;
    _isolateId = 1; // Default fallback for web platforms

    // Register common standard strings
    registerString('Unknown');
  }

  /// Start a recording session writing to a file path on [fs].
  static Future<void> start(String traceFilePath, {FileSystem? fs}) async {
    final fileSystem = fs ?? getDefaultFileSystem();
    await startWithSink(
      (baseEpochUs) => createTracerSink(fileSystem, traceFilePath, baseEpochUs),
    );
  }

  /// Start a recording session streaming events into a custom [TracerSink]
  /// created with the session's `baseEpochUs`.
  static Future<void> startWithSink(
    TracerSink Function(int baseEpochUs) createSink,
  ) async {
    if (isEnabled) return;

    _writeIndex = 0;
    _activeMetadata = {};
    _activeBuffer.fillRange(0, _activeBuffer.length, 0);

    _baseEpochUs = clock.now().microsecondsSinceEpoch;
    _stopwatch.reset();
    _stopwatch.start();

    _sink = createSink(_baseEpochUs);

    // Synchronize the current string table with the sink.
    if (_idToStringList.isNotEmpty) {
      _sink!.add(_createBuffer(0), List<String>.from(_idToStringList));
    }

    isEnabled = true;
  }

  /// Packs [stringId], [isolateId], and [phase] into a single word using
  /// JavaScript-safe 53-bit arithmetic (compatible with 64-bit VM/WASM and
  /// 32-bit-bitwise Dart2JS runtimes).
  @pragma('vm:prefer-inline')
  static int packWord0(int stringId, int isolateId, int phase) =>
      stringId * 0x100000000 + ((isolateId & 0xFFFFFF) << 8) + (phase & 0xFF);

  /// Unpacks the string table ID from [word0] without 64-bit right shifts.
  @pragma('vm:prefer-inline')
  static int unpackStringId(int word0) => (word0 ~/ 0x100000000) & 0xFFFFFFFF;

  /// Unpacks the 24-bit isolate ID from [word0].
  @pragma('vm:prefer-inline')
  static int unpackIsolateId(int word0) => (word0 ~/ 256) & 0xFFFFFF;

  /// Unpacks the 8-bit [Phase] value from [word0].
  @pragma('vm:prefer-inline')
  static int unpackPhase(int word0) => word0 & 0xFF;

  /// Records a Chrome Trace counter event (`ph: "C"`) with finite numeric
  /// [values]. Non-finite `double` values (`NaN`, `Infinity`) are omitted so
  /// Chrome Trace JSON encoders never throw.
  @pragma('vm:prefer-inline')
  static void recordCounter(
    int stringId,
    TraceCategory category,
    Map<String, num> values,
  ) {
    if (!isEnabled || !activeCategories.contains(category)) return;
    final encoded = <String, String>{
      for (final entry in values.entries)
        if (entry.value.isFinite) entry.key: '${entry.value}',
    };
    if (encoded.isEmpty) return;
    record(stringId, Phase.counter, category, metadata: encoded);
  }

  /// Register a string literal and return its static ID.
  static int registerString(String name) {
    final existing = _stringTable[name];
    if (existing != null) return existing;

    final id = _nextStringId++;
    _stringTable[name] = id;
    _idToStringList.add(name);

    if (isEnabled && _sink != null) {
      _sink!.add(_createBuffer(0), [name]);
    }

    return id;
  }

  /// Record a trace event to the buffer.
  @pragma('vm:prefer-inline')
  static void record(
    int stringId,
    int phase,
    TraceCategory category, {
    Map<String, String>? metadata,
  }) {
    if (!activeCategories.contains(category)) return;
    if (!isEnabled) return;
    final idx = _writeIndex;

    // Word 0: JS-safe 53-bit equivalent of (stringId << 32) | (isolateId << 8) | phase
    _activeBuffer[idx] = packWord0(stringId, _isolateId, phase);

    // Word 1: monotonic timestamp
    _activeBuffer[idx + 1] = _stopwatch.elapsedMicroseconds;
    if (metadata != null) {
      _activeMetadata[idx ~/ 2] = metadata;
    }

    final nextIdx = (idx + 2) & _bufferMask;
    _writeIndex = nextIdx;

    if (nextIdx == 0) {
      _swapAndFlush();
    }
  }

  /// Flush any remaining events and shut down the recording session.
  static Future<void> stop() async {
    if (!isEnabled) return;
    isEnabled = false;
    _stopwatch.stop();
    final sink = _sink;
    _sink = null;

    if (_writeIndex > 0 && sink != null) {
      // Send the partially filled buffer
      final copy = _createBuffer(_writeIndex);
      List.copyRange(copy, 0, _activeBuffer, 0, _writeIndex);
      sink.add(copy, const [], _activeMetadata);
    }

    _writeIndex = 0;
    _activeMetadata = {};
    _activeBuffer.fillRange(0, _activeBuffer.length, 0);

    await sink?.close();
  }

  static void _swapAndFlush() {
    final fullBuffer = _activeBuffer;
    _activeBuffer = _backupBuffer;
    _backupBuffer = fullBuffer;
    _writeIndex = 0;

    final fullMetadata = _activeMetadata;
    _activeMetadata = {};
    _sink!.add(fullBuffer, const [], fullMetadata);
  }
}
