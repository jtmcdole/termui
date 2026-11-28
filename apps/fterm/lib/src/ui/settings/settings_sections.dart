import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';
import 'package:termui/termui.dart' as tui;

import '../../commands/fterm_capability_context.dart';
import '../../commands/settings_descriptors.dart';
import '../../file_drop_bridge.dart';
import '../../settings_storage.dart';
import '../../update/update_service.dart';
import '../../update/update_view_model.dart';
import '../../workspace/fterm_workspace_controller.dart';
import '../fterm_overlays.dart';
import 'settings_descriptor_renderer.dart';
import 'settings_primitives.dart';

Widget _renderSettingRow(
  String id, {
  required FtermWorkspaceController workspace,
  required FtermOverlayPalette palette,
  required FtermCapabilityContext capabilities,
  VoidCallback? onBeforeWrite,
}) {
  final descriptor = settingDescriptorById(id);
  if (descriptor == null) return const SizedBox.shrink();
  return buildSettingDescriptorWidget(
    descriptor,
    workspace: workspace,
    palette: palette,
    capabilities: capabilities,
    onBeforeWrite: onBeforeWrite,
  );
}

/// Builds the collapsible panels for the **Interface** section (Tab Bar and
/// Clipboard & Selection).
final class SettingsInterfaceSection extends StatelessWidget {
  /// Backing workspace controller.
  final FtermWorkspaceController workspace;

  /// Active overlay palette.
  final FtermOverlayPalette palette;

  /// Whether running in Web mode.
  final bool isWeb;

  /// Optional platform override for hermetic testing.
  final TargetPlatform? platformOverride;

  /// Optional precomputed capability context shared from the parent overlay.
  final FtermCapabilityContext? capabilities;

  /// Panel visibility, collapse state, and search-filter configuration.
  final SettingsPanelFilter filter;

  /// Creates the Interface settings section.
  const SettingsInterfaceSection({
    super.key,
    required this.workspace,
    required this.palette,
    this.isWeb = false,
    this.platformOverride,
    this.capabilities,
    this.filter = const SettingsPanelFilter.showAll(),
  });

  @override
  Widget build(BuildContext context) {
    final resolvedCapabilities =
        capabilities ??
        FtermCapabilityContext.fromWorkspace(
          workspace,
          isWeb: isWeb,
          platform: platformOverride ?? Theme.of(context).platform,
        );
    return SettingsSpacedColumn(
      children: [
        if (filter.showPanel('interface-tab-bar'))
          _InterfaceTabBarPanel(
            workspace: workspace,
            palette: palette,
            capabilities: resolvedCapabilities,
            filter: filter,
          ),
        if (filter.showPanel('interface-clipboard'))
          _InterfaceClipboardPanel(
            workspace: workspace,
            palette: palette,
            capabilities: resolvedCapabilities,
            filter: filter,
          ),
      ],
    );
  }
}

final class _InterfaceTabBarPanel extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final FtermCapabilityContext capabilities;
  final SettingsPanelFilter filter;

  const _InterfaceTabBarPanel({
    required this.workspace,
    required this.palette,
    required this.capabilities,
    required this.filter,
  });

  @override
  Widget build(BuildContext context) => BlenderSettingsPanel(
    id: 'interface-tab-bar',
    title: 'Tab Bar',
    categoryBreadcrumb: filter.categoryBreadcrumb,
    expanded: filter.panelExpanded('interface-tab-bar'),
    onToggleExpanded: filter.toggleFor('interface-tab-bar'),
    palette: palette,
    child: SettingsSpacedColumn(
      spacing: 8,
      children: [
        if (filter.showItem('interface-dock-position'))
          _renderSettingRow(
            'interface-dock-position',
            workspace: workspace,
            palette: palette,
            capabilities: capabilities,
          ),
        if (filter.showItem('interface-auto-hide-tab'))
          _renderSettingRow(
            'interface-auto-hide-tab',
            workspace: workspace,
            palette: palette,
            capabilities: capabilities,
          ),
      ],
    ),
  );
}

final class _InterfaceClipboardPanel extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final FtermCapabilityContext capabilities;
  final SettingsPanelFilter filter;

  const _InterfaceClipboardPanel({
    required this.workspace,
    required this.palette,
    required this.capabilities,
    required this.filter,
  });

  @override
  Widget build(BuildContext context) => BlenderSettingsPanel(
    id: 'interface-clipboard',
    title: 'Clipboard & Selection',
    categoryBreadcrumb: filter.categoryBreadcrumb,
    expanded: filter.panelExpanded('interface-clipboard'),
    onToggleExpanded: filter.toggleFor('interface-clipboard'),
    palette: palette,
    child: SettingsSpacedColumn(
      spacing: 8,
      children: [
        if (filter.showItem('interface-copy-on-select'))
          _renderSettingRow(
            'interface-copy-on-select',
            workspace: workspace,
            palette: palette,
            capabilities: capabilities,
          ),
        if (filter.showItem('interface-osc52'))
          _renderSettingRow(
            'interface-osc52',
            workspace: workspace,
            palette: palette,
            capabilities: capabilities,
          ),
      ],
    ),
  );
}

/// Builds the collapsible panels for the **Themes** section (Theme &
/// Appearance, Typography, and Background).
final class SettingsThemesSection extends StatefulWidget {
  /// Backing workspace controller.
  final FtermWorkspaceController workspace;

  /// Active overlay palette.
  final FtermOverlayPalette palette;

  /// Whether running in Web mode.
  final bool isWeb;

  /// Optional platform override for hermetic testing.
  final TargetPlatform? platformOverride;

  /// Optional precomputed capability context shared from the parent overlay.
  final FtermCapabilityContext? capabilities;

  /// Panel visibility, collapse state, and search-filter configuration.
  final SettingsPanelFilter filter;

  /// Creates the Themes settings section.
  const SettingsThemesSection({
    super.key,
    required this.workspace,
    required this.palette,
    required this.isWeb,
    this.platformOverride,
    this.capabilities,
    this.filter = const SettingsPanelFilter.showAll(),
  });

  @override
  State<SettingsThemesSection> createState() => _SettingsThemesSectionState();
}

final class _SettingsThemesSectionState extends State<SettingsThemesSection> {
  late final TextEditingController _wallpaperCtrl;
  late String _lastSyncedWallpaperPath;
  bool _editingWallpaper = false;

  @override
  void initState() {
    super.initState();
    _lastSyncedWallpaperPath = widget.workspace.backgroundImagePath ?? '';
    _wallpaperCtrl = TextEditingController(text: _lastSyncedWallpaperPath);
  }

  @override
  void didUpdateWidget(SettingsThemesSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final expected = widget.workspace.backgroundImagePath ?? '';
    if (expected != _lastSyncedWallpaperPath) {
      _lastSyncedWallpaperPath = expected;
      if (!_editingWallpaper && _wallpaperCtrl.text != expected) {
        _wallpaperCtrl.text = expected;
      }
    }
  }

  @override
  void dispose() {
    _wallpaperCtrl.dispose();
    super.dispose();
  }

  void _toggleWallpaperEdit() {
    final next = !_editingWallpaper;
    if (!next) {
      _wallpaperCtrl.text = _lastSyncedWallpaperPath;
    } else if (_wallpaperCtrl.text != _lastSyncedWallpaperPath) {
      _wallpaperCtrl.text = _lastSyncedWallpaperPath;
    }
    setState(() => _editingWallpaper = next);
  }

  void _applyWallpaper() {
    final path = _wallpaperCtrl.text;
    setState(() => _editingWallpaper = false);
    unawaited(widget.workspace.setBackgroundImagePath(path));
  }

  void _clearWallpaper() {
    _lastSyncedWallpaperPath = '';
    _wallpaperCtrl.clear();
    setState(() => _editingWallpaper = false);
    unawaited(widget.workspace.setBackgroundImagePath(null));
  }

  @override
  Widget build(BuildContext context) {
    final filter = widget.filter;
    final ws = widget.workspace;
    final palette = widget.palette;
    final capabilities =
        widget.capabilities ??
        FtermCapabilityContext.fromWorkspace(
          ws,
          isWeb: widget.isWeb,
          platform: widget.platformOverride ?? Theme.of(context).platform,
        );

    return SettingsSpacedColumn(
      children: [
        if (filter.showPanel('themes-appearance'))
          _ThemesAppearancePanel(
            workspace: ws,
            palette: palette,
            capabilities: capabilities,
            filter: filter,
          ),
        if (filter.showPanel('themes-typography'))
          _ThemesTypographyPanel(
            workspace: ws,
            palette: palette,
            filter: filter,
          ),
        if (filter.showPanel('themes-background'))
          _ThemesBackgroundPanel(
            workspace: ws,
            palette: palette,
            capabilities: capabilities,
            filter: filter,
            wallpaperController: _wallpaperCtrl,
            editingWallpaper: _editingWallpaper,
            onToggleWallpaperEdit: _toggleWallpaperEdit,
            onApplyWallpaper: _applyWallpaper,
            onClearWallpaper: _clearWallpaper,
          ),
      ],
    );
  }
}

final class _ThemesAppearancePanel extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final FtermCapabilityContext capabilities;
  final SettingsPanelFilter filter;

  const _ThemesAppearancePanel({
    required this.workspace,
    required this.palette,
    required this.capabilities,
    required this.filter,
  });

  void _selectPreset(String? id) {
    if (id == null) return;
    final preset = tui.TerminalColorTheme.byId(id);
    if (preset == null) return;
    final current = workspace.workspaceSettings.themeSettings;
    final next = preset.brightness == .light
        ? current.copyWith(appearanceMode: .light, lightThemeId: preset.id)
        : current.copyWith(appearanceMode: .dark, darkThemeId: preset.id);
    workspace.setThemeSettings(next);
  }

  @override
  Widget build(BuildContext context) {
    final activeTheme = workspace.activeTerminalTheme;
    final presets = tui.TerminalColorTheme.presets;
    final selectedPresetId = presets.any((p) => p.id == activeTheme.id)
        ? activeTheme.id
        : null;

    return BlenderSettingsPanel(
      id: 'themes-appearance',
      title: 'Theme & Appearance',
      categoryBreadcrumb: filter.categoryBreadcrumb,
      expanded: filter.panelExpanded('themes-appearance'),
      onToggleExpanded: filter.toggleFor('themes-appearance'),
      palette: palette,
      child: SettingsSpacedColumn(
        children: [
          if (filter.showItem('themes-appearance-mode'))
            _renderSettingRow(
              'themes-appearance-mode',
              workspace: workspace,
              palette: palette,
              capabilities: capabilities,
            ),
          if (filter.showItem('themes-preset'))
            BlenderPropertyRow(
              label: 'Theme Preset',
              palette: palette,
              control: BlenderDropdown<String>(
                dropdownKey: const ValueKey('settings-theme-preset-dropdown'),
                value: selectedPresetId,
                palette: palette,
                items: [
                  for (final preset in presets)
                    DropdownMenuItem<String>(
                      key: ValueKey('settings-theme-${preset.id}'),
                      value: preset.id,
                      child: _ThemePresetMenuItem(
                        preset: preset,
                        palette: palette,
                      ),
                    ),
                ],
                onChanged: _selectPreset,
              ),
            ),
        ],
      ),
    );
  }
}

final class _ThemesTypographyPanel extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final SettingsPanelFilter filter;

  const _ThemesTypographyPanel({
    required this.workspace,
    required this.palette,
    required this.filter,
  });

  @override
  Widget build(BuildContext context) => BlenderSettingsPanel(
    id: 'themes-typography',
    title: 'Typography',
    categoryBreadcrumb: filter.categoryBreadcrumb,
    expanded: filter.panelExpanded('themes-typography'),
    onToggleExpanded: filter.toggleFor('themes-typography'),
    palette: palette,
    child: _FontSizePropertyRow(workspace: workspace, palette: palette),
  );
}

final class _ThemesBackgroundPanel extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final FtermCapabilityContext capabilities;
  final SettingsPanelFilter filter;
  final TextEditingController wallpaperController;
  final bool editingWallpaper;
  final VoidCallback onToggleWallpaperEdit;
  final VoidCallback onApplyWallpaper;
  final VoidCallback onClearWallpaper;

  const _ThemesBackgroundPanel({
    required this.workspace,
    required this.palette,
    required this.capabilities,
    required this.filter,
    required this.wallpaperController,
    required this.editingWallpaper,
    required this.onToggleWallpaperEdit,
    required this.onApplyWallpaper,
    required this.onClearWallpaper,
  });

  @override
  Widget build(BuildContext context) => BlenderSettingsPanel(
    id: 'themes-background',
    title: 'Background',
    categoryBreadcrumb: filter.categoryBreadcrumb,
    expanded: filter.panelExpanded('themes-background'),
    onToggleExpanded: filter.toggleFor('themes-background'),
    palette: palette,
    child: SettingsSpacedColumn(
      children: [
        if (filter.showItem('themes-bg-opacity'))
          _renderSettingRow(
            'themes-bg-opacity',
            workspace: workspace,
            palette: palette,
            capabilities: capabilities,
          ),
        if (filter.showItem('themes-wallpaper'))
          _WallpaperPropertyRow(
            workspace: workspace,
            palette: palette,
            controller: wallpaperController,
            isWeb: capabilities.isWeb,
            isEditing: editingWallpaper,
            onToggleEdit: onToggleWallpaperEdit,
            onApply: onApplyWallpaper,
            onClear: onClearWallpaper,
          ),
      ],
    ),
  );
}

final class _ThemePresetMenuItem extends StatelessWidget {
  final tui.TerminalColorTheme preset;
  final FtermOverlayPalette palette;

  const _ThemePresetMenuItem({required this.preset, required this.palette});

  @override
  Widget build(BuildContext context) {
    final swatches = <Color>[
      Color(preset.background.argb),
      Color(preset.foreground.argb),
      Color(preset.resolveAnsi256(4).argb),
      Color(preset.resolveAnsi256(2).argb),
    ];
    return Row(
      children: [
        for (final color in swatches)
          Container(
            width: 8,
            height: 8,
            margin: const .only(right: 3),
            decoration: BoxDecoration(
              color: color,
              borderRadius: .circular(2),
              border: .all(color: palette.border, width: 0.6),
            ),
          ),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            preset.id,
            overflow: .ellipsis,
            style: TextStyle(color: palette.foreground, fontSize: 11.5),
          ),
        ),
      ],
    );
  }
}

final class _FontSizePropertyRow extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;

  const _FontSizePropertyRow({required this.workspace, required this.palette});

  static String _formatFontSize(double size) => size == size.roundToDouble()
      ? '${size.toInt()} pt'
      : '${size.toStringAsFixed(1)} pt';

  @override
  Widget build(BuildContext context) {
    final size = workspace.effectiveFontSize;
    final canDecrease = size > FtermPreferences.minFontSize;
    final canIncrease = size < FtermPreferences.maxFontSize;
    final hasOverride = workspace.preferences.fontSize != null;

    return BlenderPropertyRow(
      label: 'Font Size',
      palette: palette,
      control: Row(
        children: [
          _StepperButton(
            key: const ValueKey('settings-font-decrease'),
            label: '-',
            palette: palette,
            onPressed: canDecrease
                ? () => workspace.adjustFontSize(-1.0)
                : null,
          ),
          Container(
            height: 26,
            padding: const .symmetric(horizontal: 14),
            alignment: .center,
            decoration: BoxDecoration(
              color: palette.surface,
              border: Border.symmetric(
                horizontal: BorderSide(color: palette.border),
              ),
            ),
            child: Text(
              _formatFontSize(size),
              key: const ValueKey('settings-font-size-value'),
              style: TextStyle(
                color: palette.foreground,
                fontSize: 11.5,
                fontWeight: .w600,
              ),
            ),
          ),
          _StepperButton(
            key: const ValueKey('settings-font-increase'),
            label: '+',
            palette: palette,
            isRight: true,
            onPressed: canIncrease ? () => workspace.adjustFontSize(1.0) : null,
          ),
          const SizedBox(width: 8),
          TextButton(
            key: const ValueKey('settings-font-reset'),
            onPressed: hasOverride ? workspace.resetFontSize : null,
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }
}

final class _StepperButton extends StatelessWidget {
  final String label;
  final FtermOverlayPalette palette;
  final VoidCallback? onPressed;
  final bool isRight;

  const _StepperButton({
    super.key,
    required this.label,
    required this.palette,
    required this.onPressed,
    this.isRight = false,
  });

  @override
  Widget build(BuildContext context) => Container(
    width: 28,
    height: 26,
    decoration: BoxDecoration(
      color: palette.surface,
      borderRadius: isRight
          ? const BorderRadius.horizontal(right: .circular(5))
          : const BorderRadius.horizontal(left: .circular(5)),
      border: .all(color: palette.border),
    ),
    clipBehavior: .antiAlias,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: onPressed == null
                  ? palette.muted.withValues(alpha: 0.4)
                  : palette.foreground,
              fontSize: 13,
              fontWeight: .w600,
            ),
          ),
        ),
      ),
    ),
  );
}

final class _WallpaperPropertyRow extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final TextEditingController controller;
  final bool isWeb;
  final bool isEditing;
  final VoidCallback onToggleEdit;
  final VoidCallback onApply;
  final VoidCallback onClear;

  const _WallpaperPropertyRow({
    required this.workspace,
    required this.palette,
    required this.controller,
    required this.isWeb,
    required this.isEditing,
    required this.onToggleEdit,
    required this.onApply,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final currentPath = workspace.backgroundImagePath;
    final hasWallpaper = currentPath != null;
    final wallpaperError = workspace.lastWallpaperError;
    return SettingsSpacedColumn(
      spacing: 8,
      children: [
        BlenderPropertyRow(
          label: 'Wallpaper',
          palette: palette,
          control: Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: .center,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(
                  hasWallpaper ? currentPath : 'None',
                  overflow: .ellipsis,
                  style: TextStyle(
                    color: hasWallpaper ? palette.foreground : palette.muted,
                    fontSize: 11,
                  ),
                ),
              ),
              OutlinedButton(
                key: const ValueKey('settings-wallpaper-edit'),
                onPressed: onToggleEdit,
                child: Text(isEditing ? 'Cancel' : 'Set Wallpaper'),
              ),
              TextButton(
                key: const ValueKey('settings-wallpaper-clear'),
                onPressed: hasWallpaper ? onClear : null,
                child: const Text('Clear'),
              ),
            ],
          ),
        ),
        if (isEditing)
          BlenderPropertyRow(
            label: isWeb ? 'Storage Key' : 'Image Path',
            palette: palette,
            control: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('settings-wallpaper-path-field'),
                    controller: controller,
                    style: TextStyle(color: palette.foreground, fontSize: 11.5),
                    decoration: blenderInputDecoration(
                      palette: palette,
                      hintText: isWeb
                          ? 'e.g. wallpaper.png'
                          : 'Path to PNG, JPEG, or WebP image',
                    ),
                    onSubmitted: (_) => onApply(),
                  ),
                ),
                const SizedBox(width: 6),
                OutlinedButton(
                  key: const ValueKey('settings-wallpaper-apply'),
                  onPressed: onApply,
                  child: const Text('Apply'),
                ),
              ],
            ),
          ),
        if (wallpaperError != null && wallpaperError.isNotEmpty)
          Container(
            key: const ValueKey('settings-wallpaper-error'),
            padding: const .symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: palette.danger.withValues(alpha: 0.12),
              borderRadius: .circular(6),
              border: .all(color: palette.danger),
            ),
            child: Text(
              wallpaperError,
              style: TextStyle(color: palette.danger, fontSize: 11),
            ),
          ),
      ],
    );
  }
}

/// Builds the desktop-only **Shell** section panel (shell preset, executable,
/// arguments, and login shell flag), owning its text controllers locally.
final class SettingsShellSection extends StatefulWidget {
  /// Backing workspace controller.
  final FtermWorkspaceController workspace;

  /// Active overlay palette.
  final FtermOverlayPalette palette;

  /// Whether running on Web/Wasm.
  final bool isWeb;

  /// Optional platform override for hermetic testing.
  final TargetPlatform? platformOverride;

  /// Optional precomputed capability context shared from the parent overlay.
  final FtermCapabilityContext? capabilities;

  /// Panel visibility, collapse state, and search-filter configuration.
  final SettingsPanelFilter filter;

  /// Creates the Shell settings section.
  const SettingsShellSection({
    super.key,
    required this.workspace,
    required this.palette,
    this.isWeb = false,
    this.platformOverride,
    this.capabilities,
    this.filter = const SettingsPanelFilter.showAll(),
  });

  @override
  State<SettingsShellSection> createState() => _SettingsShellSectionState();
}

final class _SettingsShellSectionState extends State<SettingsShellSection> {
  late final TextEditingController _shellExecCtrl;
  late final TextEditingController _shellArgsCtrl;

  @override
  void initState() {
    super.initState();
    final prefs = widget.workspace.preferences;
    _shellExecCtrl = TextEditingController(text: prefs.shellExecutable ?? '');
    _shellArgsCtrl = TextEditingController(
      text: FtermWorkspaceController.formatShellArguments(prefs.shellArguments),
    );
  }

  @override
  void didUpdateWidget(SettingsShellSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncControllersFromPreferences();
  }

  @override
  void dispose() {
    _shellExecCtrl.dispose();
    _shellArgsCtrl.dispose();
    super.dispose();
  }

  void _syncControllersFromPreferences() {
    final prefs = widget.workspace.preferences;
    final expectedExec = prefs.shellExecutable ?? '';
    if (_shellExecCtrl.text.trim() != expectedExec) {
      _shellExecCtrl.text = expectedExec;
    }
    final parsedArgs = FtermWorkspaceController.parseShellArguments(
      _shellArgsCtrl.text,
    );
    if (!listEquals(parsedArgs, prefs.shellArguments)) {
      _shellArgsCtrl.text = FtermWorkspaceController.formatShellArguments(
        prefs.shellArguments,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ws = widget.workspace;
    final palette = widget.palette;
    final filter = widget.filter;
    final capabilities =
        widget.capabilities ??
        FtermCapabilityContext.fromWorkspace(
          ws,
          isWeb: widget.isWeb,
          platform: widget.platformOverride ?? Theme.of(context).platform,
        );
    final isWindows = capabilities.isWindows;

    return BlenderSettingsPanel(
      id: 'shell-default',
      title: 'Default Shell',
      categoryBreadcrumb: filter.categoryBreadcrumb,
      expanded: filter.panelExpanded('shell-default'),
      onToggleExpanded: filter.toggleFor('shell-default'),
      palette: palette,
      child: SettingsSpacedColumn(
        children: [
          if (filter.showItem('shell-preset'))
            _renderSettingRow(
              'shell-preset',
              workspace: ws,
              palette: palette,
              capabilities: capabilities,
            ),
          if (filter.showItem('shell-executable'))
            BlenderPropertyRow(
              label: 'Shell Executable',
              palette: palette,
              control: TextField(
                key: const ValueKey('settings-shell-executable'),
                controller: _shellExecCtrl,
                style: TextStyle(color: palette.foreground, fontSize: 11.5),
                decoration: blenderInputDecoration(
                  palette: palette,
                  hintText: isWindows
                      ? 'Leave blank for default (e.g. pwsh, powershell.exe)'
                      : r'Leave blank for $SHELL (e.g. zsh, /bin/zsh)',
                ),
                onChanged: (value) {
                  final trimmed = value.trim();
                  ws.updatePreferences(
                    ws.preferences.copyWith(
                      shellExecutable: trimmed,
                      clearShellExecutable: trimmed.isEmpty,
                    ),
                  );
                },
              ),
            ),
          if (filter.showItem('shell-arguments'))
            BlenderPropertyRow(
              label: 'Shell Arguments',
              palette: palette,
              control: TextField(
                key: const ValueKey('settings-shell-arguments'),
                controller: _shellArgsCtrl,
                style: TextStyle(color: palette.foreground, fontSize: 11.5),
                decoration: blenderInputDecoration(
                  palette: palette,
                  hintText: 'Flags (e.g. -l --norc or -c "tmux new")',
                ),
                onChanged: (value) => ws.updatePreferences(
                  ws.preferences.copyWith(
                    shellArguments:
                        FtermWorkspaceController.parseShellArguments(value),
                  ),
                ),
              ),
            ),
          if (filter.showItem('shell-login'))
            _renderSettingRow(
              'shell-login',
              workspace: ws,
              palette: palette,
              capabilities: capabilities,
            ),
        ],
      ),
    );
  }
}

/// Builds the **System** section panels (Graphics & Performance, and Sound).
final class SettingsSystemSection extends StatelessWidget {
  /// Backing workspace controller.
  final FtermWorkspaceController workspace;

  /// Active overlay palette.
  final FtermOverlayPalette palette;

  /// Whether running on Web/Wasm.
  final bool isWeb;

  /// Optional platform override for hermetic testing.
  final TargetPlatform? platformOverride;

  /// Optional precomputed capability context shared from the parent overlay.
  final FtermCapabilityContext? capabilities;

  /// Panel visibility, collapse state, and search-filter configuration.
  final SettingsPanelFilter filter;

  /// Creates the System settings section.
  const SettingsSystemSection({
    super.key,
    required this.workspace,
    required this.palette,
    required this.isWeb,
    this.platformOverride,
    this.capabilities,
    this.filter = const SettingsPanelFilter.showAll(),
  });

  @override
  Widget build(BuildContext context) {
    final resolvedCapabilities =
        capabilities ??
        FtermCapabilityContext.fromWorkspace(
          workspace,
          isWeb: isWeb,
          platform: platformOverride ?? Theme.of(context).platform,
        );
    final showGpuDriver =
        resolvedCapabilities.isWindowsDesktop &&
        filter.showItem('system-gpu-driver');
    final showPerfHud = filter.showItem('system-perf-hud');
    final showKittyTempFile =
        resolvedCapabilities.hasLocalDesktopShell &&
        filter.showItem('system-kitty-temp-file');
    final showKittySharedMemory =
        resolvedCapabilities.hasLocalDesktopShell &&
        (resolvedCapabilities.isLinuxDesktop ||
            resolvedCapabilities.isMacOsDesktop) &&
        filter.showItem('system-kitty-shared-memory');

    return SettingsSpacedColumn(
      children: [
        if (filter.showPanel('system-graphics') &&
            (showPerfHud || showGpuDriver))
          _SystemGraphicsPanel(
            workspace: workspace,
            palette: palette,
            capabilities: resolvedCapabilities,
            filter: filter,
            showPerfHud: showPerfHud,
            showGpuDriver: showGpuDriver,
          ),
        if (filter.showPanel('system-kitty-media') &&
            (showKittyTempFile || showKittySharedMemory))
          _SystemKittyMediaPanel(
            workspace: workspace,
            palette: palette,
            capabilities: resolvedCapabilities,
            filter: filter,
            showTempFile: showKittyTempFile,
            showSharedMemory: showKittySharedMemory,
          ),
        if (filter.showPanel('system-sound'))
          _SystemSoundPanel(
            workspace: workspace,
            palette: palette,
            capabilities: resolvedCapabilities,
            filter: filter,
          ),
      ],
    );
  }
}

final class _SystemGraphicsPanel extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final FtermCapabilityContext capabilities;
  final SettingsPanelFilter filter;
  final bool showPerfHud;
  final bool showGpuDriver;

  const _SystemGraphicsPanel({
    required this.workspace,
    required this.palette,
    required this.capabilities,
    required this.filter,
    required this.showPerfHud,
    required this.showGpuDriver,
  });

  @override
  Widget build(BuildContext context) => BlenderSettingsPanel(
    id: 'system-graphics',
    title: 'Graphics & Performance',
    categoryBreadcrumb: filter.categoryBreadcrumb,
    expanded: filter.panelExpanded('system-graphics'),
    onToggleExpanded: filter.toggleFor('system-graphics'),
    palette: palette,
    child: SettingsSpacedColumn(
      children: [
        if (showPerfHud)
          _renderSettingRow(
            'system-perf-hud',
            workspace: workspace,
            palette: palette,
            capabilities: capabilities,
          ),
        if (showGpuDriver)
          _GpuDriverPreferenceRow(
            workspace: workspace,
            palette: palette,
            capabilities: capabilities,
          ),
      ],
    ),
  );
}

final class _SystemKittyMediaPanel extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final FtermCapabilityContext capabilities;
  final SettingsPanelFilter filter;
  final bool showTempFile;
  final bool showSharedMemory;

  const _SystemKittyMediaPanel({
    required this.workspace,
    required this.palette,
    required this.capabilities,
    required this.filter,
    required this.showTempFile,
    required this.showSharedMemory,
  });

  @override
  Widget build(BuildContext context) => BlenderSettingsPanel(
    id: 'system-kitty-media',
    title: 'Kitty Graphics Media',
    categoryBreadcrumb: filter.categoryBreadcrumb,
    expanded: filter.panelExpanded('system-kitty-media'),
    onToggleExpanded: filter.toggleFor('system-kitty-media'),
    palette: palette,
    child: SettingsSpacedColumn(
      spacing: 8,
      children: [
        if (showTempFile)
          _renderSettingRow(
            'system-kitty-temp-file',
            workspace: workspace,
            palette: palette,
            capabilities: capabilities,
          ),
        if (showSharedMemory)
          _renderSettingRow(
            'system-kitty-shared-memory',
            workspace: workspace,
            palette: palette,
            capabilities: capabilities,
          ),
      ],
    ),
  );
}

final class _SystemSoundPanel extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final FtermCapabilityContext capabilities;
  final SettingsPanelFilter filter;

  const _SystemSoundPanel({
    required this.workspace,
    required this.palette,
    required this.capabilities,
    required this.filter,
  });

  @override
  Widget build(BuildContext context) => BlenderSettingsPanel(
    id: 'system-sound',
    title: 'Sound',
    categoryBreadcrumb: filter.categoryBreadcrumb,
    expanded: filter.panelExpanded('system-sound'),
    onToggleExpanded: filter.toggleFor('system-sound'),
    palette: palette,
    child: SettingsSpacedColumn(
      spacing: 8,
      children: [
        if (filter.showItem('system-audio-mute'))
          _renderSettingRow(
            'system-audio-mute',
            workspace: workspace,
            palette: palette,
            capabilities: capabilities,
          ),
        if (filter.showItem('system-audio-volume'))
          _renderSettingRow(
            'system-audio-volume',
            workspace: workspace,
            palette: palette,
            capabilities: capabilities,
          ),
      ],
    ),
  );
}

/// Formats active local shells and live broadcasts into a concise human phrase.
String formatActiveSessionImpact(
  ({int activeLocalShells, int activeLiveShares}) counts,
) {
  final parts = <String>[
    if (counts.activeLocalShells > 0)
      '${counts.activeLocalShells} active local '
          '${counts.activeLocalShells == 1 ? 'shell' : 'shells'}',
    if (counts.activeLiveShares > 0)
      '${counts.activeLiveShares} live '
          '${counts.activeLiveShares == 1 ? 'broadcast' : 'broadcasts'}',
  ];
  return parts.isEmpty ? 'active sessions' : parts.join(' and ');
}

final class _ActiveSessionRestartConfirm extends StatelessWidget {
  final String message;
  final Color messageColor;
  final Key messageKey;
  final Key confirmKey;
  final Key cancelKey;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;
  final bool inlineLayout;

  const _ActiveSessionRestartConfirm({
    required this.message,
    required this.messageColor,
    required this.messageKey,
    required this.confirmKey,
    required this.cancelKey,
    required this.onConfirm,
    required this.onCancel,
    required this.inlineLayout,
  });

  @override
  Widget build(BuildContext context) {
    final text = Text(
      message,
      key: messageKey,
      style: TextStyle(color: messageColor, fontSize: inlineLayout ? 10.5 : 11),
    );
    final confirmBtn = FilledButton(
      key: confirmKey,
      onPressed: onConfirm,
      child: const Text('Confirm Restart'),
    );
    final cancelBtn = TextButton(
      key: cancelKey,
      onPressed: onCancel,
      child: const Text('Cancel'),
    );
    if (inlineLayout) {
      return Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: .center,
        children: [text, confirmBtn, cancelBtn],
      );
    }
    return SettingsSpacedColumn(
      spacing: 6,
      children: [
        text,
        Wrap(alignment: .end, spacing: 8, children: [cancelBtn, confirmBtn]),
      ],
    );
  }
}

final class _GpuDriverPreferenceRow extends StatefulWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final FtermCapabilityContext capabilities;

  const _GpuDriverPreferenceRow({
    required this.workspace,
    required this.palette,
    required this.capabilities,
  });

  @override
  State<_GpuDriverPreferenceRow> createState() =>
      _GpuDriverPreferenceRowState();
}

final class _GpuDriverPreferenceRowState
    extends State<_GpuDriverPreferenceRow> {
  bool _awaitingRestartConfirm = false;

  void _handleRestartPressed() {
    final counts = widget.workspace.activeLocalSessionCounts;
    if (counts.activeLocalShells > 0 || counts.activeLiveShares > 0) {
      setState(() => _awaitingRestartConfirm = true);
      return;
    }
    unawaited(widget.workspace.restartApplication());
  }

  void _confirmRestart() {
    setState(() => _awaitingRestartConfirm = false);
    unawaited(widget.workspace.restartApplication());
  }

  @override
  Widget build(BuildContext context) {
    final ws = widget.workspace;
    final palette = widget.palette;
    final current = ws.gpuDriverPreference;
    final showIntegratedCapTip =
        current == .powerSaving && ws.maxShaderFps == null;

    return SettingsSpacedColumn(
      spacing: 8,
      children: [
        _renderSettingRow(
          'system-gpu-driver',
          workspace: ws,
          palette: palette,
          capabilities: widget.capabilities,
          onBeforeWrite: () {
            if (_awaitingRestartConfirm) {
              setState(() => _awaitingRestartConfirm = false);
            }
          },
        ),
        if (ws.gpuDriverRestartRequired)
          _GpuDriverRestartControls(
            workspace: ws,
            palette: palette,
            awaitingConfirm: _awaitingRestartConfirm,
            onRestartPressed: _handleRestartPressed,
            onConfirmRestart: _confirmRestart,
            onCancelRestart: () =>
                setState(() => _awaitingRestartConfirm = false),
          ),
        if (showIntegratedCapTip)
          Wrap(
            spacing: 6,
            crossAxisAlignment: .center,
            children: [
              Text(
                'Integrated GPU tip: cap shader ticks for smooth pacing:',
                style: TextStyle(color: palette.muted, fontSize: 10.5),
              ),
              TextButton(
                key: const ValueKey('settings-gpu-suggest-60fps'),
                onPressed: () => ws.setMaxShaderFps(60),
                child: const Text('Use 60 FPS'),
              ),
              TextButton(
                key: const ValueKey('settings-gpu-suggest-120fps'),
                onPressed: () => ws.setMaxShaderFps(120),
                child: const Text('Use 120 FPS'),
              ),
            ],
          ),
      ],
    );
  }
}

final class _GpuDriverRestartControls extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final bool awaitingConfirm;
  final VoidCallback onRestartPressed;
  final VoidCallback onConfirmRestart;
  final VoidCallback onCancelRestart;

  const _GpuDriverRestartControls({
    required this.workspace,
    required this.palette,
    required this.awaitingConfirm,
    required this.onRestartPressed,
    required this.onConfirmRestart,
    required this.onCancelRestart,
  });

  @override
  Widget build(BuildContext context) {
    if (!awaitingConfirm) {
      return Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: .center,
        children: [
          Text(
            'Restart fterm to apply GPU adapter change.',
            key: const ValueKey('settings-gpu-driver-restart-hint'),
            style: TextStyle(color: palette.accent, fontSize: 10.5),
          ),
          OutlinedButton.icon(
            key: const ValueKey('settings-gpu-driver-restart-now'),
            onPressed: onRestartPressed,
            icon: const Icon(Icons.restart_alt, size: 14),
            label: const Text('Restart Now'),
          ),
        ],
      );
    }
    final impact = formatActiveSessionImpact(
      workspace.activeLocalSessionCounts,
    );
    return _ActiveSessionRestartConfirm(
      message: 'Restart now? This closes $impact.',
      messageColor: palette.accent,
      messageKey: const ValueKey('settings-gpu-driver-restart-confirm-text'),
      confirmKey: const ValueKey('settings-gpu-driver-confirm-restart'),
      cancelKey: const ValueKey('settings-gpu-driver-cancel-restart'),
      onConfirm: onConfirmRestart,
      onCancel: onCancelRestart,
      inlineLayout: true,
    );
  }
}

/// Builds the desktop-only **Updates** section panel.
final class SettingsUpdatesSection extends StatefulWidget {
  /// Backing workspace controller.
  final FtermWorkspaceController workspace;

  /// Active overlay palette.
  final FtermOverlayPalette palette;

  /// External URL launcher for release links.
  final UrlOpener onOpenUrl;

  /// Whether running on Web/Wasm.
  final bool isWeb;

  /// Optional platform override for hermetic testing.
  final TargetPlatform? platformOverride;

  /// Optional precomputed capability context shared from the parent overlay.
  final FtermCapabilityContext? capabilities;

  /// Panel visibility, collapse state, and search-filter configuration.
  final SettingsPanelFilter filter;

  /// Creates the desktop Updates settings section.
  const SettingsUpdatesSection({
    super.key,
    required this.workspace,
    required this.palette,
    required this.onOpenUrl,
    this.isWeb = false,
    this.platformOverride,
    this.capabilities,
    this.filter = const SettingsPanelFilter.showAll(),
  });

  @override
  State<SettingsUpdatesSection> createState() => _SettingsUpdatesSectionState();
}

final class _SettingsUpdatesSectionState extends State<SettingsUpdatesSection> {
  bool _awaitingRestartConfirm = false;

  void _onRestartPressed(UpdateViewModel vm) {
    final counts = widget.workspace.activeLocalSessionCounts;
    if (counts.activeLocalShells > 0 || counts.activeLiveShares > 0) {
      setState(() => _awaitingRestartConfirm = true);
      return;
    }
    unawaited(vm.restartToUpdate());
  }

  void _confirmRestart(UpdateViewModel vm) {
    setState(() => _awaitingRestartConfirm = false);
    unawaited(vm.restartToUpdate());
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.workspace.updateViewModel;
    final capabilities =
        widget.capabilities ??
        FtermCapabilityContext.fromWorkspace(
          widget.workspace,
          isWeb: widget.isWeb,
          platform: widget.platformOverride ?? Theme.of(context).platform,
        );
    return ListenableBuilder(
      listenable: vm,
      builder: (_, _) => _UpdatesApplicationPanel(
        workspace: widget.workspace,
        vm: vm,
        palette: widget.palette,
        capabilities: capabilities,
        onOpenUrl: widget.onOpenUrl,
        filter: widget.filter,
        awaitingRestartConfirm: _awaitingRestartConfirm,
        onRestartPressed: () => _onRestartPressed(vm),
        onConfirmRestart: () => _confirmRestart(vm),
        onCancelRestart: () => setState(() => _awaitingRestartConfirm = false),
      ),
    );
  }
}

final class _UpdatesApplicationPanel extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final UpdateViewModel vm;
  final FtermOverlayPalette palette;
  final FtermCapabilityContext capabilities;
  final UrlOpener onOpenUrl;
  final SettingsPanelFilter filter;
  final bool awaitingRestartConfirm;
  final VoidCallback onRestartPressed;
  final VoidCallback onConfirmRestart;
  final VoidCallback onCancelRestart;

  const _UpdatesApplicationPanel({
    required this.workspace,
    required this.vm,
    required this.palette,
    required this.capabilities,
    required this.onOpenUrl,
    required this.filter,
    required this.awaitingRestartConfirm,
    required this.onRestartPressed,
    required this.onConfirmRestart,
    required this.onCancelRestart,
  });

  @override
  Widget build(BuildContext context) {
    final isBusy = vm.status == .checking || vm.status == .downloading;
    return BlenderSettingsPanel(
      id: 'updates-application',
      title: 'Application Updates',
      categoryBreadcrumb: filter.categoryBreadcrumb,
      expanded: filter.panelExpanded('updates-application'),
      onToggleExpanded: filter.toggleFor('updates-application'),
      palette: palette,
      trailing: Text(
        'v${vm.currentVersion}',
        key: const ValueKey('settings-update-current-version'),
        style: TextStyle(
          color: palette.foreground,
          fontSize: 11,
          fontWeight: .w600,
        ),
      ),
      child: SettingsSpacedColumn(
        key: const ValueKey('settings-updates-section'),
        spacing: 8,
        children: [
          if (filter.showItem('updates-check'))
            BlenderPropertyRow(
              label: 'Update Check',
              palette: palette,
              control: Align(
                alignment: .centerLeft,
                child: OutlinedButton.icon(
                  key: const ValueKey('settings-update-check'),
                  onPressed: isBusy
                      ? null
                      : () => unawaited(vm.checkForUpdates()),
                  icon: const Icon(Icons.system_update_alt, size: 14),
                  label: Text(
                    vm.status == .checking ? 'Checking…' : 'Check for Updates',
                  ),
                ),
              ),
            ),
          if (filter.showItem('updates-daily'))
            _renderSettingRow(
              'updates-daily',
              workspace: workspace,
              palette: palette,
              capabilities: capabilities,
            ),
          if (filter.showItem('updates-prereleases'))
            _renderSettingRow(
              'updates-prereleases',
              workspace: workspace,
              palette: palette,
              capabilities: capabilities,
            ),
          if (vm.statusMessage case final infoMsg?)
            Text(
              infoMsg,
              key: const ValueKey('settings-update-status-message'),
              style: TextStyle(color: palette.muted, fontSize: 11),
            ),
          if (vm.errorMessage case final errMsg?)
            Text(
              errMsg,
              key: const ValueKey('settings-update-error-message'),
              style: TextStyle(color: palette.danger, fontSize: 11),
            ),
          if (vm.availableUpdate case final update?)
            _UpdateReleaseCard(
              workspace: workspace,
              vm: vm,
              update: update,
              palette: palette,
              onOpenUrl: onOpenUrl,
              awaitingRestartConfirm: awaitingRestartConfirm,
              onRestartPressed: onRestartPressed,
              onConfirmRestart: onConfirmRestart,
              onCancelRestart: onCancelRestart,
            ),
        ],
      ),
    );
  }
}

final class _UpdateReleaseCard extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final UpdateViewModel vm;
  final AvailableUpdate update;
  final FtermOverlayPalette palette;
  final UrlOpener onOpenUrl;
  final bool awaitingRestartConfirm;
  final VoidCallback onRestartPressed;
  final VoidCallback onConfirmRestart;
  final VoidCallback onCancelRestart;

  const _UpdateReleaseCard({
    required this.workspace,
    required this.vm,
    required this.update,
    required this.palette,
    required this.onOpenUrl,
    required this.awaitingRestartConfirm,
    required this.onRestartPressed,
    required this.onConfirmRestart,
    required this.onCancelRestart,
  });

  static String _summarizeNotes(String raw) {
    final lines = [
      for (final line in raw.split('\n'))
        if (line.trim() case final t when t.isNotEmpty && !t.startsWith('#')) t,
    ];
    if (lines.isEmpty) return '';
    return lines.take(2).join('\n');
  }

  static String _formatMegabytes(int bytes) =>
      (bytes / (1024 * 1024)).toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final summary = _summarizeNotes(update.notes);
    final progress = vm.downloadProgress;
    return Material(
      color: palette.surface,
      shape: RoundedRectangleBorder(
        borderRadius: .circular(6),
        side: BorderSide(color: palette.border),
      ),
      child: Padding(
        padding: const .all(10),
        child: Column(
          mainAxisSize: .min,
          crossAxisAlignment: .stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    update.isPrerelease
                        ? 'fterm v${update.version} (pre-release)'
                        : 'fterm v${update.version} available',
                    style: TextStyle(
                      color: palette.foreground,
                      fontWeight: .w600,
                      fontSize: 12,
                    ),
                  ),
                ),
                TextButton(
                  key: const ValueKey('settings-update-release-link'),
                  onPressed: () => onOpenUrl(update.htmlUrl),
                  child: const Text('Release Notes'),
                ),
              ],
            ),
            if (summary.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                summary,
                maxLines: 3,
                overflow: .ellipsis,
                style: TextStyle(color: palette.muted, fontSize: 11),
              ),
            ],
            if (update.unavailableAssetReason case final reason?) ...[
              const SizedBox(height: 4),
              Text(
                reason,
                style: TextStyle(color: palette.muted, fontSize: 11),
              ),
            ],
            const SizedBox(height: 8),
            if (vm.status == .downloading) ...[
              LinearProgressIndicator(
                key: const ValueKey('settings-update-progress'),
                value: (progress != null && progress.totalBytes > 0)
                    ? progress.fraction
                    : null,
              ),
              if (progress != null && progress.totalBytes > 0) ...[
                const SizedBox(height: 4),
                Text(
                  '${_formatMegabytes(progress.receivedBytes)} / '
                  '${_formatMegabytes(progress.totalBytes)} MB',
                  style: TextStyle(color: palette.muted, fontSize: 10),
                ),
              ],
            ] else if (vm.status == .readyToRestart)
              _UpdateReadyControls(
                workspace: workspace,
                vm: vm,
                palette: palette,
                awaitingRestartConfirm: awaitingRestartConfirm,
                onRestartPressed: onRestartPressed,
                onConfirmRestart: onConfirmRestart,
                onCancelRestart: onCancelRestart,
              )
            else
              _UpdateActionButtons(
                vm: vm,
                update: update,
                onOpenUrl: onOpenUrl,
              ),
          ],
        ),
      ),
    );
  }
}

final class _UpdateReadyControls extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final UpdateViewModel vm;
  final FtermOverlayPalette palette;
  final bool awaitingRestartConfirm;
  final VoidCallback onRestartPressed;
  final VoidCallback onConfirmRestart;
  final VoidCallback onCancelRestart;

  const _UpdateReadyControls({
    required this.workspace,
    required this.vm,
    required this.palette,
    required this.awaitingRestartConfirm,
    required this.onRestartPressed,
    required this.onConfirmRestart,
    required this.onCancelRestart,
  });

  @override
  Widget build(BuildContext context) {
    final impact = formatActiveSessionImpact(
      workspace.activeLocalSessionCounts,
    );
    return SettingsSpacedColumn(
      spacing: 8,
      children: [
        BlenderCheckboxRow(
          label: 'Apply on Quit',
          caption: 'Install staged update when fterm closes',
          value: vm.applyOnQuit,
          controlKey: const ValueKey('settings-update-apply-on-quit'),
          palette: palette,
          onChanged: vm.setApplyOnQuit,
        ),
        if (awaitingRestartConfirm)
          _ActiveSessionRestartConfirm(
            message: 'Restarting closes $impact.',
            messageColor: palette.danger,
            messageKey: const ValueKey('settings-update-restart-warning'),
            confirmKey: const ValueKey('settings-update-confirm-restart'),
            cancelKey: const ValueKey('settings-update-cancel-restart'),
            onConfirm: onConfirmRestart,
            onCancel: onCancelRestart,
            inlineLayout: false,
          )
        else
          Align(
            alignment: .centerRight,
            child: FilledButton(
              key: const ValueKey('settings-update-restart'),
              onPressed: onRestartPressed,
              child: const Text('Restart to Update'),
            ),
          ),
      ],
    );
  }
}

final class _UpdateActionButtons extends StatelessWidget {
  final UpdateViewModel vm;
  final AvailableUpdate update;
  final UrlOpener onOpenUrl;

  const _UpdateActionButtons({
    required this.vm,
    required this.update,
    required this.onOpenUrl,
  });

  @override
  Widget build(BuildContext context) {
    final canDownload = vm.capability == .supported && update.asset != null;
    final showFinderReveal =
        vm.capability == .macosAppManagementDenied && vm.stagedUpdate != null;
    return Wrap(
      alignment: .end,
      spacing: 8,
      runSpacing: 6,
      children: [
        TextButton(
          key: const ValueKey('settings-update-skip'),
          onPressed: vm.skipAvailableVersion,
          child: const Text('Skip Version'),
        ),
        if (showFinderReveal)
          FilledButton(
            key: const ValueKey('settings-update-reveal-finder'),
            onPressed: () => unawaited(vm.revealStagedInFinder()),
            child: const Text('Reveal Staged App in Finder'),
          ),
        if (canDownload)
          FilledButton(
            key: const ValueKey('settings-update-download'),
            onPressed: () => unawaited(vm.downloadAvailableUpdate()),
            child: Text(
              vm.status == .error ? 'Retry Download' : 'Download Update',
            ),
          )
        else
          OutlinedButton(
            key: const ValueKey('settings-update-open-release'),
            onPressed: () => onOpenUrl(update.htmlUrl),
            child: const Text('Open GitHub Release'),
          ),
      ],
    );
  }
}
