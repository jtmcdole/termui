import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:path/path.dart' as p;
import 'package:termui/termui.dart' as tui;
import 'package:termui_audio_flutter/termui_audio_flutter.dart';
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_pty/termui_pty.dart';

import '../audio/fterm_audio_controller.dart';
import '../launch_config.dart';
import '../settings_storage.dart';
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

  /// Drag-and-drop multi-file upload confirmation and progress sheet.
  fileUpload,
}

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

  final List<FtermTabState> _tabs = [];
  final Map<String, FtermPaneController> _panes = {};
  final List<SessionSummary> _remoteDirectorySessions = [];
  final Set<SessionId> _ownedSharedSessionIds = {};
  final Set<SessionId> _dismissedRemoteSessions = {};
  final _ChromeChangeNotifier _chromeNotifier = _ChromeChangeNotifier();

  late final FileUploadCoordinator _uploadCoordinator;

  CastWorkspaceSettings _workspaceSettings;
  FtermPreferences _preferences;
  RelayCredentials _relayCredentials;
  tui.TerminalBrightness _platformBrightness;
  TerminalColorResolver _colorResolver;

  ClientConnectionState _connectionState = ClientConnectionState.unconnected;
  String? _authErrorMessage;
  int _activeTabIndex = 0;
  FtermOverlay _activeOverlay = FtermOverlay.none;
  bool _leaderArmed = false;
  bool _workspaceVisible = true;
  bool _started = false;
  bool _disposed = false;
  int _bellEventsCount = 0;
  int _audioEventsCount = 0;
  int _titleEventsCount = 0;
  String? _statusBanner;
  List<DroppedFileSource> _pendingUploadFiles = const [];
  Uri _activeRelayUri;
  String _activeClientToken;
  String _activeCasterToken;
  bool _shouldAutoConnectRelay = false;

  /// Creates the workspace coordinator for `fterm`.
  factory FtermWorkspaceController({
    required CastLaunchConfig launchConfig,
    required CastClientRepository repository,
    required LocalHostDriver localHostDriver,
    required FtermAudioController audioController,
    required SettingsStorage storage,
    DockPosition defaultDockPosition = DockPosition.top,
    tui.TerminalBrightness initialBrightness = tui.TerminalBrightness.dark,
    Duration resizeDebounce = const Duration(milliseconds: 32),
    Clock? clock,
    void Function(tui.Buffer buffer)? onFrameRedrawn,
  }) => FtermWorkspaceController._(
    launchConfig: launchConfig,
    repository: repository,
    localHostDriver: localHostDriver,
    audioController: audioController,
    storage: storage,
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
    onFrameRedrawn: onFrameRedrawn,
  );

  FtermWorkspaceController._({
    required this.launchConfig,
    required this.repository,
    required this.localHostDriver,
    required this.audioController,
    required SettingsStorage storage,
    required CastWorkspaceSettings initialSettings,
    required FtermPreferences initialPreferences,
    required RelayCredentials initialCredentials,
    required tui.TerminalBrightness initialBrightness,
    required Duration resizeDebounce,
    required Clock? clock,
    required void Function(tui.Buffer buffer)? onFrameRedrawn,
  }) : _storage = storage,
       _settingsSaver = ThrottledSettingsSaver(storage),
       _resizeDebounce = resizeDebounce,
       _clock = clock ?? const Clock(),
       _onFrameRedrawn = onFrameRedrawn,
       _platformBrightness = initialBrightness,
       _workspaceSettings = initialSettings,
       _preferences = initialPreferences,
       _relayCredentials = initialCredentials,
       _activeRelayUri = launchConfig.serverUri,
       _activeClientToken = launchConfig.token,
       _activeCasterToken = launchConfig.casterToken,
       _colorResolver = _buildColorResolver(
         initialSettings.themeSettings,
         initialBrightness,
       ) {
    _hydrateSavedRelaySettings();
    audioController
      ..setMuted(_preferences.audioMuted)
      ..setVolume(_preferences.audioVolume);
    _uploadCoordinator = FileUploadCoordinator(
      repository: repository,
      onProgressChanged: _notifyChromeChanged,
      onError: _setStatusBanner,
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
    _shouldAutoConnectRelay =
        !launchConfig.promptForConnection ||
        _activeClientToken.isNotEmpty ||
        _relayCredentials.serverUrl.trim().isNotEmpty;
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

  /// Whether this host supports local interactive desktop shells.
  bool get isDesktopHost => localHostDriver.isSupported;

  /// Whether a `Ctrl+\` modal chord is currently armed.
  bool get isLeaderArmed => _leaderArmed;

  /// Active modal overlay (`FtermOverlay.none` when workspace is clear).
  FtermOverlay get activeOverlay => _activeOverlay;

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

  /// Persisted/active relay credentials snapshot.
  RelayCredentials get relayCredentials => RelayCredentials(
    serverUrl: _activeRelayUri.toString(),
    clientToken: _activeClientToken,
    casterToken: _activeCasterToken,
  );

  /// Active relay `/v1/client` URI.
  Uri get activeRelayUri => _activeRelayUri;

  /// Active viewer bearer token.
  String get activeClientToken => _activeClientToken;

  /// Active caster bearer token used when publishing local panes.
  String get activeCasterToken => _activeCasterToken;

  /// Resolved color theme matching current appearance & system polarity.
  tui.TerminalColorTheme get activeTerminalTheme => _colorResolver.theme;

  /// Active `copyOnSelect` preference.
  bool get copyOnSelect => _workspaceSettings.copyOnSelect;

  /// Active F12 shortcut gate (`false` = passthrough to terminal).
  bool get f12ShortcutsEnabled => _workspaceSettings.f12ShortcutsEnabled;

  /// Active dock position (`top`, `left`, or `hidden`).
  DockPosition get dockPosition => _workspaceSettings.dockPosition;

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

  /// Starts initial tabs (local shell on Desktop; auto-relay or Connect modal on Web).
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
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
  }

  void _startInitialRelayConnection() {
    if (_activeRelayUri != launchConfig.serverUri ||
        _activeClientToken != launchConfig.token) {
      unawaited(
        repository.reconnect((
          serverUri: _activeRelayUri,
          token: _activeClientToken,
        )),
      );
      return;
    }
    unawaited(repository.connect(retryOnFailure: true));
  }

  /// Connects or reconnects the relay client repository using explicit credentials
  /// and optionally persists them to `0600` desktop storage.
  Future<void> connectRelay({
    required Uri serverUri,
    required String clientToken,
    String? casterToken,
    bool persistCredentials = true,
  }) async {
    if (_disposed) return;
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
      );
      saveStoredRelayCredentials(_storage, _relayCredentials);
    }
    if (_activeOverlay == FtermOverlay.connect) {
      _activeOverlay = FtermOverlay.none;
    }
    _notifyChromeChanged();
    await repository.reconnect((serverUri: serverUri, token: clientToken));
  }

  /// Opens a new local shell tab (desktop only).
  Future<String?> openLocalShellTab([LocalShellConfig? config]) async {
    if (_disposed || !localHostDriver.isSupported) return null;
    final shellConfig =
        config ?? LocalShellConfig(colorScheme: _platformBrightness);
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
      if (localHostDriver.isSupported && remoteSessionId == null) {
        return openLocalShellTab(localShellConfig);
      }
      if (remoteSessionId != null) {
        return openRemoteSessionTab(remoteSessionId);
      }
      return null;
    }

    final targetPaneId = tab.splitTree.focusedPaneId;
    final currentPane = _panes[targetPaneId];
    final FtermPaneController newPane;
    final newPaneId = _allocatePaneId();
    if (remoteSessionId == null &&
        localHostDriver.isSupported &&
        (currentPane?.isLocal ?? true)) {
      final host = await localHostDriver.openShell(
        localShellConfig ??
            LocalShellConfig(
              workingDirectory: currentPane?.localHost?.port.workingDirectory,
              colorScheme: _platformBrightness,
            ),
      );
      if (_disposed ||
          !_tabs.contains(tab) ||
          !tab.splitTree.containsPane(targetPaneId)) {
        await host.dispose();
        return null;
      }
      newPane = _createPaneController(
        paneId: newPaneId,
        port: host.port,
        localHost: host,
      );
    } else {
      final targetSession =
          remoteSessionId ??
          currentPane?.remoteSessionId ??
          availableRemoteSessions.firstOrNull?.id;
      if (targetSession == null) return null;
      final port = repository.openTerminalPort(targetSession);
      newPane = _createPaneController(
        paneId: newPaneId,
        port: port,
        remoteSessionId: targetSession,
      );
    }

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
    if (targetId == null) return false;
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
        iapTokenProvider: launchConfig.iapTokenProviderFor(resolvedServer),
        channelOpener: channelOpener,
      );
      _ownedSharedSessionIds.add(assignedId);
      _notifyChromeChanged();
      return true;
    } on Object catch (error) {
      _setStatusBanner('Share failed: $error');
      return false;
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
    _activeOverlay = overlay;
    _leaderArmed = false;
    _notifyChromeChanged();
  }

  /// Dismisses the transient banner and active modal overlay.
  void dismissOverlay() {
    _leaderArmed = false;
    _statusBanner = null;
    if (_activeOverlay != FtermOverlay.none) {
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
    _pendingUploadFiles = List<DroppedFileSource>.unmodifiable(files);
    _setOverlay(FtermOverlay.fileUpload);
  }

  /// Uploads staged [pendingUploadFiles] to the focused remote session.
  Future<bool> confirmFileUpload() async {
    final sessionId = focusedPane?.remoteSessionId;
    final files = _pendingUploadFiles;
    if (sessionId == null || files.isEmpty) return false;
    final ok = await _uploadCoordinator.uploadFiles(sessionId, files);
    if (ok && !_disposed) {
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
    _settingsSaver.save(next);
    _notifyChromeChanged();
  }

  /// Updates and persists [FtermPreferences] (`audioMuted`, `audioVolume`,
  /// `autoHideSingleTab`, `macosOptionAsAlt`).
  void updatePreferences(FtermPreferences next) {
    if (_disposed || _preferences == next) return;
    _preferences = next;
    audioController
      ..setMuted(next.audioMuted)
      ..setVolume(next.audioVolume);
    _settingsSaver.savePreferences(next);
    _notifyChromeChanged();
  }

  /// Reloads stored settings and preferences synchronously from disk/localStorage.
  bool reloadSettingsFromStorage() {
    if (_disposed) return false;
    _settingsSaver.cancelPending();
    _workspaceSettings = loadStoredSettings(
      _storage,
      defaultDockPosition: _workspaceSettings.dockPosition,
    );
    _preferences = loadStoredPreferences(_storage);
    audioController
      ..setMuted(_preferences.audioMuted)
      ..setVolume(_preferences.audioVolume);
    _applyColorResolver();
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
  }) => FtermPaneController(
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
  );

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
    final samples = audioController.captureActiveWaveform();
    if (samples == null) return;
    final remotePort = pane.remotePort;
    if (remotePort != null) {
      remotePort.sendWaveformReply(requestId, samples);
      return;
    }
    if (pane.hasExited) return;
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
    String? latestError;
    for (final pane in _panes.values) {
      final host = pane.localHost;
      if (host == null) continue;
      final snap = host.shareSnapshot;
      if (snap.state == LocalShareState.unshared && snap.sessionId != null) {
        _ownedSharedSessionIds.remove(snap.sessionId);
      } else if (snap.sessionId != null) {
        _ownedSharedSessionIds.add(snap.sessionId!);
      }
      if (snap.state != LocalShareState.live &&
          snap.errorMessage != null &&
          snap.errorMessage!.isNotEmpty) {
        latestError = snap.errorMessage;
      }
    }
    if (latestError != null) {
      _statusBanner = 'Share failed: $latestError';
    } else if (_statusBanner?.startsWith('Share failed: ') ?? false) {
      _statusBanner = null;
    }
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
      case ClipboardFrame(:final text, :final readBlocked):
        if (!readBlocked && text.isNotEmpty) {
          unawaited(
            Clipboard.setData(ClipboardData(text: text)).catchError((_) {}),
          );
        }
      case SessionClosedFrame():
        _notifyChromeChanged();
      case ErrorFrame(:final code, :final message):
        if (CastClientRepository.isFatalAuthErrorCode(code)) {
          _connectionState = ClientConnectionState.authFailed;
          _authErrorMessage = message;
          _statusBanner = message;
          if (!localHostDriver.isSupported) {
            _activeOverlay = FtermOverlay.connect;
          }
          _notifyChromeChanged();
        } else {
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
    _settingsSaver.dispose();
    final activePanes = [..._panes.values];
    _panes.clear();
    _tabs.clear();
    _ownedSharedSessionIds.clear();
    await Future.wait([
      for (final pane in activePanes) pane.dispose(disposePort: true),
    ]);
    await localHostDriver.dispose();
    await audioController.dispose();
    await repository.dispose();
    _chromeNotifier.dispose();
    super.dispose();
  }
}
