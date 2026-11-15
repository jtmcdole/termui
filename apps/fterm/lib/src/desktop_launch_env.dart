import 'package:termui_cast_protocol/termui_cast_protocol.dart';

import 'desktop_launch_env_stub.dart'
    if (dart.library.io) 'desktop_launch_env_io.dart'
    as impl;
import 'launch_config.dart';

/// Pure-Dart factory seam building a platform [IapTokenProvider] at startup.
typedef DesktopIapProviderBuilder =
    IapTokenProvider? Function({
      required Uri serverUri,
      String? serviceAccount,
      String? keyFilePath,
    });

/// Startup connection overrides resolved from CLI flags or runtime environment
/// variables on native desktop (`dart:io`) platforms.
final class DesktopLaunchOverrides {
  /// Optional `/v1/client` WebSocket URL override.
  final String? serverUrl;

  /// Optional bearer viewer token override.
  final String? token;

  /// Optional `--token-file` path override.
  final String? tokenFile;

  /// Optional bearer caster token override (`--caster-token` /
  /// `TERMUI_CAST_CASTER_TOKEN`).
  final String? casterToken;

  /// Optional `--caster-token-file` path override.
  final String? casterTokenFile;

  /// Normalized `--iap-service-account` CLI override, if non-empty.
  final String? cliIapServiceAccount;

  /// Normalized `--iap-key-file` CLI override, if non-empty.
  final String? cliIapKeyFile;

  /// Normalized `TERMUI_CAST_IAP_SERVICE_ACCOUNT` environment fallback.
  final String? envIapServiceAccount;

  /// Normalized `TERMUI_CAST_IAP_KEY_FILE` environment fallback.
  final String? envIapKeyFile;

  /// Whether `--token` was explicitly supplied on the CLI.
  final bool hasCliToken;

  /// Whether `--caster-token` was explicitly supplied on the CLI.
  final bool hasCliCasterToken;

  /// Whether `--iap-service-account` was explicitly supplied on the CLI.
  final bool hasCliIapServiceAccount;

  /// Whether `--iap-key-file` was explicitly supplied on the CLI.
  final bool hasCliIapKeyFile;

  /// Creates an immutable set of desktop launch overrides.
  const DesktopLaunchOverrides({
    this.serverUrl,
    this.token,
    this.tokenFile,
    this.casterToken,
    this.casterTokenFile,
    this.cliIapServiceAccount,
    this.cliIapKeyFile,
    this.envIapServiceAccount,
    this.envIapKeyFile,
    this.hasCliToken = false,
    this.hasCliCasterToken = false,
    this.hasCliIapServiceAccount = false,
    this.hasCliIapKeyFile = false,
  });
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
}) {
  final cli = _parseCliArgs(args);
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
  final cliTokenFile = _nonEmptyTrimmed(cli.tokenFile);
  if (cli.hasTokenFile && cliTokenFile == null) {
    throw const FormatException('Missing non-empty value for --token-file.');
  }
  final cliCasterTokenFile = _nonEmptyTrimmed(cli.casterTokenFile);
  if (cli.hasCasterTokenFile && cliCasterTokenFile == null) {
    throw const FormatException(
      'Missing non-empty value for --caster-token-file.',
    );
  }
  final cliAccount = _nonEmptyTrimmed(cli.iapServiceAccount);
  if (cli.hasIapServiceAccount && cliAccount == null) {
    throw const FormatException(
      'Missing non-empty value for --iap-service-account.',
    );
  }
  final cliKeyFile = _nonEmptyTrimmed(cli.iapKeyFile);
  if (cli.hasIapKeyFile && cliKeyFile == null) {
    throw const FormatException('Missing non-empty value for --iap-key-file.');
  }
  return DesktopLaunchOverrides(
    serverUrl:
        _nonEmptyTrimmed(cli.serverUrl) ??
        _nonEmptyTrimmed(environment['TERMUI_CAST_SERVER_URL']),
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
    envIapKeyFile: _nonEmptyTrimmed(environment['TERMUI_CAST_IAP_KEY_FILE']),
    hasCliToken: cli.hasToken,
    hasCliCasterToken: cli.hasCasterToken,
    hasCliIapServiceAccount: cli.hasIapServiceAccount,
    hasCliIapKeyFile: cli.hasIapKeyFile,
  );
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
  void Function(String flag)? onCliSecretWarning,
}) {
  final overrides = environment != null
      ? parseDesktopLaunchOverrides(args: args, environment: environment)
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
  if (iapProvider == null && iapFactory == null) return baseConfig;
  return CastLaunchConfig(
    serverUri: baseConfig.serverUri,
    token: baseConfig.token,
    casterToken: baseConfig.casterToken,
    promptForConnection: baseConfig.promptForConnection,
    iapTokenProvider: iapProvider,
    iapTokenProviderFactory: iapFactory,
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

/// Reports a fatal startup configuration [message] on `dart:io` desktops.
void reportDesktopStartupError(String message) =>
    impl.reportPlatformStartupError(message);

/// Logs a non-fatal transport connection [error] on `dart:io` desktops.
void logDesktopConnectError(Object error) =>
    impl.logPlatformConnectError(error);

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

({
  String? serverUrl,
  String? token,
  String? tokenFile,
  String? casterToken,
  String? casterTokenFile,
  String? iapServiceAccount,
  String? iapKeyFile,
  bool hasToken,
  bool hasTokenFile,
  bool hasCasterToken,
  bool hasCasterTokenFile,
  bool hasIapServiceAccount,
  bool hasIapKeyFile,
})
_parseCliArgs(List<String> args) {
  String? serverUrl;
  String? token;
  String? tokenFile;
  String? casterToken;
  String? casterTokenFile;
  String? iapServiceAccount;
  String? iapKeyFile;
  var hasToken = false;
  var hasTokenFile = false;
  var hasCasterToken = false;
  var hasCasterTokenFile = false;
  var hasIapServiceAccount = false;
  var hasIapKeyFile = false;
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
    hasToken: hasToken,
    hasTokenFile: hasTokenFile,
    hasCasterToken: hasCasterToken,
    hasCasterTokenFile: hasCasterTokenFile,
    hasIapServiceAccount: hasIapServiceAccount,
    hasIapKeyFile: hasIapKeyFile,
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
