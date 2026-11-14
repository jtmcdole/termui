import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_caster_cli/termui_caster_cli.dart';
import 'package:termui_pty/termui_pty.dart';

import 'local_host_driver_interface.dart';

export 'local_host_driver_interface.dart';

/// Factory creating a [RoutedPtyBackend] for a spawned local shell pane.
@visibleForTesting
typedef LocalPtyBackendFactory =
    RoutedPtyBackend Function({
      required String executable,
      required List<String> arguments,
      required int initialCols,
      required int initialRows,
      required int pixelWidth,
      required int pixelHeight,
      String? workingDirectory,
      Map<String, String>? environment,
    });

/// Creates the `dart:io` desktop [LocalHostDriver].
///
/// Remains unsupported (`isSupported == false`) when `FLUTTER_TEST` is set in
/// [environment] so existing headless relay tests never spawn an unintended
/// interactive OS shell unless a test explicitly creates [IoLocalHostDriver].
LocalHostDriver createPlatformLocalHostDriver({
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  if (env.containsKey('FLUTTER_TEST')) {
    return const _DisabledIoLocalHostDriver();
  }
  return IoLocalHostDriver();
}

final class _DisabledIoLocalHostDriver implements LocalHostDriver {
  const _DisabledIoLocalHostDriver();

  @override
  bool get isSupported => false;

  @override
  Future<LocalPaneHost> openShell(LocalShellConfig config) => Future.error(
    UnsupportedError('Local shell startup disabled under FLUTTER_TEST.'),
  );

  @override
  Future<void> dispose() async {}
}

/// `dart:io` desktop [LocalHostDriver] backed by [PtyRouter],
/// [Pty2RoutedBackend], and [CasterService.fromRouterSession].
final class IoLocalHostDriver implements LocalHostDriver {
  static const Set<String> _posixLoginShellNames = {
    'zsh',
    'bash',
    'sh',
    'fish',
    'ksh',
    'dash',
    'csh',
    'tcsh',
  };

  final PtyRouter _router;
  final Map<String, _IoLocalPaneHost> _hosts = {};
  final Random _random;
  final LocalPtyBackendFactory _backendFactory;
  bool _disposed = false;
  bool _conPtyChecked = false;
  int _sessionCounter = 0;

  /// Creates a `dart:io` local shell host driver.
  IoLocalHostDriver({
    PtyRouter? router,
    Random? random,
    @visibleForTesting LocalPtyBackendFactory? backendFactory,
  }) : _router = router ?? PtyRouter(),
       _random = random ?? Random.secure(),
       _backendFactory = backendFactory ?? _startDefaultBackend;

  static RoutedPtyBackend _startDefaultBackend({
    required String executable,
    required List<String> arguments,
    required int initialCols,
    required int initialRows,
    required int pixelWidth,
    required int pixelHeight,
    String? workingDirectory,
    Map<String, String>? environment,
  }) => Pty2RoutedBackend.start(
    executable,
    arguments,
    initialCols: initialCols,
    initialRows: initialRows,
    pixelWidth: pixelWidth,
    pixelHeight: pixelHeight,
    workingDirectory: workingDirectory,
    environment: environment,
  );

  /// Whether any mounted local host currently has an active share status poll timer.
  @visibleForTesting
  bool get hasActiveSharePolling =>
      _hosts.values.any((host) => host._sharePollTimer != null);

  @override
  bool get isSupported => !_disposed;

  @override
  Future<LocalPaneHost> openShell(LocalShellConfig config) async {
    if (_disposed) {
      throw StateError('IoLocalHostDriver is disposed.');
    }
    if (Platform.isWindows && !_conPtyChecked) {
      _conPtyChecked = true;
      await Pty2RoutedBackend.ensureConPtyReady();
    }
    final executable = _resolveShellExecutable(config.executable);
    final arguments = resolveShellArguments(config, executable);
    final envOverrides = resolveChildEnvironmentOverrides(Platform.environment);
    final backend = _backendFactory(
      executable: executable,
      arguments: arguments,
      initialCols: config.initialCols,
      initialRows: config.initialRows,
      pixelWidth: config.initialCols * config.cellPixelWidth,
      pixelHeight: config.initialRows * config.cellPixelHeight,
      workingDirectory: resolveInitialWorkingDirectory(config.workingDirectory),
      environment: envOverrides.isEmpty ? null : envOverrides,
    );
    final session = _router.createSession(
      backend: backend,
      initialCols: config.initialCols,
      initialRows: config.initialRows,
      maxScrollbackLines: config.maxScrollbackLines,
      cellPixelWidth: config.cellPixelWidth,
      cellPixelHeight: config.cellPixelHeight,
      colorScheme: config.colorScheme,
    );
    final port = session.openPort(
      initialCols: config.initialCols,
      initialRows: config.initialRows,
      cellPixelWidth: config.cellPixelWidth,
      cellPixelHeight: config.cellPixelHeight,
    );
    final host = _IoLocalPaneHost(
      id: session.id,
      executableName: p.basename(executable),
      session: session,
      port: port,
      nextSessionId: _allocateShareSessionId,
      onDisposed: () => _hosts.remove(session.id),
    );
    _hosts[host.id] = host;
    return host;
  }

  SessionId _allocateShareSessionId() {
    _sessionCounter += 1;
    final nonce = _random.nextInt(0x10000).toRadixString(16).padLeft(4, '0');
    return SessionId('fterm-$pid-$_sessionCounter-$nonce');
  }

  static String _resolveShellExecutable(String? explicit) {
    final trimmed = explicit?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return trimmed;
    }
    if (Platform.isWindows) {
      final pwsh = _findInPath('pwsh.exe');
      if (pwsh != null) return pwsh;
      final comSpec = Platform.environment['COMSPEC']?.trim();
      return (comSpec != null && comSpec.isNotEmpty) ? comSpec : 'cmd.exe';
    }
    final envShell = Platform.environment['SHELL']?.trim();
    if (envShell != null && envShell.isNotEmpty) {
      return envShell;
    }
    return Platform.isMacOS ? '/bin/zsh' : '/bin/sh';
  }

  static String? _findInPath(String binaryName) {
    final pathEnv = Platform.environment['PATH'];
    if (pathEnv == null || pathEnv.isEmpty) return null;
    for (final entry in pathEnv.split(Platform.isWindows ? ';' : ':')) {
      final dir = entry.trim();
      if (dir.isEmpty) continue;
      final candidate = File(p.join(dir, binaryName));
      if (candidate.existsSync()) return candidate.path;
    }
    return null;
  }

  /// Resolves shell launch arguments, passing `['-l']` for default interactive
  /// POSIX login shells when no explicit executable or arguments are set.
  @visibleForTesting
  static List<String> resolveShellArguments(
    LocalShellConfig config,
    String executable, {
    bool? isWindows,
  }) {
    final windows = isWindows ?? Platform.isWindows;
    if (!windows &&
        config.executable == null &&
        config.arguments.isEmpty &&
        _posixLoginShellNames.contains(p.basename(executable))) {
      return const ['-l'];
    }
    return config.arguments;
  }

  /// Resolves child environment overrides, ensuring UTF-8 `LANG` when unset,
  /// empty, `'C'`, or `'POSIX'`.
  @visibleForTesting
  static Map<String, String> resolveChildEnvironmentOverrides(
    Map<String, String> environment,
  ) {
    final lang = environment['LANG']?.trim();
    if (lang == null || lang.isEmpty || lang == 'C' || lang == 'POSIX') {
      return const {'LANG': 'en_US.UTF-8'};
    }
    return const {};
  }

  /// Resolves initial working directory from [requested], `HOME`, or Windows
  /// `USERPROFILE`.
  @visibleForTesting
  static String? resolveInitialWorkingDirectory(
    String? requested, {
    Map<String, String>? environment,
    bool Function(String path)? directoryExists,
  }) {
    final trimmed = requested?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    final env = environment ?? Platform.environment;
    final exists = directoryExists ?? (path) => Directory(path).existsSync();
    for (final key in const ['HOME', 'USERPROFILE']) {
      final candidate = env[key]?.trim();
      if (candidate != null && candidate.isNotEmpty && exists(candidate)) {
        return candidate;
      }
    }
    return null;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final activeHosts = [..._hosts.values];
    _hosts.clear();
    await Future.wait([for (final host in activeHosts) host.dispose()]);
    await _router.dispose();
  }
}

final class _IoLocalPaneHost implements LocalPaneHost {
  @override
  final String id;
  final String _executableName;
  final PtyRouterSession _session;
  @override
  final TerminalPort port;
  final SessionId Function() _nextSessionId;
  final void Function() _onDisposed;
  final StreamController<LocalShareSnapshot> _shareUpdates =
      StreamController<LocalShareSnapshot>.broadcast();

  CasterService? _shareService;
  Timer? _sharePollTimer;
  LocalShareSnapshot _shareSnapshot = LocalShareSnapshot.unshared;
  String? _lastShareError;
  bool _disposed = false;

  _IoLocalPaneHost({
    required this.id,
    required String executableName,
    required PtyRouterSession session,
    required this.port,
    required SessionId Function() nextSessionId,
    required void Function() onDisposed,
  }) : _executableName = executableName,
       _session = session,
       _nextSessionId = nextSessionId,
       _onDisposed = onDisposed;

  @override
  Future<int> get exitCode => _session.exitCode;

  @override
  LocalShareSnapshot get shareSnapshot => _shareSnapshot;

  @override
  Stream<LocalShareSnapshot> get shareUpdates => _shareUpdates.stream;

  @override
  Future<SessionId> startShare({
    required Uri serverUri,
    required String casterToken,
    required String title,
    String? uploadDirPath,
    IapTokenProvider? iapTokenProvider,
    CasterTransportOpener? channelOpener,
  }) async {
    if (_disposed) {
      throw StateError('LocalPaneHost $id is disposed.');
    }
    final active = _shareService;
    if (active != null) {
      return active.config.sessionId;
    }
    final sessionId = _nextSessionId();
    final safeTitle = _sanitizeShareTitle(title);
    final config = CasterConfig(
      serverUri: serverUri,
      token: casterToken,
      sessionId: sessionId,
      title: safeTitle,
      initialCols: port.cols,
      initialRows: port.rows,
      uploadDirPath: uploadDirPath,
      command: <String>[_executableName],
    );
    late final CasterService service;
    service = CasterService.fromRouterSession(
      session: _session,
      config: config,
      iapTokenProvider: iapTokenProvider,
      channelOpener: channelOpener,
      onLog: (message) => _onShareServiceLog(service, sessionId, message),
    );
    _lastShareError = null;
    _shareService = service;
    _setShareSnapshot(
      LocalShareSnapshot(
        state: LocalShareState.connecting,
        sessionId: sessionId,
      ),
    );
    _startShareStatusPolling(service, sessionId);
    try {
      await service.start();
    } on Object catch (error) {
      if (identical(_shareService, service)) {
        _stopPolling();
        _shareService = null;
        _setShareSnapshot(
          LocalShareSnapshot(
            state: LocalShareState.error,
            errorMessage: '$error',
          ),
        );
      }
      rethrow;
    }
    _syncShareSnapshot(service, sessionId);
    return sessionId;
  }

  void _onShareServiceLog(
    CasterService service,
    SessionId sessionId,
    String message,
  ) {
    if (_disposed || !identical(_shareService, service)) return;
    final failure = _extractShareFailureMessage(message);
    if (failure == null) return;
    final isNew = failure != _lastShareError;
    _lastShareError = failure;
    if (isNew && !Platform.environment.containsKey('FLUTTER_TEST')) {
      stderr.writeln('fterm: share failed: $failure');
    }
    _syncShareSnapshot(service, sessionId);
  }

  static String? _extractShareFailureMessage(String message) {
    const prefixes = [
      'Connection attempt failed: ',
      'Transport error: ',
      'Error ',
    ];
    for (final prefix in prefixes) {
      if (message.startsWith(prefix)) {
        final detail = message.substring(prefix.length).trim();
        return detail.isEmpty ? message : detail;
      }
    }
    if (message == 'Relay authentication timed out') {
      return message;
    }
    return null;
  }

  String _sanitizeShareTitle(String rawTitle) {
    final trimmed = rawTitle.trim();
    if (trimmed.isNotEmpty) return trimmed;
    return _executableName.isNotEmpty ? _executableName : 'fterm';
  }

  void _startShareStatusPolling(CasterService service, SessionId sessionId) {
    _stopPolling();
    _sharePollTimer = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _syncShareSnapshot(service, sessionId),
    );
  }

  void _syncShareSnapshot(CasterService service, SessionId sessionId) {
    if (_disposed || !identical(_shareService, service)) return;
    final state = switch (service.stateMachine.state) {
      CasterLifecycleState.streaming => LocalShareState.live,
      CasterLifecycleState.terminated => LocalShareState.error,
      _ => LocalShareState.connecting,
    };
    if (state == LocalShareState.live) {
      _lastShareError = null;
    } else if (state == LocalShareState.error) {
      _stopPolling();
      _shareService = null;
    }
    _setShareSnapshot(
      LocalShareSnapshot(
        state: state,
        sessionId: sessionId,
        subscriberCount: service.subscriberCount,
        errorMessage: switch (state) {
          LocalShareState.live || LocalShareState.unshared => null,
          LocalShareState.connecting => _lastShareError,
          LocalShareState.error =>
            _lastShareError ?? 'Caster connection terminated',
        },
      ),
    );
  }

  void _setShareSnapshot(LocalShareSnapshot next) {
    if (_shareSnapshot == next) return;
    _shareSnapshot = next;
    if (!_shareUpdates.isClosed) {
      _shareUpdates.add(next);
    }
  }

  void _stopPolling() {
    _sharePollTimer?.cancel();
    _sharePollTimer = null;
  }

  @override
  Future<void> stopShare() async {
    _stopPolling();
    final service = _shareService;
    _shareService = null;
    if (service != null) {
      await service.stop(killPty: false);
    }
    _setShareSnapshot(LocalShareSnapshot.unshared);
  }

  @override
  void setColorScheme(tui.TerminalBrightness brightness) {
    _session.terminal.setColorScheme(brightness);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stopShare();
    await port.dispose();
    await _session.dispose();
    await _shareUpdates.close();
    _onDisposed();
  }
}
