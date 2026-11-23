import 'package:termui_cast_protocol/termui_cast_protocol.dart';

import 'desktop_launch_env_stub.dart'
    if (dart.library.io) 'desktop_launch_env_io.dart'
    as impl;
import 'launch_config.dart';

/// Pure-Dart factory seam building a platform [IapTokenProvider] at startup.
typedef DesktopIapProviderBuilder = IapTokenProvider? Function({
  required Uri serverUri,
  String? serviceAccount,
  String? keyFilePath,
  String? gcloudPath,
});

/// Startup connection overrides resolved from CLI flags or runtime environment
/// variables on native desktop (`dart:io`) platforms.
final class DesktopLaunchOverrides {
  /// Optional `/v1/client` WebSocket URL override (CLI or environment).
  final String? serverUrl;

  /// Optional `/v1/client` WebSocket URL explicitly passed via `--server` or
  /// `--url` on the CLI.
  final String? cliServerUrl;

  /// Optional bearer viewer token override.
  final String? token;

  /// Optional canonicalized `--token-file` path override.
  final String? tokenFile;

  /// Optional bearer caster token override (`--caster-token` /
  /// `TERMUI_CAST_CASTER_TOKEN`).
  final String? casterToken;

  /// Optional canonicalized `--caster-token-file` path override.
  final String? casterTokenFile;

  /// Normalized `--iap-service-account` CLI override, if non-empty.
  final String? cliIapServiceAccount;

  /// Canonicalized `--iap-key-file` CLI override, if non-empty.
  final String? cliIapKeyFile;

  /// Normalized `TERMUI_CAST_IAP_SERVICE_ACCOUNT` environment fallback.
  final String? envIapServiceAccount;

  /// Canonicalized `TERMUI_CAST_IAP_KEY_FILE` environment fallback.
  final String? envIapKeyFile;

  /// Optional canonicalized `gcloud` executable path override (CLI or env).
  final String? gcloudPath;

  /// Optional canonicalized `--gcloud-path` CLI override, if non-empty.
  final String? cliGcloudPath;

  /// Whether `--token` was explicitly supplied on the CLI.
  final bool hasCliToken;

  /// Whether `--caster-token` was explicitly supplied on the CLI.
  final bool hasCliCasterToken;

  /// Whether `--iap-service-account` was explicitly supplied on the CLI.
  final bool hasCliIapServiceAccount;

  /// Whether `--iap-key-file` was explicitly supplied on the CLI.
  final bool hasCliIapKeyFile;

  /// Optional base path for automatic startup performance trace recording.
  final String? traceOutPath;

  /// Optional positive auto-stop duration for startup performance tracing.
  final Duration? traceDuration;

  /// Whether `fterm` should exit automatically once a timed startup trace ends.
  final bool traceExitOnComplete;

  /// Creates an immutable set of desktop launch overrides.
  const DesktopLaunchOverrides({
    this.serverUrl,
    this.cliServerUrl,
    this.token,
    this.tokenFile,
    this.casterToken,
    this.casterTokenFile,
    this.cliIapServiceAccount,
    this.cliIapKeyFile,
    this.envIapServiceAccount,
    this.envIapKeyFile,
    this.gcloudPath,
    this.cliGcloudPath,
    this.hasCliToken = false,
    this.hasCliCasterToken = false,
    this.hasCliIapServiceAccount = false,
    this.hasCliIapKeyFile = false,
    this.traceOutPath,
    this.traceDuration,
    this.traceExitOnComplete = false,
  });

  /// Sanitized CLI arguments safe to forward across an auto-update relaunch
  /// (preserving canonicalized file flags and server URL while stripping raw
  /// `--token` and `--caster-token` bearer values).
  List<String> get relaunchArgs => List<String>.unmodifiable(<String>[
    if (cliServerUrl case final server?) ...['--server', server],
    if (tokenFile case final tf?) ...['--token-file', tf],
    if (casterTokenFile case final ctf?) ...['--caster-token-file', ctf],
    if (cliIapServiceAccount case final sa?) ...['--iap-service-account', sa],
    if (cliIapKeyFile case final kf?) ...['--iap-key-file', kf],
    if (cliGcloudPath case final gp?) ...['--gcloud-path', gp],
  ]);
}

/// Parses optional `--server` / `--url`, `--token`, `--token-file`,
/// `--caster-token`, `--caster-token-file`, `--iap-service-account`,
/// and `--iap-key-file` CLI flags from [args], along with `TERMUI_CAST_*`
/// environment fallbacks in [environment].
///
/// Unknown platform arguments (such as macOS LaunchServices flags) and any
/// arguments following `--` are ignored. Throws [FormatException] when a
/// recognized option flag is missing or blank where a value is required.
DesktopLaunchOverrides parseDesktopLaunchOverrides({
  List<String> args = const [],
  Map<String, String> environment = const {},
  String Function(String path)? canonicalizePath,
}) {
  final canonicalize = canonicalizePath ?? impl.canonicalizePlatformFilePath;
  final cli = _parseCliArgs(args);
  _validateMutualExclusions(cli);
  final cliTokenFile = _resolveRequiredFileFlag(
    present: cli.hasTokenFile,
    raw: cli.tokenFile,
    flag: '--token-file',
    canonicalize: canonicalize,
  );
  final cliCasterTokenFile = _resolveRequiredFileFlag(
    present: cli.hasCasterTokenFile,
    raw: cli.casterTokenFile,
    flag: '--caster-token-file',
    canonicalize: canonicalize,
  );
  final cliAccount = _resolveRequiredTextFlag(
    present: cli.hasIapServiceAccount,
    raw: cli.iapServiceAccount,
    flag: '--iap-service-account',
  );
  final cliKeyFile = _resolveRequiredFileFlag(
    present: cli.hasIapKeyFile,
    raw: cli.iapKeyFile,
    flag: '--iap-key-file',
    canonicalize: canonicalize,
  );
  final cliGcloudPath = _resolveRequiredFileFlag(
    present: cli.hasGcloudPath,
    raw: cli.gcloudPath,
    flag: '--gcloud-path',
    canonicalize: canonicalize,
  );
  final cliTraceOut = _resolveRequiredTextFlag(
    present: cli.hasTraceOut,
    raw: cli.traceOut,
    flag: '--trace-out',
  );
  final traceDuration = _resolveTraceDuration(
    hasCliSeconds: cli.hasTraceSeconds,
    cliSecondsRaw: cli.traceSeconds,
    envSecondsRaw: environment['TERMUI_TRACE_SECONDS'],
  );
  if (cli.traceExit && traceDuration == null) {
    throw const FormatException(
      '--trace-exit requires --trace-seconds or TERMUI_TRACE_SECONDS.',
    );
  }
  final cliServer = _nonEmptyTrimmed(cli.serverUrl);
  final envKeyRaw = _nonEmptyTrimmed(environment['TERMUI_CAST_IAP_KEY_FILE']);
  final envGcloudRaw = _nonEmptyTrimmed(environment['TERMUI_CAST_GCLOUD_PATH']);
  return DesktopLaunchOverrides(
    serverUrl:
        cliServer ?? _nonEmptyTrimmed(environment['TERMUI_CAST_SERVER_URL']),
    cliServerUrl: cliServer,
    token:
        _nonEmptyRaw(cli.token) ??
        _nonEmptyRaw(environment['TERMUI_CAST_TOKEN']),
    tokenFile: cliTokenFile,
    casterToken:
        _nonEmptyRaw(cli.casterToken) ??
        _nonEmptyRaw(environment['TERMUI_CAST_CASTER_TOKEN']),
    casterTokenFile: cliCasterTokenFile,
    cliIapServiceAccount: cliAccount,
    cliIapKeyFile: cliKeyFile,
    envIapServiceAccount: _nonEmptyTrimmed(
      environment['TERMUI_CAST_IAP_SERVICE_ACCOUNT'],
    ),
    envIapKeyFile: envKeyRaw == null ? null : canonicalize(envKeyRaw),
    gcloudPath:
        cliGcloudPath ??
        (envGcloudRaw == null ? null : canonicalize(envGcloudRaw)),
    cliGcloudPath: cliGcloudPath,
    hasCliToken: cli.hasToken,
    hasCliCasterToken: cli.hasCasterToken,
    hasCliIapServiceAccount: cli.hasIapServiceAccount,
    hasCliIapKeyFile: cli.hasIapKeyFile,
    traceOutPath:
        cliTraceOut ?? _nonEmptyTrimmed(environment['TERMUI_TRACE_OUT']),
    traceDuration: traceDuration,
    traceExitOnComplete: cli.traceExit,
  );
}

Duration? _resolveTraceDuration({
  required bool hasCliSeconds,
  required String? cliSecondsRaw,
  required String? envSecondsRaw,
}) {
  if (hasCliSeconds) {
    return _parsePositiveTraceSeconds(cliSecondsRaw, flag: '--trace-seconds');
  }
  final envTrimmed = _nonEmptyTrimmed(envSecondsRaw);
  if (envTrimmed == null) return null;
  return _parsePositiveTraceSeconds(envTrimmed, flag: 'TERMUI_TRACE_SECONDS');
}

Duration _parsePositiveTraceSeconds(String? raw, {required String flag}) {
  final trimmed = _nonEmptyTrimmed(raw);
  final parsed = trimmed == null ? null : int.tryParse(trimmed);
  if (parsed == null || parsed <= 0) {
    throw FormatException('Invalid positive integer for $flag: "$raw".');
  }
  return Duration(seconds: parsed);
}

void _validateMutualExclusions(_ParsedCliFlags cli) {
  if (cli.hasToken && cli.hasTokenFile) {
    throw const FormatException(
      'Cannot specify both --token and --token-file.',
    );
  }
  if (cli.hasCasterToken && cli.hasCasterTokenFile) {
    throw const FormatException(
      'Cannot specify both --caster-token and --caster-token-file.',
    );
  }
}

String? _resolveRequiredTextFlag({
  required bool present,
  required String? raw,
  required String flag,
}) {
  final normalized = _nonEmptyTrimmed(raw);
  if (present && normalized == null) {
    throw FormatException('Missing non-empty value for $flag.');
  }
  return normalized;
}

String? _resolveRequiredFileFlag({
  required bool present,
  required String? raw,
  required String flag,
  required String Function(String path) canonicalize,
}) {
  final normalized = _resolveRequiredTextFlag(
    present: present,
    raw: raw,
    flag: flag,
  );
  return normalized == null ? null : canonicalize(normalized);
}

/// Resolves [CastLaunchConfig] across CLI flags, runtime environment variables
/// (on `dart:io`), `--dart-define` constants, and [baseUri].
CastLaunchConfig resolveCastLaunchConfig({
  required Uri baseUri,
  List<String> args = const [],
  Map<String, String>? environment,
  String initialFragmentToken = '',
  String defineServerUrl = '',
  String defineToken = '',
  String defineCasterToken = '',
  DesktopIapProviderBuilder? iapProviderBuilder,
  String Function(String path)? secretFileReader,
  String Function(String path)? canonicalizePath,
  void Function(String flag)? onCliSecretWarning,
}) {
  final overrides = (environment != null || canonicalizePath != null)
      ? parseDesktopLaunchOverrides(
          args: args,
          environment: environment ?? const {},
          canonicalizePath: canonicalizePath,
        )
      : impl.readPlatformLaunchOverrides(args);
  final warnSecret = onCliSecretWarning ?? impl.warnPlatformCliSecret;
  if (overrides.hasCliToken) warnSecret('--token');
  if (overrides.hasCliCasterToken) warnSecret('--caster-token');
  final readSecretFile = secretFileReader ?? impl.readPlatformSecretFileSync;
  final resolvedToken = overrides.tokenFile != null
      ? readSecretFile(overrides.tokenFile!)
      : (overrides.token ?? defineToken);
  final resolvedCasterToken = overrides.casterTokenFile != null
      ? readSecretFile(overrides.casterTokenFile!)
      : (overrides.casterToken ?? defineCasterToken);
  final baseConfig = CastLaunchConfig.fromEnvironmentAndUri(
    baseUri: baseUri,
    initialFragmentToken: initialFragmentToken,
    envServerUrl: overrides.serverUrl ?? defineServerUrl,
    envToken: resolvedToken,
    envCasterToken: resolvedCasterToken,
  );
  final builder = iapProviderBuilder ?? impl.buildPlatformIapTokenProvider;
  final iapProvider = _resolveIapTokenProvider(
    overrides: overrides,
    serverUri: baseConfig.serverUri,
    builder: builder,
  );
  final iapFactory = _buildScopedIapProviderFactory(
    overrides: overrides,
    startupUri: baseConfig.serverUri,
    startupProvider: iapProvider,
    builder: builder,
  );
  final (selectedIapSa, selectedIapKey) = _selectIapCredentials(
    overrides: overrides,
    serverUri: baseConfig.serverUri,
    requireWssForEnv: false,
  );
  final relaunchArgs = overrides.relaunchArgs;
  final hasTraceConfig =
      overrides.traceOutPath != null ||
      overrides.traceDuration != null ||
      overrides.traceExitOnComplete;
  final hasGcloudOverride = overrides.gcloudPath != null;
  if (iapProvider == null &&
      iapFactory == null &&
      !hasGcloudOverride &&
      relaunchArgs.isEmpty &&
      !hasTraceConfig) {
    return baseConfig;
  }
  return CastLaunchConfig(
    serverUri: baseConfig.serverUri,
    token: baseConfig.token,
    casterToken: baseConfig.casterToken,
    promptForConnection: baseConfig.promptForConnection,
    iapTokenProvider: iapProvider,
    iapTokenProviderFactory: iapFactory,
    iapServiceAccount: selectedIapSa ?? '',
    iapKeyFilePath: selectedIapKey ?? '',
    gcloudPath: overrides.gcloudPath ?? '',
    relaunchArgs: relaunchArgs,
    traceOutPath: overrides.traceOutPath,
    traceDuration: overrides.traceDuration,
    traceExitOnComplete: overrides.traceExitOnComplete,
  );
}

IapTokenProvider? Function(Uri targetUri)? _buildScopedIapProviderFactory({
  required DesktopLaunchOverrides overrides,
  required Uri startupUri,
  required IapTokenProvider? startupProvider,
  required DesktopIapProviderBuilder builder,
}) {
  final (serviceAccount, keyFilePath) = _selectIapCredentials(
    overrides: overrides,
    serverUri: startupUri,
    requireWssForEnv: false,
  );
  if (serviceAccount == null && keyFilePath == null) return null;
  _validateIapCredentialFormat(
    serviceAccount: serviceAccount,
    keyFilePath: keyFilePath,
  );
  final cache = <String, IapTokenProvider?>{};
  if (startupProvider != null && startupUri.scheme == 'wss') {
    cache[TokenAuthenticator.iapAudienceForWebSocketUri(startupUri)] =
        startupProvider;
  }
  return (Uri targetUri) {
    if (targetUri.scheme != 'wss') return null;
    final audience = TokenAuthenticator.iapAudienceForWebSocketUri(targetUri);
    return cache.putIfAbsent(
      audience,
      () => builder(
        serverUri: targetUri,
        serviceAccount: serviceAccount,
        keyFilePath: keyFilePath,
        gcloudPath: overrides.gcloudPath,
      ),
    );
  };
}

(String?, String?) _selectIapCredentials({
  required DesktopLaunchOverrides overrides,
  required Uri serverUri,
  bool requireWssForEnv = true,
}) {
  final fromCli =
      overrides.hasCliIapServiceAccount || overrides.hasCliIapKeyFile;
  final useEnv = !fromCli && (!requireWssForEnv || serverUri.scheme == 'wss');
  final serviceAccount = fromCli
      ? overrides.cliIapServiceAccount
      : (useEnv ? overrides.envIapServiceAccount : null);
  final keyFilePath = fromCli
      ? overrides.cliIapKeyFile
      : (useEnv ? overrides.envIapKeyFile : null);
  return (serviceAccount, keyFilePath);
}

/// Builds a platform [IapTokenProvider] for [serverUri] on `dart:io` desktops,
/// returning `null` on Web or when neither [serviceAccount] nor [keyFilePath] is set.
IapTokenProvider? buildDesktopIapTokenProvider({
  required Uri serverUri,
  String? serviceAccount,
  String? keyFilePath,
  String? gcloudPath,
}) => impl.buildPlatformIapTokenProvider(
  serverUri: serverUri,
  serviceAccount: serviceAccount,
  keyFilePath: keyFilePath,
  gcloudPath: gcloudPath,
);

/// Probes `PATH` and standard SDK install locations for `gcloud` on desktop,
/// returning `null` when unavailable or on Web.
String? probeDesktopGcloudExecutable() => impl.probePlatformGcloudExecutable();

/// Reports a fatal startup configuration [message] on `dart:io` desktops.
void reportDesktopStartupError(String message) =>
    impl.reportPlatformStartupError(message);

/// Logs a non-fatal transport connection [error] on `dart:io` desktops.
void logDesktopConnectError(Object error) =>
    impl.logPlatformConnectError(error);

/// Launches a detached replacement `fterm` desktop process with sanitized
/// [args], returning `false` on Web or when launch fails.
Future<bool> relaunchDesktopApp({List<String> args = const []}) =>
    impl.relaunchPlatformDesktopApp(args: args);

/// Opens [directoryPath] in the OS file manager on desktop, returning `false`
/// on Web or under `FLUTTER_TEST`.
Future<bool> openDesktopDirectory(String directoryPath) =>
    impl.openPlatformDirectory(directoryPath);

IapTokenProvider? _resolveIapTokenProvider({
  required DesktopLaunchOverrides overrides,
  required Uri serverUri,
  required DesktopIapProviderBuilder builder,
}) {
  final (serviceAccount, keyFilePath) = _selectIapCredentials(
    overrides: overrides,
    serverUri: serverUri,
  );
  if (serviceAccount == null && keyFilePath == null) return null;

  _validateIapOptions(
    serverUri: serverUri,
    serviceAccount: serviceAccount,
    keyFilePath: keyFilePath,
  );
  return builder(
    serverUri: serverUri,
    serviceAccount: serviceAccount,
    keyFilePath: keyFilePath,
    gcloudPath: overrides.gcloudPath,
  );
}

void _validateIapCredentialFormat({
  required String? serviceAccount,
  required String? keyFilePath,
}) {
  if (serviceAccount != null && keyFilePath != null) {
    throw const FormatException(
      'Cannot specify both --iap-service-account and --iap-key-file.',
    );
  }
  if (serviceAccount != null &&
      !TokenAuthenticator.isValidServiceAccountEmail(serviceAccount)) {
    throw FormatException(
      'Invalid --iap-service-account email: "$serviceAccount".',
    );
  }
}

void _validateIapOptions({
  required Uri serverUri,
  required String? serviceAccount,
  required String? keyFilePath,
}) {
  _validateIapCredentialFormat(
    serviceAccount: serviceAccount,
    keyFilePath: keyFilePath,
  );
  if (serviceAccount != null && serverUri.scheme != 'wss') {
    throw const FormatException(
      '--iap-service-account requires a wss:// server URI.',
    );
  }
  if (keyFilePath != null && serverUri.scheme != 'wss') {
    throw const FormatException('--iap-key-file requires a wss:// server URI.');
  }
}

typedef _ParsedCliFlags = ({
  String? serverUrl,
  String? token,
  String? tokenFile,
  String? casterToken,
  String? casterTokenFile,
  String? iapServiceAccount,
  String? iapKeyFile,
  String? gcloudPath,
  String? traceOut,
  String? traceSeconds,
  bool hasToken,
  bool hasTokenFile,
  bool hasCasterToken,
  bool hasCasterTokenFile,
  bool hasIapServiceAccount,
  bool hasIapKeyFile,
  bool hasGcloudPath,
  bool hasTraceOut,
  bool hasTraceSeconds,
  bool traceExit,
});

_ParsedCliFlags _parseCliArgs(List<String> args) {
  String? serverUrl;
  String? token;
  String? tokenFile;
  String? casterToken;
  String? casterTokenFile;
  String? iapServiceAccount;
  String? iapKeyFile;
  String? gcloudPath;
  String? traceOut;
  String? traceSeconds;
  var hasToken = false;
  var hasTokenFile = false;
  var hasCasterToken = false;
  var hasCasterTokenFile = false;
  var hasIapServiceAccount = false;
  var hasIapKeyFile = false;
  var hasGcloudPath = false;
  var hasTraceOut = false;
  var hasTraceSeconds = false;
  var traceExit = false;
  for (var i = 0; i < args.length; i++) {
    final current = args[i];
    if (current == '--') break;
    final split = _splitEqualsOption(current);
    final flag = split?.flag ?? current;
    String readValue() =>
        split?.value ?? _requireNextArgValue(args, ++i, current);
    switch (flag) {
      case '--server' || '--url':
        serverUrl = readValue();
      case '--token':
        token = readValue();
        hasToken = true;
      case '--token-file':
        tokenFile = readValue();
        hasTokenFile = true;
      case '--caster-token':
        casterToken = readValue();
        hasCasterToken = true;
      case '--caster-token-file':
        casterTokenFile = readValue();
        hasCasterTokenFile = true;
      case '--iap-service-account':
        iapServiceAccount = readValue();
        hasIapServiceAccount = true;
      case '--iap-key-file':
        iapKeyFile = readValue();
        hasIapKeyFile = true;
      case '--gcloud-path':
        gcloudPath = readValue();
        hasGcloudPath = true;
      case '--trace-out':
        traceOut = readValue();
        hasTraceOut = true;
      case '--trace-seconds':
        traceSeconds = readValue();
        hasTraceSeconds = true;
      case '--trace-exit':
        if (split != null) {
          throw FormatException('Unexpected value for --trace-exit: $current');
        }
        traceExit = true;
    }
  }
  return (
    serverUrl: serverUrl,
    token: token,
    tokenFile: tokenFile,
    casterToken: casterToken,
    casterTokenFile: casterTokenFile,
    iapServiceAccount: iapServiceAccount,
    iapKeyFile: iapKeyFile,
    gcloudPath: gcloudPath,
    traceOut: traceOut,
    traceSeconds: traceSeconds,
    hasToken: hasToken,
    hasTokenFile: hasTokenFile,
    hasCasterToken: hasCasterToken,
    hasCasterTokenFile: hasCasterTokenFile,
    hasIapServiceAccount: hasIapServiceAccount,
    hasIapKeyFile: hasIapKeyFile,
    hasGcloudPath: hasGcloudPath,
    hasTraceOut: hasTraceOut,
    hasTraceSeconds: hasTraceSeconds,
    traceExit: traceExit,
  );
}

({String flag, String value})? _splitEqualsOption(String arg) {
  final eq = arg.indexOf('=');
  if (!arg.startsWith('--') || eq <= 2) return null;
  return (flag: arg.substring(0, eq), value: arg.substring(eq + 1));
}

String _requireNextArgValue(List<String> args, int index, String flag) {
  if (index >= args.length) {
    throw FormatException('Missing value for $flag.');
  }
  return args[index];
}

String? _nonEmptyTrimmed(String? value) {
  final trimmed = value?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}

String? _nonEmptyRaw(String? value) =>
    (value == null || value.isEmpty) ? null : value;
