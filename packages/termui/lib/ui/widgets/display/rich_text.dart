import 'dart:math';
import 'package:characters/characters.dart';
import 'package:termui/termui.dart';

/// Represents a styled span of text.
class TextRun {
  /// The string content of the text run.
  final String text;

  /// The style applied to the text.
  final Style style;

  /// Creates a [TextRun] with an explicit text value and optional styling.
  const TextRun(this.text, {this.style = Style.empty});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TextRun && other.text == text && other.style == style;

  @override
  int get hashCode => Object.hash(text, style);

  @override
  String toString() => "TextRun('$text', style: $style)";
}

/// A helper representing a single grapheme cluster with its style.
class StyledChar {
  /// The isolated grapheme character.
  final String char;

  /// The style bound to this character.
  final Style style;

  /// Creates a [StyledChar] mapping a grapheme string to its style.
  StyledChar(this.char, this.style);
}

/// A helper representing a token (a word, spaces, or a newline) for wrapping.
class StyledToken {
  /// The styled characters representing this token.
  final List<StyledChar> chars;

  /// Indicates whether this token consists entirely of whitespace.
  final bool isWhitespace;

  /// Indicates whether this token represents a newline.
  final bool isNewline;

  /// Instantiates a [StyledToken] representing a wrapped sequence of characters.
  StyledToken(this.chars, {this.isWhitespace = false, this.isNewline = false});

  /// Retrieves the character length of the token.
  int get length => chars.length;
}

/// An immutable span of text that can hold styling overrides and nested child spans.
///
/// Under standard terminal styling, [TextSpan] represents a hierarchical tree node
/// that propagates formatting rules (color, bold, underline, etc.) to all descendants.
/// Any child [TextSpan] overrides specific properties while inheriting the remaining styles.
///
/// ### Example
/// ```dart
/// const TextSpan(
///   style: Style(foreground: CharmColors.pepper),
///   children: [
///     TextSpan(text: 'This is red and normal '),
///     TextSpan(
///       text: 'bold text',
///       style: Style(modifiers: Modifier.bold),
///     ),
///   ],
/// )
/// ```
class TextSpan {
  /// The literal text represented by this span. Can be null if this span only hosts children.
  final String? text;

  /// Style overrides applied to this span and its children.
  final Style? style;

  /// Nested child text spans that inherit styling from this node.
  final List<TextSpan> children;

  /// Initializes a text span with optional text content, styling overrides, and nested children spans.
  const TextSpan({this.text, this.style, this.children = const []});

  /// Recursively flattens the styling tree into a list of styled characters.
  void buildStyledChars(List<StyledChar> output, Style parentStyle) {
    // Merge parent style with current span style.
    final mergedStyle = style != null ? parentStyle.merge(style!) : parentStyle;

    if (text != null) {
      for (final char in text!.characters) {
        output.add(StyledChar(char, mergedStyle));
      }
    }

    for (final child in children) {
      child.buildStyledChars(output, mergedStyle);
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TextSpan &&
          other.text == text &&
          other.style == style &&
          _listEquals(other.children, children);

  @override
  int get hashCode => Object.hash(text, style, Object.hashAll(children));

  bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// A widget that displays formatted text using a tree of [TextSpan] configurations.
///
/// Supports text wrapping, horizontal alignment (left, center, right), and maximum
/// line boundaries.
///
/// ### Example
/// ```dart
/// RichText(
///   textAlign: TextAlign.center,
///   text: TextSpan(
///     text: 'Hello ',
///     children: [
///       TextSpan(
///         text: 'World',
///         style: Style(modifiers: Modifier.bold),
///       ),
///     ],
///   ),
/// )
/// ```
class RichText extends Widget {
  /// The root text span tree representing the structured formatted content.
  final TextSpan text;

  /// Whether the text should automatically wrap to fit the layout width.
  final bool wrap;

  /// The horizontal alignment of the text lines.
  final TextAlign textAlign;

  /// The maximum number of lines allowed to render; clips any overflow.
  final int? maxLines;

  /// Creates a [RichText] rendering widget configuring layout behavior around a root text span.
  const RichText({
    required this.text,
    this.wrap = true,
    this.textAlign = TextAlign.left,
    this.maxLines,
  });

  @override
  Element createElement() => RichTextElement(this);

  List<List<StyledChar>> _clipStyledChars(
    List<StyledChar> chars,
    int maxWidth,
  ) {
    final lines = <List<StyledChar>>[];
    var currentLine = <StyledChar>[];
    for (final char in chars) {
      if (char.char == '\n') {
        lines.add(currentLine.take(maxWidth).toList());
        currentLine = [];
      } else {
        currentLine.add(char);
      }
    }
    lines.add(currentLine.take(maxWidth).toList());
    return lines;
  }

  List<List<StyledChar>> _wrapStyledChars(
    List<StyledChar> allChars,
    int maxWidth,
  ) {
    if (maxWidth <= 0) return [];
    if (allChars.isEmpty) return [[]];

    // Tokenize characters into words, spaces, and newlines
    final tokens = <StyledToken>[];
    var i = 0;
    while (i < allChars.length) {
      final char = allChars[i].char;
      if (char == '\n') {
        tokens.add(StyledToken([allChars[i]], isNewline: true));
        i++;
      } else if (char == ' ') {
        final spaces = <StyledChar>[];
        while (i < allChars.length && allChars[i].char == ' ') {
          spaces.add(allChars[i]);
          i++;
        }
        tokens.add(StyledToken(spaces, isWhitespace: true));
      } else {
        final word = <StyledChar>[];
        while (i < allChars.length &&
            allChars[i].char != ' ' &&
            allChars[i].char != '\n') {
          word.add(allChars[i]);
          i++;
        }
        tokens.add(StyledToken(word));
      }
    }

    // Wrap tokens into lines
    final lines = <List<StyledChar>>[];
    var currentLine = <StyledChar>[];

    for (final token in tokens) {
      if (token.isNewline) {
        lines.add(currentLine);
        currentLine = <StyledChar>[];
        continue;
      }

      if (token.isWhitespace) {
        if (currentLine.isEmpty) {
          // Skip leading whitespace on a new line
          continue;
        }
        if (currentLine.length + token.length <= maxWidth) {
          currentLine.addAll(token.chars);
        } else {
          // Commit line, drop trailing whitespace
          lines.add(currentLine);
          currentLine = <StyledChar>[];
        }
        continue;
      }

      // It's a word token
      if (currentLine.isEmpty) {
        if (token.length <= maxWidth) {
          currentLine.addAll(token.chars);
        } else {
          // Force split long word
          var remainingChars = token.chars;
          while (remainingChars.length > maxWidth) {
            lines.add(remainingChars.sublist(0, maxWidth));
            remainingChars = remainingChars.sublist(maxWidth);
          }
          currentLine.addAll(remainingChars);
        }
      } else {
        if (currentLine.length + token.length <= maxWidth) {
          currentLine.addAll(token.chars);
        } else {
          // Remove any trailing whitespace from the line before committing
          while (currentLine.isNotEmpty && currentLine.last.char == ' ') {
            currentLine.removeLast();
          }
          lines.add(currentLine);
          currentLine = <StyledChar>[];

          if (token.length <= maxWidth) {
            currentLine.addAll(token.chars);
          } else {
            // Force split long word
            var remainingChars = token.chars;
            while (remainingChars.length > maxWidth) {
              lines.add(remainingChars.sublist(0, maxWidth));
              remainingChars = remainingChars.sublist(maxWidth);
            }
            currentLine.addAll(remainingChars);
          }
        }
      }
    }

    if (currentLine.isNotEmpty) {
      // Remove trailing whitespace before committing last line
      while (currentLine.isNotEmpty && currentLine.last.char == ' ') {
        currentLine.removeLast();
      }
      lines.add(currentLine);
    }

    return lines;
  }
}

/// An element that manages a [RichText] widget.
class RichTextElement extends Element {
  List<List<StyledChar>> _cachedLines = [];

  /// Creates a rich text element for a [RichText] widget.
  RichTextElement(RichText super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final richTextWidget = widget as RichText;
    final width = constraints.maxWidth == BoxConstraints.infinity
        ? 999999
        : constraints.maxWidth;

    final allStyledChars = <StyledChar>[];
    richTextWidget.text.buildStyledChars(allStyledChars, Style.empty);

    _cachedLines = richTextWidget.wrap
        ? richTextWidget._wrapStyledChars(allStyledChars, width)
        : richTextWidget._clipStyledChars(allStyledChars, width);

    final limit = richTextWidget.maxLines != null
        ? min(richTextWidget.maxLines!, _cachedLines.length)
        : _cachedLines.length;

    var measuredWidth = 0;
    for (var i = 0; i < limit; i++) {
      final lineLen = _cachedLines[i].length;
      if (lineLen > measuredWidth) {
        measuredWidth = lineLen;
      }
    }

    final height = limit;
    return constraints.constrain(Size(measuredWidth, height));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final richTextWidget = widget as RichText;
    final area = Rect(offset.dx, offset.dy, size.width, size.height);

    final limit = richTextWidget.maxLines != null
        ? min(richTextWidget.maxLines!, area.height)
        : area.height;
    for (var y = 0; y < _cachedLines.length; y++) {
      if (y >= limit) break;
      final line = _cachedLines[y];

      // Compute horizontal alignments
      final lineLen = line.length;
      var startX = 0;
      if (richTextWidget.textAlign == TextAlign.right) {
        startX = max(0, area.width - lineLen);
      } else if (richTextWidget.textAlign == TextAlign.center) {
        startX = max(0, (area.width - lineLen) ~/ 2);
      }

      for (var x = 0; x < line.length; x++) {
        if (startX + x >= area.width) break;
        final cell = buffer.getCell(area.x + startX + x, area.y + y);
        if (cell != null) {
          cell.char = line[x].char;
          cell.style = line[x].style;
        }
      }
    }
  }
}
