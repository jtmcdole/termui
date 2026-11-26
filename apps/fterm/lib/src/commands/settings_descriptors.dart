import 'package:flutter/foundation.dart' show ValueKey;
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart'
    show DockPosition, ThemeAppearanceMode;
import 'package:termui_flutter/termui_flutter.dart'
    show ShaderAnimationMode, ShaderBackendKind;

import '../settings_storage.dart';
import '../workspace/fterm_workspace_controller.dart';
import 'fterm_capability_context.dart';
import 'fterm_descriptor_models.dart';
import 'shortcut_catalog.dart';

final String _themePresetKeywords = <String>[
  for (final preset in tui.TerminalColorTheme.presets) preset.id,
].join(' ');

String _formatPercent(double value) =>
    '${(value.clamp(0.0, 1.0) * 100).round()}%';

String _formatFontSize(double size) => size == size.roundToDouble()
    ? '${size.toInt()} pt'
    : '${size.toStringAsFixed(1)} pt';

String _metaKeyPolicySummary(
  FtermWorkspaceController ws,
  FtermCapabilityContext ctx,
) => switch (ws.preferences.metaKeyMode) {
  .passThrough =>
    ctx.isWeb
        ? 'Always passes unhandled Meta/Cmd chords to the browser.'
        : 'Always passes unhandled Meta/Cmd chords to the OS.',
  .kitty =>
    'Claims unhandled Meta/Cmd chords when Kitty keyboard protocol is active; '
        'passes through in legacy mode.',
  .auto when ctx.isWeb =>
    'Auto (Web): passes unhandled Meta/Cmd chords to the browser.',
  .auto when ctx.isMacOs =>
    'Auto (macOS): passes unhandled Cmd chords to macOS.',
  .auto =>
    'Auto (Desktop): claims unhandled Meta chords when Kitty keyboard '
        'protocol is active.',
};

const List<FtermEnumOption<DockPosition>> _dockPositionOptions =
    <FtermEnumOption<DockPosition>>[
      FtermEnumOption<DockPosition>(
        idSuffix: 'top',
        value: .top,
        label: 'Top',
        settingsKey: ValueKey('settings-dock-top'),
      ),
      FtermEnumOption<DockPosition>(
        idSuffix: 'left',
        value: .left,
        label: 'Left',
        settingsKey: ValueKey('settings-dock-left'),
      ),
      FtermEnumOption<DockPosition>(
        idSuffix: 'hidden',
        value: .hidden,
        label: 'Hidden',
        settingsKey: ValueKey('settings-dock-hidden'),
      ),
    ];

const List<FtermEnumOption<ThemeAppearanceMode>> _appearanceModeOptions =
    <FtermEnumOption<ThemeAppearanceMode>>[
      FtermEnumOption<ThemeAppearanceMode>(
        idSuffix: 'system',
        value: .system,
        label: 'System',
        settingsKey: ValueKey('settings-appearance-system'),
        extraKeywords: 'system',
      ),
      FtermEnumOption<ThemeAppearanceMode>(
        idSuffix: 'dark',
        value: .dark,
        label: 'Dark',
        settingsKey: ValueKey('settings-appearance-dark'),
        extraKeywords: 'dark',
      ),
      FtermEnumOption<ThemeAppearanceMode>(
        idSuffix: 'light',
        value: .light,
        label: 'Light',
        settingsKey: ValueKey('settings-appearance-light'),
        extraKeywords: 'light',
      ),
    ];

const List<FtermEnumOption<ShaderBackendKind?>> _shaderBackendOptions =
    <FtermEnumOption<ShaderBackendKind?>>[
      FtermEnumOption<ShaderBackendKind?>(
        idSuffix: 'auto',
        value: null,
        label: 'Auto',
        settingsKey: ValueKey('settings-shader-backend-auto'),
        extraKeywords: 'impeller webgl auto enable',
      ),
      FtermEnumOption<ShaderBackendKind?>(
        idSuffix: 'disabled',
        value: .disabled,
        label: 'Disabled',
        settingsKey: ValueKey('settings-shader-backend-disabled'),
        extraKeywords: 'disabled off rollback',
      ),
    ];

const List<FtermEnumOption<ShaderAnimationMode>> _shaderAnimationOptions =
    <FtermEnumOption<ShaderAnimationMode>>[
      FtermEnumOption<ShaderAnimationMode>(
        idSuffix: 'always',
        value: .always,
        label: 'Always',
        settingsKey: ValueKey('settings-shader-anim-always'),
        extraKeywords: 'always',
      ),
      FtermEnumOption<ShaderAnimationMode>(
        idSuffix: 'focused',
        value: .focused,
        label: 'Focused',
        settingsKey: ValueKey('settings-shader-anim-focused'),
        extraKeywords: 'focused',
      ),
      FtermEnumOption<ShaderAnimationMode>(
        idSuffix: 'onActivity',
        value: .onActivity,
        label: 'On Activity',
        settingsKey: ValueKey('settings-shader-anim-onActivity'),
        extraKeywords: 'on_activity',
      ),
      FtermEnumOption<ShaderAnimationMode>(
        idSuffix: 'staticOnly',
        value: .staticOnly,
        label: 'Static',
        settingsKey: ValueKey('settings-shader-anim-staticOnly'),
        extraKeywords: 'static',
      ),
    ];

const List<FtermEnumOption<int?>> _maxShaderFpsOptions =
    <FtermEnumOption<int?>>[
      FtermEnumOption<int?>(
        idSuffix: 'uncapped',
        value: null,
        label: 'Uncapped',
        settingsKey: ValueKey('settings-max-shader-fps-auto'),
        extraKeywords: 'Uncapped',
      ),
      FtermEnumOption<int?>(
        idSuffix: '120',
        value: 120,
        label: '120 FPS',
        settingsKey: ValueKey('settings-max-shader-fps-120'),
        extraKeywords: '120 FPS',
      ),
      FtermEnumOption<int?>(
        idSuffix: '60',
        value: 60,
        label: '60 FPS',
        settingsKey: ValueKey('settings-max-shader-fps-60'),
        extraKeywords: '60 FPS',
      ),
      FtermEnumOption<int?>(
        idSuffix: '30',
        value: 30,
        label: '30 FPS',
        settingsKey: ValueKey('settings-max-shader-fps-30'),
        extraKeywords: '30 FPS',
      ),
    ];

const List<FtermEnumOption<CliShaderPolicy>> _localCliShaderPolicyOptions =
    <FtermEnumOption<CliShaderPolicy>>[
      FtermEnumOption<CliShaderPolicy>(
        idSuffix: 'disabled',
        value: .disabled,
        label: 'Disabled',
        extraKeywords: 'disabled',
      ),
      FtermEnumOption<CliShaderPolicy>(
        idSuffix: 'presetsAndTransforms',
        value: .presetsAndTransforms,
        label: 'Presets & Transforms',
        extraKeywords: 'presets_and_transforms',
      ),
      FtermEnumOption<CliShaderPolicy>(
        idSuffix: 'promptCustomGlsl',
        value: .promptCustomGlsl,
        label: 'Prompt Custom GLSL',
        extraKeywords: 'prompt_custom_glsl',
      ),
      FtermEnumOption<CliShaderPolicy>(
        idSuffix: 'allowLocalCustomGlsl',
        value: .allowLocalCustomGlsl,
        label: 'Allow Local GLSL (Dev)',
        extraKeywords: 'allow_local_custom_glsl',
      ),
    ];

const List<FtermEnumOption<CliShaderPolicy>> _remoteCliShaderPolicyOptions =
    <FtermEnumOption<CliShaderPolicy>>[
      FtermEnumOption<CliShaderPolicy>(
        idSuffix: 'disabled',
        value: .disabled,
        label: 'Disabled',
        extraKeywords: 'disabled',
      ),
      FtermEnumOption<CliShaderPolicy>(
        idSuffix: 'presetsAndTransforms',
        value: .presetsAndTransforms,
        label: 'Presets & Transforms',
        extraKeywords: 'presets_and_transforms',
      ),
      FtermEnumOption<CliShaderPolicy>(
        idSuffix: 'promptCustomGlsl',
        value: .promptCustomGlsl,
        label: 'Prompt Custom GLSL',
        extraKeywords: 'prompt_custom_glsl',
      ),
    ];

const List<FtermEnumOption<CliFullPaneShaderMode>> _cliStackingOptions =
    <FtermEnumOption<CliFullPaneShaderMode>>[
      FtermEnumOption<CliFullPaneShaderMode>(
        idSuffix: 'cliBeforeUser',
        value: .cliBeforeUser,
        label: 'CLI Before User',
        settingsKey: ValueKey('settings-cli-full-pane-mode-cli_before_user'),
        extraKeywords: 'cli_before_user',
      ),
      FtermEnumOption<CliFullPaneShaderMode>(
        idSuffix: 'cliReplacesUser',
        value: .cliReplacesUser,
        label: 'CLI Replaces User',
        settingsKey: ValueKey('settings-cli-full-pane-mode-cli_replaces_user'),
        extraKeywords: 'cli_replaces_user',
      ),
      FtermEnumOption<CliFullPaneShaderMode>(
        idSuffix: 'askOnConflict',
        value: .askOnConflict,
        label: 'Ask on Conflict',
        settingsKey: ValueKey('settings-cli-full-pane-mode-ask_on_conflict'),
        extraKeywords: 'ask_on_conflict',
      ),
    ];

const List<FtermEnumOption<FtermMetaKeyMode>> _metaKeyModeOptions =
    <FtermEnumOption<FtermMetaKeyMode>>[
      FtermEnumOption<FtermMetaKeyMode>(
        idSuffix: 'auto',
        value: .auto,
        label: 'Auto',
        settingsKey: ValueKey('settings-meta-mode-auto'),
      ),
      FtermEnumOption<FtermMetaKeyMode>(
        idSuffix: 'passThrough',
        value: .passThrough,
        label: 'Pass Through',
        settingsKey: ValueKey('settings-meta-mode-passThrough'),
      ),
      FtermEnumOption<FtermMetaKeyMode>(
        idSuffix: 'kitty',
        value: .kitty,
        label: 'Kitty Only',
        settingsKey: ValueKey('settings-meta-mode-kitty'),
      ),
    ];

const List<FtermEnumOption<String?>> _posixShellPresetOptions =
    <FtermEnumOption<String?>>[
      FtermEnumOption<String?>(
        idSuffix: 'default',
        value: null,
        label: r'Default ($SHELL)',
        settingsKey: ValueKey('settings-shell-preset-default'),
        extraKeywords: r'Default ($SHELL)',
      ),
      FtermEnumOption<String?>(
        idSuffix: 'zsh',
        value: 'zsh',
        label: 'zsh',
        settingsKey: ValueKey('settings-shell-preset-zsh'),
        extraKeywords: 'zsh',
      ),
      FtermEnumOption<String?>(
        idSuffix: 'bash',
        value: 'bash',
        label: 'bash',
        settingsKey: ValueKey('settings-shell-preset-bash'),
        extraKeywords: 'bash',
      ),
      FtermEnumOption<String?>(
        idSuffix: 'sh',
        value: 'sh',
        label: 'sh',
        settingsKey: ValueKey('settings-shell-preset-sh'),
        extraKeywords: 'sh',
      ),
    ];

const List<FtermEnumOption<String?>> _windowsShellPresetOptions =
    <FtermEnumOption<String?>>[
      FtermEnumOption<String?>(
        idSuffix: 'default',
        value: null,
        label: 'Default',
        settingsKey: ValueKey('settings-shell-preset-default'),
        extraKeywords: 'Default',
      ),
      FtermEnumOption<String?>(
        idSuffix: 'pwsh',
        value: 'pwsh',
        label: 'pwsh',
        settingsKey: ValueKey('settings-shell-preset-pwsh'),
        extraKeywords: 'pwsh',
      ),
      FtermEnumOption<String?>(
        idSuffix: 'powershell',
        value: 'powershell.exe',
        label: 'PowerShell',
        settingsKey: ValueKey('settings-shell-preset-powershell'),
        extraKeywords: 'PowerShell powershell.exe',
      ),
      FtermEnumOption<String?>(
        idSuffix: 'cmd',
        value: 'cmd.exe',
        label: 'cmd',
        settingsKey: ValueKey('settings-shell-preset-cmd'),
        extraKeywords: 'cmd cmd.exe',
      ),
    ];

const List<FtermEnumOption<GpuDriverPreference>> _gpuDriverOptions =
    <FtermEnumOption<GpuDriverPreference>>[
      FtermEnumOption<GpuDriverPreference>(
        idSuffix: 'auto',
        value: .auto,
        label: 'Auto',
        settingsKey: ValueKey('settings-gpu-driver-auto'),
        extraKeywords: 'auto Auto',
      ),
      FtermEnumOption<GpuDriverPreference>(
        idSuffix: 'highPerformance',
        value: .highPerformance,
        label: 'High Performance',
        settingsKey: ValueKey('settings-gpu-driver-highPerformance'),
        extraKeywords: 'highPerformance High Performance',
      ),
      FtermEnumOption<GpuDriverPreference>(
        idSuffix: 'powerSaving',
        value: .powerSaving,
        label: 'Power Saving',
        settingsKey: ValueKey('settings-gpu-driver-powerSaving'),
        extraKeywords: 'powerSaving Power Saving',
      ),
    ];

// ---------------------------------------------------------------------------
// Interface settings
// ---------------------------------------------------------------------------

final FtermEnumSettingDescriptor<DockPosition> _interfaceDockPosition =
    FtermEnumSettingDescriptor<DockPosition>(
      id: 'interface-dock-position',
      paletteIdPrefix: 'interface.dock',
      section: .interface,
      panelId: 'interface-tab-bar',
      panelTitle: 'Tab Bar',
      settingsLabel: 'Tab Bar Position',
      renderStyle: .segmented,
      paletteCategory: 'Interface',
      paletteTitlePrefix: 'Dock Position',
      keywords: 'dock tab bar position top left hidden chrome tabs layout',
      icon: Icons.view_quilt_outlined,
      optionsBuilder: (_) => _dockPositionOptions,
      read: (ws) => ws.dockPosition,
      write: (ws, pos) => ws.setDockPosition(pos),
    );

final FtermToggleSettingDescriptor _interfaceAutoHideTab =
    FtermToggleSettingDescriptor(
      id: 'interface-auto-hide-tab',
      paletteId: 'settings.toggle.auto_hide_single_tab',
      section: .interface,
      panelId: 'interface-tab-bar',
      panelTitle: 'Tab Bar',
      controlKey: const ValueKey('settings-auto-hide-single'),
      settingsLabel: 'Auto-Hide Single Tab',
      settingsCaption: 'Hide tab bar when only one tab is open',
      searchTitle: 'Auto-hide tab bar on single tab',
      paletteCategory: 'Settings',
      paletteTitle: 'Toggle Auto-Hide Single Tab',
      keywords: 'tab bar auto hide single compact minimal interface',
      icon: Icons.tune,
      read: (ws) => ws.preferences.autoHideSingleTab,
      write: (ws, value) => ws.updatePreferences(
        ws.preferences.copyWith(autoHideSingleTab: value),
      ),
    );

final FtermToggleSettingDescriptor _interfaceCopyOnSelect =
    FtermToggleSettingDescriptor(
      id: 'interface-copy-on-select',
      paletteId: 'settings.toggle.copy_on_select',
      section: .interface,
      panelId: 'interface-clipboard',
      panelTitle: 'Clipboard & Selection',
      controlKey: const ValueKey('settings-copy-on-select'),
      settingsLabel: 'Copy on Selection',
      settingsCaption: 'Automatically copy highlighted mouse selections',
      searchTitle: 'Copy on mouse selection',
      paletteCategory: 'Settings',
      paletteTitle: 'Toggle Copy on Selection',
      keywords: 'clipboard yank highlight drag mouse select copy',
      icon: Icons.content_copy,
      read: (ws) => ws.copyOnSelect,
      write: (ws, value) => ws.setCopyOnSelect(value),
    );

final FtermToggleSettingDescriptor _interfaceOsc52 =
    FtermToggleSettingDescriptor(
      id: 'interface-osc52',
      paletteId: 'settings.toggle.osc52',
      section: .interface,
      panelId: 'interface-clipboard',
      panelTitle: 'Clipboard & Selection',
      controlKey: const ValueKey('settings-osc52-toggle'),
      settingsLabel: 'Remote OSC 52 Writes',
      settingsCaption: 'Allow focused remote sessions to write clipboard',
      searchTitle: 'Allow focused remote OSC 52 clipboard writes',
      paletteCategory: 'Settings',
      paletteTitle: 'Toggle Remote OSC 52 Clipboard',
      keywords: 'osc52 osc 52 remote clipboard security paste copy',
      icon: Icons.content_paste,
      read: (ws) => ws.workspaceSettings.osc52Policy == .allowFocused,
      write: (ws, enabled) =>
          ws.setOsc52Policy(enabled ? .allowFocused : .deny),
    );

// ---------------------------------------------------------------------------
// Themes settings
// ---------------------------------------------------------------------------

final FtermEnumSettingDescriptor<ThemeAppearanceMode> _themesAppearanceMode =
    FtermEnumSettingDescriptor<ThemeAppearanceMode>(
      id: 'themes-appearance-mode',
      paletteIdPrefix: 'appearance.mode',
      section: .themes,
      panelId: 'themes-appearance',
      panelTitle: 'Theme & Appearance',
      settingsLabel: 'Appearance Mode',
      renderStyle: .segmented,
      paletteCategory: 'Appearance',
      paletteTitlePrefix: 'Mode',
      keywords: 'appearance mode theme system dark light brightness color',
      icon: Icons.brightness_6_outlined,
      optionsBuilder: (_) => _appearanceModeOptions,
      read: (ws) => ws.workspaceSettings.themeSettings.appearanceMode,
      write: (ws, mode) => ws.setThemeSettings(
        ws.workspaceSettings.themeSettings.copyWith(appearanceMode: mode),
      ),
    );

final FtermCustomSettingDescriptor _themesPreset = FtermCustomSettingDescriptor(
  id: 'themes-preset',
  section: .themes,
  panelId: 'themes-appearance',
  panelTitle: 'Theme & Appearance',
  title: 'Theme Preset',
  keywords: 'color scheme palette theme $_themePresetKeywords',
);

final FtermSliderSettingDescriptor _themesFontSize =
    FtermSliderSettingDescriptor(
      id: 'themes-font-size',
      paletteId: 'appearance.font_size',
      section: .themes,
      panelId: 'themes-typography',
      panelTitle: 'Typography',
      label: 'Font Size',
      paletteCategory: 'Appearance',
      keywords: 'font size text zoom pt points scale typography slider',
      icon: Icons.format_size,
      min: FtermPreferences.minFontSize,
      max: FtermPreferences.maxFontSize,
      step: 1.0,
      divisions: (FtermPreferences.maxFontSize - FtermPreferences.minFontSize)
          .round(),
      usesCustomSettingsWidget: true,
      formatValue: _formatFontSize,
      read: (ws) => ws.effectiveFontSize,
      write: (ws, value) => ws.setFontSize(value),
    );

final FtermSliderSettingDescriptor _themesBgOpacity =
    FtermSliderSettingDescriptor(
      id: 'themes-bg-opacity',
      paletteId: 'appearance.background_opacity',
      section: .themes,
      panelId: 'themes-background',
      panelTitle: 'Background',
      label: 'Background Opacity',
      paletteCategory: 'Appearance',
      keywords:
          'background opacity transparency alpha translucent glass slider',
      icon: Icons.opacity,
      min: 0.0,
      max: 1.0,
      step: 0.05,
      sliderKey: const ValueKey('settings-background-opacity-slider'),
      valueKey: const ValueKey('settings-background-opacity-value'),
      formatValue: _formatPercent,
      read: (ws) => ws.backgroundOpacity,
      write: (ws, value) => ws.setBackgroundOpacity(value),
    );

const FtermCustomSettingDescriptor _themesWallpaper =
    FtermCustomSettingDescriptor(
      id: 'themes-wallpaper',
      section: .themes,
      panelId: 'themes-background',
      panelTitle: 'Background',
      title: 'Wallpaper',
      keywords: 'background image png jpeg webp picture wallpaper',
    );

// ---------------------------------------------------------------------------
// Shaders settings
// ---------------------------------------------------------------------------

final FtermEnumSettingDescriptor<ShaderBackendKind?> _shadersBackend =
    FtermEnumSettingDescriptor<ShaderBackendKind?>(
      id: 'shaders-backend',
      paletteIdPrefix: 'shader.backend',
      section: .shaders,
      panelId: 'shaders-pipeline',
      panelTitle: 'Pipeline & Actions',
      settingsLabel: 'Shader Backend',
      renderStyle: .segmented,
      paletteCategory: 'Shader',
      paletteTitlePrefix: 'Backend',
      keywords: 'shader backend gpu impeller webgl auto disabled shaders',
      icon: Icons.memory_outlined,
      optionsBuilder: (_) => _shaderBackendOptions,
      read: (ws) => ws.shaderBackendOverride,
      write: (ws, override) => ws.setShaderBackendOverride(override),
    );

const FtermCustomSettingDescriptor _shadersActions =
    FtermCustomSettingDescriptor(
      id: 'shaders-actions',
      section: .shaders,
      panelId: 'shaders-pipeline',
      panelTitle: 'Pipeline & Actions',
      title: 'Shader Editor, Folder & Web GLSL Upload',
      keywords:
          'new shader tab open folder upload web glsl shadertoy ghostty '
          'reload ctrl shift f5',
    );

const FtermCustomSettingDescriptor _shadersBgChain =
    FtermCustomSettingDescriptor(
      id: 'shaders-bg-chain',
      section: .shaders,
      panelId: 'shaders-background',
      panelTitle: 'Background Shaders',
      title: 'Background Shader Chain',
      keywords: 'wallpaper_wave background pass chain glsl order',
    );

const FtermCustomSettingDescriptor _shadersFgChain =
    FtermCustomSettingDescriptor(
      id: 'shaders-fg-chain',
      section: .shaders,
      panelId: 'shaders-foreground',
      panelTitle: 'Foreground Shaders',
      title: 'Foreground Shader Chain',
      keywords:
          'crt scanline phosphor glow cursor_glow scanline_overlay '
          'crt_lottes phosphor_glow retro_phosphor postprocess pass chain glsl',
    );

const FtermCustomSettingDescriptor _shadersCustomPath =
    FtermCustomSettingDescriptor(
      id: 'shaders-custom-path',
      section: .shaders,
      panelId: 'shaders-custom-params',
      panelTitle: 'Custom Shaders & Parameters',
      title: 'Add Custom .glsl Path',
      keywords: 'custom glsl file path shadertoy ghostty',
      visibility: .desktopOnly,
      paletteExcludedReason:
          'Free-form local .glsl file path input edited inline in Settings.',
    );

const FtermCustomSettingDescriptor _shadersParams =
    FtermCustomSettingDescriptor(
      id: 'shaders-params',
      section: .shaders,
      panelId: 'shaders-custom-params',
      panelTitle: 'Custom Shaders & Parameters',
      title: 'Shader Parameters (uParams0)',
      keywords: 'uparams uniforms sliders intensity x y z',
    );

final FtermEnumSettingDescriptor<ShaderAnimationMode> _shadersAnimationMode =
    FtermEnumSettingDescriptor<ShaderAnimationMode>(
      id: 'shaders-animation-mode',
      paletteIdPrefix: 'shader.animation',
      section: .shaders,
      panelId: 'shaders-playback',
      panelTitle: 'Playback & Frame Pacing',
      settingsLabel: 'Animation Mode',
      searchTitle: 'Shader Animation Mode',
      renderStyle: .segmented,
      paletteCategory: 'Shader',
      paletteTitlePrefix: 'Animation Mode',
      keywords:
          'shader animation playback focused always on activity static itime '
          'idle',
      icon: Icons.animation,
      optionsBuilder: (_) => _shaderAnimationOptions,
      read: (ws) => ws.shaderAnimationMode,
      write: (ws, mode) => ws.setShaderAnimationMode(mode),
    );

final FtermEnumSettingDescriptor<int?> _shadersMaxFps =
    FtermEnumSettingDescriptor<int?>(
      id: 'shaders-max-fps',
      paletteIdPrefix: 'shader.max_fps',
      section: .shaders,
      panelId: 'shaders-playback',
      panelTitle: 'Playback & Frame Pacing',
      settingsLabel: 'Max Shader FPS',
      settingsHintBuilder: (_, _) =>
          'Cap to 60 or 120 FPS on integrated graphics for smoother pacing.',
      renderStyle: .segmented,
      paletteCategory: 'Shader',
      paletteTitlePrefix: 'Max FPS',
      keywords:
          'shader fps frame rate cap uncapped 120 60 30 pacing battery '
          'integrated',
      icon: Icons.speed,
      optionsBuilder: (_) => _maxShaderFpsOptions,
      read: (ws) => ws.maxShaderFps,
      write: (ws, maxFps) => ws.setMaxShaderFps(maxFps),
    );

final FtermEnumSettingDescriptor<CliShaderPolicy> _shadersCliLocalPolicy =
    FtermEnumSettingDescriptor<CliShaderPolicy>(
      id: 'shaders-cli-local-policy',
      paletteIdPrefix: 'shader.cli_local_policy',
      section: .shaders,
      panelId: 'shaders-cli',
      panelTitle: 'CLI Shaders & Transforms (ESC _ S)',
      settingsLabel: 'Local Pane Policy',
      dropdownKey: const ValueKey('settings-local-cli-shader-policy'),
      renderStyle: .dropdown,
      paletteCategory: 'CLI Shader',
      paletteTitlePrefix: 'Local Policy',
      keywords:
          'cli esc s local shader transform presets prompt custom glsl policy '
          'trust',
      icon: Icons.security_outlined,
      optionsBuilder: (_) => _localCliShaderPolicyOptions,
      read: (ws) => ws.localCliShaderPolicy,
      write: (ws, policy) => ws.setLocalCliShaderPolicy(policy),
    );

final FtermEnumSettingDescriptor<CliShaderPolicy> _shadersCliRemotePolicy =
    FtermEnumSettingDescriptor<CliShaderPolicy>(
      id: 'shaders-cli-remote-policy',
      paletteIdPrefix: 'shader.cli_remote_policy',
      section: .shaders,
      panelId: 'shaders-cli',
      panelTitle: 'CLI Shaders & Transforms (ESC _ S)',
      settingsLabel: 'Remote Cast Policy',
      dropdownKey: const ValueKey('settings-remote-cli-shader-policy'),
      renderStyle: .dropdown,
      paletteCategory: 'CLI Shader',
      paletteTitlePrefix: 'Remote Policy',
      keywords: 'cli esc s remote cast relay shader trust policy',
      icon: Icons.security_outlined,
      optionsBuilder: (_) => _remoteCliShaderPolicyOptions,
      read: (ws) => ws.remoteCliShaderPolicy,
      write: (ws, policy) => ws.setRemoteCliShaderPolicy(policy),
    );

final FtermEnumSettingDescriptor<CliFullPaneShaderMode> _shadersCliStacking =
    FtermEnumSettingDescriptor<CliFullPaneShaderMode>(
      id: 'shaders-cli-stacking',
      paletteIdPrefix: 'shader.cli_stacking',
      section: .shaders,
      panelId: 'shaders-cli',
      panelTitle: 'CLI Shaders & Transforms (ESC _ S)',
      settingsLabel: 'Full-Pane Stacking',
      searchTitle: 'Full-Pane CLI Shader Stacking',
      renderStyle: .segmented,
      paletteCategory: 'CLI Shader',
      paletteTitlePrefix: 'Stacking',
      keywords:
          'cli before user replaces ask conflict stacking full pane shader '
          'replace',
      icon: Icons.layers_outlined,
      optionsBuilder: (_) => _cliStackingOptions,
      read: (ws) => ws.cliFullPaneShaderMode,
      write: (ws, mode) => ws.setCliFullPaneShaderMode(mode),
    );

final FtermToggleSettingDescriptor _shadersCliDevTrust =
    FtermToggleSettingDescriptor(
      id: 'shaders-cli-dev-trust',
      paletteId: 'shader.cli_dev_auto_trust',
      section: .shaders,
      panelId: 'shaders-cli',
      panelTitle: 'CLI Shaders & Transforms (ESC _ S)',
      controlKey: const ValueKey('settings-cli-dev-auto-trust'),
      settingsLabel: 'Dev Auto-Trust GLSL',
      settingsCaption: 'Auto-trust local custom CLI GLSL without prompting',
      searchTitle: 'Dev Auto-Trust Local Custom GLSL',
      paletteCategory: 'CLI Shader',
      paletteTitle: 'Toggle Dev Auto-Trust GLSL',
      keywords: 'cli dev auto trust local custom glsl shader',
      icon: Icons.verified_user_outlined,
      read: (ws) => ws.localCliShaderPolicy == .allowLocalCustomGlsl,
      write: (ws, enabled) => ws.setLocalCliShaderPolicy(
        enabled ? .allowLocalCustomGlsl : .promptCustomGlsl,
      ),
    );

const FtermCustomSettingDescriptor _shadersCliTrustedHashes =
    FtermCustomSettingDescriptor(
      id: 'shaders-cli-trusted-hashes',
      section: .shaders,
      panelId: 'shaders-cli',
      panelTitle: 'CLI Shaders & Transforms (ESC _ S)',
      title: 'Trusted CLI GLSL Hashes',
      keywords: 'sha256 trusted hashes reset clear cli glsl',
    );

// ---------------------------------------------------------------------------
// Keyboard settings
// ---------------------------------------------------------------------------

final FtermEnumSettingDescriptor<FtermMetaKeyMode> _keyboardMetaPolicy =
    FtermEnumSettingDescriptor<FtermMetaKeyMode>(
      id: 'keyboard-meta-policy',
      paletteIdPrefix: 'keyboard.meta_policy',
      section: .keyboard,
      panelId: 'keyboard-meta',
      panelTitle: 'Meta / Cmd Key Policy',
      settingsLabel: 'Meta / Cmd Mode',
      searchTitle: 'Meta / Cmd Key Policy',
      settingsHintBuilder: _metaKeyPolicySummary,
      settingsHintKey: const ValueKey('settings-meta-mode-summary'),
      renderStyle: .segmented,
      paletteCategory: 'Keyboard',
      paletteTitlePrefix: 'Meta Key Policy',
      keywords:
          'meta cmd command super key policy auto pass through kitty keyboard',
      icon: Icons.keyboard_outlined,
      optionsBuilder: (_) => _metaKeyModeOptions,
      read: (ws) => ws.preferences.metaKeyMode,
      write: (ws, mode) =>
          ws.updatePreferences(ws.preferences.copyWith(metaKeyMode: mode)),
    );

const FtermCustomSettingDescriptor _keyboardIgnoredChords =
    FtermCustomSettingDescriptor(
      id: 'keyboard-ignored-chords',
      section: .keyboard,
      panelId: 'keyboard-passthrough',
      panelTitle: 'Ignored Chords (Do Not Intercept)',
      title: 'Ignored Passthrough Key Chords',
      keywords:
          'ignored passthrough shortcuts keybindings chord record preset '
          'alt+f4 ctrl+shift+i',
      paletteExcludedReason:
          'Interactive key chord recorder and chip editor managed inline in '
          'Settings.',
    );

final FtermToggleSettingDescriptor
_keyboardMacosOption = FtermToggleSettingDescriptor(
  id: 'keyboard-macos-option',
  paletteId: 'settings.toggle.macos_option_as_alt',
  section: .keyboard,
  panelId: 'keyboard-host-keys',
  panelTitle: 'Host & Platform Keys',
  controlKey: const ValueKey('settings-macos-option-as-alt'),
  settingsLabel: 'macOS Option as Alt',
  settingsCaption: 'Emit Alt+key instead of macOS Option dead-key composition',
  searchTitle: 'macOS Option key acts as Alt',
  paletteCategory: 'Keyboard',
  paletteTitle: 'Toggle macOS Option as Alt',
  keywords: 'macos option alt meta keyboard dead key',
  icon: Icons.keyboard_outlined,
  read: (ws) => ws.preferences.macosOptionAsAlt,
  write: (ws, value) =>
      ws.updatePreferences(ws.preferences.copyWith(macosOptionAsAlt: value)),
);

final FtermToggleSettingDescriptor _keyboardF12Shortcuts =
    FtermToggleSettingDescriptor(
      id: 'keyboard-f12-shortcuts',
      paletteId: 'settings.toggle.f12_shortcuts',
      section: .keyboard,
      panelId: 'keyboard-host-keys',
      panelTitle: 'Host & Platform Keys',
      controlKey: const ValueKey('settings-f12-toggle'),
      settingsLabel: 'F12 Host Shortcuts',
      settingsCaption: 'Enable F12 screenshot and Shift+F12 atlas reload keys',
      searchTitle: 'Enable F12 host shortcuts (screenshot/atlas)',
      paletteCategory: 'Keyboard',
      paletteTitle: 'Toggle F12 Shortcuts',
      keywords: 'f12 screenshot atlas reload host shortcut debug',
      icon: Icons.keyboard_outlined,
      read: (ws) => ws.f12ShortcutsEnabled,
      write: (ws, value) => ws.setF12ShortcutsEnabled(value),
    );

// ---------------------------------------------------------------------------
// Shell settings (desktop)
// ---------------------------------------------------------------------------

final FtermEnumSettingDescriptor<String?> _shellPreset =
    FtermEnumSettingDescriptor<String?>(
      id: 'shell-preset',
      paletteIdPrefix: 'shell.preset',
      section: .shell,
      panelId: 'shell-default',
      panelTitle: 'Default Shell',
      settingsLabel: 'Shell Preset',
      settingsHintBuilder: (_, _) =>
          'Applies to newly opened tabs and split panes.',
      renderStyle: .segmented,
      paletteCategory: 'Shell',
      paletteTitlePrefix: 'Shell Preset',
      keywords:
          'default zsh bash sh pwsh powershell cmd shell preset override '
          'executable terminal',
      icon: Icons.terminal,
      visibility: .localDesktopShell,
      optionsBuilder: (ctx) =>
          ctx.isWindows ? _windowsShellPresetOptions : _posixShellPresetOptions,
      read: (ws) => ws.preferences.shellExecutable,
      write: (ws, selected) => ws.updatePreferences(
        ws.preferences.copyWith(
          shellExecutable: selected,
          clearShellExecutable: selected == null,
        ),
      ),
    );

const FtermCustomSettingDescriptor _shellExecutable =
    FtermCustomSettingDescriptor(
      id: 'shell-executable',
      section: .shell,
      panelId: 'shell-default',
      panelTitle: 'Default Shell',
      title: 'Shell Executable',
      keywords: 'shell path binary executable /bin/zsh powershell pwsh cmd',
      visibility: .localDesktopShell,
      paletteExcludedReason:
          'Free-form shell executable path text input edited inline in '
          'Settings.',
    );

const FtermCustomSettingDescriptor _shellArguments =
    FtermCustomSettingDescriptor(
      id: 'shell-arguments',
      section: .shell,
      panelId: 'shell-default',
      panelTitle: 'Default Shell',
      title: 'Shell Arguments',
      keywords: 'shell flags args arguments norc tmux startup',
      visibility: .localDesktopShell,
      paletteExcludedReason:
          'Free-form shell CLI arguments text input edited inline in Settings.',
    );

final FtermToggleSettingDescriptor _shellLogin = FtermToggleSettingDescriptor(
  id: 'shell-login',
  paletteId: 'settings.toggle.login_shell',
  section: .shell,
  panelId: 'shell-default',
  panelTitle: 'Default Shell',
  controlKey: const ValueKey('settings-login-shell'),
  settingsLabel: 'Login Shell (-l)',
  settingsCaption: 'Launch POSIX shells with -l when arguments are empty',
  searchTitle: 'Run as login shell (-l)',
  paletteCategory: 'Shell',
  paletteTitle: 'Toggle Login Shell (-l)',
  keywords: 'login shell -l profile environment posix',
  icon: Icons.terminal,
  visibility: .localDesktopShell,
  read: (ws) => ws.preferences.loginShell,
  write: (ws, value) =>
      ws.updatePreferences(ws.preferences.copyWith(loginShell: value)),
);

// ---------------------------------------------------------------------------
// System settings
// ---------------------------------------------------------------------------

final FtermToggleSettingDescriptor _systemPerfHud =
    FtermToggleSettingDescriptor(
      id: 'system-perf-hud',
      paletteId: 'settings.toggle.perf_hud',
      section: .system,
      panelId: 'system-graphics',
      panelTitle: 'Graphics & Performance',
      controlKey: const ValueKey('settings-perf-hud-switch'),
      settingsLabel: 'Performance HUD',
      settingsCaption: 'Show live FPS & frame timing overlay (Ctrl+Shift+F9)',
      searchTitle: 'Performance HUD (FPS • Ctrl+Shift+F9)',
      paletteCategory: 'Settings',
      paletteTitle: 'Toggle Performance HUD',
      keywords: 'perf hud fps vram frame timing overlay diagnostics',
      icon: Icons.speed,
      shortcut: FtermShortcuts.togglePerfHud,
      read: (ws) => ws.showPerfHud,
      write: (ws, value) => ws.setShowPerfHud(value),
    );

final FtermEnumSettingDescriptor<GpuDriverPreference> _systemGpuDriver =
    FtermEnumSettingDescriptor<GpuDriverPreference>(
      id: 'system-gpu-driver',
      paletteIdPrefix: 'system.gpu_driver',
      section: .system,
      panelId: 'system-graphics',
      panelTitle: 'Graphics & Performance',
      settingsLabel: 'GPU Adapter',
      searchTitle: 'Graphics Driver (Desktop GPU Adapter)',
      renderStyle: .segmented,
      paletteCategory: 'System',
      paletteTitlePrefix: 'GPU Driver',
      keywords:
          'gpu graphics adapter driver discrete integrated high performance '
          'power saving dxgi windows restart',
      icon: Icons.memory_outlined,
      visibility: .windowsDesktop,
      optionsBuilder: (_) => _gpuDriverOptions,
      read: (ws) => ws.gpuDriverPreference,
      write: (ws, pref) => ws.setGpuDriverPreference(pref),
    );

final FtermToggleSettingDescriptor _systemAudioMute =
    FtermToggleSettingDescriptor(
      id: 'system-audio-mute',
      paletteId: 'settings.toggle.mute_audio',
      section: .system,
      panelId: 'system-sound',
      panelTitle: 'Sound',
      controlKey: const ValueKey('settings-audio-mute'),
      settingsLabel: 'Mute Terminal Audio',
      settingsCaption: 'Silence terminal bell & APC synthesized audio',
      searchTitle: 'Mute terminal bell & APC audio',
      paletteCategory: 'Settings',
      paletteTitle: 'Toggle Mute Audio',
      keywords: 'sound audio bell beep apc mute silence',
      icon: Icons.volume_up,
      activeIcon: Icons.volume_off,
      read: (ws) => ws.preferences.audioMuted,
      write: (ws, value) =>
          ws.updatePreferences(ws.preferences.copyWith(audioMuted: value)),
    );

final FtermSliderSettingDescriptor _systemAudioVolume =
    FtermSliderSettingDescriptor(
      id: 'system-audio-volume',
      paletteId: 'system.audio_volume',
      section: .system,
      panelId: 'system-sound',
      panelTitle: 'Sound',
      label: 'Output Volume',
      paletteCategory: 'System',
      keywords: 'sound audio output volume gain loudness slider',
      icon: Icons.volume_up,
      min: 0.0,
      max: 1.0,
      step: 0.05,
      sliderKey: const ValueKey('settings-audio-volume-slider'),
      valueKey: const ValueKey('settings-audio-volume-value'),
      formatValue: _formatPercent,
      read: (ws) => ws.preferences.audioVolume,
      write: (ws, value) =>
          ws.updatePreferences(ws.preferences.copyWith(audioVolume: value)),
    );

// ---------------------------------------------------------------------------
// Automation settings (desktop)
// ---------------------------------------------------------------------------

final FtermToggleSettingDescriptor _automationEnable =
    FtermToggleSettingDescriptor(
      id: 'automation-enable',
      paletteId: 'settings.toggle.automation_driver',
      section: .automation,
      panelId: 'automation-driver',
      panelTitle: 'HTTP Automation Driver',
      controlKey: const ValueKey('automation-enable-switch'),
      settingsLabel: 'Enable HTTP Driver',
      settingsCaption: 'Loopback 127.0.0.1 only; resets off on restart.',
      searchTitle: 'Enable HTTP Automation Driver',
      paletteCategory: 'Automation',
      paletteTitle: 'Toggle HTTP Automation Driver',
      keywords: 'automation http server loopback driver enable api',
      icon: Icons.smart_toy_outlined,
      visibility: .desktopOnly,
      read: (ws) => ws.automationDriver.isRunning,
      write: (ws, enabled) => ws.automationDriver.setEnabled(enabled),
    );

const FtermCustomSettingDescriptor _automationPort =
    FtermCustomSettingDescriptor(
      id: 'automation-port',
      section: .automation,
      panelId: 'automation-network',
      panelTitle: 'Network & Authentication',
      title: 'Loopback Port',
      keywords: 'port 127.0.0.1 localhost tcp automation http',
      visibility: .desktopOnly,
      paletteExcludedReason:
          'Validated loopback TCP port text input managed inline in Settings.',
    );

const FtermCustomSettingDescriptor _automationPassword =
    FtermCustomSettingDescriptor(
      id: 'automation-password',
      section: .automation,
      panelId: 'automation-network',
      panelTitle: 'Network & Authentication',
      title: 'Bearer Password',
      keywords: 'bearer token password auth header regenerate copy secret',
      visibility: .desktopOnly,
      paletteExcludedReason:
          'Sensitive bearer token viewer, copy, and regenerate controls '
          'managed inline in Settings.',
    );

final FtermToggleSettingDescriptor _automationPtyScope =
    FtermToggleSettingDescriptor(
      id: 'automation-pty-scope',
      paletteId: 'settings.toggle.automation_pty_scope',
      section: .automation,
      panelId: 'automation-scope',
      panelTitle: 'Terminal Access Scope',
      controlKey: const ValueKey('automation-allow-pty-checkbox'),
      settingsLabel: 'Allow PTY Access',
      settingsCaption: 'Allow PTY input, shell spawning & screen readback',
      searchTitle: 'Allow PTY input, shell spawning & screen readback',
      paletteCategory: 'Automation',
      paletteTitle: 'Toggle Automation PTY Access',
      keywords: 'automation pty input spawn readback mouse scope security',
      icon: Icons.smart_toy_outlined,
      visibility: .desktopOnly,
      read: (ws) => ws.automationDriver.allowPty,
      write: (ws, enabled) => ws.automationDriver.setAllowPty(enabled),
    );

// ---------------------------------------------------------------------------
// Updates settings (desktop)
// ---------------------------------------------------------------------------

const FtermCustomSettingDescriptor _updatesCheck = FtermCustomSettingDescriptor(
  id: 'updates-check',
  section: .updates,
  panelId: 'updates-application',
  panelTitle: 'Application Updates',
  title: 'Check for Updates',
  keywords: 'update check version release github download upgrade',
  visibility: .updatesSupported,
);

final FtermToggleSettingDescriptor _updatesDaily = FtermToggleSettingDescriptor(
  id: 'updates-daily',
  paletteId: 'settings.toggle.updates_daily',
  section: .updates,
  panelId: 'updates-application',
  panelTitle: 'Application Updates',
  controlKey: const ValueKey('settings-update-daily'),
  settingsLabel: 'Automatic Check',
  settingsCaption: 'Check daily for updates',
  searchTitle: 'Check daily for updates',
  paletteCategory: 'Updates',
  paletteTitle: 'Toggle Daily Update Checks',
  keywords: 'update daily automatic background check schedule',
  icon: Icons.system_update_alt,
  visibility: .updatesSupported,
  read: (ws) => ws.preferences.updateCheckMode == .daily,
  write: (ws, daily) => ws.updatePreferences(
    ws.preferences.copyWith(updateCheckMode: daily ? .daily : .manual),
  ),
);

final FtermToggleSettingDescriptor _updatesPrereleases =
    FtermToggleSettingDescriptor(
      id: 'updates-prereleases',
      paletteId: 'settings.toggle.updates_prereleases',
      section: .updates,
      panelId: 'updates-application',
      panelTitle: 'Application Updates',
      controlKey: const ValueKey('settings-update-prereleases'),
      settingsLabel: 'Pre-Releases',
      settingsCaption: 'Include pre-release builds (rc / beta)',
      searchTitle: 'Include pre-releases',
      paletteCategory: 'Updates',
      paletteTitle: 'Toggle Pre-Release Updates',
      keywords: 'update prerelease pre-release beta rc canary',
      icon: Icons.system_update_alt,
      visibility: .updatesSupported,
      read: (ws) => ws.preferences.includePrereleases,
      write: (ws, include) => ws.updatePreferences(
        ws.preferences.copyWith(includePrereleases: include),
      ),
    );

// ---------------------------------------------------------------------------
// Public registries & lookup helpers
// ---------------------------------------------------------------------------

/// Canonical ordered list of all setting descriptors matching the Settings
/// sidebar section and panel hierarchy.
final List<FtermDescriptor> allSettingDescriptors =
    List<FtermDescriptor>.unmodifiable(<FtermDescriptor>[
      // Interface
      _interfaceDockPosition,
      _interfaceAutoHideTab,
      _interfaceCopyOnSelect,
      _interfaceOsc52,
      // Themes
      _themesAppearanceMode,
      _themesPreset,
      _themesFontSize,
      _themesBgOpacity,
      _themesWallpaper,
      // Shaders
      _shadersBackend,
      _shadersActions,
      _shadersBgChain,
      _shadersFgChain,
      _shadersCustomPath,
      _shadersParams,
      _shadersAnimationMode,
      _shadersMaxFps,
      _shadersCliLocalPolicy,
      _shadersCliRemotePolicy,
      _shadersCliStacking,
      _shadersCliDevTrust,
      _shadersCliTrustedHashes,
      // Keyboard
      _keyboardMetaPolicy,
      _keyboardIgnoredChords,
      _keyboardMacosOption,
      _keyboardF12Shortcuts,
      // Shell
      _shellPreset,
      _shellExecutable,
      _shellArguments,
      _shellLogin,
      // System
      _systemPerfHud,
      _systemGpuDriver,
      _systemAudioMute,
      _systemAudioVolume,
      // Automation
      _automationEnable,
      _automationPort,
      _automationPassword,
      _automationPtyScope,
      // Updates
      _updatesCheck,
      _updatesDaily,
      _updatesPrereleases,
    ]);

/// Ordered Appearance setting descriptors projected into the Command Palette
/// Appearance group.
final List<FtermDescriptor> appearanceSettingDescriptors =
    List<FtermDescriptor>.unmodifiable(<FtermDescriptor>[
      _themesBgOpacity,
      _themesFontSize,
      _themesAppearanceMode,
    ]);

/// Ordered Shader control setting descriptors projected into the Command
/// Palette Shader Control group.
final List<FtermDescriptor> shaderControlSettingDescriptors =
    List<FtermDescriptor>.unmodifiable(<FtermDescriptor>[
      _shadersBackend,
      _shadersAnimationMode,
      _shadersMaxFps,
    ]);

/// Ordered CLI shader policy setting descriptors projected into the Command
/// Palette CLI Shader group.
final List<FtermDescriptor> cliShaderSettingDescriptors =
    List<FtermDescriptor>.unmodifiable(<FtermDescriptor>[
      _shadersCliLocalPolicy,
      _shadersCliRemotePolicy,
      _shadersCliStacking,
      _shadersCliDevTrust,
    ]);

/// Ordered Settings toggle and volume slider descriptors projected into the
/// Command Palette Settings Toggle group.
final List<FtermDescriptor> paletteSettingsToggleDescriptors =
    List<FtermDescriptor>.unmodifiable(<FtermDescriptor>[
      _interfaceAutoHideTab,
      _interfaceCopyOnSelect,
      _interfaceOsc52,
      _systemAudioMute,
      _systemAudioVolume,
      _systemPerfHud,
      _keyboardMacosOption,
      _keyboardF12Shortcuts,
      _shellLogin,
      _automationEnable,
      _automationPtyScope,
      _updatesDaily,
      _updatesPrereleases,
    ]);

/// Ordered Settings enum descriptors projected into the Command Palette
/// Settings Enum group.
final List<FtermDescriptor> paletteSettingsEnumDescriptors =
    List<FtermDescriptor>.unmodifiable(<FtermDescriptor>[
      _interfaceDockPosition,
      _keyboardMetaPolicy,
      _shellPreset,
      _systemGpuDriver,
    ]);

final Map<String, FtermDescriptor> _settingDescriptorsById =
    Map<String, FtermDescriptor>.unmodifiable(<String, FtermDescriptor>{
      for (final descriptor in allSettingDescriptors) descriptor.id: descriptor,
    });

final Map<FtermSettingsSection, List<FtermDescriptor>>
_settingDescriptorsBySection =
    Map<FtermSettingsSection, List<FtermDescriptor>>.unmodifiable(
      <FtermSettingsSection, List<FtermDescriptor>>{
        for (final section in FtermSettingsSection.values)
          section: List<FtermDescriptor>.unmodifiable(<FtermDescriptor>[
            for (final descriptor in allSettingDescriptors)
              if (_sectionOf(descriptor) == section) descriptor,
          ]),
      },
    );

FtermSettingsSection? _sectionOf(FtermDescriptor descriptor) =>
    switch (descriptor) {
      FtermToggleSettingDescriptor(:final section) => section,
      FtermEnumSettingDescriptor(:final section) => section,
      FtermSliderSettingDescriptor(:final section) => section,
      FtermCustomSettingDescriptor(:final section) => section,
      FtermActionDescriptor() => null,
    };

/// Looks up a declared setting descriptor by its stable [id], or returns `null`
/// if no setting with [id] exists.
FtermDescriptor? settingDescriptorById(String id) =>
    _settingDescriptorsById[id];

/// Returns the ordered unmodifiable list of setting descriptors belonging to
/// [section].
List<FtermDescriptor> settingDescriptorsForSection(
  FtermSettingsSection section,
) => _settingDescriptorsBySection[section] ?? const <FtermDescriptor>[];
