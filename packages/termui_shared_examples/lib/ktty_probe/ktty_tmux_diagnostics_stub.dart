import 'ktty_probe_report.dart';

/// Web/non-IO stub for multiplexer detection; always returns `null`.
Future<KttyMultiplexerDiagnostics?> detectMultiplexerDiagnostics({
  Map<String, String>? environment,
  Future<String?> Function(List<String> args)? runTmux,
}) => Future<KttyMultiplexerDiagnostics?>.value(null);
