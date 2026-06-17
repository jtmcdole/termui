import 'dart:async';
import 'dart:typed_data';
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
}

/// Represents event phases in the trace log.
class Phase {
  /// A begin phase event.
  static const int begin = 1;

  /// An end phase event.
  static const int end = 2;

  /// An instant phase event.
  static const int instant = 3;
}

/// A high-performance, low-overhead event tracer.
class Tracer {
  /// Active configuration of trace categories to record.
  static Set<TraceCategory> activeCategories = TraceCategory.values.toSet();

  /// Whether the tracer is currently enabled and recording events.
  static bool isEnabled = false;

  static const int _bufferSize = 262144; // Must be power of 2 (256k events)
  static const int _eventSize = 2; // 2 words (16 bytes) per event
  static const int _bufferLength = _bufferSize * _eventSize;
  static const int _bufferMask = _bufferLength - 1;

  static late List<int> _activeBuffer;
  static late List<int> _backupBuffer;
  static int _writeIndex = 0;

  static final Map<String, int> _stringTable = {};
  static final List<String> _idToStringList = [];
  static int _nextStringId = 1;

  static final Stopwatch _stopwatch = Stopwatch();
  static int _baseEpochUs = 0;
  static int _isolateId = 0;

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

  /// Start a recording session.
  static Future<void> start(String traceFilePath, {FileSystem? fs}) async {
    if (isEnabled) return;

    final fileSystem = fs ?? getDefaultFileSystem();
    _baseEpochUs = DateTime.now().microsecondsSinceEpoch;
    _stopwatch.reset();
    _stopwatch.start();

    _sink = createTracerSink(fileSystem, traceFilePath, _baseEpochUs);

    // Synchronize the current string table with the sink
    if (_idToStringList.isNotEmpty) {
      _sink!.add(_createBuffer(0), List.from(_idToStringList));
    }

    isEnabled = true;
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
  static void record(int stringId, int phase, TraceCategory category) {
    if (!activeCategories.contains(category)) return;
    if (!isEnabled) return;
    final idx = _writeIndex;

    // Word 0: (stringId << 32) | (isolateId << 8) | phase
    _activeBuffer[idx] = (stringId << 32) | (_isolateId << 8) | phase;

    // Word 1: monotonic timestamp
    _activeBuffer[idx + 1] = _stopwatch.elapsedMicroseconds;

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

    if (_writeIndex > 0) {
      // Send the partially filled buffer
      final copy = _createBuffer(_writeIndex);
      List.copyRange(copy, 0, _activeBuffer, 0, _writeIndex);
      _sink!.add(copy, const []);
    }

    await _sink!.close();
    _sink = null;
  }

  static void _swapAndFlush() {
    final fullBuffer = _activeBuffer;
    _activeBuffer = _backupBuffer;
    _backupBuffer = fullBuffer;
    _writeIndex = 0;

    _sink!.add(fullBuffer, const []);
  }
}
