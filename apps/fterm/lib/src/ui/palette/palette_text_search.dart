import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:termui/termui.dart' as tui;
import 'package:termui_flutter/termui_flutter.dart'
    show TerminalSearchHighlight;

import '../../shader_editor/shader_editor_controller.dart';
import '../../workspace/fterm_pane_controller.dart';

const int _snippetContextBefore = 20;
const int _snippetContextAfter = 40;
const int _snippetMaxMatchGraphemes = 80;

/// Immutable text match located within a terminal scrollback/screen row or a
/// shader editor source line.
final class TerminalTextMatch {
  /// Monotonic virtual row index for terminal matches (`null` for editor
  /// matches).
  final int? virtualRow;

  /// 1-based line number within the searched range (`1..N` from oldest retained
  /// terminal line or `1..lineCount` in the shader editor).
  final int oneBasedLine;

  /// Inclusive zero-based start cell column (terminal) or UTF-16 column
  /// (shader editor).
  final int startCol;

  /// Exclusive zero-based end cell column (terminal) or UTF-16 column
  /// (shader editor).
  final int endCol;

  /// Context excerpt surrounding the matched text.
  final String snippet;

  /// Inclusive UTF-16 start offset of the match inside [snippet].
  final int snippetMatchStart;

  /// Exclusive UTF-16 end offset of the match inside [snippet].
  final int snippetMatchEnd;

  /// 1-based target line for [ShaderEditorController.jumpToLine] (`null` for
  /// terminal matches).
  final int? editorLine;

  /// 1-based UTF-16 target column for [ShaderEditorController.jumpToLine]
  /// (`null` for terminal matches).
  final int? editorColumn;

  /// Matched text length in UTF-16 code units.
  final int matchLength;

  /// Creates an immutable [TerminalTextMatch].
  const TerminalTextMatch({
    this.virtualRow,
    required this.oneBasedLine,
    required this.startCol,
    required this.endCol,
    required this.snippet,
    required this.snippetMatchStart,
    required this.snippetMatchEnd,
    this.editorLine,
    this.editorColumn,
    required this.matchLength,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalTextMatch &&
          other.virtualRow == virtualRow &&
          other.oneBasedLine == oneBasedLine &&
          other.startCol == startCol &&
          other.endCol == endCol &&
          other.snippet == snippet &&
          other.snippetMatchStart == snippetMatchStart &&
          other.snippetMatchEnd == snippetMatchEnd &&
          other.editorLine == editorLine &&
          other.editorColumn == editorColumn &&
          other.matchLength == matchLength;

  @override
  int get hashCode => Object.hash(
    virtualRow,
    oneBasedLine,
    startCol,
    endCol,
    snippet,
    snippetMatchStart,
    snippetMatchEnd,
    editorLine,
    editorColumn,
    matchLength,
  );

  @override
  String toString() =>
      'TerminalTextMatch(virtualRow: $virtualRow, line: $oneBasedLine, '
      'cols: $startCol..$endCol, editorLine: $editorLine, '
      'editorColumn: $editorColumn, length: $matchLength)';
}

/// Result of running a `%` text or regex search across a terminal pane or
/// shader editor buffer.
final class TerminalTextSearchResult {
  /// Empty search result with no matches, no highlights, and no error.
  static const TerminalTextSearchResult empty = TerminalTextSearchResult(
    matches: <TerminalTextMatch>[],
    highlights: <TerminalSearchHighlight>[],
    truncated: false,
  );

  /// Ordered matches found in top-to-bottom, left-to-right order.
  final List<TerminalTextMatch> matches;

  /// Canvas highlight spans for terminal matches (with index `0` marked active
  /// when non-empty).
  final List<TerminalSearchHighlight> highlights;

  /// Whether scanning stopped early upon hitting `maxMatches`.
  final bool truncated;

  /// Regex compilation error message when `useRegex` fails to compile.
  final String? errorMessage;

  /// Creates an immutable [TerminalTextSearchResult].
  const TerminalTextSearchResult({
    required this.matches,
    required this.highlights,
    this.truncated = false,
    this.errorMessage,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalTextSearchResult &&
          listEquals(other.matches, matches) &&
          listEquals(other.highlights, highlights) &&
          other.truncated == truncated &&
          other.errorMessage == errorMessage;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(matches),
    Object.hashAll(highlights),
    truncated,
    errorMessage,
  );

  @override
  String toString() =>
      'TerminalTextSearchResult(matches: ${matches.length}, '
      'truncated: $truncated, errorMessage: $errorMessage)';
}

/// Builds immutable [TerminalSearchHighlight] spans for [matches], marking
/// [activeIndex] as active.
List<TerminalSearchHighlight> buildHighlightsForMatches(
  List<TerminalTextMatch> matches,
  int activeIndex,
) {
  if (matches.isEmpty) return const <TerminalSearchHighlight>[];
  return List<TerminalSearchHighlight>.unmodifiable(<TerminalSearchHighlight>[
    for (var i = 0; i < matches.length; i++)
      if (matches[i].virtualRow case final virtualRow?)
        if (matches[i].endCol > matches[i].startCol)
          TerminalSearchHighlight(
            virtualRow: virtualRow,
            startCol: matches[i].startCol,
            endCol: matches[i].endCol,
            isActive: i == activeIndex,
          ),
  ]);
}

/// Searches retained scrollback and live rows of [pane] (or active alternate
/// screen rows when `altScreen` is enabled) for [query].
///
/// Maps UTF-16 regex spans onto exact terminal cell columns while skipping
/// wide-glyph continuation cells (`ch.isEmpty`), and skips uncached remote
/// empty slices without issuing network page fetches.
TerminalTextSearchResult searchTerminalPane(
  FtermPaneController pane,
  String query, {
  bool caseSensitive = false,
  bool useRegex = false,
  int maxMatches = 2000,
}) {
  if (query.isEmpty || maxMatches <= 0) return TerminalTextSearchResult.empty;

  final (:pattern, :errorMessage) = _compileSearchPattern(
    query,
    caseSensitive: caseSensitive,
    useRegex: useRegex,
  );
  if (errorMessage != null || pattern == null) {
    return TerminalTextSearchResult(
      matches: const <TerminalTextMatch>[],
      highlights: const <TerminalSearchHighlight>[],
      errorMessage: errorMessage,
    );
  }

  final startRow = pane.oldestVirtualRow;
  final endRow = pane.totalVirtualLines;
  final matches = <TerminalTextMatch>[];
  var truncated = false;

  for (var row = startRow; row < endRow; row++) {
    final slice = pane.lookupVirtualLine(row);
    if (slice == null || slice.characters.isEmpty) continue;
    truncated = _scanTerminalRow(
      slice: slice,
      virtualRow: row,
      oneBasedLine: row - startRow + 1,
      pattern: pattern,
      maxMatches: maxMatches,
      out: matches,
    );
    if (truncated) break;
  }

  final frozenMatches = List<TerminalTextMatch>.unmodifiable(matches);
  return TerminalTextSearchResult(
    matches: frozenMatches,
    highlights: buildHighlightsForMatches(frozenMatches, 0),
    truncated: truncated,
  );
}

/// Searches lines of [controller] for [query] in literal or regex mode.
TerminalTextSearchResult searchShaderEditor(
  ShaderEditorController controller,
  String query, {
  bool caseSensitive = false,
  bool useRegex = false,
  int maxMatches = 2000,
}) {
  if (query.isEmpty || maxMatches <= 0) return TerminalTextSearchResult.empty;

  final (:pattern, :errorMessage) = _compileSearchPattern(
    query,
    caseSensitive: caseSensitive,
    useRegex: useRegex,
  );
  if (errorMessage != null || pattern == null) {
    return TerminalTextSearchResult(
      matches: const <TerminalTextMatch>[],
      highlights: const <TerminalSearchHighlight>[],
      errorMessage: errorMessage,
    );
  }

  final lines = controller.textController.value.lines;
  final matches = <TerminalTextMatch>[];
  var truncated = false;

  for (var lineIdx = 0; lineIdx < lines.length; lineIdx++) {
    final raw = lines[lineIdx];
    final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    if (line.isEmpty) continue;
    truncated = _scanEditorLine(
      line: line,
      oneBasedLine: lineIdx + 1,
      pattern: pattern,
      maxMatches: maxMatches,
      out: matches,
    );
    if (truncated) break;
  }

  return TerminalTextSearchResult(
    matches: List<TerminalTextMatch>.unmodifiable(matches),
    highlights: const <TerminalSearchHighlight>[],
    truncated: truncated,
  );
}

({RegExp? pattern, String? errorMessage}) _compileSearchPattern(
  String query, {
  required bool caseSensitive,
  required bool useRegex,
}) {
  try {
    final source = useRegex ? query : RegExp.escape(query);
    return (
      pattern: RegExp(source, caseSensitive: caseSensitive),
      errorMessage: null,
    );
  } on FormatException catch (error) {
    return (
      pattern: null,
      errorMessage: error.message.isEmpty
          ? 'Invalid regular expression.'
          : error.message,
    );
  }
}

bool _scanTerminalRow({
  required tui.VirtualLineSlice slice,
  required int virtualRow,
  required int oneBasedLine,
  required RegExp pattern,
  required int maxMatches,
  required List<TerminalTextMatch> out,
}) {
  final chars = slice.characters;
  final (:line, :codeUnitToCol) = _buildRowTextAndColumnMap(chars);
  if (line.isEmpty) return false;

  final rawMatches = pattern.allMatches(line);
  List<String>? graphemes;
  List<int>? starts;
  final cols = chars.length;

  for (final match in rawMatches) {
    if (match.start == match.end) continue;
    if (out.length >= maxMatches) return true;

    final startCol = codeUnitToCol[match.start];
    var endCol = codeUnitToCol[match.end - 1] + 1;
    while (endCol < cols && chars[endCol].isEmpty) {
      endCol++;
    }

    graphemes ??= line.characters.toList(growable: false);
    starts ??= _graphemeUtf16Starts(graphemes);
    final snippet = _buildMatchSnippet(
      graphemes: graphemes,
      starts: starts,
      lineLength: line.length,
      matchStart: match.start,
      matchEnd: match.end,
    );
    out.add(
      TerminalTextMatch(
        virtualRow: virtualRow,
        oneBasedLine: oneBasedLine,
        startCol: startCol,
        endCol: endCol,
        snippet: snippet.text,
        snippetMatchStart: snippet.matchStart,
        snippetMatchEnd: snippet.matchEnd,
        matchLength: match.end - match.start,
      ),
    );
  }
  return false;
}

({String line, List<int> codeUnitToCol}) _buildRowTextAndColumnMap(
  List<String> chars,
) {
  final buffer = StringBuffer();
  final codeUnitToCol = <int>[];
  for (var col = 0; col < chars.length; col++) {
    final ch = chars[col];
    if (ch.isEmpty) continue;
    buffer.write(ch);
    for (var i = 0; i < ch.length; i++) {
      codeUnitToCol.add(col);
    }
  }
  final raw = buffer.toString();
  final trimmedEnd = _trimTrailingSpaceLength(raw);
  if (trimmedEnd == raw.length) {
    return (line: raw, codeUnitToCol: codeUnitToCol);
  }
  return (line: raw.substring(0, trimmedEnd), codeUnitToCol: codeUnitToCol);
}

int _trimTrailingSpaceLength(String text) {
  var end = text.length;
  while (end > 0) {
    final unit = text.codeUnitAt(end - 1);
    if (unit != 0x20 && unit != 0x0D) break;
    end--;
  }
  return end;
}

bool _scanEditorLine({
  required String line,
  required int oneBasedLine,
  required RegExp pattern,
  required int maxMatches,
  required List<TerminalTextMatch> out,
}) {
  List<String>? graphemes;
  List<int>? starts;

  for (final match in pattern.allMatches(line)) {
    if (match.start == match.end) continue;
    if (out.length >= maxMatches) return true;

    graphemes ??= line.characters.toList(growable: false);
    starts ??= _graphemeUtf16Starts(graphemes);
    final snippet = _buildMatchSnippet(
      graphemes: graphemes,
      starts: starts,
      lineLength: line.length,
      matchStart: match.start,
      matchEnd: match.end,
    );
    out.add(
      TerminalTextMatch(
        oneBasedLine: oneBasedLine,
        startCol: match.start,
        endCol: match.end,
        snippet: snippet.text,
        snippetMatchStart: snippet.matchStart,
        snippetMatchEnd: snippet.matchEnd,
        editorLine: oneBasedLine,
        editorColumn: match.start + 1,
        matchLength: match.end - match.start,
      ),
    );
  }
  return false;
}

List<int> _graphemeUtf16Starts(List<String> graphemes) {
  final starts = List<int>.filled(graphemes.length, 0);
  var offset = 0;
  for (var i = 0; i < graphemes.length; i++) {
    starts[i] = offset;
    offset += graphemes[i].length;
  }
  return starts;
}

int _findGraphemeStartIndex(List<int> starts, int utf16Offset) {
  var low = 0;
  var high = starts.length - 1;
  while (low < high) {
    final mid = (low + high + 1) >> 1;
    if (starts[mid] <= utf16Offset) {
      low = mid;
    } else {
      high = mid - 1;
    }
  }
  return low;
}

int _findGraphemeEndIndex(List<int> starts, int lineLength, int utf16Offset) {
  if (utf16Offset >= lineLength) return starts.length;
  var low = 0;
  var high = starts.length;
  while (low < high) {
    final mid = (low + high) >> 1;
    if (starts[mid] < utf16Offset) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  return low;
}

({String text, int matchStart, int matchEnd}) _buildMatchSnippet({
  required List<String> graphemes,
  required List<int> starts,
  required int lineLength,
  required int matchStart,
  required int matchEnd,
}) {
  if (graphemes.isEmpty) {
    return (text: '', matchStart: 0, matchEnd: 0);
  }
  final startG = _findGraphemeStartIndex(starts, matchStart);
  final rawEndG = _findGraphemeEndIndex(starts, lineLength, matchEnd);
  final endG = math.max(startG + 1, rawEndG);

  final windowStart = math.max(0, startG - _snippetContextBefore);
  final clippedEndG = math.min(endG, startG + _snippetMaxMatchGraphemes);
  final windowEnd = math.min(
    graphemes.length,
    clippedEndG + _snippetContextAfter,
  );

  final prefix = windowStart > 0 ? '…' : '';
  final suffix = windowEnd < graphemes.length ? '…' : '';
  final rawBefore = graphemes.sublist(windowStart, startG).join();
  final before = windowStart == 0 ? rawBefore.trimLeft() : rawBefore;
  final matched = graphemes.sublist(startG, clippedEndG).join();
  final after = graphemes.sublist(clippedEndG, windowEnd).join();

  final snippetStart = prefix.length + before.length;
  return (
    text: '$prefix$before$matched$after$suffix',
    matchStart: snippetStart,
    matchEnd: snippetStart + matched.length,
  );
}
