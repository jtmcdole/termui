import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:termui/terminal/event.dart' as ev;
import 'package:termui/termui.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_pty/termui_pty.dart';

import 'cast_client_repository.dart';
import 'file_upload_coordinator.dart';
import 'models.dart';
import 'network_telemetry_tracker.dart';
import 'scrollback_page_cache.dart';
import 'session_slot.dart';
import 'session_tab_strip.dart';
import 'terminal_theme_settings.dart';
import 'workspace_buffer_compositor.dart';
import 'workspace_pointer_controller.dart';

export 'session_slot.dart' show ClientSessionSyncState;

/// Pure-Dart MVVM view model managing multi-PTY sessions, HSM gating, and input encoding.
final class CastWorkspaceViewModel {
  /// Maximum UTF-8 byte length (`1 MiB`) accepted by [encodeAndSendPaste].
  static const int maxPasteBytes = 1048576;

  /// Default cap on retained ended (`⏳` / `⏻` / `💀`) tabs before LRU eviction.
  static const int defaultMaxRetainedEndedTabs =
      SessionTabStrip.defaultMaxRetainedEndedTabs;
  static final Clock _zoneClock = Clock(() => clock.now());

  /// Backing client repository.
  final CastClientRepository repository;

  /// Debounce window applied to rapid viewport resize events.
  final Duration resizeDebounce;

  /// Duration before transient clipboard or security notices auto-dismiss.
  final Duration clipboardNoticeDuration;

  /// Timeout before an unacknowledged [RequestScrollbackFrame] retries while idle.
  final Duration scrollbackRequestTimeout;

  /// Tick interval for mouse-selection drag-to-edge auto-scrolling.
  final Duration dragAutoScrollInterval;

  /// Tick interval for the Rainbow Road link-hover wave while `Ctrl`/`Cmd` is held.
  final Duration linkHoverAnimationInterval;

  /// Grace period before an inactive tab or hidden workspace unsubscribes its stream.
  final Duration inactiveSessionGrace;

  /// Optional sink invoked when local selection or `OSC 52` writes to clipboard.
  void Function(String text)? onClipboardWrite;

  /// Optional callback invoked when `Ctrl+Click` / `Cmd+Click` opens a URL.
  void Function(Uri url)? onOpenUrl;

  /// Optional callback invoked whenever user-configurable [settings] change.
  void Function(CastWorkspaceSettings settings)? onSettingsChanged;

  /// Optional callback invoked by [reloadSettingsFromStorage] to re-read persisted settings.
  final CastWorkspaceSettings Function()? onReloadSettings;

  final Map<SessionId, SessionSlot> _slots = {};
  final List<void Function()> _visualListeners = [];
  late final FileUploadCoordinator _uploadCoordinator = FileUploadCoordinator(
    repository: repository,
    onProgressChanged: _notifyVisualListeners,
    onError: _onUploadError,
  );
  final SessionTabStrip _tabStrip;
  Clock? _clock;
  NetworkTelemetryTracker? _telemetry;
  WorkspacePointerController? _pointer;
  SessionId? _activeSessionId;
  SessionId? _pendingFocusInSessionId;
  DockPosition _dockPosition;
  ClientConnectionState _connectionState = .unconnected;
  String? _authErrorMessage;
  int _viewportCols;
  int _viewportRows;
  (double width, double height) _cellPixelSize = (8.0, 16.0);
  bool _copyOnSelect;
  bool _debugOverlayEnabled;
  bool _f12ShortcutsEnabled;
  TerminalThemeSettings _themeSettings;
  TerminalBrightness _platformBrightness;
  TerminalColorTheme? _cachedActiveTheme;
  TerminalColorResolver? _cachedColorResolver;
  Timer? _countdownTimer;
  Timer? _workspaceSuspendTimer;
  String? _lastCopiedText;
  String? _clipboardNotice;
  Timer? _clipboardNoticeTimer;
  Timer? _resizeDebounceTimer;
  bool _workspaceVisible = true;
  bool _suspendedWhileHidden = false;
  bool _disposed = false;

  Clock get _resolvedClock => _clock ??= _zoneClock;
  NetworkTelemetryTracker get _resolvedTelemetry => _telemetry ??=
      NetworkTelemetryTracker(initialRepoRxBytes: repository.totalRxBytes);
  WorkspacePointerController get _resolvedPointer =>
      _pointer ??= WorkspacePointerController(
        dragAutoScrollInterval: dragAutoScrollInterval,
        linkHoverAnimationInterval: linkHoverAnimationInterval,
        isDisposed: () => _disposed,
        activeSlot: () => _activeSlot,
        viewportCols: () => _viewportCols,
        viewportRows: () => _viewportRows,
        cellPixelSize: () => _cellPixelSize,
        copyOnSelect: () => _copyOnSelect,
        isHiddenClipboardNoticeVisible: () =>
            _dockPosition == .hidden &&
            !hasAttentionBanner &&
            _clipboardNotice != null,
        dismissClipboardNotice: dismissClipboardNotice,
        copySelectionToClipboard: copySelectionToClipboard,
        onCopyFileLink: _copyFileLinkToClipboard,
        scrollActiveBy: scrollActiveBy,
        sendInput: _sendSlotInput,
        onOpenUrl: () => onOpenUrl,
        onNotifyVisualListeners: _notifyVisualListeners,
        onEmitVisualChange: _emitVisualChange,
      );

  void _sendSlotInput(SessionId sessionId, List<int> bytes) =>
      repository.sendInput(
        sessionId,
        bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
      );

  /// Creates a multi-session workspace view model.
  CastWorkspaceViewModel({
    required this.repository,
    Clock? clock,
    this.resizeDebounce = const Duration(milliseconds: 32),
    this.clipboardNoticeDuration = const Duration(seconds: 4),
    this.scrollbackRequestTimeout = ScrollbackPageCache.requestTimeout,
    this.dragAutoScrollInterval = const Duration(milliseconds: 80),
    this.linkHoverAnimationInterval = const Duration(milliseconds: 48),
    this.inactiveSessionGrace = const Duration(seconds: 10),
    this.onClipboardWrite,
    this.onOpenUrl,
    this.onSettingsChanged,
    this.onReloadSettings,
    DockPosition initialDockPosition = .top,
    bool initialCopyOnSelect = true,
    bool initialDebugOverlayEnabled = false,
    bool initialF12ShortcutsEnabled = false,
    TerminalThemeSettings initialThemeSettings = const TerminalThemeSettings(),
    TerminalBrightness initialPlatformBrightness = .dark,
    int initialViewportCols = 80,
    int initialViewportRows = 23,
    int maxRetainedEndedTabs = defaultMaxRetainedEndedTabs,
  }) : _tabStrip = SessionTabStrip(maxRetainedEndedTabs: maxRetainedEndedTabs),
       _clock = clock ?? _zoneClock,
       _telemetry = NetworkTelemetryTracker(
         initialRepoRxBytes: repository.totalRxBytes,
       ),
       _dockPosition = initialDockPosition,
       _copyOnSelect = initialCopyOnSelect,
       _debugOverlayEnabled = initialDebugOverlayEnabled,
       _f12ShortcutsEnabled = initialF12ShortcutsEnabled,
       _themeSettings = initialThemeSettings,
       _platformBrightness = initialPlatformBrightness,
       _viewportCols = initialViewportCols.clamp(
         1,
         BufferFrameCodec.maxGridCols,
       ),
       _viewportRows = initialViewportRows.clamp(
         1,
         BufferFrameCodec.maxGridRows,
       ) {
    if (repository.transport.isConnected) _connectionState = .connecting;
    clientConnectingEvent.addListener(repository.bus, _onClientConnecting);
    clientConnectFailedEvent.addListener(
      repository.bus,
      _onClientConnectFailed,
    );
    clientMessageReceivedEvent.addListener(repository.bus, _onServerMessage);
    clientCorruptSessionFrameEvent.addListener(
      repository.bus,
      _onCorruptSessionFrame,
    );
    clientDisconnectedEvent.addListener(repository.bus, _onClientDisconnected);
  }

  /// Ordered live and retained ended sessions displayed in the tab strip.
  List<SessionSummary> get sessions => _tabStrip.sessions;

  /// Currently selected session identifier, or `null` when none exist.
  SessionId? get activeSessionId => _activeSessionId;

  /// Current placement of the tab dock (`top`, `left`, or `hidden`).
  DockPosition get dockPosition => _dockPosition;

  /// Whether releasing a non-empty mouse selection automatically copies it.
  bool get copyOnSelect => _copyOnSelect;

  /// Whether `termui` debug overlay rendering (layer borders, hover, touches) is enabled.
  bool get debugOverlayEnabled => _debugOverlayEnabled;

  /// Whether `F12` (screenshot) and `Shift+F12` (atlas reload) shortcuts are enabled.
  bool get f12ShortcutsEnabled => _f12ShortcutsEnabled;

  /// Active terminal theme and contrast settings.
  TerminalThemeSettings get themeSettings => _themeSettings;

  /// Operating system platform brightness polarity.
  TerminalBrightness get platformBrightness => _platformBrightness;

  /// The active [TerminalColorTheme] resolved for [platformBrightness].
  TerminalColorTheme get activeTerminalTheme => _cachedActiveTheme ??=
      _themeSettings.resolveActiveTheme(_platformBrightness);

  /// Cached [TerminalColorResolver] for [activeTerminalTheme] and [themeSettings].
  TerminalColorResolver get colorResolver =>
      _cachedColorResolver ??= TerminalColorResolver(
        theme: activeTerminalTheme,
        settings: _themeSettings,
      );

  /// Whether [reloadSettingsFromStorage] has a configured backing storage reader.
  bool get canReloadSettings => onReloadSettings != null;

  void _invalidateThemeCaches() {
    _cachedActiveTheme = null;
    _cachedColorResolver = null;
  }

  /// Snapshot of the current user-configurable workspace settings.
  CastWorkspaceSettings get settings => CastWorkspaceSettings(
    dockPosition: _dockPosition,
    copyOnSelect: _copyOnSelect,
    debugOverlayEnabled: _debugOverlayEnabled,
    f12ShortcutsEnabled: _f12ShortcutsEnabled,
    themeSettings: _themeSettings,
  );

  /// Active client-side text selection on the current session, if any.
  TerminalSelection? get activeSelection => _resolvedPointer.activeSelection;

  /// Currently hovered `http://` or `https://` [Uri] when `Ctrl` or `Cmd` is held, or `null`.
  Uri? get hoveredUrl => _resolvedPointer.hoveredLink?.url;

  /// Virtual-buffer [TerminalSelection] span of [hoveredUrl], or `null`.
  TerminalSelection? get hoveredUrlRange => _resolvedPointer.hoveredLink?.range;

  /// Most recent text written to the clipboard via local selection or `OSC 52`.
  String? get lastCopiedText => _lastCopiedText;

  /// Active transient clipboard or `OSC 52` security notice, if any.
  String? get clipboardNotice => _clipboardNotice;

  /// Active multi-file upload progress snapshot, or `null` when idle.
  FileUploadProgress? get fileUploadProgress => _uploadCoordinator.progress;

  /// Whether a browser-to-host file upload batch is currently in flight.
  bool get isUploadingFiles => _uploadCoordinator.isUploading;

  /// Current WebSocket connection and authentication state.
  ClientConnectionState get connectionState => _connectionState;

  /// Sanitized authentication error detail when [connectionState] is `authFailed`.
  String? get authErrorMessage => _authErrorMessage;

  /// Target `/v1/client` WebSocket URI configured on [repository].
  Uri get serverUri => repository.serverUri;

  /// Bearer token configured on [repository].
  String get currentToken => repository.token;

  /// Whether a high-priority status/error banner requires visible chrome.
  bool get hasAttentionBanner =>
      _connectionState == .authFailed ||
      _connectionState == .unconnected ||
      _connectionState == .reconnecting;

  /// User-facing status/error banner text, or `null` when authenticated normally.
  String? get statusBanner => switch (_connectionState) {
    .authFailed =>
      ' ! Auth failed: ${_authErrorMessage ?? 'Invalid bearer token'} | Press Enter or click to reconnect',
    .unconnected =>
      r' ! Not connected | Press Enter or Ctrl+\ c (or click) to connect',
    .reconnecting =>
      ' ! Reconnecting to ${repository.serverUri}... | Press Ctrl+\\ c or click to edit',
    .connecting when _tabStrip.isEmpty =>
      ' Connecting to ${repository.serverUri}...',
    _ => null,
  };

  /// Current PTY viewport width in columns.
  int get viewportCols => _viewportCols;

  /// Current PTY viewport height in rows.
  int get viewportRows => _viewportRows;

  /// Cursor state of the active session.
  CursorState get activeCursor => _activeSlot?.cursor ?? CursorState.origin;

  /// Terminal input modes of the active session.
  TerminalModes get activeModes => _activeSlot?.modes ?? TerminalModes.defaults;

  /// Whether the active session requests Kitty `KeyEventType.release` reporting (`0x02`).
  bool get wantsKeyReleaseEvents =>
      (activeModes.kittyKeyboardFlags & 0x02) != 0;

  /// Whether the active session requests `?1016h` SGR-Pixels pointer coordinates.
  bool get wantsPixelMouseEvents => activeModes.sgrPixelsMouse;

  /// Current viewer cell dimensions in logical pixels used to normalize `?1016h` mouse events.
  (double width, double height) get cellPixelSize => _cellPixelSize;

  /// Updates the viewer cell dimensions in logical pixels for `?1016h` normalization.
  void setCellPixelSize(double width, double height) {
    if (width <= 0 || height <= 0) return;
    _cellPixelSize = (width, height);
  }

  /// Current sequence number of the active session (`0` when unhydrated).
  int get activeSessionSeq => _activeSlot?.seq ?? 0;

  /// Number of primary-screen scrollback lines scrolled up from the live bottom.
  int get activeScrollOffsetLines => _activeSlot?.scrollOffsetLines ?? 0;

  /// Number of columns panned right across wide scrollback history (`0` at left edge or live bottom).
  int get activeScrollOffsetCols => _activeSlot?.scrollOffsetCols ?? 0;

  /// Total primary-screen scrollback lines currently retained for the active session.
  int get activeRetainedScrollbackLines =>
      _activeSlot?.scrollbackCache.retainedLines ?? 0;

  /// Current HSM synchronization state of the active session.
  ClientSessionSyncState get activeSessionSyncState =>
      _activeSlot?.state ?? .unsubscribed;

  /// Rolling network throughput and frame telemetry at the current [Clock] instant.
  CastNetworkStats get networkStats => _resolvedTelemetry.snapshot(
    _resolvedClock.now(),
    totalRxBytes: repository.totalRxBytes,
    totalTxBytes: repository.totalTxBytes,
  );
  SessionSlot? get _activeSlot =>
      _activeSessionId == null ? null : _slots[_activeSessionId!];

  /// Latest exit code if [sessionId] closed, or `null` while running.
  int? exitCodeOf(SessionId sessionId) =>
      _tabStrip.exitCodeOf(sessionId) ?? _slots[sessionId]?.exitCode;

  /// Computes the [SessionTabStatus] (`live`, `⏳`, `⏻`, or `💀`) for [sessionId].
  SessionTabStatus tabStatusOf(SessionId sessionId) =>
      _tabStrip.statusOf(sessionId, _resolvedClock.now());

  /// Whether [sessionId] is currently live on the relay server.
  bool isSessionLive(SessionId sessionId) => _tabStrip.isLive(sessionId);

  /// Current tab title of [sessionId], or `null` when absent.
  String? titleOf(SessionId sessionId) => _tabStrip.summaryOf(sessionId)?.title;

  /// Whether [sessionId] can be renamed right now (authenticated + live tab).
  bool canRenameSession(SessionId sessionId) =>
      !_disposed &&
      _connectionState == .authenticated &&
      _tabStrip.isLive(sessionId);

  /// Validates [rawTitle] and sends a [RenameSessionFrame] when [sessionId] is live.
  bool renameSession(SessionId sessionId, String rawTitle) {
    if (_disposed) return false;
    if (!canRenameSession(sessionId)) {
      _showClipboardNotice(' ! Cannot rename an ended session ');
      return false;
    }
    final (:title, error: _) = validateSessionTitle(rawTitle);
    if (title == null || _tabStrip.summaryOf(sessionId)?.title == title) {
      return false;
    }
    repository.renameSession(sessionId, title);
    return true;
  }

  /// Moves [sessionId] to [targetIndex] in the user tab order.
  bool moveSession(SessionId sessionId, int targetIndex) {
    if (_disposed || !_tabStrip.moveTab(sessionId, targetIndex)) return false;
    _notifyVisualListeners();
    return true;
  }

  /// Dismisses an ended (`⏳`, `⏻`, or `💀`) tab and disposes its retained buffer.
  Future<bool> dismissSession(SessionId sessionId) async {
    if (_disposed ||
        !_tabStrip.contains(sessionId) ||
        _tabStrip.isLive(sessionId)) {
      return false;
    }
    final dismissingActive = sessionId == _activeSessionId;
    final nextActive = dismissingActive
        ? _tabStrip.adjacentSessionAfterDismiss(sessionId)
        : _activeSessionId;
    if (!_tabStrip.dismiss(sessionId)) return false;
    _clearActiveSelectionForSlot(sessionId);
    _slots.remove(sessionId)?.dispose();
    _syncCountdownTimer();
    if (dismissingActive) {
      if (nextActive != null) {
        await selectSession(nextActive);
        return true;
      }
      _activeSessionId = null;
    }
    _notifyVisualListeners();
    return true;
  }

  /// Dismisses [activeSessionId] when it is an ended (`⏳`, `⏻`, or `💀`) tab.
  Future<bool> dismissActiveEndedSession() async =>
      _activeSessionId != null && await dismissSession(_activeSessionId!);

  /// Returns the current HSM synchronization state of [sessionId].
  ClientSessionSyncState sessionStateOf(SessionId sessionId) =>
      _slots[sessionId]?.state ?? .unsubscribed;

  /// Registers a visual update callback and returns an unsubscribe closure.
  void Function() addVisualListener(void Function() listener) {
    _visualListeners.add(listener);
    return () => _visualListeners.remove(listener);
  }

  void _notifyVisualListeners() {
    if (_disposed) return;
    _resolvedPointer.syncHoveredLinkState();
    _emitVisualChange();
  }

  void _emitVisualChange() {
    for (final listener in [..._visualListeners]) {
      listener();
    }
  }

  void _notifySettingsChanged() {
    onSettingsChanged?.call(settings);
    _notifyVisualListeners();
  }

  /// Updates the dock placement and notifies listeners.
  void setDockPosition(DockPosition position) {
    if (_dockPosition == position) return;
    _dockPosition = position;
    _notifySettingsChanged();
  }

  /// Cycles the dock placement (`top -> left -> hidden -> top`).
  void cycleDockPosition() => setDockPosition(_dockPosition.next);

  /// Updates whether completing a mouse selection automatically copies it.
  void setCopyOnSelect(bool enabled) {
    if (_copyOnSelect == enabled) return;
    _copyOnSelect = enabled;
    _notifySettingsChanged();
  }

  /// Toggles [copyOnSelect] and displays a transient confirmation notice.
  void toggleCopyOnSelect() {
    _copyOnSelect = !_copyOnSelect;
    onSettingsChanged?.call(settings);
    _showClipboardNotice(
      r' Copy-on-select: '
      '${_copyOnSelect ? "ON" : "OFF"}'
      r' (Ctrl+\ o) ',
    );
  }

  /// Updates whether `termui` debug overlay rendering is enabled.
  void setDebugOverlayEnabled(bool enabled) {
    if (_debugOverlayEnabled == enabled) return;
    _debugOverlayEnabled = enabled;
    _notifySettingsChanged();
  }

  /// Toggles [debugOverlayEnabled] and notifies visual listeners.
  void toggleDebugOverlay() => setDebugOverlayEnabled(!_debugOverlayEnabled);

  /// Updates whether `F12` and `Shift+F12` shortcuts are enabled.
  void setF12ShortcutsEnabled(bool enabled) {
    if (_f12ShortcutsEnabled == enabled) return;
    _f12ShortcutsEnabled = enabled;
    _notifySettingsChanged();
  }

  /// Toggles [f12ShortcutsEnabled] and notifies visual listeners.
  void toggleF12Shortcuts() => setF12ShortcutsEnabled(!_f12ShortcutsEnabled);

  /// Updates the detected OS [platformBrightness] and refreshes theme colors.
  void setPlatformBrightness(TerminalBrightness brightness) {
    if (_platformBrightness == brightness) return;
    _platformBrightness = brightness;
    _invalidateThemeCaches();
    _notifyVisualListeners();
  }

  /// Replaces the active [TerminalThemeSettings] and persists changes.
  void updateThemeSettings(TerminalThemeSettings newSettings) {
    if (_themeSettings == newSettings) return;
    _themeSettings = newSettings;
    _invalidateThemeCaches();
    _notifySettingsChanged();
  }

  /// Reloads workspace settings via [onReloadSettings] and shows a confirmation notice.
  bool reloadSettingsFromStorage() {
    if (_disposed) return false;
    final reloaded = onReloadSettings?.call();
    if (reloaded == null) return false;
    _dockPosition = reloaded.dockPosition;
    _copyOnSelect = reloaded.copyOnSelect;
    _debugOverlayEnabled = reloaded.debugOverlayEnabled;
    _f12ShortcutsEnabled = reloaded.f12ShortcutsEnabled;
    if (_themeSettings != reloaded.themeSettings) {
      _themeSettings = reloaded.themeSettings;
      _invalidateThemeCaches();
    }
    showTransientNotice('Settings reloaded from storage');
    return true;
  }

  /// Cycles through built-in theme presets in [TerminalColorTheme.presets].
  void cycleThemePreset() {
    const presets = TerminalColorTheme.presets;
    final currentId = activeTerminalTheme.id;
    var idx = 0;
    for (var i = 0; i < presets.length; i++) {
      if (presets[i].id == currentId) {
        idx = i;
        break;
      }
    }
    final nextPreset = presets[(idx + 1) % presets.length];
    final isDark = nextPreset.brightness == .dark;
    updateThemeSettings(
      _themeSettings.copyWith(
        appearanceMode: isDark ? .dark : .light,
        darkThemeId: isDark ? nextPreset.id : null,
        lightThemeId: isDark ? null : nextPreset.id,
      ),
    );
  }

  /// Clears any active transient clipboard or `OSC 52` security notice.
  void dismissClipboardNotice() {
    _clipboardNoticeTimer?.cancel();
    _clipboardNoticeTimer = null;
    if (_clipboardNotice == null) return;
    _clipboardNotice = null;
    _notifyVisualListeners();
  }

  /// Displays a transient clipboard, security, or status notice in the workspace.
  void showTransientNotice(String message) => _showClipboardNotice(message);

  void _showClipboardNotice(String message) {
    _clipboardNoticeTimer?.cancel();
    _clipboardNotice = message;
    _notifyVisualListeners();
    _clipboardNoticeTimer = clipboardNoticeDuration > .zero
        ? Timer(clipboardNoticeDuration, dismissClipboardNotice)
        : null;
  }

  void _onUploadError(String reason) => _showClipboardNotice(
    ' ! Upload failed: ${_sanitizeNotice(reason, 64, 'Upload rejected')} ',
  );

  static String _sanitizeNotice(String raw, int maxChars, String fallback) =>
      WorkspaceBufferCompositor.sanitizeNotice(raw, maxChars, fallback);

  /// Uploads [files] sequentially to the active subscribed session.
  Future<bool> uploadDroppedFiles(List<DroppedFileSource> files) async {
    final slot = _activeSlot;
    if (_disposed || slot == null || slot.state == .unsubscribed) {
      _showClipboardNotice(' ! Cannot upload: no active subscribed session ');
      return false;
    }
    scrollActiveToBottom();
    return _uploadCoordinator.uploadFiles(slot.id, files);
  }

  /// Cancels any active file upload batch and notifies the caster.
  void cancelActiveFileUpload() => _uploadCoordinator.cancel();

  /// Clears the current client-side terminal selection, if any.
  void clearSelection() => _resolvedPointer.clearSelection();

  /// Matches an `http://` or `https://` URL at 0-based viewport cell `(col, row)`.
  MatchedTerminalUrl? matchUrlAtCell(int col, int row) =>
      WorkspaceBufferCompositor.matchUrlAtCell(_activeSlot, col, row);

  /// Extracts an `http://` or `https://` [Uri] at 0-based viewport cell `(col, row)`.
  Uri? extractUrlAtCell(int col, int row) => matchUrlAtCell(col, row)?.url;

  /// Updates the active keyboard [modifiers] for link-hover detection.
  void updateHoverModifiers(Set<ev.Modifier> modifiers) =>
      _resolvedPointer.updateHoverModifiers(modifiers);

  /// Clears the last recorded pointer cell when the cursor exits the terminal viewport.
  void clearMouseHover() => _resolvedPointer.clearMouseHover();

  /// Extracts text from [activeSelection] and writes it to the host clipboard.
  bool copySelectionToClipboard() {
    final selection = activeSelection;
    final slot = _activeSlot;
    if (selection == null || selection.isCollapsed || slot == null) {
      return false;
    }
    final text = WorkspaceBufferCompositor.extractSelectionText(
      slot,
      selection,
    );
    if (text.isEmpty) return false;
    _writeToClipboard(text);
    return true;
  }

  void _writeToClipboard(String text) {
    _lastCopiedText = text;
    onClipboardWrite?.call(text);
  }

  void _copyFileLinkToClipboard(String localPath) {
    _writeToClipboard(localPath);
    final label = _sanitizeNotice(localPath, 52, localPath);
    _showClipboardNotice(' Copied path: $label ');
  }

  /// Connects or reconnects [repository] to [endpoint] and resets workspace error state.
  Future<void> reconnectTo(
    CastEndpoint endpoint, {
    bool retryOnFailure = true,
  }) async {
    if (_disposed) return;
    if (endpoint.serverUri != repository.serverUri) {
      _clearWorkspaceSessions();
    } else {
      _markWorkspaceDisconnected();
    }
    _authErrorMessage = null;
    _connectionState = .connecting;
    _notifyVisualListeners();
    await repository.reconnect(endpoint, retryOnFailure: retryOnFailure);
  }

  /// Switches the active tab to [sessionId], subscribing or resizing when live.
  Future<void> selectSession(SessionId sessionId) async {
    if (_disposed) return;
    final slot = _ensureSlot(sessionId)..cancelInactiveTimer();
    final prevId = _activeSessionId;
    final switchedTab = prevId != null && prevId != sessionId;
    if (switchedTab) {
      _pendingFocusInSessionId = null;
      if (_workspaceVisible) {
        _sendFocusEventIfEnabled(_slots[prevId], focused: false);
      }
      _resolvedPointer.resetSelection();
      _scheduleInactiveSuspend(prevId);
    }
    _activeSessionId = sessionId;
    _resizeDebounceTimer?.cancel();
    _resizeDebounceTimer = null;

    if ((!_tabStrip.contains(sessionId) || _tabStrip.isLive(sessionId)) &&
        _connectionState == .authenticated &&
        !_suspendedWhileHidden) {
      if (!await _subscribeOrResizeActiveSlot(slot)) return;
      if (switchedTab && _workspaceVisible) {
        _requestOrSendFocusIn(slot);
      }
    } else {
      slot.clampHorizontalPan(_viewportCols, _viewportRows);
    }
    _notifyVisualListeners();
  }

  void _requestOrSendFocusIn(SessionSlot slot) {
    if (slot.state == .synchronized) {
      _pendingFocusInSessionId = null;
      _sendFocusEventIfEnabled(slot, focused: true);
    } else if (!_tabStrip.contains(slot.id) || _tabStrip.isLive(slot.id)) {
      _pendingFocusInSessionId = slot.id;
    }
  }

  void _sendFocusEventIfEnabled(SessionSlot? slot, {required bool focused}) {
    if (_disposed || _connectionState != .authenticated || slot == null) return;
    if (!_tabStrip.isLive(slot.id) ||
        slot.state != .synchronized ||
        !slot.modes.focusReporting) {
      return;
    }
    repository.sendInput(
      slot.id,
      utf8.encode(InputEncoder.encodeFocus(focused: focused)),
    );
  }

  Future<bool> _subscribeOrResizeActiveSlot(SessionSlot slot) async {
    final sessionId = slot.id;
    if (slot.state == .unsubscribed) {
      await slot.machine.handle(.subscribe);
      if (_disposed || !identical(_slots[sessionId], slot)) return false;
      if (_activeSessionId != sessionId ||
          _connectionState != .authenticated ||
          _suspendedWhileHidden) {
        await slot.machine.handle(.unsubscribe);
        return false;
      }
      repository.subscribe(sessionId, cols: _viewportCols, rows: _viewportRows);
    } else if (slot.currentCols != _viewportCols ||
        slot.currentRows != _viewportRows) {
      repository.sendResize(sessionId, _viewportCols, _viewportRows);
    }
    return true;
  }

  /// Selects the next or previous session in [sessions] by [delta] (`+1` or `-1`).
  Future<void> cycleSession(int delta) async {
    final nextId = _tabStrip.cycleSessionId(_activeSessionId, delta);
    if (nextId != null) await selectSession(nextId);
  }

  /// Updates whether the viewer workspace is visible, suspending background
  /// subscriptions after [inactiveSessionGrace] when hidden and resuming the
  /// active session immediately when visible again.
  void setWorkspaceVisible(bool visible) {
    if (_disposed || _workspaceVisible == visible) return;
    _workspaceVisible = visible;
    _workspaceSuspendTimer?.cancel();
    _workspaceSuspendTimer = null;
    if (visible) {
      final wasSuspended = _suspendedWhileHidden;
      _suspendedWhileHidden = false;
      final activeId = _activeSessionId;
      if (wasSuspended) {
        if (activeId != null &&
            (!_tabStrip.contains(activeId) || _tabStrip.isLive(activeId))) {
          _pendingFocusInSessionId = activeId;
        }
        _activateAfterDirectoryUpdate();
      } else if (_activeSlot case final slot?) {
        _requestOrSendFocusIn(slot);
      }
      return;
    }
    _pendingFocusInSessionId = null;
    _sendFocusEventIfEnabled(_activeSlot, focused: false);
    if (inactiveSessionGrace <= .zero) return;
    _workspaceSuspendTimer = Timer(
      inactiveSessionGrace,
      () => unawaited(_onWorkspaceSuspendTimerFired()),
    );
  }

  void _scheduleInactiveSuspend(SessionId id) {
    final slot = _slots[id];
    if (_disposed || slot == null) return;
    slot.scheduleInactiveSuspend(
      inactiveSessionGrace,
      () => unawaited(_onInactiveSlotTimerFired(id)),
    );
  }

  Future<void> _onInactiveSlotTimerFired(SessionId id) async {
    if (_disposed || id == _activeSessionId) return;
    final slot = _slots[id];
    if (slot == null || slot.state == .unsubscribed) return;
    if (_uploadCoordinator.activeSessionId == id) {
      _scheduleInactiveSuspend(id);
      return;
    }
    await _suspendSlot(slot);
  }

  Future<void> _onWorkspaceSuspendTimerFired() async {
    _workspaceSuspendTimer = null;
    if (_disposed || _workspaceVisible) return;
    _suspendedWhileHidden = true;
    var deferredForUpload = false;
    for (final slot in [..._slots.values]) {
      if (slot.state == .unsubscribed) continue;
      if (_uploadCoordinator.activeSessionId == slot.id) {
        deferredForUpload = true;
        continue;
      }
      await _suspendSlot(slot);
    }
    if (deferredForUpload && !_disposed && !_workspaceVisible) {
      _workspaceSuspendTimer = Timer(
        inactiveSessionGrace,
        () => unawaited(_onWorkspaceSuspendTimerFired()),
      );
    }
  }

  Future<void> _suspendSlot(SessionSlot slot) async {
    if (slot.state == .unsubscribed) return;
    await slot.machine.handle(.unsubscribe);
    if (_disposed || !identical(_slots[slot.id], slot)) return;
    if (_connectionState == .authenticated) repository.unsubscribe(slot.id);
    _notifyVisualListeners();
  }

  /// Updates the PTY viewport dimensions and schedules a debounced `ResizeFrame`.
  void resizeActiveViewport(int cols, int rows) {
    final safeCols = cols.clamp(1, BufferFrameCodec.maxGridCols);
    final safeRows = rows.clamp(1, BufferFrameCodec.maxGridRows);
    if (safeCols == _viewportCols && safeRows == _viewportRows) return;
    _viewportCols = safeCols;
    _viewportRows = safeRows;
    _resolvedPointer.resetSelection();
    _activeSlot?.clampHorizontalPan(_viewportCols, _viewportRows);
    _notifyVisualListeners();

    _resizeDebounceTimer?.cancel();
    _resizeDebounceTimer = null;
    if (resizeDebounce <= Duration.zero) {
      _flushDebouncedResize();
      return;
    }
    _resizeDebounceTimer = Timer(resizeDebounce, _flushDebouncedResize);
  }

  void _flushDebouncedResize() {
    _resizeDebounceTimer = null;
    if (_disposed) return;
    final slot = _activeSlot;
    if (slot == null || slot.state == .unsubscribed) return;
    if (slot.currentCols == _viewportCols &&
        slot.currentRows == _viewportRows) {
      return;
    }
    repository.sendResize(slot.id, _viewportCols, _viewportRows);
  }

  /// Whether the active session can currently scroll its primary scrollback buffer.
  bool canScrollActiveSession() => SessionSlot.canLocalScroll(_activeSlot);

  /// Scrolls the active session's primary viewport by [deltaLines].
  bool scrollActiveBy(int deltaLines) {
    final slot = _activeSlot;
    final scrolled =
        slot?.scrollBy(
          deltaLines,
          viewportCols: _viewportCols,
          viewportRows: _viewportRows,
        ) ??
        false;
    if (scrolled) _notifyVisualListeners();
    return scrolled;
  }

  /// Jumps the active session's viewport to the oldest available scrollback line.
  bool scrollActiveToTop() =>
      _activeSlot != null && scrollActiveBy(_activeSlot!.maxScrollableLines);

  /// Snaps the active session's viewport back to the live bottom (`lines = 0, cols = 0`).
  bool scrollActiveToBottom() {
    final scrolled = _activeSlot?.scrollToBottom() ?? false;
    if (scrolled) _notifyVisualListeners();
    return scrolled;
  }

  /// Pans the active scrolled-up primary viewport horizontally by [deltaCols].
  bool panActiveHorizontalBy(int deltaCols) {
    final panned =
        _activeSlot?.panHorizontalBy(
          deltaCols,
          viewportCols: _viewportCols,
          viewportRows: _viewportRows,
        ) ??
        false;
    if (panned) _notifyVisualListeners();
    return panned;
  }

  /// Returns a copied [Buffer] for rendering with scrollback rows, selection
  /// highlights, a `Modifier.reverse` cursor cell, scrollbar thumb, and notice.
  Buffer composeActiveBufferWithCursor() => WorkspaceBufferCompositor.compose(
    slot: _activeSlot,
    viewportCols: _viewportCols,
    viewportRows: _viewportRows,
    hoveredLink: _resolvedPointer.hoveredLink,
    activeSelection: _resolvedPointer.activeSelection,
    theme: activeTerminalTheme,
    themeSettings: _themeSettings,
    colorResolver: colorResolver,
    nowMs: _resolvedClock.now().millisecondsSinceEpoch,
    hiddenClipboardNotice: (_dockPosition == .hidden && !hasAttentionBanner)
        ? _clipboardNotice
        : null,
  );

  /// Encodes [event] and sends `InputFrame`, snapping any active scrollback
  /// viewport back to the live bottom on non-release key transitions.
  bool encodeAndSendKey(ev.KeyEvent event) {
    final slot = _activeSlot;
    if (slot == null || slot.state == .unsubscribed) return false;
    if (event.eventType == ev.KeyEventType.release &&
        (slot.modes.kittyKeyboardFlags & 0x02) == 0) {
      return false;
    }
    final encoded = InputEncoder.encode(
      event,
      applicationCursorKeys: slot.modes.appCursorKeys,
      kittyKeyboardFlags: slot.modes.kittyKeyboardFlags,
    );
    if (encoded.isEmpty) return false;
    if (event.eventType != ev.KeyEventType.release) {
      clearSelection();
      scrollActiveToBottom();
    }
    return sendRawInputBytes(utf8.encode(encoded));
  }

  /// Encodes [event] (wrapping in `DECSET 2004` brackets when active) and sends
  /// `InputFrame` chunks of at most `64 KiB` when within [maxPasteBytes].
  bool encodeAndSendPaste(ev.PasteEvent event) {
    final slot = _activeSlot;
    final (:bytes, :exceedsLimit) = _resolvedPointer.encodePastePayload(
      event,
      maxPasteBytes: maxPasteBytes,
    );
    if (exceedsLimit) {
      _showClipboardNotice(' ! Paste exceeds 1 MiB limit ');
      return false;
    }
    if (slot == null || bytes == null) return false;
    clearSelection();
    scrollActiveToBottom();
    _resolvedPointer.sendChunkedInput(slot.id, bytes);
    return true;
  }

  /// Sends raw [bytes] directly as an `InputFrame` to the active subscribed session.
  bool sendRawInputBytes(List<int> bytes) {
    final slot = _activeSlot;
    if (slot == null || slot.state == .unsubscribed || bytes.isEmpty) {
      return false;
    }
    _sendSlotInput(slot.id, bytes);
    return true;
  }

  /// Routes [event] to hidden-banner dismissal, `Ctrl+Click` / `Cmd+Click`
  /// URL opening, local scrollback, local text selection, or mouse forwarding.
  bool handlePtyMouseEvent(ev.MouseEvent event) =>
      _resolvedPointer.handlePtyMouseEvent(event);

  /// Encodes [event] as SGR or X10 mouse bytes when `mouseTracking` is active,
  /// or as cursor up/down keys on alternate screen when `alternateScroll` (`?1007h`)
  /// is enabled.
  bool encodeAndSendMouse(ev.MouseEvent event) =>
      _resolvedPointer.encodeAndSendMouse(event);

  void _onClientConnecting(Uri _) {
    if (_disposed) return;
    if (_connectionState != .reconnecting) _connectionState = .connecting;
    _authErrorMessage = null;
    _notifyVisualListeners();
  }

  void _onClientConnectFailed(bool _) {
    if (_disposed || _connectionState == .authFailed) return;
    _connectionState = repository.willAutoReconnect
        ? .reconnecting
        : .unconnected;
    _notifyVisualListeners();
  }

  void _onClientDisconnected(bool _) {
    if (_disposed) return;
    _markWorkspaceDisconnected();
    if (_connectionState != .authFailed) {
      _connectionState = repository.willAutoReconnect
          ? .reconnecting
          : .unconnected;
    }
    _notifyVisualListeners();
  }

  void _markWorkspaceDisconnected() {
    _pendingFocusInSessionId = null;
    _resizeDebounceTimer?.cancel();
    _resizeDebounceTimer = null;
    _uploadCoordinator.abortOnDisconnect();
    for (final slot in _slots.values) {
      slot.handleSessionEnded(exited: false, exitCode: -1);
    }
    _disposeSlots(
      _tabStrip.markAllLiveDisconnected(
        now: _resolvedClock.now(),
        activeSessionId: _activeSessionId,
      ),
    );
    _syncCountdownTimer();
  }

  void _onCorruptSessionFrame(SessionId sessionId) {
    if (_disposed || _connectionState != .authenticated) return;
    final slot = _slots[sessionId];
    if (slot == null || slot.state == .unsubscribed) return;
    unawaited(slot.machine.handle(.corruptFrame));
  }

  void _onServerMessage(CastMessage message) {
    if (_disposed) return;
    _resolvedTelemetry.recordInbound(
      _resolvedClock.now(),
      message,
      repository.totalRxBytes,
    );
    switch (message) {
      case AuthAcceptedFrame():
        _connectionState = .authenticated;
        _authErrorMessage = null;
        _activateAfterDirectoryUpdate();
      case SessionDirectoryFrame(:final sessions):
        _connectionState = .authenticated;
        _authErrorMessage = null;
        _applyDirectory(sessions);
      case BufferSnapshotFrame(:final snapshot):
        if (_slots[snapshot.sessionId] case final slot?) {
          unawaited(_handleBufferSnapshot(slot, snapshot));
        }
      case BufferDeltaFrame(:final delta):
        if (_slots[delta.sessionId] case final slot?) {
          unawaited(slot.machine.handle(.delta, delta));
        }
      case final ScrollbackChunkFrame chunk:
        _slots[chunk.sessionId]?.ingestScrollbackChunk(chunk);
      case final ClipboardFrame frame:
        _handleClipboardFrame(frame);
      case final FileUploadAckFrame ack:
        _uploadCoordinator.handleAckFrame(ack);
      case final SessionClosedFrame frame:
        _handleSessionClosedFrame(frame);
      case ErrorFrame(:final code, :final message):
        if (CastClientRepository.isFatalAuthErrorCode(code)) {
          _handleAuthFailure(message);
        } else if (code == 'rename_rejected') {
          final detail = _sanitizeNotice(message, 48, 'server rejected rename');
          _showClipboardNotice(' ! Rename rejected: $detail ');
        } else if (code == 'caster_busy' && _clipboardNotice == null) {
          _showClipboardNotice(' ! Caster input queue busy; input dropped ');
        }
      default:
        break;
    }
  }

  Future<void> _handleBufferSnapshot(
    SessionSlot slot,
    BufferSnapshot snapshot,
  ) async {
    await slot.machine.handle(.snapshot, snapshot);
    if (_disposed || _pendingFocusInSessionId != slot.id) return;
    _pendingFocusInSessionId = null;
    if (slot.id == _activeSessionId && _workspaceVisible) {
      _sendFocusEventIfEnabled(slot, focused: true);
    }
  }

  void _handleSessionClosedFrame(SessionClosedFrame frame) {
    final sessionId = frame.sessionId;
    if (_uploadCoordinator.activeSessionId == sessionId) {
      _uploadCoordinator.abortOnDisconnect(
        'Upload interrupted: session closed.',
      );
    }
    _slots[sessionId]?.handleSessionEnded(
      exited: frame.reason == .exited,
      exitCode: frame.exitCode,
    );
    _disposeSlots(
      _tabStrip.markEnded(
        sessionId,
        reason: frame.reason,
        exitCode: frame.exitCode,
        now: _resolvedClock.now(),
        activeSessionId: _activeSessionId,
      ),
    );
    _clearActiveSelectionForSlot(sessionId);
    _syncCountdownTimer();
    _notifyVisualListeners();
  }

  void _handleClipboardFrame(ClipboardFrame frame) {
    final slot = _slots[frame.sessionId];
    if (slot == null || slot.state == .unsubscribed) return;
    if (frame.readBlocked) {
      if (frame.sessionId == _activeSessionId) {
        _showClipboardNotice(
          ' ! Blocked remote clipboard read attempt (OSC 52) ',
        );
      } else {
        final raw = slot.title.isNotEmpty ? slot.title : frame.sessionId.value;
        final label = _sanitizeNotice(raw, 48, frame.sessionId.value);
        _showClipboardNotice(' ! Blocked clipboard read ($label) ');
      }
      return;
    }
    if (frame.sessionId == _activeSessionId && frame.text.isNotEmpty) {
      _writeToClipboard(frame.text);
    }
  }

  void _handleAuthFailure(String rawMessage) {
    _clearWorkspaceSessions();
    _connectionState = .authFailed;
    _authErrorMessage = _sanitizeNotice(rawMessage, 64, 'Invalid bearer token');
    _notifyVisualListeners();
  }

  void _clearWorkspaceSessions() {
    _uploadCoordinator.abortOnDisconnect('Upload interrupted: session reset.');
    _resizeDebounceTimer?.cancel();
    _resizeDebounceTimer = null;
    _cancelCountdownTimer();
    _resolvedPointer.resetAll();
    for (final slot in _slots.values) {
      slot.dispose();
    }
    _slots.clear();
    _tabStrip.clear();
    _activeSessionId = null;
    _pendingFocusInSessionId = null;
  }

  void _applyDirectory(List<SessionSummary> incoming) {
    final now = _resolvedClock.now();
    final incomingIds = <SessionId>{for (final entry in incoming) entry.id};
    for (final entry in incoming) {
      _ensureSlot(entry.id).applyDirectorySummary(entry);
    }
    for (final entry in _slots.entries) {
      if (!incomingIds.contains(entry.key) && _tabStrip.isLive(entry.key)) {
        entry.value.handleSessionEnded(exited: false, exitCode: -1);
        _clearActiveSelectionForSlot(entry.key);
      }
    }
    _disposeSlots(
      _tabStrip.reconcileDirectory(
        incoming,
        now: now,
        activeSessionId: _activeSessionId,
      ),
    );
    _syncCountdownTimer();
    _activateAfterDirectoryUpdate();
  }

  void _activateAfterDirectoryUpdate() {
    if (_suspendedWhileHidden) {
      _notifyVisualListeners();
      return;
    }
    final activeId = _activeSessionId;
    if (activeId != null && (_tabStrip.isEmpty || _tabStrip.isLive(activeId))) {
      if (_slots[activeId]?.state == .unsubscribed) {
        unawaited(selectSession(activeId));
        return;
      }
    } else if ((activeId == null || !_tabStrip.contains(activeId)) &&
        !_tabStrip.isEmpty) {
      unawaited(selectSession(_tabStrip.sessions.first.id));
      return;
    }
    _notifyVisualListeners();
  }

  void _disposeSlots(List<SessionId> ids) {
    for (final id in ids) {
      _clearActiveSelectionForSlot(id);
      _slots.remove(id)?.dispose();
    }
  }

  void _syncCountdownTimer() {
    if (_disposed || !_tabStrip.hasActiveCountdown(_resolvedClock.now())) {
      _cancelCountdownTimer();
      return;
    }
    _countdownTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => _onCountdownTick(),
    );
  }

  void _onCountdownTick() {
    if (_disposed) {
      _cancelCountdownTimer();
      return;
    }
    final now = _resolvedClock.now();
    _disposeSlots(
      _tabStrip.pruneOverflowAt(now, activeSessionId: _activeSessionId),
    );
    if (!_tabStrip.hasActiveCountdown(now)) _cancelCountdownTimer();
    _notifyVisualListeners();
  }

  void _cancelCountdownTimer() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
  }

  SessionSlot _ensureSlot(SessionId id) => _slots.putIfAbsent(
    id,
    () => SessionSlot(
      id: id,
      clock: _resolvedClock,
      requestTimeout: scrollbackRequestTimeout,
      onVisualChange: () {
        if (id == _activeSessionId) _notifyVisualListeners();
      },
      onClearSelection: () => _clearActiveSelectionForSlot(id),
      onRequestKeyframe: () => repository.requestKeyframe(id),
      onRequestScrollback: repository.requestScrollback,
    ),
  );

  void _clearActiveSelectionForSlot(SessionId sessionId) {
    if (sessionId != _activeSessionId) return;
    _resolvedPointer.resetSelection();
  }

  /// Disposes per-session state machines, timers, and bus listeners.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _uploadCoordinator.cancel();
    _workspaceSuspendTimer?.cancel();
    _workspaceSuspendTimer = null;
    _cancelCountdownTimer();
    _resolvedPointer.resetAll();
    _resizeDebounceTimer?.cancel();
    _resizeDebounceTimer = null;
    _clipboardNoticeTimer?.cancel();
    _clipboardNoticeTimer = null;
    clientConnectingEvent.removeListener(repository.bus, _onClientConnecting);
    clientConnectFailedEvent.removeListener(
      repository.bus,
      _onClientConnectFailed,
    );
    clientMessageReceivedEvent.removeListener(repository.bus, _onServerMessage);
    clientCorruptSessionFrameEvent.removeListener(
      repository.bus,
      _onCorruptSessionFrame,
    );
    clientDisconnectedEvent.removeListener(
      repository.bus,
      _onClientDisconnected,
    );
    for (final slot in _slots.values) {
      slot.dispose();
    }
    _slots.clear();
    _visualListeners.clear();
  }
}
