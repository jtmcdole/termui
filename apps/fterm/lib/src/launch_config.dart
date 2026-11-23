import 'package:termui_cast_client_core/termui_cast_client_core.dart';

/// Parsed startup connection settings resolved once at the application boundary.
final class CastLaunchConfig {
  /// Default loopback `/v1/client` WebSocket endpoint.
  static final Uri defaultServerUri = Uri.parse(defaultClientServerUrl);

  /// Target `/v1/client` WebSocket URI.
  final Uri serverUri;

  /// Bearer viewer token sent in the initial binary `AuthFrame`.
  final String token;

  /// Optional caster bearer token used when publishing local desktop panes.
  final String casterToken;

  /// Whether to prompt for connection credentials before connecting when no
  /// local desktop shell is available.
  final bool promptForConnection;

  /// Optional Cloud Run IAP bearer JWT provider (`dart:io` `wss://` only).
  final IapTokenProvider? iapTokenProvider;

  /// Optional factory returning an [IapTokenProvider] scoped to a specific
  /// `wss://` target URI (such as `/v1/caster` vs `/v1/client`).
  final IapTokenProvider? Function(Uri targetUri)? iapTokenProviderFactory;

  /// Sanitized CLI arguments forwarded when relaunching `fterm` after an
  /// in-place desktop update (file paths canonicalized, raw secrets stripped).
  final List<String> relaunchArgs;

  /// Optional base path for automatic startup performance trace recording
  /// (`--trace-out` / `TERMUI_TRACE_OUT`).
  final String? traceOutPath;

  /// Optional auto-stop duration for startup performance trace recording
  /// (`--trace-seconds` / `TERMUI_TRACE_SECONDS`).
  final Duration? traceDuration;

  /// Whether `fterm` should exit cleanly once a timed startup trace completes
  /// (`--trace-exit`).
  final bool traceExitOnComplete;

  /// Creates an explicit launch configuration.
  CastLaunchConfig({
    Uri? serverUri,
    this.token = '',
    this.casterToken = '',
    this.promptForConnection = false,
    this.iapTokenProvider,
    this.iapTokenProviderFactory,
    List<String> relaunchArgs = const [],
    this.traceOutPath,
    this.traceDuration,
    this.traceExitOnComplete = false,
  }) : serverUri = serverUri ?? defaultServerUri,
       relaunchArgs = relaunchArgs.isEmpty
           ? const []
           : List<String>.unmodifiable(relaunchArgs);

  /// Resolves an [IapTokenProvider] scoped to [targetUri] (`wss://` only),
  /// minting an audience-matched token for endpoints such as `/v1/caster`.
  IapTokenProvider? iapTokenProviderFor(Uri targetUri) {
    if (targetUri.scheme != 'wss') return null;
    final customFactory = iapTokenProviderFactory;
    if (customFactory != null) return customFactory(targetUri);
    return iapTokenProvider;
  }

  /// Parses `TERMUI_CAST_SERVER_URL`, `TERMUI_CAST_TOKEN`, `TERMUI_CAST_CASTER_TOKEN`,
  /// and `#token=` once.
  ///
  /// Bearer tokens are read from HTTP(S) URL fragments (`#token=...`) on Web or
  /// from environment/CLI configuration (`envToken`) so secrets never appear in
  /// HTTP query logs or `Referer` headers. URL-based server overrides
  /// (`?server=` and `#server=`) are ignored so a link on a trusted origin
  /// cannot redirect the viewer to an untrusted WebSocket endpoint, and non-HTTP
  /// base URIs (such as `file://` on native desktop) fall back cleanly to
  /// [defaultServerUri].
  factory CastLaunchConfig.fromEnvironmentAndUri({
    required Uri baseUri,
    String initialFragmentToken = '',
    String envServerUrl = '',
    String envToken = '',
    String envCasterToken = '',
    IapTokenProvider? iapTokenProvider,
  }) {
    final hasHttpOrigin = _hasHttpOrigin(baseUri);
    final fragToken = initialFragmentToken.isNotEmpty
        ? initialFragmentToken
        : (hasHttpOrigin
              ? _parseFragmentParams(baseUri.fragment)['token']
              : null);
    final resolvedToken = (fragToken != null && fragToken.isNotEmpty)
        ? fragToken
        : envToken;
    final trimmedServer = envServerUrl.trim();

    if (trimmedServer.isNotEmpty) {
      return CastLaunchConfig(
        serverUri: parseRelayUri(trimmedServer),
        token: resolvedToken,
        casterToken: envCasterToken,
        promptForConnection: false,
        iapTokenProvider: iapTokenProvider,
      );
    }
    return CastLaunchConfig(
      serverUri: _defaultServerUriForBase(baseUri),
      token: resolvedToken,
      casterToken: envCasterToken,
      promptForConnection: resolvedToken.trim().isEmpty,
      iapTokenProvider: iapTokenProvider,
    );
  }

  /// Parses a relay host or URL (`ws://`, `wss://`, `https://`, or bare host)
  /// into the canonical viewer `/v1/client` WebSocket URI.
  static Uri parseRelayUri(String raw) => parseCastWebSocketUri(
    raw,
    defaultPath: '/v1/client',
    normalizeCasterPath: true,
  );

  /// Derives the corresponding `/v1/caster` WebSocket URI for sharing a local
  /// pane to this relay endpoint.
  Uri get casterServerUri => deriveCasterServerUri(serverUri);

  /// Converts a viewer `/v1/client` URI into the matching `/v1/caster` URI.
  static Uri deriveCasterServerUri(Uri clientOrBaseUri) {
    final path = clientOrBaseUri.path;
    final nextPath = switch (path) {
      '' || '/' => '/v1/caster',
      '/v1/client' => '/v1/caster',
      _ when path.endsWith('/v1/client') =>
        '${path.substring(0, path.length - '/v1/client'.length)}/v1/caster',
      _ => path,
    };
    return clientOrBaseUri.replace(path: nextPath);
  }

  static bool _hasHttpOrigin(Uri baseUri) =>
      (baseUri.scheme == 'http' || baseUri.scheme == 'https') &&
      baseUri.host.isNotEmpty;

  static Uri _defaultServerUriForBase(Uri baseUri) {
    if (!_hasHttpOrigin(baseUri)) {
      return defaultServerUri;
    }
    return Uri(
      scheme: baseUri.scheme == 'https' ? 'wss' : 'ws',
      host: baseUri.host,
      port: baseUri.hasPort ? baseUri.port : null,
      path: '/v1/client',
    );
  }

  static Map<String, String> _parseFragmentParams(String fragment) {
    if (fragment.isEmpty) return const {};
    final cleaned = fragment.startsWith('?') ? fragment.substring(1) : fragment;
    if (!cleaned.contains('=')) return const {};
    try {
      return Uri.splitQueryString(cleaned);
    } on FormatException {
      return const {};
    }
  }
}
