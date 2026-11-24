import 'dart:math';
import 'package:characters/characters.dart';
import 'package:termui/termui.dart';

/// Text alignments for TUI rendering.
enum TextAlign {
  /// Align text to the left.
  left,

  /// Align text to the center.
  center,

  /// Align text to the right.
  right,

  /// Justify text to span the width.
  justify,
}

/// Measures the physical cell width of a string in a terminal,
/// correctly accounting for CJK and Emoji characters that occupy 2 cells.
int measureStringWidth(String text) {
  if (text.isEmpty) return 0;
  var width = 0;
  for (final char in text.characters) {
    width += graphemeWidth(char);
  }
  return width;
}

/// Pads or truncates a string to match the specified visual column width in a terminal,
/// correctly accounting for wide characters (CJK and Emoji) and utilizing a fast-path
/// for pure ASCII text.
String padOrTruncate(String text, int width) {
  if (width <= 0) return '';

  // 1. ASCII Fast-Path: bypass characters allocation for standard text
  var isAscii = true;
  final len = text.length;
  for (var i = 0; i < len; i++) {
    if (text.codeUnitAt(i) >= 128) {
      isAscii = false;
      break;
    }
  }

  if (isAscii) {
    if (len == width) return text;
    if (len > width) return text.substring(0, width);
    return text.padRight(width);
  }

  // 2. Slow-Path fallback for CJK and Emoji text
  final cellWidth = measureStringWidth(text);
  if (cellWidth == width) return text;
  if (cellWidth < width) return text + (' ' * (width - cellWidth));

  var currentWidth = 0;
  final sb = StringBuffer();
  for (final char in text.characters) {
    final charWidth = graphemeWidth(char);
    if (charWidth == 0) {
      sb.write(char);
      continue;
    }
    if (currentWidth + charWidth > width) break;
    sb.write(char);
    currentWidth += charWidth;
  }
  if (currentWidth < width) {
    sb.write(' ' * (width - currentWidth));
  }
  return sb.toString();
}

/// A widget that renders styled text with optional wrapping.
///
/// It supports standard formatting, custom maximum lines, and alignment.
/// In compliance with terminal standards, it correctly measures string
/// width using [measureStringWidth] which handles CJK (Chinese, Japanese, Korean)
/// and Emoji characters that occupy two visual columns (wide characters).
///
/// ### Example Usage
///
/// ```dart
/// Text(
///   'This is some multi-column CJK text: 漢字',
///   style: Style(foreground: Color(0xFFFFCC00)),
///   wrap: true,
///   textAlign: TextAlign.center,
/// );
/// ```
///
/// ### Properties and Settings
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `data` | [String] | The text characters to render. |
/// | `style` | [Style] | Formatting attributes (bold, dim, underline, color). |
/// | `wrap` | [bool] | Wrap words to a new line when constraints are exceeded. |
/// | `textAlign` | [TextAlign] | Alignment option (left, center, right, justify). |
/// | `maxLines` | [int]? | Optional maximum height limits. |
class Text extends Widget {
  /// The text characters to render.
  final String data;

  /// Formatting attributes (bold, dim, underline, color).
  final Style style;

  /// Wrap words to a new line when constraints are exceeded.
  final bool wrap;

  /// Alignment option (left, center, right, justify).
  final TextAlign textAlign;

  /// Optional maximum height limits.
  final int? maxLines;

  /// Creates a [Text] widget to render styled text.
  const Text(
    this.data, {
    super.key,
    this.style = Style.empty,
    this.wrap = true,
    this.textAlign = TextAlign.left,
    this.maxLines,
  });

  @override
  Element createElement() => TextElement(this);

  @override
  int getIntrinsicWidth(int height) {
    var maxWidth = 0;
    for (final line in data.split('\n')) {
      final w = measureStringWidth(line);
      if (w > maxWidth) maxWidth = w;
    }
    return maxWidth;
  }

  @override
  int getIntrinsicHeight(int width) {
    if (!wrap) {
      return maxLines != null ? min(maxLines!, 1) : 1;
    }
    final lines = _wrapText(data, width);
    final count = lines.length;
    return maxLines != null ? min(maxLines!, count) : count;
  }

  String _truncateToWidth(String text, int maxWidth) {
    if (maxWidth <= 0) return '';
    final sb = StringBuffer();
    var currentWidth = 0;
    for (final char in text.characters) {
      final w = isWideGrapheme(char) ? 2 : 1;
      if (currentWidth + w > maxWidth) break;
      sb.write(char);
      currentWidth += w;
    }
    return sb.toString();
  }

  List<String> _wrapText(String text, int maxWidth) {
    if (maxWidth <= 0) return [];
    final lines = <String>[];
    for (final paragraph in text.split('\n')) {
      _wrapParagraph(paragraph, maxWidth, lines);
    }
    return lines;
  }

  static void _wrapParagraph(
    String paragraph,
    int maxWidth,
    List<String> lines,
  ) {
    if (paragraph.isEmpty) {
      lines.add('');
      return;
    }

    var currentLine = '';
    var currentLineLen = 0;

    for (final word in paragraph.split(' ')) {
      if (word.isEmpty) continue;
      final wordWidth = measureStringWidth(word);

      if (currentLine.isNotEmpty &&
          currentLineLen + 1 + wordWidth <= maxWidth) {
        currentLine += ' $word';
        currentLineLen += 1 + wordWidth;
        continue;
      }

      final hadCurrentLine = currentLine.isNotEmpty;
      if (hadCurrentLine) {
        lines.add(currentLine);
        currentLine = '';
        currentLineLen = 0;
      }

      if (wordWidth <= maxWidth) {
        currentLine = word;
        currentLineLen = wordWidth;
        continue;
      }

      (currentLine, currentLineLen) = _emitOversizedWord(
        word,
        maxWidth,
        lines,
        keepFirstInCurrentLine: hadCurrentLine,
      );
    }

    if (currentLine.isNotEmpty) {
      lines.add(currentLine);
    }
  }

  static (String, int) _emitOversizedWord(
    String word,
    int maxWidth,
    List<String> lines, {
    // Preserves legacy oversized-word wrapping: 'hi abcdefgh' at width 4 -> ['hi', 'efgh', 'abcd'].
    required bool keepFirstInCurrentLine,
  }) {
    var currentLine = '';
    var currentLineLen = 0;
    var remaining = word.characters;
    while (remaining.isNotEmpty) {
      final (chunk, takeWidth, next) = _takeWordChunk(remaining, maxWidth);
      remaining = next;
      if (keepFirstInCurrentLine && takeWidth > 0 && currentLine.isEmpty) {
        currentLine = chunk;
        currentLineLen = takeWidth;
      } else {
        lines.add(chunk);
      }
    }
    return (currentLine, currentLineLen);
  }

  static (String, int, Characters) _takeWordChunk(
    Characters chars,
    int maxWidth,
  ) {
    var takeWidth = 0;
    final chunk = StringBuffer();
    var remaining = chars;
    while (remaining.isNotEmpty) {
      final char = remaining.first;
      final w = isWideGrapheme(char) ? 2 : 1;
      if (takeWidth + w > maxWidth) break;
      chunk.write(char);
      takeWidth += w;
      remaining = remaining.skip(1);
    }
    if (chunk.isNotEmpty) {
      return (chunk.toString(), takeWidth, remaining);
    }
    return (remaining.first, 0, remaining.skip(1));
  }
}

class _RenderLine {
  final String visibleChars;
  final int startX;

  _RenderLine(this.visibleChars, this.startX);
}

/// An element that represents a [Text] widget.
class TextElement extends Element {
  List<_RenderLine> _cachedLines = [];

  /// Creates a text element for a [Text] widget.
  TextElement(Text super.widget);

  @override
  Map<String, String>? get paintTraceMetadata {
    final textWidget = widget as Text;
    return {
      'text': textWidget.data.length > 40
          ? '${textWidget.data.substring(0, 40)}...'
          : textWidget.data,
    };
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    final textWidget = widget as Text;
    final width = constraints.maxWidth == BoxConstraints.infinity
        ? 999999
        : constraints.maxWidth;

    List<String> textLines;
    if (!textWidget.wrap) {
      textLines = [textWidget.data];
    } else {
      textLines = textWidget._wrapText(textWidget.data, width);
    }

    final limit = textWidget.maxLines != null
        ? min(textWidget.maxLines!, textLines.length)
        : textLines.length;

    var measuredWidth = 0;
    final lineMeasurements = <int>[];
    for (var i = 0; i < limit; i++) {
      final lineW = measureStringWidth(textLines[i]);
      lineMeasurements.add(lineW);
      if (lineW > measuredWidth) {
        measuredWidth = lineW;
      }
    }

    final height = limit;
    final resolvedSize = constraints.constrain(Size(measuredWidth, height));

    // Now that final size is known, precompute render lines
    _cachedLines = [];
    final areaWidth = resolvedSize.width;
    for (var i = 0; i < limit; i++) {
      final line = textLines[i];
      final lineWidth = lineMeasurements[i];

      final startX = switch (textWidget.textAlign) {
        TextAlign.left || TextAlign.justify => 0,
        TextAlign.right => max(0, areaWidth - lineWidth),
        TextAlign.center => max(0, (areaWidth - lineWidth) ~/ 2),
      };

      final availableWidth = areaWidth - startX;
      final visibleChars = lineWidth > availableWidth
          ? textWidget._truncateToWidth(line, availableWidth)
          : line;
      _cachedLines.add(_RenderLine(visibleChars, startX));
    }

    return resolvedSize;
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final textWidget = widget as Text;
    final area = Rect(offset.dx, offset.dy, size.width, size.height);

    final limit = textWidget.maxLines != null
        ? min(textWidget.maxLines!, area.height)
        : area.height;

    for (var i = 0; i < _cachedLines.length; i++) {
      if (i >= limit) break;
      final line = _cachedLines[i];

      buffer.writeString(
        area.x + line.startX,
        area.y + i,
        line.visibleChars,
        textWidget.style,
      );
    }
  }
}
