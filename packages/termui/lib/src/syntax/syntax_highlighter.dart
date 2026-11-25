import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:syntax_highlight_lite/syntax_highlight_lite.dart' as shl;
import 'package:termui/termui.dart';

import 'glsl_grammar.dart';

final Map<String, String> _registeredGrammars = <String, String>{};

/// Registers [grammarJson] under [language] if not yet registered.
///
/// Used internally by [registerGlslLanguage] so built-in registrations are
/// tracked alongside custom `grammarJson` definitions.
void registerSyntaxGrammarIfAbsent(String language, String grammarJson) {
  if (_registeredGrammars.containsKey(language)) return;
  _validateAndRegisterGrammar(language, grammarJson);
}

void _validateAndRegisterGrammar(String language, String grammarJson) {
  _validateGrammarJson(grammarJson);
  final existing = _registeredGrammars[language];
  if (existing != null) {
    if (existing == grammarJson) return;
    throw ArgumentError.value(
      grammarJson,
      'grammarJson',
      'Language "$language" is already registered with a different grammar.',
    );
  }
  try {
    shl.Highlighter.addLanguage(language, grammarJson);
  } on Object catch (error) {
    throw ArgumentError.value(
      grammarJson,
      'grammarJson',
      'Failed to register grammar for "$language": $error',
    );
  }
  _registeredGrammars[language] = grammarJson;
}

void _validateGrammarJson(String grammarJson) {
  final Object? decoded;
  try {
    decoded = jsonDecode(grammarJson);
  } on FormatException catch (error) {
    throw ArgumentError.value(
      grammarJson,
      'grammarJson',
      'Invalid JSON grammar: ${error.message}',
    );
  }
  if (decoded is! Map<String, Object?>) {
    throw ArgumentError.value(
      grammarJson,
      'grammarJson',
      'Grammar JSON must decode to a JSON object.',
    );
  }
  final name = decoded['name'];
  final scopeName = decoded['scopeName'];
  if (name is! String || name.isEmpty) {
    throw ArgumentError.value(
      grammarJson,
      'grammarJson',
      'Grammar JSON requires a non-empty string "name".',
    );
  }
  if (scopeName is! String || scopeName.isEmpty) {
    throw ArgumentError.value(
      grammarJson,
      'grammarJson',
      'Grammar JSON requires a non-empty string "scopeName".',
    );
  }
  final repoKeys = _validateRepository(decoded['repository']);
  _validateRule(decoded, repoKeys);
}

Set<String> _validateRepository(Object? rawRepository) {
  if (rawRepository == null) return const <String>{};
  if (rawRepository is! Map<String, Object?>) {
    throw ArgumentError.value(
      rawRepository,
      'grammarJson',
      'Grammar "repository" must be a JSON object.',
    );
  }
  final keys = rawRepository.keys.toSet();
  for (final entry in rawRepository.entries) {
    _validateRule(entry.value, keys);
  }
  return keys;
}

void _validateRule(Object? rawRule, Set<String> repoKeys) {
  if (rawRule is! Map<String, Object?>) {
    throw ArgumentError('Grammar rule must be a JSON object.');
  }
  if (rawRule.containsKey('include')) {
    _validateInclude(rawRule['include'], repoKeys);
    return;
  }
  if (rawRule.containsKey('match')) {
    _validateRegex(rawRule['match'], 'match');
    _validateCaptures(rawRule['captures'], repoKeys);
    return;
  }
  if (rawRule.containsKey('begin') &&
      (rawRule.containsKey('end') || rawRule.containsKey('while'))) {
    _validateMultilineRule(rawRule, repoKeys);
    return;
  }
  if (rawRule.containsKey('patterns')) {
    _validatePatternsList(rawRule['patterns'], repoKeys);
    return;
  }
  throw ArgumentError('Unknown TextMate grammar rule type.');
}

void _validateInclude(Object? include, Set<String> repoKeys) {
  if (include is! String || !include.startsWith('#') || include.length < 2) {
    throw ArgumentError('Invalid grammar include "$include".');
  }
  final target = include.substring(1);
  if (!repoKeys.contains(target)) {
    throw ArgumentError('Grammar include "$include" not found in repository.');
  }
}

void _validateMultilineRule(Map<String, Object?> rule, Set<String> repoKeys) {
  _validateRegex(rule['begin'], 'begin');
  if (rule.containsKey('end')) _validateRegex(rule['end'], 'end');
  if (rule.containsKey('while')) _validateRegex(rule['while'], 'while');
  _validateCaptures(rule['captures'], repoKeys);
  _validateCaptures(rule['beginCaptures'], repoKeys);
  _validateCaptures(rule['endCaptures'], repoKeys);
  if (rule.containsKey('patterns')) {
    _validatePatternsList(rule['patterns'], repoKeys);
  }
}

void _validateCaptures(Object? rawCaptures, Set<String> repoKeys) {
  if (rawCaptures == null) return;
  if (rawCaptures is! Map<String, Object?>) {
    throw ArgumentError('Grammar captures must be a JSON object.');
  }
  for (final value in rawCaptures.values) {
    if (value is! Map<String, Object?>) {
      throw ArgumentError('Grammar capture entry must be a JSON object.');
    }
    if (value.containsKey('patterns')) {
      _validatePatternsList(value['patterns'], repoKeys);
    }
  }
}

void _validatePatternsList(Object? rawPatterns, Set<String> repoKeys) {
  if (rawPatterns is! List<Object?>) {
    throw ArgumentError('Grammar "patterns" must be a JSON array.');
  }
  for (final item in rawPatterns) {
    _validateRule(item, repoKeys);
  }
}

void _validateRegex(Object? pattern, String field) {
  if (pattern is! String) {
    throw ArgumentError('Grammar "$field" must be a string.');
  }
  try {
    RegExp(pattern, multiLine: true);
  } on FormatException catch (error) {
    throw ArgumentError('Invalid regex in grammar "$field": ${error.message}');
  }
}

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
  final int order;
  final int start;
  final int end;
  final Color underlineColor;
  final UnderlineStyle underlineStyle;

  const _ResolvedDiagnostic({
    required this.order,
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
  List<TextSpan> _cachedBaseSpans = const <TextSpan>[];
  List<int>? _cachedLineStarts;
  List<TextDiagnosticSpan> _cachedDiagnostics = const <TextDiagnosticSpan>[];
  TextSpan? _cachedSpan;
  TextSpan? _cachedFieldInnerSpan;
  Style? _cachedFieldBaseStyle;
  TextSpan? _cachedFieldSpan;
  int _debugHighlightCount = 0;

  /// Creates a [SyntaxTextHighlighter] for [language] styled from [theme].
  ///
  /// When [language] is `'glsl'` and [grammarJson] is omitted,
  /// [registerGlslLanguage] is invoked automatically. Pass [grammarJson] to
  /// register a custom TextMate JSON grammar under [language]. Registration is
  /// validated upfront and throws [ArgumentError] on malformed grammars,
  /// conflicting re-registrations for an already-registered [language], or
  /// unregistered [language] identifiers.
  SyntaxTextHighlighter({
    required this.language,
    TerminalColorTheme theme = TerminalColorTheme.termuiDark,
    String? grammarJson,
  }) : _theme = theme {
    if (grammarJson != null) {
      _validateAndRegisterGrammar(language, grammarJson);
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
      if (_cachedCode != code) {
        _cachedLineStarts = null;
      }
      _cachedBaseRuns = _tokenize(code);
      _cachedBaseSpans = List<TextSpan>.unmodifiable([
        for (final run in _cachedBaseRuns)
          TextSpan(text: run.text, style: run.style),
      ]);
      _cachedCode = code;
      _cachedTheme = _theme;
      _debugHighlightCount++;
    }

    final span = _buildTextSpan(
      code,
      _cachedBaseRuns,
      _cachedBaseSpans,
      diagnostics,
    );
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
    if (identical(_cachedFieldInnerSpan, highlighted) &&
        _cachedFieldBaseStyle == baseStyle &&
        _cachedFieldSpan != null) {
      return _cachedFieldSpan!;
    }
    final wrapped = TextSpan(
      style: baseStyle,
      children: List<TextSpan>.unmodifiable(<TextSpan>[highlighted]),
    );
    _cachedFieldInnerSpan = highlighted;
    _cachedFieldBaseStyle = baseStyle;
    _cachedFieldSpan = wrapped;
    return wrapped;
  }

  void _invalidateCache() {
    _cachedCode = null;
    _cachedTheme = null;
    _cachedBaseRuns = const <_StyledRun>[];
    _cachedBaseSpans = const <TextSpan>[];
    _cachedLineStarts = null;
    _cachedDiagnostics = const <TextDiagnosticSpan>[];
    _cachedSpan = null;
    _cachedFieldInnerSpan = null;
    _cachedFieldBaseStyle = null;
    _cachedFieldSpan = null;
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
    fg = TerminalContrast.enforceMinimumContrast(
      fg,
      theme.background,
      minRatio: 3.0,
    );
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
    List<TextSpan> baseSpans,
    List<TextDiagnosticSpan> diagnostics,
  ) {
    if (baseRuns.isEmpty) {
      return TextSpan(
        text: '',
        style: Style(foreground: _theme.foreground),
      );
    }
    if (diagnostics.isEmpty) {
      return TextSpan(children: baseSpans);
    }
    final resolved = _resolveDiagnostics(code, diagnostics);
    if (resolved.isEmpty) {
      return TextSpan(children: baseSpans);
    }
    return _overlayDiagnostics(baseRuns, baseSpans, resolved);
  }

  static TextSpan _overlayDiagnostics(
    List<_StyledRun> baseRuns,
    List<TextSpan> baseSpans,
    List<_ResolvedDiagnostic> resolved,
  ) {
    final sorted = List<_ResolvedDiagnostic>.of(resolved)
      ..sort((a, b) {
        final cmp = a.start.compareTo(b.start);
        return cmp != 0 ? cmp : a.order.compareTo(b.order);
      });
    final boundaries = _collectBoundaries(sorted);
    final active = <_ResolvedDiagnostic>[];
    final children = <TextSpan>[];
    var cursor = 0;
    var boundIdx = 0;
    var diagIdx = 0;

    for (var i = 0; i < baseRuns.length; i++) {
      final run = baseRuns[i];
      final runStart = cursor;
      final runEnd = runStart + run.text.length;
      cursor = runEnd;
      if (active.isEmpty &&
          (diagIdx >= sorted.length || sorted[diagIdx].start >= runEnd)) {
        children.add(baseSpans[i]);
        continue;
      }
      while (boundIdx < boundaries.length && boundaries[boundIdx] <= runStart) {
        boundIdx++;
      }
      var segStart = runStart;
      while (boundIdx < boundaries.length && boundaries[boundIdx] < runEnd) {
        final cut = boundaries[boundIdx++];
        diagIdx = _advanceActiveDiagnostics(sorted, active, diagIdx, segStart);
        _appendSegment(
          run,
          baseSpans[i],
          runStart,
          runEnd,
          segStart,
          cut,
          active,
          children,
        );
        segStart = cut;
      }
      if (segStart < runEnd) {
        diagIdx = _advanceActiveDiagnostics(sorted, active, diagIdx, segStart);
        _appendSegment(
          run,
          baseSpans[i],
          runStart,
          runEnd,
          segStart,
          runEnd,
          active,
          children,
        );
      }
    }

    return TextSpan(children: List<TextSpan>.unmodifiable(children));
  }

  static int _advanceActiveDiagnostics(
    List<_ResolvedDiagnostic> sorted,
    List<_ResolvedDiagnostic> active,
    int diagIdx,
    int offset,
  ) {
    for (var i = active.length - 1; i >= 0; i--) {
      if (active[i].end <= offset) {
        active.removeAt(i);
      }
    }
    while (diagIdx < sorted.length && sorted[diagIdx].start <= offset) {
      final diag = sorted[diagIdx++];
      if (diag.end > offset) {
        active.add(diag);
      }
    }
    return diagIdx;
  }

  static _ResolvedDiagnostic? _primaryActiveDiagnostic(
    List<_ResolvedDiagnostic> active,
  ) {
    if (active.isEmpty) return null;
    var best = active.first;
    for (var i = 1; i < active.length; i++) {
      if (active[i].order < best.order) {
        best = active[i];
      }
    }
    return best;
  }

  static void _appendSegment(
    _StyledRun run,
    TextSpan baseSpan,
    int runStart,
    int runEnd,
    int segStart,
    int segEnd,
    List<_ResolvedDiagnostic> active,
    List<TextSpan> out,
  ) {
    final diag = _primaryActiveDiagnostic(active);
    if (diag == null && segStart == runStart && segEnd == runEnd) {
      out.add(baseSpan);
      return;
    }
    final slice = (segStart == runStart && segEnd == runEnd)
        ? run.text
        : run.text.substring(segStart - runStart, segEnd - runStart);
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

  static List<int> _collectBoundaries(List<_ResolvedDiagnostic> resolved) {
    final points = <int>{};
    for (final diag in resolved) {
      points.add(diag.start);
      points.add(diag.end);
    }
    return points.toList()..sort();
  }

  List<_ResolvedDiagnostic> _resolveDiagnostics(
    String code,
    List<TextDiagnosticSpan> diagnostics,
  ) {
    final lineStarts = _cachedLineStarts ??= _computeLineStarts(code);
    final out = <_ResolvedDiagnostic>[];

    for (var i = 0; i < diagnostics.length; i++) {
      final interval = _resolveSingleDiagnostic(
        code,
        lineStarts,
        diagnostics[i],
        i,
      );
      if (interval != null) out.add(interval);
    }
    return out;
  }

  static _ResolvedDiagnostic? _resolveSingleDiagnostic(
    String code,
    List<int> lineStarts,
    TextDiagnosticSpan diag,
    int order,
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

    if (_isAsciiSlice(code, lineStart, lineEnd)) {
      return _ResolvedDiagnostic(
        order: order,
        start: rawStart,
        end: rawEnd,
        underlineColor: diag.underlineColor,
        underlineStyle: diag.underlineStyle,
      );
    }

    final lineOffsets = _computeLineGraphemeOffsets(code, lineStart, lineEnd);
    final start = lineStart + _snapFloor(lineOffsets, rawStart - lineStart);
    var end = lineStart + _snapCeil(lineOffsets, rawEnd - lineStart);
    if (end <= start) {
      end = lineStart + _snapCeil(lineOffsets, start - lineStart + 1);
    }
    if (end > lineEnd) end = lineEnd;
    if (end <= start) return null;

    return _ResolvedDiagnostic(
      order: order,
      start: start,
      end: end,
      underlineColor: diag.underlineColor,
      underlineStyle: diag.underlineStyle,
    );
  }

  static bool _isAsciiSlice(String code, int start, int end) {
    for (var i = start; i < end; i++) {
      if (code.codeUnitAt(i) >= 0x80) return false;
    }
    return true;
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

  static List<int> _computeLineGraphemeOffsets(
    String code,
    int lineStart,
    int lineEnd,
  ) {
    final offsets = <int>[0];
    var pos = 0;
    for (final ch in code.substring(lineStart, lineEnd).characters) {
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
