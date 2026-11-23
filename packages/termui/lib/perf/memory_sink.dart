import 'dart:convert';

import 'tracer.dart';
import 'tracer_sink.dart';

/// A bounded, cross-platform [TracerSink] that formats Chrome Trace Event JSON
/// in memory without touching local disk (usable on Web, Desktop, and tests).
final class MemoryTracerSink implements TracerSink {
  /// Base epoch timestamp in microseconds supplied by [Tracer.startWithSink].
  final int baseEpochUs;

  /// Maximum number of trace events retained before dropping subsequent entries.
  final int maxEvents;

  final List<String> _stringTable = <String>['Unknown'];
  final StringBuffer _events = StringBuffer();
  int _eventCount = 0;
  int _droppedCount = 0;

  /// Creates an in-memory Chrome Trace JSON sink.
  MemoryTracerSink({required this.baseEpochUs, this.maxEvents = 250000});

  /// Number of trace events currently buffered.
  int get eventCount => _eventCount;

  /// Number of trace events dropped because [maxEvents] was reached.
  int get droppedCount => _droppedCount;

  @override
  void add(
    List<int> buffer,
    List<String> newStrings, [
    Map<int, Map<String, String>> metadata = const <int, Map<String, String>>{},
  ]) {
    _stringTable.addAll(newStrings);
    final numEvents = buffer.length ~/ 2;
    for (var i = 0; i < numEvents; i++) {
      if (_eventCount >= maxEvents) {
        _droppedCount += numEvents - i;
        return;
      }
      _appendEvent(buffer[i * 2], buffer[i * 2 + 1], metadata[i]);
    }
  }

  void _appendEvent(int word0, int ts, Map<String, String>? eventMeta) {
    final phaseVal = Tracer.unpackPhase(word0);
    final isolateId = Tracer.unpackIsolateId(word0);
    final stringId = Tracer.unpackStringId(word0);
    final name = stringId < _stringTable.length
        ? _stringTable[stringId]
        : 'Unknown';
    final ph = switch (phaseVal) {
      Phase.begin => 'B',
      Phase.end => 'E',
      Phase.counter => 'C',
      _ => 'i',
    };
    final realTs = baseEpochUs + ts;
    if (_eventCount > 0) {
      _events.write(',\n');
    }
    _eventCount++;

    final metaStr = eventMeta != null
        ? ', "args": ${_encodeArgs(eventMeta, phaseVal)}'
        : '';
    final escapedName = jsonEncode(name);
    _events.write(
      '  {"name": $escapedName, "cat": "TUI", "ph": "$ph", '
      '"ts": $realTs, "pid": 1, "tid": $isolateId$metaStr}',
    );
  }

  static String _encodeArgs(Map<String, String> raw, int phaseVal) {
    if (phaseVal != Phase.counter) {
      return jsonEncode(raw);
    }
    final numeric = <String, Object>{
      for (final entry in raw.entries)
        entry.key: _parseFiniteCounterValue(entry.value),
    };
    return jsonEncode(numeric);
  }

  static Object _parseFiniteCounterValue(String raw) {
    final parsed = num.tryParse(raw);
    return (parsed != null && parsed.isFinite) ? parsed : raw;
  }

  /// Returns a complete Chrome Trace Event JSON array (`[ ... ]`) compatible
  /// with `https://ui.perfetto.dev` and `chrome://tracing`.
  String toTraceJson() => _eventCount == 0 ? '[]\n' : '[\n$_events\n]\n';

  @override
  Future<void> close() async {}
}
