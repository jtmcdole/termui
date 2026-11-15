import 'dart:io'
    show
        File,
        FileStat,
        FileSystemException,
        IOException,
        Platform,
        exit,
        stderr;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_cast_protocol/termui_cast_protocol_io.dart';

import 'desktop_launch_env.dart';

final Map<String, ({int modifiedMicros, int size, IapServiceAccountKey key})>
_cachedIapKeys = {};
int _debugIapKeyParseCount = 0;

/// Number of times an [IapServiceAccountKey] was parsed from disk (testing helper).
@visibleForTesting
int get debugIapKeyParseCount => _debugIapKeyParseCount;

/// Clears cached [IapServiceAccountKey] instances and parse counter (testing helper).
@visibleForTesting
void resetCachedPlatformIapKeys() {
  _cachedIapKeys.clear();
  _debugIapKeyParseCount = 0;
}

/// Resolves [DesktopLaunchOverrides] from CLI [args] and [Platform.environment]
/// on native desktop (`dart:io`) platforms.
DesktopLaunchOverrides readPlatformLaunchOverrides(List<String> args) =>
    parseDesktopLaunchOverrides(args: args, environment: Platform.environment);

/// Reads and trims a bearer secret token from [path] at startup.
String readPlatformSecretFileSync(String path) {
  try {
    final trimmed = File(path).readAsStringSync().trim();
    if (trimmed.isEmpty) {
      throw FormatException('Secret file "$path" is empty.');
    }
    return trimmed;
  } on FileSystemException catch (e) {
    throw FormatException('Failed to read secret file "$path": ${e.message}');
  }
}

/// Warns when a bearer secret is passed directly via CLI [flag].
void warnPlatformCliSecret(
  String flag, {
  StringSink? err,
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  if (err == null && env.containsKey('FLUTTER_TEST')) return;
  try {
    (err ?? stderr).writeln(
      'fterm: warning: $flag on command line may be visible in process listings; '
      'prefer $flag-file or TERMUI_CAST_* environment variables.',
    );
  } on Object catch (_) {
    // Best-effort stderr warning when process stderr is closed.
  }
}

IapServiceAccountKey _loadCachedIapKeySync(String keyFilePath) {
  final canonicalPath = File(keyFilePath).absolute.path;
  final FileStat stat;
  try {
    stat = File(canonicalPath).statSync();
  } on FileSystemException catch (e) {
    throw FormatException(
      'Failed to stat IAP key file "$keyFilePath": ${e.message}',
    );
  }
  if (stat.type == .notFound) {
    throw FormatException('IAP key file not found: "$keyFilePath".');
  }
  final modifiedMicros = stat.modified.microsecondsSinceEpoch;
  final cached = _cachedIapKeys[canonicalPath];
  if (cached != null &&
      cached.modifiedMicros == modifiedMicros &&
      cached.size == stat.size) {
    return cached.key;
  }
  final parsed = IapServiceAccountKey.fromFileSync(canonicalPath);
  _debugIapKeyParseCount++;
  _cachedIapKeys[canonicalPath] = (
    modifiedMicros: modifiedMicros,
    size: stat.size,
    key: parsed,
  );
  return parsed;
}

/// Parses any `--iap-key-file` once (cached across audiences) and builds [IapJwtSigner].
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
      : _loadCachedIapKeySync(keyFilePath);
  return IapJwtSigner(
    serviceAccount: serviceAccount,
    serviceAccountKey: parsedKey,
    targetAudienceUrl: TokenAuthenticator.iapAudienceForWebSocketUri(serverUri),
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
