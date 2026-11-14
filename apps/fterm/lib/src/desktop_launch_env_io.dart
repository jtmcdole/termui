import 'dart:io' show IOException, Platform, exit, stderr;

import 'package:clock/clock.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_cast_protocol/termui_cast_protocol_io.dart';

import 'desktop_launch_env.dart';

/// Resolves [DesktopLaunchOverrides] from CLI [args] and [Platform.environment]
/// on native desktop (`dart:io`) platforms.
DesktopLaunchOverrides readPlatformLaunchOverrides(List<String> args) =>
    parseDesktopLaunchOverrides(args: args, environment: Platform.environment);

/// Parses any `--iap-key-file` once at startup and builds a cached [IapJwtSigner].
IapTokenProvider? buildPlatformIapTokenProvider({
  required Uri serverUri,
  String? serviceAccount,
  String? keyFilePath,
  Clock clock = const Clock(),
  ProcessRunner? processRunner,
}) {
  if (serviceAccount == null && keyFilePath == null) return null;
  final parsedKey = keyFilePath == null
      ? null
      : IapServiceAccountKey.fromFileSync(keyFilePath);
  return IapJwtSigner(
    serviceAccount: serviceAccount,
    serviceAccountKey: parsedKey,
    targetAudienceUrl: IapJwtSigner.audienceForWebSocketUri(serverUri),
    clock: clock,
    processRunner: processRunner,
  ).getBearerToken;
}

/// Logs [message] to `stderr` (ignoring detached-GUI console [IOException]s)
/// and exits with `EX_USAGE` (`64`) outside `FLUTTER_TEST`.
void reportPlatformStartupError(
  String message, {
  StringSink? err,
  Map<String, String>? environment,
  void Function(int code)? onExit,
}) {
  try {
    (err ?? stderr).writeln('fterm: $message');
  } on IOException catch (_) {}
  final env = environment ?? Platform.environment;
  if (!env.containsKey('FLUTTER_TEST')) {
    (onExit ?? exit)(64);
  }
}

/// Logs a transport connect [error] to `stderr` on desktop outside `FLUTTER_TEST`.
void logPlatformConnectError(
  Object error, {
  StringSink? err,
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  if (err == null && env.containsKey('FLUTTER_TEST')) return;
  try {
    (err ?? stderr).writeln('fterm: connect failed: $error');
  } on IOException catch (_) {}
}
