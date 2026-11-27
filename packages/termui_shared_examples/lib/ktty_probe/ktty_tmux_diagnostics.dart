import 'ktty_probe_report.dart';

export 'ktty_tmux_diagnostics_stub.dart'
    if (dart.library.io) 'ktty_tmux_diagnostics_io.dart';

/// Remediation hint emitted when `tmux` `allow-passthrough` is disabled or unknown.
const String kttyTmuxPassthroughHint =
    'Run: tmux set -gp allow-passthrough on (or all)';

/// Remediation hint emitted when `tmux` does not advertise `RGB` or `Tc` truecolor.
const String kttyTmuxTrueColorHint =
    'Run: tmux set -as terminal-features ",xterm-256color:RGB"';

/// Remediation hint emitted when running inside GNU `screen`.
const String kttyScreenPassthroughHint =
    'GNU screen requires DCS passthrough; Kitty graphics may be stripped.';

final RegExp _whitespacePattern = RegExp(r'\s+');
final RegExp _trueColorTokenPattern = RegExp(
  r'''(?:^|[:,;\s"'])(?:RGB|Tc)(?:$|[:,;\s"'])''',
);

String? _parseAllowPassthrough(String? output) {
  if (output == null) return null;
  final trimmed = output.trim();
  if (trimmed.isEmpty) return null;
  final value = trimmed.split(_whitespacePattern).last.toLowerCase();
  return switch (value) {
    'off' || 'on' || 'all' => value,
    _ => null,
  };
}

bool _hasTrueColorCapability(String? output) {
  if (output == null || output.isEmpty) return false;
  return _trueColorTokenPattern.hasMatch(output);
}

/// Parses enclosing multiplexer diagnostics from [environment] and raw `tmux`
/// option outputs in pure Dart without `dart:io` dependencies.
KttyMultiplexerDiagnostics? parseTmuxDiagnostics({
  required Map<String, String> environment,
  required String? passthroughOutput,
  required String? featuresOutput,
  required String? overridesOutput,
}) {
  if ((environment['TMUX'] ?? '').isNotEmpty) {
    final allowPassthrough = _parseAllowPassthrough(passthroughOutput);
    final hasTrueColor =
        _hasTrueColorCapability(featuresOutput) ||
        _hasTrueColorCapability(overridesOutput);
    final hints = <String>[
      if (allowPassthrough == null || allowPassthrough == 'off')
        kttyTmuxPassthroughHint,
      if (!hasTrueColor) kttyTmuxTrueColorHint,
    ];
    return KttyMultiplexerDiagnostics(
      multiplexer: 'tmux',
      allowPassthrough: allowPassthrough,
      hasTrueColor: hasTrueColor,
      hints: List<String>.unmodifiable(hints),
    );
  }

  if ((environment['STY'] ?? '').isNotEmpty) {
    return const KttyMultiplexerDiagnostics(
      multiplexer: 'screen',
      hints: [kttyScreenPassthroughHint],
    );
  }

  return null;
}
