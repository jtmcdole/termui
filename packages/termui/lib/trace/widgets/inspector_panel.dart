import 'package:characters/characters.dart';
import "package:termui/termui_trace.dart";
import "package:termui/termui.dart";
// ignore_for_file: public_member_api_docs
import 'dart:math';

String formatDuration(double ms) {
  if (ms < 0.001) {
    return '${(ms * 1000000).toStringAsFixed(1)} ns';
  } else if (ms < 1.0) {
    return '${(ms * 1000).toStringAsFixed(1)} μs';
  } else {
    return '${ms.toStringAsFixed(2)} ms';
  }
}

List<String> wrapTraceText(String text, int maxWidth) {
  if (maxWidth <= 0) return [];
  if (text.characters.length <= maxWidth) return [text];

  final words = text.split(' ');
  final lines = <String>[];
  var currentLine = '';
  var currentLen = 0;

  for (final word in words) {
    if (word.isEmpty) continue;
    final wordLen = word.characters.length;

    if (currentLine.isEmpty) {
      currentLine = word;
      currentLen = wordLen;
    } else if (currentLen + 1 + wordLen <= maxWidth) {
      currentLine = '$currentLine $word';
      currentLen += 1 + wordLen;
    } else {
      lines.add(currentLine);
      currentLine = '  $word'; // Indent wrapped lines
      currentLen = 2 + wordLen;
    }
  }
  if (currentLine.isNotEmpty) {
    lines.add(currentLine);
  }
  return lines;
}

String _truncateInspectorLine(String text, int maxWidth) {
  final available = maxWidth - 2;
  if (available <= 0) return '';
  final chars = text.characters;
  if (chars.length <= available) return text;
  if (maxWidth < 5) {
    return chars.take(available).toString();
  }
  return '${chars.take(maxWidth - 5)}...';
}

List<String> _buildHoveredSpanLines(
  TraceSpan span,
  int maxWidth,
  TimeDisplayMode timeDisplayMode,
  int? baseTime,
) {
  final durMs = (span.endUs - span.startUs) / 1000.0;
  final startMs = span.startUs / 1000.0;
  final endMs = span.endUs / 1000.0;

  final timingLine = switch (timeDisplayMode) {
    TimeDisplayMode.formatted =>
      'Start: ${formatDuration(startMs)}  |  End: ${formatDuration(endMs)}  |  Duration: ${formatDuration(durMs)}',
    TimeDisplayMode.rawRelative =>
      'Start: ${span.startUs}  |  End: ${span.endUs}  |  Duration: ${formatDuration(durMs)}',
    TimeDisplayMode.rawAbsolute =>
      'Start: ${span.startUs + (baseTime ?? 0)}  |  End: ${span.endUs + (baseTime ?? 0)}  |  Duration: ${formatDuration(durMs)}',
  };

  final lines = <String>[
    _truncateInspectorLine('[Hovered] ${span.displayLabel}', maxWidth),
    _truncateInspectorLine(timingLine, maxWidth),
  ];

  if (span.args.isNotEmpty) {
    lines.add('Args:');
    final wrapWidth = max(0, maxWidth - 2);
    for (final MapEntry(:key, :value) in span.args.entries) {
      var argStr = '  $key: $value';
      final argChars = argStr.characters;
      if (argChars.length > 1000) {
        argStr = '${argChars.take(1000)}... (truncated)';
      }
      lines.addAll(wrapTraceText(argStr, wrapWidth));
    }
  }
  return lines;
}

Widget buildInspectorPanel(
  String? exportMessage,
  TraceSpan? hoveredSpan,
  TimeDisplayMode timeDisplayMode,
  int? baseTime,
) {
  return LayoutBuilder(
    builder: (context, constraints) {
      final maxWidth = constraints.maxWidth;

      Widget contentWidget;
      int contentHeight = 1;

      if (exportMessage != null) {
        contentWidget = Text(
          exportMessage,
          style: const Style(foreground: Color(100, 255, 100)),
        );
      } else if (hoveredSpan == null) {
        contentWidget = Text(
          'No event hovered. Hover over a span to inspect details.',
          style: const Style(foreground: Colors.white),
        );
      } else {
        final lines = _buildHoveredSpanLines(
          hoveredSpan,
          maxWidth,
          timeDisplayMode,
          baseTime,
        );
        final totalLines = lines.length;
        contentHeight = min(totalLines, 12);

        contentWidget = ListView.fromStrings(
          lines,
          itemStyle: const Style(foreground: Colors.white),
          selectedStyle: const Style(foreground: Colors.white),
          showScrollbar: totalLines > contentHeight,
        );
      }

      return SizedBox(
        height: contentHeight + 2,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            border: Border(
              topChar: '─',
              bottomChar: '─',
              leftChar: '│',
              rightChar: '│',
              topLeftChar: '├',
              topRightChar: '┤',
              bottomLeftChar: '└',
              bottomRightChar: '┘',
              style: Style(foreground: Color(120, 120, 120)),
            ),
            backgroundColor: Color(30, 30, 30),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
            child: contentWidget,
          ),
        ),
      );
    },
  );
}
