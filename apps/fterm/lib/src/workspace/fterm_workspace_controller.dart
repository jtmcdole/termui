import 'dart:async';
import 'dart:collection' show UnmodifiableMapView;
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui show AppExitType;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier, listEquals;
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, ServicesBinding;
import 'package:path/path.dart' as p;
import 'package:termui/termui.dart' as tui;
import 'package:termui_audio_flutter/termui_audio_flutter.dart';
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_flutter/termui_flutter.dart'
    show
        BuiltinShaders,
        DiagnosableShaderBackend,
        ShaderAnimationMode,
        ShaderBackendDiagnostics,
        ShaderBackendKind,
        ShaderCompileException,
        ShaderPassSpec,
        ShaderStageHint,
        ShadertoyGlslAnalysis,
        ShadertoyGlslShim,
        TerminalShaderConfig,
        TerminalShaderController,
        TerminalShaderPreset,
        TerminalShaderStage;
import 'package:termui_pty/termui_pty.dart';

import '../about/about_repository.dart';
import '../about/about_service.dart';
import '../about/about_view_model.dart';
import '../audio/fterm_audio_controller.dart';
import '../desktop_launch_env.dart';
import '../feedback/diagnostic_log.dart';
import '../feedback/feedback_models.dart';
import '../launch_config.dart';
import '../perf/fterm_trace_recorder.dart';
import '../perf/trace_exporter.dart';
import '../settings_storage.dart';
import '../shader_profile_store.dart';
import '../update/update_service.dart';
import '../update/update_view_model.dart';
import 'cli_shader_state.dart';
import 'fterm_pane_controller.dart';
import 'local_host_driver.dart';
import 'split_tree_model.dart';

/// Active modal overlay shown above the `fterm` terminal workspace.
enum FtermOverlay {
  /// Workspace terminal grid is unobstructed.
  none,

  /// Relay server URL and bearer credentials connection prompt.
  connect,

  /// Local shell launcher and remote relay session picker.
  sessionPicker,

  /// Theme, font, tab dock, and audio settings sheet.
  settings,

  /// Live network and audio telemetry overlay.
  stats,

  /// Custom pinned tab title editor with `clearPin` toggle.
  rename,

  /// Keyboard chord and desktop native shortcut reference.
  help,

  /// Application metadata, SVG logo, build date, and open-source licenses link.
  about,

  /// Deduplicated open-source and bundled font license viewer.
  licenses,

  /// Guided GitHub feedback and bug-report submission modal.
  feedback,

  /// Drag-and-drop multi-file upload confirmation and progress sheet.
  fileUpload,

  /// Release highlights and interactive live shader preview showcase.
  whatsNew,
}

typedef _WhatsNewPreviewSnapshot = ({
  List<String> backgroundChain,
  List<String> foregroundChain,
  double backgroundOpacity,
  bool showPerfHud,
});

final class _ChromeChangeNotifier extends ChangeNotifier {
  void emitChange() => notifyListeners();
}

/// Mutable state for a single workspace tab and its binary split tree.
final class FtermTabState {
  /// Stable unique tab identifier.
  final String tabId;

  /// Binary split layout and focused/zoomed pane state for this tab.
  SplitTreeModel splitTree;

  /// Optional user-pinned custom tab title (`Ctrl+\ r`).
  String? pinnedTitle;

  /// Unread `BEL` badge counter accumulated while this tab is backgrounded.
  int unreadBellCount = 0;

  /// Creates a tab wrapping [splitTree].
  FtermTabState({
    required this.tabId,
    required this.splitTree,
    this.pinnedTitle,
  });

  /// Whether a user-pinned title currently overrides live shell titles.
  bool get isUserPinned => pinnedTitle != null && pinnedTitle!.isNotEmpty;

  /// Resolves display title (`pinnedTitle` > live shell/remote title > fallback).
  String resolveTitle(Map<String, FtermPaneController> panes) {
    final pinned = pinnedTitle;
    if (pinned != null && pinned.isNotEmpty) return pinned;
    final focused = panes[splitTree.focusedPaneId];
    if (focused == null) return 'fterm';
    final remote = focused.remotePort;
    if (remote != null) {
      final title = remote.displayTitle.trim();
      return title.isNotEmpty ? title : remote.sessionId.value;
    }
    if (focused.shellTitle.isNotEmpty) return focused.shellTitle;
    final cwd = focused.localHost?.port.workingDirectory;
    if (cwd != null && cwd.trim().isNotEmpty) {
      final base = p.basename(cwd.trim());
      return base.isNotEmpty ? base : cwd.trim();
    }
    return 'shell';
  }

  /// Whether all panes in this tab have exited.
  bool isExited(Map<String, FtermPaneController> panes) {
    final ids = splitTree.paneIds;
    if (ids.isEmpty) return false;
    for (final id in ids) {
      final pane = panes[id];
      if (pane != null && !pane.hasExited) return false;
    }
    return true;
  }

  /// Highest relay subscriber count across panes in this tab.
  int viewerCount(
    Map<String, FtermPaneController> panes, {
    int Function(SessionId id)? remoteSubscriberCount,
  }) {
    var count = 0;
    for (final id in splitTree.paneIds) {
      final pane = panes[id];
      if (pane == null) continue;
      if (pane.isLocal) {
        count = math.max(count, pane.shareSnapshot.subscriberCount);
      } else if (pane.remoteSessionId case final sessionId?) {
        count = math.max(count, remoteSubscriberCount?.call(sessionId) ?? 0);
      }
    }
    return count;
  }

  /// Whether any local pane in this tab is currently sharing to a relay.
  bool isShared(Map<String, FtermPaneController> panes) {
    for (final id in splitTree.paneIds) {
      final pane = panes[id];
      if (pane != null &&
          pane.isLocal &&
          pane.shareSnapshot.state != LocalShareState.unshared) {
        return true;
      }
    }
    return false;
  }
}

/// Top-level workspace coordinator unifying local desktop shells, remote relay
/// sessions, binary split trees, audio chimes, settings, and modal overlays.
final class FtermWorkspaceController extends ChangeNotifier {
  static int _idCounter = 0;

  /// Launch configuration resolved from CLI, env, and URL fragments.
  final CastLaunchConfig launchConfig;

  /// Backing relay client repository.
  final CastClientRepository repository;

  /// Native desktop shell host driver (or Web stub where unsupported).
  final LocalHostDriver localHostDriver;

  /// Audio synthesis and clip engine controller.
  final FtermAudioController audioController;

  final SettingsStorage _storage;
  final ThrottledSettingsSaver _settingsSaver;
  final Duration _resizeDebounce;
  final Clock _clock;
  final void Function(tui.Buffer buffer)? _onFrameRedrawn;
  final DesktopIapProviderBuilder _iapProviderBuilder;
  final String? Function() _gcloudPathProber;
  final Map<String, IapTokenProvider?> _iapProviderCache =
      <String, IapTokenProvider?>{};

  /// Fallback terminal font size (in logical pixels) when preferences omit it.
  final double defaultFontSize;

  final List<FtermTabState> _tabs = [];
  final Map<String, FtermPaneController> _panes = {};
  late final Map<String, FtermPaneController> _panesView =
      UnmodifiableMapView<String, FtermPaneController>(_panes);
  final List<SessionSummary> _remoteDirectorySessions = [];
  final Set<SessionId> _ownedSharedSessionIds = {};
  final Set<SessionId> _dismissedRemoteSessions = {};
  final Set<String> _togglingSharePaneIds = {};
  final _ChromeChangeNotifier _chromeNotifier = _ChromeChangeNotifier();

  late final FileUploadCoordinator _uploadCoordinator;

  /// Desktop auto-update ViewModel (fine-grained progress + coarse chrome cues).
  late final UpdateViewModel updateViewModel;

  /// About & open-source licenses ViewModel shared by modal overlays.
  late final AboutViewModel aboutViewModel;

  /// Cross-platform performance trace recorder bound to this workspace.
  late final FtermTraceRecorder traceRecorder;
  final bool _ownsTraceRecorder;
  final Future<void> Function() _onRequestExit;
  final Future<bool> Function(List<String> args) _onRelaunchApp;
  final GpuDriverPreference _initialGpuDriverPreference;
  String? _activeGpuAdapterName;
  int? _activeGpuVramMb;

  /// Bounded in-memory sanitized diagnostic log for opt-in issue reports.
  final FtermDiagnosticLog diagnosticLog;
  final bool _ownsDiagnosticLog;
  final TerminalShaderController _shaderController;
  final bool _ownsShaderController;
  final ShaderProfileStore _shaderProfileStore;
  final bool _ownsShaderProfileStore;
  final Future<void> Function(String directoryPath)? _openDirectoryHandler;
  StreamSubscription<ShaderDirectoryChange>? _shaderWatchSubscription;
  TerminalShaderConfig _activeShaderConfig = TerminalShaderConfig.empty;
  Map<String, List<double>> _shaderParamsByPass = <String, List<double>>{};
  List<String> _availableCustomShaders = const <String>[];
  final Map<String, ShadertoyGlslAnalysis> _customShaderAnalyses =
      <String, ShadertoyGlslAnalysis>{};
  String? _lastShaderAssetError;
  String? _lastLoggedShareError;
  bool _lastUpdateWasError = false;

  CastWorkspaceSettings _workspaceSettings;
  FtermPreferences _preferences;
  RelayCredentials _relayCredentials;
  tui.TerminalBrightness _platformBrightness;
  TerminalColorResolver _colorResolver;

  ClientConnectionState _connectionState = ClientConnectionState.unconnected;
  String? _authErrorMessage;
  int _activeTabIndex = 0;
  FtermOverlay _activeOverlay = FtermOverlay.none;
  _WhatsNewPreviewSnapshot? _whatsNewPreviewSnapshot;
  bool _leaderArmed = false;
  bool _workspaceVisible = true;
  bool _windowFocused = true;
  bool _started = false;
  bool _disposed = false;
  int _bellEventsCount = 0;
  int _audioEventsCount = 0;
  int _titleEventsCount = 0;
  String? _statusBanner;
  List<DroppedFileSource> _pendingUploadFiles = const [];
  SessionId? _stagedUploadSessionId;
  Uri _activeRelayUri;
  String _activeClientToken;
  String _activeCasterToken;
  String _activeIapServiceAccount;
  String _activeIapKeyFilePath;
  String _activeGcloudPath;
  bool _hasRuntimeIapOverride = false;
  bool _shouldAutoConnectRelay = false;

  /// Creates the workspace coordinator for `fterm`.
  factory FtermWorkspaceController({
    required CastLaunchConfig launchConfig,
    required CastClientRepository repository,
    required LocalHostDriver localHostDriver,
    required FtermAudioController audioController,
    required SettingsStorage storage,
    DockPosition defaultDockPosition = DockPosition.top,
    double defaultFontSize = FtermPreferences.defaultFontSize,
    tui.TerminalBrightness initialBrightness = tui.TerminalBrightness.dark,
    Duration resizeDebounce = const Duration(milliseconds: 32),
    Clock? clock,
    UpdateService? updateService,
    UpdateTimerFactory? updateTimerFactory,
    AboutService? aboutService,
    FtermDiagnosticLog? diagnosticLog,
    TerminalShaderController? shaderController,
    ShaderProfileStore? shaderProfileStore,
    FtermTraceRecorder? traceRecorder,
    Future<void> Function()? onRequestExit,
    Future<bool> Function(List<String> args)? onRelaunchApp,
    Future<void> Function(String directoryPath)? openDirectoryHandler,
    DesktopIapProviderBuilder? iapProviderBuilder,
    String? Function()? gcloudPathProber,
    void Function(tui.Buffer buffer)? onFrameRedrawn,
  }) => FtermWorkspaceController._(
    launchConfig: launchConfig,
    repository: repository,
    localHostDriver: localHostDriver,
    audioController: audioController,
    storage: storage,
    defaultFontSize: defaultFontSize,
    initialSettings: loadStoredSettings(
      storage,
      defaultDockPosition: defaultDockPosition,
    ),
    initialPreferences: loadStoredPreferences(storage),
    initialCredentials: localHostDriver.isSupported
        ? loadStoredRelayCredentials(storage)
        : RelayCredentials.empty,
    initialBrightness: initialBrightness,
    resizeDebounce: resizeDebounce,
    clock: clock,
    updateService: updateService,
    updateTimerFactory: updateTimerFactory,
    aboutService: aboutService,
    diagnosticLog: diagnosticLog,
    shaderController: shaderController,
    shaderProfileStore: shaderProfileStore,
    traceRecorder: traceRecorder,
    onRequestExit: onRequestExit,
    onRelaunchApp: onRelaunchApp,
    openDirectoryHandler: openDirectoryHandler,
    iapProviderBuilder: iapProviderBuilder,
    gcloudPathProber: gcloudPathProber,
    onFrameRedrawn: onFrameRedrawn,
  );

  FtermWorkspaceController._({
    required this.launchConfig,
    required this.repository,
    required this.localHostDriver,
    required this.audioController,
    required SettingsStorage storage,
    required this.defaultFontSize,
    required CastWorkspaceSettings initialSettings,
    required FtermPreferences initialPreferences,
    required RelayCredentials initialCredentials,
    required tui.TerminalBrightness initialBrightness,
    required this._resizeDebounce,
    required Clock? clock,
    required UpdateService? updateService,
    required UpdateTimerFactory? updateTimerFactory,
    required AboutService? aboutService,
    required FtermDiagnosticLog? diagnosticLog,
    required TerminalShaderController? shaderController,
    required ShaderProfileStore? shaderProfileStore,
    required FtermTraceRecorder? traceRecorder,
    required Future<void> Function()? onRequestExit,
    required Future<bool> Function(List<String> args)? onRelaunchApp,
    required this._openDirectoryHandler,
    required DesktopIapProviderBuilder? iapProviderBuilder,
    required String? Function()? gcloudPathProber,
    required this._onFrameRedrawn,
  }) : _storage = storage,
       _settingsSaver = ThrottledSettingsSaver(storage),
       _clock = clock ?? const Clock(),
       _iapProviderBuilder = iapProviderBuilder ?? buildDesktopIapTokenProvider,
       _gcloudPathProber = gcloudPathProber ?? probeDesktopGcloudExecutable,
       _ownsTraceRecorder = traceRecorder == null,
       _onRequestExit = onRequestExit ?? _defaultRequestExit,
       _onRelaunchApp = onRelaunchApp ?? _defaultRelaunchApp,
       _initialGpuDriverPreference = initialPreferences.gpuDriverPreference,
       _ownsDiagnosticLog = diagnosticLog == null,
       diagnosticLog =
           diagnosticLog ?? FtermDiagnosticLog(clock: clock ?? const Clock()),
       _ownsShaderController = shaderController == null,
       _shaderController =
           shaderController ??
           TerminalShaderController(
             initialBackendOverride: initialPreferences.shaderBackendOverride,
           ),
       _ownsShaderProfileStore = shaderProfileStore == null,
       _shaderProfileStore =
           shaderProfileStore ?? createPlatformShaderProfileStore(),
       _platformBrightness = initialBrightness,
       _workspaceSettings = initialSettings,
       _preferences = initialPreferences,
       _relayCredentials = initialCredentials,
       _activeRelayUri = launchConfig.serverUri,
       _activeClientToken = launchConfig.token,
       _activeCasterToken = launchConfig.casterToken,
       _activeIapServiceAccount = launchConfig.iapServiceAccount.trim(),
       _activeIapKeyFilePath = launchConfig.iapKeyFilePath.trim(),
       _activeGcloudPath = launchConfig.gcloudPath.trim(),
       _colorResolver = _buildColorResolver(
         initialSettings.themeSettings,
         initialBrightness,
       ) {
    this.traceRecorder =
        traceRecorder ??
        FtermTraceRecorder(
          readDiagnostics: readShaderBackendDiagnostics,
          readMetadata: _buildTraceSessionMetadata,
        );
    _hydrateSavedRelaySettings();
    _initShaderSubsystem();
    audioController
      ..setMuted(_preferences.audioMuted)
      ..setVolume(_preferences.audioVolume);
    _uploadCoordinator = FileUploadCoordinator(
      repository: repository,
      onProgressChanged: _notifyChromeChanged,
      onError: (message) {
        this.diagnosticLog.record(DiagnosticEventKind.fileUploadFailed);
        _setStatusBanner(message);
      },
    );
    updateViewModel = UpdateViewModel(
      service: updateService ?? createPlatformUpdateService(),
      readPreferences: () => _preferences,
      writePreferences: updatePreferences,
      beforeExitTeardown: prepareForUpdateSwap,
      relaunchArgs: launchConfig.relaunchArgs,
      onCoarseStateChanged: _onUpdateCoarseStateChanged,
      clock: _clock,
      timerFactory: updateTimerFactory,
    );
    aboutViewModel = AboutViewModel(
      repository: AboutRepository(
        service: aboutService ?? createDefaultAboutService(),
      ),
    );
    if (repository.transport.isConnected) {
      _connectionState = ClientConnectionState.connecting;
    }
    clientConnectingEvent.addListener(repository.bus, _onClientConnecting);
    clientConnectFailedEvent.addListener(
      repository.bus,
      _onClientConnectFailed,
    );
    clientMessageReceivedEvent.addListener(repository.bus, _onServerMessage);
    clientDisconnectedEvent.addListener(repository.bus, _onClientDisconnected);
  }

  static TerminalColorResolver _buildColorResolver(
    TerminalThemeSettings settings,
    tui.TerminalBrightness brightness,
  ) => TerminalColorResolver(
    theme: settings.resolveActiveTheme(brightness),
    settings: settings,
  );

  void _hydrateSavedRelaySettings() {
    if (_activeClientToken.isEmpty &&
        _relayCredentials.clientToken.isNotEmpty) {
      _activeClientToken = _relayCredentials.clientToken;
    }
    if (_activeCasterToken.isEmpty &&
        _relayCredentials.casterToken.isNotEmpty) {
      _activeCasterToken = _relayCredentials.casterToken;
    }
    if (launchConfig.serverUri == CastLaunchConfig.defaultServerUri &&
        _relayCredentials.serverUrl.trim().isNotEmpty) {
      try {
        _activeRelayUri = CastLaunchConfig.parseRelayUri(
          _relayCredentials.serverUrl,
        );
      } on FormatException {
        // Ignore corrupt stored URL and keep launchConfig fallback.
      }
    }
    _hydrateSavedIapSettings();
    _shouldAutoConnectRelay =
        !launchConfig.promptForConnection ||
        _activeClientToken.isNotEmpty ||
        _relayCredentials.serverUrl.trim().isNotEmpty;
  }

  void _hydrateSavedIapSettings() {
    final hasLaunchIap =
        _activeIapServiceAccount.isNotEmpty ||
        _activeIapKeyFilePath.isNotEmpty ||
        launchConfig.iapTokenProvider != null ||
        launchConfig.iapTokenProviderFactory != null;
    if (!hasLaunchIap) {
      final savedKey = _relayCredentials.iapKeyFilePath.trim();
      final savedSa = _relayCredentials.iapServiceAccount.trim();
      // Keep modes mutually exclusive if hand-edited settings.json sets both.
      if (savedKey.isNotEmpty) {
        _activeIapKeyFilePath = savedKey;
        _activeIapServiceAccount = '';
      } else if (savedSa.isNotEmpty) {
        _activeIapServiceAccount = savedSa;
        _activeIapKeyFilePath = '';
      }
    }
    if (_activeGcloudPath.isEmpty &&
        _relayCredentials.gcloudPath.trim().isNotEmpty) {
      _activeGcloudPath = _relayCredentials.gcloudPath.trim();
    }
  }

  /// Sub-listenable notified on tab/focus/overlay/theme/settings changes.
  ChangeNotifier get chromeNotifier => _chromeNotifier;

  /// Ordered workspace tabs.
  List<FtermTabState> get tabs => List<FtermTabState>.unmodifiable(_tabs);

  /// Active tab index (`0` when empty).
  int get activeTabIndex =>
      _tabs.isEmpty ? 0 : _activeTabIndex.clamp(0, _tabs.length - 1);

  /// Active workspace tab, or `null` when no tabs are open.
  FtermTabState? get activeTab => _tabs.isEmpty ? null : _tabs[activeTabIndex];

  /// Active split tree in [activeTab], or `null` when empty.
  SplitTreeModel? get activeSplitTree => activeTab?.splitTree;

  /// Focused pane controller in [activeTab], or `null` when empty.
  FtermPaneController? get focusedPane {
    final tab = activeTab;
    if (tab == null) return null;
    return _panes[tab.splitTree.focusedPaneId];
  }

  /// Looks up a mounted pane controller by [paneId].
  FtermPaneController? paneById(String paneId) => _panes[paneId];

  /// Read-only view of all mounted pane controllers keyed by pane ID.
  Map<String, FtermPaneController> get panes => _panesView;

  /// Whether this host supports local interactive desktop shells.
  bool get isDesktopHost => localHostDriver.isSupported;

  /// Whether a `Ctrl+\` modal chord is currently armed.
  bool get isLeaderArmed => _leaderArmed;

  /// Active modal overlay (`FtermOverlay.none` when workspace is clear).
  FtermOverlay get activeOverlay => _activeOverlay;

  /// Running semantic version used for the What's New pill and modal header.
  String get currentWhatsNewVersion =>
      updateViewModel.currentVersion.toString();

  /// Whether the non-blocking tab-bar `NEW` pill should appear for the current
  /// application version.
  bool get shouldShowWhatsNewPill =>
      _preferences.lastSeenWhatsNewVersion != currentWhatsNewVersion;

  /// Whether live shader chains, background opacity, or Perf HUD visibility
  /// differ from the snapshot captured when opening the What's New modal.
  bool get hasWhatsNewPreviewChanges {
    final snapshot = _whatsNewPreviewSnapshot;
    if (snapshot == null) return false;
    return !listEquals(backgroundShaderChain, snapshot.backgroundChain) ||
        !listEquals(foregroundShaderChain, snapshot.foregroundChain) ||
        (backgroundOpacity - snapshot.backgroundOpacity).abs() > 1e-6 ||
        showPerfHud != snapshot.showPerfHud;
  }

  _WhatsNewPreviewSnapshot _captureWhatsNewPreviewSnapshot() => (
    backgroundChain: List<String>.unmodifiable(backgroundShaderChain),
    foregroundChain: List<String>.unmodifiable(foregroundShaderChain),
    backgroundOpacity: backgroundOpacity,
    showPerfHud: showPerfHud,
  );

  /// Opens [FtermOverlay.whatsNew], capturing a pre-preview snapshot for
  /// one-click revert and persisting [currentWhatsNewVersion] so the tab-bar
  /// `NEW` pill clears once viewed.
  void openWhatsNew() {
    if (_disposed) return;
    if (_activeOverlay != FtermOverlay.whatsNew) {
      _whatsNewPreviewSnapshot = _captureWhatsNewPreviewSnapshot();
    }
    final version = currentWhatsNewVersion;
    if (_preferences.lastSeenWhatsNewVersion != version) {
      updatePreferences(
        _preferences.copyWith(lastSeenWhatsNewVersion: version),
      );
    }
    _setOverlay(FtermOverlay.whatsNew);
  }

  /// Applies a live shader chain preview from the What's New modal, capturing
  /// the pre-preview state if needed and auto-revealing background opacity when
  /// [backgroundChain] is non-empty.
  Future<void> applyWhatsNewShaderPreview({
    required List<String> backgroundChain,
    required List<String> foregroundChain,
  }) async {
    if (_disposed) return;
    _whatsNewPreviewSnapshot ??= _captureWhatsNewPreviewSnapshot();
    final nextBg = _normalizeShaderEntries(backgroundChain);
    final nextFg = _normalizeShaderEntries(foregroundChain);
    _preferences = _preferences.copyWith(
      backgroundShaderPaths: nextBg,
      foregroundShaderPaths: nextFg,
    );
    _workspaceSettings = _workspaceSettings.copyWith(
      themeSettings: _workspaceSettings.themeSettings.copyWith(
        backgroundShaderChain: nextBg,
        foregroundShaderChain: nextFg,
      ),
    );
    if (nextBg.isNotEmpty) {
      _maybeAutoLowerBackgroundOpacity();
    }
    _rebuildActiveShaderConfig();
    _settingsSaver.save(_workspaceSettings);
    _settingsSaver.savePreferences(_preferences);
    _notifyChromeChanged();
    await _syncActiveShaders();
  }

  /// Restores the shader chains, background opacity, and Perf HUD visibility
  /// captured before the What's New preview session began.
  Future<void> revertWhatsNewPreview() async {
    final snapshot = _whatsNewPreviewSnapshot;
    if (_disposed || snapshot == null) return;
    final nextBg = _normalizeShaderEntries(snapshot.backgroundChain);
    final nextFg = _normalizeShaderEntries(snapshot.foregroundChain);
    final safeOpacity = snapshot.backgroundOpacity.isFinite
        ? snapshot.backgroundOpacity.clamp(0.0, 1.0)
        : 1.0;
    _preferences = _preferences.copyWith(
      backgroundShaderPaths: nextBg,
      foregroundShaderPaths: nextFg,
      showPerfHud: snapshot.showPerfHud,
    );
    _workspaceSettings = _workspaceSettings.copyWith(
      themeSettings: _workspaceSettings.themeSettings.copyWith(
        backgroundShaderChain: nextBg,
        foregroundShaderChain: nextFg,
        backgroundOpacity: safeOpacity,
      ),
    );
    _rebuildActiveShaderConfig();
    _settingsSaver.save(_workspaceSettings);
    _settingsSaver.savePreferences(_preferences);
    _notifyChromeChanged();
    await _syncActiveShaders();
  }

  /// Optional transient status message shown in corner pill / modal header.
  String? get statusBanner => _statusBanner;

  /// Queued files staged for the [FtermOverlay.fileUpload] dialog.
  List<DroppedFileSource> get pendingUploadFiles => _pendingUploadFiles;

  /// Active multi-file upload coordinator.
  FileUploadCoordinator get uploadCoordinator => _uploadCoordinator;

  /// Current workspace visual and interaction settings.
  CastWorkspaceSettings get workspaceSettings => _workspaceSettings;

  /// Current `fterm` audio & chrome preferences.
  FtermPreferences get preferences => _preferences;

  /// Effective base terminal font size resolved from [preferences] and
  /// [defaultFontSize] (before display `TextScaler` scaling).
  double get effectiveFontSize =>
      _preferences.effectiveFontSize(defaultFontSize);

  /// Persisted/active relay credentials snapshot.
  RelayCredentials get relayCredentials => RelayCredentials(
    serverUrl: _activeRelayUri.toString(),
    clientToken: _activeClientToken,
    casterToken: _activeCasterToken,
    iapServiceAccount: _activeIapServiceAccount,
    iapKeyFilePath: _activeIapKeyFilePath,
    gcloudPath: _activeGcloudPath,
  );

  /// Active relay `/v1/client` URI.
  Uri get activeRelayUri => _activeRelayUri;

  /// Active viewer bearer token.
  String get activeClientToken => _activeClientToken;

  /// Active caster bearer token used when publishing local panes.
  String get activeCasterToken => _activeCasterToken;

  /// Active Cloud Run IAP service account email (`''` when unset).
  String get activeIapServiceAccount => _activeIapServiceAccount;

  /// Active Cloud Run IAP service account JSON key file path (`''` when unset).
  String get activeIapKeyFilePath => _activeIapKeyFilePath;

  /// Active custom `gcloud` executable path override (`''` for auto-probing).
  String get activeGcloudPath => _activeGcloudPath;

  /// Probes `PATH` and standard SDK locations for an installed `gcloud`
  /// executable on desktop, returning `null` when unavailable or on Web.
  String? probeGcloudExecutable() =>
      localHostDriver.isSupported ? _gcloudPathProber() : null;

  /// Resolved color theme matching current appearance & system polarity.
  tui.TerminalColorTheme get activeTerminalTheme => _colorResolver.theme;

  /// Active `copyOnSelect` preference.
  bool get copyOnSelect => _workspaceSettings.copyOnSelect;

  /// Active F12 shortcut gate (`false` = passthrough to terminal).
  bool get f12ShortcutsEnabled => _workspaceSettings.f12ShortcutsEnabled;

  /// Active dock position (`top`, `left`, or `hidden`).
  DockPosition get dockPosition => _workspaceSettings.dockPosition;

  /// Shared GPU/WebGL2 shader controller powering all panes in this workspace.
  TerminalShaderController get shaderController => _shaderController;

  /// Backing platform store for user `.glsl` files and wallpaper images.
  ShaderProfileStore get shaderProfileStore => _shaderProfileStore;

  /// Active compiled shader pass chains, animation mode, opacity, and
  /// wallpaper configuration forwarded to every pane's `TerminalSurface`.
  TerminalShaderConfig get activeShaderConfig => _activeShaderConfig;

  /// Default opacity applied automatically when enabling a wallpaper or
  /// background shader while [backgroundOpacity] is still `1.0` (`100%`), so
  /// the background layer is immediately visible.
  static const double autoRevealBackgroundOpacity = 0.5;

  /// Active default-background cell opacity (`0.0..1.0`, persisted in
  /// [TerminalThemeSettings]).
  double get backgroundOpacity =>
      _workspaceSettings.themeSettings.backgroundOpacity;

  /// Whether the in-app FPS and frame-timing performance HUD is visible.
  bool get showPerfHud => _preferences.showPerfHud;

  /// Persisted Windows GPU adapter preference read by the native launcher.
  GpuDriverPreference get gpuDriverPreference =>
      _preferences.gpuDriverPreference;

  /// GPU adapter preference active when this process launched.
  GpuDriverPreference get initialGpuDriverPreference =>
      _initialGpuDriverPreference;

  /// Whether changing [gpuDriverPreference] requires restarting `fterm`.
  bool get gpuDriverRestartRequired =>
      _preferences.gpuDriverPreference != _initialGpuDriverPreference;

  /// Optional maximum ambient shader FPS (`null` = uncapped display vsync).
  int? get maxShaderFps => _preferences.maxShaderFps;

  /// Active GPU adapter description reported by the native host or backend
  /// (e.g. `NVIDIA GeForce RTX 5080 Laptop GPU` or `Intel(R) Graphics`).
  String? get activeGpuAdapterName =>
      _activeGpuAdapterName ?? readShaderBackendDiagnostics()?.gpuRenderer;

  /// Dedicated GPU video memory in MiB reported by the native host, if known.
  int? get activeGpuVramMb => _activeGpuVramMb;

  /// Records the active GPU adapter description and dedicated VRAM reported by
  /// the native platform runner.
  void setActiveGpuAdapterInfo({String? name, int? dedicatedVramMb}) {
    final trimmed = name?.trim();
    final nextName = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    final nextVram = (dedicatedVramMb != null && dedicatedVramMb > 0)
        ? dedicatedVramMb
        : null;
    if (_disposed ||
        (_activeGpuAdapterName == nextName && _activeGpuVramMb == nextVram)) {
      return;
    }
    _activeGpuAdapterName = nextName;
    _activeGpuVramMb = nextVram;
    _notifyChromeChanged();
  }

  /// Whether a performance trace capture is currently active.
  bool get isRecordingTrace => traceRecorder.isRecording;

  /// Most recent completed trace export result, if any.
  TraceExportResult? get lastTraceExport => traceRecorder.lastExport;

  /// Reads live GPU diagnostics when the active backend supports inspection.
  ShaderBackendDiagnostics? readShaderBackendDiagnostics() =>
      switch (_shaderController.backend) {
        final DiagnosableShaderBackend diagnosable =>
          diagnosable.readDiagnostics(),
        _ => null,
      };

  /// Active trust policy for CLI `ESC _ S` shaders on local panes.
  CliShaderPolicy get localCliShaderPolicy => _preferences.localCliShaderPolicy;

  /// Active trust policy for CLI `ESC _ S` shaders on remote `termui_cast` panes.
  CliShaderPolicy get remoteCliShaderPolicy =>
      _preferences.remoteCliShaderPolicy;

  /// Active stacking policy when CLI full-pane `a=set` shaders coexist with user shaders.
  CliFullPaneShaderMode get cliFullPaneShaderMode =>
      _preferences.cliFullPaneShaderMode;

  /// Persisted lowercase SHA-256 hashes of user-trusted custom CLI GLSL shaders.
  Set<String> get trustedCliShaderHashes => _preferences.trustedCliShaderHashes;

  /// Queued custom CLI GLSL approval prompts across mounted panes (focused pane first).
  List<PendingCliShaderApproval> get pendingCliShaderApprovals {
    final focusedId = focusedPane?.paneId;
    final focused = <PendingCliShaderApproval>[];
    final others = <PendingCliShaderApproval>[];
    for (final pane in _panes.values) {
      final list = pane.cliShaderState.pendingApprovals;
      if (list.isEmpty) continue;
      if (pane.paneId == focusedId) {
        focused.addAll(list);
      } else {
        others.addAll(list);
      }
    }
    return List<PendingCliShaderApproval>.unmodifiable([...focused, ...others]);
  }

  /// Active full-pane conflict prompt when [cliFullPaneShaderMode] is
  /// [CliFullPaneShaderMode.askOnConflict], prioritizing the focused pane.
  PendingCliFullPaneConflict? get activeCliFullPaneConflict {
    final focusedConflict = focusedPane?.cliShaderState.pendingFullPaneConflict;
    if (focusedConflict != null) return focusedConflict;
    for (final pane in _panes.values) {
      final conflict = pane.cliShaderState.pendingFullPaneConflict;
      if (conflict != null) return conflict;
    }
    return null;
  }

  /// Active blocked-remote-shader notice when a remote pane received `0x1C`
  /// shader frames while [remoteCliShaderPolicy] is [CliShaderPolicy.disabled],
  /// prioritizing the focused pane.
  PendingBlockedRemoteShadersNotice? get activeBlockedRemoteShadersNotice {
    final focusedNotice =
        focusedPane?.cliShaderState.pendingBlockedRemoteNotice;
    if (focusedNotice != null) return focusedNotice;
    for (final pane in _panes.values) {
      final notice = pane.cliShaderState.pendingBlockedRemoteNotice;
      if (notice != null) return notice;
    }
    return null;
  }

  /// Dismisses the blocked remote CLI shader notice on [paneId].
  void dismissBlockedRemoteShadersNotice(String paneId) {
    if (_disposed) return;
    _panes[paneId]?.cliShaderState.dismissBlockedRemoteNotice();
    _notifyChromeChanged();
  }

  /// Updates the local pane CLI shader trust policy and syncs all local panes.
  void setLocalCliShaderPolicy(CliShaderPolicy policy) {
    if (_disposed || _preferences.localCliShaderPolicy == policy) return;
    updatePreferences(_preferences.copyWith(localCliShaderPolicy: policy));
    _syncPaneCliShaderPolicies();
  }

  /// Updates the remote `termui_cast` CLI shader trust policy and syncs all remote panes.
  ///
  /// When upgrading away from [CliShaderPolicy.disabled], requests a keyframe
  /// for each mounted remote session so active `0x1C` shader definitions,
  /// regions, and transforms replay immediately.
  void setRemoteCliShaderPolicy(CliShaderPolicy policy) {
    if (_disposed || _preferences.remoteCliShaderPolicy == policy) return;
    final wasDisabled =
        _preferences.remoteCliShaderPolicy == CliShaderPolicy.disabled;
    updatePreferences(_preferences.copyWith(remoteCliShaderPolicy: policy));
    _syncPaneCliShaderPolicies();
    if (wasDisabled && policy != CliShaderPolicy.disabled) {
      _requestKeyframesForActiveRemoteSessions();
    }
  }

  void _requestKeyframesForActiveRemoteSessions() {
    final requested = <SessionId>{};
    for (final pane in _panes.values) {
      final sessionId = pane.remoteSessionId;
      if (sessionId == null || !requested.add(sessionId)) continue;
      repository.requestKeyframe(sessionId);
    }
  }

  /// Updates how CLI `a=set` full-pane shaders combine with user Settings shaders.
  void setCliFullPaneShaderMode(CliFullPaneShaderMode mode) {
    if (_disposed || _preferences.cliFullPaneShaderMode == mode) return;
    updatePreferences(_preferences.copyWith(cliFullPaneShaderMode: mode));
    _syncPaneCliShaderPolicies();
  }

  /// Clears all persisted trusted custom CLI GLSL SHA-256 digests.
  void clearTrustedCliShaderHashes() {
    if (_disposed || _preferences.trustedCliShaderHashes.isEmpty) return;
    updatePreferences(
      _preferences.copyWith(trustedCliShaderHashes: const <String>{}),
    );
    _syncPaneCliShaderPolicies();
  }

  /// Approves all pending custom CLI GLSL prompts strictly matching [sha256].
  ///
  /// When [remember] is `true`, persists [sha256] in [trustedCliShaderHashes].
  void approveCliShaderHash(String sha256, {required bool remember}) {
    if (_disposed) return;
    final normalized = sha256.trim().toLowerCase();
    if (remember && !_preferences.trustedCliShaderHashes.contains(normalized)) {
      final next = <String>{..._preferences.trustedCliShaderHashes, normalized};
      updatePreferences(_preferences.copyWith(trustedCliShaderHashes: next));
    }
    for (final pane in _panes.values) {
      pane.cliShaderState.approveHash(normalized, remember: remember);
    }
    _syncActiveCliFullPaneShaders();
    _notifyChromeChanged();
  }

  /// Denies any pending custom CLI GLSL prompt matching [sha256].
  void denyCliShaderHash(String sha256) {
    if (_disposed) return;
    final normalized = sha256.trim().toLowerCase();
    for (final pane in _panes.values) {
      pane.cliShaderState.denyHash(normalized);
    }
    _notifyChromeChanged();
  }

  /// Denies and clears all queued custom CLI GLSL prompts on [paneId].
  void denyAllPendingCliShaders(String paneId) {
    if (_disposed) return;
    _panes[paneId]?.cliShaderState.denyAllPending();
    _notifyChromeChanged();
  }

  /// Resolves an active [CliFullPaneShaderMode.askOnConflict] prompt on [paneId].
  void resolveCliFullPaneConflict(
    String paneId,
    CliFullPaneConflictChoice choice,
  ) {
    if (_disposed) return;
    _panes[paneId]?.cliShaderState.resolveFullPaneConflict(choice);
    _syncActiveCliFullPaneShaders();
    _notifyChromeChanged();
  }

  /// Ordered background shader presets or custom `.glsl` paths.
  List<String> get backgroundShaderChain =>
      _preferences.backgroundShaderPaths.isNotEmpty
      ? _preferences.backgroundShaderPaths
      : _workspaceSettings.themeSettings.backgroundShaderChain;

  /// Ordered foreground shader presets or custom `.glsl` paths.
  List<String> get foregroundShaderChain =>
      _preferences.foregroundShaderPaths.isNotEmpty
      ? _preferences.foregroundShaderPaths
      : _workspaceSettings.themeSettings.foregroundShaderChain;

  /// Active `iTime` animation policy for time-varying fragment shaders.
  ShaderAnimationMode get shaderAnimationMode =>
      _preferences.shaderAnimationMode;

  /// Optional runtime backend rollback override (`null` = auto).
  ShaderBackendKind? get shaderBackendOverride =>
      _preferences.shaderBackendOverride;

  /// Configured wallpaper path or Web storage key, or `null` if none.
  String? get backgroundImagePath => _preferences.backgroundImagePath;

  /// Path to the user's desktop shaders directory, or `null` on Web/test.
  String? get shadersDirectoryPath => _shaderProfileStore.shadersDirectoryPath;

  /// Most recent GLSL compilation or validation error, if any.
  ShaderCompileException? get lastShaderCompileError =>
      _shaderController.lastCompileError;

  /// Most recent wallpaper or shader file I/O validation error, if any.
  String? get lastShaderAssetError => _lastShaderAssetError;

  /// Sorted custom `.glsl` / `.frag` paths discovered in [shaderProfileStore].
  List<String> get availableCustomShaders => _availableCustomShaders;

  /// Returns the 8-float uniform parameter vector (`uParams0`, `uParams1`)
  /// configured for [passId].
  Float32List shaderParamsFor(String passId) {
    final stored = _shaderParamsByPass[passId];
    final result = Float32List(ShaderPassSpec.paramCount);
    if (stored == null) return result;
    final count = math.min(stored.length, result.length);
    for (var i = 0; i < count; i++) {
      result[i] = stored[i];
    }
    return result;
  }

  /// Whether the 28px tab bar should collapse when `<= 1` tab is open.
  bool get shouldShowTabBar {
    if (dockPosition == DockPosition.hidden) return false;
    if (_preferences.autoHideSingleTab && _tabs.length <= 1) return false;
    return true;
  }

  /// Relay WebSocket connection state.
  ClientConnectionState get connectionState => _connectionState;

  /// Latest authentication rejection message when [connectionState] is `authFailed`.
  String? get authErrorMessage => _authErrorMessage;

  /// Current relay subscriber count reported for remote [sessionId], or `0`.
  int subscriberCountFor(SessionId sessionId) {
    for (final session in _remoteDirectorySessions) {
      if (session.id == sessionId) return session.subscriberCount;
    }
    return 0;
  }

  /// Counts of bell events observed during this session.
  int get bellEventsCount => _bellEventsCount;

  /// Count of `ESC _ A` audio events observed during this session.
  int get audioEventsCount => _audioEventsCount;

  /// Count of shell title updates observed during this session.
  int get titleEventsCount => _titleEventsCount;

  /// Remote sessions discovered on the relay, excluding sessions currently
  /// cast by local panes inside this `fterm` process.
  List<SessionSummary> get availableRemoteSessions => [
    for (final session in _remoteDirectorySessions)
      if (!_ownedSharedSessionIds.contains(session.id)) session,
  ];

  /// Immutable copy of local self-casted session identifiers currently excluded
  /// from the Session Picker.
  Set<SessionId> get ownedSharedSessionIds =>
      Set<SessionId>.unmodifiable(_ownedSharedSessionIds);

  /// Current clock instance.
  Clock get workspaceClock => _clock;

  /// Counts live local shell panes and active outbound relay broadcasts so
  /// restarting for an update warns before terminating running sessions.
  ({int activeLocalShells, int activeLiveShares}) get activeLocalSessionCounts {
    var shells = 0;
    var shares = 0;
    for (final pane in _panes.values) {
      if (!pane.isLocal) continue;
      if (!pane.hasExited) {
        shells += 1;
      }
      final shareState = pane.shareSnapshot.state;
      if (shareState == LocalShareState.live ||
          shareState == LocalShareState.connecting) {
        shares += 1;
      }
    }
    return (activeLocalShells: shells, activeLiveShares: shares);
  }

  /// Flushes settings and closes all local PTYs and outbound shares in parallel
  /// before an update swap, bounded by a 2-second timeout.
  Future<void> prepareForUpdateSwap() async {
    if (_disposed) return;
    _settingsSaver.flush();
    await _settingsSaver.flushAsync();
    final activePanes = [..._panes.values];
    _panes.clear();
    _tabs.clear();
    _ownedSharedSessionIds.clear();
    _activeTabIndex = 0;
    try {
      await Future.wait([
        for (final pane in activePanes) pane.dispose(disposePort: true),
      ]).timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // Local PTYs already received terminate concurrently with stopShare().
    }
  }

  /// Starts initial tabs (local shell on Desktop; auto-relay or Connect modal on Web).
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    updateViewModel.start();
    if (localHostDriver.isSupported) {
      try {
        await openLocalShellTab();
      } on Object catch (error) {
        if (!_disposed) {
          _setStatusBanner('Local shell failed: $error');
        }
      }
      if (!_disposed && _shouldAutoConnectRelay) {
        _startInitialRelayConnection();
      }
      _maybeStartLaunchTrace();
      return;
    }
    if (launchConfig.promptForConnection &&
        _activeClientToken.isEmpty &&
        _relayCredentials.clientToken.isEmpty) {
      _setOverlay(FtermOverlay.connect);
    } else {
      _startInitialRelayConnection();
    }
    _syncAutoRemoteTabs();
    _maybeStartLaunchTrace();
  }

  void _maybeStartLaunchTrace() {
    if (_disposed) return;
    if (launchConfig.traceOutPath == null &&
        launchConfig.traceDuration == null) {
      return;
    }
    unawaited(
      startTraceRecording(
        outputBasePath: launchConfig.traceOutPath,
        duration: launchConfig.traceDuration,
        exitOnComplete: launchConfig.traceExitOnComplete,
      ),
    );
  }

  void _startInitialRelayConnection() {
    final endpointChanged =
        _activeRelayUri != launchConfig.serverUri ||
        _activeClientToken != launchConfig.token;
    IapTokenProvider? startupIap;
    var replaceIap = false;
    if (_activeRelayUri.scheme == 'wss' &&
        (endpointChanged || launchConfig.iapTokenProvider == null)) {
      try {
        startupIap = resolveIapTokenProviderFor(_activeRelayUri);
        replaceIap = startupIap != null;
      } on Object catch (error) {
        _setStatusBanner('Saved Cloud Run IAP config invalid: $error');
        return;
      }
    }
    if (endpointChanged || replaceIap) {
      unawaited(
        repository.reconnect(
          (serverUri: _activeRelayUri, token: _activeClientToken),
          iapTokenProvider: startupIap,
          replaceIapTokenProvider: replaceIap,
        ),
      );
      return;
    }
    unawaited(repository.connect(retryOnFailure: true));
  }

  /// Resolves an audience-scoped [IapTokenProvider] for [targetUri] (`wss://`
  /// only) from active runtime/saved IAP settings or startup [launchConfig].
  IapTokenProvider? resolveIapTokenProviderFor(Uri targetUri) {
    if (targetUri.scheme != 'wss') return null;
    final fromLaunch = _tryReuseLaunchIapProvider(targetUri);
    if (fromLaunch != null) return fromLaunch;
    if (_activeIapServiceAccount.isEmpty && _activeIapKeyFilePath.isEmpty) {
      return null;
    }
    final serviceAccount = _activeIapServiceAccount.isEmpty
        ? null
        : _activeIapServiceAccount;
    final keyFilePath = _activeIapKeyFilePath.isEmpty
        ? null
        : _activeIapKeyFilePath;
    if (serviceAccount != null &&
        !TokenAuthenticator.isValidServiceAccountEmail(serviceAccount)) {
      throw FormatException(
        'Invalid GCP service account email: "$serviceAccount".',
      );
    }
    final audience = TokenAuthenticator.iapAudienceForWebSocketUri(targetUri);
    return _iapProviderCache.putIfAbsent(
      audience,
      () => _iapProviderBuilder(
        serverUri: targetUri,
        serviceAccount: serviceAccount,
        keyFilePath: keyFilePath,
        gcloudPath: _activeGcloudPath.isEmpty ? null : _activeGcloudPath,
      ),
    );
  }

  IapTokenProvider? _tryReuseLaunchIapProvider(Uri targetUri) {
    if (_hasRuntimeIapOverride) return null;
    if (_activeIapServiceAccount != launchConfig.iapServiceAccount.trim() ||
        _activeIapKeyFilePath != launchConfig.iapKeyFilePath.trim() ||
        _activeGcloudPath != launchConfig.gcloudPath.trim()) {
      return null;
    }
    if (launchConfig.iapTokenProviderFactory != null) {
      return launchConfig.iapTokenProviderFor(targetUri);
    }
    if (launchConfig.iapTokenProvider != null &&
        launchConfig.serverUri.scheme == 'wss' &&
        TokenAuthenticator.iapAudienceForWebSocketUri(targetUri) ==
            TokenAuthenticator.iapAudienceForWebSocketUri(
              launchConfig.serverUri,
            )) {
      return launchConfig.iapTokenProvider;
    }
    return null;
  }

  /// Connects or reconnects the relay client repository using explicit credentials
  /// and optionally persists them to `0600` desktop storage.
  Future<void> connectRelay({
    required Uri serverUri,
    required String clientToken,
    String? casterToken,
    String? iapServiceAccount,
    String? iapKeyFilePath,
    String? gcloudPath,
    bool persistCredentials = true,
  }) async {
    if (_disposed) return;
    final hasIapUpdate =
        iapServiceAccount != null ||
        iapKeyFilePath != null ||
        gcloudPath != null;
    final nextSa = iapServiceAccount != null
        ? iapServiceAccount.trim()
        : _activeIapServiceAccount;
    final nextKey = iapKeyFilePath != null
        ? iapKeyFilePath.trim()
        : _activeIapKeyFilePath;
    final nextGcloud = gcloudPath != null
        ? gcloudPath.trim()
        : _activeGcloudPath;

    if (hasIapUpdate) {
      _validateRelayIapSelection(
        serverUri: serverUri,
        serviceAccount: nextSa,
        keyFilePath: nextKey,
      );
    }
    final iapChanged =
        nextSa != _activeIapServiceAccount ||
        nextKey != _activeIapKeyFilePath ||
        nextGcloud != _activeGcloudPath;
    final nextIapProvider = _buildRelayIapProvider(
      serverUri: serverUri,
      hasIapUpdate: hasIapUpdate,
      iapChanged: iapChanged,
      serviceAccount: nextSa,
      keyFilePath: nextKey,
      gcloudPath: nextGcloud,
    );

    if (iapChanged) {
      _iapProviderCache.clear();
    }
    if (hasIapUpdate) {
      _hasRuntimeIapOverride = true;
    }
    _activeIapServiceAccount = nextSa;
    _activeIapKeyFilePath = nextKey;
    _activeGcloudPath = nextGcloud;
    if (nextIapProvider != null && serverUri.scheme == 'wss') {
      _iapProviderCache[TokenAuthenticator.iapAudienceForWebSocketUri(
            serverUri,
          )] =
          nextIapProvider;
    }

    _activeRelayUri = serverUri;
    _activeClientToken = clientToken;
    if (casterToken != null) {
      _activeCasterToken = casterToken;
    }
    _shouldAutoConnectRelay = true;
    _statusBanner = null;

    if (persistCredentials && localHostDriver.isSupported) {
      _relayCredentials = RelayCredentials(
        serverUrl: serverUri.toString(),
        clientToken: clientToken,
        casterToken: _activeCasterToken,
        iapServiceAccount: _activeIapServiceAccount,
        iapKeyFilePath: _activeIapKeyFilePath,
        gcloudPath: _activeGcloudPath,
      );
      saveStoredRelayCredentials(_storage, _relayCredentials);
    }
    if (_activeOverlay == FtermOverlay.connect) {
      _activeOverlay = FtermOverlay.none;
    }
    _notifyChromeChanged();
    await repository.reconnect(
      (serverUri: serverUri, token: clientToken),
      iapTokenProvider: nextIapProvider,
      replaceIapTokenProvider: true,
    );
  }

  static void _validateRelayIapSelection({
    required Uri serverUri,
    required String serviceAccount,
    required String keyFilePath,
  }) {
    if (serviceAccount.isNotEmpty && keyFilePath.isNotEmpty) {
      throw const FormatException(
        'Specify either an IAP service account email or a JSON key file, not both.',
      );
    }
    if ((serviceAccount.isNotEmpty || keyFilePath.isNotEmpty) &&
        serverUri.scheme != 'wss') {
      throw const FormatException(
        'Cloud Run IAP authentication requires a wss:// relay URL.',
      );
    }
    if (serviceAccount.isNotEmpty &&
        !TokenAuthenticator.isValidServiceAccountEmail(serviceAccount)) {
      throw const FormatException('Invalid GCP service account email.');
    }
  }

  IapTokenProvider? _buildRelayIapProvider({
    required Uri serverUri,
    required bool hasIapUpdate,
    required bool iapChanged,
    required String serviceAccount,
    required String keyFilePath,
    required String gcloudPath,
  }) {
    if (serverUri.scheme != 'wss') return null;
    if (!hasIapUpdate) {
      return resolveIapTokenProviderFor(serverUri);
    }
    if (serviceAccount.isEmpty && keyFilePath.isEmpty) {
      return null;
    }
    if (!iapChanged) {
      final audience = TokenAuthenticator.iapAudienceForWebSocketUri(serverUri);
      if (_iapProviderCache.containsKey(audience)) {
        return _iapProviderCache[audience];
      }
    }
    return _iapProviderBuilder(
      serverUri: serverUri,
      serviceAccount: serviceAccount.isEmpty ? null : serviceAccount,
      keyFilePath: keyFilePath.isEmpty ? null : keyFilePath,
      gcloudPath: gcloudPath.isEmpty ? null : gcloudPath,
    );
  }

  /// Opens a new local shell tab (desktop only).
  Future<String?> openLocalShellTab([LocalShellConfig? config]) async {
    if (_disposed || !localHostDriver.isSupported) return null;
    final shellConfig = config ?? _defaultLocalShellConfig();
    final host = await localHostDriver.openShell(shellConfig);
    if (_disposed) {
      await host.dispose();
      return null;
    }
    final paneId = _allocatePaneId();
    final pane = _createPaneController(
      paneId: paneId,
      port: host.port,
      localHost: host,
    );
    _panes[paneId] = pane;
    final tabId = _allocateTabId();
    _tabs.add(
      FtermTabState(tabId: tabId, splitTree: SplitTreeModel.single(paneId)),
    );
    _activeTabIndex = _tabs.length - 1;
    _syncFocusedPaneStates();
    _activeOverlay = FtermOverlay.none;
    _notifyChromeChanged();
    return tabId;
  }

  /// Opens or focuses a tab viewing [sessionId] from the relay.
  String? openRemoteSessionTab(SessionId sessionId) {
    if (_disposed) return null;
    _dismissedRemoteSessions.remove(sessionId);
    final existingIdx = _findTabIndexForSession(sessionId);
    if (existingIdx >= 0) {
      selectTab(existingIdx);
      _activeOverlay = FtermOverlay.none;
      _notifyChromeChanged();
      return _tabs[existingIdx].tabId;
    }
    final port = repository.openTerminalPort(sessionId);
    final paneId = _allocatePaneId();
    final pane = _createPaneController(
      paneId: paneId,
      port: port,
      remoteSessionId: sessionId,
    );
    _panes[paneId] = pane;
    final tabId = _allocateTabId();
    _tabs.add(
      FtermTabState(tabId: tabId, splitTree: SplitTreeModel.single(paneId)),
    );
    _activeTabIndex = _tabs.length - 1;
    _syncFocusedPaneStates();
    _activeOverlay = FtermOverlay.none;
    _notifyChromeChanged();
    return tabId;
  }

  /// Splits the currently focused pane along [axis].
  ///
  /// On Desktop hosts, spawns a new local shell in the new split pane (unless
  /// [remoteSessionId] is explicitly specified). On Web/viewer hosts, opens a
  /// new [RemoteTerminalPort] attached to [remoteSessionId] or the focused
  /// pane's remote session.
  Future<String?> splitFocusedPane(
    SplitAxis axis, {
    SessionId? remoteSessionId,
    LocalShellConfig? localShellConfig,
  }) async {
    if (_disposed) return null;
    final tab = activeTab;
    if (tab == null) {
      return _openSplitInEmptyWorkspace(
        remoteSessionId: remoteSessionId,
        localShellConfig: localShellConfig,
      );
    }

    final targetPaneId = tab.splitTree.focusedPaneId;
    final newPaneId = _allocatePaneId();
    final newPane = await _createSplitPane(
      tab: tab,
      targetPaneId: targetPaneId,
      newPaneId: newPaneId,
      currentPane: _panes[targetPaneId],
      remoteSessionId: remoteSessionId,
      localShellConfig: localShellConfig,
    );
    if (newPane == null) return null;

    _panes[newPaneId] = newPane;
    tab.splitTree = tab.splitTree.splitPane(
      targetPaneId: targetPaneId,
      newPaneId: newPaneId,
      axis: axis,
    );
    _syncFocusedPaneStates();
    _notifyChromeChanged();
    return newPaneId;
  }

  Future<String?> _openSplitInEmptyWorkspace({
    SessionId? remoteSessionId,
    LocalShellConfig? localShellConfig,
  }) async {
    if (localHostDriver.isSupported && remoteSessionId == null) {
      return openLocalShellTab(localShellConfig);
    }
    if (remoteSessionId != null) {
      return openRemoteSessionTab(remoteSessionId);
    }
    return null;
  }

  Future<FtermPaneController?> _createSplitPane({
    required FtermTabState tab,
    required String targetPaneId,
    required String newPaneId,
    required FtermPaneController? currentPane,
    required SessionId? remoteSessionId,
    required LocalShellConfig? localShellConfig,
  }) async {
    final useLocal =
        remoteSessionId == null &&
        localHostDriver.isSupported &&
        (currentPane?.isLocal ?? true);
    if (!useLocal) {
      final targetSession =
          remoteSessionId ??
          currentPane?.remoteSessionId ??
          availableRemoteSessions.firstOrNull?.id;
      if (targetSession == null) return null;
      return _createPaneController(
        paneId: newPaneId,
        port: repository.openTerminalPort(targetSession),
        remoteSessionId: targetSession,
      );
    }

    final host = await localHostDriver.openShell(
      localShellConfig ??
          _defaultLocalShellConfig(
            workingDirectory: currentPane?.localHost?.port.workingDirectory,
          ),
    );
    if (_disposed ||
        !_tabs.contains(tab) ||
        !tab.splitTree.containsPane(targetPaneId)) {
      await host.dispose();
      return null;
    }
    return _createPaneController(
      paneId: newPaneId,
      port: host.port,
      localHost: host,
    );
  }

  /// Closes [paneId] (or the currently focused pane), promoting its sibling or
  /// closing the containing tab when it is the final pane.
  Future<void> closePane([String? paneId]) async {
    if (_disposed) return;
    final targetPaneId = paneId ?? activeTab?.splitTree.focusedPaneId;
    if (targetPaneId == null) return;
    final tabIdx = _findTabIndexContainingPane(targetPaneId);
    if (tabIdx < 0) return;

    final tab = _tabs[tabIdx];
    final removedPane = _panes.remove(targetPaneId);
    final nextTree = tab.splitTree.closePane(targetPaneId);
    if (nextTree == null) {
      _removeTabAt(_tabs.indexOf(tab));
    } else {
      tab.splitTree = nextTree;
    }
    _recordClosedPaneMetadata(removedPane);
    if (removedPane != null) {
      _disposeScopeIfUnused(removedPane);
    }
    _syncFocusedPaneStates();
    _notifyChromeChanged();
    if (removedPane != null) {
      await removedPane.dispose(disposePort: true);
    }
  }

  static String _scopeKeyForPane(FtermPaneController pane) =>
      pane.remoteSessionId?.value ?? pane.paneId;

  void _disposeScopeIfUnused(
    FtermPaneController pane, {
    String? excludingPaneId,
    bool requireLive = false,
  }) {
    final scopeKey = _scopeKeyForPane(pane);
    final stillInUse = _panes.values.any(
      (other) =>
          other.paneId != excludingPaneId &&
          _scopeKeyForPane(other) == scopeKey &&
          (!requireLive || !other.hasExited),
    );
    if (!stillInUse) {
      audioController.disposeScope(scopeKey);
    }
  }

  void _recordClosedPaneMetadata(FtermPaneController? pane) {
    if (pane == null) return;
    if (pane.shareSnapshot.sessionId case final sharedId?) {
      _ownedSharedSessionIds.remove(sharedId);
    }
    if (pane.remoteSessionId case final remoteId?) {
      final stillOpenElsewhere = _panes.values.any(
        (other) => other.remoteSessionId == remoteId,
      );
      if (!stillOpenElsewhere) {
        _dismissedRemoteSessions.add(remoteId);
      }
    }
  }

  void _removeTabAt(int tabIdx) {
    _tabs.removeAt(tabIdx);
    if (_tabs.isEmpty) {
      _activeTabIndex = 0;
    } else if (_activeTabIndex >= _tabs.length) {
      _activeTabIndex = _tabs.length - 1;
    } else if (tabIdx < _activeTabIndex) {
      _activeTabIndex -= 1;
    }
  }

  /// Closes an entire tab at [tabIndex] and disposes all of its panes.
  Future<void> closeTab(int tabIndex) async {
    if (_disposed || tabIndex < 0 || tabIndex >= _tabs.length) return;
    final tab = _tabs[tabIndex];
    for (final paneId in [...tab.splitTree.paneIds]) {
      await closePane(paneId);
    }
  }

  /// Selects tab [index] and clears its unread bell badge.
  void selectTab(int index) {
    if (_disposed || index < 0 || index >= _tabs.length) return;
    _activeTabIndex = index;
    _tabs[index].unreadBellCount = 0;
    _syncFocusedPaneStates();
    _notifyChromeChanged();
  }

  /// Switches to the next or previous tab cyclically.
  void cycleTab({bool reverse = false}) {
    if (_tabs.length <= 1) return;
    final step = reverse ? -1 : 1;
    selectTab((activeTabIndex + step + _tabs.length) % _tabs.length);
  }

  /// Reorders tabs from [oldIndex] to [newIndex].
  void reorderTabs(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= _tabs.length ||
        newIndex < 0 ||
        newIndex > _tabs.length ||
        oldIndex == newIndex) {
      return;
    }
    final activeId = activeTab?.tabId;
    final item = _tabs.removeAt(oldIndex);
    final insertAt = newIndex > oldIndex ? newIndex - 1 : newIndex;
    _tabs.insert(insertAt.clamp(0, _tabs.length), item);
    if (activeId != null) {
      final nextActive = _tabs.indexWhere((t) => t.tabId == activeId);
      if (nextActive >= 0) _activeTabIndex = nextActive;
    }
    _notifyChromeChanged();
  }

  /// Focuses [paneId] directly (e.g., on pointer down inside a split leaf).
  void focusPane(String paneId) {
    final tabIdx = _findTabIndexContainingPane(paneId);
    if (tabIdx < 0) return;
    final tab = _tabs[tabIdx];
    if (tabIdx == _activeTabIndex &&
        tab.splitTree.focusedPaneId == paneId &&
        tab.unreadBellCount == 0) {
      return;
    }
    _activeTabIndex = tabIdx;
    tab.unreadBellCount = 0;
    tab.splitTree = tab.splitTree.focusPane(paneId);
    _syncFocusedPaneStates();
    _notifyChromeChanged();
  }

  /// Moves pane focus directionally (`hjkl` / arrows) in the active tab.
  void focusDirection(FocusDirection direction) {
    final tab = activeTab;
    if (tab == null) return;
    final next = tab.splitTree.focusDirection(direction);
    if (identical(next, tab.splitTree)) return;
    tab.splitTree = next;
    _syncFocusedPaneStates();
    _notifyChromeChanged();
  }

  /// Updates split divider [ratio] for [splitId] in the active tab.
  void setSplitRatio(String splitId, double ratio) {
    final tab = activeTab;
    if (tab == null) return;
    final next = tab.splitTree.setSplitRatio(splitId, ratio);
    if (identical(next, tab.splitTree)) return;
    tab.splitTree = next;
    _notifyChromeChanged();
  }

  /// Toggles `tmux`-style fullscreen zoom on the focused pane.
  void toggleZoom() {
    final tab = activeTab;
    if (tab == null) return;
    final next = tab.splitTree.toggleZoom();
    if (identical(next, tab.splitTree)) return;
    tab.splitTree = next;
    _notifyChromeChanged();
  }

  /// Renames [tabIndex] (or [activeTabIndex]) with a pinned title, or clears
  /// the pin when [clearPin] is true to follow live shell titles again.
  void renameTab({
    int? tabIndex,
    required String title,
    bool clearPin = false,
  }) {
    final idx = tabIndex ?? activeTabIndex;
    if (idx < 0 || idx >= _tabs.length) return;
    final tab = _tabs[idx];
    final trimmed = title.trim();
    if (clearPin || trimmed.isEmpty) {
      tab.pinnedTitle = null;
    } else {
      tab.pinnedTitle = trimmed;
    }
    final pane = _panes[tab.splitTree.focusedPaneId];
    if (pane?.remotePort case final remote?) {
      final wireTitle = clearPin
          ? (remote.shellTitle.isNotEmpty
                ? remote.shellTitle
                : remote.displayTitle)
          : (trimmed.isNotEmpty ? trimmed : remote.displayTitle);
      remote.rename(wireTitle, clearPin: clearPin || trimmed.isEmpty);
    }
    _activeOverlay = FtermOverlay.none;
    _notifyChromeChanged();
  }

  /// Toggles live relay sharing for [paneId] (or focused pane).
  ///
  /// Returns `true` when share state changed cleanly, or `false` if sharing is
  /// unavailable or awaiting relay credentials.
  Future<bool> togglePaneShare({
    String? paneId,
    Uri? serverUri,
    String? casterToken,
    CasterTransportOpener? channelOpener,
  }) async {
    if (_disposed) return false;
    final targetId = paneId ?? activeTab?.splitTree.focusedPaneId;
    if (targetId == null || !_togglingSharePaneIds.add(targetId)) return false;
    try {
      final pane = _panes[targetId];
      final host = pane?.localHost;
      if (pane == null || host == null) return false;

      final shareState = host.shareSnapshot.state;
      if (shareState == LocalShareState.connecting ||
          shareState == LocalShareState.live) {
        await _stopShareForHost(host);
        _notifyChromeChanged();
        return true;
      }
      if (shareState == LocalShareState.error) {
        await _stopShareForHost(host);
      }

      final resolvedServer =
          serverUri ?? CastLaunchConfig.deriveCasterServerUri(_activeRelayUri);
      final resolvedToken =
          casterToken ??
          (_activeCasterToken.isNotEmpty
              ? _activeCasterToken
              : _relayCredentials.casterToken);
      if (_requiresCasterTokenPrompt(
        channelOpener: channelOpener,
        resolvedToken: resolvedToken,
        serverUri: resolvedServer,
      )) {
        _setStatusBanner('Configure relay caster token before sharing.');
        _setOverlay(FtermOverlay.connect);
        return false;
      }

      final tabTitle = _resolveShareTitle(targetId, pane);
      try {
        final assignedId = await host.startShare(
          serverUri: resolvedServer,
          casterToken: resolvedToken,
          title: tabTitle,
          iapTokenProvider: resolveIapTokenProviderFor(resolvedServer),
          channelOpener: channelOpener,
        );
        _ownedSharedSessionIds.add(assignedId);
        _notifyChromeChanged();
        return true;
      } on Object catch (error) {
        _setStatusBanner('Share failed: $error');
        return false;
      }
    } finally {
      _togglingSharePaneIds.remove(targetId);
    }
  }

  Future<void> _stopShareForHost(LocalPaneHost host) async {
    final activeId = host.shareSnapshot.sessionId;
    await host.stopShare();
    if (activeId != null) {
      _ownedSharedSessionIds.remove(activeId);
    }
  }

  static bool _requiresCasterTokenPrompt({
    required CasterTransportOpener? channelOpener,
    required String resolvedToken,
    required Uri serverUri,
  }) =>
      channelOpener == null &&
      resolvedToken.isEmpty &&
      serverUri.host != '127.0.0.1' &&
      serverUri.host != 'localhost';

  String _resolveShareTitle(String paneId, FtermPaneController pane) {
    final tabIdx = _findTabIndexContainingPane(paneId);
    if (tabIdx >= 0) {
      return _tabs[tabIdx].resolveTitle(_panes);
    }
    return pane.shellTitle.isNotEmpty ? pane.shellTitle : 'fterm';
  }

  /// Arms or disarms the `Ctrl+\` leader chord indicator.
  void setLeaderArmed(bool armed) {
    if (_leaderArmed == armed) return;
    _leaderArmed = armed;
    _notifyChromeChanged();
  }

  /// Opens or dismisses a workspace modal overlay.
  void setOverlay(FtermOverlay overlay) => _setOverlay(overlay);

  void _setOverlay(FtermOverlay overlay) {
    if (_disposed || _activeOverlay == overlay) return;
    if (_activeOverlay == FtermOverlay.whatsNew &&
        overlay != FtermOverlay.whatsNew) {
      _whatsNewPreviewSnapshot = null;
    } else if (overlay == FtermOverlay.whatsNew &&
        _whatsNewPreviewSnapshot == null) {
      _whatsNewPreviewSnapshot = _captureWhatsNewPreviewSnapshot();
    }
    _activeOverlay = overlay;
    _leaderArmed = false;
    switch (overlay) {
      case FtermOverlay.about || FtermOverlay.feedback || FtermOverlay.licenses:
        unawaited(aboutViewModel.ensureInitialized());
        if (overlay == FtermOverlay.licenses) {
          unawaited(aboutViewModel.ensureLicensesLoaded());
        }
      default:
        break;
    }
    _notifyChromeChanged();
  }

  /// Builds an allowlisted, opt-in diagnostic summary of workspace state for
  /// GitHub issue reports (never includes URLs, hostnames, tokens, paths, or
  /// terminal contents).
  FtermWorkspaceDiagnosticSummary buildDiagnosticSummary({
    required bool isWeb,
  }) {
    final focused = focusedPane;
    final hasRemoteOrSharedPane = _panes.values.any(
      (pane) =>
          !pane.isLocal || pane.shareSnapshot.state != LocalShareState.unshared,
    );
    final usesRelay =
        isWeb ||
        hasRemoteOrSharedPane ||
        _connectionState != ClientConnectionState.unconnected;
    return FtermWorkspaceDiagnosticSummary(
      tabCount: _tabs.length,
      paneCount: activeSplitTree?.paneCount ?? 0,
      focusedPaneKind: focused == null
          ? 'none'
          : (focused.isLocal ? 'local shell' : 'remote session (via relay)'),
      usesRelay: usesRelay,
      activePtySize: focused == null
          ? null
          : '${focused.activePtySize.$1}x${focused.activePtySize.$2}',
      themeId: activeTerminalTheme.id,
      appearanceMode: _workspaceSettings.themeSettings.appearanceMode.name,
      fontSize: effectiveFontSize,
      dockPosition: _workspaceSettings.dockPosition.name,
      connectionState: _connectionState.name,
      audioInitialized: audioController.isInitialized,
      isWeb: isWeb,
      updateStatus: isWeb ? null : updateViewModel.status.name,
    );
  }

  /// Dismisses the transient banner and active modal overlay.
  void dismissOverlay() {
    _statusBanner = null;
    if (_activeOverlay == FtermOverlay.fileUpload) {
      cancelFileUpload();
      return;
    }
    _leaderArmed = false;
    if (_activeOverlay == FtermOverlay.licenses) {
      _activeOverlay = FtermOverlay.about;
      _notifyChromeChanged();
      return;
    }
    if (_activeOverlay == FtermOverlay.whatsNew) {
      _whatsNewPreviewSnapshot = null;
    }
    if (_activeOverlay != FtermOverlay.none) {
      _activeOverlay = FtermOverlay.none;
    }
    _notifyChromeChanged();
  }

  /// Cancels any active or staged file upload, clears pending files, and closes the overlay.
  void cancelFileUpload() {
    _leaderArmed = false;
    _uploadCoordinator.cancel();
    _pendingUploadFiles = const [];
    _stagedUploadSessionId = null;
    if (_activeOverlay == FtermOverlay.fileUpload) {
      _activeOverlay = FtermOverlay.none;
    }
    _notifyChromeChanged();
  }

  /// Stages dropped files onto the active remote pane and opens [FtermOverlay.fileUpload].
  void stageDroppedFiles(List<DroppedFileSource> files) {
    if (_disposed || files.isEmpty) return;
    final target = focusedPane?.remoteSessionId;
    if (target == null) {
      _setStatusBanner('Drop uploads target remote shared panes.');
      return;
    }
    _stagedUploadSessionId = target;
    _pendingUploadFiles = List<DroppedFileSource>.unmodifiable(files);
    _setOverlay(FtermOverlay.fileUpload);
  }

  /// Uploads staged [pendingUploadFiles] to the remote session pinned at drop time.
  Future<bool> confirmFileUpload() async {
    final sessionId = _stagedUploadSessionId;
    final files = _pendingUploadFiles;
    if (sessionId == null || files.isEmpty) return false;
    final ok = await _uploadCoordinator.uploadFiles(sessionId, files);
    if (ok && !_disposed) {
      _stagedUploadSessionId = null;
      _pendingUploadFiles = const [];
      _activeOverlay = FtermOverlay.none;
      _notifyChromeChanged();
    }
    return ok;
  }

  /// Cycles dock mode `top` -> `left` -> `hidden` -> `top`.
  void cycleDockPosition() {
    final next = switch (_workspaceSettings.dockPosition) {
      DockPosition.top => DockPosition.left,
      DockPosition.left => DockPosition.hidden,
      DockPosition.hidden => DockPosition.top,
    };
    setDockPosition(next);
  }

  /// Updates and persists dock position.
  void setDockPosition(DockPosition position) => updateWorkspaceSettings(
    _workspaceSettings.copyWith(dockPosition: position),
  );

  /// Updates and persists copy-on-select setting.
  void setCopyOnSelect(bool enabled) => updateWorkspaceSettings(
    _workspaceSettings.copyWith(copyOnSelect: enabled),
  );

  /// Updates and persists inbound remote `OSC 52` clipboard policy.
  void setOsc52Policy(Osc52ClipboardPolicy policy) =>
      updateWorkspaceSettings(_workspaceSettings.copyWith(osc52Policy: policy));

  /// Updates and persists F12 shortcut capture setting.
  void setF12ShortcutsEnabled(bool enabled) => updateWorkspaceSettings(
    _workspaceSettings.copyWith(f12ShortcutsEnabled: enabled),
  );

  /// Updates and persists active theme settings.
  void setThemeSettings(TerminalThemeSettings nextThemeSettings) =>
      updateWorkspaceSettings(
        _workspaceSettings.copyWith(themeSettings: nextThemeSettings),
      );

  /// Updates [CastWorkspaceSettings], propagates colors, and saves throttled.
  void updateWorkspaceSettings(CastWorkspaceSettings next) {
    if (_disposed || _workspaceSettings == next) return;
    _workspaceSettings = next;
    _applyColorResolver();
    _rebuildActiveShaderConfig();
    _syncClipboardPolicies();
    _settingsSaver.save(next);
    _notifyChromeChanged();
  }

  /// Updates and persists default background cell [opacity] (`0.0..1.0`).
  void setBackgroundOpacity(double opacity) {
    final safe = opacity.isFinite ? opacity.clamp(0.0, 1.0) : 1.0;
    setThemeSettings(
      _workspaceSettings.themeSettings.copyWith(backgroundOpacity: safe),
    );
  }

  /// Shows or hides the in-app FPS and frame-timing performance HUD and
  /// persists the preference.
  void setShowPerfHud(bool enabled) {
    if (_disposed || _preferences.showPerfHud == enabled) return;
    _preferences = _preferences.copyWith(showPerfHud: enabled);
    _settingsSaver.savePreferences(_preferences);
    _notifyChromeChanged();
  }

  /// Toggles the in-app FPS and frame-timing performance HUD (`Ctrl+Shift+F9`).
  void togglePerfHud() => setShowPerfHud(!showPerfHud);

  /// Updates and persists the native GPU adapter selection preference (takes
  /// effect on next process launch).
  void setGpuDriverPreference(GpuDriverPreference preference) {
    if (_disposed || _preferences.gpuDriverPreference == preference) return;
    _preferences = _preferences.copyWith(gpuDriverPreference: preference);
    _settingsSaver.savePreferences(_preferences);
    _notifyChromeChanged();
  }

  /// Updates and persists the maximum ambient shader FPS (`null` = uncapped).
  void setMaxShaderFps(int? maxFps) {
    final normalized = (maxFps == null || maxFps <= 0)
        ? null
        : maxFps.clamp(15, 240);
    if (_disposed || _preferences.maxShaderFps == normalized) return;
    _preferences = _preferences.copyWith(
      maxShaderFps: normalized,
      clearMaxShaderFps: normalized == null,
    );
    _settingsSaver.savePreferences(_preferences);
    _notifyChromeChanged();
  }

  /// Starts capturing a paired `.trace.json` and `.summary.json` performance
  /// trace via [traceRecorder].
  Future<bool> startTraceRecording({
    String? outputBasePath,
    Duration? duration,
    bool exitOnComplete = false,
  }) async {
    if (_disposed) return false;
    return traceRecorder.start(
      outputBasePath: outputBasePath,
      duration: duration,
      onAutoStop: exitOnComplete
          ? (result) async {
              if (!_disposed && result != null) {
                await _onRequestExit();
              }
            }
          : null,
    );
  }

  /// Stops an active performance trace recording and exports its bundle.
  Future<TraceExportResult?> stopTraceRecording() async {
    if (_disposed) return null;
    return traceRecorder.stop();
  }

  /// Starts or stops performance trace recording (`Ctrl+Shift+F10` or HUD
  /// `[REC]` / `[STOP]` button).
  Future<void> toggleTraceRecording() async {
    if (_disposed) return;
    if (traceRecorder.isRecording) {
      await stopTraceRecording();
      return;
    }
    await startTraceRecording();
  }

  TraceSessionMetadata _buildTraceSessionMetadata() {
    final activeShaders = <String>[
      for (final pass in _activeShaderConfig.backgroundPasses) pass.id,
      for (final pass in _activeShaderConfig.foregroundPasses) pass.id,
      if (focusedPane case final pane?)
        for (final region in pane.displayBuffer.shaderRegions) region.shaderId,
    ];
    return TraceSessionMetadata.fromPlatform(
      backendKind: _shaderController.backendKind.name,
      activeShaders: activeShaders,
      gpuAdapter: activeGpuAdapterName,
    );
  }

  static Future<void> _defaultRequestExit() async {
    await ServicesBinding.instance.exitApplication(ui.AppExitType.required);
  }

  static Future<bool> _defaultRelaunchApp(List<String> args) =>
      relaunchDesktopApp(args: args);

  /// Flushes persisted settings, launches a replacement `fterm` instance, tears
  /// down local sessions cleanly, and exits the current process (e.g. to apply
  /// a changed Windows GPU adapter preference).
  Future<bool> restartApplication() async {
    if (_disposed) return false;
    _settingsSaver.flush();
    await _settingsSaver.flushAsync();
    final launched = await _onRelaunchApp(launchConfig.relaunchArgs);
    if (!launched) {
      if (!_disposed) {
        _setStatusBanner(
          'Unable to relaunch fterm automatically. Please restart manually.',
        );
      }
      return false;
    }
    await prepareForUpdateSwap();
    if (!_disposed) {
      await _onRequestExit();
    }
    return true;
  }

  /// Copies the latest exported trace summary path to the clipboard and opens
  /// its containing directory on desktop when available.
  Future<bool> revealLastTraceExport() async {
    final export = traceRecorder.lastExport;
    if (_disposed || export == null) return false;
    unawaited(
      Clipboard.setData(ClipboardData(text: export.summaryPath))
          .catchError((_) {}),
    );
    final dirPath = p.dirname(export.summaryPath);
    final handler = _openDirectoryHandler;
    if (handler != null && dirPath.isNotEmpty && dirPath != '.') {
      await handler(dirPath);
    } else if (dirPath.isNotEmpty && dirPath != '.') {
      await openDesktopDirectory(dirPath);
    }
    if (!_disposed) {
      _setStatusBanner('Trace path copied: ${export.summaryPath}');
    }
    return true;
  }

  void _maybeAutoLowerBackgroundOpacity() {
    if (backgroundOpacity < 1.0) return;
    _workspaceSettings = _workspaceSettings.copyWith(
      themeSettings: _workspaceSettings.themeSettings.copyWith(
        backgroundOpacity: autoRevealBackgroundOpacity,
      ),
    );
    _settingsSaver.save(_workspaceSettings);
  }

  /// Updates and persists the active [ShaderAnimationMode] across both
  /// [FtermPreferences] and [TerminalThemeSettings].
  void setShaderAnimationMode(ShaderAnimationMode mode) {
    if (_disposed) return;
    _preferences = _preferences.copyWith(shaderAnimationMode: mode);
    _workspaceSettings = _workspaceSettings.copyWith(
      themeSettings: _workspaceSettings.themeSettings.copyWith(
        animationMode: mode,
      ),
    );
    _rebuildActiveShaderConfig();
    _settingsSaver.save(_workspaceSettings);
    _settingsSaver.savePreferences(_preferences);
    _notifyChromeChanged();
  }

  /// Switches and persists the runtime [ShaderBackendKind] override (`null`
  /// restores platform auto-selection) and recompiles active shaders.
  Future<void> setShaderBackendOverride(ShaderBackendKind? override) async {
    if (_disposed) return;
    _preferences = _preferences.copyWith(
      shaderBackendOverride: override,
      clearShaderBackendOverride: override == null,
    );
    _settingsSaver.savePreferences(_preferences);
    _notifyChromeChanged();
    await _shaderController.setBackendOverride(
      override,
      sourceLoader: _shaderProfileStore.loadShaderSource,
    );
    if (_disposed) return;
    _rebuildActiveShaderConfig();
    _syncShaderCompileBanner();
    _notifyChromeChanged();
  }

  /// Replaces the ordered background shader chain (`preset` wire names or
  /// custom `.glsl` paths) and compiles updated passes.
  Future<void> setBackgroundShaderChain(List<String> entries) async {
    if (_disposed) return;
    final normalized = _normalizeShaderEntries(entries);
    _preferences = _preferences.copyWith(backgroundShaderPaths: normalized);
    _workspaceSettings = _workspaceSettings.copyWith(
      themeSettings: _workspaceSettings.themeSettings.copyWith(
        backgroundShaderChain: normalized,
      ),
    );
    if (normalized.isNotEmpty) {
      _maybeAutoLowerBackgroundOpacity();
    }
    _rebuildActiveShaderConfig();
    _settingsSaver.save(_workspaceSettings);
    _settingsSaver.savePreferences(_preferences);
    _notifyChromeChanged();
    await _syncActiveShaders();
  }

  /// Replaces the ordered foreground shader chain (`preset` wire names or
  /// custom `.glsl` paths) and compiles updated passes.
  Future<void> setForegroundShaderChain(List<String> entries) async {
    if (_disposed) return;
    final normalized = _normalizeShaderEntries(entries);
    _preferences = _preferences.copyWith(foregroundShaderPaths: normalized);
    _workspaceSettings = _workspaceSettings.copyWith(
      themeSettings: _workspaceSettings.themeSettings.copyWith(
        foregroundShaderChain: normalized,
      ),
    );
    _rebuildActiveShaderConfig();
    _settingsSaver.save(_workspaceSettings);
    _settingsSaver.savePreferences(_preferences);
    _notifyChromeChanged();
    await _syncActiveShaders();
  }

  /// Adds or removes [entry] in [backgroundShaderChain].
  Future<void> toggleBackgroundShader(String entry) {
    final trimmed = entry.trim();
    if (trimmed.isEmpty) return Future<void>.value();
    final next = <String>[...backgroundShaderChain];
    if (!next.remove(trimmed)) {
      next.add(trimmed);
    }
    return setBackgroundShaderChain(next);
  }

  /// Adds or removes [entry] in [foregroundShaderChain].
  Future<void> toggleForegroundShader(String entry) {
    final trimmed = entry.trim();
    if (trimmed.isEmpty) return Future<void>.value();
    final next = <String>[...foregroundShaderChain];
    if (!next.remove(trimmed)) {
      next.add(trimmed);
    }
    return setForegroundShaderChain(next);
  }

  /// Moves the background shader at [fromIndex] to [toIndex] in
  /// [backgroundShaderChain], changing pass execution order (`0 -> N - 1`,
  /// where later passes run on top of earlier ones).
  Future<void> moveBackgroundShader(int fromIndex, int toIndex) {
    final reordered = _moveChainEntry(
      backgroundShaderChain,
      fromIndex,
      toIndex,
    );
    if (reordered == null) return Future<void>.value();
    return setBackgroundShaderChain(reordered);
  }

  /// Moves the foreground shader at [fromIndex] to [toIndex] in
  /// [foregroundShaderChain], changing pass execution order (`0 -> N - 1`).
  Future<void> moveForegroundShader(int fromIndex, int toIndex) {
    final reordered = _moveChainEntry(
      foregroundShaderChain,
      fromIndex,
      toIndex,
    );
    if (reordered == null) return Future<void>.value();
    return setForegroundShaderChain(reordered);
  }

  ShadertoyGlslAnalysis? _analysisForEntry(
    String entry,
    TerminalShaderStage stage,
  ) {
    final direct = _shaderController.analysisForPass(
      _passIdForEntry(entry, stage),
    );
    if (direct != null) return direct;
    final otherStage = stage == TerminalShaderStage.background
        ? TerminalShaderStage.foreground
        : TerminalShaderStage.background;
    return _shaderController.analysisForPass(
          _passIdForEntry(entry, otherStage),
        ) ??
        _customShaderAnalyses[entry];
  }

  /// Whether shader [entry] in [stage] samples `iChannel0` (chains on top of
  /// the previous pass), `false` when it is a standalone base/source shader,
  /// or `null` when its GLSL source has not been analyzed yet.
  bool? shaderSamplesChannel0(String entry, TerminalShaderStage stage) {
    final analysis = _analysisForEntry(entry, stage);
    if (analysis != null) return analysis.samplesChannel0;
    final preset = TerminalShaderPreset.fromWireName(entry);
    if (preset != TerminalShaderPreset.none) {
      return BuiltinShaders.samplesChannel0(preset);
    }
    return null;
  }

  /// Recommended pipeline stage (`BG`, `FG`, or `Any`) inferred for [entry]
  /// from an optional `// @fterm-stage:` directive or static GLSL analysis.
  ShaderStageHint? shaderStageHint(String entry, TerminalShaderStage stage) {
    final analysis = _analysisForEntry(entry, stage);
    if (analysis != null) return analysis.stageHint;
    final preset = TerminalShaderPreset.fromWireName(entry);
    if (preset != TerminalShaderPreset.none) {
      return BuiltinShaders.stageHint(preset);
    }
    return null;
  }

  /// Returns a human-readable warning when [stage]'s active shader chain has
  /// overlapping or overwriting passes, or `null` when no conflict exists.
  ///
  /// Passes execute sequentially (`0 -> N - 1`), feeding each pass's output
  /// into the next pass's `iChannel0`. Any pass after index `0` that does not
  /// sample `iChannel0` overwrites all earlier passes; in
  /// [TerminalShaderStage.foreground], even pass `0` ignoring `iChannel0`
  /// covers terminal text. For [TerminalShaderStage.background], selecting
  /// multiple shaders always surfaces an ordering notice.
  String? shaderChainWarningFor(TerminalShaderStage stage) {
    final chain = stage == TerminalShaderStage.background
        ? backgroundShaderChain
        : foregroundShaderChain;
    if (chain.isEmpty) return null;

    final minCheckIndex = stage == TerminalShaderStage.foreground ? 0 : 1;
    for (var i = chain.length - 1; i >= minCheckIndex; i--) {
      final entry = chain[i];
      if (shaderSamplesChannel0(entry, stage) == false) {
        final overwriter = _shaderDisplayName(entry);
        if (i == 0) {
          return '$overwriter does not sample iChannel0 and will cover '
              'terminal text. Move it to Background Shaders.';
        }
        final hidden = <String>[
          for (var j = 0; j < i; j++) _shaderDisplayName(chain[j]),
        ].join(', ');
        return '$overwriter does not sample iChannel0 and overwrites '
            '$hidden. Reorder or disable extra shaders.';
      }
    }

    if (stage == TerminalShaderStage.background && chain.length > 1) {
      return '${chain.length} background shaders active. Passes run in order '
          '(1 → ${chain.length}); the final pass wins unless it blends '
          'iChannel0.';
    }
    return null;
  }

  /// Updates float parameter [index] (`0..7`) for shader pass [passId] and
  /// persists it inside [FtermPreferences.customShaderProfileJson].
  void setShaderParam(String passId, int index, double value) {
    if (_disposed ||
        index < 0 ||
        index >= ShaderPassSpec.paramCount ||
        !value.isFinite) {
      return;
    }
    final existing = _shaderParamsByPass[passId];
    final nextList = existing != null
        ? List<double>.of(existing)
        : List<double>.filled(ShaderPassSpec.paramCount, 0.0);
    nextList[index] = value;
    _shaderParamsByPass[passId] = nextList;
    _preferences = _preferences.copyWith(
      customShaderProfileJson: jsonEncode(_shaderParamsByPass),
    );
    _rebuildActiveShaderConfig();
    _settingsSaver.savePreferences(_preferences);
    _notifyChromeChanged();
  }

  /// Sets or clears the wallpaper image path/key, decoding validated bytes
  /// asynchronously into [shaderController].
  Future<void> setBackgroundImagePath(String? path) async {
    if (_disposed) return;
    final trimmed = path?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      _lastShaderAssetError = null;
      _preferences = _preferences.copyWith(clearBackgroundImagePath: true);
      _shaderController.clearWallpaperImage();
      _rebuildActiveShaderConfig();
      _settingsSaver.savePreferences(_preferences);
      _notifyChromeChanged();
      return;
    }
    _preferences = _preferences.copyWith(backgroundImagePath: trimmed);
    _maybeAutoLowerBackgroundOpacity();
    _rebuildActiveShaderConfig();
    _settingsSaver.savePreferences(_preferences);
    _notifyChromeChanged();
    await _loadPersistedWallpaper(trimmed);
  }

  /// Validates, persists, and activates uploaded wallpaper [bytes] under [key].
  Future<void> uploadWallpaperBytes(String key, Uint8List bytes) async {
    if (_disposed) return;
    try {
      await _shaderProfileStore.saveWallpaperBytes(key, bytes);
      if (_disposed) return;
      await _shaderController.setWallpaperBytes(bytes);
      if (_disposed) return;
      _lastShaderAssetError = null;
      _preferences = _preferences.copyWith(backgroundImagePath: key.trim());
      _maybeAutoLowerBackgroundOpacity();
      _rebuildActiveShaderConfig();
      _settingsSaver.savePreferences(_preferences);
      _notifyChromeChanged();
    } on Object catch (error) {
      if (_disposed) return;
      _lastShaderAssetError = '$error';
      _setStatusBanner('Wallpaper failed: $error');
    }
  }

  /// Validates, persists, and optionally activates an inline custom `.glsl`
  /// shader snippet (used for Web uploads and quick shader creation).
  Future<void> uploadCustomShader(
    String name,
    String glslSource, {
    TerminalShaderStage stage = TerminalShaderStage.foreground,
    bool activate = true,
  }) async {
    if (_disposed) return;
    final normalizedName = name.trim();
    try {
      await _shaderProfileStore.saveShaderSource(normalizedName, glslSource);
      if (_disposed) return;
      _lastShaderAssetError = null;
      await refreshCustomShaders();
      if (_disposed || !activate) return;
      if (stage == TerminalShaderStage.background) {
        final next = <String>[
          ...backgroundShaderChain,
          if (!backgroundShaderChain.contains(normalizedName)) normalizedName,
        ];
        await setBackgroundShaderChain(next);
      } else {
        final next = <String>[
          ...foregroundShaderChain,
          if (!foregroundShaderChain.contains(normalizedName)) normalizedName,
        ];
        await setForegroundShaderChain(next);
      }
      await reloadShaders();
    } on Object catch (error) {
      if (_disposed) return;
      _lastShaderAssetError = '$error';
      _setStatusBanner('Shader upload failed: $error');
    }
  }

  /// Reloads custom `.glsl` shaders from [shaderProfileStore] and refreshes
  /// compile error notices (`Ctrl+Shift+F5`).
  Future<void> reloadShaders() async {
    if (_disposed) return;
    await refreshCustomShaders();
    if (_disposed) return;
    _rebuildActiveShaderConfig();
    await _shaderController.reloadCustomShaders(
      config: _activeShaderConfig,
      sourceLoader: _shaderProfileStore.loadShaderSource,
    );
    if (_disposed) return;
    _syncShaderCompileBanner();
    _notifyChromeChanged();
  }

  /// Refreshes the list of available custom `.glsl` / `.frag` files from
  /// [shaderProfileStore] and statically analyzes each file so the Settings UI
  /// can show `base`/`chains` and `BG`/`FG`/`Any` hints before activation.
  Future<void> refreshCustomShaders() async {
    if (_disposed) return;
    try {
      final listed = await _shaderProfileStore.listShaderFiles();
      if (_disposed) return;
      final analyzed = <String, ShadertoyGlslAnalysis>{};
      for (final path in listed) {
        if (_disposed) return;
        final analysis = await _tryAnalyzeCustomShader(path);
        if (analysis != null) {
          analyzed[path] = analysis;
        }
      }
      if (_disposed) return;
      _availableCustomShaders = listed;
      _customShaderAnalyses
        ..clear()
        ..addAll(analyzed);
      _notifyChromeChanged();
    } on Object {
      // Ignore unavailable shader directory during startup or tests.
    }
  }

  Future<ShadertoyGlslAnalysis?> _tryAnalyzeCustomShader(String path) async {
    try {
      final source = await _shaderProfileStore.loadShaderSource(path);
      return ShadertoyGlslShim.analyze(source, shaderId: path);
    } on Object {
      return null;
    }
  }

  /// Opens or reveals the desktop shaders directory, returning `true` when a
  /// shaders folder path is available on the current platform.
  Future<bool> openShadersFolder() async {
    if (_disposed) return false;
    final dirPath = _shaderProfileStore.shadersDirectoryPath;
    if (dirPath == null || dirPath.trim().isEmpty) {
      _setStatusBanner('Shaders folder is unavailable on this platform.');
      return false;
    }
    final handler = _openDirectoryHandler;
    if (handler != null) {
      await handler(dirPath);
      return true;
    }
    unawaited(
      Clipboard.setData(ClipboardData(text: dirPath)).catchError((_) {}),
    );
    _setStatusBanner('Shaders folder copied: $dirPath');
    return true;
  }

  void _initShaderSubsystem() {
    _shaderParamsByPass = _decodeShaderParamsMap(
      _preferences.customShaderProfileJson,
    );
    _rebuildActiveShaderConfig();
    _shaderController.addListener(_onShaderControllerChanged);
    _shaderWatchSubscription = _shaderProfileStore
        .watchShaderDirectory()
        .listen(
          _onShaderDirectoryChanged,
          onError: (Object _, StackTrace _) {},
        );
    if (!_activeShaderConfig.isEmpty) {
      unawaited(_syncActiveShaders());
    }
    if (_preferences.backgroundImagePath case final wallpaperPath?) {
      unawaited(_loadPersistedWallpaper(wallpaperPath));
    }
    unawaited(refreshCustomShaders());
  }

  void _onShaderControllerChanged() {
    if (_disposed) return;
    for (final pane in _panes.values) {
      pane.attachShaderBackend(_shaderController.backend);
    }
    _rebuildActiveShaderConfig();
    _syncShaderCompileBanner();
    _notifyChromeChanged();
  }

  void _onShaderDirectoryChanged(ShaderDirectoryChange _) {
    if (_disposed) return;
    unawaited(reloadShaders());
  }

  Future<String> _loadShaderSourceWithCli(String path) {
    if (path.startsWith('cli:')) {
      for (final pane in _panes.values) {
        final cliSource = pane.cliShaderState.lookupApprovedFullPaneSource(
          path,
        );
        if (cliSource != null) {
          return Future<String>.value(cliSource);
        }
      }
    }
    return _shaderProfileStore.loadShaderSource(path);
  }

  TerminalShaderConfig _buildSyncShaderConfig() {
    final cliBg = <ShaderPassSpec>[];
    final cliFg = <ShaderPassSpec>[];
    for (final pane in _panes.values) {
      for (final pass in pane.cliShaderState.collectActiveCliFullPanePasses()) {
        if (pass.stage == TerminalShaderStage.background) {
          cliBg.add(pass);
        } else {
          cliFg.add(pass);
        }
      }
    }
    if (cliBg.isEmpty && cliFg.isEmpty) return _activeShaderConfig;
    return _activeShaderConfig.copyWith(
      backgroundPasses: [..._activeShaderConfig.backgroundPasses, ...cliBg],
      foregroundPasses: [..._activeShaderConfig.foregroundPasses, ...cliFg],
    );
  }

  void _syncActiveCliFullPaneShaders() {
    if (_disposed) return;
    unawaited(_syncActiveShaders());
  }

  Future<void> _syncActiveShaders() async {
    if (_disposed) return;
    await _shaderController.syncConfig(
      _buildSyncShaderConfig(),
      sourceLoader: _loadShaderSourceWithCli,
    );
    if (_disposed) return;
    _syncShaderCompileBanner();
    _notifyChromeChanged();
  }

  Future<void> _loadPersistedWallpaper(String pathOrKey) async {
    try {
      final bytes = await _shaderProfileStore.loadWallpaperBytes(pathOrKey);
      if (_disposed) return;
      await _shaderController.setWallpaperBytes(bytes);
      if (_disposed) return;
      _lastShaderAssetError = null;
      _rebuildActiveShaderConfig();
      _notifyChromeChanged();
    } on Object catch (error) {
      if (_disposed) return;
      _lastShaderAssetError = '$error';
      _setStatusBanner('Wallpaper failed: $error');
    }
  }

  void _syncShaderCompileBanner() {
    final compileError = _shaderController.lastCompileError;
    if (compileError != null) {
      final loc = compileError.lineNumber == null
          ? ''
          : ' (line ${compileError.lineNumber})';
      _statusBanner = 'Shader error$loc: ${compileError.message}';
      return;
    }
    if (_statusBanner?.startsWith('Shader error') ?? false) {
      _statusBanner = null;
    }
  }

  void _rebuildActiveShaderConfig() {
    final bgPasses = _buildPassSpecs(
      backgroundShaderChain,
      TerminalShaderStage.background,
    );
    final fgPasses = _buildPassSpecs(
      foregroundShaderChain,
      TerminalShaderStage.foreground,
    );
    _activeShaderConfig = TerminalShaderConfig(
      backgroundPasses: bgPasses,
      foregroundPasses: fgPasses,
      animationMode: shaderAnimationMode,
      backgroundOpacity: backgroundOpacity,
      backgroundImage: _shaderController.wallpaperImage,
      enabled: true,
    );
  }

  List<ShaderPassSpec> _buildPassSpecs(
    List<String> entries,
    TerminalShaderStage stage,
  ) {
    if (entries.isEmpty) return const <ShaderPassSpec>[];
    final specs = <ShaderPassSpec>[];
    for (final raw in entries) {
      final entry = raw.trim();
      if (entry.isEmpty) continue;
      final preset = TerminalShaderPreset.fromWireName(entry);
      final passId = _passIdForEntry(entry, stage);
      if (preset != TerminalShaderPreset.none) {
        specs.add(
          ShaderPassSpec(
            id: passId,
            stage: stage,
            preset: preset,
            usesPrevFrame: BuiltinShaders.usesPrevFrame(preset),
            params: shaderParamsFor(passId),
          ),
        );
      } else {
        specs.add(
          ShaderPassSpec(
            id: passId,
            stage: stage,
            customSourcePath: entry,
            params: shaderParamsFor(passId),
          ),
        );
      }
    }
    return List<ShaderPassSpec>.unmodifiable(specs);
  }

  static String _passIdForEntry(String entry, TerminalShaderStage stage) {
    final preset = TerminalShaderPreset.fromWireName(entry);
    final suffix = preset != TerminalShaderPreset.none
        ? preset.wireName
        : entry;
    return '${stage.name}:$suffix';
  }

  static String _shaderDisplayName(String entry) {
    final preset = TerminalShaderPreset.fromWireName(entry);
    if (preset != TerminalShaderPreset.none) return preset.wireName;
    return p.basename(entry);
  }

  static List<String>? _moveChainEntry(
    List<String> chain,
    int fromIndex,
    int toIndex,
  ) {
    if (fromIndex < 0 ||
        fromIndex >= chain.length ||
        toIndex < 0 ||
        toIndex >= chain.length ||
        fromIndex == toIndex) {
      return null;
    }
    final next = List<String>.of(chain);
    final moved = next.removeAt(fromIndex);
    next.insert(toIndex, moved);
    return next;
  }

  static List<String> _normalizeShaderEntries(List<String> entries) {
    final seen = <String>{};
    final out = <String>[];
    for (final item in entries) {
      final trimmed = item.trim();
      if (trimmed.isNotEmpty && seen.add(trimmed)) {
        out.add(trimmed);
      }
    }
    return out.isEmpty ? const <String>[] : List<String>.unmodifiable(out);
  }

  static Map<String, List<double>> _decodeShaderParamsMap(String? raw) {
    if (raw == null || raw.trim().isEmpty) return <String, List<double>>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<Object?, Object?>) return <String, List<double>>{};
      final parsed = <String, List<double>>{};
      for (final MapEntry(:key, :value) in decoded.entries) {
        if (key is! String || value is! List<Object?>) continue;
        final floats = List<double>.filled(ShaderPassSpec.paramCount, 0.0);
        final count = math.min(value.length, floats.length);
        for (var i = 0; i < count; i++) {
          final item = value[i];
          if (item is num && item.isFinite) {
            floats[i] = item.toDouble();
          }
        }
        parsed[key] = floats;
      }
      return parsed;
    } on Object {
      return <String, List<double>>{};
    }
  }

  /// Updates and persists [FtermPreferences] (`audioMuted`, `audioVolume`,
  /// `autoHideSingleTab`, `macosOptionAsAlt`, `fontSize`, shell overrides, and
  /// update preferences).
  void updatePreferences(FtermPreferences next) {
    if (_disposed || _preferences == next) return;
    _preferences = next;
    audioController
      ..setMuted(next.audioMuted)
      ..setVolume(next.audioVolume);
    _settingsSaver.savePreferences(next);
    updateViewModel.onPreferencesChanged();
    _notifyChromeChanged();
  }

  /// Adjusts the persisted base terminal font size by [delta], clamped to
  /// `[FtermPreferences.minFontSize, FtermPreferences.maxFontSize]`.
  void adjustFontSize(double delta) {
    final nextSize = (effectiveFontSize + delta).clamp(
      FtermPreferences.minFontSize,
      FtermPreferences.maxFontSize,
    );
    updatePreferences(_preferences.copyWith(fontSize: nextSize.toDouble()));
  }

  /// Clears any persisted font-size zoom override so [effectiveFontSize]
  /// falls back to [defaultFontSize].
  void resetFontSize() {
    updatePreferences(_preferences.copyWith(clearFontSize: true));
  }

  static final RegExp _shellTokenPattern = RegExp(
    r'''(?:"(?:\\.|[^"\\])*"|'[^']*'|\\.|[^\s"'\\])+''',
  );
  static final RegExp _needsShellQuoting = RegExp(r'''[\s"'\\]''');

  /// Parses shell arguments, honoring single quotes, double quotes, and `\` escapes.
  static List<String> parseShellArguments(String raw) => List.unmodifiable([
    for (final match in _shellTokenPattern.allMatches(raw))
      _unquoteShellToken(match[0]!),
  ]);

  /// Formats parsed shell [args] back into a round-trippable input string.
  static String formatShellArguments(List<String> args) =>
      [for (final arg in args) _formatShellArgument(arg)].join(' ');

  static String _formatShellArgument(String arg) {
    if (arg.isEmpty) return '""';
    if (!_needsShellQuoting.hasMatch(arg)) return arg;
    final escaped = arg.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return '"$escaped"';
  }

  static String _unquoteShellToken(String token) {
    final out = StringBuffer();
    String? quote;
    for (var i = 0; i < token.length; i++) {
      final ch = token[i];
      if (ch == r'\' && quote != "'" && i + 1 < token.length) {
        out.write(token[++i]);
      } else if (ch == quote) {
        quote = null;
      } else if (quote == null && (ch == '"' || ch == "'")) {
        quote = ch;
      } else {
        out.write(ch);
      }
    }
    return out.toString();
  }

  LocalShellConfig _defaultLocalShellConfig({String? workingDirectory}) =>
      LocalShellConfig(
        executable: _preferences.shellExecutable,
        arguments: _preferences.shellArguments,
        loginShell: _preferences.loginShell,
        workingDirectory: workingDirectory,
        colorScheme: _platformBrightness,
      );

  /// Reloads stored settings and preferences synchronously from disk/localStorage.
  bool reloadSettingsFromStorage() {
    if (_disposed) return false;
    _settingsSaver.cancelPending();
    if (_storage case final BatchSettingsStorage batch) {
      batch.invalidateCache();
    }
    _workspaceSettings = loadStoredSettings(
      _storage,
      defaultDockPosition: _workspaceSettings.dockPosition,
    );
    _preferences = loadStoredPreferences(_storage);
    audioController
      ..setMuted(_preferences.audioMuted)
      ..setVolume(_preferences.audioVolume);
    _applyColorResolver();
    _shaderParamsByPass = _decodeShaderParamsMap(
      _preferences.customShaderProfileJson,
    );
    _rebuildActiveShaderConfig();
    unawaited(
      _shaderController.setBackendOverride(
        _preferences.shaderBackendOverride,
        sourceLoader: _shaderProfileStore.loadShaderSource,
      ),
    );
    unawaited(_syncActiveShaders());
    _syncClipboardPolicies();
    _syncPaneCliShaderPolicies();
    updateViewModel.onPreferencesChanged();
    _notifyChromeChanged();
    return true;
  }

  /// Synchronizes system dark/light brightness changes onto theme & local shells.
  void setPlatformBrightness(tui.TerminalBrightness brightness) {
    if (_disposed || _platformBrightness == brightness) return;
    _platformBrightness = brightness;
    _applyColorResolver();
    _notifyChromeChanged();
  }

  /// Tracks foreground window visibility (`false` increments unread bells even
  /// on focused pane and flushes pending settings writes).
  void setWorkspaceVisible(bool visible) {
    if (_disposed || _workspaceVisible == visible) return;
    _workspaceVisible = visible;
    if (visible) {
      activeTab?.unreadBellCount = 0;
      focusedPane?.clearBellCount();
    } else {
      _settingsSaver.flush();
    }
    _notifyChromeChanged();
  }

  /// Tracks whether the `fterm` OS window currently holds input focus.
  void setWindowFocused(bool focused) {
    if (_disposed || _windowFocused == focused) return;
    _windowFocused = focused;
    _notifyChromeChanged();
  }

  void _syncClipboardPolicies() {
    for (final pane in _panes.values) {
      pane.remotePort?.clipboardPolicy = _workspaceSettings.osc52Policy;
    }
  }

  void _syncPaneCliShaderPolicies() {
    final userHasFullPane =
        backgroundShaderChain.isNotEmpty || foregroundShaderChain.isNotEmpty;
    final backendKind = _shaderController.backendKind;
    for (final pane in _panes.values) {
      pane.syncCliShaderPolicy(
        policy: pane.isLocal
            ? _preferences.localCliShaderPolicy
            : _preferences.remoteCliShaderPolicy,
        fullPaneMode: _preferences.cliFullPaneShaderMode,
        trustedHashes: _preferences.trustedCliShaderHashes,
        userHasFullPaneShaders: userHasFullPane,
        backendKind: backendKind,
      );
    }
    _syncActiveCliFullPaneShaders();
  }

  void _handlePaneCliShaderUiChanged(String _) {
    if (_disposed) return;
    _syncActiveCliFullPaneShaders();
    _notifyChromeChanged();
  }

  void _handlePaneCliShaderQuarantined(
    String paneId,
    String shaderId,
    String reason,
  ) {
    if (_disposed) return;
    _setStatusBanner('Quarantined CLI shader "$shaderId": $reason');
  }

  /// Cancels throttled timers and flushes settings immediately (e.g., on pause).
  void flushPendingSettings() {
    if (_disposed) return;
    _settingsSaver.flush();
  }

  FtermPaneController _createPaneController({
    required String paneId,
    required TerminalPort port,
    LocalPaneHost? localHost,
    SessionId? remoteSessionId,
  }) {
    if (port is RemoteTerminalPort) {
      port.clipboardPolicy = _workspaceSettings.osc52Policy;
    }
    final isLocalPane = localHost != null;
    final pane = FtermPaneController(
      paneId: paneId,
      port: port,
      colorResolver: _colorResolver,
      localHost: localHost,
      remoteSessionId: remoteSessionId,
      resizeDebounce: _resizeDebounce,
      onBell: _handlePaneBell,
      onAudio: _handlePaneAudio,
      onTitleChanged: _handlePaneTitleChanged,
      onClipboard: _handlePaneClipboard,
      onExited: _handlePaneExited,
      onShareChanged: _handlePaneShareChanged,
      onFrameRedrawn: _onFrameRedrawn,
      cliShaderPolicy: isLocalPane
          ? _preferences.localCliShaderPolicy
          : _preferences.remoteCliShaderPolicy,
      cliFullPaneShaderMode: _preferences.cliFullPaneShaderMode,
      trustedCliShaderHashes: _preferences.trustedCliShaderHashes,
      shaderBackend: _shaderController.backend,
      onCliShaderUiChanged: _handlePaneCliShaderUiChanged,
      onCliShaderQuarantined: _handlePaneCliShaderQuarantined,
    );
    pane.syncCliShaderPolicy(
      policy: isLocalPane
          ? _preferences.localCliShaderPolicy
          : _preferences.remoteCliShaderPolicy,
      fullPaneMode: _preferences.cliFullPaneShaderMode,
      trustedHashes: _preferences.trustedCliShaderHashes,
      userHasFullPaneShaders:
          backgroundShaderChain.isNotEmpty || foregroundShaderChain.isNotEmpty,
      backendKind: _shaderController.backendKind,
    );
    return pane;
  }

  bool _isCanonicalEventPane(String paneId) {
    final pane = _panes[paneId];
    if (pane == null) return false;
    final remoteId = pane.remoteSessionId;
    if (remoteId == null) return true;
    final focused = focusedPane;
    if (focused != null && focused.remoteSessionId == remoteId) {
      return focused.paneId == paneId;
    }
    for (final candidate in _panes.values) {
      if (candidate.remoteSessionId == remoteId) {
        return candidate.paneId == paneId;
      }
    }
    return false;
  }

  void _handlePaneBell(String paneId) {
    if (_disposed || !_isCanonicalEventPane(paneId)) return;
    _bellEventsCount += 1;
    final tabIdx = _findTabIndexContainingPane(paneId);
    final pan = _computePaneStereoPan(tabIdx, paneId);
    unawaited(audioController.playBell(pan: pan));

    final isForegroundFocused =
        _workspaceVisible &&
        tabIdx >= 0 &&
        tabIdx == activeTabIndex &&
        _tabs[tabIdx].splitTree.focusedPaneId == paneId;
    if (!isForegroundFocused && tabIdx >= 0 && tabIdx < _tabs.length) {
      _tabs[tabIdx].unreadBellCount += 1;
      _notifyChromeChanged();
    }
  }

  void _handlePaneAudio(String paneId, TerminalAudioEvent event) {
    if (_disposed || !_isCanonicalEventPane(paneId)) return;
    final pane = _panes[paneId];
    if (pane == null) return;
    _audioEventsCount += 1;
    if (event case TerminalWaveformQueryAudioEvent(:final requestId)) {
      _handleWaveformQuery(pane, requestId);
      return;
    }
    final tabIdx = _findTabIndexContainingPane(paneId);
    final pan = _computePaneStereoPan(tabIdx, paneId);
    unawaited(
      audioController.handleAudioEvent(
        event,
        scopeKey: _scopeKeyForPane(pane),
        fallbackPan: pan,
      ),
    );
  }

  void _handleWaveformQuery(FtermPaneController pane, int requestId) {
    final isForegroundFocused =
        _workspaceVisible &&
        _windowFocused &&
        focusedPane?.paneId == pane.paneId;
    final remotePort = pane.remotePort;
    if (remotePort != null) {
      final samples = isForegroundFocused
          ? audioController.captureActiveWaveform()
          : null;
      remotePort.sendWaveformReply(requestId, samples ?? Float32List(256));
      return;
    }
    if (!isForegroundFocused || pane.hasExited) return;
    final samples = audioController.captureActiveWaveform();
    if (samples == null) return;
    final encoded = ApcAudioEncoder.encodeWaveformReply(requestId, samples);
    pane.port.sendInput(Uint8List.fromList(utf8.encode(encoded)));
  }

  void _handlePaneTitleChanged(String _, String _) {
    if (_disposed) return;
    _titleEventsCount += 1;
    _notifyChromeChanged();
  }

  double _computePaneStereoPan(int tabIdx, String paneId) {
    if (tabIdx != activeTabIndex || tabIdx < 0 || tabIdx >= _tabs.length) {
      return 0.0;
    }
    return _tabs[tabIdx].splitTree.panOf(paneId);
  }

  void _handlePaneClipboard(String paneId, String selection, String text) {
    if (_disposed || text.isEmpty) return;
    if (_workspaceSettings.osc52Policy == Osc52ClipboardPolicy.deny) return;
    if (!_workspaceVisible || !_windowFocused) return;
    if (focusedPane?.paneId != paneId) return;
    const maxBytes = CastWorkspaceSettings.defaultMaxOsc52ClipboardBytes;
    if (text.length > maxBytes) return;
    if (text.length * 3 > maxBytes && utf8.encode(text).length > maxBytes) {
      return;
    }
    if (selection.contains('c') || selection.isEmpty) {
      unawaited(
        Clipboard.setData(ClipboardData(text: text)).catchError((_) {}),
      );
    }
  }

  void _handlePaneExited(String paneId, int exitCode) {
    if (_disposed) return;
    final pane = _panes[paneId];
    final sharedId = pane?.shareSnapshot.sessionId;
    if (sharedId != null) {
      _ownedSharedSessionIds.remove(sharedId);
    }
    if (pane != null) {
      _disposeScopeIfUnused(pane, excludingPaneId: paneId, requireLive: true);
    }
    _notifyChromeChanged();
  }

  void _handlePaneShareChanged() {
    if (_disposed) return;
    final latestError = _syncPaneShareOwnershipAndErrors();
    _applyShareStatusBanner(latestError);
    _notifyChromeChanged();
  }

  String? _syncPaneShareOwnershipAndErrors() {
    String? latestError;
    for (final pane in _panes.values) {
      final snap = pane.localHost?.shareSnapshot;
      if (snap == null) continue;
      _syncOwnedSharedSessionId(snap);
      final error = snap.errorMessage;
      if (snap.state != LocalShareState.live &&
          error != null &&
          error.isNotEmpty) {
        latestError = error;
      }
    }
    return latestError;
  }

  void _syncOwnedSharedSessionId(LocalShareSnapshot snap) {
    final sessionId = snap.sessionId;
    if (sessionId == null) return;
    if (snap.state == LocalShareState.unshared) {
      _ownedSharedSessionIds.remove(sessionId);
    } else {
      _ownedSharedSessionIds.add(sessionId);
    }
  }

  void _applyShareStatusBanner(String? latestError) {
    if (latestError == null) {
      _lastLoggedShareError = null;
      if (_statusBanner?.startsWith('Share failed: ') ?? false) {
        _statusBanner = null;
      }
      return;
    }
    _statusBanner = 'Share failed: $latestError';
    if (latestError != _lastLoggedShareError) {
      _lastLoggedShareError = latestError;
      diagnosticLog.record(DiagnosticEventKind.localShareFailed);
    }
  }

  void _onUpdateCoarseStateChanged() {
    if (_disposed) return;
    final isError = updateViewModel.status == UpdateStatus.error;
    if (isError && !_lastUpdateWasError) {
      diagnosticLog.record(DiagnosticEventKind.updateError);
    }
    _lastUpdateWasError = isError;
    _notifyChromeChanged();
  }

  void _onClientConnecting(Uri _) {
    if (_disposed) return;
    _connectionState = ClientConnectionState.connecting;
    _notifyChromeChanged();
  }

  void _onClientConnectFailed(bool _) {
    if (_disposed) return;
    if (_connectionState != ClientConnectionState.authFailed) {
      _connectionState = ClientConnectionState.reconnecting;
    }
    _notifyChromeChanged();
  }

  void _onClientDisconnected(bool _) {
    if (_disposed) return;
    diagnosticLog.record(DiagnosticEventKind.relayDisconnected);
    if (_connectionState != ClientConnectionState.authFailed) {
      _connectionState = ClientConnectionState.reconnecting;
    }
    _notifyChromeChanged();
  }

  void _onServerMessage(CastMessage message) {
    if (_disposed) return;
    switch (message) {
      case AuthAcceptedFrame():
        _connectionState = ClientConnectionState.authenticated;
        _authErrorMessage = null;
        _statusBanner = null;
        _notifyChromeChanged();
      case SessionDirectoryFrame(:final sessions):
        _connectionState = ClientConnectionState.authenticated;
        _authErrorMessage = null;
        _remoteDirectorySessions
          ..clear()
          ..addAll(sessions);
        if (!localHostDriver.isSupported) {
          _syncAutoRemoteTabs();
        }
        _notifyChromeChanged();
      case FileUploadAckFrame():
        _uploadCoordinator.handleAckFrame(message);
      case SessionClosedFrame():
        _notifyChromeChanged();
      case ErrorFrame(:final code, :final message):
        if (CastClientRepository.isFatalAuthErrorCode(code)) {
          diagnosticLog.record(DiagnosticEventKind.relayAuthFailed);
          _connectionState = ClientConnectionState.authFailed;
          _authErrorMessage = message;
          _statusBanner = message;
          if (!localHostDriver.isSupported) {
            _activeOverlay = FtermOverlay.connect;
          }
          _notifyChromeChanged();
        } else {
          diagnosticLog.record(DiagnosticEventKind.relayProtocolError);
          _setStatusBanner(message);
        }
      default:
        break;
    }
  }

  void _syncAutoRemoteTabs() {
    final sessions = availableRemoteSessions;
    for (final info in sessions) {
      if (_dismissedRemoteSessions.contains(info.id)) continue;
      if (_findTabIndexForSession(info.id) >= 0) continue;
      final port = repository.openTerminalPort(info.id);
      final paneId = _allocatePaneId();
      final pane = _createPaneController(
        paneId: paneId,
        port: port,
        remoteSessionId: info.id,
      );
      _panes[paneId] = pane;
      _tabs.add(
        FtermTabState(
          tabId: _allocateTabId(),
          splitTree: SplitTreeModel.single(paneId),
        ),
      );
    }
    if (_tabs.isNotEmpty) {
      _activeTabIndex = _activeTabIndex.clamp(0, _tabs.length - 1);
      _syncFocusedPaneStates();
    }
  }

  void _syncFocusedPaneStates() {
    final currentTab = activeTab;
    final activePaneId = currentTab?.splitTree.focusedPaneId;
    for (final MapEntry(key: id, value: pane) in _panes.entries) {
      pane.setFocused(id == activePaneId && _workspaceVisible);
    }
  }

  void _applyColorResolver() {
    _colorResolver = _buildColorResolver(
      _workspaceSettings.themeSettings,
      _platformBrightness,
    );
    for (final pane in _panes.values) {
      pane.setColorResolver(_colorResolver);
    }
  }

  int _findTabIndexForSession(SessionId sessionId) {
    for (var i = 0; i < _tabs.length; i++) {
      for (final paneId in _tabs[i].splitTree.paneIds) {
        if (_panes[paneId]?.remoteSessionId == sessionId) {
          return i;
        }
      }
    }
    return -1;
  }

  int _findTabIndexContainingPane(String paneId) {
    for (var i = 0; i < _tabs.length; i++) {
      if (_tabs[i].splitTree.containsPane(paneId)) return i;
    }
    return -1;
  }

  void _setStatusBanner(String message) {
    _statusBanner = message;
    _notifyChromeChanged();
  }

  void _notifyChromeChanged() {
    if (_disposed) return;
    _chromeNotifier.emitChange();
    notifyListeners();
  }

  static String _allocatePaneId() => 'pane-${++_idCounter}';
  static String _allocateTabId() => 'tab-${++_idCounter}';

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _uploadCoordinator.cancel();
    clientConnectingEvent.removeListener(repository.bus, _onClientConnecting);
    clientConnectFailedEvent.removeListener(
      repository.bus,
      _onClientConnectFailed,
    );
    clientMessageReceivedEvent.removeListener(repository.bus, _onServerMessage);
    clientDisconnectedEvent.removeListener(
      repository.bus,
      _onClientDisconnected,
    );
    updateViewModel.dispose();
    aboutViewModel.dispose();
    final shaderWatchSubscription = _shaderWatchSubscription;
    _shaderWatchSubscription = null;
    _shaderController.removeListener(_onShaderControllerChanged);
    _disposeOwnedSubsystems();
    _settingsSaver.dispose();
    if (shaderWatchSubscription != null) {
      unawaited(shaderWatchSubscription.cancel());
    }
    await _settingsSaver.flushAsync();
    final activePanes = [..._panes.values];
    _panes.clear();
    _tabs.clear();
    _ownedSharedSessionIds.clear();
    await Future.wait([
      _disposePanesAndHost(activePanes),
      audioController.dispose(),
      repository.dispose(),
    ]);
    _chromeNotifier.dispose();
    super.dispose();
  }

  void _disposeOwnedSubsystems() {
    if (_ownsShaderProfileStore) {
      _shaderProfileStore.dispose();
    }
    if (_ownsShaderController) {
      _shaderController.dispose();
    }
    if (_ownsTraceRecorder) {
      traceRecorder.dispose();
    }
    if (_ownsDiagnosticLog) {
      diagnosticLog.dispose();
    }
  }

  Future<void> _disposePanesAndHost(
    List<FtermPaneController> activePanes,
  ) async {
    try {
      await Future.wait([
        for (final pane in activePanes) pane.dispose(disposePort: true),
      ]);
    } finally {
      await localHostDriver.dispose();
    }
  }
}
