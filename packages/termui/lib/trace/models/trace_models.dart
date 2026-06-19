import 'package:characters/characters.dart';
// ignore_for_file: public_member_api_docs
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

class TraceEvent {
  final String name;
  final String phase;
  final String category;
  final int timestamp;
  final int tid;
  final Map<String, String> args;

  TraceEvent({
    required this.name,
    required this.phase,
    required this.category,
    required this.timestamp,
    required this.tid,
    required this.args,
  });

  factory TraceEvent.fromJson(Map<String, dynamic> json) {
    final argsRaw = json['args'] ?? json['metadata'];
    final Map<String, String> parsedArgs = {};
    if (argsRaw is Map) {
      argsRaw.forEach((k, v) {
        parsedArgs[k.toString()] = jsonEncode(v);
      });
    }
    return TraceEvent(
      name: json['name'] as String? ?? 'Unknown',
      phase: json['ph'] as String? ?? 'i',
      category: json['cat'] as String? ?? 'TUI',
      timestamp: json['ts'] as int? ?? 0,
      tid: json['tid'] as int? ?? 0,
      args: parsedArgs,
    );
  }
}

/// Interval representing a matched Begin/End trace event.
class TraceSpan {
  final String name;
  final String category;
  final int startUs;
  final int endUs;
  final int depth;
  final Map<String, String> args;

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
          ? '${text.characters.take(17).toString()}...'
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
  final sorted = List<TraceEvent>.from(events)
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

  final absoluteMaxTimestamp = sorted.isEmpty ? 0 : sorted.last.timestamp;

  final List<TraceSpan> spans = [];
  final Map<int, List<_StackEntry>> activeStacksByTid = {};

  for (final event in sorted) {
    final tid = event.tid;
    activeStacksByTid.putIfAbsent(tid, () => []);
    final stack = activeStacksByTid[tid]!;

    if (event.phase == 'B') {
      stack.add(_StackEntry(event, stack.length));
    } else if (event.phase == 'E') {
      int matchIdx = -1;
      for (int i = stack.length - 1; i >= 0; i--) {
        if (stack[i].event.name == event.name) {
          matchIdx = i;
          break;
        }
      }
      if (matchIdx != -1) {
        // Pop orphaned children above the matched parent
        while (stack.length > matchIdx + 1) {
          final orphanEntry = stack.removeLast();
          final orphanEvent = orphanEntry.event;
          spans.add(
            TraceSpan(
              name: orphanEvent.name,
              category: orphanEvent.category,
              startUs: orphanEvent.timestamp,
              endUs: event.timestamp, // Auto-closed at parent's end
              depth: orphanEntry.depth,
              args: orphanEvent.args,
            ),
          );
        }

        // Pop the actual matched parent
        final beginEntry = stack.removeLast();
        final begin = beginEntry.event;
        spans.add(
          TraceSpan(
            name: begin.name,
            category: begin.category,
            startUs: begin.timestamp,
            endUs: event.timestamp,
            depth: beginEntry.depth,
            args: begin.args,
          ),
        );
      }
    } else if (event.phase == 'i') {
      spans.add(
        TraceSpan(
          name: event.name,
          category: event.category,
          startUs: event.timestamp,
          endUs: event.timestamp + 1,
          depth: stack.length,
          args: event.args,
        ),
      );
    }
  }
  for (final tid in activeStacksByTid.keys) {
    for (final entry in activeStacksByTid[tid]!) {
      final begin = entry.event;
      spans.add(
        TraceSpan(
          name: begin.name,
          category: begin.category,
          startUs: begin.timestamp,
          endUs:
              absoluteMaxTimestamp, // Indicates missing 'E' phase is clamped to trace end
          depth: entry.depth,
          args: begin.args,
        ),
      );
    }
  }
  return spans;
}

Future<Map<String, Object>?> parseTraceFile(String path) async {
  return await Isolate.run(() {
    final file = File(path);
    if (!file.existsSync()) return null;

    final content = file.readAsStringSync();
    final jsonList = jsonDecode(content) as List<dynamic>;
    final events = jsonList
        .map((e) => TraceEvent.fromJson(e as Map<String, dynamic>))
        .toList();

    int baseTime = 0;
    if (events.isNotEmpty) {
      baseTime = events.map((e) => e.timestamp).reduce(min);
      for (var i = 0; i < events.length; i++) {
        final ev = events[i];
        events[i] = TraceEvent(
          name: ev.name,
          phase: ev.phase,
          category: ev.category,
          timestamp: ev.timestamp - baseTime,
          tid: ev.tid,
          args: ev.args,
        );
      }
    }

    final computedSpans = computeSpans(events);
    if (computedSpans.isEmpty) return null;

    computedSpans.sort((a, b) => a.startUs.compareTo(b.startUs));

    final mMinTs = computedSpans.map((s) => s.startUs).reduce(min);
    final mMaxTs = computedSpans.map((s) => s.endUs).reduce(max);

    return {
      'spans': computedSpans,
      'minTs': mMinTs,
      'maxTs': mMaxTs,
      'baseTime': baseTime,
    };
  });
}
