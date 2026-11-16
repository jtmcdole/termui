import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:clock/clock.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:termui/termui.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_cast_protocol/termui_cast_protocol_io.dart';
import 'package:termui_pty/termui_pty.dart';

import 'authoritative_terminal.dart';
import 'caster_state_machine.dart';
import 'file_upload_receiver.dart';
import 'pty_process_adapter.dart';

export 'package:termui_cast_protocol/termui_cast_protocol.dart'
    show IapTokenProvider;

/// Factory opening a binary WebSocket `StreamChannel<Uint8List>` to the relay server.
typedef ChannelOpener = Future<StreamChannel<Uint8List>> Function();

/// Async probe returning the active server revision identifier, or `null` if unavailable.
typedef RevisionProber = Future<String?> Function();

/// Immutable status snapshot emitted by [CasterService.statusStream].
final class CasterStatusSnapshot {
  /// Active lifecycle state of the caster relay connection.
  final CasterLifecycleState state;

  /// Active remote viewer count subscribed to this session.
  final int subscriberCount;

  /// Effective session title currently shown to viewers.
  final String title;

  /// Most recent connection or server error message, or `null` when healthy.
  final String? lastError;

  /// Creates an immutable status snapshot.
  const CasterStatusSnapshot({
    required this.state,
    required this.subscriberCount,
    required this.title,
    this.lastError,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CasterStatusSnapshot &&
          state == other.state &&
          subscriberCount == other.subscriberCount &&
          title == other.title &&
          lastError == other.lastError;

  @override
  int get hashCode => Object.hash(state, subscriberCount, title, lastError);
}

/// Validated CLI configuration for `termui_cast`.
final class CasterConfig {
  /// Default number of primary-screen scrollback lines retained by `termui_cast`.
  static const int defaultScrollbackLines = 5000;

  /// Hard upper bound on `--scrollback-lines` (`100,000`).
  static const int maxScrollbackLinesLimit = 100000;

  /// Default local relay server caster endpoint.
  static final Uri defaultServerUri = Uri.parse(
    'ws://127.0.0.1:8420/v1/caster',
  );

  /// Relay server `/v1/caster` WebSocket endpoint.
  final Uri serverUri;

  /// Bearer token sent inside the initial binary `AuthFrame`.
  final String token;

  /// Unique session identifier announced to the relay server.
  final SessionId sessionId;

  /// Display title shown in client tabs.
  final String title;

  /// Initial PTY width in columns.
  final int initialCols;

  /// Initial PTY height in rows.
  final int initialRows;

  /// Number of primary-screen scrollback lines retained in caster memory.
  final int maxScrollbackLines;

  /// Terminal color scheme polarity (`dark` or `light`) for query responses.
  final TerminalBrightness colorScheme;

  /// Optional Google Cloud service account email used to sign IAP bearer JWTs.
  final String? iapServiceAccount;

  /// Optional path to a Google Cloud service account JSON key file (`RS256`).
  final String? iapKeyFilePath;

  /// Pre-parsed service account RSA key when [iapKeyFilePath] is configured.
  final IapServiceAccountKey? iapServiceAccountKey;

  /// Whether to download `Microsoft.Windows.Console.ConPTY` (`conpty.dll` +
  /// `OpenConsole.exe`) on Windows if not already present locally.
  final bool downloadConPty;

  /// Whether browser-to-host file uploads are enabled for this session.
  final bool uploadEnabled;

  /// Optional custom directory path where uploaded files are stored.
  final String? uploadDirPath;

  /// Maximum allowed byte size per uploaded file.
  final int maxUploadBytes;

  /// Whether `SIGHUP` reconnects/re-registers instead of shutting down cleanly.
  final bool keepAliveOnHup;

  /// Non-fatal startup configuration warnings to display to the user.
  final List<String> warnings;

  /// Target executable and arguments to run inside `pty2`.
  final List<String> command;

  /// Creates a validated caster configuration.
  CasterConfig({
    Uri? serverUri,
    this.token = '',
    required this.sessionId,
    required String title,
    this.initialCols = 80,
    this.initialRows = 24,
    this.maxScrollbackLines = defaultScrollbackLines,
    this.colorScheme = .dark,
    String? iapServiceAccount,
    String? iapKeyFilePath,
    IapServiceAccountKey? iapServiceAccountKey,
    this.downloadConPty = false,
    this.uploadEnabled = true,
    String? uploadDirPath,
    this.maxUploadBytes = FileUploadReceiver.defaultMaxUploadBytes,
    this.keepAliveOnHup = false,
    List<String> warnings = const <String>[],
    required List<String> command,
  }) : serverUri = serverUri ?? defaultServerUri,
       title = title.trim(),
       iapServiceAccount = _normalizeOptionalString(iapServiceAccount),
       iapKeyFilePath = _normalizeOptionalString(iapKeyFilePath),
       iapServiceAccountKey =
           iapServiceAccountKey ??
           _parseKeyFileAtBoundary(
             serverUri ?? defaultServerUri,
             _normalizeOptionalString(iapServiceAccount),
             _normalizeOptionalString(iapKeyFilePath),
           ),
       uploadDirPath = _normalizeOptionalString(uploadDirPath),
       warnings = List<String>.unmodifiable(warnings),
       command = List<String>.unmodifiable(command) {
    _validate();
  }

  static String? _normalizeOptionalString(String? raw) {
    final trimmed = raw?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  static IapServiceAccountKey? _parseKeyFileAtBoundary(
    Uri resolvedServerUri,
    String? normalizedIapAccount,
    String? normalizedKeyPath,
  ) {
    if (normalizedKeyPath == null) return null;
    if (normalizedIapAccount != null) {
      throw const FormatException(
        'Cannot specify both --iap-service-account and --iap-key-file.',
      );
    }
    if (resolvedServerUri.scheme != 'wss') {
      throw const FormatException(
        '--iap-key-file requires a wss:// server URI.',
      );
    }
    return IapServiceAccountKey.fromFileSync(normalizedKeyPath);
  }

  void _validate() {
    if ((serverUri.scheme != 'ws' && serverUri.scheme != 'wss') ||
        serverUri.host.isEmpty) {
      throw FormatException(
        'Expected ws:// or wss:// URL with a non-empty host, got "$serverUri".',
      );
    }
    if (serverUri.userInfo.isNotEmpty) {
      throw const FormatException(
        'Relay server URI must not contain userInfo credentials.',
      );
    }
    if (command.isEmpty || command.first.trim().isEmpty) {
      throw const FormatException('Target command after -- is required.');
    }
    if (!sessionId.isValid) {
      throw FormatException('Invalid session ID: "${sessionId.value}".');
    }
    _validateTextAndBounds();
    _validateSecurityOptions();
  }

  void _validateTextAndBounds() {
    BufferFrameCodec.validateTitle(title);
    if (utf8.encode(token).length > 4096) {
      throw const FormatException('Bearer token exceeds 4096 UTF-8 bytes.');
    }
    if (initialCols <= 0 ||
        initialCols > BufferFrameCodec.maxGridCols ||
        initialRows <= 0 ||
        initialRows > BufferFrameCodec.maxGridRows) {
      throw FormatException(
        'Initial dimensions out of range: ${initialCols}x$initialRows.',
      );
    }
    if (maxScrollbackLines < 0 ||
        maxScrollbackLines > maxScrollbackLinesLimit) {
      throw FormatException(
        '--scrollback-lines must be between 0 and $maxScrollbackLinesLimit, got $maxScrollbackLines.',
      );
    }
    if (maxUploadBytes < 0) {
      throw FormatException(
        '--max-upload-bytes must be non-negative, got $maxUploadBytes.',
      );
    }
  }

  void _validateSecurityOptions() {
    final iapAccount = iapServiceAccount;
    if (iapAccount != null && iapServiceAccountKey != null) {
      throw const FormatException(
        'Cannot specify both --iap-service-account and --iap-key-file.',
      );
    }
    if (iapAccount != null) {
      if (serverUri.scheme != 'wss') {
        throw const FormatException(
          '--iap-service-account requires a wss:// server URI.',
        );
      }
      if (!TokenAuthenticator.isValidServiceAccountEmail(iapAccount)) {
        throw FormatException(
          'Invalid --iap-service-account email: "$iapAccount".',
        );
      }
    }
    if (iapServiceAccountKey != null && serverUri.scheme != 'wss') {
      throw const FormatException(
        '--iap-key-file requires a wss:// server URI.',
      );
    }
  }

  /// Builds the CLI `ArgParser` for `termui_cast`.
  static ArgParser buildArgParser() {
    return ArgParser(allowTrailingOptions: false)
      ..addOption(
        'server',
        defaultsTo: 'ws://127.0.0.1:8420/v1/caster',
        help:
            'Relay server WebSocket URL (ws:// or wss://, or \$TERMUI_CAST_SERVER_URL).',
      )
      ..addOption(
        'token',
        defaultsTo: '',
        help:
            'Bearer token sent in initial binary AuthFrame (prefer \$TERMUI_CAST_CASTER_TOKEN or --token-file).',
      )
      ..addOption(
        'token-file',
        help:
            'Path to a UTF-8 file containing the caster bearer token (or \$TERMUI_CAST_CASTER_TOKEN_FILE).',
      )
      ..addOption('session-id', help: 'Explicit unique session identifier.')
      ..addOption('title', help: 'Tab label displayed in viewer clients.')
      ..addOption('cols', defaultsTo: '80', help: 'Initial PTY column width.')
      ..addOption('rows', defaultsTo: '24', help: 'Initial PTY row height.')
      ..addOption(
        'scrollback-lines',
        defaultsTo: '$defaultScrollbackLines',
        help:
            'Primary-screen scrollback lines retained in caster memory (0 to disable, 0..$maxScrollbackLinesLimit, or \$TERMUI_CAST_SCROLLBACK_LINES).',
      )
      ..addOption(
        'color-scheme',
        defaultsTo: 'dark',
        help:
            'Terminal color scheme polarity for query responses (dark or light, or \$TERMUI_CAST_COLOR_SCHEME).',
      )
      ..addOption(
        'iap-service-account',
        help:
            'GCP service account email for signing Cloud Run IAP bearer JWTs (or \$TERMUI_CAST_IAP_SERVICE_ACCOUNT).',
      )
      ..addOption(
        'iap-key-file',
        help:
            'Path to a GCP service account JSON key file for local RS256 IAP signing without gcloud (or \$TERMUI_CAST_IAP_KEY_FILE).',
      )
      ..addFlag(
        'download-conpty',
        help:
            'Download Microsoft ConPTY (conpty.dll + OpenConsole.exe) on Windows if not already cached locally (or \$TERMUI_CAST_DOWNLOAD_CONPTY).',
      )
      ..addFlag(
        'keep-alive-on-hup',
        help:
            'Reconnect and re-register on SIGHUP instead of shutting down cleanly (or \$TERMUI_CAST_KEEP_ALIVE_ON_HUP).',
      )
      ..addFlag(
        'upload',
        defaultsTo: true,
        help:
            'Allow browser drag-and-drop file uploads into this session (or \$TERMUI_CAST_UPLOAD).',
      )
      ..addOption(
        'upload-dir',
        help:
            'Destination directory for browser file uploads (or \$TERMUI_CAST_UPLOAD_DIR).',
      )
      ..addOption(
        'max-upload-bytes',
        defaultsTo: '${FileUploadReceiver.defaultMaxUploadBytes}',
        help:
            'Maximum size in bytes per uploaded file (or \$TERMUI_CAST_MAX_UPLOAD_BYTES).',
      )
      ..addFlag(
        'help',
        abbr: 'h',
        negatable: false,
        help: 'Show CLI usage instructions.',
      );
  }

  /// Parses CLI [args] once at startup, returning `null` on `--help`.
  static CasterConfig? fromArgs(
    List<String> args, {
    SessionId? defaultSessionId,
    Clock clock = const Clock(),
    Map<String, String> environment = const <String, String>{},
  }) {
    final results = buildArgParser().parse(args);
    if (results['help'] as bool) return null;

    final command = results.rest;
    if (command.isEmpty) {
      throw const FormatException(
        'Missing command to cast (pass `-- <executable> [args...]`).',
      );
    }
    final cols = _parseIntOption(
      results,
      'cols',
      null,
      '--cols and --rows must be valid integers.',
    );
    final rows = _parseIntOption(
      results,
      'rows',
      null,
      '--cols and --rows must be valid integers.',
    );
    final maxScrollbackLines = _parseIntOption(
      results,
      'scrollback-lines',
      environment['TERMUI_CAST_SCROLLBACK_LINES'],
      '--scrollback-lines must be a valid integer.',
    );
    final rawColorScheme = _resolveOption(
      results,
      'color-scheme',
      environment['TERMUI_CAST_COLOR_SCHEME'],
    );
    final TerminalBrightness colorScheme = switch (rawColorScheme
        .trim()
        .toLowerCase()) {
      'light' => .light,
      'dark' => .dark,
      final invalid => throw FormatException(
        'Invalid --color-scheme "$invalid", expected "dark" or "light".',
      ),
    };
    final rawServer = _resolveOption(
      results,
      'server',
      environment['TERMUI_CAST_SERVER_URL'],
    );
    final warnings = <String>[];
    final rawToken = _resolveCasterToken(results, environment, warnings);
    final parsedUri = parseCastWebSocketUri(
      rawServer,
      defaultPath: '/v1/caster',
    );
    final (iapAccount, iapKeyFile) = _resolveIapOptions(
      results,
      parsedUri,
      environment,
    );
    final sessionId = _resolveSessionId(
      results['session-id'] as String?,
      defaultSessionId,
      clock,
    );
    final rawTitle = results['title'] as String?;
    final title = (rawTitle != null && rawTitle.trim().isNotEmpty)
        ? rawTitle
        : _executableDisplayName(command.first);
    final downloadConPty = _resolveFlag(
      results,
      'download-conpty',
      'TERMUI_CAST_DOWNLOAD_CONPTY',
      environment['TERMUI_CAST_DOWNLOAD_CONPTY'],
    );
    final keepAliveOnHup = _resolveFlag(
      results,
      'keep-alive-on-hup',
      'TERMUI_CAST_KEEP_ALIVE_ON_HUP',
      environment['TERMUI_CAST_KEEP_ALIVE_ON_HUP'],
    );
    final uploadEnabled = _resolveFlag(
      results,
      'upload',
      'TERMUI_CAST_UPLOAD',
      environment['TERMUI_CAST_UPLOAD'],
      defaultValue: true,
    );
    final uploadDirPath =
        (results['upload-dir'] as String?) ??
        environment['TERMUI_CAST_UPLOAD_DIR'];
    final maxUploadBytes = _parseIntOption(
      results,
      'max-upload-bytes',
      environment['TERMUI_CAST_MAX_UPLOAD_BYTES'],
      '--max-upload-bytes must be a valid integer.',
    );

    return CasterConfig(
      serverUri: parsedUri,
      token: rawToken,
      sessionId: sessionId,
      title: title,
      initialCols: cols,
      initialRows: rows,
      maxScrollbackLines: maxScrollbackLines,
      colorScheme: colorScheme,
      iapServiceAccount: iapAccount,
      iapKeyFilePath: iapKeyFile,
      downloadConPty: downloadConPty,
      keepAliveOnHup: keepAliveOnHup,
      uploadEnabled: uploadEnabled,
      uploadDirPath: uploadDirPath,
      maxUploadBytes: maxUploadBytes,
      warnings: warnings,
      command: command,
    );
  }

  /// Creates an [IapJwtSigner] for this config, or `null` when IAP is unconfigured.
  IapJwtSigner? createIapSigner() {
    if (iapServiceAccount == null && iapServiceAccountKey == null) return null;
    return IapJwtSigner(
      serviceAccount: iapServiceAccount,
      serviceAccountKey: iapServiceAccountKey,
      targetAudienceUrl: TokenAuthenticator.iapAudienceForWebSocketUri(
        serverUri,
      ),
    );
  }

  static String _resolveCasterToken(
    ArgResults results,
    Map<String, String> environment,
    List<String> warnings,
  ) {
    final cliHasToken = results.wasParsed('token');
    final cliHasTokenFile = results.wasParsed('token-file');
    if (cliHasToken && cliHasTokenFile) {
      throw const FormatException(
        'Cannot specify both --token and --token-file.',
      );
    }
    if (cliHasToken) {
      final token = results['token'] as String;
      if (token.isNotEmpty) {
        warnings.add(
          '--token exposes the bearer token on process argv; prefer TERMUI_CAST_CASTER_TOKEN or --token-file.',
        );
      }
      return token;
    }
    if (cliHasTokenFile) {
      return _readTokenFile((results['token-file'] as String).trim());
    }
    final envToken = environment['TERMUI_CAST_CASTER_TOKEN'];
    final envTokenFile = environment['TERMUI_CAST_CASTER_TOKEN_FILE']?.trim();
    if (envToken != null &&
        envToken.isNotEmpty &&
        envTokenFile != null &&
        envTokenFile.isNotEmpty) {
      throw const FormatException(
        'Cannot specify both TERMUI_CAST_CASTER_TOKEN and TERMUI_CAST_CASTER_TOKEN_FILE.',
      );
    }
    if (envToken != null && envToken.trim().isNotEmpty) {
      return envToken.trim();
    }
    if (envTokenFile != null && envTokenFile.isNotEmpty) {
      return _readTokenFile(envTokenFile);
    }
    return '';
  }

  static String _readTokenFile(String path) {
    if (path.isEmpty) {
      throw const FormatException('--token-file path must not be empty.');
    }
    try {
      return File(path).readAsStringSync().trim();
    } on FileSystemException catch (e) {
      throw FormatException('Failed to read token file "$path": ${e.message}');
    }
  }

  static bool _resolveFlag(
    ArgResults results,
    String flagName,
    String envName,
    String? envValue, {
    bool defaultValue = false,
  }) {
    if (results.wasParsed(flagName)) {
      return results[flagName] as bool;
    }
    return switch (envValue?.trim().toLowerCase()) {
      null || '' => defaultValue,
      '0' || 'false' || 'no' => false,
      '1' || 'true' || 'yes' => true,
      final invalid => throw FormatException(
        'Invalid boolean value "$invalid" for $envName.',
      ),
    };
  }

  static int _parseIntOption(
    ArgResults results,
    String optionName,
    String? envValue,
    String errorMessage,
  ) {
    final value = int.tryParse(_resolveOption(results, optionName, envValue));
    if (value == null) throw FormatException(errorMessage);
    return value;
  }

  static (String?, String?) _resolveIapOptions(
    ArgResults results,
    Uri parsedUri,
    Map<String, String> environment,
  ) {
    final cliIapAccount = results['iap-service-account'] as String?;
    final cliIapKeyFile = results['iap-key-file'] as String?;
    final useEnvIap =
        parsedUri.scheme == 'wss' &&
        !results.wasParsed('iap-service-account') &&
        !results.wasParsed('iap-key-file');
    return (
      cliIapAccount ??
          (useEnvIap ? environment['TERMUI_CAST_IAP_SERVICE_ACCOUNT'] : null),
      cliIapKeyFile ??
          (useEnvIap ? environment['TERMUI_CAST_IAP_KEY_FILE'] : null),
    );
  }

  static SessionId _resolveSessionId(
    String? rawSessionId,
    SessionId? defaultSessionId,
    Clock clock,
  ) {
    if (rawSessionId != null && rawSessionId.isNotEmpty) {
      return SessionId(rawSessionId);
    }
    return defaultSessionId ??
        SessionId('cast-${clock.now().microsecondsSinceEpoch}');
  }

  static String _resolveOption(
    ArgResults results,
    String optionName,
    String? envValue,
  ) {
    final cliValue = results[optionName] as String;
    if (!results.wasParsed(optionName) &&
        envValue != null &&
        envValue.trim().isNotEmpty) {
      return envValue.trim();
    }
    return cliValue;
  }

  static String _executableDisplayName(String executable) {
    final slash = max(
      executable.lastIndexOf('/'),
      executable.lastIndexOf(r'\'),
    );
    return slash >= 0 && slash + 1 < executable.length
        ? executable.substring(slash + 1)
        : executable;
  }
}

/// Service bridging a local [PtySession] and [AuthoritativeTerminal] to the relay server.
final class CasterService {
  /// Validated caster configuration.
  final CasterConfig config;

  /// Spawned pseudo-terminal session.
  final PtySession pty;

  /// Authoritative terminal emulator and diff engine.
  final AuthoritativeTerminal terminal;

  /// Connection lifecycle state machine.
  final CasterConnectionMachine stateMachine;

  /// Optional diagnostic log callback for server errors and transport faults.
  final void Function(String message)? onLog;

  /// Maximum duration allowed for `AuthAcceptedFrame` after sending `AuthFrame`.
  final Duration authTimeout;

  /// Maximum queued outbound control/scrollback/upload frames while the uplink is paused.
  final int maxOutboundFrames;

  /// Maximum queued outbound bytes while the uplink is paused.
  final int maxOutboundBytes;

  late final ChannelOpener _channelOpener;
  late final RevisionProber? _revisionProber;
  final Duration _revisionPollInterval;
  final Duration _uploadIdleTimeout;
  final Duration _frameCoalesceInterval;
  final Duration _ptyKillTimeout;
  final FileUploadReceiver _uploadReceiver;
  final Uint8List _resumeToken;
  final bool _isWindows;
  final Completer<int> _doneCompleter = Completer<int>();
  final Completer<void> _ptyOutputDone = Completer<void>();
  final Queue<Uint8List> _outboundQueue = Queue<Uint8List>();

  final PtyRouterSession? _routerSession;
  final String _remoteEndpointId;
  final String _initialTitle;
  final Clock? _clockOverride;
  String _shellTitle = '';
  String? _pinnedTitle;
  String _sessionTitle;
  ({int cols, int rows})? _lastRemoteViewport;
  Future<void> Function()? _cancelPtySub;
  StreamSubscription<Uint8List>? _channelSub;
  StreamChannel<Uint8List>? _activeChannel;
  StreamController<Uint8List>? _outboundController;
  AbortableByteStream? _outboundStream;
  Future<void>? _outboundPumpFuture;
  Completer<void>? _outboundDrainCompleter;
  int _outboundQueuedBytes = 0;
  bool _drainingOutbound = false;
  Timer? _authTimer;
  Timer? _coalesceTimer;
  Timer? _syncOutputTimeoutTimer;
  Timer? _shellTitleTimer;
  bool _pendingShellTitle = false;
  DateTime? _lastBellSentAt;
  Timer? _reconnectTimer;
  Timer? _revisionTimer;
  Timer? _uploadIdleTimer;
  static const Duration _maxSyncOutputHold = Duration(milliseconds: 150);
  static const Duration _shellTitleCoalesceInterval = Duration(
    milliseconds: 150,
  );
  static const Duration _bellRateLimitInterval = Duration(milliseconds: 75);
  static const int _maxReplyCharsPerChunk = 1024;
  static const int _maxReplyBufferChars = 64 * 1024;
  static const int _maxPendingWaveformQueries = 16;
  static const Duration _drainTimeout = Duration(milliseconds: 500);
  final StringBuffer _replyBuffer = StringBuffer();
  final Queue<String> _overflowReplies = Queue<String>();
  int _overflowReplyChars = 0;
  Timer? _replyDrainTimer;
  String? _connectedRevision;
  bool _baselineProbeCompleted = false;
  bool _revisionProbeInFlight = false;
  bool _revisionProbePending = false;
  bool _revisionReconnectDeferred = false;
  String? _pendingClipboardText;
  bool _pendingClipboardReadBlocked = false;
  int _subscriberCount = 0;
  bool _registrationConfirmed = false;
  final Queue<int> _pendingWaveformReqIds = Queue<int>();
  Future<void> _uploadSerial = Future<void>.value();
  int _pendingUploadTasks = 0;
  final StreamController<CasterStatusSnapshot> _statusController =
      StreamController<CasterStatusSnapshot>.broadcast();
  CasterStatusSnapshot? _lastEmittedStatus;
  String? _lastError;
  int _connectEpoch = 0;
  ({StreamChannel<Uint8List> channel, StreamSubscription<Uint8List>? sub})?
  _retiredConnection;
  Timer? _retireTimer;
  bool _started = false;
  bool _stopping = false;
  bool _finishing = false;

  /// Creates a caster service owning a standalone [pty] and [AuthoritativeTerminal].
  CasterService({
    required CasterConfig config,
    required PtySession pty,
    ChannelOpener? channelOpener,
    IapTokenProvider? iapTokenProvider,
    RevisionProber? revisionProber,
    Duration revisionPollInterval = const Duration(seconds: 60),
    Duration uploadIdleTimeout = const Duration(seconds: 30),
    Duration ptyKillTimeout = const Duration(seconds: 2),
    int maxOutboundFrames = 64,
    int maxOutboundBytes = 8 * 1024 * 1024,
    Uint8List? resumeToken,
    Random? random,
    Clock? clock,
    bool? isWindows,
    void Function(String message)? onLog,
    Duration authTimeout = const Duration(seconds: 5),
    Duration frameCoalesceInterval = const Duration(milliseconds: 16),
    Duration baseReconnectDelay = const Duration(milliseconds: 200),
  }) : this._(
         config: config,
         pty: pty,
         terminal: AuthoritativeTerminal(
           sessionId: config.sessionId,
           initialCols: config.initialCols,
           initialRows: config.initialRows,
           maxScrollbackLines: config.maxScrollbackLines,
           initialTheme: config.colorScheme == .light
               ? TerminalColorTheme.termuiLight
               : TerminalColorTheme.termuiDark,
           onLog: onLog,
         ),
         routerSession: null,
         remoteEndpointId: 'cast:${config.sessionId.value}',
         channelOpener: channelOpener,
         iapTokenProvider: iapTokenProvider,
         revisionProber: revisionProber,
         revisionPollInterval: revisionPollInterval,
         uploadIdleTimeout: uploadIdleTimeout,
         ptyKillTimeout: ptyKillTimeout,
         maxOutboundFrames: maxOutboundFrames,
         maxOutboundBytes: maxOutboundBytes,
         resumeToken: resumeToken,
         random: random,
         clock: clock,
         isWindows: isWindows,
         onLog: onLog,
         authTimeout: authTimeout,
         frameCoalesceInterval: frameCoalesceInterval,
         baseReconnectDelay: baseReconnectDelay,
       );

  /// Creates a caster service sharing an existing in-process [PtyRouterSession].
  ///
  /// Wraps `session.terminal` without taking ownership of disposal or `onReply`,
  /// registers a remote viewport endpoint only while `subscriberCount > 0`, and
  /// releases it when all remote viewers disconnect.
  factory CasterService.fromRouterSession({
    required CasterConfig config,
    required PtyRouterSession session,
    String? remoteEndpointId,
    ChannelOpener? channelOpener,
    IapTokenProvider? iapTokenProvider,
    RevisionProber? revisionProber,
    Duration revisionPollInterval = const Duration(seconds: 60),
    Duration uploadIdleTimeout = const Duration(seconds: 30),
    Duration ptyKillTimeout = const Duration(seconds: 2),
    int maxOutboundFrames = 64,
    int maxOutboundBytes = 8 * 1024 * 1024,
    Uint8List? resumeToken,
    Random? random,
    Clock? clock,
    bool? isWindows,
    void Function(String message)? onLog,
    Duration authTimeout = const Duration(seconds: 5),
    Duration frameCoalesceInterval = const Duration(milliseconds: 16),
    Duration baseReconnectDelay = const Duration(milliseconds: 200),
  }) {
    final endpointId = remoteEndpointId ?? 'cast:${config.sessionId.value}';
    return CasterService._(
      config: config,
      pty: _RouterSessionPtyAdapter(session, endpointId),
      terminal: AuthoritativeTerminal.wrapping(
        session.terminal,
        sessionId: config.sessionId,
        wireTerminalHooks: false,
        onLog: onLog,
      ),
      routerSession: session,
      remoteEndpointId: endpointId,
      channelOpener: channelOpener,
      iapTokenProvider: iapTokenProvider,
      revisionProber: revisionProber,
      revisionPollInterval: revisionPollInterval,
      uploadIdleTimeout: uploadIdleTimeout,
      ptyKillTimeout: ptyKillTimeout,
      maxOutboundFrames: maxOutboundFrames,
      maxOutboundBytes: maxOutboundBytes,
      resumeToken: resumeToken,
      random: random,
      clock: clock,
      isWindows: isWindows,
      onLog: onLog,
      authTimeout: authTimeout,
      frameCoalesceInterval: frameCoalesceInterval,
      baseReconnectDelay: baseReconnectDelay,
    );
  }

  CasterService._({
    required this.config,
    required this.pty,
    required this.terminal,
    required PtyRouterSession? routerSession,
    required String remoteEndpointId,
    ChannelOpener? channelOpener,
    IapTokenProvider? iapTokenProvider,
    RevisionProber? revisionProber,
    required Duration revisionPollInterval,
    required Duration uploadIdleTimeout,
    required Duration ptyKillTimeout,
    required this.maxOutboundFrames,
    required this.maxOutboundBytes,
    Uint8List? resumeToken,
    Random? random,
    Clock? clock,
    bool? isWindows,
    this.onLog,
    required this.authTimeout,
    required Duration frameCoalesceInterval,
    required Duration baseReconnectDelay,
  }) : _routerSession = routerSession,
       _remoteEndpointId = remoteEndpointId,
       _initialTitle = config.title,
       _clockOverride = clock,
       _sessionTitle = config.title,
       stateMachine = CasterConnectionMachine(
         random: random,
         baseDelay: baseReconnectDelay,
       ),
       _uploadReceiver = FileUploadReceiver(
         sessionId: config.sessionId,
         uploadDir: config.uploadDirPath == null
             ? null
             : Directory(config.uploadDirPath!),
         enabled: config.uploadEnabled,
         maxUploadBytes: config.maxUploadBytes,
       ),
       _resumeToken = _resolveResumeToken(resumeToken),
       _isWindows = isWindows ?? Platform.isWindows,
       _revisionPollInterval = revisionPollInterval,
       _uploadIdleTimeout = uploadIdleTimeout,
       _ptyKillTimeout = ptyKillTimeout,
       _frameCoalesceInterval = frameCoalesceInterval {
    final resolvedTokenProvider = _resolveTokenProvider(
      config,
      iapTokenProvider,
    );
    _channelOpener =
        channelOpener ??
        _buildDefaultChannelOpener(config, resolvedTokenProvider);
    _revisionProber =
        revisionProber ??
        (channelOpener == null
            ? _buildDefaultRevisionProber(config, resolvedTokenProvider)
            : null);
    if (routerSession != null) {
      _shellTitle = sanitizeShellTitle(routerSession.terminal.windowTitle);
      if (_shellTitle.isNotEmpty) {
        _sessionTitle = _shellTitle;
      }
    } else {
      terminal.onClipboardFrame = _onClipboardFrame;
      terminal.onTerminalReply = _onTerminalReply;
    }
  }

  String get _effectiveShellTitle =>
      _shellTitle.isNotEmpty ? _shellTitle : _initialTitle;

  Clock get _clock => _clockOverride ?? clock;

  static Uint8List _resolveResumeToken(Uint8List? explicitToken) {
    if (explicitToken != null) {
      return _copyValidatedResumeToken(explicitToken);
    }
    final rng = Random.secure();
    final generated = Uint8List(RegisterSessionFrame.resumeTokenByteLength);
    var nonZero = 0;
    for (var i = 0; i < generated.length; i++) {
      final byte = rng.nextInt(256);
      generated[i] = byte;
      nonZero |= byte;
    }
    if (nonZero == 0) {
      generated[0] = 1; // coverage:ignore-line
    }
    return generated;
  }

  static Uint8List _copyValidatedResumeToken(Uint8List explicitToken) {
    if (explicitToken.length != RegisterSessionFrame.resumeTokenByteLength) {
      throw ArgumentError.value(
        explicitToken.length,
        'resumeToken.length',
        'Must be ${RegisterSessionFrame.resumeTokenByteLength} bytes.',
      );
    }
    var nonZero = 0;
    for (final byte in explicitToken) {
      nonZero |= byte;
    }
    if (nonZero == 0) {
      throw ArgumentError.value(
        explicitToken,
        'resumeToken',
        'Must contain at least one non-zero byte.',
      );
    }
    return Uint8List.fromList(explicitToken);
  }

  static IapTokenProvider? _resolveTokenProvider(
    CasterConfig config,
    IapTokenProvider? customIapProvider,
  ) {
    if (customIapProvider != null) return customIapProvider;
    return config.createIapSigner()?.getBearerToken;
  }

  static ChannelOpener _buildDefaultChannelOpener(
    CasterConfig config,
    IapTokenProvider? tokenProvider,
  ) {
    return () async {
      Map<String, Object>? headers;
      if (tokenProvider != null) {
        final bearer = await tokenProvider().timeout(
          const Duration(seconds: 10),
        );
        headers = <String, Object>{'Authorization': 'Bearer $bearer'};
      }
      return connectCastWebSocket(config.serverUri, headers: headers);
    };
  }

  static RevisionProber _buildDefaultRevisionProber(
    CasterConfig config,
    IapTokenProvider? tokenProvider,
  ) {
    final probeScheme = config.serverUri.scheme == 'wss' ? 'https' : 'http';
    final probeUri = Uri(
      scheme: probeScheme,
      host: config.serverUri.host,
      port: config.serverUri.hasPort ? config.serverUri.port : null,
      path: config.serverUri.path.isEmpty ? '/' : config.serverUri.path,
    );
    return () => _probeRevisionOverHttp(probeUri, tokenProvider: tokenProvider);
  }

  static Future<String?> _probeRevisionOverHttp(
    Uri probeUri, {
    required IapTokenProvider? tokenProvider,
  }) async {
    HttpClient? client;
    try {
      final bearer = tokenProvider == null
          ? null
          : await tokenProvider().timeout(const Duration(seconds: 5));
      final activeClient = HttpClient();
      client = activeClient;
      activeClient.connectionTimeout = const Duration(seconds: 5);
      return await _executeRevisionHeadRequest(
        activeClient,
        probeUri,
        bearer,
      ).timeout(const Duration(seconds: 5));
    } on Object {
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  static Future<String?> _executeRevisionHeadRequest(
    HttpClient client,
    Uri probeUri,
    String? bearer,
  ) async {
    final request = await client.openUrl('HEAD', probeUri);
    request.followRedirects = false;
    request.persistentConnection = false;
    if (bearer != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    }
    final response = await request.close();
    await response.drain<void>();
    if (response.statusCode != HttpStatus.ok) return null;
    final rawRevision = response.headers.value(castRevisionHeader)?.trim();
    return (rawRevision == null || rawRevision.isEmpty) ? null : rawRevision;
  }

  void _onClipboardFrame(ClipboardFrame frame) {
    if (_stopping ||
        stateMachine.state != .streaming ||
        _subscriberCount <= 0 ||
        _activeChannel == null) {
      return;
    }
    if (frame.readBlocked) {
      _pendingClipboardReadBlocked = true;
    } else if (frame.text.isNotEmpty) {
      _pendingClipboardText = frame.text;
    } else {
      return;
    }
    _scheduleDirtyFlushIfSubscribed();
  }

  void _onTerminalReply(String reply) {
    if (_stopping || _ptyOutputDone.isCompleted || reply.isEmpty) return;
    if (_overflowReplies.isEmpty &&
        _replyBuffer.length + reply.length <= _maxReplyCharsPerChunk) {
      _replyBuffer.write(reply);
      return;
    }
    if (_replyBuffer.length + _overflowReplyChars + reply.length <=
        _maxReplyBufferChars) {
      _overflowReplies.addLast(reply);
      _overflowReplyChars += reply.length;
    }
  }

  void _flushPendingReplies() {
    if (_replyBuffer.isNotEmpty) {
      final combined = '$_replyBuffer';
      _replyBuffer.clear();
      if (!_stopping && !_ptyOutputDone.isCompleted) {
        pty.writeBytes(utf8.encode(combined));
      }
    }
    if (_overflowReplies.isNotEmpty &&
        !_stopping &&
        !_ptyOutputDone.isCompleted) {
      _replyDrainTimer ??= Timer(Duration.zero, _drainOverflowReplies);
    }
  }

  void _drainOverflowReplies() {
    _replyDrainTimer = null;
    if (_stopping || _ptyOutputDone.isCompleted || _overflowReplies.isEmpty) {
      _overflowReplies.clear();
      _overflowReplyChars = 0;
      return;
    }
    final batch = StringBuffer();
    while (_overflowReplies.isNotEmpty) {
      final next = _overflowReplies.first;
      if (batch.isNotEmpty &&
          batch.length + next.length > _maxReplyCharsPerChunk) {
        break;
      }
      _overflowReplies.removeFirst();
      _overflowReplyChars -= next.length;
      batch.write(next);
      if (batch.length >= _maxReplyCharsPerChunk) break;
    }
    if (batch.isNotEmpty) {
      pty.writeBytes(utf8.encode('$batch'));
    }
    if (_overflowReplies.isNotEmpty) {
      _replyDrainTimer ??= Timer(Duration.zero, _drainOverflowReplies);
    }
  }

  void _cancelFrameTimers({bool clearPendingTitle = false}) {
    _coalesceTimer?.cancel();
    _coalesceTimer = null;
    _syncOutputTimeoutTimer?.cancel();
    _syncOutputTimeoutTimer = null;
    _shellTitleTimer?.cancel();
    _shellTitleTimer = null;
    if (clearPendingTitle) {
      _pendingShellTitle = false;
    }
  }

  /// Completes with the child process exit code once casting finishes.
  Future<int> get done => _doneCompleter.future;

  /// Broadcast stream of caster lifecycle, viewer count, title, and error updates.
  Stream<CasterStatusSnapshot> get statusStream => _statusController.stream;

  /// Current immutable status snapshot for in-process UI callers.
  CasterStatusSnapshot get currentStatus => CasterStatusSnapshot(
    state: stateMachine.state,
    subscriberCount: _subscriberCount,
    title: _sessionTitle,
    lastError: _lastError,
  );

  void _emitStatus() {
    if (_statusController.isClosed) return;
    final next = currentStatus;
    if (next == _lastEmittedStatus) return;
    _lastEmittedStatus = next;
    _statusController.add(next);
  }

  /// Current active viewer count reported by the relay server.
  int get subscriberCount => _subscriberCount;

  /// Current session display title (updated by inbound [RenameSessionFrame]s).
  String get currentTitle => _sessionTitle;

  /// Copy of this caster instance's 16-byte session resume token.
  Uint8List get resumeToken => Uint8List.fromList(_resumeToken);

  bool _isStaleEpoch(int epoch) => _stopping || _connectEpoch != epoch;

  bool _isActiveChannel(StreamChannel<Uint8List> channel) =>
      !_stopping && identical(_activeChannel, channel);

  /// Starts capturing PTY output and connecting to the relay server.
  Future<void> start() async {
    if (_started || _stopping) return;
    _started = true;
    final epoch = ++_connectEpoch;
    onLog?.call(
      'Started "${config.command.join(' ')}" (session: ${config.sessionId.value}, title: "${config.title}", ${terminal.cols}x${terminal.rows})',
    );
    _attachTerminalEventHooks();
    if (_routerSession != null) {
      unawaited(_awaitRouterExit());
    } else {
      _listenStandalonePtyOutput();
      unawaited(_awaitPtyExit());
    }
    await stateMachine.dispatch(.start);
    _emitStatus();
    if (_isStaleEpoch(epoch)) return;
    unawaited(_connectAttempt(epoch));
  }

  void _listenStandalonePtyOutput() {
    if (pty case final Pty2Session pty2) {
      final sub = pty2.textOutput.listen(
        (chunk) {
          _replyBuffer.clear();
          terminal.writeString(chunk);
          _flushPendingReplies();
          _scheduleDirtyFlushIfSubscribed();
        },
        onDone: _completePtyOutput,
        onError: (Object _) => _completePtyOutput(),
      );
      _cancelPtySub = sub.cancel;
      return;
    }
    final sub = pty.output.listen(
      (chunk) {
        _replyBuffer.clear();
        terminal.writeOutput(chunk);
        _flushPendingReplies();
        _scheduleDirtyFlushIfSubscribed();
      },
      onDone: _completePtyOutput,
      onError: (Object _) => _completePtyOutput(),
    );
    _cancelPtySub = sub.cancel;
  }

  void _attachTerminalEventHooks() {
    final router = _routerSession;
    if (router != null) {
      router
        ..addListener(_onRouterTerminalChanged)
        ..addTitleListener(_onShellTitle)
        ..addBellListener(_onBell)
        ..addAudioListener(_onAudioEvent)
        ..addClipboardListener(_onRouterClipboardWrite)
        ..addClipboardBlockedListener(_onRouterClipboardBlocked);
      return;
    }
    terminal
      ..addTitleListener(_onShellTitle)
      ..addBellListener(_onBell)
      ..addAudioListener(_onAudioEvent);
  }

  void _detachTerminalEventHooks() {
    final router = _routerSession;
    if (router != null) {
      router
        ..removeListener(_onRouterTerminalChanged)
        ..removeTitleListener(_onShellTitle)
        ..removeBellListener(_onBell)
        ..removeAudioListener(_onAudioEvent)
        ..removeClipboardListener(_onRouterClipboardWrite)
        ..removeClipboardBlockedListener(_onRouterClipboardBlocked)
        ..removeEndpointViewport(_remoteEndpointId);
      return;
    }
    terminal
      ..removeTitleListener(_onShellTitle)
      ..removeBellListener(_onBell)
      ..removeAudioListener(_onAudioEvent);
  }

  void _onRouterTerminalChanged() {
    if (_stopping || _ptyOutputDone.isCompleted) return;
    _scheduleDirtyFlushIfSubscribed();
  }

  void _onRouterClipboardWrite(String selection, String text) {
    if (text.isEmpty) return;
    if (!selection.contains('c') && !selection.contains('p')) return;
    _onClipboardFrame(ClipboardFrame(sessionId: config.sessionId, text: text));
  }

  void _onRouterClipboardBlocked(String _) {
    _onClipboardFrame(
      ClipboardFrame(sessionId: config.sessionId, readBlocked: true),
    );
  }

  void _onShellTitle(String rawTitle) {
    if (_stopping) return;
    final clean = sanitizeShellTitle(rawTitle);
    if (clean == _shellTitle) return;
    _shellTitle = clean;
    if (_pinnedTitle == null) {
      _sessionTitle = _effectiveShellTitle;
    }
    _emitStatus();
    if (stateMachine.state != .streaming || _isOutboundPaused) {
      _pendingShellTitle = true;
      return;
    }
    if (_shellTitleTimer == null) {
      _pendingShellTitle = false;
      _sendFrame(
        ShellTitleFrame(sessionId: config.sessionId, title: clean),
        droppable: true,
      );
      _shellTitleTimer = Timer(
        _shellTitleCoalesceInterval,
        _onShellTitleCooldownDone,
      );
    } else {
      _pendingShellTitle = true;
    }
  }

  void _onShellTitleCooldownDone() {
    _shellTitleTimer = null;
    if (_stopping || !_pendingShellTitle) {
      _pendingShellTitle = false;
      return;
    }
    if (stateMachine.state != .streaming || _isOutboundPaused) {
      return;
    }
    _pendingShellTitle = false;
    _sendFrame(
      ShellTitleFrame(sessionId: config.sessionId, title: _shellTitle),
      droppable: true,
    );
    _shellTitleTimer = Timer(
      _shellTitleCoalesceInterval,
      _onShellTitleCooldownDone,
    );
  }

  void _flushPendingShellTitleIfReady() {
    if (_stopping ||
        !_pendingShellTitle ||
        stateMachine.state != .streaming ||
        _isOutboundPaused ||
        _shellTitleTimer != null) {
      return;
    }
    _pendingShellTitle = false;
    _sendFrame(
      ShellTitleFrame(sessionId: config.sessionId, title: _shellTitle),
      droppable: true,
    );
    _shellTitleTimer = Timer(
      _shellTitleCoalesceInterval,
      _onShellTitleCooldownDone,
    );
  }

  void _onBell() {
    if (_stopping ||
        stateMachine.state != .streaming ||
        _subscriberCount <= 0) {
      return;
    }
    final now = _clock.now();
    final last = _lastBellSentAt;
    if (last != null && now.difference(last) < _bellRateLimitInterval) {
      return;
    }
    _lastBellSentAt = now;
    _sendFrame(BellFrame(sessionId: config.sessionId), droppable: true);
  }

  void _onAudioEvent(TerminalAudioEvent event) {
    if (event case TerminalWaveformQueryAudioEvent(:final requestId)) {
      _handleWaveformQueryAudioEvent(requestId);
      return;
    }
    if (_stopping ||
        stateMachine.state != .streaming ||
        _subscriberCount <= 0) {
      return;
    }
    final isControl = _isControlAudioEvent(event);
    if (!isControl) {
      final highWaterFrames = (maxOutboundFrames * 3) ~/ 4;
      final highWaterBytes = (maxOutboundBytes * 3) ~/ 4;
      if ((highWaterFrames > 0 && _outboundQueue.length >= highWaterFrames) ||
          (highWaterBytes > 0 && _outboundQueuedBytes >= highWaterBytes)) {
        return;
      }
    }
    final frame = AudioFrame(
      sessionId: config.sessionId,
      payload: _toCastAudioPayload(event),
    );
    if (isControl && !_canFitControlAudioFrame(frame)) {
      return;
    }
    _sendFrame(frame, droppable: !isControl);
  }

  void _handleWaveformQueryAudioEvent(int requestId) {
    if (_stopping || _finishing || _ptyOutputDone.isCompleted) return;
    if (_subscriberCount <= 0 || stateMachine.state != .streaming) {
      if (_routerSession == null) {
        final empty = AudioApcHandler.encodeWaveformReply(requestId, null);
        pty.writeBytes(Uint8List.fromList(utf8.encode(empty)));
      }
      return;
    }
    final highWaterFrames = (maxOutboundFrames * 3) ~/ 4;
    final highWaterBytes = (maxOutboundBytes * 3) ~/ 4;
    if ((highWaterFrames > 0 && _outboundQueue.length >= highWaterFrames) ||
        (highWaterBytes > 0 && _outboundQueuedBytes >= highWaterBytes)) {
      return;
    }
    while (_pendingWaveformReqIds.length >= _maxPendingWaveformQueries) {
      final dropped = _pendingWaveformReqIds.removeFirst();
      if (_routerSession == null) {
        final empty = AudioApcHandler.encodeWaveformReply(dropped, null);
        pty.writeBytes(Uint8List.fromList(utf8.encode(empty)));
      }
    }
    _pendingWaveformReqIds.addLast(requestId);
    _sendFrame(
      AudioFrame(
        sessionId: config.sessionId,
        payload: CastWaveformQueryAudioPayload(requestId: requestId),
      ),
      droppable: true,
    );
  }

  void _onAudioWaveformReply(
    SessionId sessionId,
    int requestId,
    Float32List samples,
  ) {
    if (sessionId != config.sessionId ||
        !_pendingWaveformReqIds.remove(requestId)) {
      return;
    }
    if (_stopping || _finishing || _ptyOutputDone.isCompleted) return;
    final reply = AudioApcHandler.encodeWaveformReply(requestId, samples);
    pty.writeBytes(Uint8List.fromList(utf8.encode(reply)));
  }

  bool _canFitControlAudioFrame(AudioFrame frame) {
    if (_outboundQueue.length >= maxOutboundFrames) return false;
    try {
      final encoded = BufferFrameCodec.encode(frame);
      return _outboundQueuedBytes + encoded.length <= maxOutboundBytes;
    } on Object {
      return false;
    }
  }

  static bool _isControlAudioEvent(TerminalAudioEvent event) => switch (event) {
    TerminalStopAudioEvent() => true,
    TerminalBusAudioEvent(:final op) =>
      op == 'create' || op == 'destroy' || op == 'attach',
    TerminalStreamAudioEvent(:final op) => op == 'open' || op == 'end',
    TerminalClipAudioEvent(:final streamId) => streamId != null,
    TerminalUpdateAudioEvent(
      :final seekPosition,
      :final paused,
      :final scheduleStopDuration,
    ) =>
      seekPosition != null || paused != null || scheduleStopDuration != null,
    _ => false,
  };

  Future<void> _awaitRouterExit() async {
    final code = await _routerSession!.exitCode;
    if (_stopping || _finishing) return;
    onLog?.call('Child process exited with code $code');
    _completePtyOutput();
    await _finishWithExitCode(code);
  }

  /// Forces an immediate reconnect and session re-registration with the relay
  /// server, canceling any pending backoff timer and resetting retry attempts.
  Future<void> checkIn() async {
    if (!_started || _stopping || stateMachine.state == .terminated) {
      return;
    }
    final epoch = ++_connectEpoch;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    onLog?.call(
      'Check-in requested; reconnecting session "${config.sessionId.value}"',
    );
    await _closeActiveChannel(retire: true);
    if (_isStaleEpoch(epoch)) return;
    final transitioned = await stateMachine.dispatch(.checkIn);
    _emitStatus();
    if (!transitioned || _isStaleEpoch(epoch)) return;
    unawaited(_connectAttempt(epoch));
  }

  void _completePtyOutput() {
    if (!_ptyOutputDone.isCompleted) _ptyOutputDone.complete();
  }

  Future<void> _awaitPtyExit() async {
    final code = await pty.exitCode;
    if (_stopping || _finishing) return;
    onLog?.call('Child process exited with code $code');
    try {
      await _ptyOutputDone.future.timeout(_drainTimeout);
    } on TimeoutException {
      _completePtyOutput();
    }
    await _finishWithExitCode(code);
  }

  Future<void> _connectAttempt(int epoch) async {
    if (_isStaleEpoch(epoch)) return;
    final StreamChannel<Uint8List> channel;
    try {
      channel = await _channelOpener();
    } on Object catch (error) {
      if (_isStaleEpoch(epoch)) return;
      _lastError = '$error';
      onLog?.call('Connection attempt failed: $error');
      await _scheduleReconnect(fromConnectFailure: true, epoch: epoch);
      return;
    }
    if (_isStaleEpoch(epoch)) {
      unawaited(channel.sink.close().catchError((Object _) {}));
      return;
    }
    _activeChannel = channel;
    final outCtrl = StreamController<Uint8List>(
      sync: true,
      onPause: _onOutboundPause,
      onResume: _onOutboundResume,
      onCancel: () async {},
    );
    final outStream = AbortableByteStream(outCtrl.stream);
    _outboundController = outCtrl;
    _outboundStream = outStream;
    _outboundQueue.clear();
    _outboundQueuedBytes = 0;
    _outboundPumpFuture = channel.sink
        .addStream(outStream)
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace _) {
            onLog?.call('Failed to send outbound frame: $error');
          },
        );
    _channelSub = channel.stream.listen(
      (raw) {
        if (!_isActiveChannel(channel)) return;
        _onServerBytes(raw);
      },
      onError: (Object error) {
        if (!_isActiveChannel(channel)) return;
        _lastError = '$error';
        onLog?.call('Transport error: $error');
        unawaited(_scheduleReconnect(epoch: epoch));
      },
      onDone: () {
        if (!_isActiveChannel(channel)) return;
        unawaited(_scheduleReconnect(epoch: epoch));
      },
    );
    _authTimer?.cancel();
    _authTimer = Timer(authTimeout, () {
      _lastError = 'Relay authentication timed out';
      onLog?.call('Relay authentication timed out');
      unawaited(_scheduleReconnect(epoch: epoch));
    });
    _sendFrame(AuthFrame(role: .caster, token: config.token));
  }

  void _onServerBytes(Uint8List raw) {
    final CastMessage msg;
    try {
      msg = BufferFrameCodec.decode(raw);
    } on FormatException catch (error) {
      onLog?.call('Malformed server frame: $error');
      unawaited(_scheduleReconnect());
      return;
    }
    switch (msg) {
      case AuthAcceptedFrame():
        unawaited(_onAuthAccepted());
      case SubscriberCountFrame(:final subscriberCount):
        _onSubscriberCount(subscriberCount);
      case RequestKeyframeFrame():
        _onRequestKeyframe();
      case RequestScrollbackFrame frame:
        _onRequestScrollback(frame);
      case FileUploadStartFrame frame:
        _onFileUploadStart(frame);
      case FileUploadChunkFrame frame:
        _onFileUploadChunk(frame);
      case FileUploadEndFrame frame:
        _onFileUploadEnd(frame);
      case InputFrame(:final data):
        if (!_ptyOutputDone.isCompleted) {
          pty.writeBytes(data);
        }
      case AudioWaveformReplyFrame(
        :final sessionId,
        :final requestId,
        :final samples,
      ):
        _onAudioWaveformReply(sessionId, requestId, samples);
      case ResizeFrame(:final cols, :final rows):
        _onResizeFrame(cols, rows);
      case RenameSessionFrame(:final sessionId, :final title, :final clearPin):
        if (sessionId == config.sessionId) {
          if (clearPin) {
            _pinnedTitle = null;
            _sessionTitle = _effectiveShellTitle;
          } else {
            _pinnedTitle = title;
            _sessionTitle = title;
          }
          _emitStatus();
        }
      case ErrorFrame(:final code, :final message):
        _onErrorFrame(code, message);
      default:
        break;
    }
  }

  Future<void> _onAuthAccepted() async {
    final channel = _activeChannel;
    if (channel == null) return;
    final epoch = _connectEpoch;
    _authTimer?.cancel();
    _authTimer = null;
    final transitioned = await stateMachine.dispatch(.connected);
    if (!transitioned || _isStaleEpoch(epoch) || !_isActiveChannel(channel)) {
      return;
    }
    _lastError = null;
    _registrationConfirmed = false;
    _sendFrame(
      RegisterSessionFrame(
        sessionId: config.sessionId,
        title: _sessionTitle,
        cols: AuthoritativeTerminal.clampCols(terminal.cols),
        rows: AuthoritativeTerminal.clampRows(terminal.rows),
        resumeToken: _resumeToken,
      ),
    );
    if ((_pinnedTitle != null || _pendingShellTitle) &&
        _shellTitle.isNotEmpty) {
      _pendingShellTitle = false;
      _sendFrame(
        ShellTitleFrame(sessionId: config.sessionId, title: _shellTitle),
        droppable: true,
      );
    }
    _emitStatus();
    _closeRetiredConnection();
    final safeUri = Uri(
      scheme: config.serverUri.scheme,
      host: config.serverUri.host,
      port: config.serverUri.hasPort ? config.serverUri.port : null,
      path: config.serverUri.path,
    );
    onLog?.call('Registered session "${config.sessionId.value}" on $safeUri');
    _connectedRevision = null;
    _baselineProbeCompleted = false;
    _revisionProbeInFlight = false;
    _revisionProbePending = false;
    _revisionReconnectDeferred = false;
    _revisionTimer?.cancel();
    _revisionTimer = null;
    if (_revisionProber != null) {
      if (_revisionPollInterval > Duration.zero) {
        _revisionTimer = Timer.periodic(
          _revisionPollInterval,
          (_) => unawaited(_probeServerRevision()),
        );
      }
      unawaited(_probeServerRevision());
    }
  }

  void _onSubscriberCount(int count) {
    final prevCount = _subscriberCount;
    if (count != prevCount) {
      onLog?.call('Active viewers: $count');
    }
    _subscriberCount = count;
    if (!_registrationConfirmed) {
      _registrationConfirmed = true;
      _lastError = null;
      unawaited(stateMachine.dispatch(.registered).then((_) => _emitStatus()));
    } else if (count != prevCount) {
      _emitStatus();
    }
    if (_subscriberCount <= 0) {
      _pendingWaveformReqIds.clear();
      _lastRemoteViewport = null;
      _cancelFrameTimers();
      _clearPendingClipboard();
      _routerSession?.removeEndpointViewport(_remoteEndpointId);
      unawaited(_probeServerRevision());
      return;
    }
    if (prevCount <= 0) {
      final router = _routerSession;
      if (router != null) {
        if (_lastRemoteViewport case (:final cols, :final rows)?) {
          router.setEndpointViewport(
            _remoteEndpointId,
            cols,
            rows,
            isPrimary: false,
          );
        }
      }
      if (stateMachine.state == .streaming && _shellTitle.isNotEmpty) {
        _sendFrame(
          ShellTitleFrame(sessionId: config.sessionId, title: _shellTitle),
          droppable: true,
        );
      }
    }
  }

  Future<void> _probeServerRevision() async {
    final prober = _revisionProber;
    final channelAtStart = _activeChannel;
    if (prober == null || !_isStreamingChannel(channelAtStart)) {
      return;
    }
    if (_revisionProbeInFlight) {
      _revisionProbePending = true;
      return;
    }
    _revisionProbeInFlight = true;
    try {
      final probed = await _runRevisionProberSafely(prober);
      if (!_isStreamingChannel(channelAtStart)) return;
      _applyProbedRevision(probed);
    } finally {
      _completeRevisionProbeTurn(channelAtStart);
    }
  }

  bool _isStreamingChannel(StreamChannel<Uint8List>? expected) =>
      expected != null &&
      !_stopping &&
      identical(_activeChannel, expected) &&
      stateMachine.state == .streaming;

  static Future<String?> _runRevisionProberSafely(RevisionProber prober) async {
    try {
      final raw = await prober().timeout(const Duration(seconds: 12));
      final trimmed = raw?.trim();
      return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    } on Object {
      return null;
    }
  }

  void _applyProbedRevision(String? activeRevision) {
    if (!_baselineProbeCompleted) {
      _baselineProbeCompleted = true;
      _connectedRevision = activeRevision;
      return;
    }
    if (activeRevision == null) return;
    if (activeRevision == _connectedRevision) {
      _revisionReconnectDeferred = false;
      return;
    }
    if (_uploadReceiver.hasActiveUploads) {
      if (!_revisionReconnectDeferred) {
        _revisionReconnectDeferred = true;
        onLog?.call(
          'Server revision changed (${_connectedRevision ?? 'unknown'} -> $activeRevision); deferring reconnect until file upload completes',
        );
      }
      return;
    }
    onLog?.call(
      'Server revision changed (${_connectedRevision ?? 'unknown'} -> $activeRevision); reconnecting',
    );
    unawaited(_scheduleReconnect());
  }

  void _completeRevisionProbeTurn(StreamChannel<Uint8List>? channelAtStart) {
    if (!identical(_activeChannel, channelAtStart)) return;
    _revisionProbeInFlight = false;
    if (_revisionProbePending) {
      _revisionProbePending = false;
      if (!_stopping && stateMachine.state == .streaming) {
        unawaited(_probeServerRevision());
      }
    }
  }

  void _onRequestKeyframe() {
    _cancelFrameTimers();
    if (terminal.needsKeyframe || (_subscriberCount <= 1 && terminal.isDirty)) {
      _sendFrame(BufferSnapshotFrame(snapshot: terminal.takeSnapshot()));
      _scheduleDirtyFlushIfSubscribed();
      return;
    }
    if (terminal.isDirty) {
      final deltaFrame = terminal.takeNextFrame();
      if (deltaFrame != null) _sendFrame(deltaFrame);
    }
    _sendFrame(BufferSnapshotFrame(snapshot: terminal.snapshotCurrent()));
    _scheduleDirtyFlushIfSubscribed();
  }

  void _onRequestScrollback(RequestScrollbackFrame frame) {
    if (frame.sessionId != config.sessionId) return;
    _sendFrame(terminal.sliceScrollback(frame));
  }

  void _onFileUploadStart(FileUploadStartFrame frame) {
    if (frame.sessionId != config.sessionId) return;
    _enqueueUploadTask(() async {
      final ack = await _uploadReceiver.handleStartAsync(frame);
      if (_stopping || _finishing) return;
      _sendFrame(ack);
    });
  }

  void _onFileUploadChunk(FileUploadChunkFrame frame) {
    if (frame.sessionId != config.sessionId) return;
    _enqueueUploadTask(() async {
      final ack = await _uploadReceiver.handleChunkAsync(frame);
      if (_stopping || _finishing) return;
      _sendFrame(ack);
    });
  }

  void _onFileUploadEnd(FileUploadEndFrame frame) {
    if (frame.sessionId != config.sessionId) return;
    _enqueueUploadTask(() async {
      final (ack, completedPath) = await _uploadReceiver.handleEndAsync(frame);
      if (_stopping || _finishing) return;
      _sendFrame(ack);
      if (completedPath != null && !_ptyOutputDone.isCompleted) {
        final formatted = FileUploadReceiver.formatUploadedPathForPty(
          completedPath,
          isWindows: _isWindows,
          bracketedPaste: terminal.modes.bracketedPaste,
        );
        pty.writeBytes(Uint8List.fromList(utf8.encode(formatted)));
      }
    });
  }

  void _enqueueUploadTask(Future<void> Function() task) {
    // Pause idle countdown while upload frames await serial disk I/O so slow
    // filesystem operations never trigger false inter-frame stall aborts.
    _pendingUploadTasks++;
    _uploadIdleTimer?.cancel();
    _uploadIdleTimer = null;
    _uploadSerial = _uploadSerial
        .then((_) => _runTrackedUploadTask(task))
        .catchError((Object error) {
          onLog?.call('File upload error: $error');
        });
  }

  Future<void> _runTrackedUploadTask(Future<void> Function() task) async {
    try {
      await task();
    } finally {
      _pendingUploadTasks--;
      _syncUploadIdleTimer();
    }
  }

  void _syncUploadIdleTimer() {
    _uploadIdleTimer?.cancel();
    _uploadIdleTimer = null;
    if (_stopping || _finishing || _pendingUploadTasks > 0) return;
    if (_uploadReceiver.hasActiveUploads) {
      if (_uploadIdleTimeout > Duration.zero) {
        _uploadIdleTimer = Timer(_uploadIdleTimeout, _onUploadIdleTimeout);
      }
      return;
    }
    if (_revisionReconnectDeferred) {
      _revisionReconnectDeferred = false;
      unawaited(_scheduleReconnect());
    }
  }

  void _onUploadIdleTimeout() {
    _uploadIdleTimer = null;
    if (_pendingUploadTasks > 0 || !_uploadReceiver.hasActiveUploads) return;
    _uploadReceiver.abortAll();
    onLog?.call('Aborted stalled file upload after idle timeout');
    if (_revisionReconnectDeferred) {
      _revisionReconnectDeferred = false;
      unawaited(_scheduleReconnect());
    }
  }

  void _onResizeFrame(int rawCols, int rawRows) {
    if (_ptyOutputDone.isCompleted) return;
    final cols = AuthoritativeTerminal.clampCols(rawCols);
    final rows = AuthoritativeTerminal.clampRows(rawRows);
    _lastRemoteViewport = (cols: cols, rows: rows);
    final router = _routerSession;
    if (router != null) {
      if (_subscriberCount > 0) {
        router.setEndpointViewport(
          _remoteEndpointId,
          cols,
          rows,
          isPrimary: false,
        );
      }
    } else {
      pty.resize(cols, rows);
    }
    final targetCols = router?.cols ?? cols;
    final targetRows = router?.rows ?? rows;
    if (terminal.resize(targetCols, targetRows)) {
      _coalesceTimer?.cancel();
      _coalesceTimer = null;
      _flushPendingShellTitleIfReady();
      _scheduleDirtyFlushIfSubscribed();
      return;
    }
    if (terminal.synchronizedOutput) {
      terminal.forceKeyframe();
      _flushPendingShellTitleIfReady();
      _scheduleDirtyFlushIfSubscribed();
      return;
    }
    _cancelFrameTimers();
    final snapshot = terminal.isDirty
        ? terminal.takeSnapshot()
        : terminal.snapshotCurrent();
    _sendFrame(BufferSnapshotFrame(snapshot: snapshot));
    _flushPendingShellTitleIfReady();
    _scheduleDirtyFlushIfSubscribed();
  }

  void _onErrorFrame(String code, String message) {
    _lastError = '$code: $message';
    onLog?.call('Server error ($code): $message');
    if (_isFatalErrorCode(code)) {
      _emitStatus();
      _completePtyOutput();
      unawaited(_finishWithExitCode(78, killPty: _routerSession == null));
      return;
    }
    unawaited(_scheduleReconnect());
  }

  static bool _isFatalErrorCode(String code) => switch (code) {
    'auth_failed' || 'auth_role' || 'bad_auth' => true,
    _ => false,
  };

  bool get _isOutboundPaused => _outboundController?.isPaused ?? false;

  void _onOutboundPause() {
    _cancelFrameTimers();
  }

  void _onOutboundResume() {
    if (_outboundDrainCompleter != null) {
      _drainOutboundQueue();
      return;
    }
    if (_stopping || _activeChannel == null) return;
    _drainOutboundQueue();
    if (!_isOutboundPaused) {
      _flushPendingShellTitleIfReady();
      _scheduleDirtyFlushIfSubscribed();
    }
  }

  bool get _hasPendingClipboard =>
      _pendingClipboardText != null || _pendingClipboardReadBlocked;

  void _clearPendingClipboard() {
    _pendingClipboardText = null;
    _pendingClipboardReadBlocked = false;
  }

  void _scheduleDirtyFlushIfSubscribed() {
    if (_stopping ||
        stateMachine.state != .streaming ||
        _subscriberCount <= 0 ||
        _isOutboundPaused ||
        (!terminal.isDirty && !_hasPendingClipboard)) {
      return;
    }
    if (terminal.synchronizedOutput) {
      _coalesceTimer ??= Timer(_frameCoalesceInterval, _flushDirtyFrame);
      _syncOutputTimeoutTimer ??= Timer(
        _maxSyncOutputHold,
        _onSyncOutputTimeout,
      );
      return;
    }
    if (_syncOutputTimeoutTimer != null) {
      _syncOutputTimeoutTimer?.cancel();
      _syncOutputTimeoutTimer = null;
      if (_coalesceTimer == null) {
        _flushDirtyFrame();
      }
      return;
    }
    _coalesceTimer ??= Timer(_frameCoalesceInterval, _flushDirtyFrame);
  }

  void _onSyncOutputTimeout() {
    _syncOutputTimeoutTimer = null;
    _coalesceTimer?.cancel();
    _coalesceTimer = null;
    terminal.resetSynchronizedOutput();
    _flushDirtyFrame();
  }

  void _flushDirtyFrame() {
    _coalesceTimer = null;
    if (_stopping ||
        stateMachine.state != .streaming ||
        _subscriberCount <= 0 ||
        _isOutboundPaused ||
        terminal.synchronizedOutput) {
      return;
    }
    _syncOutputTimeoutTimer?.cancel();
    _syncOutputTimeoutTimer = null;
    final frame = terminal.takeNextFrame();
    if (frame != null) _sendFrame(frame);
    if (!_isOutboundPaused) {
      _flushPendingClipboard();
      if (terminal.isDirty) {
        _scheduleDirtyFlushIfSubscribed();
      }
    }
  }

  void _flushPendingClipboard() {
    final readBlocked = _pendingClipboardReadBlocked;
    final text = _pendingClipboardText;
    _clearPendingClipboard();
    if (readBlocked) {
      _sendFrame(
        ClipboardFrame(sessionId: config.sessionId, readBlocked: true),
      );
    }
    if (text != null) {
      _sendFrame(ClipboardFrame(sessionId: config.sessionId, text: text));
    }
  }

  void _sendFrame(CastMessage message, {bool droppable = false}) {
    final channel = _activeChannel;
    final controller = _outboundController;
    if (channel == null || controller == null || controller.isClosed) return;
    final Uint8List encoded;
    try {
      encoded = BufferFrameCodec.encode(message);
    } on Object catch (error) {
      onLog?.call('Failed to send ${message.runtimeType}: $error');
      return;
    }
    if (!controller.isPaused && _outboundQueue.isEmpty && !_drainingOutbound) {
      try {
        controller.add(encoded);
      } on Object catch (error) {
        onLog?.call('Failed to send ${message.runtimeType}: $error');
      }
      return;
    }
    if (!_tryEnqueueOutbound(encoded) && !droppable) {
      onLog?.call(
        'Outbound frame queue overflow (${_outboundQueue.length} frames, $_outboundQueuedBytes bytes)',
      );
      if (!_stopping) {
        unawaited(_scheduleReconnect());
      }
    }
  }

  bool _tryEnqueueOutbound(Uint8List encoded) {
    if (_outboundQueue.length >= maxOutboundFrames ||
        _outboundQueuedBytes + encoded.length > maxOutboundBytes) {
      return false;
    }
    _outboundQueue.addLast(encoded);
    _outboundQueuedBytes += encoded.length;
    if (!_isOutboundPaused) {
      _drainOutboundQueue();
    }
    return true;
  }

  void _drainOutboundQueue() {
    final controller = _outboundController;
    if (_drainingOutbound || controller == null || controller.isClosed) return;
    _drainingOutbound = true;
    try {
      while (!controller.isPaused &&
          !controller.isClosed &&
          _outboundQueue.isNotEmpty) {
        final next = _outboundQueue.removeFirst();
        _outboundQueuedBytes -= next.length;
        try {
          controller.add(next);
        } on Object catch (error) {
          onLog?.call('Failed to send queued frame: $error');
        }
      }
    } finally {
      _drainingOutbound = false;
      if (_outboundQueue.isEmpty) {
        _completeOutboundDrain();
      }
    }
  }

  void _completeOutboundDrain() {
    final waiter = _outboundDrainCompleter;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
  }

  Future<void> _scheduleReconnect({
    bool fromConnectFailure = false,
    int? epoch,
  }) async {
    final targetEpoch = epoch ?? _connectEpoch;
    if (_isStaleEpoch(targetEpoch)) return;
    if (!fromConnectFailure && _activeChannel == null) return;
    final backoffEpoch = ++_connectEpoch;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _closeActiveChannel();
    if (_isStaleEpoch(backoffEpoch) || stateMachine.state == .terminated) {
      return;
    }
    final CasterLifecycleEvent event =
        fromConnectFailure || stateMachine.state == .connecting
        ? .connectionFailed
        : .disconnected;
    await stateMachine.dispatch(event);
    _emitStatus();
    if (_isStaleEpoch(backoffEpoch) || stateMachine.state == .terminated) {
      return;
    }
    _reconnectTimer = Timer(
      stateMachine.nextBackoffDelay(),
      () => unawaited(_onReconnectTimerFired(backoffEpoch)),
    );
  }

  Future<void> _onReconnectTimerFired(int backoffEpoch) async {
    _reconnectTimer = null;
    if (_isStaleEpoch(backoffEpoch)) return;
    final nextEpoch = ++_connectEpoch;
    await stateMachine.dispatch(.retryTimerFired);
    _emitStatus();
    if (_isStaleEpoch(nextEpoch)) return;
    unawaited(_connectAttempt(nextEpoch));
  }

  Future<bool> _closeOutboundPump({bool drain = false}) async {
    final outStream = _outboundStream;
    final outCtrl = _outboundController;
    final outPump = _outboundPumpFuture;
    var timedOut = drain && outCtrl != null && !outCtrl.isClosed
        ? await _awaitOutboundDrain()
        : _resetOutboundDrain();
    _outboundStream = null;
    _outboundController = null;
    _outboundPumpFuture = null;
    _outboundQueue.clear();
    _outboundQueuedBytes = 0;
    if (!drain || timedOut) {
      outStream?.abort();
    }
    if (outCtrl != null && !outCtrl.isClosed) {
      unawaited(outCtrl.close());
    }
    if (outPump != null) {
      timedOut = await _awaitOutboundPumpClose(
        outPump,
        outStream,
        drain: drain,
        alreadyTimedOut: timedOut,
      );
    }
    return timedOut;
  }

  bool _resetOutboundDrain() {
    _completeOutboundDrain();
    _outboundDrainCompleter = null;
    return false;
  }

  Future<bool> _awaitOutboundDrain() async {
    _drainOutboundQueue();
    if (_outboundQueue.isEmpty) return false;
    var timedOut = false;
    final drainCompleter = Completer<void>();
    _outboundDrainCompleter = drainCompleter;
    await drainCompleter.future.timeout(
      _drainTimeout,
      onTimeout: () => timedOut = true,
    );
    if (identical(_outboundDrainCompleter, drainCompleter)) {
      _outboundDrainCompleter = null;
    }
    return timedOut;
  }

  Future<bool> _awaitOutboundPumpClose(
    Future<void> outPump,
    AbortableByteStream? outStream, {
    required bool drain,
    required bool alreadyTimedOut,
  }) async {
    if (!drain || alreadyTimedOut) {
      await outPump;
      return alreadyTimedOut;
    }
    var timedOut = false;
    await outPump.timeout(
      _drainTimeout,
      onTimeout: () {
        timedOut = true;
        outStream?.abort();
      },
    );
    return timedOut;
  }

  void _closeRetiredConnection() {
    _retireTimer?.cancel();
    _retireTimer = null;
    final retired = _retiredConnection;
    _retiredConnection = null;
    if (retired != null) {
      unawaited(retired.channel.sink.close().catchError((Object _) {}));
      final retiredSub = retired.sub;
      if (retiredSub != null) {
        unawaited(retiredSub.cancel());
      }
    }
  }

  Future<void> _closeActiveChannel({
    bool retire = false,
    bool drainOutbound = false,
  }) async {
    final chan = _activeChannel;
    if (!retire || chan != null) {
      _closeRetiredConnection();
    }
    _authTimer?.cancel();
    _authTimer = null;
    _cancelFrameTimers(clearPendingTitle: true);
    _lastBellSentAt = null;
    _revisionTimer?.cancel();
    _revisionTimer = null;
    _uploadIdleTimer?.cancel();
    _uploadIdleTimer = null;
    _replyDrainTimer?.cancel();
    _replyDrainTimer = null;
    _overflowReplies.clear();
    _overflowReplyChars = 0;
    _connectedRevision = null;
    _baselineProbeCompleted = false;
    _revisionProbeInFlight = false;
    _revisionProbePending = false;
    _revisionReconnectDeferred = false;
    _registrationConfirmed = false;
    _clearPendingClipboard();
    _uploadReceiver.abortAll();
    _pendingWaveformReqIds.clear();
    _subscriberCount = 0;
    _lastRemoteViewport = null;
    _routerSession?.removeEndpointViewport(_remoteEndpointId);
    terminal.forceKeyframe();
    final wasPaused = _isOutboundPaused;
    final sub = _channelSub;
    _channelSub = null;
    _activeChannel = null;
    if (sub != null) {
      sub
        ..onData(null)
        ..onError((Object _) {})
        ..onDone(null);
    }
    final drainTimedOut = await _closeOutboundPump(drain: drainOutbound);
    if (chan != null && retire && !wasPaused) {
      _retiredConnection = (channel: chan, sub: sub);
      _retireTimer = Timer(authTimeout, _closeRetiredConnection);
      return;
    }
    if (chan != null) {
      if ((wasPaused && !drainOutbound) || drainTimedOut || retire) {
        unawaited(chan.sink.close().catchError((Object _) {}));
      } else {
        await chan.sink
            .close()
            .timeout(const Duration(seconds: 1), onTimeout: () {})
            .catchError((Object _) {});
      }
    }
    if (sub != null) {
      unawaited(sub.cancel());
    }
  }

  Future<void> _killPtyWithEscalation() async {
    pty.kill();
    try {
      await pty.exitCode.timeout(_ptyKillTimeout);
    } on TimeoutException {
      pty.kill(.sigkill);
    } on Object catch (_) {}
  }

  Future<int> _finishWithExitCode(int code, {bool killPty = false}) async {
    if (_finishing) return _doneCompleter.future;
    _finishing = true;
    _stopping = true;
    final killFuture = killPty ? _killPtyWithEscalation() : null;
    _authTimer?.cancel();
    _authTimer = null;
    _cancelFrameTimers(clearPendingTitle: true);
    _lastBellSentAt = null;
    _revisionTimer?.cancel();
    _revisionTimer = null;
    _uploadIdleTimer?.cancel();
    _uploadIdleTimer = null;
    _replyDrainTimer?.cancel();
    _replyDrainTimer = null;
    _overflowReplies.clear();
    _overflowReplyChars = 0;

    if (stateMachine.state == .streaming) {
      if (_subscriberCount > 0) {
        while (terminal.isDirty && !_isOutboundPaused) {
          final finalFrame = terminal.takeNextFrame();
          if (finalFrame == null) break;
          _sendFrame(finalFrame);
        }
        _flushPendingClipboard();
      }
      _sendFrame(
        SessionClosedFrame(
          sessionId: config.sessionId,
          reason: .exited,
          exitCode: code,
        ),
      );
    }

    await _closeActiveChannel(drainOutbound: true);
    final cancelPtySub = _cancelPtySub;
    _cancelPtySub = null;
    if (cancelPtySub != null) {
      unawaited(cancelPtySub());
    }
    if (killFuture != null) {
      await killFuture;
    }
    _uploadReceiver.dispose();
    _detachTerminalEventHooks();
    terminal.dispose();
    await stateMachine.dispatch(.stop);
    _emitStatus();
    unawaited(_statusController.close());
    stateMachine.dispose();
    _doneCompleter.complete(code);
    return code;
  }

  /// Stops reconnect timers, closes the active channel, and disposes resources.
  Future<void> stop({bool killPty = false}) async {
    _completePtyOutput();
    await _finishWithExitCode(-1, killPty: killPty);
  }
}

CastAudioPayload _toCastAudioPayload(TerminalAudioEvent event) =>
    switch (event) {
      TerminalToneAudioEvent(
        :final waveform,
        :final frequencyHz,
        :final duration,
        :final volume,
        :final pan,
        :final busId,
      ) =>
        CastToneAudioPayload(
          waveform: waveform,
          frequencyHz: frequencyHz,
          duration: duration,
          volume: volume,
          pan: pan,
          busId: busId,
        ),
      TerminalClipAudioEvent(
        :final clipId,
        :final format,
        :final bytes,
        :final volume,
        :final pan,
        :final loop,
        :final startOffset,
        :final busId,
        :final streamId,
      ) =>
        CastClipAudioPayload(
          clipId: clipId,
          format: format,
          bytes: bytes,
          volume: volume,
          pan: pan,
          loop: loop,
          startOffset: startOffset,
          busId: busId,
          streamId: streamId,
        ),
      TerminalStreamAudioEvent(
        :final op,
        :final streamId,
        :final seq,
        :final maxBufferSize,
        :final releaseConsumed,
        :final bufferingTimeNeeds,
        :final sampleRate,
        :final channels,
        :final chunkBytes,
      ) =>
        CastStreamAudioPayload(
          op: op,
          streamId: streamId,
          seq: seq,
          maxBufferSize: maxBufferSize,
          releaseConsumed: releaseConsumed,
          bufferingTimeNeeds: bufferingTimeNeeds,
          sampleRate: sampleRate,
          channels: channels,
          chunkBytes: chunkBytes,
        ),
      TerminalStopAudioEvent(:final clipId) => CastStopAudioPayload(
        clipId: clipId,
      ),
      TerminalBusAudioEvent(
        :final op,
        :final busId,
        :final filterId,
        :final paramId,
        :final value,
        :final duration,
      ) =>
        CastBusAudioPayload(
          op: op,
          busId: busId,
          filterId: filterId,
          paramId: paramId,
          value: value,
          duration: duration,
        ),
      TerminalUpdateAudioEvent(
        :final clipId,
        :final volume,
        :final pan,
        :final seekPosition,
        :final paused,
        :final speed,
        :final preservePitch,
        :final fadeVolumeTarget,
        :final fadeVolumeDuration,
        :final fadeSpeedTarget,
        :final fadeSpeedDuration,
        :final scheduleStopDuration,
      ) =>
        CastUpdateAudioPayload(
          clipId: clipId,
          volume: volume,
          pan: pan,
          seekPosition: seekPosition,
          paused: paused,
          speed: speed,
          preservePitch: preservePitch,
          fadeVolumeTarget: fadeVolumeTarget,
          fadeVolumeDuration: fadeVolumeDuration,
          fadeSpeedTarget: fadeSpeedTarget,
          fadeSpeedDuration: fadeSpeedDuration,
          scheduleStopDuration: scheduleStopDuration,
        ),
      TerminalWaveformQueryAudioEvent(:final requestId) =>
        CastWaveformQueryAudioPayload(requestId: requestId),
    };

final class _RouterSessionPtyAdapter implements PtySession {
  final PtyRouterSession _session;
  final String _endpointId;

  const _RouterSessionPtyAdapter(this._session, this._endpointId);

  @override
  Stream<Uint8List> get output => const Stream<Uint8List>.empty();

  @override
  Future<int> get exitCode => _session.exitCode;

  @override
  void writeBytes(Uint8List data) => _session.writeInput(data);

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {
    _session.setEndpointViewport(_endpointId, cols, rows, isPrimary: false);
  }

  @override
  bool kill([ProcessSignal signal = .sigterm]) => false;
}
