import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';

import 'caster_service.dart';
import 'pty_process_adapter.dart';

/// Async factory launching a [PtySession] for [config], or returning `null` on failure.
typedef PtyStarter = Future<PtySession?> Function(CasterConfig config);

/// Supervises a primary [CasterService] and any remotely spawned child shell sessions
/// within a single `termui_cast` process.
final class CasterSupervisor {
  /// Configuration for the initial primary session launched by the CLI.
  final CasterConfig primaryConfig;

  /// Factory used to start both the primary and remotely spawned child PTYs.
  final PtyStarter ptyStarter;

  /// Host environment snapshot used to resolve default shells for spawned sessions.
  final Map<String, String> environment;

  /// Optional custom transport factory forwarded to every managed [CasterService].
  final ChannelOpener? channelOpener;

  /// Optional IAP bearer token provider forwarded to every managed [CasterService].
  final IapTokenProvider? iapTokenProvider;

  /// Optional server revision prober forwarded to every managed [CasterService].
  final RevisionProber? revisionProber;

  /// Optional diagnostic log sink shared across supervised sessions.
  final void Function(String message)? onLog;

  final Random _random;
  final Clock? _clock;
  final bool? _isWindows;
  final Duration _revisionPollInterval;
  final Duration _uploadIdleTimeout;
  final Duration _ptyKillTimeout;
  final int _maxOutboundFrames;
  final int _maxOutboundBytes;
  final Duration _authTimeout;
  final Duration _frameCoalesceInterval;
  final Duration _baseReconnectDelay;

  final Completer<int> _doneCompleter = Completer<int>();
  final Set<CasterService> _activeServices = <CasterService>{};
  final Set<SessionId> _seenSessionIds = <SessionId>{};

  int _spawnSequence = 1;
  int _pendingSpawns = 0;
  int? _primaryExitCode;
  bool _started = false;
  bool _stopping = false;

  /// Creates a multi-PTY supervisor starting from [primaryConfig].
  CasterSupervisor({
    required this.primaryConfig,
    required this.ptyStarter,
    Map<String, String>? environment,
    this.channelOpener,
    this.iapTokenProvider,
    this.revisionProber,
    this.onLog,
    Random? random,
    Clock? clock,
    bool? isWindows,
    Duration revisionPollInterval = const Duration(seconds: 60),
    Duration uploadIdleTimeout = const Duration(seconds: 30),
    Duration ptyKillTimeout = const Duration(seconds: 2),
    int maxOutboundFrames = 64,
    int maxOutboundBytes = 8 * 1024 * 1024,
    Duration authTimeout = const Duration(seconds: 5),
    Duration frameCoalesceInterval = const Duration(milliseconds: 16),
    Duration baseReconnectDelay = const Duration(milliseconds: 200),
  }) : environment = Map<String, String>.unmodifiable(
         environment ?? Platform.environment,
       ),
       _random = random ?? Random.secure(),
       _clock = clock,
       _isWindows = isWindows,
       _revisionPollInterval = revisionPollInterval,
       _uploadIdleTimeout = uploadIdleTimeout,
       _ptyKillTimeout = ptyKillTimeout,
       _maxOutboundFrames = maxOutboundFrames,
       _maxOutboundBytes = maxOutboundBytes,
       _authTimeout = authTimeout,
       _frameCoalesceInterval = frameCoalesceInterval,
       _baseReconnectDelay = baseReconnectDelay {
    _seenSessionIds.add(primaryConfig.sessionId);
  }

  /// Completes once the primary and all remotely spawned child PTYs have exited.
  ///
  /// Resolves to the primary session's exit code on normal completion, `-1` on
  /// explicit [stop], or `70` if the primary PTY failed to launch.
  Future<int> get done => _doneCompleter.future;

  /// Number of currently live [CasterService] instances managed by this supervisor.
  int get activeSessionCount => _activeServices.length;

  /// Immutable snapshot of currently live [CasterService] instances.
  List<CasterService> get activeServices =>
      List<CasterService>.unmodifiable(_activeServices);

  /// Launches the primary PTY and begins streaming to the relay server.
  ///
  /// Returns `true` when the primary session started successfully, or `false` if
  /// the supervisor was already started/stopped or the primary PTY failed to launch.
  Future<bool> start() async {
    if (_started || _stopping) return false;
    _started = true;
    final pty = await _startPtySafely(primaryConfig, isPrimary: true);
    if (_stopping) {
      pty?.kill();
      _completeDone(-1);
      return false;
    }
    if (pty == null) {
      _completeDone(70);
      return false;
    }
    final primaryService = _createService(primaryConfig, pty);
    _registerService(primaryService, isPrimary: true);
    await primaryService.start();
    return true;
  }

  /// Fans out an immediate relay reconnect/re-registration (`SIGHUP`) to all live sessions.
  Future<void> checkIn() async {
    if (!_started || _stopping) return;
    final services = List<CasterService>.of(_activeServices);
    await Future.wait(<Future<void>>[
      for (final service in services) service.checkIn(),
    ]);
  }

  /// Stops every active session and optionally terminates its child PTY process.
  Future<void> stop({bool killPty = false}) async {
    _stopping = true;
    final services = List<CasterService>.of(_activeServices);
    await Future.wait(<Future<void>>[
      for (final service in services) service.stop(killPty: killPty),
    ]);
    _completeDone(-1);
  }

  /// Formats a sanitized spawned child session title (`"<baseTitle> #<index>"`)
  /// clamped cleanly to [maxSessionTitleBytes] on a valid UTF-8 boundary.
  static String buildChildTitle(String baseTitle, int index) {
    final suffix = ' #$index';
    final cleanBase = sanitizeShellTitle(baseTitle);
    if (cleanBase.isEmpty) {
      return sanitizeShellTitle('shell$suffix');
    }
    final combined = '$cleanBase$suffix';
    if (utf8.encode(combined).length <= maxSessionTitleBytes) {
      return combined;
    }
    final budget = maxSessionTitleBytes - utf8.encode(suffix).length;
    if (budget <= 0) {
      return sanitizeShellTitle(suffix);
    }
    final baseBytes = utf8.encode(cleanBase);
    var end = min(baseBytes.length, budget);
    while (end > 0 &&
        end < baseBytes.length &&
        (baseBytes[end] & 0xC0) == 0x80) {
      end--;
    }
    final truncatedBase = utf8
        .decode(Uint8List.sublistView(baseBytes, 0, end), allowMalformed: true)
        .trimRight();
    final candidate = truncatedBase.isEmpty
        ? 'shell$suffix'
        : '$truncatedBase$suffix';
    return sanitizeShellTitle(candidate);
  }

  Future<void> _handleSpawnRequest() async {
    if (_stopping || _doneCompleter.isCompleted) return;
    _pendingSpawns++;
    PtySession? pty;
    CasterService? childService;
    try {
      final childConfig = _buildChildConfig();
      pty = await _startPtySafely(childConfig, isPrimary: false);
      if (_stopping || _doneCompleter.isCompleted) {
        pty?.kill();
        return;
      }
      if (pty == null) return;
      childService = _createService(childConfig, pty);
      _registerService(childService, isPrimary: false);
      await childService.start();
    } on Object catch (error) {
      onLog?.call('Failed to spawn child session: $error');
      await _cleanupFailedChildSpawn(childService, pty);
    } finally {
      _pendingSpawns--;
      _maybeCompleteDone();
    }
  }

  Future<void> _cleanupFailedChildSpawn(
    CasterService? childService,
    PtySession? pty,
  ) async {
    if (childService == null) {
      pty?.kill();
      return;
    }
    _activeServices.remove(childService);
    try {
      await childService.stop(killPty: true);
    } on Object catch (stopError) {
      onLog?.call(
        'Failed to clean up child session after start error: $stopError',
      );
    }
  }

  Future<PtySession?> _startPtySafely(
    CasterConfig config, {
    required bool isPrimary,
  }) async {
    try {
      final pty = await ptyStarter(config);
      if (pty == null && !isPrimary) {
        onLog?.call(
          'Failed to spawn child PTY "${config.title}" (session: ${config.sessionId.value})',
        );
      }
      return pty;
    } on Object catch (error) {
      final label = isPrimary ? 'primary' : 'spawned';
      onLog?.call('Failed to start $label PTY "${config.title}": $error');
      return null;
    }
  }

  CasterConfig _buildChildConfig() {
    final spawnIndex = ++_spawnSequence;
    return CasterConfig(
      serverUri: primaryConfig.serverUri,
      token: primaryConfig.token,
      sessionId: _generateChildSessionId(),
      title: buildChildTitle(primaryConfig.title, spawnIndex),
      initialCols: primaryConfig.initialCols,
      initialRows: primaryConfig.initialRows,
      maxScrollbackLines: primaryConfig.maxScrollbackLines,
      colorScheme: primaryConfig.colorScheme,
      iapServiceAccount: primaryConfig.iapServiceAccount,
      iapKeyFilePath: primaryConfig.iapKeyFilePath,
      iapServiceAccountKey: primaryConfig.iapServiceAccountKey,
      downloadConPty: primaryConfig.downloadConPty,
      uploadEnabled: primaryConfig.uploadEnabled,
      uploadDirPath: primaryConfig.uploadDirPath,
      maxUploadBytes: primaryConfig.maxUploadBytes,
      keepAliveOnHup: primaryConfig.keepAliveOnHup,
      allowSpawn: true,
      command: CasterConfig.resolveDefaultShellCommand(
        environment,
        isWindows: _isWindows,
      ),
    );
  }

  SessionId _generateChildSessionId() {
    for (var attempt = 0; attempt < 8; attempt++) {
      final buf = StringBuffer('cast-');
      for (var i = 0; i < 8; i++) {
        buf.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
      }
      final candidate = SessionId('$buf');
      if (_seenSessionIds.add(candidate)) return candidate;
    }
    final fallback = SessionId('cast-spawn-$_spawnSequence');
    _seenSessionIds.add(fallback);
    return fallback;
  }

  CasterService _createService(CasterConfig config, PtySession pty) {
    return CasterService(
      config: config,
      pty: pty,
      channelOpener: channelOpener,
      iapTokenProvider: iapTokenProvider,
      revisionProber: revisionProber,
      revisionPollInterval: _revisionPollInterval,
      uploadIdleTimeout: _uploadIdleTimeout,
      ptyKillTimeout: _ptyKillTimeout,
      maxOutboundFrames: _maxOutboundFrames,
      maxOutboundBytes: _maxOutboundBytes,
      random: _random,
      clock: _clock,
      isWindows: _isWindows,
      onLog: onLog,
      onSpawnRequested: config.allowSpawn ? _handleSpawnRequest : null,
      authTimeout: _authTimeout,
      frameCoalesceInterval: _frameCoalesceInterval,
      baseReconnectDelay: _baseReconnectDelay,
    );
  }

  void _registerService(CasterService service, {required bool isPrimary}) {
    _activeServices.add(service);
    unawaited(
      service.done.then((code) {
        _activeServices.remove(service);
        if (isPrimary) {
          _primaryExitCode = code;
        }
        _maybeCompleteDone();
      }),
    );
  }

  void _maybeCompleteDone() {
    if (_activeServices.isNotEmpty || _pendingSpawns > 0) return;
    _completeDone(_stopping ? -1 : (_primaryExitCode ?? 0));
  }

  void _completeDone(int exitCode) {
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete(exitCode);
    }
  }
}
