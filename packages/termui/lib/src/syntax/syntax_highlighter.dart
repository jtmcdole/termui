import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:syntax_highlight_lite/syntax_highlight_lite.dart' as shl;
import 'package:termui/termui.dart';

import 'glsl_grammar.dart';

/// A 1-based line/column underline overlay (such as a compiler error or lint
/// warning squiggle) applied on top of syntax-highlighted [TextSpan] tokens.
final class TextDiagnosticSpan {
  /// 1-based line number in the source string.
  final int line;

  /// 1-based UTF-16 column on [line].
  final int column;

  /// Highlighted span length in UTF-16 code units (`>= 1`).
  final int length;

  /// SGR 58 underline color painted under this span.
  final Color underlineColor;

  /// Underline stroke variant (defaults to [UnderlineStyle.curly]).
  final UnderlineStyle underlineStyle;

  /// Creates an immutable [TextDiagnosticSpan].
  const TextDiagnosticSpan({
    required this.line,
    required this.column,
    required this.length,
    required this.underlineColor,
    this.underlineStyle = UnderlineStyle.curly,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TextDiagnosticSpan &&
          other.line == line &&
          other.column == column &&
          other.length == length &&
          other.underlineColor == underlineColor &&
          other.underlineStyle == underlineStyle;

  @override
  int get hashCode =>
      Object.hash(line, column, length, underlineColor, underlineStyle);
}

final class _StyledRun {
  final String text;
  final Style style;

  const _StyledRun(this.text, this.style);
}

final class _ResolvedDiagnostic {
  final int start;
  final int end;
  final Color underlineColor;
  final UnderlineStyle underlineStyle;

  const _ResolvedDiagnostic({
    required this.start,
    required this.end,
    required this.underlineColor,
    required this.underlineStyle,
  });
}

/// Bridges `syntax_highlight_lite` TextMate grammars into cached `termui`
/// [TextSpan] trees usable directly in both [RichText] and
/// [TextField.spanBuilder].
final class SyntaxTextHighlighter {
  /// Language identifier registered with `syntax_highlight_lite` (for example
  /// `'glsl'`).
  final String language;

  TerminalColorTheme _theme;
  late shl.Highlighter _highlighter;

  String? _cachedCode;
  TerminalColorTheme? _cachedTheme;
  List<_StyledRun> _cachedBaseRuns = const <_StyledRun>[];
  List<TextDiagnosticSpan> _cachedDiagnostics = const <TextDiagnosticSpan>[];
  TextSpan? _cachedSpan;
  int _debugHighlightCount = 0;

  /// Creates a [SyntaxTextHighlighter] for [language] styled from [theme].
  ///
  /// When [language] is `'glsl'` and [grammarJson] is omitted,
  /// [registerGlslLanguage] is invoked automatically. Pass [grammarJson] to
  /// register a custom TextMate JSON grammar under [language]. Registration is
  /// first-registration-wins per [language] id, and throws [ArgumentError] if
  /// [language] has not been registered.
  SyntaxTextHighlighter({
    required this.language,
    TerminalColorTheme theme = TerminalColorTheme.termuiDark,
    String? grammarJson,
  }) : _theme = theme {
    if (grammarJson != null) {
      shl.Highlighter.addLanguage(language, grammarJson);
    } else if (language == kGlslLanguageId) {
      registerGlslLanguage();
    }
    _highlighter = _createHighlighter(language, _theme);
  }

  /// Active terminal color theme used to colorize grammar scopes.
  TerminalColorTheme get theme => _theme;

  /// Number of full TextMate highlighting passes performed (useful in tests
  /// to verify cache hits across unchanged repaints).
  int get debugHighlightCount => _debugHighlightCount;

  /// Updates the active [TerminalColorTheme] and rebuilds the underlying
  /// TextMate theme table when [nextTheme] differs from [theme].
  void setTheme(TerminalColorTheme nextTheme) {
    if (_theme == nextTheme) return;
    _theme = nextTheme;
    _highlighter = _createHighlighter(language, _theme);
    _invalidateCache();
  }

  /// Highlights [code] into a `termui` [TextSpan] tree with optional
  /// [diagnostics] overlaid as SGR 58 underline spans.
  ///
  /// Results are cached by `(code, theme, diagnostics)` so cursor blinks and
  /// scroll repaints reuse the existing [TextSpan] tree without re-tokenizing.
  TextSpan highlight(
    String code, {
    List<TextDiagnosticSpan> diagnostics = const <TextDiagnosticSpan>[],
  }) {
    final baseMatches = _cachedCode == code && _cachedTheme == _theme;
    if (baseMatches &&
        _cachedSpan != null &&
        _diagnosticsEqual(_cachedDiagnostics, diagnostics)) {
      return _cachedSpan!;
    }

    if (!baseMatches) {
      _cachedBaseRuns = _tokenize(code);
      _cachedCode = code;
      _cachedTheme = _theme;
      _debugHighlightCount++;
    }

    final span = _buildTextSpan(code, _cachedBaseRuns, diagnostics);
    _cachedDiagnostics = List<TextDiagnosticSpan>.unmodifiable(diagnostics);
    _cachedSpan = span;
    return span;
  }

  /// Convenience [TextFieldSpanBuilder] adapter that highlights [text] using
  /// [diagnostics] while preserving [baseStyle] background attributes.
  TextSpan buildFieldSpan(
    String text,
    Style baseStyle, {
    List<TextDiagnosticSpan> diagnostics = const <TextDiagnosticSpan>[],
  }) {
    final highlighted = highlight(text, diagnostics: diagnostics);
    if (baseStyle == Style.empty) return highlighted;
    return TextSpan(style: baseStyle, children: <TextSpan>[highlighted]);
  }

  void _invalidateCache() {
    _cachedCode = null;
    _cachedTheme = null;
    _cachedBaseRuns = const <_StyledRun>[];
    _cachedDiagnostics = const <TextDiagnosticSpan>[];
    _cachedSpan = null;
  }

  List<_StyledRun> _tokenize(String code) {
    if (code.isEmpty) return const <_StyledRun>[];
    final root = _highlighter.highlight(code);
    final rawRuns = <_StyledRun>[];
    final fallbackStyle = Style(foreground: _theme.foreground);
    _collectRuns(root, fallbackStyle, rawRuns);
    return _coalesceRuns(rawRuns);
  }

  void _collectRuns(shl.TextSpan node, Style inherited, List<_StyledRun> out) {
    final effective = node.style == null
        ? inherited
        : _convertStyle(node.style!, _theme);
    final text = node.text;
    if (text != null && text.isNotEmpty) {
      out.add(_StyledRun(text, effective));
    }
    for (final child in node.children) {
      _collectRuns(child, effective, out);
    }
  }

  static Style _convertStyle(shl.TextStyle style, TerminalColorTheme theme) {
    var fg = Color.argb(style.foreground.argb);
    if (theme.brightness == TerminalBrightness.dark && fg == Colors.black) {
      fg = theme.foreground;
    }
    var modifiers = Modifier.none;
    if (style.bold) modifiers |= Modifier.bold;
    if (style.italic) modifiers |= Modifier.italic;
    if (style.underline) modifiers |= Modifier.underlineSingle;
    return Style(foreground: fg, modifiers: modifiers);
  }

  static List<_StyledRun> _coalesceRuns(List<_StyledRun> runs) {
    if (runs.length <= 1) return runs;
    final merged = <_StyledRun>[];
    var currentText = StringBuffer(runs.first.text);
    var currentStyle = runs.first.style;
    for (var i = 1; i < runs.length; i++) {
      final run = runs[i];
      if (run.style == currentStyle) {
        currentText.write(run.text);
      } else {
        merged.add(_StyledRun(currentText.toString(), currentStyle));
        currentText = StringBuffer(run.text);
        currentStyle = run.style;
      }
    }
    merged.add(_StyledRun(currentText.toString(), currentStyle));
    return merged;
  }

  TextSpan _buildTextSpan(
    String code,
    List<_StyledRun> baseRuns,
    List<TextDiagnosticSpan> diagnostics,
  ) {
    if (baseRuns.isEmpty) {
      return TextSpan(
        text: '',
        style: Style(foreground: _theme.foreground),
      );
    }
    if (diagnostics.isEmpty) {
      return TextSpan(
        children: [
          for (final run in baseRuns)
            TextSpan(text: run.text, style: run.style),
        ],
      );
    }
    final resolved = _resolveDiagnostics(code, diagnostics);
    if (resolved.isEmpty) {
      return TextSpan(
        children: [
          for (final run in baseRuns)
            TextSpan(text: run.text, style: run.style),
        ],
      );
    }
    return _overlayDiagnostics(baseRuns, resolved);
  }

  static TextSpan _overlayDiagnostics(
    List<_StyledRun> baseRuns,
    List<_ResolvedDiagnostic> resolved,
  ) {
    final boundaries = _collectBoundaries(resolved);
    final children = <TextSpan>[];
    var cursor = 0;

    for (final run in baseRuns) {
      final runStart = cursor;
      final runEnd = runStart + run.text.length;
      _emitRunSegments(run, runStart, runEnd, boundaries, resolved, children);
      cursor = runEnd;
    }

    return TextSpan(children: children);
  }

  static void _emitRunSegments(
    _StyledRun run,
    int runStart,
    int runEnd,
    List<int> boundaries,
    List<_ResolvedDiagnostic> resolved,
    List<TextSpan> out,
  ) {
    var segStart = runStart;
    for (final cut in boundaries) {
      if (cut <= segStart) continue;
      if (cut >= runEnd) break;
      _appendSegment(run, runStart, segStart, cut, resolved, out);
      segStart = cut;
    }
    if (segStart < runEnd) {
      _appendSegment(run, runStart, segStart, runEnd, resolved, out);
    }
  }

  static void _appendSegment(
    _StyledRun run,
    int runStart,
    int segStart,
    int segEnd,
    List<_ResolvedDiagnostic> resolved,
    List<TextSpan> out,
  ) {
    final slice = run.text.substring(segStart - runStart, segEnd - runStart);
    final diag = _firstDiagnosticAt(resolved, segStart);
    final style = diag == null
        ? run.style
        : run.style.merge(
            Style(
              underlineStyle: diag.underlineStyle,
              underlineColor: diag.underlineColor,
            ),
          );
    out.add(TextSpan(text: slice, style: style));
  }

  static _ResolvedDiagnostic? _firstDiagnosticAt(
    List<_ResolvedDiagnostic> resolved,
    int offset,
  ) {
    for (final diag in resolved) {
      if (offset >= diag.start && offset < diag.end) return diag;
    }
    return null;
  }

  static List<int> _collectBoundaries(List<_ResolvedDiagnostic> resolved) {
    final points = <int>{};
    for (final diag in resolved) {
      points.add(diag.start);
      points.add(diag.end);
    }
    return points.toList()..sort();
  }

  static List<_ResolvedDiagnostic> _resolveDiagnostics(
    String code,
    List<TextDiagnosticSpan> diagnostics,
  ) {
    final lineStarts = _computeLineStarts(code);
    final graphemeOffsets = _computeGraphemeOffsets(code);
    final out = <_ResolvedDiagnostic>[];

    for (final diag in diagnostics) {
      final interval = _resolveSingleDiagnostic(
        code,
        lineStarts,
        graphemeOffsets,
        diag,
      );
      if (interval != null) out.add(interval);
    }
    return out;
  }

  static _ResolvedDiagnostic? _resolveSingleDiagnostic(
    String code,
    List<int> lineStarts,
    List<int> graphemeOffsets,
    TextDiagnosticSpan diag,
  ) {
    if (lineStarts.isEmpty || code.isEmpty) return null;
    final lineIdx = (diag.line - 1).clamp(0, lineStarts.length - 1);
    final lineStart = lineStarts[lineIdx];
    final lineEnd = _lineContentEnd(code, lineStarts, lineIdx);
    if (lineEnd <= lineStart) return null;

    final rawCol = (diag.column - 1).clamp(0, lineEnd - lineStart);
    final rawStart = (lineStart + rawCol).clamp(lineStart, lineEnd - 1);
    final spanLen = diag.length < 1 ? 1 : diag.length;
    final rawEnd = (rawStart + spanLen).clamp(rawStart + 1, lineEnd);

    final start = _snapFloor(graphemeOffsets, rawStart);
    var end = _snapCeil(graphemeOffsets, rawEnd);
    if (end <= start) {
      end = _snapCeil(graphemeOffsets, start + 1);
    }
    if (end > lineEnd) end = lineEnd;
    if (end <= start) return null;

    return _ResolvedDiagnostic(
      start: start,
      end: end,
      underlineColor: diag.underlineColor,
      underlineStyle: diag.underlineStyle,
    );
  }

  static List<int> _computeLineStarts(String code) {
    final starts = <int>[0];
    for (var i = 0; i < code.length; i++) {
      if (code.codeUnitAt(i) == 0x0A) {
        starts.add(i + 1);
      }
    }
    return starts;
  }

  static int _lineContentEnd(String code, List<int> lineStarts, int lineIdx) {
    var end = lineIdx + 1 < lineStarts.length
        ? lineStarts[lineIdx + 1] - 1
        : code.length;
    if (end > lineStarts[lineIdx] && code.codeUnitAt(end - 1) == 0x0D) {
      end--;
    }
    return end;
  }

  static List<int> _computeGraphemeOffsets(String code) {
    final offsets = <int>[0];
    var pos = 0;
    for (final ch in code.characters) {
      pos += ch.length;
      offsets.add(pos);
    }
    return offsets;
  }

  static int _snapFloor(List<int> sortedOffsets, int target) {
    var lo = 0;
    var hi = sortedOffsets.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (sortedOffsets[mid] <= target) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return sortedOffsets[lo];
  }

  static int _snapCeil(List<int> sortedOffsets, int target) {
    var lo = 0;
    var hi = sortedOffsets.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (sortedOffsets[mid] >= target) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return sortedOffsets[lo];
  }

  static bool _diagnosticsEqual(
    List<TextDiagnosticSpan> a,
    List<TextDiagnosticSpan> b,
  ) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static shl.Highlighter _createHighlighter(
    String language,
    TerminalColorTheme theme,
  ) {
    final themeJson = _buildThemeJson(theme);
    final shlTheme = shl.HighlighterTheme.fromConfiguration(
      themeJson,
      shl.TextStyle(foreground: shl.Color(theme.foreground.argb)),
    );
    try {
      return shl.Highlighter(language: language, theme: shlTheme);
    } on TypeError {
      throw ArgumentError.value(
        language,
        'language',
        'Language is not registered; pass grammarJson to register it.',
      );
    }
  }

  static String _buildThemeJson(TerminalColorTheme theme) {
    final isDark = theme.brightness == TerminalBrightness.dark;
    final fgHex = _readableHex(theme.foreground, theme, minRatio: 4.5);
    final commentHex = _readableHex(theme.ansi[8], theme, minRatio: 3.0);
    final directiveHex = _readableHex(
      isDark ? theme.ansi[14] : theme.ansi[6],
      theme,
    );
    final uniformHex = _readableHex(
      isDark ? theme.ansi[11] : theme.ansi[13],
      theme,
    );
    final builtinVarHex = _readableHex(theme.ansi[6], theme);
    final keywordHex = _readableHex(theme.ansi[5], theme);
    final typeHex = _readableHex(theme.ansi[4], theme);
    final modifierHex = _readableHex(
      isDark ? theme.ansi[12] : theme.ansi[4],
      theme,
    );
    final functionHex = _readableHex(theme.ansi[2], theme);
    final numberHex = _readableHex(theme.ansi[3], theme);
    final constantHex = _readableHex(theme.ansi[1], theme);
    final stringHex = _readableHex(
      isDark ? theme.ansi[10] : theme.ansi[2],
      theme,
    );

    final settings = <Map<String, Object?>>[
      // Unscoped fallback rule prevents syntax_highlight_lite from falling back
      // to 0xFF000000 black on dark themes for unmatched or unstyled scopes.
      <String, Object?>{
        'settings': <String, Object?>{'foreground': fgHex},
      },
      _scopeRule('meta.directive.fterm', directiveHex, fontStyle: 'bold'),
      _scopeRule('comment', commentHex, fontStyle: 'italic'),
      _scopeRule('meta.preprocessor', keywordHex),
      _scopeRule('variable.language.shadertoy', uniformHex, fontStyle: 'bold'),
      _scopeRule('variable.language', builtinVarHex),
      _scopeRule('keyword', keywordHex, fontStyle: 'bold'),
      _scopeRule('storage.type', typeHex, fontStyle: 'bold'),
      _scopeRule('storage.modifier', modifierHex),
      _scopeRule('support.function', functionHex),
      _scopeRule('constant.numeric', numberHex),
      _scopeRule('constant.language', constantHex),
      _scopeRule('string', stringHex),
    ];

    return jsonEncode(<String, Object?>{'settings': settings});
  }

  static Map<String, Object?> _scopeRule(
    String scope,
    String foregroundHex, {
    String? fontStyle,
  }) {
    final styleMap = <String, Object?>{'foreground': foregroundHex};
    if (fontStyle != null) {
      assert(
        fontStyle == 'italic' ||
            fontStyle == 'bold' ||
            fontStyle == 'underline',
        'syntax_highlight_lite only supports single-token fontStyle values.',
      );
      styleMap['fontStyle'] = fontStyle;
    }
    return <String, Object?>{'scope': scope, 'settings': styleMap};
  }

  static String _readableHex(
    Color color,
    TerminalColorTheme theme, {
    double minRatio = 3.5,
  }) {
    final adjusted = TerminalContrast.enforceMinimumContrast(
      color,
      theme.background,
      minRatio: minRatio,
    );
    return CustomPaletteOverrides.formatHexRgb(adjusted);
  }
}
