import 'dart:math';
import 'dart:typed_data';

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

final class _SpanOrdinalCounter {
  int _next = 0;
  int next() => _next++;
}

final class _ShaderSpanGroup {
  final String? explicitId;
  final int autoOrdinal;
  final ShaderRef shader;
  final CellPadding padding;
  final ShaderRegionStage stage;
  final int zIndex;
  final bool? persist;
  final Float32List? params;

  const _ShaderSpanGroup({
    required this.explicitId,
    required this.autoOrdinal,
    required this.shader,
    required this.padding,
    required this.stage,
    required this.zIndex,
    required this.persist,
    required this.params,
  });

  String resolveId(Offset offset) {
    final explicit = explicitId;
    if (explicit != null && explicit.isNotEmpty) {
      return sanitizeShaderRegionId(explicit, fallback: 'rt');
    }
    final slug = sanitizeShaderRegionId(shader.shaderId, fallback: 'shader');
    return sanitizeShaderRegionId(
      'rt_${slug}_${offset.dx}_${offset.dy}_$autoOrdinal',
      fallback: 'rt',
    );
  }
}

/// A helper representing a single grapheme cluster with its style and optional
/// shader region or cell transform metadata.
class StyledChar {
  /// The isolated grapheme character.
  final String char;

  /// The style bound to this character.
  final Style style;

  /// Optional per-cell spatial transform inherited from a [TextSpan].
  final CellTransform? transform;

  final _ShaderSpanGroup? _shaderGroup;

  /// Creates a [StyledChar] mapping a grapheme string to its style.
  StyledChar(this.char, this.style, {this.transform}) : _shaderGroup = null;

  StyledChar._withGroup(
    this.char,
    this.style,
    this.transform,
    this._shaderGroup,
  );
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

  /// Optional scoped [ShaderRef] applied across all lines spanned by this node.
  final ShaderRef? shader;

  /// Optional stable region identifier (`^[A-Za-z0-9_.-]{1,64}$`) for [shader].
  final String? shaderRegionId;

  /// Cell-grid bleed padding around this span's painted glyphs when [shader] is set.
  final CellPadding shaderPadding;

  /// Compositing stage relative to text glyphs when [shader] is set.
  final ShaderRegionStage shaderStage;

  /// Stacking order among active shader regions when [shader] is set.
  final int shaderZIndex;

  /// Optional previous-frame feedback override for [shader].
  final bool? shaderPersist;

  /// Optional user float uniforms (`p0..p7`) passed to [shader].
  final Float32List? shaderParams;

  /// Optional per-cell spatial [CellTransform] applied to cells painted by this span.
  final CellTransform? transform;

  /// Initializes a text span with optional text content, styling overrides,
  /// shader region metadata, per-cell transform, and nested children spans.
  const TextSpan({
    this.text,
    this.style,
    this.children = const [],
    this.shader,
    this.shaderRegionId,
    this.shaderPadding = CellPadding.zero,
    this.shaderStage = ShaderRegionStage.overGlyphs,
    this.shaderZIndex = 0,
    this.shaderPersist,
    this.shaderParams,
    this.transform,
  });

  /// Recursively flattens the styling tree into a list of styled characters.
  void buildStyledChars(List<StyledChar> output, Style parentStyle) {
    _collectStyledChars(output, parentStyle, null, null, _SpanOrdinalCounter());
  }

  void _collectStyledChars(
    List<StyledChar> output,
    Style parentStyle,
    _ShaderSpanGroup? parentGroup,
    CellTransform? parentTransform,
    _SpanOrdinalCounter counter,
  ) {
    final mergedStyle = style != null ? parentStyle.merge(style!) : parentStyle;
    final activeGroup = shader != null
        ? _ShaderSpanGroup(
            explicitId: shaderRegionId,
            autoOrdinal: counter.next(),
            shader: shader!,
            padding: shaderPadding,
            stage: shaderStage,
            zIndex: shaderZIndex,
            persist: shaderPersist,
            params: shaderParams,
          )
        : parentGroup;
    final activeTransform = transform ?? parentTransform;

    if (text != null) {
      for (final char in text!.characters) {
        output.add(
          StyledChar._withGroup(
            char,
            mergedStyle,
            activeTransform,
            activeGroup,
          ),
        );
      }
    }

    for (final child in children) {
      child._collectStyledChars(
        output,
        mergedStyle,
        activeGroup,
        activeTransform,
        counter,
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TextSpan &&
          other.text == text &&
          other.style == style &&
          other.shader == shader &&
          other.shaderRegionId == shaderRegionId &&
          other.shaderPadding == shaderPadding &&
          other.shaderStage == shaderStage &&
          other.shaderZIndex == shaderZIndex &&
          other.shaderPersist == shaderPersist &&
          _floatListEquals(other.shaderParams, shaderParams) &&
          other.transform == transform &&
          _listEquals(other.children, children);

  @override
  int get hashCode => Object.hash(
    text,
    style,
    shader,
    shaderRegionId,
    shaderPadding,
    shaderStage,
    shaderZIndex,
    shaderPersist,
    shaderParams == null ? null : Object.hashAll(shaderParams!),
    transform,
    Object.hashAll(children),
  );

  static bool _floatListEquals(Float32List? a, Float32List? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

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

    final tokens = _tokenizeStyledChars(allChars);
    final lines = <List<StyledChar>>[];
    var currentLine = <StyledChar>[];

    for (final token in tokens) {
      if (token.isNewline) {
        lines.add(currentLine);
        currentLine = <StyledChar>[];
      } else if (token.isWhitespace) {
        currentLine = _appendWhitespaceToken(
          lines,
          currentLine,
          token,
          maxWidth,
        );
      } else {
        currentLine = _appendWordToken(lines, currentLine, token, maxWidth);
      }
    }

    if (currentLine.isNotEmpty) {
      _trimTrailingSpaces(currentLine);
      lines.add(currentLine);
    }

    return lines;
  }

  static List<StyledToken> _tokenizeStyledChars(List<StyledChar> allChars) {
    final tokens = <StyledToken>[];
    var i = 0;
    while (i < allChars.length) {
      final char = allChars[i].char;
      if (char == '\n') {
        tokens.add(StyledToken([allChars[i]], isNewline: true));
        i++;
      } else if (char == ' ') {
        final end = _scanRunEnd(allChars, i, whitespace: true);
        tokens.add(StyledToken(allChars.sublist(i, end), isWhitespace: true));
        i = end;
      } else {
        final end = _scanRunEnd(allChars, i, whitespace: false);
        tokens.add(StyledToken(allChars.sublist(i, end)));
        i = end;
      }
    }
    return tokens;
  }

  static int _scanRunEnd(
    List<StyledChar> allChars,
    int start, {
    required bool whitespace,
  }) {
    var i = start;
    while (i < allChars.length) {
      final c = allChars[i].char;
      if (c == '\n' || (c == ' ') != whitespace) break;
      i++;
    }
    return i;
  }

  static List<StyledChar> _appendWhitespaceToken(
    List<List<StyledChar>> lines,
    List<StyledChar> currentLine,
    StyledToken token,
    int maxWidth,
  ) {
    if (currentLine.isEmpty) return currentLine;
    if (currentLine.length + token.length <= maxWidth) {
      currentLine.addAll(token.chars);
      return currentLine;
    }
    lines.add(currentLine);
    return <StyledChar>[];
  }

  static List<StyledChar> _appendWordToken(
    List<List<StyledChar>> lines,
    List<StyledChar> currentLine,
    StyledToken token,
    int maxWidth,
  ) {
    if (currentLine.isNotEmpty &&
        currentLine.length + token.length <= maxWidth) {
      currentLine.addAll(token.chars);
      return currentLine;
    }
    var targetLine = currentLine;
    if (targetLine.isNotEmpty) {
      _trimTrailingSpaces(targetLine);
      lines.add(targetLine);
      targetLine = <StyledChar>[];
    }
    var remaining = token.chars;
    while (remaining.length > maxWidth) {
      lines.add(remaining.sublist(0, maxWidth));
      remaining = remaining.sublist(maxWidth);
    }
    targetLine.addAll(remaining);
    return targetLine;
  }

  static void _trimTrailingSpaces(List<StyledChar> line) {
    while (line.isNotEmpty && line.last.char == ' ') {
      line.removeLast();
    }
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
    final groupRects = <_ShaderSpanGroup, List<Rect>>{};

    final limit = richTextWidget.maxLines != null
        ? min(richTextWidget.maxLines!, area.height)
        : area.height;
    for (var y = 0; y < _cachedLines.length; y++) {
      if (y >= limit) break;
      final line = _cachedLines[y];
      final startX = _resolveLineStartX(
        richTextWidget.textAlign,
        area.width,
        line.length,
      );
      _paintStyledLine(
        buffer,
        line,
        area.x + startX,
        area.y + y,
        area.x + area.width,
        groupRects,
      );
    }
    _registerShaderRegions(buffer, offset, groupRects);
  }

  static int _resolveLineStartX(TextAlign align, int areaWidth, int lineLen) =>
      switch (align) {
        TextAlign.right => max(0, areaWidth - lineLen),
        TextAlign.center => max(0, (areaWidth - lineLen) ~/ 2),
        TextAlign.left || TextAlign.justify => 0,
      };

  static void _paintStyledLine(
    Buffer buffer,
    List<StyledChar> line,
    int startX,
    int cellY,
    int maxX,
    Map<_ShaderSpanGroup, List<Rect>> groupRects,
  ) {
    _ShaderSpanGroup? activeGroup;
    var runStartX = 0;
    var runEndX = 0;
    var col = startX;

    for (final sc in line) {
      final w = max(1, graphemeWidth(sc.char));
      if (col + w > maxX) break;
      buffer.setAttributes(
        col,
        cellY,
        char: sc.char,
        fg: sc.style.foreground?.argb ?? 0,
        bg: sc.style.background?.argb ?? 0,
        modifiers: sc.style.modifiers,
        underlineColor: sc.style.underlineColor?.argb ?? 0,
        uri: sc.style.uri,
      );
      if (sc.transform case final xform? when !xform.isIdentity) {
        buffer.setCellTransform(col, cellY, xform);
      }

      final group = sc._shaderGroup;
      if (identical(group, activeGroup)) {
        if (group != null) runEndX = col + w;
      } else {
        _flushShaderRun(groupRects, activeGroup, runStartX, runEndX, cellY);
        activeGroup = group;
        runStartX = col;
        runEndX = col + w;
      }
      col += w;
    }
    _flushShaderRun(groupRects, activeGroup, runStartX, runEndX, cellY);
  }

  static void _flushShaderRun(
    Map<_ShaderSpanGroup, List<Rect>> groupRects,
    _ShaderSpanGroup? group,
    int startX,
    int endX,
    int y,
  ) {
    if (group == null || endX <= startX) return;
    (groupRects[group] ??= <Rect>[]).add(Rect(startX, y, endX - startX, 1));
  }

  static void _registerShaderRegions(
    Buffer buffer,
    Offset offset,
    Map<_ShaderSpanGroup, List<Rect>> groupRects,
  ) {
    for (final entry in groupRects.entries) {
      final group = entry.key;
      buffer.addShaderRegion(
        ShaderRegion.fromRef(
          id: group.resolveId(offset),
          shader: group.shader,
          sourceRects: entry.value,
          padding: group.padding,
          stage: group.stage,
          zIndex: group.zIndex,
          persist: group.persist,
          params: group.params,
        ),
      );
    }
  }
}
