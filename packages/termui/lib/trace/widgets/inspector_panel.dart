import '../models/trace_models.dart';
import 'trace_viewer_app.dart';
// ignore_for_file: public_member_api_docs
import 'dart:math';
import 'package:termui/termui.dart';

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
  if (text.length <= maxWidth) return [text];

  final words = text.split(' ');
  final lines = <String>[];
  var currentLine = '';

  for (final word in words) {
    if (word.isEmpty) continue;

    if (currentLine.isEmpty) {
      currentLine = word;
    } else if (currentLine.length + 1 + word.length <= maxWidth) {
      currentLine += ' $word';
    } else {
      lines.add(currentLine);
      currentLine = '  $word'; // Indent wrapped lines
    }
  }
  if (currentLine.isNotEmpty) {
    lines.add(currentLine);
  }
  return lines;
}

Widget buildInspectorPanel(
  String? exportMessage,
  TraceSpan? hoveredSpan,
  TimeDisplayMode timeDisplayMode,
  int? baseTime,
) {
  int rawLineCount = 1;
  if (exportMessage == null && hoveredSpan != null) {
    rawLineCount = 2; // Title + Timing
    if (hoveredSpan.args.isNotEmpty) {
      rawLineCount += 1 + hoveredSpan.args.length;
    }
  }
  final panelHeight = min(rawLineCount, 12);

  return SizedBox(
    height: panelHeight + 2,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;

        Widget contentWidget;
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
          final span = hoveredSpan;
          final durMs = (span.endUs - span.startUs) / 1000.0;
          final startMs = span.startUs / 1000.0;
          final endMs = span.endUs / 1000.0;

          final lines = <String>[];

          String titleLine = '[Hovered] ${span.displayLabel}';
          if (titleLine.length > maxWidth - 2) {
            titleLine = '${titleLine.substring(0, maxWidth - 5)}...';
          }
          lines.add(titleLine);

          String timingLine = '';
          switch (timeDisplayMode) {
            case TimeDisplayMode.formatted:
              timingLine =
                  'Start: ${formatDuration(startMs)}  |  End: ${formatDuration(endMs)}  |  Duration: ${formatDuration(durMs)}';
              break;
            case TimeDisplayMode.rawRelative:
              timingLine =
                  'Start: ${span.startUs}  |  End: ${span.endUs}  |  Duration: ${formatDuration(durMs)}';
              break;
            case TimeDisplayMode.rawAbsolute:
              final absStart = span.startUs + (baseTime ?? 0);
              final absEnd = span.endUs + (baseTime ?? 0);
              timingLine =
                  'Start: $absStart  |  End: $absEnd  |  Duration: ${formatDuration(durMs)}';
              break;
          }
          if (timingLine.length > maxWidth - 2) {
            timingLine = '${timingLine.substring(0, maxWidth - 5)}...';
          }
          lines.add(timingLine);

          if (span.args.isNotEmpty) {
            lines.add('Args:');
            for (final entry in span.args.entries) {
              final argStr = '  ${entry.key}: ${entry.value}';
              lines.addAll(wrapTraceText(argStr, maxWidth - 2));
            }
          }

          final totalLines = lines.length;

          contentWidget = ListView.fromStrings(
            lines,
            itemStyle: const Style(foreground: Colors.white),
            selectedStyle: const Style(foreground: Colors.white),
            showScrollbar: totalLines > panelHeight,
          );
        }

        return DecoratedBox(
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
        );
      },
    ),
  );
}
