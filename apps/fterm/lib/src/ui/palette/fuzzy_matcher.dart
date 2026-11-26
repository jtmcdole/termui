import 'dart:math' as math;

import 'package:flutter/widgets.dart' show StringCharacters;

/// Scored subsequence match result with grapheme-cluster indices into the
/// matched candidate string.
typedef FuzzyMatchResult = ({int score, List<int> matchedIndices});

const int _baseMatchBonus = 10;
const int _prefixBonus = 24;
const int _wordBoundaryBonus = 18;
const int _camelCaseBonus = 14;
const int _consecutiveBonus = 16;
const int _maxStreakSteps = 6;
const int _streakStepBonus = 2;
const int _exactCaseBonus = 1;
const int _maxGapPenalty = 6;
const int _maxStartOffsetPenalty = 12;
const int _maxLengthPenalty = 40;
const int _maxDpCells = 4096;
const int _negInf = -1 << 29;

const int _titleMatchBoost = 20;
const int _categoryTitleBoost = 10;
const int _keywordOnlyPenalty = 15;
const int _combinedKeywordPenalty = 20;

/// Performs case-insensitive subsequence fuzzy matching of [query] against
/// [candidate], scoring prefix matches, word boundaries (`:`, ` `, `_`, `-`,
/// `/`), camelCase transitions, consecutive streaks, and shorter candidates.
///
/// Returns `null` when [query] is not a subsequence of [candidate].
FuzzyMatchResult? fuzzyMatch(String query, String candidate) {
  final trimmed = query.trim();
  if (trimmed.isEmpty) {
    return (score: 0, matchedIndices: const <int>[]);
  }
  if (candidate.isEmpty) return null;

  final queryChars = trimmed.characters.toList(growable: false);
  final candChars = candidate.characters.toList(growable: false);
  if (queryChars.length > candChars.length) return null;

  final queryLower = <String>[for (final ch in queryChars) ch.toLowerCase()];
  final candLower = <String>[for (final ch in candChars) ch.toLowerCase()];
  if (!_isSubsequence(queryLower, candLower)) return null;

  final posBonuses = _computePositionBonuses(candChars);
  if (queryChars.length * candChars.length > _maxDpCells) {
    return _greedyFallbackMatch(
      queryChars: queryChars,
      queryLower: queryLower,
      candChars: candChars,
      candLower: candLower,
      posBonuses: posBonuses,
    );
  }
  return _dpOptimalMatch(
    queryChars: queryChars,
    queryLower: queryLower,
    candChars: candChars,
    candLower: candLower,
    posBonuses: posBonuses,
  );
}

/// Scores a palette entry across [title], optional [category], and [keywords],
/// always returning `matchedIndices` mapped into [title].
FuzzyMatchResult? matchPaletteEntry(
  String query, {
  required String title,
  String? category,
  String keywords = '',
}) {
  final trimmed = query.trim();
  if (trimmed.isEmpty) {
    return (score: 0, matchedIndices: const <int>[]);
  }

  FuzzyMatchResult? best;
  final titleMatch = fuzzyMatch(trimmed, title);
  if (titleMatch != null) {
    best = (
      score: titleMatch.score + _titleMatchBoost,
      matchedIndices: titleMatch.matchedIndices,
    );
  }

  final hasCategory = category != null && category.isNotEmpty;
  if (hasCategory) {
    final prefix = '$category: ';
    final combinedMatch = fuzzyMatch(trimmed, '$prefix$title');
    if (combinedMatch != null) {
      final candidateScore = combinedMatch.score + _categoryTitleBoost;
      if (best == null || candidateScore > best.score) {
        best = (
          score: candidateScore,
          matchedIndices: _shiftIndicesForTitle(
            combinedMatch.matchedIndices,
            prefixLen: prefix.characters.length,
            titleLen: title.characters.length,
          ),
        );
      }
    }
  }
  if (best != null) return best;

  return _matchEntryKeywords(
    trimmed,
    title: title,
    category: category,
    keywords: keywords,
  );
}

FuzzyMatchResult? _matchEntryKeywords(
  String query, {
  required String title,
  required String? category,
  required String keywords,
}) {
  if (keywords.isEmpty) return null;
  final keywordMatch = fuzzyMatch(query, keywords);
  if (keywordMatch != null) {
    return (
      score: keywordMatch.score - _keywordOnlyPenalty,
      matchedIndices: const <int>[],
    );
  }
  final prefix = category != null && category.isNotEmpty ? '$category ' : '';
  final fullText = '$prefix$title $keywords';
  final fullMatch = fuzzyMatch(query, fullText);
  if (fullMatch == null) return null;
  return (
    score: fullMatch.score - _combinedKeywordPenalty,
    matchedIndices: _shiftIndicesForTitle(
      fullMatch.matchedIndices,
      prefixLen: prefix.characters.length,
      titleLen: title.characters.length,
    ),
  );
}

List<int> _shiftIndicesForTitle(
  List<int> indices, {
  required int prefixLen,
  required int titleLen,
}) {
  final end = prefixLen + titleLen;
  return <int>[
    for (final idx in indices)
      if (idx >= prefixLen && idx < end) idx - prefixLen,
  ];
}

bool _isSubsequence(List<String> queryLower, List<String> candLower) {
  var qi = 0;
  for (var ci = 0; ci < candLower.length && qi < queryLower.length; ci++) {
    if (candLower[ci] == queryLower[qi]) {
      qi++;
    }
  }
  return qi == queryLower.length;
}

List<int> _computePositionBonuses(List<String> candChars) {
  final bonuses = List<int>.filled(candChars.length, 0);
  if (candChars.isEmpty) return bonuses;
  bonuses[0] = _prefixBonus;
  for (var i = 1; i < candChars.length; i++) {
    final prev = candChars[i - 1];
    final curr = candChars[i];
    if (_isWordSeparator(prev)) {
      bonuses[i] = _wordBoundaryBonus;
    } else if (_isCamelBoundary(prev, curr)) {
      bonuses[i] = _camelCaseBonus;
    }
  }
  return bonuses;
}

bool _isWordSeparator(String ch) => switch (ch) {
  ':' || ' ' || '_' || '-' || '/' || '.' => true,
  _ => false,
};

bool _isCamelBoundary(String prev, String curr) {
  if (prev.length != 1 || curr.length != 1) return false;
  final prevCode = prev.codeUnitAt(0);
  final currCode = curr.codeUnitAt(0);
  final prevLower = prevCode >= 0x61 && prevCode <= 0x7A;
  final currUpper = currCode >= 0x41 && currCode <= 0x5A;
  return prevLower && currUpper;
}

int _lengthPenalty(int candLen, int queryLen) =>
    math.min((candLen - queryLen) ~/ 2, _maxLengthPenalty);

FuzzyMatchResult _dpOptimalMatch({
  required List<String> queryChars,
  required List<String> queryLower,
  required List<String> candChars,
  required List<String> candLower,
  required List<int> posBonuses,
}) {
  final qLen = queryChars.length;
  final cLen = candChars.length;
  final dp = List<int>.filled(qLen * cLen, _negInf);
  final streak = List<int>.filled(qLen * cLen, 0);
  final parent = List<int>.filled(qLen * cLen, -1);

  _fillFirstQueryRow(
    dp: dp,
    queryChar: queryChars[0],
    queryLow: queryLower[0],
    candChars: candChars,
    candLower: candLower,
    posBonuses: posBonuses,
  );

  for (var qi = 1; qi < qLen; qi++) {
    _fillNextQueryRow(
      qi: qi,
      cLen: cLen,
      dp: dp,
      streak: streak,
      parent: parent,
      queryChar: queryChars[qi],
      queryLow: queryLower[qi],
      candChars: candChars,
      candLower: candLower,
      posBonuses: posBonuses,
    );
  }

  final lastRowOffset = (qLen - 1) * cLen;
  var bestCol = -1;
  var bestScore = _negInf;
  for (var ci = 0; ci < cLen; ci++) {
    final candidateScore = dp[lastRowOffset + ci];
    if (candidateScore > bestScore) {
      bestScore = candidateScore;
      bestCol = ci;
    }
  }
  final indices = _backtrackIndices(
    parent: parent,
    qLen: qLen,
    cLen: cLen,
    endCol: bestCol,
  );
  return (
    score: bestScore - _lengthPenalty(cLen, qLen),
    matchedIndices: indices,
  );
}

void _fillFirstQueryRow({
  required List<int> dp,
  required String queryChar,
  required String queryLow,
  required List<String> candChars,
  required List<String> candLower,
  required List<int> posBonuses,
}) {
  for (var ci = 0; ci < candLower.length; ci++) {
    if (candLower[ci] != queryLow) continue;
    final exactBonus = candChars[ci] == queryChar ? _exactCaseBonus : 0;
    final startPenalty = math.min(ci, _maxStartOffsetPenalty) ~/ 2;
    dp[ci] = _baseMatchBonus + posBonuses[ci] + exactBonus - startPenalty;
  }
}

void _fillNextQueryRow({
  required int qi,
  required int cLen,
  required List<int> dp,
  required List<int> streak,
  required List<int> parent,
  required String queryChar,
  required String queryLow,
  required List<String> candChars,
  required List<String> candLower,
  required List<int> posBonuses,
}) {
  final prevRow = (qi - 1) * cLen;
  final currRow = qi * cLen;
  var bestPrevScore = _negInf;
  var bestPrevCol = -1;

  for (var ci = qi; ci < cLen; ci++) {
    final prevCol = ci - 1;
    final prevVal = dp[prevRow + prevCol];
    if (prevVal > bestPrevScore) {
      bestPrevScore = prevVal;
      bestPrevCol = prevCol;
    }
    if (candLower[ci] != queryLow || bestPrevCol < 0) continue;

    final exactBonus = candChars[ci] == queryChar ? _exactCaseBonus : 0;
    final cellBonus = _baseMatchBonus + posBonuses[ci] + exactBonus;
    final gap = ci - bestPrevCol - 1;
    var bestScore =
        bestPrevScore + cellBonus - math.min<int>(gap, _maxGapPenalty);
    var bestParent = bestPrevCol;
    var bestStreak = 0;

    if (prevVal > _negInf) {
      final nextStreak = streak[prevRow + prevCol] + 1;
      final streakReward =
          _consecutiveBonus +
          math.min<int>(nextStreak - 1, _maxStreakSteps) * _streakStepBonus;
      final consecScore = prevVal + cellBonus + streakReward;
      if (consecScore >= bestScore) {
        bestScore = consecScore;
        bestParent = prevCol;
        bestStreak = nextStreak;
      }
    }

    dp[currRow + ci] = bestScore;
    parent[currRow + ci] = bestParent;
    streak[currRow + ci] = bestStreak;
  }
}

List<int> _backtrackIndices({
  required List<int> parent,
  required int qLen,
  required int cLen,
  required int endCol,
}) {
  final result = List<int>.filled(qLen, 0);
  var col = endCol;
  for (var qi = qLen - 1; qi >= 0; qi--) {
    result[qi] = col;
    col = parent[qi * cLen + col];
  }
  return result;
}

FuzzyMatchResult _greedyFallbackMatch({
  required List<String> queryChars,
  required List<String> queryLower,
  required List<String> candChars,
  required List<String> candLower,
  required List<int> posBonuses,
}) {
  final indices = <int>[];
  var score = 0;
  var qi = 0;
  var prevCi = -1;
  var currentStreak = 0;

  for (var ci = 0; ci < candLower.length && qi < queryLower.length; ci++) {
    if (candLower[ci] != queryLower[qi]) continue;
    indices.add(ci);
    final exactBonus = candChars[ci] == queryChars[qi] ? _exactCaseBonus : 0;
    score += _baseMatchBonus + posBonuses[ci] + exactBonus;
    if (prevCi < 0) {
      score -= math.min(ci, _maxStartOffsetPenalty) ~/ 2;
    } else if (ci == prevCi + 1) {
      currentStreak++;
      score +=
          _consecutiveBonus +
          math.min(currentStreak - 1, _maxStreakSteps) * _streakStepBonus;
    } else {
      currentStreak = 0;
      score -= math.min<int>(ci - prevCi - 1, _maxGapPenalty);
    }
    prevCi = ci;
    qi++;
  }
  return (
    score: score - _lengthPenalty(candChars.length, queryChars.length),
    matchedIndices: indices,
  );
}
