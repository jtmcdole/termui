import 'package:termui/termui.dart' as tui;

import 'automation_models.dart';

/// Extracts a plain-text [AutomationScreenSnapshot] from a visible [tui.Buffer].
///
/// Inspects `buffer.characters[rowOffset + col]` directly, skipping empty
/// trailing wide-glyph continuation cells (`ch.isEmpty`) and trimming trailing
/// whitespace from each line while preserving [tui.Buffer.width] and
/// [tui.Buffer.height].
AutomationScreenSnapshot extractScreenSnapshot(
  tui.Buffer buffer, {
  required String paneId,
  required int cursorCol,
  required int cursorRow,
  required bool cursorVisible,
}) {
  final cols = buffer.width;
  final rows = buffer.height;
  if (cols <= 0 || rows <= 0) {
    return AutomationScreenSnapshot(
      paneId: paneId,
      cols: cols,
      rows: rows,
      cursorCol: cursorCol,
      cursorRow: cursorRow,
      cursorVisible: cursorVisible,
      lines: const [],
    );
  }

  final chars = buffer.characters;
  final lines = <String>[
    for (var row = 0; row < rows; row++)
      _extractRowText(chars, row * cols, cols).trimRight(),
  ];
  return AutomationScreenSnapshot(
    paneId: paneId,
    cols: cols,
    rows: rows,
    cursorCol: cursorCol,
    cursorRow: cursorRow,
    cursorVisible: cursorVisible,
    lines: lines,
  );
}

/// Scans visible rows of [buffer] for literal [text] or [regex] matches and
/// returns exact cell coordinates and normalized `[0..1]` center points.
///
/// Throws [FormatException] when neither or both of [text] and [regex] are
/// supplied, when the pattern is empty, or when [regex] fails to compile.
List<AutomationScreenMatch> findInScreenBuffer(
  tui.Buffer buffer, {
  String? text,
  String? regex,
  bool caseSensitive = true,
}) {
  final pattern = _compileSearchPattern(
    text: text,
    regex: regex,
    caseSensitive: caseSensitive,
  );
  final cols = buffer.width;
  final rows = buffer.height;
  if (cols <= 0 || rows <= 0) return const [];

  final chars = buffer.characters;
  final matches = <AutomationScreenMatch>[];
  for (var row = 0; row < rows; row++) {
    _collectRowMatches(
      chars: chars,
      row: row,
      cols: cols,
      rows: rows,
      pattern: pattern,
      out: matches,
    );
  }
  return matches;
}

RegExp _compileSearchPattern({
  required String? text,
  required String? regex,
  required bool caseSensitive,
}) {
  final hasText = text != null;
  final hasRegex = regex != null;
  if (hasText == hasRegex) {
    throw const FormatException(
      'Exactly one of "text" or "regex" must be provided.',
    );
  }
  if (text != null) {
    if (text.isEmpty) {
      throw const FormatException('Field "text" must not be empty.');
    }
    return RegExp(RegExp.escape(text), caseSensitive: caseSensitive);
  }
  final source = regex!;
  if (source.isEmpty) {
    throw const FormatException('Field "regex" must not be empty.');
  }
  return RegExp(source, caseSensitive: caseSensitive);
}

String _extractRowText(List<String> chars, int rowOffset, int cols) {
  final buffer = StringBuffer();
  for (var col = 0; col < cols; col++) {
    final ch = chars[rowOffset + col];
    if (ch.isNotEmpty) {
      buffer.write(ch);
    }
  }
  return buffer.toString();
}

void _collectRowMatches({
  required List<String> chars,
  required int row,
  required int cols,
  required int rows,
  required RegExp pattern,
  required List<AutomationScreenMatch> out,
}) {
  final rowOffset = row * cols;
  final rowText = StringBuffer();
  final codeUnitToCol = <int>[];
  for (var col = 0; col < cols; col++) {
    final ch = chars[rowOffset + col];
    if (ch.isEmpty) continue;
    rowText.write(ch);
    for (var i = 0; i < ch.length; i++) {
      codeUnitToCol.add(col);
    }
  }

  final line = rowText.toString();
  if (line.isEmpty) return;

  final y = (row + 0.5) / rows;
  for (final match in pattern.allMatches(line)) {
    if (match.start == match.end) continue;
    final startCol = codeUnitToCol[match.start];
    var endCol = codeUnitToCol[match.end - 1] + 1;
    while (endCol < cols && chars[rowOffset + endCol].isEmpty) {
      endCol++;
    }
    out.add(
      AutomationScreenMatch(
        row: row,
        col: startCol,
        endCol: endCol,
        text: match.group(0) ?? '',
        x: (startCol + endCol) / (2 * cols),
        y: y,
      ),
    );
  }
}
