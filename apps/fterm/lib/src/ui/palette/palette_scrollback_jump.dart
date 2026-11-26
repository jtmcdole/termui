import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:termui/termui.dart' as tui;

import '../../shader_editor/shader_editor_controller.dart';
import '../../workspace/fterm_pane_controller.dart';
import 'fuzzy_matcher.dart';

const int _maxPreviewGraphemes = 120;

/// Status hint returned when `:` scrollback jump is invoked on an alternate
/// screen application (such as `vim` or `htop`).
const String altScreenScrollbackJumpHint =
    'Scrollback jump is unavailable in alternate screen.';

/// Immutable jump target candidate surfaced by `:` scrollback and editor line
/// jump mode.
final class ScrollbackJumpCandidate {
  /// Stable identifier for list keys and selection tracking.
  final String id;

  /// Primary display label (landmark name, prompt text, or jump action).
  final String title;

  /// Optional secondary line number or source preview caption.
  final String? subtitle;

  /// Target monotonic virtual row for terminal panes (`null` for editor targets).
  final int? targetVirtualRow;

  /// Target 1-based line number for `ShaderEditorController` (`null` for
  /// terminal targets).
  final int? editorLine;

  /// Whether this entry represents a structural landmark (`Top` / `Bottom`).
  final bool isLandmark;

  /// Matched grapheme-cluster indices into [title] from fuzzy filtering.
  final List<int> matchedIndices;

  /// Creates an immutable [ScrollbackJumpCandidate].
  const ScrollbackJumpCandidate({
    required this.id,
    required this.title,
    this.subtitle,
    this.targetVirtualRow,
    this.editorLine,
    this.isLandmark = false,
    this.matchedIndices = const <int>[],
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScrollbackJumpCandidate &&
          other.id == id &&
          other.title == title &&
          other.subtitle == subtitle &&
          other.targetVirtualRow == targetVirtualRow &&
          other.editorLine == editorLine &&
          other.isLandmark == isLandmark &&
          listEquals(other.matchedIndices, matchedIndices);

  @override
  int get hashCode => Object.hash(
    id,
    title,
    subtitle,
    targetVirtualRow,
    editorLine,
    isLandmark,
    Object.hashAll(matchedIndices),
  );

  @override
  String toString() =>
      'ScrollbackJumpCandidate(id: $id, title: $title, '
      'targetVirtualRow: $targetVirtualRow, editorLine: $editorLine, '
      'isLandmark: $isLandmark)';
}

/// Evaluation output for `:` scrollback or shader-editor jump queries.
final class ScrollbackJumpResult {
  /// Ordered jump candidates to display in the palette list.
  final List<ScrollbackJumpCandidate> candidates;

  /// Optional informational or error status hint shown above/instead of items.
  final String? statusHint;

  /// Direct target resolved from a numeric, percentage, or keyword expression
  /// (`null` when browsing or fuzzy-filtering landmarks/prompts).
  final ScrollbackJumpCandidate? directTarget;

  /// Creates an immutable [ScrollbackJumpResult].
  const ScrollbackJumpResult({
    required this.candidates,
    this.statusHint,
    this.directTarget,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScrollbackJumpResult &&
          listEquals(other.candidates, candidates) &&
          other.statusHint == statusHint &&
          other.directTarget == directTarget;

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(candidates), statusHint, directTarget);

  @override
  String toString() =>
      'ScrollbackJumpResult(candidates: ${candidates.length}, '
      'statusHint: $statusHint, directTarget: $directTarget)';
}

sealed class _JumpExpression {
  const _JumpExpression();
}

final class _AbsoluteLineExpression extends _JumpExpression {
  final int lineNumber;
  const _AbsoluteLineExpression(this.lineNumber);
}

final class _RelativeFromBottomExpression extends _JumpExpression {
  final int linesFromBottom;
  const _RelativeFromBottomExpression(this.linesFromBottom);
}

final class _PercentExpression extends _JumpExpression {
  final double percent;
  const _PercentExpression(this.percent);
}

final class _TopLandmarkExpression extends _JumpExpression {
  const _TopLandmarkExpression();
}

final class _BottomLandmarkExpression extends _JumpExpression {
  const _BottomLandmarkExpression();
}

final RegExp _positiveIntPattern = RegExp(r'^\+?(\d+)$');
final RegExp _negativeIntPattern = RegExp(r'^-(\d+)$');
final RegExp _percentPattern = RegExp(r'^([+-]?\d+(?:\.\d+)?)%$');

/// Resolves a `:` scrollback jump [query] against [pane].
///
/// Supports positive 1-based line numbers (`1..N` relative to
/// [FtermPaneController.oldestVirtualRow]), negative offsets from live bottom
/// (`-N`), percentages (`0%..100%`), keywords (`top`, `bottom`, `0`), and
/// fuzzy-filtered landmarks plus reverse-chronological OSC 133;A prompts.
ScrollbackJumpResult resolveTerminalScrollbackJump(
  FtermPaneController pane,
  String query,
) {
  if (pane.port.modes.altScreen) {
    return const ScrollbackJumpResult(
      candidates: <ScrollbackJumpCandidate>[],
      statusHint: altScreenScrollbackJumpHint,
    );
  }

  final oldestRow = pane.oldestVirtualRow;
  final totalLines = pane.totalVirtualLines;
  final lineCount = totalLines - oldestRow;
  if (lineCount <= 0) {
    return const ScrollbackJumpResult(
      candidates: <ScrollbackJumpCandidate>[],
      statusHint: 'No scrollback lines available.',
    );
  }

  final trimmed = query.trim();
  if (trimmed.isNotEmpty) {
    final expr = _parseJumpExpression(trimmed);
    if (expr != null) {
      return _resolveTerminalExpression(
        pane: pane,
        expression: expr,
        oldestRow: oldestRow,
        totalLines: totalLines,
      );
    }
  }

  return _buildTerminalBrowseResult(
    pane: pane,
    query: trimmed,
    oldestRow: oldestRow,
    totalLines: totalLines,
  );
}

/// Resolves a `:` line jump [query] against a GLSL [ShaderEditorController].
///
/// Supports `:1..lineCount`, `:-N`, `:N%`, `:top`, `:bottom`, and `:0`,
/// returning 1-based [ScrollbackJumpCandidate.editorLine] targets with trimmed
/// source line previews.
ScrollbackJumpResult resolveShaderEditorJump(
  ShaderEditorController controller,
  String query,
) {
  final lines = controller.textController.value.lines;
  final lineCount = controller.lineCount;
  if (lineCount <= 0 || lines.isEmpty) {
    return const ScrollbackJumpResult(
      candidates: <ScrollbackJumpCandidate>[],
      statusHint: 'Editor buffer is empty.',
    );
  }

  final trimmed = query.trim();
  if (trimmed.isNotEmpty) {
    final expr = _parseJumpExpression(trimmed);
    if (expr != null) {
      return _resolveEditorExpression(
        lines: lines,
        lineCount: lineCount,
        expression: expr,
      );
    }
  }

  return _buildEditorBrowseResult(
    lines: lines,
    lineCount: lineCount,
    query: trimmed,
  );
}

_JumpExpression? _parseJumpExpression(String trimmed) {
  final lower = trimmed.toLowerCase();
  if (lower == 'top') return const _TopLandmarkExpression();
  if (lower == 'bottom') return const _BottomLandmarkExpression();

  if (_percentPattern.firstMatch(trimmed) case final pctMatch?) {
    final parsed = double.tryParse(pctMatch.group(1)!);
    if (parsed != null) return _PercentExpression(parsed);
  }

  if (_negativeIntPattern.firstMatch(trimmed) case final negMatch?) {
    final parsed = int.tryParse(negMatch.group(1)!);
    if (parsed != null) return _RelativeFromBottomExpression(parsed);
  }

  if (_positiveIntPattern.firstMatch(trimmed) case final posMatch?) {
    final parsed = int.tryParse(posMatch.group(1)!);
    if (parsed == null) return null;
    return parsed == 0
        ? const _TopLandmarkExpression()
        : _AbsoluteLineExpression(parsed);
  }

  return null;
}

ScrollbackJumpResult _resolveTerminalExpression({
  required FtermPaneController pane,
  required _JumpExpression expression,
  required int oldestRow,
  required int totalLines,
}) {
  final maxRow = totalLines - 1;
  final lineCount = totalLines - oldestRow;
  final targetRow = switch (expression) {
    _AbsoluteLineExpression(:final lineNumber) =>
      (oldestRow + (lineNumber - 1)).clamp(oldestRow, maxRow),
    _RelativeFromBottomExpression(:final linesFromBottom) =>
      (totalLines - linesFromBottom).clamp(oldestRow, maxRow),
    _PercentExpression(:final percent) =>
      oldestRow +
          ((maxRow - oldestRow) * (percent.clamp(0, 100) / 100)).round(),
    _TopLandmarkExpression() => oldestRow,
    _BottomLandmarkExpression() => maxRow,
  };

  final oneBased = targetRow - oldestRow + 1;
  final preview = _extractTrimmedRowText(pane.lookupVirtualLine(targetRow));
  final isLandmark =
      expression is _TopLandmarkExpression ||
      expression is _BottomLandmarkExpression;
  final title = switch (expression) {
    _TopLandmarkExpression() => 'Top of Scrollback',
    _BottomLandmarkExpression() => 'Live Bottom',
    _ => 'Go to line $oneBased',
  };
  final subtitle = preview.isEmpty
      ? 'Line $oneBased of $lineCount'
      : 'Line $oneBased of $lineCount · $preview';
  final target = ScrollbackJumpCandidate(
    id: 'jump-row-$targetRow',
    title: title,
    subtitle: subtitle,
    targetVirtualRow: targetRow,
    isLandmark: isLandmark,
  );
  return ScrollbackJumpResult(
    candidates: List<ScrollbackJumpCandidate>.unmodifiable(
      <ScrollbackJumpCandidate>[target],
    ),
    statusHint: 'Jumping to line $oneBased of $lineCount',
    directTarget: target,
  );
}

ScrollbackJumpResult _buildTerminalBrowseResult({
  required FtermPaneController pane,
  required String query,
  required int oldestRow,
  required int totalLines,
}) {
  final maxRow = totalLines - 1;
  final lineCount = totalLines - oldestRow;
  final baseCandidates = <ScrollbackJumpCandidate>[
    ScrollbackJumpCandidate(
      id: 'landmark-bottom',
      title: 'Live Bottom',
      subtitle: 'Line $lineCount of $lineCount',
      targetVirtualRow: maxRow,
      isLandmark: true,
    ),
    ScrollbackJumpCandidate(
      id: 'landmark-top',
      title: 'Top of Scrollback',
      subtitle: 'Line 1 of $lineCount',
      targetVirtualRow: oldestRow,
      isLandmark: true,
    ),
    for (final row in pane.promptLines.reversed)
      _buildPromptCandidate(
        pane: pane,
        virtualRow: row,
        oldestRow: oldestRow,
        lineCount: lineCount,
      ),
  ];

  if (query.isEmpty) {
    return ScrollbackJumpResult(
      candidates: List<ScrollbackJumpCandidate>.unmodifiable(baseCandidates),
      statusHint:
          'Enter line (1..$lineCount), -N, N%, top, bottom, or filter prompts',
    );
  }

  final filtered = _fuzzyFilterCandidates(query, baseCandidates);
  return ScrollbackJumpResult(
    candidates: filtered,
    statusHint: filtered.isEmpty
        ? 'No matching landmarks or prompts for "$query".'
        : null,
  );
}

ScrollbackJumpCandidate _buildPromptCandidate({
  required FtermPaneController pane,
  required int virtualRow,
  required int oldestRow,
  required int lineCount,
}) {
  final oneBased = virtualRow - oldestRow + 1;
  final text = _extractTrimmedRowText(pane.lookupVirtualLine(virtualRow));
  final title = text.isEmpty ? 'Prompt at line $oneBased' : text;
  return ScrollbackJumpCandidate(
    id: 'prompt-row-$virtualRow',
    title: title,
    subtitle: 'Prompt · Line $oneBased of $lineCount',
    targetVirtualRow: virtualRow,
  );
}

ScrollbackJumpResult _resolveEditorExpression({
  required List<String> lines,
  required int lineCount,
  required _JumpExpression expression,
}) {
  final targetLine = switch (expression) {
    _AbsoluteLineExpression(:final lineNumber) => lineNumber.clamp(
      1,
      lineCount,
    ),
    _RelativeFromBottomExpression(:final linesFromBottom) =>
      (lineCount - linesFromBottom + 1).clamp(1, lineCount),
    _PercentExpression(:final percent) =>
      1 + ((lineCount - 1) * (percent.clamp(0, 100) / 100)).round(),
    _TopLandmarkExpression() => 1,
    _BottomLandmarkExpression() => lineCount,
  };

  final preview = _trimmedEditorLinePreview(lines, targetLine);
  final isLandmark =
      expression is _TopLandmarkExpression ||
      expression is _BottomLandmarkExpression;
  final title = switch (expression) {
    _TopLandmarkExpression() => 'Top of File',
    _BottomLandmarkExpression() => 'Bottom of File',
    _ => 'Go to line $targetLine',
  };
  final subtitle = preview.isEmpty
      ? 'Line $targetLine of $lineCount (empty)'
      : preview;
  final target = ScrollbackJumpCandidate(
    id: 'editor-line-$targetLine',
    title: title,
    subtitle: subtitle,
    editorLine: targetLine,
    isLandmark: isLandmark,
  );
  return ScrollbackJumpResult(
    candidates: List<ScrollbackJumpCandidate>.unmodifiable(
      <ScrollbackJumpCandidate>[target],
    ),
    statusHint: 'Jumping to line $targetLine of $lineCount',
    directTarget: target,
  );
}

ScrollbackJumpResult _buildEditorBrowseResult({
  required List<String> lines,
  required int lineCount,
  required String query,
}) {
  final topPreview = _trimmedEditorLinePreview(lines, 1);
  final bottomPreview = _trimmedEditorLinePreview(lines, lineCount);
  final landmarks = <ScrollbackJumpCandidate>[
    ScrollbackJumpCandidate(
      id: 'editor-landmark-top',
      title: 'Top of File',
      subtitle: topPreview.isEmpty ? 'Line 1 of $lineCount' : topPreview,
      editorLine: 1,
      isLandmark: true,
    ),
    ScrollbackJumpCandidate(
      id: 'editor-landmark-bottom',
      title: 'Bottom of File',
      subtitle: bottomPreview.isEmpty
          ? 'Line $lineCount of $lineCount'
          : bottomPreview,
      editorLine: lineCount,
      isLandmark: true,
    ),
  ];

  if (query.isEmpty) {
    return ScrollbackJumpResult(
      candidates: List<ScrollbackJumpCandidate>.unmodifiable(landmarks),
      statusHint: 'Enter line (1..$lineCount), -N, N%, top, or bottom',
    );
  }

  final filtered = _fuzzyFilterCandidates(query, landmarks);
  return ScrollbackJumpResult(
    candidates: filtered,
    statusHint: filtered.isEmpty
        ? 'Enter line (1..$lineCount), -N, N%, top, or bottom'
        : null,
  );
}

List<ScrollbackJumpCandidate> _fuzzyFilterCandidates(
  String query,
  List<ScrollbackJumpCandidate> candidates,
) {
  final scored = <({int score, int order, ScrollbackJumpCandidate item})>[];
  for (var i = 0; i < candidates.length; i++) {
    final candidate = candidates[i];
    final match = matchPaletteEntry(
      query,
      title: candidate.title,
      keywords: candidate.subtitle ?? '',
    );
    if (match == null) continue;
    scored.add((
      score: match.score,
      order: i,
      item: ScrollbackJumpCandidate(
        id: candidate.id,
        title: candidate.title,
        subtitle: candidate.subtitle,
        targetVirtualRow: candidate.targetVirtualRow,
        editorLine: candidate.editorLine,
        isLandmark: candidate.isLandmark,
        matchedIndices: List<int>.unmodifiable(match.matchedIndices),
      ),
    ));
  }
  scored.sort((a, b) {
    final scoreDiff = b.score.compareTo(a.score);
    return scoreDiff != 0 ? scoreDiff : a.order.compareTo(b.order);
  });
  return List<ScrollbackJumpCandidate>.unmodifiable(<ScrollbackJumpCandidate>[
    for (final entry in scored) entry.item,
  ]);
}

String _extractTrimmedRowText(tui.VirtualLineSlice? slice) {
  if (slice == null || slice.characters.isEmpty) return '';
  final buffer = StringBuffer();
  for (final ch in slice.characters) {
    if (ch.isNotEmpty) {
      buffer.write(ch);
    }
  }
  return _truncateGraphemes(buffer.toString().trim());
}

String _trimmedEditorLinePreview(List<String> lines, int oneBasedLine) {
  final idx = (oneBasedLine - 1).clamp(0, lines.length - 1);
  final raw = lines[idx];
  final stripped = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
  return _truncateGraphemes(stripped.trim());
}

String _truncateGraphemes(String text) {
  final chars = text.characters;
  if (chars.length <= _maxPreviewGraphemes) return text;
  return '${chars.take(_maxPreviewGraphemes - 1).string}…';
}
