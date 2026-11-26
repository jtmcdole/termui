import 'dart:io'
    show
        File,
        FileStat,
        FileSystemException,
        IOException,
        Platform,
        Process,
        ProcessStartMode,
        exit,
        stderr;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
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
    parseDesktopLaunchOverrides(
      args: args,
      environment: Platform.environment,
      canonicalizePath: canonicalizePlatformFilePath,
    );

/// Resolves [rawPath] against the startup working directory (expanding leading
/// `~/` first) so relaunches from `/` (such as macOS `open -n`) keep valid file
/// flag paths.
String canonicalizePlatformFilePath(String rawPath) =>
    p.normalize(File(expandHomePath(rawPath)).absolute.path);

/// Probes `PATH` and standard SDK install locations for a `gcloud` executable.
String? probePlatformGcloudExecutable() => probeGcloudExecutable();

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
  String? gcloudPath,
  Clock clock = const Clock(),
  ProcessRunner? processRunner,
}) {
  if (serviceAccount == null && keyFilePath == null) return null;
  final trimmedKey = keyFilePath?.trim();
  final parsedKey = (trimmedKey == null || trimmedKey.isEmpty)
      ? null
      : _loadCachedIapKeySync(expandHomePath(trimmedKey));
  final trimmedGcloud = gcloudPath?.trim();
  final resolvedGcloud = (trimmedGcloud != null && trimmedGcloud.isNotEmpty)
      ? expandHomePath(trimmedGcloud)
      : 'gcloud';
  return IapJwtSigner(
    serviceAccount: serviceAccount,
    serviceAccountKey: parsedKey,
    targetAudienceUrl: TokenAuthenticator.iapAudienceForWebSocketUri(serverUri),
    gcloudExecutable: resolvedGcloud,
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

/// Launches a detached replacement `fterm` process with sanitized [args],
/// stripping `FTERM_GPU_PREFERENCE` and `FTERM_AUTOMATION_TOKEN` so the
/// restarted instance honors saved GPU settings and does not inherit ephemeral
/// automation secrets.
Future<bool> relaunchPlatformDesktopApp({
  List<String> args = const [],
  Map<String, String>? environment,
  Future<Object> Function(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    bool includeParentEnvironment,
    ProcessStartMode mode,
  })?
  processStarter,
}) async {
  final env = Map<String, String>.of(environment ?? Platform.environment);
  if (env.containsKey('FLUTTER_TEST')) return false;
  env
    ..remove('FTERM_GPU_PREFERENCE')
    ..remove('FTERM_AUTOMATION_TOKEN');
  final starter = processStarter ?? Process.start;
  try {
    await starter(
      Platform.resolvedExecutable,
      args,
      environment: env,
      includeParentEnvironment: false,
      mode: ProcessStartMode.detached,
    );
    return true;
  } on Object {
    return false;
  }
}

/// Opens [directoryPath] in the native desktop file manager (`explorer.exe`,
/// `open`, or `xdg-open`), returning `false` under `FLUTTER_TEST` or on failure.
Future<bool> openPlatformDirectory(
  String directoryPath, {
  Map<String, String>? environment,
}) async {
  final env = environment ?? Platform.environment;
  if (env.containsKey('FLUTTER_TEST')) return false;
  final trimmed = directoryPath.trim();
  if (trimmed.isEmpty || trimmed == '.') return false;
  final executable = Platform.isWindows
      ? 'explorer.exe'
      : Platform.isMacOS
      ? 'open'
      : 'xdg-open';
  try {
    await Process.start(executable, <String>[
      trimmed,
    ], mode: ProcessStartMode.detached);
    return true;
  } on Object {
    return false;
  }
}
