import 'shader_backend.dart';

final RegExp _namedFileDiagnosticPattern = RegExp(
  r'^(.*?)(TerminalShaderFragment|TerminalShaderVertex|[^\s:]+\.glsl):(\d+)(?::(\d+))?:\s*(?:(error|warning|info|note)\s*:\s*)?(.+)$',
  caseSensitive: false,
);

final RegExp _glslangAngleDiagnosticPattern = RegExp(
  r'^\s*(ERROR|WARNING|INFO)\s*:\s*\d+:(\d+)(?::(\d+))?\s*:\s*(.+)$',
  caseSensitive: false,
);

final RegExp _mesaDiagnosticPattern = RegExp(
  r'^\s*\d+:(\d+)\s*(?:\((\d+)\))?\s*:\s*(?:(?:preprocessor\s+)?(error|warning|info|note)\s*:\s*)?(.+)$',
  caseSensitive: false,
);

final RegExp _genericLinePattern = RegExp(
  r'\bline\s+(\d+)\b',
  caseSensitive: false,
);

final RegExp _errorDetailPattern = RegExp(
  r'(?:^|\s)error:\s*(.+)$',
  caseSensitive: false,
);

final RegExp _quotedTokenPattern = RegExp(
  r'''(?:'([^']+)'|`([^`]+)`|"([^"]+)")''',
);

final RegExp _identifierPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
final RegExp _leadingIdentifierPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*');

/// Parses `impellerc` / `glslang` [stderr] output into span-annotated
/// [ShaderDiagnostic] entries mapped to 1-based [userSource] coordinates.
///
/// Subtracts [shimPrefixLineCount] from fragment shader line numbers and clamps
/// out-of-range coordinates into `[1, userLineCount]` when [userSource] is
/// non-empty.
List<ShaderDiagnostic> parseImpellercDiagnostics(
  String stderr, {
  required String userSource,
  int shimPrefixLineCount = 0,
}) {
  final rawLines = _splitLogLines(stderr);
  if (rawLines.isEmpty) return const <ShaderDiagnostic>[];

  final userLines = _splitUserLines(userSource);
  final diagnostics = <ShaderDiagnostic>[];
  for (final rawLine in rawLines) {
    final parsed = _parseImpellercLine(
      rawLine,
      userLines: userLines,
      shimPrefixLineCount: shimPrefixLineCount,
    );
    if (parsed != null) {
      diagnostics.add(parsed);
    }
  }
  if (diagnostics.isNotEmpty) return diagnostics;

  return <ShaderDiagnostic>[
    ShaderDiagnostic(
      severity: ShaderDiagnosticSeverity.error,
      origin: ShaderDiagnosticOrigin.compiler,
      message: _extractFallbackMessage(rawLines),
    ),
  ];
}

/// Parses WebGL2 ANGLE, Mesa, or generic shader/program [infoLog] output into
/// span-annotated [ShaderDiagnostic] entries mapped to 1-based [userSource]
/// coordinates.
///
/// Strips embedded NUL bytes (`\u0000`), subtracts [prefixLineOffset], and
/// clamps out-of-range lines into `[1, userLineCount]` when [userSource] is
/// non-empty.
List<ShaderDiagnostic> parseWebGlDiagnostics(
  String infoLog, {
  required String userSource,
  required int prefixLineOffset,
}) {
  final rawLines = _splitLogLines(infoLog);
  if (rawLines.isEmpty) return const <ShaderDiagnostic>[];

  final userLines = _splitUserLines(userSource);
  final diagnostics = <ShaderDiagnostic>[];
  for (final rawLine in rawLines) {
    final parsed = _parseWebGlLine(
      rawLine,
      userLines: userLines,
      prefixLineOffset: prefixLineOffset,
    );
    if (parsed != null) {
      diagnostics.add(parsed);
    }
  }
  if (diagnostics.isNotEmpty) return diagnostics;

  return <ShaderDiagnostic>[
    ShaderDiagnostic(
      severity: ShaderDiagnosticSeverity.error,
      origin: ShaderDiagnosticOrigin.compiler,
      message: rawLines.first,
    ),
  ];
}

/// Returns the first error-severity diagnostic in [diagnostics], falling back
/// to the first diagnostic if all entries are warnings or info, or `null` when
/// [diagnostics] is empty.
ShaderDiagnostic? firstErrorDiagnostic(List<ShaderDiagnostic> diagnostics) {
  if (diagnostics.isEmpty) return null;
  for (final diagnostic in diagnostics) {
    if (diagnostic.severity == ShaderDiagnosticSeverity.error) {
      return diagnostic;
    }
  }
  return diagnostics.first;
}

/// Resolves a 1-based UTF-16 `(column, length)` span on [lineText] using
/// quoted tokens extracted from compiler [message] and an optional 1-based
/// [explicitColumn].
///
/// Returns `null` when neither [explicitColumn] nor a matching quoted token is
/// present on [lineText].
({int column, int length})? resolveQuotedTokenSpan(
  String lineText,
  String message, {
  int? explicitColumn,
}) {
  final tokens = _extractQuotedTokens(message);
  if (explicitColumn != null && explicitColumn >= 1) {
    return _resolveExplicitColumnSpan(lineText, explicitColumn, tokens);
  }
  if (lineText.isEmpty) return null;
  for (final token in tokens) {
    final offset = _findTokenOffset(lineText, token);
    if (offset >= 0) {
      return (column: offset + 1, length: token.length);
    }
  }
  return null;
}

ShaderDiagnostic? _parseImpellercLine(
  String line, {
  required List<String> userLines,
  required int shimPrefixLineCount,
}) {
  final namedMatch = _namedFileDiagnosticPattern.firstMatch(line);
  if (namedMatch != null) {
    final sourceName = namedMatch.group(2)!.toLowerCase();
    final isVertex =
        sourceName == 'terminalshadervertex' ||
        sourceName.endsWith('vertex.glsl');
    final rawLineNum = int.tryParse(namedMatch.group(3) ?? '');
    if (rawLineNum == null || rawLineNum <= 0) return null;
    final explicitCol = int.tryParse(namedMatch.group(4) ?? '');
    final severity = _parseSeverity(namedMatch.group(5));
    final message = namedMatch.group(6)!.trim();
    if (message.isEmpty) return null;
    return _buildLineDiagnostic(
      severity: severity,
      message: message,
      rawLine: rawLineNum,
      explicitColumn: explicitCol,
      prefixOffset: isVertex ? 0 : shimPrefixLineCount,
      userLines: userLines,
    );
  }

  return _parseGlslangAngleLine(
    line,
    userLines: userLines,
    prefixOffset: shimPrefixLineCount,
  );
}

ShaderDiagnostic? _parseWebGlLine(
  String line, {
  required List<String> userLines,
  required int prefixLineOffset,
}) {
  final angle = _parseGlslangAngleLine(
    line,
    userLines: userLines,
    prefixOffset: prefixLineOffset,
  );
  if (angle != null) return angle;

  final mesaMatch = _mesaDiagnosticPattern.firstMatch(line);
  if (mesaMatch != null) {
    final rawLineNum = int.tryParse(mesaMatch.group(1) ?? '');
    if (rawLineNum == null || rawLineNum <= 0) return null;
    final explicitCol = int.tryParse(mesaMatch.group(2) ?? '');
    final severity = _parseSeverity(mesaMatch.group(3));
    final message = mesaMatch.group(4)!.trim();
    if (message.isEmpty) return null;
    return _buildLineDiagnostic(
      severity: severity,
      message: message,
      rawLine: rawLineNum,
      explicitColumn: explicitCol,
      prefixOffset: prefixLineOffset,
      userLines: userLines,
    );
  }

  final genericMatch = _genericLinePattern.firstMatch(line);
  if (genericMatch == null) return null;
  final rawLineNum = int.tryParse(genericMatch.group(1) ?? '');
  if (rawLineNum == null || rawLineNum <= 0) return null;
  return _buildLineDiagnostic(
    severity: _inferSeverityFromLine(line),
    message: line,
    rawLine: rawLineNum,
    explicitColumn: null,
    prefixOffset: prefixLineOffset,
    userLines: userLines,
  );
}

ShaderDiagnostic? _parseGlslangAngleLine(
  String line, {
  required List<String> userLines,
  required int prefixOffset,
}) {
  final match = _glslangAngleDiagnosticPattern.firstMatch(line);
  if (match == null) return null;
  final rawLineNum = int.tryParse(match.group(2) ?? '');
  if (rawLineNum == null || rawLineNum <= 0) return null;
  final explicitCol = int.tryParse(match.group(3) ?? '');
  final message = match.group(4)!.trim();
  if (message.isEmpty) return null;
  return _buildLineDiagnostic(
    severity: _parseSeverity(match.group(1)),
    message: message,
    rawLine: rawLineNum,
    explicitColumn: explicitCol,
    prefixOffset: prefixOffset,
    userLines: userLines,
  );
}

ShaderDiagnostic _buildLineDiagnostic({
  required ShaderDiagnosticSeverity severity,
  required String message,
  required int rawLine,
  required int? explicitColumn,
  required int prefixOffset,
  required List<String> userLines,
}) {
  final userLine = _adjustUserLine(rawLine, prefixOffset, userLines.length);
  final lineText = userLine >= 1 && userLine <= userLines.length
      ? userLines[userLine - 1]
      : '';
  final span = resolveQuotedTokenSpan(
    lineText,
    message,
    explicitColumn: explicitColumn,
  );
  return ShaderDiagnostic(
    severity: severity,
    origin: ShaderDiagnosticOrigin.compiler,
    message: message,
    line: userLine,
    column: span?.column,
    length: span?.length ?? 1,
  );
}

int _adjustUserLine(int rawLine, int prefixOffset, int userLineCount) {
  final effectiveOffset = prefixOffset > 0 ? prefixOffset : 0;
  final adjusted = rawLine - effectiveOffset;
  if (userLineCount <= 0) {
    return adjusted >= 1 ? adjusted : 1;
  }
  return adjusted.clamp(1, userLineCount);
}

({int column, int length}) _resolveExplicitColumnSpan(
  String lineText,
  int explicitColumn,
  List<String> tokens,
) {
  if (lineText.isEmpty) {
    return (column: 1, length: 1);
  }
  final clampedCol = explicitColumn.clamp(1, lineText.length);
  final offset = clampedCol - 1;
  for (final token in tokens) {
    if (lineText.startsWith(token, offset)) {
      return (column: clampedCol, length: token.length);
    }
  }
  final idMatch = _leadingIdentifierPattern.firstMatch(
    lineText.substring(offset),
  );
  final length = idMatch != null ? idMatch.group(0)!.length : 1;
  return (column: clampedCol, length: length);
}

List<String> _extractQuotedTokens(String message) {
  final tokens = <String>[];
  for (final match in _quotedTokenPattern.allMatches(message)) {
    final raw = match.group(1) ?? match.group(2) ?? match.group(3);
    if (raw != null && raw.trim().isNotEmpty) {
      tokens.add(raw);
    }
  }
  return tokens;
}

int _findTokenOffset(String lineText, String token) {
  if (_identifierPattern.hasMatch(token)) {
    final wordPattern = RegExp(
      '(?<![A-Za-z0-9_])${RegExp.escape(token)}(?![A-Za-z0-9_])',
    );
    final match = wordPattern.firstMatch(lineText);
    if (match != null) return match.start;
  }
  return lineText.indexOf(token);
}

ShaderDiagnosticSeverity _parseSeverity(String? raw) =>
    switch (raw?.toLowerCase()) {
      'warning' => ShaderDiagnosticSeverity.warning,
      'info' || 'note' => ShaderDiagnosticSeverity.info,
      _ => ShaderDiagnosticSeverity.error,
    };

ShaderDiagnosticSeverity _inferSeverityFromLine(String line) {
  final lower = line.toLowerCase();
  if (lower.contains('warning')) return ShaderDiagnosticSeverity.warning;
  if (lower.contains('info') || lower.contains('note')) {
    return ShaderDiagnosticSeverity.info;
  }
  return ShaderDiagnosticSeverity.error;
}

String _extractFallbackMessage(List<String> lines) {
  for (final line in lines) {
    final match = _errorDetailPattern.firstMatch(line);
    final detail = match?.group(1)?.trim();
    if (detail != null && detail.isNotEmpty) {
      return detail;
    }
  }
  return lines.first;
}

List<String> _splitLogLines(String rawLog) {
  final normalized = rawLog
      .replaceAll('\u0000', '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  return <String>[
    for (final line in normalized.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];
}

List<String> _splitUserLines(String userSource) {
  if (userSource.isEmpty) return const <String>[];
  final normalized = userSource.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final lines = normalized.split('\n');
  if (lines.length > 1 && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines;
}
