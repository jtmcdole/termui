import 'package:characters/characters.dart';
// ignore_for_file: public_member_api_docs
import 'dart:convert';
import 'dart:math';
import 'package:file/file.dart';
import 'package:termui/perf/fs_locator.dart';
import 'package:termui/utils/gzip_json.dart';
import 'package:termui/utils/interval_tree.dart';

class TraceEvent {
  final String name;
  final String phase;
  final String category;
  final int timestamp;
  final int? dur;
  final int tid;
  final Map<String, String> args;

  TraceEvent({
    required this.name,
    required this.phase,
    required this.category,
    required this.timestamp,
    this.dur,
    required this.tid,
    required this.args,
  });

  factory TraceEvent.fromJson(Map<String, Object?> json) {
    final argsRaw = json['args'] ?? json['metadata'];
    final Map<String, String> parsedArgs = {};
    if (argsRaw is Map<Object?, Object?>) {
      argsRaw.forEach((k, v) {
        parsedArgs['$k'] = jsonEncode(v);
      });
    }
    return TraceEvent(
      name: json['name'] as String? ?? 'Unknown',
      phase: json['ph'] as String? ?? 'i',
      category: json['cat'] as String? ?? 'TUI',
      timestamp: (json['ts'] as num?)?.toInt() ?? 0,
      dur: (json['dur'] as num?)?.toInt(),
      tid: (json['tid'] as num?)?.toInt() ?? 0,
      args: parsedArgs,
    );
  }
}

/// Interval representing a matched Begin/End trace event.
class TraceSpan implements Interval<int> {
  final String name;
  final String category;
  final int startUs;
  final int endUs;
  final int depth;
  final Map<String, String> args;

  @override
  int get start => startUs;

  @override
  int get end => endUs;

  final String displayLabel;

  TraceSpan({
    required this.name,
    required this.category,
    required this.startUs,
    required this.endUs,
    required this.depth,
    required this.args,
    String? displayLabel,
  }) : displayLabel = displayLabel ?? _computeDisplayLabel(name, args);

  static String _computeDisplayLabel(String name, Map<String, String> args) {
    String widgetName = name;
    String action = '';

    final parts = name.split(':');
    if (parts.length == 2) {
      widgetName = parts[0];
      action = parts[1];
    }

    String metaPart = '';

    if (args.containsKey('text')) {
      var text = args['text']!;
      if (text.startsWith('"') && text.endsWith('"') && text.length >= 2) {
        text = text.substring(1, text.length - 1);
      }
      final truncated = text.characters.length > 20
          ? '${text.characters.take(17)}...'
          : text;
      if (truncated != widgetName) {
        metaPart = '[$truncated]';
      }
    } else if (args.containsKey('key')) {
      var keyStr = args['key']!;
      if (keyStr.startsWith('"') &&
          keyStr.endsWith('"') &&
          keyStr.length >= 2) {
        keyStr = keyStr.substring(1, keyStr.length - 1);
      }
      if (keyStr != widgetName) {
        metaPart = '[$keyStr]';
      }
    }

    final components = <String>[];
    if (metaPart.isNotEmpty) components.add(metaPart);
    if (action.isNotEmpty) components.add(action);
    if (widgetName.isNotEmpty) components.add(widgetName);

    return components.join(' ');
  }
}

class _StackEntry {
  final TraceEvent event;
  final int depth;
  _StackEntry(this.event, this.depth);
}

/// Reconstructs TraceSpans from raw TraceEvents.
List<TraceSpan> computeSpans(List<TraceEvent> events) {
  final indexedEvents = List.generate(
    events.length,
    (i) => MapEntry(i, events[i]),
  );
  indexedEvents.sort((a, b) {
    final cmp = a.value.timestamp.compareTo(b.value.timestamp);
    return cmp != 0 ? cmp : a.key.compareTo(b.key);
  });
  final sorted = [for (final e in indexedEvents) e.value];

  final absoluteMaxTimestamp = sorted.isEmpty ? 0 : sorted.last.timestamp;
  final spans = <TraceSpan>[];
  final activeStacksByTid = <int, List<_StackEntry>>{};

  for (final event in sorted) {
    final stack = activeStacksByTid[event.tid] ??= [];
    switch (event.phase) {
      case 'B':
        stack.add(_StackEntry(event, stack.length));
      case 'E':
        _closeMatchingSpan(stack, event, spans);
      case 'i':
        spans.add(_spanFromEvent(event, event.timestamp + 1, stack.length));
      case 'X':
        spans.add(
          _spanFromEvent(
            event,
            event.timestamp + (event.dur ?? 1),
            stack.length,
          ),
        );
    }
  }

  for (final stack in activeStacksByTid.values) {
    for (final entry in stack) {
      spans.add(_spanFromEvent(entry.event, absoluteMaxTimestamp, entry.depth));
    }
  }
  return spans;
}

void _closeMatchingSpan(
  List<_StackEntry> stack,
  TraceEvent endEvent,
  List<TraceSpan> spans,
) {
  final matchIdx = stack.lastIndexWhere((e) => e.event.name == endEvent.name);
  if (matchIdx == -1) return;

  while (stack.length > matchIdx) {
    final entry = stack.removeLast();
    spans.add(_spanFromEvent(entry.event, endEvent.timestamp, entry.depth));
  }
}

TraceSpan _spanFromEvent(TraceEvent event, int endUs, int depth) => TraceSpan(
  name: event.name,
  category: event.category,
  startUs: event.timestamp,
  endUs: endUs,
  depth: depth,
  args: event.args,
);

Future<Map<String, Object>?> parseTraceFile(
  String path, {
  FileSystem? fileSystem,
}) async {
  final fs = fileSystem ?? getDefaultFileSystem();
  final file = fs.file(path);
  if (!await file.exists()) return null;

  final String content;
  if (path.endsWith('.gz')) {
    final bytes = await file.readAsBytes();
    final decompressed = await decompressGzip(bytes);
    content = utf8.decode(decompressed);
  } else {
    content = await file.readAsString();
  }

  return _parseTraceJsonContent(content);
}

Map<String, Object>? _parseTraceJsonContent(String content) {
  final jsonList = jsonDecode(content) as List<Object?>;
  final events = [
    for (final e in jsonList) TraceEvent.fromJson(e as Map<String, Object?>),
  ];

  final baseTime = _normalizeEventTimestamps(events);
  final computedSpans = computeSpans(events);
  if (computedSpans.isEmpty) return null;

  computedSpans.sort((a, b) => a.startUs.compareTo(b.startUs));
  final (mMinTs, mMaxTs, mMaxDuration) = _computeSpanBounds(computedSpans);

  return {
    'spans': computedSpans,
    'minTs': mMinTs,
    'maxTs': mMaxTs,
    'baseTime': baseTime,
    'maxSpanDuration': mMaxDuration,
  };
}

int _normalizeEventTimestamps(List<TraceEvent> events) {
  if (events.isEmpty) return 0;
  var baseTime = events.first.timestamp;
  for (var i = 1; i < events.length; i++) {
    baseTime = min(baseTime, events[i].timestamp);
  }
  for (var i = 0; i < events.length; i++) {
    final ev = events[i];
    events[i] = TraceEvent(
      name: ev.name,
      phase: ev.phase,
      category: ev.category,
      timestamp: ev.timestamp - baseTime,
      dur: ev.dur,
      tid: ev.tid,
      args: ev.args,
    );
  }
  return baseTime;
}

(int minTs, int maxTs, int maxDuration) _computeSpanBounds(
  List<TraceSpan> spans,
) {
  var mMinTs = spans.first.startUs;
  var mMaxTs = spans.first.endUs;
  var mMaxDuration = 0;
  for (final s in spans) {
    mMinTs = min(mMinTs, s.startUs);
    mMaxTs = max(mMaxTs, s.endUs);
    mMaxDuration = max(mMaxDuration, s.endUs - s.startUs);
  }
  return (mMinTs, mMaxTs, mMaxDuration);
}
