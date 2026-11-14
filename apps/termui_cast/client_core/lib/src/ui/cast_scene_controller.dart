import 'dart:async';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:termui/terminal/event.dart' as ev;
import 'package:termui/termui.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';

import '../cast_workspace_view_model.dart';
import '../models.dart';
import 'chords_help_dialog.dart';
import 'connection_prompt_dialog.dart';
import 'dock_tab_layout.dart';
import 'file_upload_dialog.dart';
import 'palette_editor_dialog.dart';
import 'remote_pty_scene_renderer.dart';
import 'rename_tab_dialog.dart';
import 'session_dock_bar.dart';
import 'settings_dialog.dart';
import 'stats_for_nerds_dialog.dart';

typedef _SceneLayout = ({
  int ptyX,
  int ptyY,
  int ptyW,
  int ptyH,
  bool showChrome,
  int chromeX,
  int chromeY,
  int chromeW,
  int chromeH,
});

/// Pure-Dart controller wiring [SceneManager] layers, resize hooks,
/// connection prompt modal orchestration, and `Ctrl+\` leader chords.
final class CastSceneController implements Reassemblable {
  /// Host terminal attached to [sceneManager].
  final Terminal terminal;

  /// Backing multi-session workspace view model.
  final CastWorkspaceViewModel viewModel;

  /// Compositing scene manager driving [ptyLayer] and [chromeLayer].
  late final SceneManager sceneManager;

  /// Direct PTY buffer renderer (`zIndex: 0`).
  late final RemotePtySceneRenderer ptyRenderer;

  /// Clickable session dock renderer (`zIndex: 10`).
  late final SessionDockBar dockRenderer;

  /// Scene layer displaying the active remote PTY buffer.
  late final SceneLayer ptyLayer;

  /// Scene layer displaying the tab bar, left sidebar, or attention banner.
  late final SceneLayer chromeLayer;

  final _DragGhostRenderer _dragGhostRenderer = _DragGhostRenderer();
  late final SceneLayer _dragGhostLayer;
  late final void Function() _removeVisualListener;
  final Set<(ev.KeyType, String)> _suppressedShortcutReleases = {};
  DockPosition _appliedDockPosition;
  bool _appliedForceBanner;
  bool _leaderArmed = false;
  bool _promptOpen = false;
  bool _helpOpen = false;
  bool _statsOpen = false;
  bool _settingsOpen = false;
  bool _paletteOpen = false;
  bool _renameOpen = false;
  bool _uploadDialogOpen = false;
  bool _pointerCursorActive = false;
  bool _disposed = false;

  /// Computes the `(cols, rows)` PTY viewport dimensions inside [terminalSize]
  /// for the given [dock] placement.
  static Point<int> computePtyViewportSize(
    Point<int> terminalSize,
    DockPosition dock, {
    bool forceTopBanner = false,
  }) {
    final layout = _computeLayout(
      terminalSize,
      dock,
      forceTopBanner: forceTopBanner,
    );
    return Point<int>(layout.ptyW, layout.ptyH);
  }

  /// Creates and attaches a [SceneManager] multi-PTY controller.
  CastSceneController({
    required this.terminal,
    required this.viewModel,
    Clock? clock,
    void Function(Buffer buffer)? onFrameRedrawn,
  }) : _appliedDockPosition = viewModel.dockPosition,
       _appliedForceBanner = viewModel.hasAttentionBanner {
    ptyRenderer = RemotePtySceneRenderer(
      viewModel: viewModel,
      shouldSuppressKeyRelease: _shouldSuppressPtyKeyRelease,
      onPtyKeyPress: _clearSuppressedKeyOnPress,
    );
    dockRenderer = SessionDockBar(
      viewModel: viewModel,
      clock: clock,
      onRequestConnectionPrompt: _handleRequestConnectionPrompt,
      onRequestChordsHelp: _handleRequestChordsHelp,
      onRequestStats: _handleRequestStats,
      onRequestSettings: _handleRequestSettings,
      onRequestRenameSession: _handleRequestRenameSession,
      onReleasePointerFocus: _restorePtyFocus,
      onKeyEvent: _handleDockKeyEvent,
    );
    sceneManager = SceneManager(terminal, renderingMode: .alternateScreen)
      ..enableMouseTracking = true
      ..enableDebugToggleKey = false
      ..onFrameRedrawn = onFrameRedrawn
      ..onKeyEvent = _handleGlobalKeyEvent
      ..onPasteEvent = _handleGlobalPasteEvent;
    _setDebugOverlayFlags(viewModel.debugOverlayEnabled);
    viewModel.onClipboardWrite = terminal.setClipboard;

    final initial = _computeLayout(
      terminal.backend.size,
      viewModel.dockPosition,
      forceTopBanner: viewModel.hasAttentionBanner,
    );
    ptyRenderer.resize(initial.ptyW, initial.ptyH);
    dockRenderer.resize(initial.chromeW, initial.chromeH);
    ptyLayer = SceneLayer(
      renderer: ptyRenderer,
      sizing: .fixed,
      x: initial.ptyX,
      y: initial.ptyY,
      width: initial.ptyW,
      height: initial.ptyH,
      zIndex: 0,
      mouseOpaque: true,
      onResize: _onTerminalResize,
    );
    chromeLayer = SceneLayer(
      renderer: dockRenderer,
      sizing: .fixed,
      x: initial.chromeX,
      y: initial.chromeY,
      width: initial.chromeW,
      height: initial.chromeH,
      zIndex: 10,
      hitTestable: initial.showChrome,
      mouseOpaque: true,
    );
    _dragGhostLayer = SceneLayer(
      renderer: _dragGhostRenderer,
      sizing: .fixed,
      x: 0,
      y: 0,
      width: 1,
      height: 1,
      zIndex: 900,
      hitTestable: false,
      mouseOpaque: false,
    );
    DragDropManager.onDragSessionChanged = _handleDragSessionChanged;

    sceneManager.layers.add(ptyLayer);
    if (initial.showChrome) {
      sceneManager.layers.add(chromeLayer);
    }
    sceneManager.focusedLayer = ptyLayer;
    _removeVisualListener = viewModel.addVisualListener(_onViewModelChanged);
    TermuiBinding.register(this);
    sceneManager.render();
  }

  /// Whether a [ConnectionPromptDialog] modal is currently mounted on [sceneManager].
  bool get isConnectionPromptOpen => _promptOpen;

  /// Whether a [ChordsHelpDialog] modal is currently mounted on [sceneManager].
  bool get isChordsHelpOpen => _helpOpen;

  /// Whether a [StatsForNerdsDialog] modal is currently mounted on [sceneManager].
  bool get isStatsDialogOpen => _statsOpen;

  /// Whether a [SettingsDialog] modal is currently mounted on [sceneManager].
  bool get isSettingsDialogOpen => _settingsOpen;

  /// Whether a [PaletteEditorDialog] modal is currently mounted on [sceneManager].
  bool get isPaletteEditorOpen => _paletteOpen;

  /// Whether a [RenameTabDialog] modal is currently mounted on [sceneManager].
  bool get isRenameDialogOpen => _renameOpen;

  /// Whether a [FileUploadDialog] modal is currently mounted on [sceneManager].
  bool get isFileUploadDialogOpen => _uploadDialogOpen;

  /// Whether the active remote PTY currently requests Kitty key-release events (`0x02`).
  bool get wantsKeyReleaseEvents =>
      !_disposed && !_anyModalOpen && ptyRenderer.wantsKeyReleaseEvents;

  /// Whether the active remote PTY or open [PaletteEditorDialog] currently
  /// requests `?1016h` SGR-Pixels mouse events.
  bool get wantsPixelMouseEvents =>
      !_disposed &&
      (_paletteOpen || (!_anyModalOpen && ptyRenderer.wantsPixelMouseEvents));

  /// Current viewer cell dimensions in logical pixels.
  (double width, double height) get cellPixelSize => ptyRenderer.cellPixelSize;

  /// Updates the viewer cell dimensions in logical pixels for `?1016h` mouse normalization.
  void setCellPixelSize(double width, double height) =>
      ptyRenderer.setCellPixelSize(width, height);

  bool get _anyModalOpen =>
      _promptOpen ||
      _helpOpen ||
      _statsOpen ||
      _settingsOpen ||
      _paletteOpen ||
      _renameOpen ||
      _uploadDialogOpen;

  void _bindCallbacks() {
    ptyRenderer
      ..shouldSuppressKeyRelease = _shouldSuppressPtyKeyRelease
      ..onPtyKeyPress = _clearSuppressedKeyOnPress;
    dockRenderer
      ..onRequestConnectionPrompt = _handleRequestConnectionPrompt
      ..onRequestChordsHelp = _handleRequestChordsHelp
      ..onRequestStats = _handleRequestStats
      ..onRequestSettings = _handleRequestSettings
      ..onRequestRenameSession = _handleRequestRenameSession
      ..onReleasePointerFocus = _restorePtyFocus
      ..onKeyEvent = _handleDockKeyEvent;
    sceneManager
      ..onKeyEvent = _handleGlobalKeyEvent
      ..onPasteEvent = _handleGlobalPasteEvent;
    _setDebugOverlayFlags(viewModel.debugOverlayEnabled);
    DragDropManager.onDragSessionChanged = _handleDragSessionChanged;
    viewModel.onClipboardWrite ??= terminal.setClipboard;
  }

  void _handleDragSessionChanged(DragSession? session) {
    if (_disposed) return;
    if (session == null ||
        !dockRenderer.ownsDragSession(session) ||
        session.data is! DockTabDragData) {
      _dragGhostRenderer.clear();
      if (sceneManager.layers.contains(_dragGhostLayer)) {
        sceneManager.layers.remove(_dragGhostLayer);
      }
      sceneManager.scheduleRender();
      return;
    }

    final data = session.data as DockTabDragData;
    final rawSize = terminal.backend.size;
    final termW = max(1, rawSize.x);
    final termH = max(1, rawSize.y);
    final pillW = max(1, min(data.widthCols, termW));
    final (clippedText, _) = DockTabLayout.clipWithWidth(data.label, pillW);
    final mousePos = data.globalMousePosition;
    final int targetX = (mousePos.x - 1 - data.grabOffsetCols).clamp(
      0,
      max(0, termW - pillW),
    );
    final int targetY = (mousePos.y - 1).clamp(0, max(0, termH - 1));

    _dragGhostRenderer.updatePill(
      text: clippedText,
      widthCols: pillW,
      style: data.style,
    );
    _dragGhostLayer
      ..x = targetX
      ..y = targetY
      ..width = pillW
      ..height = 1;
    if (!sceneManager.layers.contains(_dragGhostLayer)) {
      sceneManager.layers.add(_dragGhostLayer);
    }
    sceneManager.scheduleRender();
  }

  void _abortActiveTabDrag() {
    if (dockRenderer.cancelActiveDrag()) {
      _restorePtyFocus();
    }
  }

  void _handleRequestConnectionPrompt() {
    if (!_disposed) {
      unawaited(openConnectionPrompt());
    }
  }

  void _handleRequestChordsHelp() {
    if (!_disposed) {
      unawaited(openChordsHelp());
    }
  }

  void _handleRequestStats() {
    if (!_disposed) {
      unawaited(openStatsForNerds());
    }
  }

  void _handleRequestSettings() {
    if (!_disposed) {
      unawaited(openSettings());
    }
  }

  void _handleRequestRenameSession(SessionId sessionId) {
    if (!_disposed) {
      unawaited(openRenameTabDialog(sessionId));
    }
  }

  @override
  void reassemble() {
    if (_disposed) return;
    _bindCallbacks();
    _applyLayout(terminal.backend.size, syncLayerMembership: true);
    dockRenderer.render();
    sceneManager.scheduleRender();
  }

  /// Opens the interactive [ConnectionPromptDialog] modal over the workspace.
  ///
  /// When submitted, reconnects [viewModel] to the chosen [CastEndpoint].
  /// When dismissed via `Escape` or clicking the backdrop barrier, leaves the
  /// workspace and status banner active so the user can return via `Enter`,
  /// `Ctrl+\ c`, or clicking the banner.
  Future<CastEndpoint?> openConnectionPrompt() async {
    if (_disposed || _anyModalOpen) return null;
    _abortActiveTabDrag();
    _leaderArmed = false;
    _promptOpen = true;
    _syncMousePointer();
    try {
      final authError = viewModel.authErrorMessage;
      final endpoint = await ConnectionPromptDialog.show(
        sceneManager,
        initialServerUrl: '${viewModel.serverUri}',
        initialToken: viewModel.currentToken,
        initialError: authError == null ? null : 'Auth failed: $authError',
        terminalTheme: viewModel.activeTerminalTheme,
      );
      if (_disposed) return null;
      if (endpoint != null) {
        unawaited(viewModel.reconnectTo(endpoint));
      }
      return endpoint;
    } finally {
      _promptOpen = false;
      _restorePtyFocusAfterModal();
    }
  }

  /// Opens the interactive [ChordsHelpDialog] modal over the workspace.
  Future<void> openChordsHelp() async {
    if (_disposed || _anyModalOpen) return;
    _abortActiveTabDrag();
    _leaderArmed = false;
    _helpOpen = true;
    _syncMousePointer();
    try {
      await ChordsHelpDialog.show(
        sceneManager,
        terminalTheme: viewModel.activeTerminalTheme,
      );
    } finally {
      _helpOpen = false;
      _restorePtyFocusAfterModal();
    }
  }

  /// Opens the interactive [StatsForNerdsDialog] modal over the workspace.
  Future<void> openStatsForNerds() async {
    if (_disposed || _anyModalOpen) return;
    _abortActiveTabDrag();
    _leaderArmed = false;
    _statsOpen = true;
    _syncMousePointer();
    try {
      await StatsForNerdsDialog.show(sceneManager, viewModel: viewModel);
    } finally {
      _statsOpen = false;
      _restorePtyFocusAfterModal();
    }
  }

  /// Opens the interactive [SettingsDialog] modal over the workspace.
  Future<void> openSettings() async {
    if (_disposed || _anyModalOpen) return;
    _abortActiveTabDrag();
    _leaderArmed = false;
    _settingsOpen = true;
    _syncMousePointer();
    var openPaletteOnClose = false;
    try {
      await SettingsDialog.show(
        sceneManager,
        viewModel: viewModel,
        onOpenPaletteEditor: () => openPaletteOnClose = true,
      );
    } finally {
      _settingsOpen = false;
      _restorePtyFocusAfterModal();
    }
    if (openPaletteOnClose && !_disposed) {
      await openPaletteEditor();
    }
  }

  /// Opens the interactive [PaletteEditorDialog] modal over the workspace.
  Future<void> openPaletteEditor() async {
    if (_disposed || _anyModalOpen) return;
    _abortActiveTabDrag();
    _leaderArmed = false;
    _paletteOpen = true;
    _syncMousePointer();
    try {
      await PaletteEditorDialog.show(sceneManager, viewModel: viewModel);
    } finally {
      _paletteOpen = false;
      _restorePtyFocusAfterModal();
    }
  }

  /// Opens [RenameTabDialog] for [sessionId] (or [CastWorkspaceViewModel.activeSessionId])
  /// when the workspace is authenticated and the target tab is live.
  Future<String?> openRenameTabDialog([SessionId? sessionId]) async {
    final targetId = sessionId ?? viewModel.activeSessionId;
    if (_disposed ||
        _anyModalOpen ||
        targetId == null ||
        !viewModel.canRenameSession(targetId)) {
      return null;
    }
    _abortActiveTabDrag();
    _leaderArmed = false;
    _renameOpen = true;
    _syncMousePointer();
    try {
      final submitted = await RenameTabDialog.show(
        sceneManager,
        initialTitle: viewModel.titleOf(targetId) ?? '',
        terminalTheme: viewModel.activeTerminalTheme,
      );
      if (_disposed || submitted == null) return null;
      viewModel.renameSession(targetId, submitted);
      return submitted;
    } finally {
      _renameOpen = false;
      _restorePtyFocusAfterModal();
    }
  }

  /// Opens [FileUploadDialog] to confirm and stream dropped [files] to the host.
  Future<bool?> handleDroppedFiles(List<DroppedFileSource> files) async {
    if (_disposed || _anyModalOpen || files.isEmpty) return null;
    if (viewModel.activeSessionSyncState == .unsubscribed) {
      await viewModel.uploadDroppedFiles(const []);
      return null;
    }
    _abortActiveTabDrag();
    _leaderArmed = false;
    _uploadDialogOpen = true;
    _syncMousePointer();
    try {
      return await FileUploadDialog.show(
        sceneManager,
        viewModel: viewModel,
        droppedFiles: files,
        terminalTheme: viewModel.activeTerminalTheme,
      );
    } finally {
      if (viewModel.isUploadingFiles) {
        viewModel.cancelActiveFileUpload();
      }
      _uploadDialogOpen = false;
      _restorePtyFocusAfterModal();
    }
  }

  void _restorePtyFocusAfterModal() {
    if (!_disposed) {
      _suppressedShortcutReleases.clear();
      if (viewModel.wantsKeyReleaseEvents) {
        _suppressedShortcutReleases
          ..add((ev.KeyType.escape, 'Escape'))
          ..add((ev.KeyType.enter, 'Enter'));
      }
      _syncMousePointer();
      sceneManager.focusedLayer = ptyLayer;
      sceneManager.scheduleRender();
    }
  }

  void _restorePtyFocus() {
    if (sceneManager.focusedLayer == chromeLayer) {
      sceneManager.focusedLayer = ptyLayer;
    }
  }

  void _onTerminalResize(Point<int> newSize) {
    _abortActiveTabDrag();
    final layout = _applyLayout(newSize, syncLayerMembership: false);
    if (sceneManager.layers.contains(chromeLayer) != layout.showChrome) {
      scheduleMicrotask(() {
        if (_disposed) return;
        _syncChromeMembership(
          _computeLayout(
            terminal.backend.size,
            viewModel.dockPosition,
            forceTopBanner: viewModel.hasAttentionBanner,
          ).showChrome,
        );
        sceneManager.scheduleRender();
      });
    }
  }

  void _onViewModelChanged() {
    if (_disposed) return;
    if (!wantsKeyReleaseEvents) {
      _suppressedShortcutReleases.clear();
    }
    _syncMousePointer();
    if (_setDebugOverlayFlags(viewModel.debugOverlayEnabled)) {
      sceneManager.scheduleRender();
    }
    final nextForceBanner = viewModel.hasAttentionBanner;
    if (_appliedDockPosition == viewModel.dockPosition &&
        _appliedForceBanner == nextForceBanner) {
      return;
    }
    _abortActiveTabDrag();
    _appliedDockPosition = viewModel.dockPosition;
    _appliedForceBanner = nextForceBanner;
    _applyLayout(terminal.backend.size, syncLayerMembership: true);
    sceneManager.scheduleRender();
  }

  static bool _setDebugOverlayFlags(bool enabled) {
    final changed =
        debugShowTouchesEnabled != enabled ||
        debugPaintHoverEnabled != enabled ||
        debugMouseCursorEnabled != enabled ||
        debugPaintLayerBordersEnabled != enabled;
    debugShowTouchesEnabled = enabled;
    debugPaintHoverEnabled = enabled;
    debugMouseCursorEnabled = enabled;
    debugPaintLayerBordersEnabled = enabled;
    return changed;
  }

  void _syncMousePointer() {
    if (_anyModalOpen || !viewModel.wantsKeyReleaseEvents) {
      _suppressedShortcutReleases.clear();
    }
    final shouldShowPointer =
        !_disposed && !_anyModalOpen && viewModel.hoveredUrl != null;
    if (_pointerCursorActive == shouldShowPointer) return;
    _pointerCursorActive = shouldShowPointer;
    if (shouldShowPointer) {
      terminal.setMousePointer(.pointer);
    } else {
      terminal.resetMousePointer();
    }
  }

  _SceneLayout _applyLayout(
    Point<int> rawSize, {
    required bool syncLayerMembership,
  }) {
    final layout = _computeLayout(
      rawSize,
      viewModel.dockPosition,
      forceTopBanner: viewModel.hasAttentionBanner,
    );
    ptyLayer
      ..x = layout.ptyX
      ..y = layout.ptyY
      ..width = layout.ptyW
      ..height = layout.ptyH;
    ptyRenderer.resize(layout.ptyW, layout.ptyH);

    chromeLayer
      ..x = layout.chromeX
      ..y = layout.chromeY
      ..width = layout.chromeW
      ..height = layout.chromeH
      ..hitTestable = layout.showChrome;
    dockRenderer.resize(layout.chromeW, layout.chromeH);

    if (syncLayerMembership) {
      _syncChromeMembership(layout.showChrome);
    }

    final focused = sceneManager.focusedLayer;
    if (!_anyModalOpen &&
        (focused == null ||
            (focused == chromeLayer &&
                !dockRenderer.hasActivePointerGesture))) {
      sceneManager.focusedLayer = ptyLayer;
    }
    return layout;
  }

  void _syncChromeMembership(bool showChrome) {
    if (!showChrome) {
      _abortActiveTabDrag();
    }
    final hasChrome = sceneManager.layers.contains(chromeLayer);
    if (showChrome && !hasChrome) {
      sceneManager.layers.add(chromeLayer);
    } else if (!showChrome && hasChrome) {
      sceneManager.layers.remove(chromeLayer);
    }
  }

  static _SceneLayout _computeLayout(
    Point<int> rawSize,
    DockPosition dock, {
    required bool forceTopBanner,
  }) {
    final w = max(1, rawSize.x);
    final h = max(1, rawSize.y);
    return switch (dock) {
      .top when h >= 2 => _computeTopBarLayout(w, h),
      .hidden when forceTopBanner && h >= 2 => _computeTopBarLayout(w, h),
      .left when w >= 6 => _computeLeftLayout(w, h),
      _ => (
        ptyX: 0,
        ptyY: 0,
        ptyW: w,
        ptyH: h,
        showChrome: false,
        chromeX: 0,
        chromeY: 0,
        chromeW: 1,
        chromeH: 1,
      ),
    };
  }

  static _SceneLayout _computeTopBarLayout(int w, int h) => (
    ptyX: 0,
    ptyY: SessionDockBar.topBarHeight,
    ptyW: w,
    ptyH: h - SessionDockBar.topBarHeight,
    showChrome: true,
    chromeX: 0,
    chromeY: 0,
    chromeW: w,
    chromeH: SessionDockBar.topBarHeight,
  );

  static _SceneLayout _computeLeftLayout(int w, int h) {
    final dockW = min(SessionDockBar.leftSidebarWidth, w ~/ 2);
    return (
      ptyX: dockW,
      ptyY: 0,
      ptyW: w - dockW,
      ptyH: h,
      showChrome: true,
      chromeX: 0,
      chromeY: 0,
      chromeW: dockW,
      chromeH: h,
    );
  }

  bool _handleGlobalPasteEvent(ev.PasteEvent event) {
    if (_anyModalOpen || sceneManager.focusedLayer != chromeLayer) {
      return false;
    }
    return ptyRenderer.handlePasteEvent(event);
  }

  bool _handleGlobalKeyEvent(ev.KeyEvent event) {
    final focused = sceneManager.focusedLayer;
    if (_anyModalOpen ||
        (focused != null && focused != ptyLayer && focused != chromeLayer)) {
      return false;
    }
    if (event.eventType == ev.KeyEventType.release) {
      return _handleGlobalKeyRelease(event, focused: focused);
    }
    if (!_leaderArmed) {
      return _handleUnarmedKeyEvent(event, focused: focused);
    }
    _leaderArmed = false;
    if (_isLeaderKey(event)) {
      viewModel.sendRawInputBytes(const [0x1c]);
      _recordConsumedShortcut(event);
      return true;
    }
    _recordConsumedShortcut(event);
    _dispatchLeaderCommand(event);
    return true;
  }

  bool _shouldSuppressPtyKeyRelease(ev.KeyEvent event) {
    if (_consumeSuppressedRelease(event)) {
      return true;
    }
    return _leaderArmed && _isLeaderKey(event);
  }

  bool _handleDockKeyEvent(ev.KeyEvent event) =>
      event.eventType == ev.KeyEventType.release &&
      !_anyModalOpen &&
      _handleGlobalKeyRelease(event, focused: chromeLayer);

  bool _handleGlobalKeyRelease(
    ev.KeyEvent event, {
    required SceneLayer? focused,
  }) {
    if (_shouldSuppressPtyKeyRelease(event)) {
      return true;
    }
    return focused == chromeLayer && ptyRenderer.handleKeyEvent(event);
  }

  static const Map<String, String> _shiftedUsPunctuationToUnshifted = {
    '!': '1',
    '@': '2',
    '#': '3',
    r'$': '4',
    '%': '5',
    '^': '6',
    '&': '7',
    '*': '8',
    '(': '9',
    ')': '0',
    '_': '-',
    '+': '=',
    '{': '[',
    '}': ']',
    '|': r'\',
    ':': ';',
    '"': "'",
    '<': ',',
    '>': '.',
    '?': '/',
    '~': '`',
  };

  void _recordConsumedShortcut(ev.KeyEvent event) {
    if (!viewModel.wantsKeyReleaseEvents || _anyModalOpen) {
      _suppressedShortcutReleases.clear();
      return;
    }
    _suppressedShortcutReleases.add((event.type, event.baseKey));
    if (_shiftedUsPunctuationToUnshifted[event.baseKey] case final unshifted?) {
      _suppressedShortcutReleases.add((event.type, unshifted));
    }
    if (event.type != ev.KeyType.character || event.key.length != 1) return;
    final unit = event.key.codeUnitAt(0);
    if (unit >= 1 && unit <= 26) {
      _suppressedShortcutReleases.add((
        ev.KeyType.character,
        String.fromCharCode(0x40 + unit),
      ));
    } else if (unit == 0x1c) {
      _suppressedShortcutReleases.add((ev.KeyType.character, r'\'));
    }
  }

  void _clearSuppressedKeyOnPress(ev.KeyEvent event) {
    if (_suppressedShortcutReleases.isEmpty) return;
    _suppressedShortcutReleases.remove((event.type, event.baseKey));
    if (_shiftedUsPunctuationToUnshifted[event.baseKey] case final unshifted?) {
      _suppressedShortcutReleases.remove((event.type, unshifted));
    }
  }

  bool _consumeSuppressedRelease(ev.KeyEvent event) {
    if (!wantsKeyReleaseEvents) {
      _suppressedShortcutReleases.clear();
      return false;
    }
    return _suppressedShortcutReleases.remove((event.type, event.baseKey));
  }

  bool _handleUnarmedKeyEvent(
    ev.KeyEvent event, {
    required SceneLayer? focused,
  }) {
    if (focused == chromeLayer &&
        event.type == ev.KeyType.escape &&
        dockRenderer.cancelActiveDrag()) {
      _restorePtyFocus();
      _recordConsumedShortcut(event);
      return true;
    }
    if (_isLeaderKey(event)) {
      _leaderArmed = true;
      _recordConsumedShortcut(event);
      return true;
    }
    if (_isCopyShortcut(event)) {
      viewModel.copySelectionToClipboard();
      _recordConsumedShortcut(event);
      return true;
    }
    if (_isPasteShortcut(event)) {
      terminal.requestPaste();
      _recordConsumedShortcut(event);
      return true;
    }
    if (_handleScrollShortcut(event)) {
      _recordConsumedShortcut(event);
      return true;
    }
    if (_shouldOpenPromptOnEnter(event)) {
      unawaited(openConnectionPrompt());
      _recordConsumedShortcut(event);
      return true;
    }
    return focused == chromeLayer && ptyRenderer.handleKeyEvent(event);
  }

  bool _handleScrollShortcut(ev.KeyEvent event) {
    final mods = event.modifiers;
    if (mods.contains(ev.Modifier.control) ||
        mods.contains(ev.Modifier.alt) ||
        mods.contains(ev.Modifier.meta) ||
        !viewModel.canScrollActiveSession()) {
      return false;
    }
    final shiftHeld = mods.contains(ev.Modifier.shift);
    if (viewModel.activeScrollOffsetLines > 0) {
      return _handleScrolledNavigation(event.type, shiftHeld: shiftHeld);
    }
    return shiftHeld && _handlePageScrollKey(event.type);
  }

  bool _handleScrolledNavigation(ev.KeyType type, {required bool shiftHeld}) {
    if (_handlePageScrollKey(type)) return true;
    switch (type) {
      case .up:
        viewModel.scrollActiveBy(1);
        return true;
      case .down:
        viewModel.scrollActiveBy(-1);
        return true;
      case .left:
        viewModel.panActiveHorizontalBy(shiftHeld ? -8 : -1);
        return true;
      case .right:
        viewModel.panActiveHorizontalBy(shiftHeld ? 8 : 1);
        return true;
      case .escape when !shiftHeld:
        viewModel.scrollActiveToBottom();
        return true;
      default:
        return false;
    }
  }

  bool _handlePageScrollKey(ev.KeyType type) {
    final pageStep = max(1, viewModel.viewportRows - 2);
    switch (type) {
      case .pageUp:
        viewModel.scrollActiveBy(pageStep);
        return true;
      case .pageDown:
        viewModel.scrollActiveBy(-pageStep);
        return true;
      case .home:
        viewModel.scrollActiveToTop();
        return true;
      case .end:
        viewModel.scrollActiveToBottom();
        return true;
      default:
        return false;
    }
  }

  bool _shouldOpenPromptOnEnter(ev.KeyEvent event) =>
      event.type == ev.KeyType.enter &&
      (viewModel.connectionState == .authFailed ||
          viewModel.connectionState == .unconnected);

  static bool _isLeaderKey(ev.KeyEvent event) =>
      event.key == '\x1c' ||
      (event.type == ev.KeyType.character &&
          event.modifiers.contains(ev.Modifier.control) &&
          event.key == r'\');

  static bool _isCopyShortcut(ev.KeyEvent event) {
    if (event.type != ev.KeyType.character) return false;
    final mods = event.modifiers;
    final lower = event.key.toLowerCase();
    final isCmdC =
        lower == 'c' &&
        mods.contains(ev.Modifier.meta) &&
        !mods.contains(ev.Modifier.control) &&
        !mods.contains(ev.Modifier.alt);
    final isCtrlShiftC =
        (lower == 'c' || event.key == '\x03') &&
        mods.contains(ev.Modifier.control) &&
        mods.contains(ev.Modifier.shift) &&
        !mods.contains(ev.Modifier.meta) &&
        !mods.contains(ev.Modifier.alt);
    return isCmdC || isCtrlShiftC;
  }

  static bool _isPasteShortcut(ev.KeyEvent event) {
    final mods = event.modifiers;
    if (event.type == ev.KeyType.insert) {
      return mods.contains(ev.Modifier.shift) &&
          !mods.contains(ev.Modifier.control) &&
          !mods.contains(ev.Modifier.alt) &&
          !mods.contains(ev.Modifier.meta);
    }
    if (event.type != ev.KeyType.character) return false;
    final lower = event.key.toLowerCase();
    final isCmdV =
        lower == 'v' &&
        mods.contains(ev.Modifier.meta) &&
        !mods.contains(ev.Modifier.control) &&
        !mods.contains(ev.Modifier.alt);
    final isCtrlShiftV =
        (lower == 'v' || event.key == '\x16') &&
        mods.contains(ev.Modifier.control) &&
        mods.contains(ev.Modifier.shift) &&
        !mods.contains(ev.Modifier.meta) &&
        !mods.contains(ev.Modifier.alt);
    return isCmdV || isCtrlShiftV;
  }

  void _dispatchLeaderCommand(ev.KeyEvent event) {
    if (event.type == ev.KeyType.tab) {
      final backward =
          event.key == 'backtab' || event.modifiers.contains(ev.Modifier.shift);
      unawaited(viewModel.cycleSession(backward ? -1 : 1));
      return;
    }
    if (event.type == ev.KeyType.backspace) {
      unawaited(openChordsHelp());
      return;
    }
    switch (event.key.toLowerCase()) {
      case 'c' || '\x03':
        unawaited(openConnectionPrompt());
      case 'y' || '\x19':
        viewModel.copySelectionToClipboard();
      case 'v' || '\x16':
        terminal.requestPaste();
      case 'o' || '\x0f':
        viewModel.toggleCopyOnSelect();
      case '?' || '/' || 'h' || '\x1f' || '\x08':
        unawaited(openChordsHelp());
      case 's' || 'i' || '\x13':
        unawaited(openStatsForNerds());
      case ',':
        unawaited(openSettings());
      case 't' || '\x14':
        viewModel.cycleThemePreset();
        viewModel.showTransientNotice(
          'Theme: ${viewModel.activeTerminalTheme.name} (Ctrl+\\ t)',
        );
      case 'n' || ']' || '\x0e':
        unawaited(viewModel.cycleSession(1));
      case 'p' || '[' || '\x10':
        unawaited(viewModel.cycleSession(-1));
      case 'd' || ' ' || '\x04' || '\x00':
        viewModel.cycleDockPosition();
      case 'r' || '\x12':
        unawaited(openRenameTabDialog());
      case 'x' || '\x18':
        unawaited(viewModel.dismissActiveEndedSession());
      case 'g' || '\x07':
        viewModel.scrollActiveToBottom();
      case '1' || '2' || '3' || '4' || '5' || '6' || '7' || '8' || '9':
        _selectDigitSession(event.key.codeUnitAt(0) - 0x31);
    }
  }

  void _selectDigitSession(int index) {
    if (index < viewModel.sessions.length) {
      unawaited(viewModel.selectSession(viewModel.sessions[index].id));
    }
  }

  /// Disposes the [SceneManager] and unsubscribes listeners.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _setDebugOverlayFlags(false);
    if (DragDropManager.onDragSessionChanged == _handleDragSessionChanged) {
      DragDropManager.onDragSessionChanged = null;
    }
    _syncMousePointer();
    TermuiBinding.unregister(this);
    _removeVisualListener();
    if (viewModel.onClipboardWrite == terminal.setClipboard) {
      viewModel.onClipboardWrite = null;
    }
    sceneManager
      ..onFrameRedrawn = null
      ..dispose();
    _dragGhostRenderer.dispose();
    ptyRenderer.dispose();
    dockRenderer.dispose();
  }
}

final class _DragGhostRenderer implements SceneRenderer {
  Buffer? _buffer;
  String _text = '';
  Style _style = const Style();

  @override
  Buffer? get currentBuffer => _buffer;

  @override
  bool get wantsMouseTracking => false;

  @override
  bool get wantsAlternateScreen => false;

  @override
  bool get showsCursor => false;

  @override
  Point<int>? get requestedCursorPosition => null;

  void updatePill({
    required String text,
    required int widthCols,
    required Style style,
  }) {
    _text = text;
    _style = style;
    _paint(max(1, widthCols), 1);
  }

  void clear() {
    _buffer = null;
    _text = '';
  }

  void _paint(int w, int h) {
    final buf = Buffer.blank(w, h);
    buf.writeString(0, 0, DockTabLayout.clipAndPadRight(_text, w), _style);
    _buffer = buf;
  }

  @override
  void resize(int width, int height) {
    if (_text.isEmpty) return;
    _paint(max(1, width), max(1, height));
  }

  @override
  bool handleKeyEvent(ev.KeyEvent event) => false;

  @override
  bool handleMouseEvent(ev.MouseEvent event) => false;

  @override
  bool handlePasteEvent(ev.PasteEvent event) => false;

  @override
  void dispose() {
    clear();
  }
}
