import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart'
    show
        Clipboard,
        ClipboardData,
        HardwareKeyboard,
        KeyDownEvent,
        KeyEvent,
        KeyRepeatEvent,
        KeyUpEvent,
        LogicalKeyboardKey,
        MethodCall,
        MethodChannel;
import 'package:material_ui/material_ui.dart';
import 'package:termui/terminal/event.dart' as ev;
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_flutter/termui_flutter.dart';

import '../automation/automation_models.dart';
import '../file_drop_bridge.dart';
import '../font_loader.dart';
import '../settings_storage.dart';
import '../shader_editor/shader_editor_controller.dart';
import '../shader_editor/shader_editor_pane.dart';
import '../workspace/cli_shader_state.dart';
import '../workspace/fterm_pane_controller.dart';
import '../workspace/fterm_workspace_controller.dart';
import '../workspace/local_host_driver.dart';
import '../workspace/split_tree_model.dart';
import 'fterm_overlays.dart';
import 'fterm_perf_hud.dart';
import 'fterm_shortcut_dispatcher.dart';

/// Root Flutter shell hosting the 28px tab bar, recursive binary split trees
/// of [TerminalSurface] panes sharing one [GlyphAtlasController], and overlays.
final class FtermShellScaffold extends StatefulWidget {
  /// Backing workspace controller.
  final FtermWorkspaceController workspace;

  /// Monospace cell point size passed to the shared [GlyphAtlasController].
  final double fontSize;

  /// External URL launcher invoked on `Ctrl/Cmd+Click`.
  final UrlOpener onOpenUrl;

  /// Optional platform override for testing macOS vs Linux/Windows chrome.
  final TargetPlatform? platformOverride;

  /// Optional Web polarity override for testing Web vs Desktop behavior.
  final bool? isWebOverride;

  /// Optional drag-over indicator shown during file drag-and-drop hover.
  final bool isDraggingOverFiles;

  /// Creates the main `fterm` workspace scaffold.
  const FtermShellScaffold({
    super.key,
    required this.workspace,
    required this.onOpenUrl,
    this.fontSize = 13.0,
    this.platformOverride,
    this.isWebOverride,
    this.isDraggingOverFiles = false,
  });

  @override
  State<FtermShellScaffold> createState() => _FtermShellScaffoldState();
}

enum _TabContextAction {
  saveShader,
  saveShaderAs,
  previewSolo,
  previewBlend,
  previewOff,
  renameTab,
  closeTab,
}

final class _FtermShellScaffoldState extends State<FtermShellScaffold>
    with WidgetsBindingObserver {
  static const double tabBarHeight = 28.0;
  static const double leftRailWidth = 172.0;
  static const double macOsTrafficLightInset = 72.0;
  static const MethodChannel _windowChannel = MethodChannel('fterm/window');

  GlyphAtlasController? _atlasController;
  late FtermShortcutDispatcher _shortcutDispatcher;
  late final TerminalService _terminalService;
  late final AutomationPointerDispatcher _automationPointerDispatcher;
  final Map<String, FocusNode> _paneFocusNodes = {};
  final Map<String, GlobalKey<State<TerminalSurface>>> _paneSurfaceKeys = {};
  final Map<String, GlobalKey> _paneBoundaryKeys = {};
  final Set<String> _suppressMiddleReleasePaneIds = {};
  final FocusNode _emptyWorkspaceFocusNode = FocusNode(
    debugLabel: 'fterm-empty-focus',
  );
  String? _lastRequestedFocusedPaneId;
  Object? _lastLayoutSignature;
  bool _hadBakedAtlas = false;
  bool _atlasInitRequested = false;
  bool _passedThroughEarlyF12 = false;
  DateTime? _lastTabTapAt;
  String? _lastTabTapId;

  TargetPlatform get _platform =>
      widget.platformOverride ?? defaultTargetPlatform;
  bool get _isWeb => widget.isWebOverride ?? kIsWeb;

  double _resolvedFontSize(BuildContext context) {
    final baseFontSize = widget.workspace.preferences.effectiveFontSize(
      widget.fontSize,
    );
    final scaler =
        MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling;
    return scaler
        .scale(baseFontSize)
        .clamp(FtermPreferences.minFontSize, FtermPreferences.maxFontSize)
        .toDouble();
  }

  double? _resolveDevicePixelRatio() {
    final dpr =
        MediaQuery.maybeDevicePixelRatioOf(context) ??
        View.maybeOf(context)?.devicePixelRatio;
    return (dpr != null && dpr.isFinite && dpr > 0) ? dpr : null;
  }

  void _syncAtlasConfig() {
    final ctrl = _atlasController;
    if (!mounted || ctrl == null) return;
    unawaited(
      ctrl.updateConfig(
        fontSize: _resolvedFontSize(context),
        devicePixelRatio: _resolveDevicePixelRatio(),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final initialFontSize = widget.workspace.preferences.effectiveFontSize(
      widget.fontSize,
    );
    _shortcutDispatcher = FtermShortcutDispatcher(
      workspace: widget.workspace,
      platformOverride: widget.platformOverride,
      isWebOverride: widget.isWebOverride,
    );
    _terminalService = _FtermTerminalService(onOpenUrl: widget.onOpenUrl);
    _automationPointerDispatcher = _ScaffoldAutomationPointerDispatcher(
      surfaceKeys: _paneSurfaceKeys,
      isMounted: () => mounted,
    );
    widget.workspace.attachAutomationPointerDispatcher(
      _automationPointerDispatcher,
    );
    widget.workspace.chromeNotifier.addListener(_onWorkspaceChromeChanged);
    _lastLayoutSignature = _computeLayoutSignature(
      resolvedFontSize: initialFontSize,
    );
    FocusManager.instance.addEarlyKeyEventHandler(_handleEarlyF12Event);
    _windowChannel.setMethodCallHandler(_handleWindowChannelCall);
    if (!_isWeb) {
      unawaited(_queryGraphicsAdapterInfo());
    }
  }

  Future<void> _queryGraphicsAdapterInfo() async {
    try {
      final info = await _windowChannel.invokeMapMethod<String, Object?>(
        'getGraphicsAdapterInfo',
      );
      if (!mounted || info == null) return;
      final description = info['description'] is String
          ? info['description']! as String
          : null;
      final vramMb = info['dedicatedVideoMemoryMB'] is int
          ? info['dedicatedVideoMemoryMB']! as int
          : null;
      widget.workspace.setActiveGpuAdapterInfo(
        name: description,
        dedicatedVramMb: vramMb,
      );
    } on Object {
      // Non-Windows runners and unit tests may not register this method.
    }
  }

  Future<Object?> _handleWindowChannelCall(MethodCall call) async {
    if (call.method == 'windowSizeMoveChanged' && mounted) {
      widget.workspace.shaderController.setAmbientTicksPaused(
        call.arguments == true,
      );
    }
    return null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_atlasInitRequested) {
      _atlasInitRequested = true;
      final ctrl = GlyphAtlasController(
        fontSize: _resolvedFontSize(context),
        devicePixelRatio: _resolveDevicePixelRatio() ?? 1.0,
        fontFamily: castPrimaryFontFamily,
        fontFamilyFallback: castFallbackFontFamilies,
      )..addListener(_onAtlasChanged);
      _atlasController = ctrl;
      unawaited(ctrl.ensureInitialized());
    } else {
      _syncAtlasConfig();
    }
    _lastLayoutSignature = _computeLayoutSignature();
  }

  @override
  void didChangeMetrics() {
    _syncAtlasConfig();
    if (_isWeb && mounted) {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncAtlasConfig();
      if (_isWeb && mounted) {
        setState(() {});
      }
    }
  }

  void _onAtlasChanged() {
    final hasAtlas = _atlasController?.atlas != null;
    if (hasAtlas && !_hadBakedAtlas) {
      _hadBakedAtlas = true;
      _lastRequestedFocusedPaneId = null;
      _syncKeyboardFocus();
    } else if (!hasAtlas) {
      _hadBakedAtlas = false;
    }
  }

  @override
  void didUpdateWidget(FtermShellScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fontSize != widget.fontSize) {
      _syncAtlasConfig();
    }
    if (!identical(oldWidget.workspace, widget.workspace) ||
        oldWidget.platformOverride != widget.platformOverride ||
        oldWidget.isWebOverride != widget.isWebOverride) {
      _shortcutDispatcher = FtermShortcutDispatcher(
        workspace: widget.workspace,
        platformOverride: widget.platformOverride,
        isWebOverride: widget.isWebOverride,
      );
    }
    if (!identical(oldWidget.workspace, widget.workspace)) {
      oldWidget.workspace.attachAutomationPointerDispatcher(null);
      oldWidget.workspace.chromeNotifier.removeListener(
        _onWorkspaceChromeChanged,
      );
      widget.workspace.attachAutomationPointerDispatcher(
        _automationPointerDispatcher,
      );
      widget.workspace.chromeNotifier.addListener(_onWorkspaceChromeChanged);
      _lastRequestedFocusedPaneId = null;
      _syncAtlasConfig();
      _lastLayoutSignature = _computeLayoutSignature();
    }
  }

  Object _computeLayoutSignature({double? resolvedFontSize}) {
    final ws = widget.workspace;
    return Object.hashAll([
      ws.activeTabIndex,
      ws.dockPosition,
      ws.shouldShowTabBar,
      ws.activeOverlay != FtermOverlay.none,
      ws.activeTerminalTheme,
      ws.workspaceSettings.themeSettings.faintOpacity,
      ws.backgroundOpacity,
      ws.activeShaderConfig,
      ws.shadersEmergencyStopped,
      ws.shaderEmergencyStopReason,
      ws.shaderController.backendKind,
      ws.localCliShaderPolicy,
      ws.remoteCliShaderPolicy,
      ws.cliFullPaneShaderMode,
      ws.pendingCliShaderApprovals.length,
      ws.activeCliFullPaneConflict?.shaderLabel,
      ws.showPerfHud,
      ws.maxShaderFps,
      ws.preferences.macosOptionAsAlt,
      ws.preferences.metaKeyMode,
      Object.hashAll(ws.preferences.passthroughShortcuts),
      ws.preferences.fontSize,
      ws.updateViewModel.status,
      ws.automationDriver.isRunning,
      ws.automationDriver.allowPty,
      ws.automationDriver.port,
      resolvedFontSize ?? _resolvedFontSize(context),
      for (final tab in ws.tabs) ...[
        tab.tabId,
        identityHashCode(tab.splitTree),
      ],
    ]);
  }

  void _onWorkspaceChromeChanged() {
    if (!mounted) return;
    _pruneDisposedFocusNodes();
    _syncAtlasConfig();
    final nextSignature = _computeLayoutSignature();
    if (nextSignature != _lastLayoutSignature) {
      _lastLayoutSignature = nextSignature;
      setState(() {});
    }
    _syncKeyboardFocus();
  }

  void _pruneDisposedFocusNodes() {
    final activeIds = <String>{
      for (final tab in widget.workspace.tabs) ...tab.splitTree.paneIds,
    };
    _suppressMiddleReleasePaneIds.removeWhere((id) => !activeIds.contains(id));
    final stale = [
      for (final id in _paneFocusNodes.keys)
        if (!activeIds.contains(id)) id,
    ];
    for (final id in stale) {
      _paneFocusNodes.remove(id)?.dispose();
    }
    final staleSurfaceKeys = [
      for (final id in _paneSurfaceKeys.keys)
        if (!activeIds.contains(id)) id,
    ];
    for (final id in staleSurfaceKeys) {
      _paneSurfaceKeys.remove(id);
      _paneBoundaryKeys.remove(id);
    }
  }

  void _syncKeyboardFocus() {
    if (widget.workspace.activeOverlay != FtermOverlay.none) {
      _lastRequestedFocusedPaneId = null;
      _unfocusWorkspacePanes();
      return;
    }
    if (_atlasController?.atlas == null) {
      _lastRequestedFocusedPaneId = null;
      return;
    }
    final targetId = widget.workspace.focusedPaneId;
    if (targetId == null || targetId == _lastRequestedFocusedPaneId) return;
    _lastRequestedFocusedPaneId = targetId;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _applyPostFramePaneFocus(targetId),
    );
  }

  void _unfocusWorkspacePanes() {
    for (final node in _paneFocusNodes.values) {
      if (node.hasFocus) {
        node.unfocus();
      }
    }
    if (_emptyWorkspaceFocusNode.hasFocus) {
      _emptyWorkspaceFocusNode.unfocus();
    }
  }

  void _applyPostFramePaneFocus(String targetId) {
    if (!mounted || widget.workspace.activeOverlay != FtermOverlay.none) {
      return;
    }
    final node = _paneFocusNodes[targetId];
    if (node == null || node.context == null) {
      _lastRequestedFocusedPaneId = null;
      return;
    }
    node.requestFocus();
  }

  FocusNode _focusNodeForPane(String paneId) => _paneFocusNodes.putIfAbsent(
    paneId,
    () => FocusNode(debugLabel: 'fterm-pane-$paneId'),
  );

  GlobalKey<State<TerminalSurface>> _surfaceKeyForPane(String paneId) =>
      _paneSurfaceKeys.putIfAbsent(
        paneId,
        () => GlobalKey<State<TerminalSurface>>(
          debugLabel: 'fterm-pane-surface-$paneId',
        ),
      );

  GlobalKey _boundaryKeyForPane(String paneId) => _paneBoundaryKeys.putIfAbsent(
    paneId,
    () => GlobalKey(debugLabel: 'fterm-pane-boundary-$paneId'),
  );

  Future<ui.Image?> _captureFocusedPaneScreenshot() async {
    final paneId = widget.workspace.focusedPaneId;
    if (paneId == null) return null;
    final boundary =
        _paneBoundaryKeys[paneId]?.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) return null;
    return boundary.toImage(pixelRatio: 2.0);
  }

  static Set<ev.Modifier> _collectHardwareModifiers() {
    final kb = HardwareKeyboard.instance;
    return {
      if (kb.isShiftPressed) ev.Modifier.shift,
      if (kb.isAltPressed) ev.Modifier.alt,
      if (kb.isControlPressed) ev.Modifier.control,
      if (kb.isMetaPressed) ev.Modifier.meta,
    };
  }

  bool _shouldPassThroughEarlyF12(KeyEvent event, Set<ev.Modifier> mods) {
    final matches = _shortcutDispatcher.isPassthroughShortcut(
      event.logicalKey,
      mods,
    );
    if (event is KeyDownEvent) {
      _passedThroughEarlyF12 = matches;
      return matches;
    }
    if (event is KeyUpEvent) {
      final wasPassedThrough = _passedThroughEarlyF12;
      _passedThroughEarlyF12 = false;
      return matches || wasPassedThrough;
    }
    return matches || _passedThroughEarlyF12;
  }

  KeyEventResult _handleEarlyF12Event(KeyEvent event) {
    if (widget.workspace.activeOverlay != FtermOverlay.none) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.f12) {
      return KeyEventResult.ignored;
    }
    final mods = _collectHardwareModifiers();
    if (_shouldPassThroughEarlyF12(event, mods)) {
      return KeyEventResult.ignored;
    }
    if (widget.workspace.f12ShortcutsEnabled &&
        mods.difference(const <ev.Modifier>{.shift}).isEmpty) {
      return KeyEventResult.ignored;
    }
    final pane = widget.workspace.focusedPane;
    if (pane == null) return KeyEventResult.ignored;

    if (event is KeyDownEvent) {
      pane.sendInputEvent(ev.KeyEvent('f12', ev.KeyType.f12, modifiers: mods));
    } else if (event is KeyRepeatEvent) {
      pane.sendInputEvent(
        ev.KeyEvent(
          'f12',
          ev.KeyType.f12,
          modifiers: mods,
          eventType: ev.KeyEventType.repeat,
        ),
      );
    } else if (event is KeyUpEvent && pane.reportKeyReleaseEvents) {
      pane.sendInputEvent(
        ev.KeyEvent(
          'f12',
          ev.KeyType.f12,
          modifiers: mods,
          eventType: ev.KeyEventType.release,
        ),
      );
    }
    return KeyEventResult.handled;
  }

  KeyEventResult _handleRootKeyEvent(KeyEvent event) {
    final mods = _collectHardwareModifiers();
    return switch (_shortcutDispatcher.handleHostShortcut(event, mods)) {
      .handled => .handled,
      .passThrough || .unhandled => .ignored,
    };
  }

  Future<void> _pasteClipboardToPane(FtermPaneController pane) async {
    final String? text;
    try {
      text = await _terminalService.getClipboard();
    } on Object catch (_) {
      return;
    }
    if (!mounted || text == null || text.isEmpty) return;
    pane.sendInputEvent(ev.PasteEvent(text));
  }

  void _handlePaneInputEvent(FtermPaneController pane, ev.InputEvent event) {
    if (event case ev.MouseEvent() when _handleMiddleMousePaste(pane, event)) {
      return;
    }
    pane.sendInputEvent(event);
  }

  bool _handleMiddleMousePaste(FtermPaneController pane, ev.MouseEvent event) {
    final isMiddlePress =
        event.button == ev.MouseButton.middle &&
        event.type == ev.MouseEventType.press;
    final bypassMouseTracking =
        !pane.mouseTracking || event.modifiers.contains(ev.Modifier.shift);
    if (isMiddlePress && bypassMouseTracking) {
      _suppressMiddleReleasePaneIds.add(pane.paneId);
      unawaited(_pasteClipboardToPane(pane));
      return true;
    }
    if (!_suppressMiddleReleasePaneIds.contains(pane.paneId)) {
      return false;
    }
    switch (event.type) {
      case ev.MouseEventType.drag:
        return event.button == ev.MouseButton.middle;
      case ev.MouseEventType.release:
        _suppressMiddleReleasePaneIds.remove(pane.paneId);
        return true;
      case ev.MouseEventType.press:
        _suppressMiddleReleasePaneIds.remove(pane.paneId);
        return false;
      default:
        return false;
    }
  }

  @override
  void dispose() {
    _windowChannel.setMethodCallHandler(null);
    widget.workspace.shaderController.setAmbientTicksPaused(false);
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeEarlyKeyEventHandler(_handleEarlyF12Event);
    _atlasController?.removeListener(_onAtlasChanged);
    widget.workspace.attachAutomationPointerDispatcher(null);
    widget.workspace.chromeNotifier.removeListener(_onWorkspaceChromeChanged);
    for (final node in _paneFocusNodes.values) {
      node.dispose();
    }
    _paneFocusNodes.clear();
    _paneSurfaceKeys.clear();
    _paneBoundaryKeys.clear();
    _emptyWorkspaceFocusNode.dispose();
    _atlasController?.dispose();
    _atlasController = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.workspace.activeTerminalTheme;
    final bgColor = Color(theme.background.argb);
    final showBar = widget.workspace.shouldShowTabBar;
    final dock = widget.workspace.dockPosition;
    final isMacOsDesktop = !_isWeb && _platform == TargetPlatform.macOS;

    final resolvedFontSize = _resolvedFontSize(context);
    final Widget mainContent = Expanded(
      child: _buildActiveTabBody(theme, resolvedFontSize),
    );

    final Widget workspaceLayout = switch ((showBar, dock)) {
      (true, DockPosition.top) => Column(
        children: [_buildTopTabBar(theme), mainContent],
      ),
      (true, DockPosition.left) => Row(
        children: [_buildLeftTabRail(theme), mainContent],
      ),
      _ when isMacOsDesktop => Column(
        children: [
          ColoredBox(
            color: bgColor,
            child: _buildMacOsSafeDragRow(
              key: const ValueKey('fterm-macos-titlebar-strip'),
            ),
          ),
          mainContent,
        ],
      ),
      _ => _buildActiveTabBody(theme, resolvedFontSize),
    };

    return Scaffold(
      backgroundColor: bgColor,
      body: Focus(
        canRequestFocus: false,
        onKeyEvent: (_, event) => _handleRootKeyEvent(event),
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) =>
              unawaited(widget.workspace.audioController.notifyUserGesture()),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ExcludeFocus(
                excluding: widget.workspace.activeOverlay != FtermOverlay.none,
                child: workspaceLayout,
              ),
              if (widget.isDraggingOverFiles) _buildDragOverlay(theme),
              if (widget.workspace.showPerfHud)
                Positioned(
                  top: (showBar && dock == DockPosition.top) ? 36 : 12,
                  right: 12,
                  child: FtermPerfHud(workspace: widget.workspace),
                ),
              ListenableBuilder(
                listenable: widget.workspace.chromeNotifier,
                builder: (_, _) => _CliShaderApprovalBannerHost(
                  workspace: widget.workspace,
                  theme: theme,
                  topOffset: (showBar && dock == DockPosition.top) ? 36 : 12,
                ),
              ),
              if (widget.workspace.shadersEmergencyStopped)
                _ShaderEmergencyStopPill(workspace: widget.workspace),
              if (!showBar && widget.workspace.automationDriver.isRunning)
                _AutomationCornerPill(
                  driver: widget.workspace.automationDriver,
                  theme: theme,
                  topOffset: widget.workspace.showPerfHud ? 68.0 : 8.0,
                  onTap: () => widget.workspace.openSettingsOverlay(
                    initialSection: .automation,
                  ),
                ),
              ListenableBuilder(
                listenable: widget.workspace.chromeNotifier,
                builder: (_, _) => FtermOverlayHost(
                  workspace: widget.workspace,
                  onOpenUrl: widget.onOpenUrl,
                  isWeb: _isWeb,
                  platformOverride: widget.platformOverride,
                  onCaptureScreenshot: _captureFocusedPaneScreenshot,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActiveTabBody(tui.TerminalColorTheme theme, double fontSize) {
    final tab = widget.workspace.activeTab;
    if (tab == null) {
      return _buildEmptyWorkspaceState(theme);
    }
    final tree = tab.splitTree;
    if (tree.isZoomed) {
      final zoomedId = tree.zoomedPaneId;
      if (zoomedId != null &&
          (widget.workspace.shaderEditorPaneById(zoomedId) != null ||
              widget.workspace.paneById(zoomedId) != null)) {
        return _buildLeafWidget(
          paneId: zoomedId,
          tab: tab,
          showFocusBorder: false,
          theme: theme,
          fontSize: fontSize,
        );
      }
    }
    return _SplitTreeView(
      key: ValueKey('split-root-${tab.tabId}'),
      node: tree.root,
      tab: tab,
      workspace: widget.workspace,
      theme: theme,
      buildLeaf: (paneId) => _buildLeafWidget(
        paneId: paneId,
        tab: tab,
        showFocusBorder: tree.paneCount > 1,
        theme: theme,
        fontSize: fontSize,
      ),
    );
  }

  Widget _buildLeafWidget({
    required String paneId,
    required FtermTabState tab,
    required bool showFocusBorder,
    required tui.TerminalColorTheme theme,
    required double fontSize,
  }) {
    final editorPane = widget.workspace.shaderEditorPaneById(paneId);
    if (editorPane != null) {
      return _buildEditorPaneLeaf(
        editorPane: editorPane,
        tab: tab,
        showFocusBorder: showFocusBorder,
        theme: theme,
        fontSize: fontSize,
      );
    }
    final pane = widget.workspace.paneById(paneId);
    if (pane == null) {
      return ColoredBox(color: Color(theme.background.argb));
    }
    return _buildPaneLeaf(
      pane: pane,
      tab: tab,
      showFocusBorder: showFocusBorder,
      theme: theme,
      fontSize: fontSize,
    );
  }

  Widget _buildEditorPaneLeaf({
    required ShaderEditorPane editorPane,
    required FtermTabState tab,
    required bool showFocusBorder,
    required tui.TerminalColorTheme theme,
    required double fontSize,
  }) {
    final isFocused = editorPane.paneId == tab.splitTree.focusedPaneId;
    final defaultBg = Color(theme.background.argb);
    final fgColor = Color(theme.foreground.argb);
    final borderColor = isFocused
        ? Color(theme.cursorColor.argb)
        : fgColor.withValues(alpha: 0.16);
    final isZoomed = tab.splitTree.zoomedPaneId == editorPane.paneId;

    final surface = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => widget.workspace.focusPane(editorPane.paneId),
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            key: _boundaryKeyForPane(editorPane.paneId),
            child: ListenableBuilder(
              listenable: editorPane.previewConfigListenable,
              builder: (_, _) {
                final bgOverride = editorPane.previewBackgroundColorOverride;
                final surfaceBg = bgOverride != null
                    ? Color(bgOverride.argb)
                    : defaultBg;
                return TerminalSurface(
                  key: _surfaceKeyForPane(editorPane.paneId),
                  atlasController: _atlasController,
                  focusNode: _focusNodeForPane(editorPane.paneId),
                  autofocus:
                      isFocused &&
                      widget.workspace.activeOverlay == FtermOverlay.none,
                  bufferProvider: editorPane.readDisplayBuffer,
                  bufferListenable: editorPane.bufferListenable,
                  cursorPositionProvider: editorPane.readCursorPosition,
                  cursorVisibleProvider: editorPane.readCursorVisible,
                  mouseTracking: true,
                  macosOptionAsAlt:
                      widget.workspace.preferences.macosOptionAsAlt,
                  metaKeyPolicy: _shortcutDispatcher.resolveMetaKeyPolicy(),
                  fontSize: fontSize,
                  fontFamily: castPrimaryFontFamily,
                  fontFamilyFallback: castFallbackFontFamilies,
                  backgroundColor: surfaceBg,
                  foregroundColor: fgColor,
                  backgroundOpacity: editorPane.previewBackgroundOpacity,
                  shaderController: widget.workspace.shaderController,
                  shaderConfig: editorPane.resolvePreviewShaderConfig(
                    widget.workspace.activeShaderConfig,
                  ),
                  maxAmbientFps: widget.workspace.maxShaderFps?.toDouble(),
                  gpuFrameWatchdog: editorPane.gpuFrameWatchdog,
                  faintOpacity: widget
                      .workspace
                      .workspaceSettings
                      .themeSettings
                      .faintOpacity,
                  palette: theme,
                  service: _terminalService,
                  enableHostShortcuts: true,
                  alignment: Alignment.topLeft,
                  onViewportSizeChanged: editorPane.updateViewportSize,
                  onInputEvent: editorPane.handleInputEvent,
                  onTextInput: editorPane.handleCommittedText,
                  onHostShortcut: _shortcutDispatcher.handleHostShortcut,
                  onFocusChanged: (hasFocus) {
                    editorPane.setFocused(hasFocus);
                    if (hasFocus) {
                      widget.workspace.focusPane(editorPane.paneId);
                    }
                  },
                );
              },
            ),
          ),
          ListenableBuilder(
            listenable: editorPane.controller,
            builder: (_, _) => _buildOpaqueFgPreviewPill(editorPane),
          ),
          if (isZoomed)
            Positioned(
              top: 6,
              right: 8,
              child: IgnorePointer(
                child: Container(
                  key: ValueKey('pane-pill-${editorPane.paneId}'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Color.lerp(
                      defaultBg,
                      fgColor,
                      0.14,
                    )!.withValues(alpha: 0.88),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: fgColor.withValues(alpha: 0.2)),
                  ),
                  child: Text(
                    'ZOOM',
                    style: TextStyle(
                      color: fgColor,
                      fontSize: 10,
                      fontFamily: castPrimaryFontFamily,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    if (!showFocusBorder) {
      return SizedBox.expand(
        key: ValueKey('pane-leaf-${editorPane.paneId}'),
        child: surface,
      );
    }
    return Container(
      key: ValueKey('pane-leaf-${editorPane.paneId}'),
      decoration: BoxDecoration(
        border: Border.all(color: borderColor, width: 1.0),
      ),
      child: surface,
    );
  }

  Widget _buildOpaqueFgPreviewPill(ShaderEditorPane editorPane) {
    final ctrl = editorPane.controller;
    final samplesChannel0 =
        ctrl.lastAnalysis?.samplesChannel0 ??
        widget.workspace.shaderController
            .analysisForPass(editorPane.previewPassId)
            ?.samplesChannel0 ??
        true;
    final hidesEditor =
        !widget.workspace.shadersEmergencyStopped &&
        ctrl.previewMode == ShaderEditorPreviewMode.foreground &&
        !samplesChannel0;
    if (!hidesEditor) return const SizedBox.shrink();

    const pillBg = Color(0xE6261717);
    const pillBorder = Color(0xFFFF6B6B);
    const pillFg = Color(0xFFFFFFFF);
    const actionBg = Color(0xFF3A2323);

    return Positioned(
      top: 8,
      right: 12,
      child: Material(
        color: Colors.transparent,
        child: Container(
          key: ValueKey('editor-fg-opaque-pill-${editorPane.paneId}'),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: pillBg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: pillBorder, width: 1.25),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'FG hides editor (no iChannel0)',
                style: TextStyle(
                  color: pillFg,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  fontFamily: castPrimaryFontFamily,
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                key: ValueKey('editor-fg-switch-bg-${editorPane.paneId}'),
                onTap: () =>
                    ctrl.setPreviewMode(ShaderEditorPreviewMode.background),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: actionBg,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: pillBorder),
                  ),
                  child: const Text(
                    'Switch to BG',
                    style: TextStyle(
                      color: pillFg,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      fontFamily: castPrimaryFontFamily,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              InkWell(
                key: ValueKey('editor-fg-off-${editorPane.paneId}'),
                onTap: () => ctrl.setPreviewMode(ShaderEditorPreviewMode.off),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: actionBg,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: pillBorder),
                  ),
                  child: const Text(
                    'Off',
                    style: TextStyle(
                      color: pillFg,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      fontFamily: castPrimaryFontFamily,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyWorkspaceState(tui.TerminalColorTheme theme) {
    final fg = Color(theme.foreground.argb);
    return Focus(
      focusNode: _emptyWorkspaceFocusNode,
      autofocus: widget.workspace.activeOverlay == FtermOverlay.none,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'fterm',
              style: TextStyle(
                color: fg.withValues(alpha: 0.75),
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              children: [
                if (widget.workspace.isDesktopHost)
                  FilledButton.icon(
                    onPressed: () =>
                        unawaited(widget.workspace.openLocalShellTab()),
                    icon: const Icon(Icons.terminal, size: 16),
                    label: const Text('New Local Shell'),
                  ),
                OutlinedButton.icon(
                  onPressed: () =>
                      widget.workspace.setOverlay(FtermOverlay.connect),
                  icon: const Icon(Icons.link, size: 16),
                  label: const Text('Connect Relay'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  bool _readCopyOnSelect() => widget.workspace.copyOnSelect;

  Widget _buildPaneLeaf({
    required FtermPaneController pane,
    required FtermTabState tab,
    required bool showFocusBorder,
    required tui.TerminalColorTheme theme,
    required double fontSize,
  }) {
    final isFocused = pane.paneId == tab.splitTree.focusedPaneId;
    final bgColor = Color(theme.background.argb);
    final fgColor = Color(theme.foreground.argb);
    final borderColor = isFocused
        ? Color(theme.cursorColor.argb)
        : fgColor.withValues(alpha: 0.16);

    final surface = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => widget.workspace.focusPane(pane.paneId),
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            key: _boundaryKeyForPane(pane.paneId),
            child: TerminalSurface(
              key: _surfaceKeyForPane(pane.paneId),
              atlasController: _atlasController,
              focusNode: _focusNodeForPane(pane.paneId),
              autofocus:
                  isFocused &&
                  widget.workspace.activeOverlay == FtermOverlay.none,
              bufferProvider: pane.readDisplayBuffer,
              bufferListenable: pane.bufferListenable,
              activePtySizeProvider: pane.readActivePtySize,
              cursorPositionProvider: pane.readCursorPosition,
              cursorVisibleProvider: pane.readCursorVisible,
              kittyKeyboardFlagsProvider: pane.readKittyKeyboardFlags,
              reportKeyReleaseEventsProvider: pane.readReportKeyReleaseEvents,
              reportPixelMouseEventsProvider: pane.readReportPixelMouseEvents,
              mouseTrackingProvider: pane.readMouseTracking,
              mouseCursorNameProvider: pane.readMouseCursorShape,
              copyOnSelectProvider: _readCopyOnSelect,
              macosOptionAsAlt: widget.workspace.preferences.macosOptionAsAlt,
              metaKeyPolicy: _shortcutDispatcher.resolveMetaKeyPolicy(),
              fontSize: fontSize,
              fontFamily: castPrimaryFontFamily,
              fontFamilyFallback: castFallbackFontFamilies,
              backgroundColor: bgColor,
              foregroundColor: fgColor,
              backgroundOpacity: widget.workspace.backgroundOpacity,
              shaderController: widget.workspace.shaderController,
              shaderConfig: pane.resolveShaderConfig(
                widget.workspace.activeShaderConfig,
              ),
              maxAmbientFps: widget.workspace.maxShaderFps?.toDouble(),
              cliShaderRegistry: pane.cliShaderRegistry,
              gpuFrameWatchdog: pane.gpuFrameWatchdog,
              faintOpacity:
                  widget.workspace.workspaceSettings.themeSettings.faintOpacity,
              palette: theme,
              outOfBoundsDimColor: const Color(0x88000000),
              service: _terminalService,
              topVirtualRowProvider: pane.readTopVirtualRow,
              selectionEpochProvider: pane.readSelectionEpoch,
              virtualLineLookup: pane.lookupVirtualLine,
              onSelectionAutoScroll: pane.scrollLines,
              enableBuiltinSelection: true,
              enableBuiltinLinkOpen: true,
              linkLineLookup: pane.lookupLinkLine,
              hoveredLinkStyler: _styleHoveredRainbowLink,
              hoveredLinkAnimationInterval:
                  WorkspaceBufferCompositor.rainbowHoverTickInterval,
              searchHighlightsProvider: pane.readSearchHighlights,
              searchHighlightsListenable: pane.searchHighlightsListenable,
              searchMatchColor: Color(theme.resolveAnsi256(4).argb),
              activeSearchMatchColor: Color(theme.resolveAnsi256(3).argb),
              enableHostShortcuts: true,
              alignment: Alignment.topLeft,
              onViewportSizeChanged: pane.updateViewportSize,
              onInputEvent: (event) => _handlePaneInputEvent(pane, event),
              onTextInput: pane.sendCommittedText,
              onHostShortcut: _shortcutDispatcher.handleHostShortcut,
              onFocusChanged: (hasFocus) {
                if (hasFocus) widget.workspace.focusPane(pane.paneId);
              },
            ),
          ),
          _buildPaneCornerPill(pane, tab, theme),
        ],
      ),
    );

    if (!showFocusBorder) {
      return SizedBox.expand(
        key: ValueKey('pane-leaf-${pane.paneId}'),
        child: surface,
      );
    }
    return Container(
      key: ValueKey('pane-leaf-${pane.paneId}'),
      decoration: BoxDecoration(
        border: Border.all(color: borderColor, width: 1.0),
      ),
      child: surface,
    );
  }

  static void _styleHoveredRainbowLink(
    ResolvedTerminalLink _,
    int cellCount,
    DateTime timestamp,
    HoveredLinkCellStyles styles,
  ) {
    styles.fillBackground(WorkspaceBufferCompositor.rainbowLinkBackgroundArgb);
    styles.fillModifiers(WorkspaceBufferCompositor.rainbowLinkModifiers);
    styles.underlineMatchesForeground = true;
    final phaseHue = WorkspaceBufferCompositor.rainbowPhaseHueAt(
      timestamp.millisecondsSinceEpoch,
    );
    for (var i = 0; i < cellCount; i++) {
      styles.setForeground(
        i,
        WorkspaceBufferCompositor.rainbowLinkForegroundAtPhase(i, phaseHue),
      );
    }
  }

  Widget _buildPaneCornerPill(
    FtermPaneController pane,
    FtermTabState tab,
    tui.TerminalColorTheme theme,
  ) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.workspace.chromeNotifier,
      pane.pillNotifier,
    ]),
    builder: (_, _) {
      final labels = _collectPaneCornerLabels(pane, tab);
      if (labels.isEmpty) return const SizedBox.shrink();

      final fg = Color(theme.foreground.argb);
      final bg = Color(theme.background.argb);
      return Positioned(
        top: 6,
        right: 8,
        child: IgnorePointer(
          child: Container(
            key: ValueKey('pane-pill-${pane.paneId}'),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Color.lerp(bg, fg, 0.14)!.withValues(alpha: 0.88),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: fg.withValues(alpha: 0.2)),
            ),
            child: Text(
              labels.join(' · '),
              style: TextStyle(
                color: fg,
                fontSize: 10,
                fontFamily: castPrimaryFontFamily,
              ),
            ),
          ),
        ),
      );
    },
  );

  List<String> _collectPaneCornerLabels(
    FtermPaneController pane,
    FtermTabState tab,
  ) {
    final shareLabel = _formatPaneShareLabel(pane);
    final showUpdatePill =
        !_isWeb &&
        !widget.workspace.shouldShowTabBar &&
        pane.paneId == tab.splitTree.focusedPaneId;
    final updateLabel = showUpdatePill
        ? widget.workspace.updateViewModel.cornerPillLabel
        : null;
    return [
      ?updateLabel,
      if (tab.splitTree.zoomedPaneId == pane.paneId) 'ZOOM',
      ?shareLabel,
      if (pane.scrollOffsetLines > 0) '+${pane.scrollOffsetLines}',
      if (pane.hasExited) '💀 ${pane.exitStatus ?? 0}',
    ];
  }

  String? _formatPaneShareLabel(FtermPaneController pane) {
    final share = pane.shareSnapshot;
    if (pane.isLocal && share.state != LocalShareState.unshared) {
      return switch (share.state) {
        LocalShareState.live => 'LIVE • ${share.subscriberCount}v',
        LocalShareState.connecting =>
          share.errorMessage != null ? 'SHARING (RETRY)' : 'SHARING...',
        LocalShareState.error => 'SHARE ERR',
        LocalShareState.unshared => null,
      };
    }
    final remoteId = pane.remoteSessionId;
    if (remoteId != null) {
      final count = widget.workspace.subscriberCountFor(remoteId);
      if (count > 1) return '${count}v';
    }
    return null;
  }

  Widget _buildMacOsSafeDragRow({Key? key}) => SizedBox(
    key: key,
    height: tabBarHeight,
    child: Row(
      children: [
        const SizedBox(width: macOsTrafficLightInset),
        Expanded(
          child: _WindowDragStrip(
            key: const ValueKey('fterm-window-drag-strip'),
            enableMacOsDrag: true,
            windowChannel: _windowChannel,
          ),
        ),
      ],
    ),
  );

  Widget _buildTopTabBar(tui.TerminalColorTheme theme) => ListenableBuilder(
    listenable: widget.workspace.chromeNotifier,
    builder: (_, _) {
      final bg = _chromeBackground(theme);
      final fg = Color(theme.foreground.argb);
      final border = fg.withValues(alpha: 0.14);
      final isMacOsDesktop = !_isWeb && _platform == TargetPlatform.macOS;
      final panes = widget.workspace.panes;
      final editorPanes = widget.workspace.editorPanes;

      return Container(
        key: const ValueKey('fterm-tab-bar-top'),
        height: tabBarHeight,
        decoration: BoxDecoration(
          color: bg,
          border: Border(bottom: BorderSide(color: border, width: 1)),
        ),
        child: LayoutBuilder(
          builder: (_, barConstraints) {
            final compactWhatsNew = barConstraints.maxWidth < 420.0;
            return Row(
              children: [
                if (isMacOsDesktop)
                  const SizedBox(
                    key: ValueKey('fterm-macos-inset'),
                    width: macOsTrafficLightInset,
                  ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (_, constraints) {
                      final maxTabsWidth = math.max(
                        0.0,
                        constraints.maxWidth - 48.0,
                      );
                      return Row(
                        children: [
                          ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: maxTabsWidth),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  for (
                                    var i = 0;
                                    i < widget.workspace.tabs.length;
                                    i++
                                  )
                                    _buildHorizontalTabChip(
                                      index: i,
                                      tab: widget.workspace.tabs[i],
                                      panes: panes,
                                      editorPanes: editorPanes,
                                      theme: theme,
                                    ),
                                ],
                              ),
                            ),
                          ),
                          Expanded(
                            child: _WindowDragStrip(
                              key: const ValueKey('fterm-window-drag-strip'),
                              enableMacOsDrag: isMacOsDesktop,
                              windowChannel: _windowChannel,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                ..._buildChromeActionControls(
                  theme,
                  compactWhatsNew: compactWhatsNew,
                ),
              ],
            );
          },
        ),
      );
    },
  );

  Widget _buildLeftTabRail(tui.TerminalColorTheme theme) => ListenableBuilder(
    listenable: widget.workspace.chromeNotifier,
    builder: (_, _) {
      final bg = _chromeBackground(theme);
      final fg = Color(theme.foreground.argb);
      final border = fg.withValues(alpha: 0.14);
      final isMacOsDesktop = !_isWeb && _platform == TargetPlatform.macOS;
      final panes = widget.workspace.panes;
      final editorPanes = widget.workspace.editorPanes;

      return Container(
        key: const ValueKey('fterm-tab-bar-left'),
        width: leftRailWidth,
        decoration: BoxDecoration(
          color: bg,
          border: Border(right: BorderSide(color: border, width: 1)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (isMacOsDesktop)
              _buildMacOsSafeDragRow(
                key: const ValueKey('fterm-macos-inset-top'),
              ),
            Expanded(
              child: ListView.builder(
                itemCount: widget.workspace.tabs.length,
                itemBuilder: (_, i) => _buildVerticalTabTile(
                  index: i,
                  tab: widget.workspace.tabs[i],
                  panes: panes,
                  editorPanes: editorPanes,
                  theme: theme,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Wrap(
                spacing: 2,
                children: _buildChromeActionControls(
                  theme,
                  compactWhatsNew: true,
                ),
              ),
            ),
          ],
        ),
      );
    },
  );

  List<Widget> _buildTabStatusBadges(
    tui.TerminalColorTheme theme, {
    required String tabId,
    required bool shared,
    required bool exited,
    required bool dirtyEditor,
  }) => [
    if (dirtyEditor)
      Padding(
        padding: const EdgeInsets.only(right: 5),
        child: Container(
          key: ValueKey('fterm-tab-dirty-dot-$tabId'),
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: Color(theme.resolveAnsi256(3).argb),
            shape: BoxShape.circle,
          ),
        ),
      ),
    if (shared)
      Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Icon(
          Icons.wifi_tethering,
          size: 11,
          color: Color(theme.resolveAnsi256(2).argb),
        ),
      ),
    if (exited)
      const Padding(
        padding: EdgeInsets.only(right: 4),
        child: Text('💀', style: TextStyle(fontSize: 10)),
      ),
  ];

  Color _resolveTabBackground(
    tui.TerminalColorTheme theme, {
    required bool selected,
    required bool dirtyEditor,
  }) {
    final activeBg = Color(theme.background.argb);
    if (!dirtyEditor) {
      return selected ? activeBg : Colors.transparent;
    }
    final warning = Color(theme.resolveAnsi256(3).argb);
    return selected
        ? Color.lerp(activeBg, warning, 0.16)!
        : warning.withValues(alpha: 0.14);
  }

  Widget _buildHorizontalTabChip({
    required int index,
    required FtermTabState tab,
    required Map<String, FtermPaneController> panes,
    required Map<String, ShaderEditorPane> editorPanes,
    required tui.TerminalColorTheme theme,
  }) {
    final selected = index == widget.workspace.activeTabIndex;
    final fg = Color(theme.foreground.argb);
    final warning = Color(theme.resolveAnsi256(3).argb);
    final title = tab.resolveTitle(panes, editorPanes: editorPanes);
    final exited = tab.isExited(panes, editorPanes: editorPanes);
    final shared = tab.isShared(panes);
    final dirtyEditor = widget.workspace.tabHasDirtyShaderEditor(tab);
    final chipBg = _resolveTabBackground(
      theme,
      selected: selected,
      dirtyEditor: dirtyEditor,
    );

    return GestureDetector(
      key: ValueKey('fterm-tab-${tab.tabId}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _handleTabTap(index, tab.tabId),
      onSecondaryTapDown: (details) =>
          unawaited(_showTabContextMenu(details.globalPosition, index, tab)),
      child: Container(
        height: tabBarHeight,
        constraints: const BoxConstraints(minWidth: 72, maxWidth: 180),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: chipBg,
          border: Border(
            right: BorderSide(color: fg.withValues(alpha: 0.12), width: 1),
            bottom: dirtyEditor
                ? BorderSide(color: warning, width: 2)
                : BorderSide.none,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ..._buildTabStatusBadges(
              theme,
              tabId: tab.tabId,
              shared: shared,
              exited: exited,
              dirtyEditor: dirtyEditor,
            ),
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: dirtyEditor
                      ? warning
                      : (selected ? fg : fg.withValues(alpha: 0.68)),
                  fontSize: 11,
                  fontWeight: (selected || dirtyEditor)
                      ? FontWeight.w600
                      : FontWeight.normal,
                  fontFamily: castPrimaryFontFamily,
                ),
              ),
            ),
            if (tab.unreadBellCount > 0)
              Container(
                key: ValueKey('fterm-tab-bell-${tab.tabId}'),
                margin: const EdgeInsets.only(left: 5),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Color(theme.resolveAnsi256(3).argb),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${tab.unreadBellCount}',
                  style: TextStyle(
                    color: Color(theme.background.argb),
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            const SizedBox(width: 4),
            InkWell(
              key: ValueKey('fterm-tab-close-${tab.tabId}'),
              onTap: () => unawaited(widget.workspace.closeTab(index)),
              child: Icon(
                Icons.close,
                size: 12,
                color: fg.withValues(alpha: 0.55),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVerticalTabTile({
    required int index,
    required FtermTabState tab,
    required Map<String, FtermPaneController> panes,
    required Map<String, ShaderEditorPane> editorPanes,
    required tui.TerminalColorTheme theme,
  }) {
    final selected = index == widget.workspace.activeTabIndex;
    final fg = Color(theme.foreground.argb);
    final warning = Color(theme.resolveAnsi256(3).argb);
    final title = tab.resolveTitle(panes, editorPanes: editorPanes);
    final exited = tab.isExited(panes, editorPanes: editorPanes);
    final shared = tab.isShared(panes);
    final dirtyEditor = widget.workspace.tabHasDirtyShaderEditor(tab);
    final tileBg = _resolveTabBackground(
      theme,
      selected: selected,
      dirtyEditor: dirtyEditor,
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: (details) =>
          unawaited(_showTabContextMenu(details.globalPosition, index, tab)),
      child: InkWell(
        key: ValueKey('fterm-tab-${tab.tabId}'),
        onTap: () => _handleTabTap(index, tab.tabId),
        child: Container(
          height: tabBarHeight,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: tileBg,
            border: dirtyEditor
                ? Border(left: BorderSide(color: warning, width: 2.5))
                : null,
          ),
          child: Row(
            children: [
              ..._buildTabStatusBadges(
                theme,
                tabId: tab.tabId,
                shared: shared,
                exited: exited,
                dirtyEditor: dirtyEditor,
              ),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: dirtyEditor
                        ? warning
                        : (selected ? fg : fg.withValues(alpha: 0.7)),
                    fontSize: 11,
                    fontWeight: (selected || dirtyEditor)
                        ? FontWeight.w600
                        : FontWeight.normal,
                    fontFamily: castPrimaryFontFamily,
                  ),
                ),
              ),
              if (tab.unreadBellCount > 0)
                Container(
                  key: ValueKey('fterm-tab-bell-${tab.tabId}'),
                  margin: const EdgeInsets.only(right: 4),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: Color(theme.resolveAnsi256(3).argb),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${tab.unreadBellCount}',
                    style: TextStyle(
                      color: Color(theme.background.argb),
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              InkWell(
                key: ValueKey('fterm-tab-close-${tab.tabId}'),
                onTap: () => unawaited(widget.workspace.closeTab(index)),
                child: Icon(
                  Icons.close,
                  size: 12,
                  color: fg.withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  ShaderEditorPane? _findTabEditorPane(FtermTabState tab) {
    final focusedEditor = widget.workspace.shaderEditorPaneById(
      tab.splitTree.focusedPaneId,
    );
    if (focusedEditor != null) return focusedEditor;
    for (final paneId in tab.splitTree.paneIds) {
      final editor = widget.workspace.shaderEditorPaneById(paneId);
      if (editor != null) return editor;
    }
    return null;
  }

  Future<void> _showTabContextMenu(
    Offset globalPosition,
    int index,
    FtermTabState tab,
  ) async {
    final overlayObj = Overlay.maybeOf(context)?.context.findRenderObject();
    if (overlayObj is! RenderBox) return;
    final tabId = tab.tabId;
    final editorPane = _findTabEditorPane(tab);
    final editorPaneId = editorPane?.paneId;
    final action = await showMenu<_TabContextAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
        Offset.zero & overlayObj.size,
      ),
      items: _buildTabContextMenuItems(editorPane),
    );
    if (!mounted || action == null) return;
    final liveIndex = widget.workspace.tabs.indexWhere((t) => t.tabId == tabId);
    if (liveIndex < 0) return;
    final liveEditor = editorPaneId == null
        ? null
        : widget.workspace.shaderEditorPaneById(editorPaneId);
    _applyTabContextAction(action, index: liveIndex, editorPane: liveEditor);
  }

  List<PopupMenuEntry<_TabContextAction>> _buildTabContextMenuItems(
    ShaderEditorPane? editorPane,
  ) {
    final items = <PopupMenuEntry<_TabContextAction>>[];
    if (editorPane != null) {
      final isMacOs =
          (widget.platformOverride ?? defaultTargetPlatform) ==
          TargetPlatform.macOS;
      final saveShortcut = isMacOs ? 'Cmd+S' : 'Alt+S';
      final saveAsShortcut = isMacOs ? 'Cmd+Shift+S' : 'Alt+Shift+S';
      final ctrl = editorPane.controller;
      final previewActive = ctrl.previewMode != ShaderEditorPreviewMode.off;
      final isSolo =
          previewActive &&
          ctrl.chainComposition == ShaderEditorChainComposition.solo;
      final isBlend =
          previewActive &&
          ctrl.chainComposition ==
              ShaderEditorChainComposition.blendWithWorkspace;
      items.addAll(<PopupMenuEntry<_TabContextAction>>[
        PopupMenuItem<_TabContextAction>(
          key: const ValueKey('tab-menu-save-shader'),
          value: _TabContextAction.saveShader,
          child: Text('Save Shader ($saveShortcut)'),
        ),
        PopupMenuItem<_TabContextAction>(
          key: const ValueKey('tab-menu-save-shader-as'),
          value: _TabContextAction.saveShaderAs,
          child: Text('Save Shader As... ($saveAsShortcut)'),
        ),
        const PopupMenuDivider(),
        CheckedPopupMenuItem<_TabContextAction>(
          key: const ValueKey('tab-menu-preview-solo'),
          value: _TabContextAction.previewSolo,
          checked: isSolo,
          child: const Text('Preview: Solo'),
        ),
        CheckedPopupMenuItem<_TabContextAction>(
          key: const ValueKey('tab-menu-preview-blend'),
          value: _TabContextAction.previewBlend,
          checked: isBlend,
          child: const Text('Preview: Blend with Workspace'),
        ),
        CheckedPopupMenuItem<_TabContextAction>(
          key: const ValueKey('tab-menu-preview-off'),
          value: _TabContextAction.previewOff,
          checked: !previewActive,
          child: const Text('Preview: Off'),
        ),
        const PopupMenuDivider(),
      ]);
    }
    items.addAll(const <PopupMenuEntry<_TabContextAction>>[
      PopupMenuItem<_TabContextAction>(
        key: ValueKey('tab-menu-rename'),
        value: _TabContextAction.renameTab,
        child: Text('Rename Tab'),
      ),
      PopupMenuItem<_TabContextAction>(
        key: ValueKey('tab-menu-close'),
        value: _TabContextAction.closeTab,
        child: Text('Close Tab'),
      ),
    ]);
    return items;
  }

  void _applyTabContextAction(
    _TabContextAction action, {
    required int index,
    required ShaderEditorPane? editorPane,
  }) {
    switch (action) {
      case _TabContextAction.saveShader:
        if (editorPane != null) {
          unawaited(widget.workspace.saveShaderEditorPane(editorPane.paneId));
        }
      case _TabContextAction.saveShaderAs:
        if (editorPane != null) {
          widget.workspace.selectTab(index);
          widget.workspace.focusPane(editorPane.paneId);
          editorPane.controller.beginSaveAs();
        }
      case _TabContextAction.previewSolo:
        if (editorPane != null) {
          _activateEditorPreviewComposition(
            editorPane,
            ShaderEditorChainComposition.solo,
          );
        }
      case _TabContextAction.previewBlend:
        if (editorPane != null) {
          _activateEditorPreviewComposition(
            editorPane,
            ShaderEditorChainComposition.blendWithWorkspace,
          );
        }
      case _TabContextAction.previewOff:
        editorPane?.controller.setPreviewMode(ShaderEditorPreviewMode.off);
      case _TabContextAction.renameTab:
        widget.workspace.selectTab(index);
        widget.workspace.setOverlay(FtermOverlay.rename);
      case _TabContextAction.closeTab:
        unawaited(widget.workspace.closeTab(index));
    }
  }

  void _activateEditorPreviewComposition(
    ShaderEditorPane editorPane,
    ShaderEditorChainComposition composition,
  ) {
    final ctrl = editorPane.controller;
    ctrl.setChainComposition(composition);
    if (ctrl.previewMode == ShaderEditorPreviewMode.off) {
      final targetMode = ctrl.detectedStageHint == ShaderStageHint.foreground
          ? ShaderEditorPreviewMode.foreground
          : ShaderEditorPreviewMode.background;
      ctrl.setPreviewMode(targetMode);
    }
  }

  void _handleTabTap(int index, String tabId) {
    final now = widget.workspace.workspaceClock.now();
    final isDoubleTap =
        _lastTabTapId == tabId &&
        _lastTabTapAt != null &&
        now.difference(_lastTabTapAt!) <= const Duration(milliseconds: 300);
    _lastTabTapId = tabId;
    _lastTabTapAt = now;
    widget.workspace.selectTab(index);
    if (isDoubleTap) {
      _lastTabTapAt = null;
      widget.workspace.setOverlay(FtermOverlay.rename);
    }
  }

  List<Widget> _buildChromeActionControls(
    tui.TerminalColorTheme theme, {
    bool compactWhatsNew = false,
  }) {
    final fg = Color(theme.foreground.argb);
    final focused = widget.workspace.focusedPane;
    final muted = widget.workspace.audioController.muted;

    return [
      if (widget.workspace.isLeaderArmed) _buildLeaderBadge(theme),
      if (widget.workspace.automationDriver.isRunning)
        _buildAutomationActiveIndicator(theme),
      if (widget.workspace.shouldShowWhatsNewPill)
        _buildWhatsNewPill(theme, compact: compactWhatsNew),
      _buildConnectActionButton(theme),
      _buildSessionsActionButton(theme),
      if (focused != null && focused.isLocal)
        _buildShareActionButton(focused, theme),
      _chromeIconButton(
        key: const ValueKey('fterm-new-tab-button'),
        tooltip: widget.workspace.isDesktopHost
            ? 'New local shell'
            : 'Sessions & relay',
        icon: Icons.add,
        color: fg.withValues(alpha: 0.75),
        onTap: _onNewTabActionPressed,
      ),
      _chromeIconButton(
        key: const ValueKey('fterm-mute-toggle'),
        tooltip: muted ? 'Unmute audio' : 'Mute audio',
        icon: muted ? Icons.volume_off : Icons.volume_up,
        color: fg.withValues(alpha: 0.72),
        onTap: () => widget.workspace.updatePreferences(
          widget.workspace.preferences.copyWith(audioMuted: !muted),
        ),
      ),
      _chromeIconButton(
        key: const ValueKey('fterm-command-palette-button'),
        tooltip: _isWeb
            ? r'Command Palette (Ctrl+\ Shift+P)'
            : (_platform == TargetPlatform.macOS
                  ? 'Command Palette (Cmd+Shift+P)'
                  : 'Command Palette (Ctrl+Shift+P)'),
        icon: Icons.manage_search,
        color: fg.withValues(alpha: 0.72),
        onTap: () => widget.workspace.openCommandPalette(initialInput: '>'),
      ),
      _buildSettingsActionButton(theme),
      _chromeIconButton(
        key: const ValueKey('fterm-help-button'),
        tooltip: 'Shortcuts (Ctrl+\\ ?)',
        icon: Icons.help_outline,
        color: fg.withValues(alpha: 0.72),
        onTap: () => widget.workspace.setOverlay(FtermOverlay.help),
      ),
      _chromeIconButton(
        key: const ValueKey('fterm-feedback-button'),
        tooltip: 'Send feedback / Report issue',
        icon: Icons.feedback_outlined,
        color: fg.withValues(alpha: 0.72),
        onTap: () => widget.workspace.setOverlay(FtermOverlay.feedback),
      ),
      _chromeIconButton(
        key: const ValueKey('fterm-about-button'),
        tooltip: 'About fterm (Ctrl+\\ a)',
        icon: Icons.info_outline,
        color: fg.withValues(alpha: 0.72),
        onTap: () => widget.workspace.setOverlay(FtermOverlay.about),
      ),
    ];
  }

  Widget _buildAutomationActiveIndicator(tui.TerminalColorTheme theme) =>
      _AutomationActiveIndicator(
        driver: widget.workspace.automationDriver,
        theme: theme,
        height: tabBarHeight,
        onTap: () =>
            widget.workspace.openSettingsOverlay(initialSection: .automation),
      );

  Widget _buildWhatsNewPill(
    tui.TerminalColorTheme theme, {
    required bool compact,
  }) {
    final accent = Color(theme.resolveAnsi256(4).argb);
    final tooltip = "What's New in v${widget.workspace.currentWhatsNewVersion}";
    if (compact) {
      return Tooltip(
        message: tooltip,
        child: InkWell(
          key: const ValueKey('fterm-whats-new-pill'),
          borderRadius: BorderRadius.circular(10),
          onTap: widget.workspace.openWhatsNew,
          child: SizedBox(
            width: 24,
            height: tabBarHeight,
            child: Center(
              child: Container(
                width: 20,
                height: 18,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: accent.withValues(alpha: 0.55)),
                ),
                child: Icon(Icons.auto_awesome, size: 11, color: accent),
              ),
            ),
          ),
        ),
      );
    }
    return Tooltip(
      message: tooltip,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: InkWell(
            key: const ValueKey('fterm-whats-new-pill'),
            borderRadius: BorderRadius.circular(10),
            onTap: widget.workspace.openWhatsNew,
            child: Container(
              height: 19,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: accent.withValues(alpha: 0.55)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.auto_awesome, size: 11, color: accent),
                  const SizedBox(width: 3),
                  Text(
                    'NEW',
                    style: TextStyle(
                      color: accent,
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      fontFamily: castPrimaryFontFamily,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsActionButton(tui.TerminalColorTheme theme) {
    final fg = Color(theme.foreground.argb);
    final showBadge =
        !_isWeb && widget.workspace.updateViewModel.hasActionableUpdate;
    final accent = Color(theme.resolveAnsi256(4).argb);
    return Tooltip(
      message: showBadge
          ? 'Settings — update available (Ctrl+\\ ,)'
          : 'Settings (Ctrl+\\ ,)',
      child: InkWell(
        key: const ValueKey('fterm-settings-button'),
        onTap: () => widget.workspace.setOverlay(FtermOverlay.settings),
        child: SizedBox(
          width: 24,
          height: tabBarHeight,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(Icons.tune, size: 14, color: fg.withValues(alpha: 0.72)),
              if (showBadge)
                Positioned(
                  right: 3,
                  top: 5,
                  child: Container(
                    key: const ValueKey('fterm-settings-update-dot'),
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLeaderBadge(tui.TerminalColorTheme theme) => Container(
    key: const ValueKey('fterm-leader-badge'),
    margin: const EdgeInsets.symmetric(horizontal: 4),
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
    decoration: BoxDecoration(
      color: Color(theme.resolveAnsi256(4).argb),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      r'^\',
      style: TextStyle(
        color: Color(theme.background.argb),
        fontSize: 10,
        fontWeight: FontWeight.bold,
      ),
    ),
  );

  Widget _buildConnectActionButton(tui.TerminalColorTheme theme) {
    final fg = Color(theme.foreground.argb);
    final (icon, color, tooltip) = switch (widget.workspace.connectionState) {
      ClientConnectionState.authenticated => (
        Icons.cloud_done_outlined,
        Color(theme.resolveAnsi256(2).argb),
        'Relay connected — configure (Ctrl+\\ c)',
      ),
      ClientConnectionState.connecting ||
      ClientConnectionState.reconnecting => (
        Icons.cloud_sync_outlined,
        Color(theme.resolveAnsi256(3).argb),
        'Relay connecting — configure (Ctrl+\\ c)',
      ),
      ClientConnectionState.authFailed => (
        Icons.cloud_off_outlined,
        Color(theme.resolveAnsi256(1).argb),
        'Relay authentication failed — configure (Ctrl+\\ c)',
      ),
      ClientConnectionState.unconnected => (
        Icons.cloud_outlined,
        fg.withValues(alpha: 0.72),
        'Relay connection settings (Ctrl+\\ c)',
      ),
    };
    return _chromeIconButton(
      key: const ValueKey('fterm-connect-button'),
      tooltip: tooltip,
      icon: icon,
      color: color,
      onTap: () => widget.workspace.setOverlay(FtermOverlay.connect),
    );
  }

  Widget _buildSessionsActionButton(tui.TerminalColorTheme theme) {
    final fg = Color(theme.foreground.argb);
    final count = widget.workspace.availableRemoteSessions.length;
    final hasSessions = count > 0;
    final color = hasSessions
        ? Color(theme.resolveAnsi256(2).argb)
        : fg.withValues(alpha: 0.72);
    final tooltip = hasSessions
        ? 'Remote sessions ($count) (Ctrl+\\ c)'
        : 'Sessions & shells (Ctrl+\\ c)';

    return Tooltip(
      message: tooltip,
      child: InkWell(
        key: const ValueKey('fterm-sessions-button'),
        onTap: () => widget.workspace.setOverlay(FtermOverlay.sessionPicker),
        child: SizedBox(
          width: hasSessions ? 30 : 24,
          height: tabBarHeight,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(Icons.dns_outlined, size: 14, color: color),
              if (hasSessions)
                Positioned(
                  right: 1,
                  top: 3,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      count > 9 ? '9+' : '$count',
                      style: TextStyle(
                        color: Color(theme.background.argb),
                        fontSize: 8,
                        fontWeight: FontWeight.bold,
                        height: 1.1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildShareActionButton(
    FtermPaneController focused,
    tui.TerminalColorTheme theme,
  ) {
    final fg = Color(theme.foreground.argb);
    final share = focused.shareSnapshot;
    final (icon, color, tooltip) = switch (share.state) {
      LocalShareState.unshared => (
        Icons.cast,
        fg.withValues(alpha: 0.72),
        'Share local pane (Ctrl+\\ b)',
      ),
      LocalShareState.connecting => (
        Icons.cast_connected,
        Color(theme.resolveAnsi256(3).argb),
        share.errorMessage != null
            ? 'Share retrying (${share.errorMessage}) — click to stop'
            : 'Connecting share... — click to stop',
      ),
      LocalShareState.live => (
        Icons.cast_connected,
        Color(theme.resolveAnsi256(2).argb),
        'Stop sharing local pane (${share.subscriberCount} viewers) (Ctrl+\\ b)',
      ),
      LocalShareState.error => (
        Icons.cast_connected,
        Color(theme.resolveAnsi256(1).argb),
        share.errorMessage != null
            ? 'Share error (${share.errorMessage}) — click to retry'
            : 'Share failed — click to retry',
      ),
    };
    return _chromeIconButton(
      key: const ValueKey('fterm-share-toggle'),
      tooltip: tooltip,
      icon: icon,
      color: color,
      onTap: () => unawaited(widget.workspace.togglePaneShare()),
    );
  }

  void _onNewTabActionPressed() {
    if (widget.workspace.isDesktopHost) {
      unawaited(widget.workspace.openLocalShellTab());
      return;
    }
    widget.workspace.setOverlay(FtermOverlay.sessionPicker);
  }

  Widget _chromeIconButton({
    required Key key,
    required String tooltip,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) => Tooltip(
    message: tooltip,
    child: InkWell(
      key: key,
      onTap: onTap,
      child: SizedBox(
        width: 24,
        height: tabBarHeight,
        child: Icon(icon, size: 14, color: color),
      ),
    ),
  );

  Color _chromeBackground(tui.TerminalColorTheme theme) {
    final bg = Color(theme.background.argb);
    final isDark = theme.brightness == tui.TerminalBrightness.dark;
    return isDark
        ? Color.lerp(bg, const Color(0xFFFFFFFF), 0.05)!
        : Color.lerp(bg, const Color(0xFF000000), 0.05)!;
  }

  Widget _buildDragOverlay(tui.TerminalColorTheme theme) => IgnorePointer(
    child: Container(
      decoration: BoxDecoration(
        color: const Color(0xAA0D131F),
        border: Border.all(
          color: Color(theme.resolveAnsi256(2).argb),
          width: 2.0,
        ),
      ),
      padding: const EdgeInsets.all(24),
      child: const Center(
        child: Text(
          'Drop files to upload to remote host',
          style: TextStyle(
            color: Color(0xFFEAF2FF),
            fontSize: 16,
            fontWeight: FontWeight.bold,
            fontFamily: castPrimaryFontFamily,
          ),
        ),
      ),
    ),
  );
}

final class _WindowDragStrip extends StatelessWidget {
  final bool enableMacOsDrag;
  final MethodChannel windowChannel;

  const _WindowDragStrip({
    super.key,
    required this.enableMacOsDrag,
    required this.windowChannel,
  });

  @override
  Widget build(BuildContext context) {
    if (!enableMacOsDrag) {
      return const SizedBox(height: _FtermShellScaffoldState.tabBarHeight);
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => unawaited(
        windowChannel.invokeMethod<void>('startDrag').catchError((_) {}),
      ),
      onDoubleTap: () => unawaited(
        windowChannel.invokeMethod<void>('zoomWindow').catchError((_) {}),
      ),
      child: const SizedBox(height: _FtermShellScaffoldState.tabBarHeight),
    );
  }
}

final class _SplitTreeView extends StatelessWidget {
  static const double dividerThickness = 1.0;
  static const double dividerHitThickness = 6.0;

  final SplitTreeNode node;
  final FtermTabState tab;
  final FtermWorkspaceController workspace;
  final tui.TerminalColorTheme theme;
  final Widget Function(String paneId) buildLeaf;

  const _SplitTreeView({
    super.key,
    required this.node,
    required this.tab,
    required this.workspace,
    required this.theme,
    required this.buildLeaf,
  });

  @override
  Widget build(BuildContext context) {
    switch (node) {
      case PaneLeaf(:final paneId):
        return buildLeaf(paneId);
      case final SplitNode split:
        return LayoutBuilder(
          builder: (layoutContext, constraints) =>
              _buildSplitLayout(layoutContext, split, constraints),
        );
    }
  }

  Widget _buildSplitLayout(
    BuildContext context,
    SplitNode split,
    BoxConstraints constraints,
  ) {
    final isHoriz = split.axis == SplitAxis.horizontal;
    final totalSpan = isHoriz ? constraints.maxWidth : constraints.maxHeight;
    final usableSpan = math.max(0.0, totalSpan - dividerThickness);
    final rawDpr =
        MediaQuery.maybeDevicePixelRatioOf(context) ??
        View.maybeOf(context)?.devicePixelRatio ??
        1.0;
    final dpr = rawDpr.isFinite && rawDpr > 0 ? rawDpr : 1.0;
    final rawFirstSpan = (usableSpan * split.ratio).clamp(0.0, usableSpan);
    final firstSpan = ((rawFirstSpan * dpr).roundToDouble() / dpr).clamp(
      0.0,
      usableSpan,
    );
    final dividerColor = Color(theme.foreground.argb).withValues(alpha: 0.22);

    final firstChild = _SplitTreeView(
      node: split.first,
      tab: tab,
      workspace: workspace,
      theme: theme,
      buildLeaf: buildLeaf,
    );
    final secondChild = _SplitTreeView(
      node: split.second,
      tab: tab,
      workspace: workspace,
      theme: theme,
      buildLeaf: buildLeaf,
    );
    final visualSpacer = SizedBox(
      width: isHoriz ? dividerThickness : null,
      height: isHoriz ? null : dividerThickness,
    );
    final layout = isHoriz
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: firstSpan, child: firstChild),
              visualSpacer,
              Expanded(child: secondChild),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: firstSpan, child: firstChild),
              visualSpacer,
              Expanded(child: secondChild),
            ],
          );

    final hitOffset =
        firstSpan - (dividerHitThickness - dividerThickness) * 0.5;
    final handle = _SplitDragHandle(
      key: ValueKey('splitter-hit-${split.splitId}'),
      splitId: split.splitId,
      axis: split.axis,
      color: dividerColor,
      ratio: split.ratio,
      usableSpan: usableSpan,
      onRatioChanged: (ratio) => workspace.setSplitRatio(split.splitId, ratio),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        layout,
        if (isHoriz)
          Positioned(
            left: hitOffset,
            top: 0,
            bottom: 0,
            width: dividerHitThickness,
            child: handle,
          )
        else
          Positioned(
            top: hitOffset,
            left: 0,
            right: 0,
            height: dividerHitThickness,
            child: handle,
          ),
      ],
    );
  }
}

final class _SplitDragHandle extends StatefulWidget {
  final String splitId;
  final SplitAxis axis;
  final Color color;
  final double ratio;
  final double usableSpan;
  final void Function(double nextRatio) onRatioChanged;

  const _SplitDragHandle({
    super.key,
    required this.splitId,
    required this.axis,
    required this.color,
    required this.ratio,
    required this.usableSpan,
    required this.onRatioChanged,
  });

  @override
  State<_SplitDragHandle> createState() => _SplitDragHandleState();
}

final class _SplitDragHandleState extends State<_SplitDragHandle> {
  double? _dragStartRatio;
  double _dragDeltaPx = 0.0;

  void _startDrag(DragStartDetails _) {
    _dragStartRatio = widget.ratio;
    _dragDeltaPx = 0.0;
  }

  void _updateDrag(double deltaPx) {
    if (widget.usableSpan <= 0) return;
    final startRatio = _dragStartRatio ?? widget.ratio;
    _dragDeltaPx += deltaPx;
    final nextRatio =
        ((widget.usableSpan * startRatio) + _dragDeltaPx) / widget.usableSpan;
    widget.onRatioChanged(nextRatio);
  }

  void _endDrag([Object? _]) {
    _dragStartRatio = null;
    _dragDeltaPx = 0.0;
  }

  @override
  Widget build(BuildContext context) {
    final isHoriz = widget.axis == SplitAxis.horizontal;
    return MouseRegion(
      cursor: isHoriz
          ? SystemMouseCursors.resizeLeftRight
          : SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: isHoriz ? _startDrag : null,
        onHorizontalDragUpdate: isHoriz ? (d) => _updateDrag(d.delta.dx) : null,
        onHorizontalDragEnd: isHoriz ? _endDrag : null,
        onHorizontalDragCancel: isHoriz ? _endDrag : null,
        onVerticalDragStart: !isHoriz ? _startDrag : null,
        onVerticalDragUpdate: !isHoriz ? (d) => _updateDrag(d.delta.dy) : null,
        onVerticalDragEnd: !isHoriz ? _endDrag : null,
        onVerticalDragCancel: !isHoriz ? _endDrag : null,
        child: Center(
          child: SizedBox(
            key: ValueKey('splitter-${widget.splitId}'),
            width: isHoriz ? _SplitTreeView.dividerThickness : double.infinity,
            height: isHoriz ? double.infinity : _SplitTreeView.dividerThickness,
            child: ColoredBox(color: widget.color),
          ),
        ),
      ),
    );
  }
}

final class _FtermTerminalService implements TerminalService {
  final UrlOpener onOpenUrl;

  const _FtermTerminalService({required this.onOpenUrl});

  @override
  Future<String?> saveScreenshot(String basename, Uint8List bytes) =>
      const DefaultTerminalService().saveScreenshot(basename, bytes);

  @override
  Future<void> setClipboard(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  @override
  Future<String?> getClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }

  @override
  Future<bool> openUrl(String url) async {
    final parsed = Uri.tryParse(url);
    if (parsed == null) return false;
    onOpenUrl(parsed);
    return true;
  }
}

final class _CliShaderApprovalBannerHost extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final tui.TerminalColorTheme theme;
  final double topOffset;

  const _CliShaderApprovalBannerHost({
    required this.workspace,
    required this.theme,
    required this.topOffset,
  });

  @override
  Widget build(BuildContext context) {
    final approvals = workspace.pendingCliShaderApprovals;
    final conflict = workspace.activeCliFullPaneConflict;
    final blockedRemote = workspace.activeBlockedRemoteShadersNotice;
    if (approvals.isEmpty && conflict == null && blockedRemote == null) {
      return const SizedBox.shrink();
    }
    final Widget banner;
    if (approvals.isNotEmpty) {
      banner = _CliShaderTrustBanner(
        workspace: workspace,
        approval: approvals.first,
        queueLength: approvals.length,
        theme: theme,
      );
    } else if (conflict != null) {
      banner = _CliFullPaneConflictBanner(
        workspace: workspace,
        conflict: conflict,
        theme: theme,
      );
    } else {
      banner = _BlockedRemoteCliShadersBanner(
        workspace: workspace,
        notice: blockedRemote!,
        theme: theme,
      );
    }
    return Positioned(
      top: topOffset,
      left: 16,
      right: 16,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 740),
          child: banner,
        ),
      ),
    );
  }
}

final class _BlockedRemoteCliShadersBanner extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final PendingBlockedRemoteShadersNotice notice;
  final tui.TerminalColorTheme theme;

  const _BlockedRemoteCliShadersBanner({
    required this.workspace,
    required this.notice,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final fg = Color(theme.foreground.argb);
    final bg = Color(theme.background.argb);
    final accent = Color(theme.cursorColor.argb);
    final surfaceBg = Color.lerp(bg, fg, 0.14)!.withValues(alpha: 0.97);

    return Material(
      color: Colors.transparent,
      child: Container(
        key: const ValueKey('cli-remote-shaders-blocked-banner'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: surfaceBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: accent.withValues(alpha: 0.75), width: 1.5),
          boxShadow: const [
            BoxShadow(
              color: Color(0x88000000),
              blurRadius: 16,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome, size: 16, color: accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Remote session "${notice.paneLabel}" sent CLI shader effects',
                    style: TextStyle(
                      color: fg,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Remote CLI shaders are disabled by default. Enable built-in '
              'presets & cell transforms, or prompt before compiling custom GLSL.',
              style: TextStyle(color: fg.withValues(alpha: 0.82), fontSize: 12),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                TextButton(
                  key: const ValueKey('cli-remote-blocked-dismiss'),
                  onPressed: () => workspace.dismissBlockedRemoteShadersNotice(
                    notice.paneId,
                  ),
                  child: const Text('Dismiss'),
                ),
                OutlinedButton(
                  key: const ValueKey('cli-remote-enable-presets'),
                  onPressed: () => workspace.setRemoteCliShaderPolicy(
                    CliShaderPolicy.presetsAndTransforms,
                  ),
                  child: const Text('Enable Presets & Transforms'),
                ),
                FilledButton(
                  key: const ValueKey('cli-remote-enable-prompt-glsl'),
                  onPressed: () => workspace.setRemoteCliShaderPolicy(
                    CliShaderPolicy.promptCustomGlsl,
                  ),
                  child: const Text('Allow & Prompt Custom GLSL'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

final class _CliShaderTrustBanner extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final PendingCliShaderApproval approval;
  final int queueLength;
  final tui.TerminalColorTheme theme;

  const _CliShaderTrustBanner({
    required this.workspace,
    required this.approval,
    required this.queueLength,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final fg = Color(theme.foreground.argb);
    final bg = Color(theme.background.argb);
    final accent = Color(theme.cursorColor.argb);
    final shortHash = approval.sha256.length >= 16
        ? approval.sha256.substring(0, 16)
        : approval.sha256;
    final pinnedHash = approval.sha256;

    final surfaceBg = Color.lerp(bg, fg, 0.14)!.withValues(alpha: 0.97);
    final codeBg = bg.withValues(alpha: 0.92);

    return Material(
      color: Colors.transparent,
      child: Container(
        key: const ValueKey('cli-shader-approval-banner'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: surfaceBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: accent.withValues(alpha: 0.85), width: 1.5),
          boxShadow: const [
            BoxShadow(
              color: Color(0x88000000),
              blurRadius: 18,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome, size: 18, color: accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Approve Custom CLI GPU Shader "${approval.shaderId}"?',
                    style: TextStyle(
                      color: fg,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (queueLength > 1)
                  Text(
                    '1 of $queueLength pending',
                    key: const ValueKey('cli-shader-approval-queue-count'),
                    style: TextStyle(
                      color: fg.withValues(alpha: 0.78),
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Pane "${approval.paneLabel}" requested compiling a custom GLSL '
              'fragment shader (SHA-256: $shortHash…).',
              style: TextStyle(color: fg.withValues(alpha: 0.82), fontSize: 12),
            ),
            const SizedBox(height: 10),
            Container(
              constraints: const BoxConstraints(maxHeight: 160),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: codeBg,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: fg.withValues(alpha: 0.22)),
              ),
              child: SingleChildScrollView(
                child: Text(
                  approval.sourcePreview,
                  key: const ValueKey('cli-shader-approval-preview'),
                  style: TextStyle(
                    color: fg.withValues(alpha: 0.92),
                    fontFamily: castPrimaryFontFamily,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                TextButton(
                  key: const ValueKey('cli-shader-deny-all'),
                  onPressed: () =>
                      workspace.denyAllPendingCliShaders(approval.paneId),
                  child: const Text('Deny All'),
                ),
                OutlinedButton(
                  key: const ValueKey('cli-shader-deny'),
                  onPressed: () => workspace.denyCliShaderHash(pinnedHash),
                  child: const Text('Deny'),
                ),
                OutlinedButton(
                  key: const ValueKey('cli-shader-allow-once'),
                  onPressed: () => workspace.approveCliShaderHash(
                    pinnedHash,
                    remember: false,
                  ),
                  child: const Text('Allow Once'),
                ),
                FilledButton(
                  key: const ValueKey('cli-shader-trust-hash'),
                  onPressed: () => workspace.approveCliShaderHash(
                    pinnedHash,
                    remember: true,
                  ),
                  child: const Text('Always Trust Hash'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

final class _CliFullPaneConflictBanner extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final PendingCliFullPaneConflict conflict;
  final tui.TerminalColorTheme theme;

  const _CliFullPaneConflictBanner({
    required this.workspace,
    required this.conflict,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final fg = Color(theme.foreground.argb);
    final bg = Color(theme.background.argb);
    final accent = Color(theme.cursorColor.argb);
    return Material(
      color: Colors.transparent,
      child: Container(
        key: const ValueKey('cli-full-pane-conflict-banner'),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Color.lerp(bg, fg, 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: accent.withValues(alpha: 0.7)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Pane "${conflict.paneLabel}" requested full-pane shader '
              '"${conflict.shaderLabel}" while user shaders are active.',
              style: TextStyle(
                color: fg,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.end,
              children: [
                TextButton(
                  key: const ValueKey('cli-conflict-keep-user'),
                  onPressed: () => workspace.resolveCliFullPaneConflict(
                    conflict.paneId,
                    CliFullPaneConflictChoice.keepUserOnly,
                  ),
                  child: const Text('Keep User Only'),
                ),
                OutlinedButton(
                  key: const ValueKey('cli-conflict-cli-replaces'),
                  onPressed: () => workspace.resolveCliFullPaneConflict(
                    conflict.paneId,
                    CliFullPaneConflictChoice.cliReplacesUser,
                  ),
                  child: const Text('CLI Replaces User'),
                ),
                FilledButton(
                  key: const ValueKey('cli-conflict-cli-before'),
                  onPressed: () => workspace.resolveCliFullPaneConflict(
                    conflict.paneId,
                    CliFullPaneConflictChoice.cliBeforeUser,
                  ),
                  child: const Text('CLI Before User'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

final class _ShaderEmergencyStopPill extends StatelessWidget {
  final FtermWorkspaceController workspace;

  const _ShaderEmergencyStopPill({required this.workspace});

  @override
  Widget build(BuildContext context) {
    final reason = workspace.shaderEmergencyStopReason;
    final tooltip = reason == null
        ? 'All GPU shaders bypassed via Emergency Stop.'
        : 'Emergency Stop: $reason';
    return Positioned(
      bottom: 14,
      right: 14,
      child: Material(
        color: Colors.transparent,
        elevation: 12,
        borderRadius: BorderRadius.circular(20),
        child: Tooltip(
          message: tooltip,
          child: Container(
            key: const ValueKey('fterm-shader-estop-pill'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFB42318),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFFFE4E6), width: 1.5),
              boxShadow: const [
                BoxShadow(
                  color: Color(0xAA000000),
                  blurRadius: 14,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: Color(0xFFFFFFFF),
                ),
                const SizedBox(width: 6),
                const Text(
                  'Shaders Stopped (Ctrl+Shift+F6)',
                  style: TextStyle(
                    color: Color(0xFFFFFFFF),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    fontFamily: castPrimaryFontFamily,
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  key: const ValueKey('fterm-shader-estop-resume'),
                  borderRadius: BorderRadius.circular(12),
                  onTap: () =>
                      unawaited(workspace.resumeShadersFromEmergencyStop()),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFFFFF),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      'Resume',
                      style: TextStyle(
                        color: Color(0xFF912018),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        fontFamily: castPrimaryFontFamily,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _ScaffoldAutomationPointerDispatcher
    implements AutomationPointerDispatcher {
  final Map<String, GlobalKey<State<TerminalSurface>>> _surfaceKeys;
  final bool Function() _isMounted;

  const _ScaffoldAutomationPointerDispatcher({
    required this._surfaceKeys,
    required this._isMounted,
  });

  TerminalSurfaceState? _resolveSurface(String paneId) {
    if (!_isMounted()) return null;
    final state = _surfaceKeys[paneId]?.currentState;
    return state is TerminalSurfaceState ? state : null;
  }

  @override
  bool injectPointer({
    required String paneId,
    required double x,
    required double y,
    bool pressed = false,
  }) {
    final surface = _resolveSurface(paneId);
    if (surface == null) return false;
    surface.injectShaderPointerNormalized(x: x, y: y, pressed: pressed);
    return true;
  }

  @override
  bool clearPointer({required String paneId}) {
    final surface = _resolveSurface(paneId);
    if (surface == null) return false;
    surface.clearInjectedShaderPointer();
    return true;
  }
}

String _formatAutomationIndicatorTooltip(AutomationDriverViewModel driver) {
  final scope = driver.allowPty ? 'Base + PTY' : 'Base only';
  return 'Automation driver listening on 127.0.0.1:${driver.port} ($scope) '
      '— Open Automation settings';
}

Color _automationIndicatorDotColor(
  tui.TerminalColorTheme theme, {
  required bool allowPty,
}) => allowPty
    ? Color(theme.resolveAnsi256(3).argb)
    : Color(theme.resolveAnsi256(4).argb);

final class _AutomationActiveIndicator extends StatelessWidget {
  final AutomationDriverViewModel driver;
  final tui.TerminalColorTheme theme;
  final double height;
  final VoidCallback onTap;

  const _AutomationActiveIndicator({
    required this.driver,
    required this.theme,
    required this.height,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = Color(theme.foreground.argb);
    final dotColor = _automationIndicatorDotColor(
      theme,
      allowPty: driver.allowPty,
    );
    return Tooltip(
      message: _formatAutomationIndicatorTooltip(driver),
      child: InkWell(
        key: const ValueKey('fterm-automation-indicator'),
        onTap: onTap,
        child: SizedBox(
          width: 24,
          height: height,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                Icons.api_outlined,
                size: 14,
                color: fg.withValues(alpha: 0.72),
              ),
              Positioned(
                right: 3,
                top: 5,
                child: Container(
                  key: const ValueKey('fterm-automation-indicator-dot'),
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: dotColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _AutomationCornerPill extends StatelessWidget {
  final AutomationDriverViewModel driver;
  final tui.TerminalColorTheme theme;
  final double topOffset;
  final VoidCallback onTap;

  const _AutomationCornerPill({
    required this.driver,
    required this.theme,
    required this.topOffset,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = Color(theme.foreground.argb);
    final bg = Color(theme.background.argb);
    final dotColor = _automationIndicatorDotColor(
      theme,
      allowPty: driver.allowPty,
    );
    return Positioned(
      top: topOffset,
      right: 8,
      child: Material(
        color: Colors.transparent,
        child: Tooltip(
          message: _formatAutomationIndicatorTooltip(driver),
          child: InkWell(
            key: const ValueKey('fterm-automation-corner-pill'),
            borderRadius: BorderRadius.circular(4),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: Color.lerp(bg, fg, 0.14)!.withValues(alpha: 0.88),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: fg.withValues(alpha: 0.2)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.api_outlined,
                    size: 12,
                    color: fg.withValues(alpha: 0.78),
                  ),
                  const SizedBox(width: 4),
                  Container(
                    key: const ValueKey('fterm-automation-corner-pill-dot'),
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: dotColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
