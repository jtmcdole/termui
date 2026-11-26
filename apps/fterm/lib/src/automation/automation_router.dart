import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:termui/terminal/event.dart' as ev;
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart'
    show ThemeAppearanceMode;
import 'package:termui_flutter/termui_flutter.dart'
    show ShaderDiagnostic, TerminalShaderPreset;

import '../shader_editor/shader_editor_controller.dart';
import '../shader_editor/shader_editor_pane.dart';
import '../workspace/fterm_pane_controller.dart';
import '../workspace/fterm_workspace_controller.dart';
import '../workspace/local_host_driver.dart';
import '../workspace/split_tree_model.dart';
import 'automation_models.dart';
import 'automation_screen_search.dart';

/// Stateless HTTP `v1` route dispatcher binding loopback automation endpoints
/// to [FtermWorkspaceController], [AutomationWindowBridge], and mounted
/// `TerminalSurfaceState` pointer dispatch.
final class AutomationRouter {
  /// Maximum time [_defaultAwaitFrameSettle] waits for `endOfFrame`.
  static const Duration defaultFrameSettleTimeout = Duration(milliseconds: 150);

  /// Post-resize settle delay allowing [FtermPaneController]'s 32ms resize
  /// debounce to flush updated PTY dimensions before returning bounds.
  static const Duration defaultResizeSettleDelay = Duration(milliseconds: 48);

  static const int _maxScrollSteps = 20;

  static const Set<String> _knownPaths = <String>{
    '/v1/state',
    '/v1/window/bounds',
    '/v1/ui',
    '/v1/shader',
    '/v1/shader/editor',
    '/v1/tabs',
    '/v1/tabs/select',
    '/v1/tabs/close',
    '/v1/tabs/spawn',
    '/v1/pty/write',
    '/v1/screen',
    '/v1/screen/find',
    '/v1/input/pointer',
    '/v1/input/mouse',
  };

  final FtermWorkspaceController _workspace;
  final AutomationWindowBridge _windowBridge;
  final AutomationPointerDispatcher? Function() _readPointerDispatcher;
  final Future<void> Function() _awaitFrameSettle;
  final Duration _resizeSettleDelay;

  /// Creates an [AutomationRouter] bound to [FtermWorkspaceController] and
  /// [AutomationWindowBridge].
  ///
  /// Pass [awaitFrameSettle] in widget tests (for example `() async {}`) so
  /// `tester.runAsync` calls never block waiting on an unpumped frame.
  AutomationRouter({
    required this._workspace,
    required this._windowBridge,
    required this._readPointerDispatcher,
    Future<void> Function()? awaitFrameSettle,
    this._resizeSettleDelay = defaultResizeSettleDelay,
  }) : _awaitFrameSettle = awaitFrameSettle ?? _defaultAwaitFrameSettle;

  /// Routes an authenticated [request] to its corresponding `v1` handler.
  Future<AutomationHttpResponse> handleRequest(
    AutomationHttpRequest request,
  ) async {
    final path = _normalizePath(request.path);
    final body = request.body ?? const <String, Object?>{};
    return switch ((request.method, path)) {
      ('GET', '/v1/state') => _handleGetState(),
      ('GET', '/v1/window/bounds') => _handleGetWindowBounds(),
      ('POST', '/v1/window/bounds') => _handlePostWindowBounds(body),
      ('GET', '/v1/ui') => _handleGetUi(),
      ('POST', '/v1/ui') => _handlePostUi(body),
      ('GET', '/v1/shader') => _handleGetShader(),
      ('POST', '/v1/shader') => _handlePostShader(body),
      ('GET', '/v1/shader/editor') => _handleGetShaderEditor(),
      ('POST', '/v1/shader/editor') => _handlePostShaderEditor(body),
      ('GET', '/v1/tabs') => _handleGetTabs(),
      ('POST', '/v1/tabs/select') => _handlePostTabsSelect(body),
      ('POST', '/v1/tabs/close') => _handlePostTabsClose(body),
      ('POST', '/v1/tabs/spawn') => _handlePostTabsSpawn(body),
      ('POST', '/v1/pty/write') => _handlePostPtyWrite(body),
      ('GET', '/v1/screen') => _handleGetScreen(request.queryParameters),
      ('POST', '/v1/screen/find') => _handlePostScreenFind(body),
      ('POST', '/v1/input/pointer') => _handlePostInputPointer(body),
      ('POST', '/v1/input/mouse') => _handlePostInputMouse(body),
      _ when _knownPaths.contains(path) => AutomationHttpResponse.error(
        statusCode: 405,
        code: 'method_not_allowed',
        message: 'Method ${request.method} is not allowed for $path.',
      ),
      _ => AutomationHttpResponse.error(
        statusCode: 404,
        code: 'not_found',
        message: 'Unknown automation endpoint: $path.',
      ),
    };
  }

  static String _normalizePath(String rawPath) {
    if (rawPath.length > 1 && rawPath.endsWith('/')) {
      return rawPath.substring(0, rawPath.length - 1);
    }
    return rawPath;
  }

  static Future<void> _defaultAwaitFrameSettle() async {
    final binding = SchedulerBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.idle &&
        !binding.hasScheduledFrame) {
      binding.scheduleFrame();
    }
    try {
      await binding.endOfFrame.timeout(defaultFrameSettleTimeout);
    } on TimeoutException {
      // Headless or minimized windows may not produce a frame within 150ms.
    }
  }

  // ---------------------------------------------------------------------------
  // GET /v1/state
  // ---------------------------------------------------------------------------

  Future<AutomationHttpResponse> _handleGetState() async {
    final bounds = await _windowBridge.getBounds();
    final tabs = _buildTabsSnapshot();
    return AutomationHttpResponse.ok(<String, Object?>{
      'window': bounds.toJson(),
      'overlay': _workspace.activeOverlay.name,
      'theme': _workspace.activeTerminalTheme.id,
      'appearanceMode':
          _workspace.workspaceSettings.themeSettings.appearanceMode.name,
      'fontSize': _workspace.effectiveFontSize,
      'perfHud': _workspace.showPerfHud,
      'backgroundShaderChain': _workspace.backgroundShaderChain,
      'foregroundShaderChain': _workspace.foregroundShaderChain,
      'backgroundOpacity': _workspace.backgroundOpacity,
      'activeTabIndex': tabs['activeTabIndex'],
      'activeTabId': tabs['activeTabId'],
      'focusedPaneId': tabs['focusedPaneId'],
      'tabs': tabs['tabs'],
    });
  }

  // ---------------------------------------------------------------------------
  // GET / POST /v1/window/bounds
  // ---------------------------------------------------------------------------

  Future<AutomationHttpResponse> _handleGetWindowBounds() async {
    final bounds = await _windowBridge.getBounds();
    return AutomationHttpResponse.ok(_buildBoundsPayload(bounds));
  }

  Future<AutomationHttpResponse> _handlePostWindowBounds(
    Map<String, Object?> body,
  ) async {
    final WindowBoundsRequest request;
    try {
      request = WindowBoundsRequest.fromJson(body);
    } on FormatException catch (error) {
      return _badRequest(error.message);
    }

    final bounds = await _windowBridge.setBounds(request);
    await _awaitFrameSettle();
    if (request.hasSizeChange && _resizeSettleDelay > Duration.zero) {
      await Future<void>.delayed(_resizeSettleDelay);
      await _awaitFrameSettle();
    }
    return AutomationHttpResponse.ok(_buildBoundsPayload(bounds));
  }

  Map<String, Object?> _buildBoundsPayload(WindowBoundsSnapshot bounds) {
    final (cols, rows) = _focusedPaneDimensions();
    return <String, Object?>{...bounds.toJson(), 'cols': ?cols, 'rows': ?rows};
  }

  (int?, int?) _focusedPaneDimensions() {
    if (_workspace.focusedPane case final pane?) {
      final buf = pane.readDisplayBuffer();
      return (buf.width, buf.height);
    }
    if (_workspace.focusedEditorPane case final editor?) {
      final buf = editor.readDisplayBuffer();
      return (buf.width, buf.height);
    }
    return (null, null);
  }

  // ---------------------------------------------------------------------------
  // GET / POST /v1/ui
  // ---------------------------------------------------------------------------

  Future<AutomationHttpResponse> _handleGetUi() async =>
      AutomationHttpResponse.ok(_buildUiSnapshot());

  Future<AutomationHttpResponse> _handlePostUi(
    Map<String, Object?> body,
  ) async {
    final _UiUpdateRequest parsed;
    try {
      parsed = _parseUiUpdateRequest(body);
    } on FormatException catch (error) {
      return _badRequest(error.message);
    }

    if (parsed.fontSize case final size?) {
      _workspace.setFontSize(size);
    }
    if (parsed.theme case final preset?) {
      final current = _workspace.workspaceSettings.themeSettings;
      final next = preset.brightness == tui.TerminalBrightness.light
          ? current.copyWith(
              appearanceMode: ThemeAppearanceMode.light,
              lightThemeId: preset.id,
            )
          : current.copyWith(
              appearanceMode: ThemeAppearanceMode.dark,
              darkThemeId: preset.id,
            );
      _workspace.setThemeSettings(next);
    }
    if (parsed.perfHud case final enabled?) {
      _workspace.setShowPerfHud(enabled);
    }
    if (parsed.overlay case final overlay?) {
      _applyOverlay(overlay);
    }
    await _awaitFrameSettle();
    return AutomationHttpResponse.ok(_buildUiSnapshot());
  }

  _UiUpdateRequest _parseUiUpdateRequest(Map<String, Object?> body) {
    final fontSize = _readOptionalPositiveDouble(body, 'fontSize');
    final rawTheme = _readOptionalString(body, 'theme');
    tui.TerminalColorTheme? theme;
    if (rawTheme != null) {
      theme = _resolveThemePreset(rawTheme);
      if (theme == null) {
        throw FormatException('Unknown theme preset "$rawTheme".');
      }
    }
    final perfHud = _readOptionalBool(body, 'perfHud');
    final rawOverlay = _readOptionalString(body, 'overlay');
    FtermOverlay? overlay;
    if (rawOverlay != null) {
      overlay = _parseUiOverlay(rawOverlay);
      if (overlay == null) {
        throw FormatException('Unsupported overlay "$rawOverlay".');
      }
    }
    return (
      fontSize: fontSize,
      theme: theme,
      perfHud: perfHud,
      overlay: overlay,
    );
  }

  void _applyOverlay(FtermOverlay overlay) {
    switch (overlay) {
      case FtermOverlay.none:
        _workspace.dismissOverlay();
      case FtermOverlay.whatsNew:
        _workspace.openWhatsNew();
      case FtermOverlay.commandPalette:
        _workspace.openCommandPalette();
      default:
        _workspace.setOverlay(overlay);
    }
  }

  Map<String, Object?> _buildUiSnapshot() => <String, Object?>{
    'fontSize': _workspace.effectiveFontSize,
    'theme': _workspace.activeTerminalTheme.id,
    'appearanceMode':
        _workspace.workspaceSettings.themeSettings.appearanceMode.name,
    'availableThemes': <String>[
      for (final preset in tui.TerminalColorTheme.presets) preset.id,
    ],
    'perfHud': _workspace.showPerfHud,
    'overlay': _workspace.activeOverlay.name,
  };

  static tui.TerminalColorTheme? _resolveThemePreset(String raw) {
    final query = raw.trim().toLowerCase();
    if (query.isEmpty) return null;
    for (final preset in tui.TerminalColorTheme.presets) {
      if (preset.id.toLowerCase() == query ||
          preset.name.toLowerCase() == query) {
        return preset;
      }
    }
    return null;
  }

  static FtermOverlay? _parseUiOverlay(String raw) => switch (raw.trim()) {
    'none' => FtermOverlay.none,
    'settings' => FtermOverlay.settings,
    'help' => FtermOverlay.help,
    'about' => FtermOverlay.about,
    'whatsNew' => FtermOverlay.whatsNew,
    'commandPalette' => FtermOverlay.commandPalette,
    _ => null,
  };

  // ---------------------------------------------------------------------------
  // GET / POST /v1/shader
  // ---------------------------------------------------------------------------

  Future<AutomationHttpResponse> _handleGetShader() async =>
      AutomationHttpResponse.ok(_buildShaderSnapshot());

  Future<AutomationHttpResponse> _handlePostShader(
    Map<String, Object?> body,
  ) async {
    final bool clear;
    final List<String>? background;
    final List<String>? foreground;
    final double? backgroundOpacity;
    try {
      clear = _readOptionalBool(body, 'clear') ?? false;
      background = _readOptionalStringList(body, 'background');
      foreground = _readOptionalStringList(body, 'foreground');
      backgroundOpacity = _readOptionalUnitDouble(body, 'backgroundOpacity');
    } on FormatException catch (error) {
      return _badRequest(error.message);
    }

    if (clear) {
      await _workspace.setBackgroundShaderChain(const <String>[]);
      await _workspace.setForegroundShaderChain(const <String>[]);
    }
    if (background != null) {
      await _workspace.setBackgroundShaderChain(background);
    }
    if (foreground != null) {
      await _workspace.setForegroundShaderChain(foreground);
    }
    // Apply explicit opacity after chain updates so auto-reveal does not
    // overwrite the caller's requested opacity.
    if (backgroundOpacity != null) {
      _workspace.setBackgroundOpacity(backgroundOpacity);
    }
    await _awaitFrameSettle();
    return AutomationHttpResponse.ok(_buildShaderSnapshot());
  }

  Map<String, Object?> _buildShaderSnapshot() => <String, Object?>{
    'background': _workspace.backgroundShaderChain,
    'foreground': _workspace.foregroundShaderChain,
    'backgroundOpacity': _workspace.backgroundOpacity,
    'availablePresets': <String>[
      for (final preset in TerminalShaderPreset.values)
        if (preset != TerminalShaderPreset.none) preset.wireName,
    ],
  };

  // ---------------------------------------------------------------------------
  // GET / POST /v1/shader/editor
  // ---------------------------------------------------------------------------

  Future<AutomationHttpResponse> _handleGetShaderEditor() async {
    final located = _findActiveOrFirstEditorPane();
    if (located == null) {
      return AutomationHttpResponse.ok(const <String, Object?>{'open': false});
    }
    return AutomationHttpResponse.ok(
      _serializeEditorState(located.pane, tabId: located.tabId),
    );
  }

  Future<AutomationHttpResponse> _handlePostShaderEditor(
    Map<String, Object?> body,
  ) async {
    final _ShaderEditorUpdateRequest parsed;
    try {
      parsed = _parseShaderEditorRequest(body);
    } on FormatException catch (error) {
      return _badRequest(error.message);
    }

    final located = await _resolveOrOpenEditorPane(parsed);
    if (located == null) {
      return AutomationHttpResponse.error(
        statusCode: 404,
        code: 'editor_not_found',
        message: parsed.open
            ? 'Unable to open shader editor tab.'
            : 'No shader editor pane is currently open.',
      );
    }

    final editor = located.pane;
    final controller = editor.controller;
    final editError = _applyEditorSourceEdit(controller, parsed);
    if (editError != null) return editError;

    if (parsed.previewMode case final mode?) {
      controller.setPreviewMode(mode);
    }
    if (parsed.composition case final comp?) {
      controller.setChainComposition(comp);
    }
    if (parsed.awaitCompile) {
      await controller.triggerCompileNow();
    }
    await _awaitFrameSettle();

    final diagnostics = <Map<String, Object?>>[
      for (final d in controller.diagnostics) _serializeDiagnostic(d),
    ];
    if (controller.errorCount > 0) {
      return AutomationHttpResponse.error(
        statusCode: 422,
        code: 'shader_compile_error',
        message:
            'Shader compilation failed with ${controller.errorCount} '
            'error(s).',
        details: <String, Object?>{
          'paneId': editor.paneId,
          'tabId': located.tabId,
          'compiled': false,
          'diagnostics': diagnostics,
        },
      );
    }
    return AutomationHttpResponse.ok(<String, Object?>{
      ..._serializeEditorState(editor, tabId: located.tabId),
      'compiled': true,
    });
  }

  _ShaderEditorUpdateRequest _parseShaderEditorRequest(
    Map<String, Object?> body,
  ) {
    final open = _readOptionalBool(body, 'open') ?? true;
    final rawPreset = _readOptionalString(body, 'preset');
    final path = _readOptionalString(body, 'path');
    if (rawPreset != null && path != null) {
      throw const FormatException('Specify at most one of "preset" or "path".');
    }
    TerminalShaderPreset? preset;
    if (rawPreset != null) {
      preset = _parseShaderPreset(rawPreset);
      if (preset == null) {
        throw FormatException('Unknown shader preset "$rawPreset".');
      }
    }
    final previewMode = _parseOptionalPreviewMode(body);
    final composition = _parseOptionalComposition(body);
    final source = _readOptionalString(body, 'source');
    final find = _readOptionalString(body, 'find');
    final replace = _readOptionalString(body, 'replace');
    _validateEditorSourceArgs(source: source, find: find, replace: replace);
    final awaitCompile = _readOptionalBool(body, 'awaitCompile') ?? true;
    return (
      open: open,
      preset: preset,
      path: path,
      previewMode: previewMode,
      composition: composition,
      source: source,
      find: find,
      replace: replace,
      awaitCompile: awaitCompile,
    );
  }

  static void _validateEditorSourceArgs({
    required String? source,
    required String? find,
    required String? replace,
  }) {
    if (source != null && (find != null || replace != null)) {
      throw const FormatException(
        'Field "source" cannot be combined with "find"/"replace".',
      );
    }
    if (find != null && find.isEmpty) {
      throw const FormatException('Field "find" must not be empty.');
    }
    if (find != null && replace == null) {
      throw const FormatException(
        'Field "replace" is required when "find" is specified.',
      );
    }
    if (replace != null && find == null) {
      throw const FormatException(
        'Field "replace" requires "find" to be specified.',
      );
    }
  }

  Future<({ShaderEditorPane pane, String tabId})?> _resolveOrOpenEditorPane(
    _ShaderEditorUpdateRequest req,
  ) async {
    if (!req.open) {
      return _findActiveOrFirstEditorPane();
    }
    if (req.preset != null || req.path != null) {
      final tabId = await _workspace.openShaderEditorTab(
        pathOrKey: req.path,
        clonePreset: req.preset,
      );
      final pane = _workspace.focusedEditorPane;
      if (tabId == null || pane == null) return null;
      return (pane: pane, tabId: tabId);
    }
    final existing = _findActiveOrFirstEditorPane();
    if (existing != null) {
      _workspace.focusPane(existing.pane.paneId);
      return existing;
    }
    final tabId = await _workspace.openShaderEditorTab();
    final pane = _workspace.focusedEditorPane;
    if (tabId == null || pane == null) return null;
    return (pane: pane, tabId: tabId);
  }

  AutomationHttpResponse? _applyEditorSourceEdit(
    ShaderEditorController controller,
    _ShaderEditorUpdateRequest req,
  ) {
    if (req.find case final needle?) {
      final current = controller.source;
      if (!current.contains(needle)) {
        return AutomationHttpResponse.error(
          statusCode: 404,
          code: 'find_not_found',
          message: 'Pattern "$needle" was not found in the active shader.',
        );
      }
      final updated = current.replaceFirst(needle, req.replace!);
      controller.textController.value = tui.TextEditingValue(
        text: updated,
        selection: const tui.TextSelection.collapsed(offset: 0),
      );
      return null;
    }
    if (req.source case final nextSource?) {
      controller.textController.value = tui.TextEditingValue(
        text: nextSource,
        selection: const tui.TextSelection.collapsed(offset: 0),
      );
    }
    return null;
  }

  ({ShaderEditorPane pane, String tabId})? _findActiveOrFirstEditorPane() {
    if (_workspace.focusedEditorPane case final focused?) {
      final tab = _workspace.activeTab;
      if (tab != null) return (pane: focused, tabId: tab.tabId);
    }
    for (final tab in _workspace.tabs) {
      for (final paneId in tab.splitTree.paneIds) {
        if (_workspace.shaderEditorPaneById(paneId) case final editor?) {
          return (pane: editor, tabId: tab.tabId);
        }
      }
    }
    return null;
  }

  Map<String, Object?> _serializeEditorState(
    ShaderEditorPane editor, {
    required String tabId,
  }) {
    final controller = editor.controller;
    return <String, Object?>{
      'open': true,
      'paneId': editor.paneId,
      'tabId': tabId,
      'shaderName': editor.shaderName,
      'sourcePath': editor.sourcePath,
      'previewMode': _previewModeWireName(controller.previewMode),
      'composition': _compositionWireName(controller.chainComposition),
      'isDirty': editor.isDirty,
      'source': controller.source,
      'diagnostics': <Map<String, Object?>>[
        for (final d in controller.diagnostics) _serializeDiagnostic(d),
      ],
    };
  }

  static Map<String, Object?> _serializeDiagnostic(ShaderDiagnostic d) =>
      <String, Object?>{
        'severity': d.severity.name,
        'origin': d.origin.name,
        'message': d.message,
        'line': ?d.line,
        'column': ?d.column,
        'length': d.length,
        'hint': ?d.hint,
      };

  static TerminalShaderPreset? _parseShaderPreset(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed == 'none') return null;
    for (final preset in TerminalShaderPreset.values) {
      if (preset == TerminalShaderPreset.none) continue;
      if (preset.wireName == trimmed || preset.name == trimmed) {
        return preset;
      }
    }
    return null;
  }

  static ShaderEditorPreviewMode? _parseOptionalPreviewMode(
    Map<String, Object?> body,
  ) {
    final raw = _readOptionalString(body, 'previewMode');
    if (raw == null) return null;
    return switch (raw.trim().toLowerCase()) {
      'off' => ShaderEditorPreviewMode.off,
      'bg' || 'background' => ShaderEditorPreviewMode.background,
      'fg' || 'foreground' => ShaderEditorPreviewMode.foreground,
      _ => throw FormatException('Invalid previewMode "$raw".'),
    };
  }

  static ShaderEditorChainComposition? _parseOptionalComposition(
    Map<String, Object?> body,
  ) {
    final raw = _readOptionalString(body, 'composition');
    if (raw == null) return null;
    return switch (raw.trim().toLowerCase()) {
      'solo' => ShaderEditorChainComposition.solo,
      'blend' ||
      'blendwithworkspace' => ShaderEditorChainComposition.blendWithWorkspace,
      _ => throw FormatException('Invalid composition "$raw".'),
    };
  }

  static String _previewModeWireName(ShaderEditorPreviewMode mode) =>
      switch (mode) {
        ShaderEditorPreviewMode.off => 'off',
        ShaderEditorPreviewMode.background => 'bg',
        ShaderEditorPreviewMode.foreground => 'fg',
      };

  static String _compositionWireName(ShaderEditorChainComposition comp) =>
      switch (comp) {
        ShaderEditorChainComposition.solo => 'solo',
        ShaderEditorChainComposition.blendWithWorkspace => 'blend',
      };

  // ---------------------------------------------------------------------------
  // GET /v1/tabs, POST /v1/tabs/select, POST /v1/tabs/close, POST /v1/tabs/spawn
  // ---------------------------------------------------------------------------

  Future<AutomationHttpResponse> _handleGetTabs() async =>
      AutomationHttpResponse.ok(_buildTabsSnapshot());

  Future<AutomationHttpResponse> _handlePostTabsSelect(
    Map<String, Object?> body,
  ) async {
    final int? index;
    final String? tabId;
    final String? title;
    final String? paneId;
    try {
      index = _readOptionalInt(body, 'index');
      tabId = _readOptionalString(body, 'tabId');
      title = _readOptionalString(body, 'title');
      paneId = _readOptionalString(body, 'paneId');
    } on FormatException catch (error) {
      return _badRequest(error.message);
    }

    if (index == null && tabId == null && title == null && paneId == null) {
      return _badRequest(
        'Provide at least one of "paneId", "tabId", "index", or "title".',
      );
    }

    if (paneId != null) {
      if (!_paneExists(paneId)) {
        return _paneNotFound(paneId);
      }
      _workspace.focusPane(paneId);
    } else {
      final resolvedIdx = _resolveTabIndex(
        index: index,
        tabId: tabId,
        title: title,
      );
      if (resolvedIdx == null) {
        return AutomationHttpResponse.error(
          statusCode: 404,
          code: 'tab_not_found',
          message: 'No workspace tab matched the requested selector.',
        );
      }
      _workspace.selectTab(resolvedIdx);
    }

    await _awaitFrameSettle();
    return AutomationHttpResponse.ok(_buildTabsSnapshot());
  }

  Future<AutomationHttpResponse> _handlePostTabsClose(
    Map<String, Object?> body,
  ) async {
    final String? paneId;
    final String? tabId;
    final int? index;
    final bool force;
    try {
      paneId = _readOptionalString(body, 'paneId');
      tabId = _readOptionalString(body, 'tabId');
      index = _readOptionalInt(body, 'index');
      force = _readOptionalBool(body, 'force') ?? true;
    } on FormatException catch (error) {
      return _badRequest(error.message);
    }

    if (paneId != null) {
      if (!_paneExists(paneId)) return _paneNotFound(paneId);
      await _workspace.closePane(paneId, force);
    } else if (tabId != null || index != null) {
      final resolvedIdx = _resolveTabIndex(index: index, tabId: tabId);
      if (resolvedIdx == null) {
        return AutomationHttpResponse.error(
          statusCode: 404,
          code: 'tab_not_found',
          message: 'No workspace tab matched the requested selector.',
        );
      }
      await _workspace.closeTab(resolvedIdx, force: force);
    } else {
      final focused = _workspace.focusedPaneId;
      if (focused == null) {
        return AutomationHttpResponse.error(
          statusCode: 404,
          code: 'pane_not_found',
          message: 'No active pane to close.',
        );
      }
      await _workspace.closePane(focused, force);
    }

    await _awaitFrameSettle();
    return AutomationHttpResponse.ok(_buildTabsSnapshot());
  }

  /// Spawns a local shell tab or split pane.
  ///
  /// Split axis mapping matches [SplitAxis]: `"horizontal"` splits panes
  /// side-by-side (`Row`), while `"vertical"` splits panes top-and-bottom
  /// (`Column`). When only `cwd` is provided, preserves the user's configured
  /// shell executable, arguments, and login-shell defaults.
  Future<AutomationHttpResponse> _handlePostTabsSpawn(
    Map<String, Object?> body,
  ) async {
    final _TabSpawnRequest parsed;
    try {
      parsed = _parseTabSpawnRequest(body);
    } on FormatException catch (error) {
      return _badRequest(error.message);
    }

    final shellConfig = _buildSpawnShellConfig(parsed);
    final String? created;
    if (parsed.splitAxis case final axis?) {
      created = await _workspace.splitFocusedPane(
        axis,
        localShellConfig: shellConfig,
      );
    } else {
      created = await _workspace.openLocalShellTab(shellConfig);
    }

    final activeTab = _workspace.activeTab;
    final focusedPaneId = _workspace.focusedPaneId;
    if (created == null || activeTab == null || focusedPaneId == null) {
      return AutomationHttpResponse.error(
        statusCode: 409,
        code: 'spawn_failed',
        message: 'Unable to spawn local shell pane on this host.',
      );
    }

    if (parsed.title case final title? when title.trim().isNotEmpty) {
      _workspace.renameTab(title: title);
    }
    await _awaitFrameSettle();
    return AutomationHttpResponse.ok(<String, Object?>{
      'tabId': activeTab.tabId,
      'paneId': focusedPaneId,
    });
  }

  _TabSpawnRequest _parseTabSpawnRequest(Map<String, Object?> body) {
    final rawSplit = _readOptionalString(body, 'split');
    final SplitAxis? splitAxis = switch (rawSplit?.trim().toLowerCase()) {
      null => null,
      'horizontal' => SplitAxis.horizontal,
      'vertical' => SplitAxis.vertical,
      final invalid => throw FormatException(
        'Field "split" must be "horizontal" or "vertical", got "$invalid".',
      ),
    };
    final title = _readOptionalString(body, 'title');
    final command = _readOptionalString(body, 'command');
    if (command != null && command.trim().isEmpty) {
      throw const FormatException('Field "command" must not be blank.');
    }
    final args = _readOptionalStringList(body, 'args');
    final cwd = _readOptionalString(body, 'cwd');
    if (cwd != null && cwd.trim().isEmpty) {
      throw const FormatException('Field "cwd" must not be blank.');
    }
    return (
      splitAxis: splitAxis,
      title: title,
      command: command?.trim(),
      args: args,
      cwd: cwd?.trim(),
    );
  }

  LocalShellConfig? _buildSpawnShellConfig(_TabSpawnRequest req) {
    if (req.command == null && req.args == null && req.cwd == null) {
      return null;
    }
    final prefs = _workspace.preferences;
    final preserveDefaultShell = req.command == null;
    return LocalShellConfig(
      executable: req.command ?? prefs.shellExecutable,
      arguments:
          req.args ??
          (preserveDefaultShell ? prefs.shellArguments : const <String>[]),
      loginShell: preserveDefaultShell ? prefs.loginShell : false,
      workingDirectory: req.cwd,
      colorScheme: _workspace.activeTerminalTheme.brightness,
    );
  }

  Map<String, Object?> _buildTabsSnapshot() {
    final tabs = _workspace.tabs;
    final activeTab = _workspace.activeTab;
    return <String, Object?>{
      'activeTabIndex': _workspace.activeTabIndex,
      'activeTabId': activeTab?.tabId,
      'focusedPaneId': _workspace.focusedPaneId,
      'tabs': <Map<String, Object?>>[
        for (var i = 0; i < tabs.length; i++) _serializeTab(tabs[i], index: i),
      ],
    };
  }

  Map<String, Object?> _serializeTab(FtermTabState tab, {required int index}) =>
      <String, Object?>{
        'index': index,
        'tabId': tab.tabId,
        'title': tab.resolveTitle(
          _workspace.panes,
          editorPanes: _workspace.editorPanes,
        ),
        'active': index == _workspace.activeTabIndex,
        'focusedPaneId': tab.splitTree.focusedPaneId,
        'zoomedPaneId': tab.splitTree.zoomedPaneId,
        'panes': <Map<String, Object?>>[
          for (final paneId in tab.splitTree.paneIds)
            _serializePane(paneId, focusedPaneId: tab.splitTree.focusedPaneId),
        ],
      };

  Map<String, Object?> _serializePane(
    String paneId, {
    required String focusedPaneId,
  }) {
    if (_workspace.shaderEditorPaneById(paneId) case final editor?) {
      final buf = editor.readDisplayBuffer();
      return <String, Object?>{
        'paneId': paneId,
        'kind': 'shader_editor',
        'cols': buf.width,
        'rows': buf.height,
        'focused': paneId == focusedPaneId,
        'title': editor.shaderName,
        'isDirty': editor.isDirty,
      };
    }
    if (_workspace.paneById(paneId) case final pane?) {
      final buf = pane.readDisplayBuffer();
      final title = pane.shellTitle.isNotEmpty
          ? pane.shellTitle
          : (pane.remotePort?.displayTitle ?? '');
      return <String, Object?>{
        'paneId': paneId,
        'kind': pane.isLocal ? 'local_pty' : 'remote_pty',
        'cols': buf.width,
        'rows': buf.height,
        'focused': paneId == focusedPaneId,
        'title': title,
        'exited': pane.hasExited,
      };
    }
    return <String, Object?>{
      'paneId': paneId,
      'kind': 'unknown',
      'cols': 0,
      'rows': 0,
      'focused': paneId == focusedPaneId,
      'title': '',
    };
  }

  int? _resolveTabIndex({int? index, String? tabId, String? title}) {
    final tabs = _workspace.tabs;
    if (tabId != null) {
      final idx = tabs.indexWhere((tab) => tab.tabId == tabId);
      return idx >= 0 ? idx : null;
    }
    if (index != null) {
      return (index >= 0 && index < tabs.length) ? index : null;
    }
    if (title != null) {
      final needle = title.trim().toLowerCase();
      for (var i = 0; i < tabs.length; i++) {
        final resolved = tabs[i].resolveTitle(
          _workspace.panes,
          editorPanes: _workspace.editorPanes,
        );
        if (resolved.toLowerCase() == needle) return i;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // POST /v1/pty/write
  // ---------------------------------------------------------------------------

  Future<AutomationHttpResponse> _handlePostPtyWrite(
    Map<String, Object?> body,
  ) async {
    final Uint8List bytes;
    final String? explicitPaneId;
    try {
      bytes = _parsePtyWriteBytes(body);
      explicitPaneId = _readOptionalString(body, 'paneId');
    } on FormatException catch (error) {
      return _badRequest(error.message);
    }

    final targetPaneId = explicitPaneId ?? _workspace.focusedPaneId;
    if (targetPaneId == null) {
      return AutomationHttpResponse.error(
        statusCode: 404,
        code: 'pane_not_found',
        message: 'No focused pane is available.',
      );
    }

    if (_workspace.audioController.needsGestureUnlock) {
      await _workspace.audioController.notifyUserGesture();
    }
    final result = _workspace.sendRawPtyBytes(targetPaneId, bytes);
    return switch (result) {
      AutomationPtyWriteResult.ok => AutomationHttpResponse.ok(
        <String, Object?>{'paneId': targetPaneId, 'bytesWritten': bytes.length},
      ),
      AutomationPtyWriteResult.editorPane => AutomationHttpResponse.error(
        statusCode: 400,
        code: 'editor_pane_not_writable',
        message:
            'Pane "$targetPaneId" is a shader editor pane and does not accept '
            'raw PTY bytes.',
      ),
      AutomationPtyWriteResult.exited => AutomationHttpResponse.error(
        statusCode: 409,
        code: 'pane_exited',
        message: 'Pane "$targetPaneId" has already exited.',
      ),
      AutomationPtyWriteResult.notFound => _paneNotFound(targetPaneId),
    };
  }

  static Uint8List _parsePtyWriteBytes(Map<String, Object?> body) {
    final text = _readOptionalString(body, 'text');
    final b64 = _readOptionalString(body, 'base64');
    if ((text != null) == (b64 != null)) {
      throw const FormatException(
        'Exactly one of "text" or "base64" must be provided.',
      );
    }
    if (text != null) {
      return Uint8List.fromList(utf8.encode(text));
    }
    try {
      return base64Decode(b64!);
    } on FormatException {
      throw const FormatException('Field "base64" is not valid base64.');
    }
  }

  // ---------------------------------------------------------------------------
  // GET /v1/screen & POST /v1/screen/find
  // ---------------------------------------------------------------------------

  Future<AutomationHttpResponse> _handleGetScreen(
    Map<String, String> queryParameters,
  ) async {
    final targetPaneId = queryParameters['paneId'] ?? _workspace.focusedPaneId;
    if (targetPaneId == null) {
      return AutomationHttpResponse.error(
        statusCode: 404,
        code: 'pane_not_found',
        message: 'No focused pane is available.',
      );
    }
    final target = _resolveScreenTarget(targetPaneId);
    if (target == null) return _paneNotFound(targetPaneId);

    final snapshot = extractScreenSnapshot(
      target.buffer,
      paneId: targetPaneId,
      cursorCol: target.cursor.col,
      cursorRow: target.cursor.row,
      cursorVisible: target.cursorVisible,
    );
    return AutomationHttpResponse.ok(snapshot.toJson());
  }

  Future<AutomationHttpResponse> _handlePostScreenFind(
    Map<String, Object?> body,
  ) async {
    final String? text;
    final String? regex;
    final bool caseSensitive;
    final String? explicitPaneId;
    try {
      text = _readOptionalString(body, 'text');
      regex = _readOptionalString(body, 'regex');
      caseSensitive = _readOptionalBool(body, 'caseSensitive') ?? true;
      explicitPaneId = _readOptionalString(body, 'paneId');
    } on FormatException catch (error) {
      return _badRequest(error.message);
    }

    final targetPaneId = explicitPaneId ?? _workspace.focusedPaneId;
    if (targetPaneId == null) {
      return AutomationHttpResponse.error(
        statusCode: 404,
        code: 'pane_not_found',
        message: 'No focused pane is available.',
      );
    }
    final target = _resolveScreenTarget(targetPaneId);
    if (target == null) return _paneNotFound(targetPaneId);

    final List<AutomationScreenMatch> matches;
    try {
      matches = findInScreenBuffer(
        target.buffer,
        text: text,
        regex: regex,
        caseSensitive: caseSensitive,
      );
    } on FormatException catch (error) {
      return _badRequest(error.message);
    }

    return AutomationHttpResponse.ok(<String, Object?>{
      'paneId': targetPaneId,
      'cols': target.buffer.width,
      'rows': target.buffer.height,
      'matches': <Map<String, Object?>>[
        for (final match in matches) match.toJson(),
      ],
    });
  }

  ({tui.Buffer buffer, ({int col, int row}) cursor, bool cursorVisible})?
  _resolveScreenTarget(String paneId) {
    if (_workspace.paneById(paneId) case final pane?) {
      return (
        buffer: pane.readDisplayBuffer(),
        cursor: pane.readCursorPosition(),
        cursorVisible: pane.readCursorVisible(),
      );
    }
    if (_workspace.shaderEditorPaneById(paneId) case final editor?) {
      return (
        buffer: editor.readDisplayBuffer(),
        cursor: editor.readCursorPosition(),
        cursorVisible: editor.readCursorVisible(),
      );
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // POST /v1/input/pointer (Base) & POST /v1/input/mouse (PTY)
  // ---------------------------------------------------------------------------

  Future<AutomationHttpResponse> _handlePostInputPointer(
    Map<String, Object?> body,
  ) async {
    final bool clear;
    final double? x;
    final double? y;
    final bool pressed;
    final String? explicitPaneId;
    try {
      clear = _readOptionalBool(body, 'clear') ?? false;
      x = _readOptionalUnitDouble(body, 'x');
      y = _readOptionalUnitDouble(body, 'y');
      pressed = _readOptionalBool(body, 'pressed') ?? false;
      explicitPaneId = _readOptionalString(body, 'paneId');
    } on FormatException catch (error) {
      return _badRequest(error.message);
    }

    if (!clear && (x == null || y == null)) {
      return _badRequest(
        'Provide normalized "x" and "y" in [0, 1], or set "clear": true.',
      );
    }

    final targetPaneId = explicitPaneId ?? _workspace.focusedPaneId;
    if (targetPaneId == null || !_paneExists(targetPaneId)) {
      return _paneNotFound(targetPaneId ?? '<none>');
    }
    final dispatcher = _readPointerDispatcher();
    if (dispatcher == null) {
      return AutomationHttpResponse.error(
        statusCode: 404,
        code: 'surface_unavailable',
        message: 'No terminal surface pointer dispatcher is attached.',
      );
    }

    if (clear) {
      final ok = dispatcher.clearPointer(paneId: targetPaneId);
      if (!ok) return _surfaceNotMounted(targetPaneId);
      return AutomationHttpResponse.ok(<String, Object?>{
        'paneId': targetPaneId,
        'cleared': true,
      });
    }

    final ok = dispatcher.injectPointer(
      paneId: targetPaneId,
      x: x!,
      y: y!,
      pressed: pressed,
    );
    if (!ok) return _surfaceNotMounted(targetPaneId);
    return AutomationHttpResponse.ok(<String, Object?>{
      'paneId': targetPaneId,
      'x': x,
      'y': y,
      'pressed': pressed,
    });
  }

  Future<AutomationHttpResponse> _handlePostInputMouse(
    Map<String, Object?> body,
  ) async {
    final _MouseInputRequest parsed;
    try {
      parsed = _parseMouseInputRequest(body);
    } on FormatException catch (error) {
      return _badRequest(error.message);
    }

    final targetPaneId = parsed.paneId ?? _workspace.focusedPaneId;
    if (targetPaneId == null) {
      return AutomationHttpResponse.error(
        statusCode: 404,
        code: 'pane_not_found',
        message: 'No focused pane is available.',
      );
    }

    final ptyPane = _workspace.paneById(targetPaneId);
    final editorPane = _workspace.shaderEditorPaneById(targetPaneId);
    if (ptyPane == null && editorPane == null) {
      return _paneNotFound(targetPaneId);
    }
    if (ptyPane != null && ptyPane.hasExited) {
      return AutomationHttpResponse.error(
        statusCode: 409,
        code: 'pane_exited',
        message: 'Pane "$targetPaneId" has already exited.',
      );
    }

    if (_workspace.audioController.needsGestureUnlock) {
      await _workspace.audioController.notifyUserGesture();
    }
    final buffer =
        ptyPane?.readDisplayBuffer() ?? editorPane!.readDisplayBuffer();
    final coords = _resolveMouseCoordinates(parsed, buffer);
    _updateShaderPointerForMouse(targetPaneId, parsed.action, coords);
    final events = _buildMouseEvents(parsed, coords);
    for (final event in events) {
      if (ptyPane != null) {
        ptyPane.sendInputEvent(event);
      } else {
        editorPane!.handleInputEvent(event);
      }
    }
    return AutomationHttpResponse.ok(<String, Object?>{
      'paneId': targetPaneId,
      'action': parsed.action,
      'col': coords.col,
      'row': coords.row,
      'x': coords.x,
      'y': coords.y,
    });
  }

  _MouseInputRequest _parseMouseInputRequest(Map<String, Object?> body) {
    final action = _readOptionalString(body, 'action')?.trim().toLowerCase();
    if (action == null ||
        const <String>{
              'move',
              'down',
              'drag',
              'up',
              'click',
              'scroll',
            }.contains(action) ==
            false) {
      throw const FormatException(
        'Field "action" must be one of "move", "down", "drag", "up", '
        '"click", or "scroll".',
      );
    }
    final col = _readOptionalInt(body, 'col');
    final row = _readOptionalInt(body, 'row');
    final x = _readOptionalUnitDouble(body, 'x');
    final y = _readOptionalUnitDouble(body, 'y');
    _validateMouseCoords(col: col, row: row, x: x, y: y);

    final rawButton = _readOptionalString(body, 'button')?.trim().toLowerCase();
    final button = switch (rawButton) {
      null || 'left' => ev.MouseButton.left,
      'middle' => ev.MouseButton.middle,
      'right' => ev.MouseButton.right,
      _ => throw FormatException('Invalid mouse button "$rawButton".'),
    };
    final deltaY = _readOptionalFiniteDouble(body, 'deltaY');
    if (action == 'scroll' && deltaY != null && deltaY == 0) {
      throw const FormatException(
        'Field "deltaY" must be non-zero for scroll.',
      );
    }
    final modifiers = <ev.Modifier>{
      if (_readOptionalBool(body, 'shift') ?? false) ev.Modifier.shift,
      if (_readOptionalBool(body, 'ctrl') ?? false) ev.Modifier.control,
      if (_readOptionalBool(body, 'alt') ?? false) ev.Modifier.alt,
    };
    final paneId = _readOptionalString(body, 'paneId');
    return (
      action: action,
      col: col,
      row: row,
      x: x,
      y: y,
      button: button,
      deltaY: deltaY ?? 1.0,
      modifiers: modifiers,
      paneId: paneId,
    );
  }

  static void _validateMouseCoords({
    required int? col,
    required int? row,
    required double? x,
    required double? y,
  }) {
    final hasCell = col != null || row != null;
    final hasNorm = x != null || y != null;
    if (!hasCell && !hasNorm) {
      throw const FormatException(
        'Provide either ("col", "row") or normalized ("x", "y").',
      );
    }
    if (hasCell && (col == null || row == null)) {
      throw const FormatException('Both "col" and "row" must be provided.');
    }
    if (hasCell && (col! < 0 || row! < 0)) {
      throw const FormatException('"col" and "row" must be non-negative.');
    }
    if (hasNorm && (x == null || y == null)) {
      throw const FormatException('Both "x" and "y" must be provided.');
    }
  }

  static ({int col, int row, double x, double y}) _resolveMouseCoordinates(
    _MouseInputRequest req,
    tui.Buffer buffer,
  ) {
    final cols = math.max(1, buffer.width);
    final rows = math.max(1, buffer.height);
    if (req.col != null && req.row != null) {
      final col = req.col!.clamp(0, cols - 1);
      final row = req.row!.clamp(0, rows - 1);
      return (col: col, row: row, x: (col + 0.5) / cols, y: (row + 0.5) / rows);
    }
    final normX = req.x!.clamp(0.0, 1.0);
    final normY = req.y!.clamp(0.0, 1.0);
    final col = (normX * cols).floor().clamp(0, cols - 1);
    final row = (normY * rows).floor().clamp(0, rows - 1);
    return (col: col, row: row, x: normX, y: normY);
  }

  void _updateShaderPointerForMouse(
    String paneId,
    String action,
    ({int col, int row, double x, double y}) coords,
  ) {
    final dispatcher = _readPointerDispatcher();
    if (dispatcher == null) return;
    if (action == 'click') {
      dispatcher.injectPointer(
        paneId: paneId,
        x: coords.x,
        y: coords.y,
        pressed: true,
      );
      dispatcher.injectPointer(
        paneId: paneId,
        x: coords.x,
        y: coords.y,
        pressed: false,
      );
      return;
    }
    final pressed = action == 'down' || action == 'drag';
    dispatcher.injectPointer(
      paneId: paneId,
      x: coords.x,
      y: coords.y,
      pressed: pressed,
    );
  }

  static List<ev.MouseEvent> _buildMouseEvents(
    _MouseInputRequest req,
    ({int col, int row, double x, double y}) coords,
  ) {
    final x1 = coords.col + 1;
    final y1 = coords.row + 1;
    return switch (req.action) {
      'move' => <ev.MouseEvent>[
        ev.MouseEvent(
          x: x1,
          y: y1,
          button: ev.MouseButton.none,
          type: ev.MouseEventType.move,
          modifiers: req.modifiers,
        ),
      ],
      'down' => <ev.MouseEvent>[
        ev.MouseEvent(
          x: x1,
          y: y1,
          button: req.button,
          type: ev.MouseEventType.press,
          modifiers: req.modifiers,
        ),
      ],
      'drag' => <ev.MouseEvent>[
        ev.MouseEvent(
          x: x1,
          y: y1,
          button: req.button,
          type: ev.MouseEventType.drag,
          modifiers: req.modifiers,
        ),
      ],
      'up' => <ev.MouseEvent>[
        ev.MouseEvent(
          x: x1,
          y: y1,
          button: req.button,
          type: ev.MouseEventType.release,
          modifiers: req.modifiers,
        ),
      ],
      'click' => <ev.MouseEvent>[
        ev.MouseEvent(
          x: x1,
          y: y1,
          button: req.button,
          type: ev.MouseEventType.press,
          modifiers: req.modifiers,
        ),
        ev.MouseEvent(
          x: x1,
          y: y1,
          button: req.button,
          type: ev.MouseEventType.release,
          modifiers: req.modifiers,
        ),
      ],
      'scroll' => _buildScrollEvents(
        x1: x1,
        y1: y1,
        deltaY: req.deltaY,
        modifiers: req.modifiers,
      ),
      _ => const <ev.MouseEvent>[],
    };
  }

  static List<ev.MouseEvent> _buildScrollEvents({
    required int x1,
    required int y1,
    required double deltaY,
    required Set<ev.Modifier> modifiers,
  }) {
    final wheelButton = deltaY < 0
        ? ev.MouseButton.wheelUp
        : ev.MouseButton.wheelDown;
    final steps = deltaY.abs().ceil().clamp(1, _maxScrollSteps);
    return <ev.MouseEvent>[
      for (var i = 0; i < steps; i++)
        ev.MouseEvent(
          x: x1,
          y: y1,
          button: wheelButton,
          type: ev.MouseEventType.press,
          modifiers: modifiers,
        ),
    ];
  }

  // ---------------------------------------------------------------------------
  // Shared Validation & Error Helpers
  // ---------------------------------------------------------------------------

  bool _paneExists(String paneId) =>
      _workspace.paneById(paneId) != null ||
      _workspace.shaderEditorPaneById(paneId) != null;

  static AutomationHttpResponse _badRequest(String message) =>
      AutomationHttpResponse.error(
        statusCode: 400,
        code: 'bad_request',
        message: message,
      );

  static AutomationHttpResponse _paneNotFound(String paneId) =>
      AutomationHttpResponse.error(
        statusCode: 404,
        code: 'pane_not_found',
        message: 'Pane "$paneId" was not found.',
      );

  static AutomationHttpResponse _surfaceNotMounted(String paneId) =>
      AutomationHttpResponse.error(
        statusCode: 404,
        code: 'surface_not_mounted',
        message: 'Terminal surface for pane "$paneId" is not mounted.',
      );

  static String? _readOptionalString(Map<String, Object?> body, String key) {
    final raw = body[key];
    return switch (raw) {
      null => null,
      final String value => value,
      _ => throw FormatException('Field "$key" must be a string.'),
    };
  }

  static bool? _readOptionalBool(Map<String, Object?> body, String key) {
    final raw = body[key];
    return switch (raw) {
      null => null,
      final bool value => value,
      _ => throw FormatException('Field "$key" must be a boolean.'),
    };
  }

  static int? _readOptionalInt(Map<String, Object?> body, String key) {
    final raw = body[key];
    return switch (raw) {
      null => null,
      final int value => value,
      final double value when value.isFinite && value == value.truncate() =>
        value.toInt(),
      _ => throw FormatException('Field "$key" must be an integer.'),
    };
  }

  static double? _readOptionalFiniteDouble(
    Map<String, Object?> body,
    String key,
  ) {
    final raw = body[key];
    return switch (raw) {
      null => null,
      final num value when value.isFinite => value.toDouble(),
      _ => throw FormatException('Field "$key" must be a finite number.'),
    };
  }

  static double? _readOptionalPositiveDouble(
    Map<String, Object?> body,
    String key,
  ) {
    final value = _readOptionalFiniteDouble(body, key);
    if (value != null && value <= 0) {
      throw FormatException('Field "$key" must be greater than zero.');
    }
    return value;
  }

  static double? _readOptionalUnitDouble(
    Map<String, Object?> body,
    String key,
  ) {
    final value = _readOptionalFiniteDouble(body, key);
    if (value != null && (value < 0.0 || value > 1.0)) {
      throw FormatException('Field "$key" must be between 0.0 and 1.0.');
    }
    return value;
  }

  static List<String>? _readOptionalStringList(
    Map<String, Object?> body,
    String key,
  ) {
    final raw = body[key];
    if (raw == null) return null;
    if (raw is! List<Object?>) {
      throw FormatException('Field "$key" must be a list of strings.');
    }
    final out = <String>[];
    for (final item in raw) {
      if (item is! String) {
        throw FormatException('Every element of "$key" must be a string.');
      }
      out.add(item);
    }
    return out;
  }
}

typedef _UiUpdateRequest = ({
  double? fontSize,
  tui.TerminalColorTheme? theme,
  bool? perfHud,
  FtermOverlay? overlay,
});

typedef _ShaderEditorUpdateRequest = ({
  bool open,
  TerminalShaderPreset? preset,
  String? path,
  ShaderEditorPreviewMode? previewMode,
  ShaderEditorChainComposition? composition,
  String? source,
  String? find,
  String? replace,
  bool awaitCompile,
});

typedef _TabSpawnRequest = ({
  SplitAxis? splitAxis,
  String? title,
  String? command,
  List<String>? args,
  String? cwd,
});

typedef _MouseInputRequest = ({
  String action,
  int? col,
  int? row,
  double? x,
  double? y,
  ev.MouseButton button,
  double deltaY,
  Set<ev.Modifier> modifiers,
  String? paneId,
});
