import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:path/path.dart' as p;
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_protocol/termui_cast_protocol.dart'
    show SessionId, SessionSummary;
import 'package:termui_flutter/termui_flutter.dart'
    show
        BuiltinShaders,
        ShaderStageHint,
        TerminalShaderPreset,
        TerminalShaderStage;

import '../../commands/action_descriptors.dart';
import '../../commands/descriptor_adapters.dart';
import '../../commands/fterm_capability_context.dart';
import '../../commands/settings_descriptors.dart';
import '../../commands/shortcut_catalog.dart';
import '../../workspace/fterm_workspace_controller.dart';
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

const List<String> _shaderParamAxes = <String>['x', 'y', 'z'];

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

  /// Enabled runtime feature flag identifiers.
  final Set<String> enabledFeatures;

  /// Creates a [PaletteContext] derived from [workspace] and runtime flags.
  PaletteContext({
    required this.workspace,
    required this.isWeb,
    required this.platform,
    bool? isDesktopHost,
    bool? supportsUpdates,
    this.enabledFeatures = const <String>{},
  }) : isDesktopHost = isDesktopHost ?? workspace.isDesktopHost,
       supportsUpdates =
           supportsUpdates ?? workspace.updateViewModel.isSupportedDesktop;

  /// Unified capability context shared with declarative descriptors.
  FtermCapabilityContext get capabilities => FtermCapabilityContext(
    isWeb: isWeb,
    platform: platform,
    isDesktopHost: isDesktopHost,
    supportsUpdates: supportsUpdates,
    enabledFeatures: enabledFeatures,
  );

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
List<PaletteItem> buildPaletteCommands(PaletteContext context) {
  final ws = context.workspace;
  final caps = context.capabilities;
  final wallpaperPath = ws.backgroundImagePath;
  final trustedCount = ws.trustedCliShaderHashes.length;
  return List<PaletteItem>.unmodifiable(<PaletteItem>[
    ...projectDescriptorsToPaletteItems(
      workspaceAndTabActionDescriptors,
      ws,
      caps,
    ),
    ..._buildThemeCommands(context),
    ...projectDescriptorsToPaletteItems(appearanceSettingDescriptors, ws, caps),
    ...projectDescriptorsToPaletteItems(appearanceActionDescriptors, ws, caps),
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
    ..._buildShaderPresetCommands(context),
    ..._buildCustomShaderCommands(context),
    ..._buildShaderParamSliderCommands(context),
    ...projectDescriptorsToPaletteItems(
      shaderControlSettingDescriptors,
      ws,
      caps,
    ),
    ...projectDescriptorsToPaletteItems(shaderActionDescriptors, ws, caps),
    ...projectDescriptorsToPaletteItems(cliShaderSettingDescriptors, ws, caps),
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
    ...projectDescriptorsToPaletteItems(
      paletteSettingsToggleDescriptors,
      ws,
      caps,
    ),
    ...projectDescriptorsToPaletteItems(
      paletteSettingsEnumDescriptors,
      ws,
      caps,
    ),
    ..._buildSettingsSectionCommands(context),
    ...projectDescriptorsToPaletteItems(
      systemAndOverlayActionDescriptors,
      ws,
      caps,
    ),
  ]);
}

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

List<PaletteItem> _buildSettingsSectionCommands(PaletteContext ctx) {
  final ws = ctx.workspace;
  final caps = ctx.capabilities;
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
        shortcutHint: meta.section == .interface
            ? FtermShortcuts.openSettings.formatPaletteHint(caps)
            : null,
        keywords:
            'settings preferences section open ${meta.label.toLowerCase()} '
            '${meta.section.name}',
        icon: meta.icon,
        onExecute: () => ws.openSettingsOverlay(initialSection: meta.section),
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

String _formatShaderParam(double value) =>
    value.clamp(0.0, 2.0).toStringAsFixed(2);
