import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:path/path.dart' as p;
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart'
    show DockPosition, Osc52ClipboardPolicy, ThemeAppearanceMode;
import 'package:termui_cast_protocol/termui_cast_protocol.dart'
    show SessionId, SessionSummary;
import 'package:termui_flutter/termui_flutter.dart'
    show
        BuiltinShaders,
        ShaderAnimationMode,
        ShaderBackendKind,
        ShaderStageHint,
        TerminalShaderPreset,
        TerminalShaderStage;

import '../../settings_storage.dart';
import '../../workspace/fterm_pane_controller.dart';
import '../../workspace/fterm_workspace_controller.dart';
import '../../workspace/local_host_driver.dart' show LocalShareState;
import '../../workspace/split_tree_model.dart' show FocusDirection, SplitAxis;
import '../settings/settings_catalog.dart';
import 'fuzzy_matcher.dart';
import 'palette_models.dart';

/// Default cap on recently used commands surfaced in Quick Switcher mode.
const int defaultQuickSwitchRecentLimit = 5;

/// Section header for pinned session-MRU commands in `>` mode.
const String paletteRecentlyUsedGroup = 'Recently Used';

/// Section header for remaining commands beneath [paletteRecentlyUsedGroup].
const String paletteAllCommandsGroup = 'All Commands';

/// Section header for open workspace tabs in Quick Switcher mode.
const String quickSwitchTabsGroup = 'Open Tabs';

/// Section header for split panes inside multi-pane tabs in Quick Switcher.
const String quickSwitchPanesGroup = 'Split Panes';

/// Section header for available remote relay sessions in Quick Switcher.
const String quickSwitchRemoteGroup = 'Remote Sessions';

/// Section header for session-MRU commands in Quick Switcher mode.
const String quickSwitchRecentGroup = 'Recently Used Commands';

const List<(String id, String label, String? executable)> _posixShellPresets = [
  ('default', r'Default ($SHELL)', null),
  ('zsh', 'zsh', 'zsh'),
  ('bash', 'bash', 'bash'),
  ('sh', 'sh', 'sh'),
];

const List<(String id, String label, String? executable)> _windowsShellPresets =
    [
      ('default', 'Default', null),
      ('pwsh', 'pwsh', 'pwsh'),
      ('powershell', 'PowerShell', 'powershell.exe'),
      ('cmd', 'cmd', 'cmd.exe'),
    ];

const List<(int? fps, String id, String label)> _maxShaderFpsOptions = [
  (null, 'uncapped', 'Uncapped'),
  (120, '120', '120 FPS'),
  (60, '60', '60 FPS'),
  (30, '30', '30 FPS'),
];

const List<(GpuDriverPreference pref, String label)> _gpuDriverOptions = [
  (.auto, 'Auto'),
  (.highPerformance, 'High Performance'),
  (.powerSaving, 'Power Saving'),
];

const List<String> _shaderParamAxes = <String>['x', 'y', 'z'];

const List<CliShaderPolicy> _remoteCliShaderPolicies = <CliShaderPolicy>[
  .disabled,
  .presetsAndTransforms,
  .promptCustomGlsl,
];

/// Platform and capability context controlling palette command visibility,
/// active badges, and shortcut hints.
final class PaletteContext {
  /// Backing workspace coordinator read and mutated by palette items.
  final FtermWorkspaceController workspace;

  /// Whether the app is running in Flutter Web / Wasm mode.
  final bool isWeb;

  /// Active target platform used for shortcut labels and OS-specific commands.
  final TargetPlatform platform;

  /// Whether native desktop shells are supported on this host.
  final bool isDesktopHost;

  /// Whether desktop self-updates are supported on this build.
  final bool supportsUpdates;

  /// Creates a [PaletteContext] derived from [workspace] and runtime flags.
  PaletteContext({
    required this.workspace,
    required this.isWeb,
    required this.platform,
    bool? isDesktopHost,
    bool? supportsUpdates,
  }) : isDesktopHost = isDesktopHost ?? workspace.isDesktopHost,
       supportsUpdates =
           supportsUpdates ?? workspace.updateViewModel.isSupportedDesktop;

  /// Whether local desktop shell capabilities are available.
  bool get hasLocalDesktopShell => !isWeb && isDesktopHost;

  /// Whether native desktop Windows commands (e.g. DXGI GPU driver) apply.
  bool get isWindowsDesktop => !isWeb && platform == .windows;

  /// Whether macOS shortcut conventions (`Cmd`) apply.
  bool get isMacOs => platform == .macOS;
}

typedef _RankedPaletteItem = ({
  PaletteItem item,
  int score,
  int mruRank,
  int order,
});

/// Builds the full flat single-step `>` command catalog visible in [context].
List<PaletteItem> buildPaletteCommands(PaletteContext context) =>
    List<PaletteItem>.unmodifiable(<PaletteItem>[
      ..._buildWorkspaceAndTabCommands(context),
      ..._buildThemeCommands(context),
      ..._buildAppearanceCommands(context),
      ..._buildShaderPresetCommands(context),
      ..._buildCustomShaderCommands(context),
      ..._buildShaderParamSliderCommands(context),
      ..._buildShaderControlCommands(context),
      ..._buildCliShaderPolicyCommands(context),
      ..._buildSettingsToggleCommands(context),
      ..._buildSettingsEnumCommands(context),
      ..._buildSettingsSectionCommands(context),
      ..._buildSystemAndOverlayCommands(context),
    ]);

/// Filters and ranks `>` commands for [query] using [matchPaletteEntry].
///
/// When [query] is empty, session-MRU commands from
/// `context.workspace.recentCommandIds` are pinned at the top under
/// [paletteRecentlyUsedGroup], followed by remaining commands.
List<PaletteItem> queryPaletteCommands(PaletteContext context, String query) {
  final catalog = buildPaletteCommands(context);
  final recentIds = context.workspace.recentCommandIds;
  final trimmed = query.trim();
  if (trimmed.isEmpty) {
    return _orderCommandsWithMruPinning(catalog, recentIds);
  }
  final mruRankById = <String, int>{
    for (var i = 0; i < recentIds.length; i++) recentIds[i]: i,
  };
  return _rankItemsByQuery(catalog, trimmed, mruRankById: mruRankById);
}

/// Builds the canonical Quick Switcher items (empty prefix): open tabs,
/// split panes in multi-pane tabs, available remote relay sessions, and top
/// session MRU commands.
List<PaletteItem> buildQuickSwitchItems(
  PaletteContext context, {
  int maxRecentCommands = defaultQuickSwitchRecentLimit,
}) => List<PaletteItem>.unmodifiable(<PaletteItem>[
  ..._buildQuickSwitchTabs(context),
  ..._buildQuickSwitchSplitPanes(context),
  ..._buildQuickSwitchRemoteSessions(context),
  ..._buildQuickSwitchRecentCommands(context, limit: maxRecentCommands),
]);

/// Filters and ranks Quick Switcher items for [query].
///
/// When [query] is empty, returns sections in canonical order: Open Tabs,
/// Split Panes, Remote Sessions, and Recently Used Commands.
List<PaletteItem> queryQuickSwitchItems(
  PaletteContext context,
  String query, {
  int maxRecentCommands = defaultQuickSwitchRecentLimit,
}) {
  final items = buildQuickSwitchItems(
    context,
    maxRecentCommands: maxRecentCommands,
  );
  final trimmed = query.trim();
  if (trimmed.isEmpty) return items;
  return _rankItemsByQuery(items, trimmed);
}

List<PaletteItem> _orderCommandsWithMruPinning(
  List<PaletteItem> catalog,
  List<String> recentIds,
) {
  if (recentIds.isEmpty) return catalog;
  final byId = <String, PaletteItem>{for (final item in catalog) item.id: item};
  final pinnedIds = <String>{};
  final pinned = <PaletteItem>[];
  for (final id in recentIds) {
    final item = byId[id];
    if (item != null && pinnedIds.add(id)) {
      pinned.add(item.copyWith(groupLabel: paletteRecentlyUsedGroup));
    }
  }
  if (pinned.isEmpty) return catalog;
  return List<PaletteItem>.unmodifiable(<PaletteItem>[
    ...pinned,
    for (final item in catalog)
      if (!pinnedIds.contains(item.id))
        item.copyWith(groupLabel: paletteAllCommandsGroup),
  ]);
}

List<PaletteItem> _rankItemsByQuery(
  List<PaletteItem> items,
  String query, {
  Map<String, int> mruRankById = const <String, int>{},
}) {
  const unranked = 1 << 20;
  final ranked = <_RankedPaletteItem>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    final match = matchPaletteEntry(
      query,
      title: item.title,
      category: item.category,
      keywords: item.keywords,
    );
    if (match == null) continue;
    ranked.add((
      item: item.copyWith(
        matchedTitleIndices: match.matchedIndices,
        clearGroupLabel: true,
      ),
      score: match.score,
      mruRank: mruRankById[item.id] ?? unranked,
      order: i,
    ));
  }
  ranked.sort(_compareRankedItems);
  return List<PaletteItem>.unmodifiable(<PaletteItem>[
    for (final entry in ranked) entry.item,
  ]);
}

int _compareRankedItems(_RankedPaletteItem a, _RankedPaletteItem b) {
  final byScore = b.score.compareTo(a.score);
  if (byScore != 0) return byScore;
  final byMru = a.mruRank.compareTo(b.mruRank);
  if (byMru != 0) return byMru;
  return a.order.compareTo(b.order);
}

List<PaletteItem> _buildWorkspaceAndTabCommands(PaletteContext ctx) {
  final ws = ctx.workspace;
  final isZoomed = ws.activeSplitTree?.isZoomed ?? false;
  final shareBadge = _relayShareBadge(ws.focusedPane);
  return <PaletteItem>[
    if (ctx.hasLocalDesktopShell)
      PaletteItem(
        id: 'workspace.new_local_shell',
        category: 'Workspace',
        title: 'New Local Shell',
        shortcutHint: ctx.isMacOs ? 'Cmd+T' : 'Ctrl+Shift+T',
        keywords: 'new tab terminal local shell pty spawn',
        icon: Icons.add_box_outlined,
        onExecute: ws.openLocalShellTab,
      ),
    PaletteItem(
      id: 'workspace.sessions_picker',
      category: 'Workspace',
      title: 'Sessions & Shells',
      shortcutHint: r'Ctrl+\ c',
      keywords: 'session picker shells local remote switch connect',
      icon: Icons.terminal,
      onExecute: () => ws.setOverlay(.sessionPicker),
    ),
    PaletteItem(
      id: 'pane.split_right',
      category: 'Pane',
      title: 'Split Right',
      shortcutHint: ctx.isWeb
          ? r'Ctrl+\ |'
          : (ctx.isMacOs ? 'Cmd+D' : 'Ctrl+Shift+D'),
      keywords: 'split horizontal side by side pane right',
      icon: Icons.vertical_split,
      onExecute: () => ws.splitFocusedPane(SplitAxis.horizontal),
    ),
    PaletteItem(
      id: 'pane.split_down',
      category: 'Pane',
      title: 'Split Down',
      shortcutHint: ctx.isWeb
          ? r'Ctrl+\ -'
          : (ctx.isMacOs ? 'Cmd+Shift+D' : 'Ctrl+Shift+E'),
      keywords: 'split vertical stacked pane down bottom',
      icon: Icons.horizontal_split,
      onExecute: () => ws.splitFocusedPane(SplitAxis.vertical),
    ),
    PaletteItem(
      id: 'pane.focus_left',
      category: 'Pane',
      title: 'Focus Left',
      shortcutHint: r'Ctrl+\ h',
      keywords: 'pane navigate move focus left arrow',
      icon: Icons.arrow_back,
      onExecute: () => ws.focusDirection(FocusDirection.left),
    ),
    PaletteItem(
      id: 'pane.focus_down',
      category: 'Pane',
      title: 'Focus Down',
      shortcutHint: r'Ctrl+\ j',
      keywords: 'pane navigate move focus down arrow',
      icon: Icons.arrow_downward,
      onExecute: () => ws.focusDirection(FocusDirection.down),
    ),
    PaletteItem(
      id: 'pane.focus_up',
      category: 'Pane',
      title: 'Focus Up',
      shortcutHint: r'Ctrl+\ k',
      keywords: 'pane navigate move focus up arrow',
      icon: Icons.arrow_upward,
      onExecute: () => ws.focusDirection(FocusDirection.up),
    ),
    PaletteItem(
      id: 'pane.focus_right',
      category: 'Pane',
      title: 'Focus Right',
      shortcutHint: r'Ctrl+\ l',
      keywords: 'pane navigate move focus right arrow',
      icon: Icons.arrow_forward,
      onExecute: () => ws.focusDirection(FocusDirection.right),
    ),
    PaletteItem(
      id: 'pane.toggle_zoom',
      category: 'Pane',
      title: 'Toggle Zoom',
      shortcutHint: r'Ctrl+\ z',
      activeBadge: isZoomed ? 'Zoomed' : null,
      keywords: 'pane zoom fullscreen maximize expand tmux',
      icon: Icons.zoom_out_map,
      onExecute: ws.toggleZoom,
    ),
    PaletteItem(
      id: 'pane.close',
      category: 'Pane',
      title: 'Close Pane',
      shortcutHint: ctx.isWeb
          ? r'Ctrl+\ x'
          : (ctx.isMacOs ? 'Cmd+W' : 'Ctrl+Shift+W'),
      keywords: 'close pane tab exit kill',
      icon: Icons.close,
      onExecute: ws.closePane,
    ),
    PaletteItem(
      id: 'tab.next',
      category: 'Tab',
      title: 'Next Tab',
      shortcutHint: r'Ctrl+\ n',
      keywords: 'tab switch cycle next forward',
      icon: Icons.tab,
      onExecute: ws.cycleTab,
    ),
    PaletteItem(
      id: 'tab.previous',
      category: 'Tab',
      title: 'Previous Tab',
      shortcutHint: r'Ctrl+\ p',
      keywords: 'tab switch cycle previous prev back',
      icon: Icons.tab,
      onExecute: () => ws.cycleTab(reverse: true),
    ),
    PaletteItem(
      id: 'tab.rename',
      category: 'Tab',
      title: 'Rename Tab',
      shortcutHint: r'Ctrl+\ r',
      keywords: 'tab rename title pin label',
      icon: Icons.edit,
      onExecute: () => ws.setOverlay(.rename),
    ),
    if (ctx.hasLocalDesktopShell)
      PaletteItem(
        id: 'pane.toggle_relay_share',
        category: 'Workspace',
        title: 'Toggle Relay Share',
        shortcutHint: r'Ctrl+\ b',
        activeBadge: shareBadge,
        keywords: 'relay share broadcast cast live stream',
        icon: Icons.cast,
        onExecute: ws.togglePaneShare,
      ),
    PaletteItem(
      id: 'interface.cycle_dock_position',
      category: 'Interface',
      title: 'Cycle Tab Bar Position',
      subtitle: 'Current: ${_dockLabel(ws.dockPosition)}',
      shortcutHint: r'Ctrl+\ d',
      keywords: 'tab bar dock position cycle top left hidden',
      icon: Icons.view_quilt_outlined,
      onExecute: ws.cycleDockPosition,
    ),
  ];
}

List<PaletteItem> _buildThemeCommands(PaletteContext ctx) {
  final ws = ctx.workspace;
  final activeId = ws.activeTerminalTheme.id;
  return <PaletteItem>[
    for (final preset in tui.TerminalColorTheme.presets)
      PaletteItem(
        id: 'theme.preset.${preset.id}',
        category: 'Theme',
        title: preset.id,
        subtitle: '${preset.name} (${preset.brightness.name})',
        activeBadge: activeId == preset.id ? 'Active' : null,
        keywords:
            'theme color scheme palette ${preset.id} ${preset.name} '
            '${preset.brightness.name}',
        icon: Icons.palette_outlined,
        onExecute: () => _applyThemePreset(ws, preset),
      ),
  ];
}

void _applyThemePreset(
  FtermWorkspaceController ws,
  tui.TerminalColorTheme preset,
) {
  final current = ws.workspaceSettings.themeSettings;
  final next = preset.brightness == .light
      ? current.copyWith(appearanceMode: .light, lightThemeId: preset.id)
      : current.copyWith(appearanceMode: .dark, darkThemeId: preset.id);
  ws.setThemeSettings(next);
}

List<PaletteItem> _buildAppearanceCommands(PaletteContext ctx) {
  final ws = ctx.workspace;
  final currentMode = ws.workspaceSettings.themeSettings.appearanceMode;
  final fontSize = ws.effectiveFontSize;
  final fontLabel = _formatFontSize(fontSize);
  final wallpaperPath = ws.backgroundImagePath;
  return <PaletteItem>[
    PaletteItem(
      id: 'appearance.background_opacity',
      category: 'Appearance',
      title: 'Background Opacity',
      keywords:
          'background opacity transparency alpha translucent glass slider',
      icon: Icons.opacity,
      slider: PaletteSliderSpec(
        value: ws.backgroundOpacity.clamp(0.0, 1.0),
        min: 0.0,
        max: 1.0,
        step: 0.05,
        formatValue: _formatPercent,
        onChanged: ws.setBackgroundOpacity,
      ),
    ),
    PaletteItem(
      id: 'appearance.font_size',
      category: 'Appearance',
      title: 'Font Size',
      keywords: 'font size text zoom pt points scale typography slider',
      icon: Icons.format_size,
      slider: PaletteSliderSpec(
        value: fontSize.clamp(
          FtermPreferences.minFontSize,
          FtermPreferences.maxFontSize,
        ),
        min: FtermPreferences.minFontSize,
        max: FtermPreferences.maxFontSize,
        step: 1.0,
        divisions: (FtermPreferences.maxFontSize - FtermPreferences.minFontSize)
            .round(),
        formatValue: _formatFontSize,
        onChanged: ws.setFontSize,
      ),
    ),
    for (final mode in ThemeAppearanceMode.values)
      PaletteItem(
        id: 'appearance.mode.${mode.name}',
        category: 'Appearance',
        title: 'Mode: ${_appearanceLabel(mode)}',
        activeBadge: currentMode == mode ? 'Active' : null,
        keywords: 'appearance mode theme brightness color ${mode.name}',
        icon: Icons.brightness_6_outlined,
        onExecute: () => ws.setThemeSettings(
          ws.workspaceSettings.themeSettings.copyWith(appearanceMode: mode),
        ),
      ),
    PaletteItem(
      id: 'appearance.font_increase',
      category: 'Appearance',
      title: 'Increase Font Size',
      subtitle: 'Current: $fontLabel',
      shortcutHint: ctx.isMacOs ? 'Cmd+=' : 'Ctrl+=',
      keywords: 'font size zoom in larger text typography',
      icon: Icons.text_increase,
      onExecute: () => ws.adjustFontSize(1.0),
    ),
    PaletteItem(
      id: 'appearance.font_decrease',
      category: 'Appearance',
      title: 'Decrease Font Size',
      subtitle: 'Current: $fontLabel',
      shortcutHint: ctx.isMacOs ? 'Cmd+-' : 'Ctrl+-',
      keywords: 'font size zoom out smaller text typography',
      icon: Icons.text_decrease,
      onExecute: () => ws.adjustFontSize(-1.0),
    ),
    PaletteItem(
      id: 'appearance.font_reset',
      category: 'Appearance',
      title: 'Reset Font Size',
      subtitle: 'Current: $fontLabel',
      shortcutHint: ctx.isMacOs ? 'Cmd+0' : 'Ctrl+0',
      keywords: 'font size zoom reset default typography',
      icon: Icons.format_size,
      onExecute: ws.resetFontSize,
    ),
    PaletteItem(
      id: 'appearance.wallpaper_set',
      category: 'Appearance',
      title: 'Set Wallpaper...',
      subtitle: wallpaperPath ?? 'None',
      keywords: 'wallpaper background image png jpeg webp picture set',
      icon: Icons.wallpaper_outlined,
      onExecute: () => ws.openSettingsOverlay(initialSection: .themes),
    ),
    if (wallpaperPath != null)
      PaletteItem(
        id: 'appearance.wallpaper_clear',
        category: 'Appearance',
        title: 'Clear Wallpaper',
        subtitle: wallpaperPath,
        keywords: 'wallpaper background image clear remove reset',
        icon: Icons.hide_image_outlined,
        onExecute: () => ws.setBackgroundImagePath(null),
      ),
  ];
}

List<PaletteItem> _buildShaderPresetCommands(PaletteContext ctx) {
  final ws = ctx.workspace;
  final bgActive = ws.backgroundShaderChain.toSet();
  final fgActive = ws.foregroundShaderChain.toSet();
  return <PaletteItem>[
    for (final preset in TerminalShaderPreset.values)
      if (preset != TerminalShaderPreset.none)
        _buildSingleShaderPresetItem(
          ws,
          preset,
          bgActive: bgActive,
          fgActive: fgActive,
        ),
  ];
}

PaletteItem _buildSingleShaderPresetItem(
  FtermWorkspaceController ws,
  TerminalShaderPreset preset, {
  required Set<String> bgActive,
  required Set<String> fgActive,
}) {
  final stage = BuiltinShaders.defaultStageForPreset(preset);
  final wireName = preset.wireName;
  final isBg = stage == TerminalShaderStage.background;
  final isActive = isBg
      ? bgActive.contains(wireName)
      : fgActive.contains(wireName);
  return PaletteItem(
    id: 'shader.preset.$wireName',
    category: 'Shader',
    title: 'Toggle $wireName',
    subtitle: isBg ? 'Background preset' : 'Foreground preset',
    activeBadge: isActive ? 'Active' : null,
    keywords: 'shader gpu glsl preset ${stage.name} $wireName ${preset.name}',
    icon: Icons.auto_awesome_outlined,
    onExecute: () => isBg
        ? ws.toggleBackgroundShader(wireName)
        : ws.toggleForegroundShader(wireName),
  );
}

List<PaletteItem> _buildCustomShaderCommands(PaletteContext ctx) {
  final ws = ctx.workspace;
  final bgActive = ws.backgroundShaderChain.toSet();
  final fgActive = ws.foregroundShaderChain.toSet();
  final customEntries = _collectCustomShaderEntries(ws);
  return <PaletteItem>[
    for (final entry in customEntries)
      ..._buildCustomShaderItems(
        ws,
        entry,
        bgActive: bgActive,
        fgActive: fgActive,
      ),
  ];
}

List<String> _collectCustomShaderEntries(FtermWorkspaceController ws) {
  final seen = <String>{};
  final result = <String>[];
  void consider(String entry) {
    final trimmed = entry.trim();
    if (trimmed.isEmpty) return;
    if (TerminalShaderPreset.fromWireName(trimmed) !=
        TerminalShaderPreset.none) {
      return;
    }
    if (seen.add(trimmed)) {
      result.add(trimmed);
    }
  }

  for (final path in ws.availableCustomShaders) {
    consider(path);
  }
  for (final path in ws.backgroundShaderChain) {
    consider(path);
  }
  for (final path in ws.foregroundShaderChain) {
    consider(path);
  }
  return result;
}

List<PaletteItem> _buildCustomShaderItems(
  FtermWorkspaceController ws,
  String entry, {
  required Set<String> bgActive,
  required Set<String> fgActive,
}) {
  final inBg = bgActive.contains(entry);
  final inFg = fgActive.contains(entry);
  if (inBg && inFg) {
    return <PaletteItem>[
      _buildCustomShaderItem(
        ws,
        entry,
        id: 'shader.custom.$entry.bg',
        targetBg: true,
        isActive: true,
      ),
      _buildCustomShaderItem(
        ws,
        entry,
        id: 'shader.custom.$entry.fg',
        targetBg: false,
        isActive: true,
      ),
    ];
  }
  final targetBg =
      inBg ||
      (!inFg &&
          ws.shaderStageHint(entry, .foreground) == ShaderStageHint.background);
  return <PaletteItem>[
    _buildCustomShaderItem(
      ws,
      entry,
      id: 'shader.custom.$entry',
      targetBg: targetBg,
      isActive: targetBg ? inBg : inFg,
    ),
  ];
}

PaletteItem _buildCustomShaderItem(
  FtermWorkspaceController ws,
  String entry, {
  required String id,
  required bool targetBg,
  required bool isActive,
}) {
  final name = p.basename(entry);
  return PaletteItem(
    id: id,
    category: 'Shader',
    title: 'Toggle $name',
    subtitle: targetBg
        ? 'Custom background shader'
        : 'Custom foreground shader',
    activeBadge: isActive ? 'Active' : null,
    keywords:
        'shader custom glsl $name $entry '
        '${targetBg ? 'background' : 'foreground'}',
    icon: Icons.auto_awesome_outlined,
    onExecute: () => targetBg
        ? ws.toggleBackgroundShader(entry)
        : ws.toggleForegroundShader(entry),
  );
}

List<PaletteItem> _buildShaderParamSliderCommands(PaletteContext ctx) {
  final ws = ctx.workspace;
  final activePassIds = _collectActiveShaderPassIds(ws);
  if (activePassIds.isEmpty) return const <PaletteItem>[];
  return <PaletteItem>[
    for (final passId in activePassIds)
      ..._buildSingleShaderPassParamSliders(ws, passId),
  ];
}

List<String> _collectActiveShaderPassIds(FtermWorkspaceController ws) {
  final seen = <String>{};
  final result = <String>[];
  void consider(String id) {
    final trimmed = id.trim();
    if (trimmed.isNotEmpty && seen.add(trimmed)) {
      result.add(trimmed);
    }
  }

  final config = ws.activeShaderConfig;
  for (final pass in config.backgroundPasses) {
    consider(pass.id);
  }
  for (final pass in config.foregroundPasses) {
    consider(pass.id);
  }
  for (final entry in ws.backgroundShaderChain) {
    consider(entry);
  }
  for (final entry in ws.foregroundShaderChain) {
    consider(entry);
  }
  return result;
}

List<PaletteItem> _buildSingleShaderPassParamSliders(
  FtermWorkspaceController ws,
  String passId,
) {
  final values = ws.shaderParamsFor(passId);
  final label = p.basename(passId);
  return <PaletteItem>[
    for (var i = 0; i < _shaderParamAxes.length; i++)
      PaletteItem(
        id: 'shader.param.$passId.${_shaderParamAxes[i]}',
        category: 'Shader',
        title: '$label uParams0.${_shaderParamAxes[i]}',
        keywords:
            'shader param uniform uparams intensity slider $passId $label '
            '${_shaderParamAxes[i]}',
        icon: Icons.tune,
        slider: PaletteSliderSpec(
          value: values[i].clamp(0.0, 2.0),
          min: 0.0,
          max: 2.0,
          step: 0.05,
          formatValue: _formatShaderParam,
          onChanged: (v) => ws.setShaderParam(passId, i, v),
        ),
      ),
  ];
}

List<PaletteItem> _buildCliShaderPolicyCommands(PaletteContext ctx) {
  final ws = ctx.workspace;
  final localPolicy = ws.localCliShaderPolicy;
  final remotePolicy = ws.remoteCliShaderPolicy;
  final stackingMode = ws.cliFullPaneShaderMode;
  final trustedCount = ws.trustedCliShaderHashes.length;
  return <PaletteItem>[
    for (final policy in CliShaderPolicy.values)
      PaletteItem(
        id: 'shader.cli_local_policy.${policy.name}',
        category: 'CLI Shader',
        title: 'Local Policy: ${_cliPolicyLabel(policy)}',
        activeBadge: localPolicy == policy ? 'Active' : null,
        keywords:
            'cli esc s local shader transform policy trust ${policy.wireName}',
        icon: Icons.security_outlined,
        onExecute: () => ws.setLocalCliShaderPolicy(policy),
      ),
    for (final policy in _remoteCliShaderPolicies)
      PaletteItem(
        id: 'shader.cli_remote_policy.${policy.name}',
        category: 'CLI Shader',
        title: 'Remote Policy: ${_cliPolicyLabel(policy)}',
        activeBadge: remotePolicy == policy ? 'Active' : null,
        keywords:
            'cli esc s remote cast relay shader policy trust '
            '${policy.wireName}',
        icon: Icons.security_outlined,
        onExecute: () => ws.setRemoteCliShaderPolicy(policy),
      ),
    for (final mode in CliFullPaneShaderMode.values)
      PaletteItem(
        id: 'shader.cli_stacking.${mode.name}',
        category: 'CLI Shader',
        title: 'Stacking: ${_cliStackingLabel(mode)}',
        activeBadge: stackingMode == mode ? 'Active' : null,
        keywords:
            'cli full pane stacking conflict shader replace ${mode.wireName}',
        icon: Icons.layers_outlined,
        onExecute: () => ws.setCliFullPaneShaderMode(mode),
      ),
    PaletteItem(
      id: 'shader.cli_dev_auto_trust',
      category: 'CLI Shader',
      title: 'Toggle Dev Auto-Trust GLSL',
      activeBadge: _boolBadge(localPolicy == .allowLocalCustomGlsl),
      keywords: 'cli dev auto trust local custom glsl shader',
      icon: Icons.verified_user_outlined,
      onExecute: () => ws.setLocalCliShaderPolicy(
        ws.localCliShaderPolicy == .allowLocalCustomGlsl
            ? .promptCustomGlsl
            : .allowLocalCustomGlsl,
      ),
    ),
    if (trustedCount > 0)
      PaletteItem(
        id: 'shader.cli_reset_trusted_hashes',
        category: 'CLI Shader',
        title: 'Reset Trusted GLSL Hashes',
        activeBadge: '$trustedCount trusted',
        keywords: 'cli sha256 trusted hashes reset clear glsl',
        icon: Icons.delete_sweep_outlined,
        onExecute: ws.clearTrustedCliShaderHashes,
      ),
  ];
}

List<PaletteItem> _buildShaderControlCommands(PaletteContext ctx) {
  final ws = ctx.workspace;
  final backendOverride = ws.shaderBackendOverride;
  final stopped = ws.shadersEmergencyStopped;
  return <PaletteItem>[
    PaletteItem(
      id: 'shader.backend.auto',
      category: 'Shader',
      title: 'Backend: Auto',
      activeBadge: backendOverride == null ? 'Active' : null,
      keywords: 'shader backend gpu impeller webgl auto enable',
      icon: Icons.memory_outlined,
      onExecute: () => ws.setShaderBackendOverride(null),
    ),
    PaletteItem(
      id: 'shader.backend.disabled',
      category: 'Shader',
      title: 'Backend: Disabled',
      activeBadge: backendOverride == ShaderBackendKind.disabled
          ? 'Active'
          : null,
      keywords: 'shader backend gpu disabled off rollback',
      icon: Icons.memory_outlined,
      onExecute: () => ws.setShaderBackendOverride(ShaderBackendKind.disabled),
    ),
    for (final mode in ShaderAnimationMode.values)
      PaletteItem(
        id: 'shader.animation.${mode.name}',
        category: 'Shader',
        title: 'Animation Mode: ${_shaderAnimationLabel(mode)}',
        activeBadge: ws.shaderAnimationMode == mode ? 'Active' : null,
        keywords: 'shader animation playback itime ${mode.wireName}',
        icon: Icons.animation,
        onExecute: () => ws.setShaderAnimationMode(mode),
      ),
    for (final (fps, key, label) in _maxShaderFpsOptions)
      PaletteItem(
        id: 'shader.max_fps.$key',
        category: 'Shader',
        title: 'Max FPS: $label',
        activeBadge: ws.maxShaderFps == fps ? 'Active' : null,
        keywords: 'shader fps frame rate cap pacing battery $label',
        icon: Icons.speed,
        onExecute: () => ws.setMaxShaderFps(fps),
      ),
    PaletteItem(
      id: 'shader.emergency_stop',
      category: 'Shader',
      title: stopped ? 'Resume Shaders' : 'Emergency Stop Shaders',
      shortcutHint: 'Ctrl+Shift+F6',
      activeBadge: stopped ? 'Stopped' : null,
      keywords: 'shader emergency stop resume bypass panic gpu',
      icon: stopped ? Icons.play_arrow : Icons.stop_circle_outlined,
      onExecute: ws.toggleShaderEmergencyStop,
    ),
    PaletteItem(
      id: 'shader.reload',
      category: 'Shader',
      title: 'Reload Shaders',
      shortcutHint: ctx.isWeb ? null : 'Ctrl+Shift+F5',
      keywords: 'shader reload recompile refresh glsl',
      icon: Icons.refresh,
      onExecute: ws.reloadShaders,
    ),
    if (ctx.hasLocalDesktopShell)
      PaletteItem(
        id: 'shader.open_folder',
        category: 'Shader',
        title: 'Open Shaders Folder',
        keywords: 'shader folder directory reveal explorer finder glsl',
        icon: Icons.folder_open,
        onExecute: ws.openShadersFolder,
      ),
    PaletteItem(
      id: 'shader.new_editor_tab',
      category: 'Shader',
      title: 'New Shader Editor Tab',
      shortcutHint: r'Ctrl+\ e',
      keywords: 'shader editor new glsl live code tab',
      icon: Icons.code,
      onExecute: ws.openShaderEditorTab,
    ),
  ];
}

List<PaletteItem> _buildSettingsToggleCommands(PaletteContext ctx) {
  final ws = ctx.workspace;
  final prefs = ws.preferences;
  final osc52Enabled =
      ws.workspaceSettings.osc52Policy == Osc52ClipboardPolicy.allowFocused;
  return <PaletteItem>[
    PaletteItem(
      id: 'settings.toggle.auto_hide_single_tab',
      category: 'Settings',
      title: 'Toggle Auto-Hide Single Tab',
      activeBadge: _boolBadge(prefs.autoHideSingleTab),
      keywords: 'tab bar auto hide single compact interface',
      icon: Icons.tune,
      onExecute: () => ws.updatePreferences(
        ws.preferences.copyWith(
          autoHideSingleTab: !ws.preferences.autoHideSingleTab,
        ),
      ),
    ),
    PaletteItem(
      id: 'settings.toggle.copy_on_select',
      category: 'Settings',
      title: 'Toggle Copy on Selection',
      activeBadge: _boolBadge(ws.copyOnSelect),
      keywords: 'clipboard yank highlight drag mouse select copy',
      icon: Icons.content_copy,
      onExecute: () => ws.setCopyOnSelect(!ws.copyOnSelect),
    ),
    PaletteItem(
      id: 'settings.toggle.osc52',
      category: 'Settings',
      title: 'Toggle Remote OSC 52 Clipboard',
      activeBadge: _boolBadge(osc52Enabled),
      keywords: 'osc52 osc 52 remote clipboard security paste copy',
      icon: Icons.content_paste,
      onExecute: () => ws.setOsc52Policy(
        ws.workspaceSettings.osc52Policy == Osc52ClipboardPolicy.allowFocused
            ? Osc52ClipboardPolicy.deny
            : Osc52ClipboardPolicy.allowFocused,
      ),
    ),
    PaletteItem(
      id: 'settings.toggle.mute_audio',
      category: 'Settings',
      title: 'Toggle Mute Audio',
      activeBadge: _boolBadge(prefs.audioMuted),
      keywords: 'sound audio bell beep apc mute silence',
      icon: prefs.audioMuted ? Icons.volume_off : Icons.volume_up,
      onExecute: () => ws.updatePreferences(
        ws.preferences.copyWith(audioMuted: !ws.preferences.audioMuted),
      ),
    ),
    PaletteItem(
      id: 'system.audio_volume',
      category: 'System',
      title: 'Output Volume',
      keywords: 'sound audio output volume gain loudness slider',
      icon: Icons.volume_up,
      slider: PaletteSliderSpec(
        value: prefs.audioVolume.clamp(0.0, 1.0),
        min: 0.0,
        max: 1.0,
        step: 0.05,
        formatValue: _formatPercent,
        onChanged: (v) =>
            ws.updatePreferences(ws.preferences.copyWith(audioVolume: v)),
      ),
    ),
    PaletteItem(
      id: 'settings.toggle.perf_hud',
      category: 'Settings',
      title: 'Toggle Performance HUD',
      shortcutHint: ctx.isWeb ? null : 'Ctrl+Shift+F9',
      activeBadge: _boolBadge(ws.showPerfHud),
      keywords: 'perf hud fps vram frame timing diagnostics overlay',
      icon: Icons.speed,
      onExecute: ws.togglePerfHud,
    ),
    PaletteItem(
      id: 'settings.toggle.macos_option_as_alt',
      category: 'Keyboard',
      title: 'Toggle macOS Option as Alt',
      activeBadge: _boolBadge(prefs.macosOptionAsAlt),
      keywords: 'macos option alt meta keyboard dead key',
      icon: Icons.keyboard_outlined,
      onExecute: () => ws.updatePreferences(
        ws.preferences.copyWith(
          macosOptionAsAlt: !ws.preferences.macosOptionAsAlt,
        ),
      ),
    ),
    PaletteItem(
      id: 'settings.toggle.f12_shortcuts',
      category: 'Keyboard',
      title: 'Toggle F12 Shortcuts',
      activeBadge: _boolBadge(ws.f12ShortcutsEnabled),
      keywords: 'f12 screenshot atlas reload host shortcut debug',
      icon: Icons.keyboard_outlined,
      onExecute: () => ws.setF12ShortcutsEnabled(!ws.f12ShortcutsEnabled),
    ),
    if (ctx.hasLocalDesktopShell)
      PaletteItem(
        id: 'settings.toggle.login_shell',
        category: 'Shell',
        title: 'Toggle Login Shell (-l)',
        activeBadge: _boolBadge(prefs.loginShell),
        keywords: 'login shell -l profile environment posix',
        icon: Icons.terminal,
        onExecute: () => ws.updatePreferences(
          ws.preferences.copyWith(loginShell: !ws.preferences.loginShell),
        ),
      ),
    if (!ctx.isWeb) ...<PaletteItem>[
      PaletteItem(
        id: 'settings.toggle.automation_driver',
        category: 'Automation',
        title: 'Toggle HTTP Automation Driver',
        activeBadge: _boolBadge(ws.automationDriver.isRunning),
        keywords: 'automation http loopback server driver api enable',
        icon: Icons.smart_toy_outlined,
        onExecute: () =>
            ws.automationDriver.setEnabled(!ws.automationDriver.isRunning),
      ),
      PaletteItem(
        id: 'settings.toggle.automation_pty_scope',
        category: 'Automation',
        title: 'Toggle Automation PTY Access',
        activeBadge: _boolBadge(ws.automationDriver.allowPty),
        keywords: 'automation pty input spawn readback mouse scope security',
        icon: Icons.smart_toy_outlined,
        onExecute: () =>
            ws.automationDriver.setAllowPty(!ws.automationDriver.allowPty),
      ),
    ],
    if (!ctx.isWeb && ctx.supportsUpdates) ...<PaletteItem>[
      PaletteItem(
        id: 'settings.toggle.updates_daily',
        category: 'Updates',
        title: 'Toggle Daily Update Checks',
        activeBadge: _boolBadge(prefs.updateCheckMode == .daily),
        keywords: 'update automatic daily background check schedule',
        icon: Icons.system_update_alt,
        onExecute: () => ws.updatePreferences(
          ws.preferences.copyWith(
            updateCheckMode: ws.preferences.updateCheckMode == .daily
                ? .manual
                : .daily,
          ),
        ),
      ),
      PaletteItem(
        id: 'settings.toggle.updates_prereleases',
        category: 'Updates',
        title: 'Toggle Pre-Release Updates',
        activeBadge: _boolBadge(prefs.includePrereleases),
        keywords: 'update prerelease pre-release beta rc canary',
        icon: Icons.system_update_alt,
        onExecute: () => ws.updatePreferences(
          ws.preferences.copyWith(
            includePrereleases: !ws.preferences.includePrereleases,
          ),
        ),
      ),
    ],
  ];
}

List<PaletteItem> _buildSettingsEnumCommands(PaletteContext ctx) =>
    <PaletteItem>[
      ..._buildDockAndMetaCommands(ctx),
      if (ctx.hasLocalDesktopShell) ..._buildShellPresetCommands(ctx),
      if (ctx.isWindowsDesktop) ..._buildGpuDriverCommands(ctx),
    ];

List<PaletteItem> _buildDockAndMetaCommands(PaletteContext ctx) {
  final ws = ctx.workspace;
  final prefs = ws.preferences;
  return <PaletteItem>[
    for (final pos in DockPosition.values)
      PaletteItem(
        id: 'interface.dock.${pos.name}',
        category: 'Interface',
        title: 'Dock Position: ${_dockLabel(pos)}',
        activeBadge: ws.dockPosition == pos ? 'Active' : null,
        keywords: 'dock tab bar position top left hidden chrome',
        icon: Icons.view_quilt_outlined,
        onExecute: () => ws.setDockPosition(pos),
      ),
    for (final mode in FtermMetaKeyMode.values)
      PaletteItem(
        id: 'keyboard.meta_policy.${mode.name}',
        category: 'Keyboard',
        title: 'Meta Key Policy: ${_metaKeyLabel(mode)}',
        activeBadge: prefs.metaKeyMode == mode ? 'Active' : null,
        keywords: 'meta cmd command super key policy auto pass through kitty',
        icon: Icons.keyboard_outlined,
        onExecute: () =>
            ws.updatePreferences(ws.preferences.copyWith(metaKeyMode: mode)),
      ),
  ];
}

List<PaletteItem> _buildShellPresetCommands(PaletteContext ctx) {
  final ws = ctx.workspace;
  final prefs = ws.preferences;
  final shellPresets = ctx.platform == .windows
      ? _windowsShellPresets
      : _posixShellPresets;
  return <PaletteItem>[
    for (final (id, label, executable) in shellPresets)
      PaletteItem(
        id: 'shell.preset.$id',
        category: 'Shell',
        title: 'Shell Preset: $label',
        activeBadge: prefs.shellExecutable == executable ? 'Active' : null,
        keywords: 'shell preset default executable $label ${executable ?? ''}',
        icon: Icons.terminal,
        onExecute: () => ws.updatePreferences(
          ws.preferences.copyWith(
            shellExecutable: executable,
            clearShellExecutable: executable == null,
          ),
        ),
      ),
  ];
}

List<PaletteItem> _buildGpuDriverCommands(PaletteContext ctx) {
  final ws = ctx.workspace;
  return <PaletteItem>[
    for (final (pref, label) in _gpuDriverOptions)
      PaletteItem(
        id: 'system.gpu_driver.${pref.name}',
        category: 'System',
        title: 'GPU Driver: $label',
        activeBadge: ws.gpuDriverPreference == pref ? 'Active' : null,
        keywords:
            'gpu graphics adapter driver windows dxgi discrete integrated '
            '${pref.wireName} $label',
        icon: Icons.memory_outlined,
        onExecute: () => ws.setGpuDriverPreference(pref),
      ),
  ];
}

List<PaletteItem> _buildSettingsSectionCommands(PaletteContext ctx) {
  final ws = ctx.workspace;
  final visible = SettingsCatalog.visibleSections(
    isWeb: ctx.isWeb,
    isDesktopHost: ctx.isDesktopHost,
    supportsUpdates: ctx.supportsUpdates,
  );
  return <PaletteItem>[
    for (final meta in visible)
      PaletteItem(
        id: 'settings.open.${meta.section.name}',
        category: 'Settings',
        title: 'Open ${meta.label}',
        shortcutHint: meta.section == .interface ? r'Ctrl+\ ,' : null,
        keywords:
            'settings preferences section open ${meta.label.toLowerCase()} '
            '${meta.section.name}',
        icon: meta.icon,
        onExecute: () => ws.openSettingsOverlay(initialSection: meta.section),
      ),
    PaletteItem(
      id: 'settings.reload_storage',
      category: 'Settings',
      title: 'Reload from Storage',
      keywords: 'settings reload disk storage json refresh config',
      icon: Icons.refresh,
      onExecute: ws.reloadSettingsFromStorage,
    ),
  ];
}

List<PaletteItem> _buildSystemAndOverlayCommands(PaletteContext ctx) {
  final ws = ctx.workspace;
  return <PaletteItem>[
    if (!ctx.isWeb && ctx.supportsUpdates)
      PaletteItem(
        id: 'system.check_updates',
        category: 'System',
        title: 'Check for Updates',
        keywords: 'update check version release upgrade github',
        icon: Icons.system_update_alt,
        onExecute: () {
          ws.openSettingsOverlay(initialSection: .updates);
          return ws.updateViewModel.checkForUpdates();
        },
      ),
    PaletteItem(
      id: 'overlay.connect',
      category: 'Workspace',
      title: 'Relay Connection',
      keywords: 'relay connect server url token credentials iap',
      icon: Icons.cloud_outlined,
      onExecute: () => ws.setOverlay(.connect),
    ),
    PaletteItem(
      id: 'overlay.stats',
      category: 'System',
      title: 'Session Stats',
      shortcutHint: r'Ctrl+\ i',
      keywords: 'stats telemetry network audio metrics diagnostics',
      icon: Icons.analytics_outlined,
      onExecute: () => ws.setOverlay(.stats),
    ),
    PaletteItem(
      id: 'overlay.help',
      category: 'Help',
      title: 'Keyboard Shortcuts',
      shortcutHint: r'Ctrl+\ ?',
      keywords: 'help shortcuts keybindings chords reference',
      icon: Icons.keyboard_outlined,
      onExecute: () => ws.setOverlay(.help),
    ),
    PaletteItem(
      id: 'overlay.whats_new',
      category: 'Help',
      title: "What's New",
      keywords: 'whats new release notes highlights changelog showcase',
      icon: Icons.auto_awesome,
      onExecute: ws.openWhatsNew,
    ),
    PaletteItem(
      id: 'overlay.about',
      category: 'Help',
      title: 'About fterm',
      shortcutHint: r'Ctrl+\ a',
      keywords: 'about version licenses credits fterm',
      icon: Icons.info_outline,
      onExecute: () => ws.setOverlay(.about),
    ),
  ];
}

List<PaletteItem> _buildQuickSwitchTabs(PaletteContext ctx) {
  final ws = ctx.workspace;
  final tabs = ws.tabs;
  final activeIdx = ws.activeTabIndex;
  return <PaletteItem>[
    for (var i = 0; i < tabs.length; i++)
      _buildQuickSwitchTabItem(ws, tabs[i], index: i, activeIndex: activeIdx),
  ];
}

PaletteItem _buildQuickSwitchTabItem(
  FtermWorkspaceController ws,
  FtermTabState tab, {
  required int index,
  required int activeIndex,
}) {
  final resolvedTitle = tab.resolveTitle(ws.panes, editorPanes: ws.editorPanes);
  final paneCount = tab.splitTree.paneCount;
  final subtitleParts = <String>[
    if (paneCount > 1) '$paneCount panes',
    if (tab.unreadBellCount > 0) '${tab.unreadBellCount} bell',
  ];
  return PaletteItem(
    id: 'switch.tab.${tab.tabId}',
    title: 'Tab ${index + 1}: $resolvedTitle',
    subtitle: subtitleParts.isEmpty ? null : subtitleParts.join(' • '),
    shortcutHint: index < 9 ? 'Ctrl+\\ ${index + 1}' : null,
    activeBadge: index == activeIndex ? 'Active' : null,
    keywords: 'tab ${index + 1} $resolvedTitle ${tab.tabId}',
    icon: Icons.tab,
    groupLabel: quickSwitchTabsGroup,
    onExecute: () => ws.selectTab(index),
  );
}

List<PaletteItem> _buildQuickSwitchSplitPanes(PaletteContext ctx) {
  final ws = ctx.workspace;
  final tabs = ws.tabs;
  final activeIdx = ws.activeTabIndex;
  final items = <PaletteItem>[];
  for (var tabIdx = 0; tabIdx < tabs.length; tabIdx++) {
    final tab = tabs[tabIdx];
    final paneIds = tab.splitTree.paneIds;
    if (paneIds.length <= 1) continue;
    final tabTitle = tab.resolveTitle(ws.panes, editorPanes: ws.editorPanes);
    for (var paneIdx = 0; paneIdx < paneIds.length; paneIdx++) {
      final paneId = paneIds[paneIdx];
      items.add(
        _buildQuickSwitchPaneItem(
          ws,
          paneId: paneId,
          paneIndex: paneIdx,
          tabIndex: tabIdx,
          tabTitle: tabTitle,
          isActive:
              tabIdx == activeIdx && tab.splitTree.focusedPaneId == paneId,
        ),
      );
    }
  }
  return items;
}

PaletteItem _buildQuickSwitchPaneItem(
  FtermWorkspaceController ws, {
  required String paneId,
  required int paneIndex,
  required int tabIndex,
  required String tabTitle,
  required bool isActive,
}) {
  final label = _resolvePaneLabel(ws, paneId, paneIndex);
  final isEditor = ws.shaderEditorPaneById(paneId) != null;
  return PaletteItem(
    id: 'switch.pane.$paneId',
    title: 'Pane ${paneIndex + 1}: $label',
    subtitle: 'Tab ${tabIndex + 1}: $tabTitle',
    activeBadge: isActive ? 'Active' : null,
    keywords: 'pane split tab ${tabIndex + 1} $tabTitle $label $paneId',
    icon: isEditor ? Icons.code : Icons.view_quilt_outlined,
    groupLabel: quickSwitchPanesGroup,
    onExecute: () => ws.focusPane(paneId),
  );
}

String _resolvePaneLabel(
  FtermWorkspaceController ws,
  String paneId,
  int paneIndex,
) {
  final editor = ws.shaderEditorPaneById(paneId);
  if (editor != null) {
    return editor.isDirty ? '${editor.shaderName}*' : editor.shaderName;
  }
  final pane = ws.paneById(paneId);
  if (pane == null) return 'Pane ${paneIndex + 1}';
  final remote = pane.remotePort;
  if (remote != null) {
    final title = remote.displayTitle.trim();
    return title.isNotEmpty ? title : remote.sessionId.value;
  }
  if (pane.shellTitle.isNotEmpty) return pane.shellTitle;
  final cwd = pane.localHost?.port.workingDirectory?.trim();
  if (cwd != null && cwd.isNotEmpty) {
    final base = p.basename(cwd);
    return base.isNotEmpty ? base : cwd;
  }
  return 'shell';
}

List<PaletteItem> _buildQuickSwitchRemoteSessions(PaletteContext ctx) {
  final ws = ctx.workspace;
  final openSessionIds = <SessionId>{
    for (final pane in ws.panes.values) ?pane.remoteSessionId,
  };
  return <PaletteItem>[
    for (final session in ws.availableRemoteSessions)
      _buildQuickSwitchRemoteItem(
        ws,
        session,
        isOpen: openSessionIds.contains(session.id),
      ),
  ];
}

PaletteItem _buildQuickSwitchRemoteItem(
  FtermWorkspaceController ws,
  SessionSummary session, {
  required bool isOpen,
}) {
  final trimmed = session.title.trim();
  final displayTitle = trimmed.isNotEmpty ? trimmed : session.id.value;
  return PaletteItem(
    id: 'switch.remote.${session.id.value}',
    category: 'Remote',
    title: displayTitle,
    subtitle: '${session.id.value} • ${session.cols}x${session.rows}',
    activeBadge: isOpen ? 'Open' : null,
    keywords: 'remote relay session ${session.id.value} $displayTitle',
    icon: Icons.cloud_outlined,
    groupLabel: quickSwitchRemoteGroup,
    onExecute: () => ws.openRemoteSessionTab(session.id),
  );
}

List<PaletteItem> _buildQuickSwitchRecentCommands(
  PaletteContext ctx, {
  required int limit,
}) {
  final recentIds = ctx.workspace.recentCommandIds;
  if (limit <= 0 || recentIds.isEmpty) return const <PaletteItem>[];
  final byId = <String, PaletteItem>{
    for (final item in buildPaletteCommands(ctx)) item.id: item,
  };
  final items = <PaletteItem>[];
  for (final id in recentIds) {
    final item = byId[id];
    if (item == null) continue;
    items.add(item.copyWith(groupLabel: quickSwitchRecentGroup));
    if (items.length >= limit) break;
  }
  return items;
}

String? _relayShareBadge(FtermPaneController? pane) {
  if (pane == null || !pane.isLocal) return null;
  return switch (pane.shareSnapshot.state) {
    LocalShareState.live => 'Live',
    LocalShareState.connecting => 'Connecting',
    LocalShareState.unshared || LocalShareState.error => null,
  };
}

String _boolBadge(bool enabled) => enabled ? 'On' : 'Off';

String _dockLabel(DockPosition pos) => switch (pos) {
  .top => 'Top',
  .left => 'Left',
  .hidden => 'Hidden',
};

String _appearanceLabel(ThemeAppearanceMode mode) => switch (mode) {
  .system => 'System',
  .dark => 'Dark',
  .light => 'Light',
};

String _shaderAnimationLabel(ShaderAnimationMode mode) => switch (mode) {
  .always => 'Always',
  .focused => 'Focused',
  .onActivity => 'On Activity',
  .staticOnly => 'Static',
};

String _metaKeyLabel(FtermMetaKeyMode mode) => switch (mode) {
  .auto => 'Auto',
  .passThrough => 'Pass Through',
  .kitty => 'Kitty Only',
};

String _cliPolicyLabel(CliShaderPolicy policy) => switch (policy) {
  .disabled => 'Disabled',
  .presetsAndTransforms => 'Presets & Transforms',
  .promptCustomGlsl => 'Prompt Custom GLSL',
  .allowLocalCustomGlsl => 'Allow Local GLSL (Dev)',
};

String _cliStackingLabel(CliFullPaneShaderMode mode) => switch (mode) {
  .cliBeforeUser => 'CLI Before User',
  .cliReplacesUser => 'CLI Replaces User',
  .askOnConflict => 'Ask on Conflict',
};

String _formatPercent(double value) =>
    '${(value.clamp(0.0, 1.0) * 100).round()}%';

String _formatShaderParam(double value) =>
    value.clamp(0.0, 2.0).toStringAsFixed(2);

String _formatFontSize(double size) => size == size.roundToDouble()
    ? '${size.toInt()} pt'
    : '${size.toStringAsFixed(1)} pt';
