import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ktty_probe_report.dart';
import 'ktty_tmux_diagnostics.dart';

const Duration _tmuxCommandTimeout = Duration(seconds: 1);

Future<String?> _runTmuxProcess(
  List<String> args,
  Map<String, String> environment,
) async {
  Process? process;
  try {
    process = await Process.start('tmux', args, environment: environment);
    final stdoutFuture = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join()
        .catchError((Object _) => '');
    final stderrDrain = process.stderr.drain<void>().catchError((Object _) {});
    final (exitCode, output, _) = await (
      process.exitCode,
      stdoutFuture,
      stderrDrain,
    ).wait.timeout(_tmuxCommandTimeout);
    return exitCode == 0 ? output : null;
  } on Object {
    process?.kill();
    return null;
  }
}

Future<String?> _safeRunTmux(
  Future<String?> Function(List<String> args) runner,
  List<String> args,
) async {
  try {
    return await runner(args).timeout(_tmuxCommandTimeout);
  } on Object {
    return null;
  }
}

/// Detects an enclosing `tmux` or GNU `screen` multiplexer and queries `tmux`
/// passthrough and truecolor settings when `$TMUX` is set.
Future<KttyMultiplexerDiagnostics?> detectMultiplexerDiagnostics({
  Map<String, String>? environment,
  Future<String?> Function(List<String> args)? runTmux,
}) async {
  final env = environment ?? Platform.environment;
  final hasTmux = (env['TMUX'] ?? '').isNotEmpty;
  final hasScreen = (env['STY'] ?? '').isNotEmpty;
  if (!hasTmux && !hasScreen) return null;
  if (!hasTmux) {
    return parseTmuxDiagnostics(
      environment: env,
      passthroughOutput: null,
      featuresOutput: null,
      overridesOutput: null,
    );
  }

  final runner = runTmux ?? (args) => _runTmuxProcess(args, env);
  final (passthroughOutput, featuresOutput, overridesOutput) = await (
    _safeRunTmux(runner, const ['show', '-Ap', 'allow-passthrough']),
    _safeRunTmux(runner, const ['show', '-s', 'terminal-features']),
    _safeRunTmux(runner, const ['show', '-s', 'terminal-overrides']),
  ).wait;

  return parseTmuxDiagnostics(
    environment: env,
    passthroughOutput: passthroughOutput,
    featuresOutput: featuresOutput,
    overridesOutput: overridesOutput,
  );
}
