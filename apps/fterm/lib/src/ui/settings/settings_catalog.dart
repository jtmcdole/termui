import 'package:material_ui/material_ui.dart';
import 'package:termui/termui.dart' as tui;

import '../../workspace/fterm_workspace_controller.dart';

/// Metadata describing one clickable category in the Blender-style left rail.
final class SettingsSectionMeta {
  /// Target settings section enum value.
  final FtermSettingsSection section;

  /// Human-readable sidebar label.
  final String label;

  /// Compact sidebar icon.
  final IconData icon;

  /// Visual cluster index (`0` = display, `1` = input/shell, `2` = system).
  final int cluster;

  /// Whether this category is hidden in Web builds.
  final bool desktopOnly;

  /// Creates sidebar section metadata.
  const SettingsSectionMeta({
    required this.section,
    required this.label,
    required this.icon,
    required this.cluster,
    this.desktopOnly = false,
  });
}

/// Searchable setting entry belonging to a panel inside a section.
final class SettingsSearchItem {
  /// Unique identifier used to filter controls inside a panel during search.
  final String id;

  /// Owning section.
  final FtermSettingsSection section;

  /// Owning collapsible panel identifier.
  final String panelId;

  /// Display title of the owning panel.
  final String panelTitle;

  /// Setting label displayed to users.
  final String title;

  /// Additional searchable keywords, option values, and synonyms.
  final String keywords;

  /// Whether this entry only exists on desktop hosts (local PTY / filesystem).
  final bool desktopOnly;

  /// Whether this entry only renders on native Windows builds.
  final bool windowsOnly;

  /// Creates a searchable setting descriptor.
  const SettingsSearchItem({
    required this.id,
    required this.section,
    required this.panelId,
    required this.panelTitle,
    required this.title,
    required this.keywords,
    this.desktopOnly = false,
    this.windowsOnly = false,
  });
}

/// Matched panel group returned by [SettingsCatalog.search].
final class SettingsSearchPanelMatch {
  /// Owning sidebar section metadata.
  final SettingsSectionMeta sectionMeta;

  /// Matched panel identifier.
  final String panelId;

  /// Display title of the matched panel.
  final String panelTitle;

  /// Identifiers of the matched items inside [panelId].
  final Set<String> matchedItemIds;

  /// Creates a matched panel group.
  const SettingsSearchPanelMatch({
    required this.sectionMeta,
    required this.panelId,
    required this.panelTitle,
    required this.matchedItemIds,
  });
}

/// Cross-category search output containing sidebar badge counts and ordered
/// panel matches.
final class SettingsSearchResult {
  /// Number of matching settings per sidebar section.
  final Map<FtermSettingsSection, int> sectionMatchCounts;

  /// Ordered matched panels across all visible sections.
  final List<SettingsSearchPanelMatch> panelMatches;

  /// Total number of matching setting entries.
  final int totalMatches;

  /// Creates a search result snapshot.
  const SettingsSearchResult({
    required this.sectionMatchCounts,
    required this.panelMatches,
    required this.totalMatches,
  });
}

typedef _IndexedSearchItem = ({
  SettingsSearchItem item,
  SettingsSectionMeta sectionMeta,
  String haystack,
});

/// Canonical registry of Blender-style Settings categories, panel collapse
/// defaults, and cross-category search metadata.
abstract final class SettingsCatalog {
  /// Panel identifiers that start collapsed by default when browsing normally.
  static const Set<String> defaultCollapsedPanels = <String>{'shaders-cli'};

  static final RegExp _whitespace = RegExp(r'\s+');

  /// Ordered metadata for all sidebar sections across 3 visual clusters.
  static const List<SettingsSectionMeta> allSections = <SettingsSectionMeta>[
    SettingsSectionMeta(
      section: .interface,
      label: 'Interface',
      icon: Icons.tune,
      cluster: 0,
    ),
    SettingsSectionMeta(
      section: .themes,
      label: 'Themes',
      icon: Icons.palette_outlined,
      cluster: 0,
    ),
    SettingsSectionMeta(
      section: .shaders,
      label: 'Shaders',
      icon: Icons.auto_awesome_outlined,
      cluster: 0,
    ),
    SettingsSectionMeta(
      section: .keyboard,
      label: 'Keyboard',
      icon: Icons.keyboard_outlined,
      cluster: 1,
    ),
    SettingsSectionMeta(
      section: .shell,
      label: 'Shell',
      icon: Icons.terminal,
      cluster: 1,
      desktopOnly: true,
    ),
    SettingsSectionMeta(
      section: .system,
      label: 'System',
      icon: Icons.memory_outlined,
      cluster: 2,
    ),
    SettingsSectionMeta(
      section: .automation,
      label: 'Automation',
      icon: Icons.smart_toy_outlined,
      cluster: 2,
      desktopOnly: true,
    ),
    SettingsSectionMeta(
      section: .updates,
      label: 'Updates',
      icon: Icons.system_update_alt,
      cluster: 2,
      desktopOnly: true,
    ),
  ];

  static final Map<FtermSettingsSection, SettingsSectionMeta> _metaBySection =
      Map<FtermSettingsSection, SettingsSectionMeta>.unmodifiable({
        for (final meta in allSections) meta.section: meta,
      });

  /// Returns metadata for [section].
  static SettingsSectionMeta metaFor(FtermSettingsSection section) =>
      _metaBySection[section]!;

  /// Returns the sidebar sections visible on the active platform.
  static List<SettingsSectionMeta> visibleSections({
    required bool isWeb,
    required bool isDesktopHost,
    required bool supportsUpdates,
  }) => <SettingsSectionMeta>[
    for (final meta in allSections)
      if (_isSectionVisible(
        meta.section,
        isWeb: isWeb,
        isDesktopHost: isDesktopHost,
        supportsUpdates: supportsUpdates,
      ))
        meta,
  ];

  /// Resolves [candidate] to a visible section on the current platform,
  /// falling back to [FtermSettingsSection.interface] when hidden.
  static FtermSettingsSection resolveVisibleSection(
    FtermSettingsSection candidate, {
    required bool isWeb,
    required bool isDesktopHost,
    required bool supportsUpdates,
  }) =>
      _isSectionVisible(
        candidate,
        isWeb: isWeb,
        isDesktopHost: isDesktopHost,
        supportsUpdates: supportsUpdates,
      )
      ? candidate
      : .interface;

  static bool _isSectionVisible(
    FtermSettingsSection section, {
    required bool isWeb,
    required bool isDesktopHost,
    required bool supportsUpdates,
  }) => switch (section) {
    .shell => !isWeb && isDesktopHost,
    .automation => !isWeb,
    .updates => !isWeb && supportsUpdates,
    _ => true,
  };

  static final String _themePresetKeywords = [
    for (final preset in tui.TerminalColorTheme.presets) preset.id,
  ].join(' ');

  /// Full unmodifiable list of searchable settings items across all sections
  /// and panels.
  static final List<SettingsSearchItem> allSearchItems =
      List<SettingsSearchItem>.unmodifiable(<SettingsSearchItem>[
        // Interface
        const SettingsSearchItem(
          id: 'interface-dock-position',
          section: .interface,
          panelId: 'interface-tab-bar',
          panelTitle: 'Tab Bar',
          title: 'Tab Bar Position',
          keywords: 'dock top left hidden chrome bar tabs layout',
        ),
        const SettingsSearchItem(
          id: 'interface-auto-hide-tab',
          section: .interface,
          panelId: 'interface-tab-bar',
          panelTitle: 'Tab Bar',
          title: 'Auto-hide tab bar on single tab',
          keywords: 'single tab hide compact minimal bar',
        ),
        const SettingsSearchItem(
          id: 'interface-copy-on-select',
          section: .interface,
          panelId: 'interface-clipboard',
          panelTitle: 'Clipboard & Selection',
          title: 'Copy on mouse selection',
          keywords: 'clipboard yank highlight drag mouse select',
        ),
        const SettingsSearchItem(
          id: 'interface-osc52',
          section: .interface,
          panelId: 'interface-clipboard',
          panelTitle: 'Clipboard & Selection',
          title: 'Allow focused remote OSC 52 clipboard writes',
          keywords: 'osc52 osc 52 remote clipboard security paste copy',
        ),

        // Themes
        const SettingsSearchItem(
          id: 'themes-appearance-mode',
          section: .themes,
          panelId: 'themes-appearance',
          panelTitle: 'Theme & Appearance',
          title: 'Appearance Mode',
          keywords: 'system dark light brightness color mode',
        ),
        SettingsSearchItem(
          id: 'themes-preset',
          section: .themes,
          panelId: 'themes-appearance',
          panelTitle: 'Theme & Appearance',
          title: 'Theme Preset',
          keywords: 'color scheme palette theme $_themePresetKeywords',
        ),
        const SettingsSearchItem(
          id: 'themes-font-size',
          section: .themes,
          panelId: 'themes-typography',
          panelTitle: 'Typography',
          title: 'Font Size',
          keywords: 'text zoom pt points scale size typography font',
        ),
        const SettingsSearchItem(
          id: 'themes-bg-opacity',
          section: .themes,
          panelId: 'themes-background',
          panelTitle: 'Background',
          title: 'Background Opacity',
          keywords: 'transparency alpha translucent glass opacity',
        ),
        const SettingsSearchItem(
          id: 'themes-wallpaper',
          section: .themes,
          panelId: 'themes-background',
          panelTitle: 'Background',
          title: 'Wallpaper',
          keywords: 'background image png jpeg webp picture wallpaper',
        ),

        // Shaders
        const SettingsSearchItem(
          id: 'shaders-backend',
          section: .shaders,
          panelId: 'shaders-pipeline',
          panelTitle: 'Pipeline & Actions',
          title: 'Shader Backend',
          keywords: 'gpu impeller webgl auto disabled backend shaders',
        ),
        const SettingsSearchItem(
          id: 'shaders-actions',
          section: .shaders,
          panelId: 'shaders-pipeline',
          panelTitle: 'Pipeline & Actions',
          title: 'Shader Editor, Folder & Web GLSL Upload',
          keywords:
              'new shader tab open folder upload web glsl shadertoy ghostty '
              'reload ctrl shift f5',
        ),
        const SettingsSearchItem(
          id: 'shaders-bg-chain',
          section: .shaders,
          panelId: 'shaders-background',
          panelTitle: 'Background Shaders',
          title: 'Background Shader Chain',
          keywords: 'wallpaper_wave background pass chain glsl order',
        ),
        const SettingsSearchItem(
          id: 'shaders-fg-chain',
          section: .shaders,
          panelId: 'shaders-foreground',
          panelTitle: 'Foreground Shaders',
          title: 'Foreground Shader Chain',
          keywords:
              'crt scanline phosphor glow cursor_glow scanline_overlay '
              'crt_lottes phosphor_glow retro_phosphor postprocess pass chain '
              'glsl',
        ),
        const SettingsSearchItem(
          id: 'shaders-custom-path',
          section: .shaders,
          panelId: 'shaders-custom-params',
          panelTitle: 'Custom Shaders & Parameters',
          title: 'Add Custom .glsl Path',
          keywords: 'custom glsl file path shadertoy ghostty',
          desktopOnly: true,
        ),
        const SettingsSearchItem(
          id: 'shaders-params',
          section: .shaders,
          panelId: 'shaders-custom-params',
          panelTitle: 'Custom Shaders & Parameters',
          title: 'Shader Parameters (uParams0)',
          keywords: 'uparams uniforms sliders intensity x y z',
        ),
        const SettingsSearchItem(
          id: 'shaders-animation-mode',
          section: .shaders,
          panelId: 'shaders-playback',
          panelTitle: 'Playback & Frame Pacing',
          title: 'Shader Animation Mode',
          keywords: 'animation focused always on activity static itime idle',
        ),
        const SettingsSearchItem(
          id: 'shaders-max-fps',
          section: .shaders,
          panelId: 'shaders-playback',
          panelTitle: 'Playback & Frame Pacing',
          title: 'Max Shader FPS',
          keywords: 'fps frame rate cap uncapped 120 60 30 battery integrated',
        ),
        const SettingsSearchItem(
          id: 'shaders-cli-local-policy',
          section: .shaders,
          panelId: 'shaders-cli',
          panelTitle: 'CLI Shaders & Transforms (ESC _ S)',
          title: 'Local Pane Policy',
          keywords:
              'cli esc s shader transform presets prompt custom glsl trust',
        ),
        const SettingsSearchItem(
          id: 'shaders-cli-remote-policy',
          section: .shaders,
          panelId: 'shaders-cli',
          panelTitle: 'CLI Shaders & Transforms (ESC _ S)',
          title: 'Remote Cast Policy',
          keywords: 'cli esc s remote cast relay shader trust policy',
        ),
        const SettingsSearchItem(
          id: 'shaders-cli-stacking',
          section: .shaders,
          panelId: 'shaders-cli',
          panelTitle: 'CLI Shaders & Transforms (ESC _ S)',
          title: 'Full-Pane CLI Shader Stacking',
          keywords: 'cli before user replaces ask conflict stacking full pane',
        ),
        const SettingsSearchItem(
          id: 'shaders-cli-dev-trust',
          section: .shaders,
          panelId: 'shaders-cli',
          panelTitle: 'CLI Shaders & Transforms (ESC _ S)',
          title: 'Dev Auto-Trust Local Custom GLSL',
          keywords: 'dev auto trust custom glsl cli local',
        ),
        const SettingsSearchItem(
          id: 'shaders-cli-trusted-hashes',
          section: .shaders,
          panelId: 'shaders-cli',
          panelTitle: 'CLI Shaders & Transforms (ESC _ S)',
          title: 'Trusted CLI GLSL Hashes',
          keywords: 'sha256 trusted hashes reset clear cli glsl',
        ),

        // Keyboard
        const SettingsSearchItem(
          id: 'keyboard-meta-policy',
          section: .keyboard,
          panelId: 'keyboard-meta',
          panelTitle: 'Meta / Cmd Key Policy',
          title: 'Meta / Cmd Key Policy',
          keywords: 'meta cmd command super auto pass through kitty keyboard',
        ),
        const SettingsSearchItem(
          id: 'keyboard-ignored-chords',
          section: .keyboard,
          panelId: 'keyboard-passthrough',
          panelTitle: 'Ignored Chords (Do Not Intercept)',
          title: 'Ignored Passthrough Key Chords',
          keywords:
              'ignored passthrough shortcuts keybindings chord record preset '
              'alt+f4 ctrl+shift+i',
        ),
        const SettingsSearchItem(
          id: 'keyboard-macos-option',
          section: .keyboard,
          panelId: 'keyboard-host-keys',
          panelTitle: 'Host & Platform Keys',
          title: 'macOS Option key acts as Alt',
          keywords: 'macos option alt meta dead key',
        ),
        const SettingsSearchItem(
          id: 'keyboard-f12-shortcuts',
          section: .keyboard,
          panelId: 'keyboard-host-keys',
          panelTitle: 'Host & Platform Keys',
          title: 'Enable F12 host shortcuts (screenshot/atlas)',
          keywords: 'f12 screenshot atlas reload host shortcut debug',
        ),

        // Shell (desktop)
        const SettingsSearchItem(
          id: 'shell-preset',
          section: .shell,
          panelId: 'shell-default',
          panelTitle: 'Default Shell',
          title: 'Shell Preset',
          keywords:
              'default zsh bash sh pwsh powershell cmd shell override terminal',
          desktopOnly: true,
        ),
        const SettingsSearchItem(
          id: 'shell-executable',
          section: .shell,
          panelId: 'shell-default',
          panelTitle: 'Default Shell',
          title: 'Shell Executable',
          keywords: 'shell path binary executable /bin/zsh powershell pwsh cmd',
          desktopOnly: true,
        ),
        const SettingsSearchItem(
          id: 'shell-arguments',
          section: .shell,
          panelId: 'shell-default',
          panelTitle: 'Default Shell',
          title: 'Shell Arguments',
          keywords: 'shell flags args arguments norc tmux startup',
          desktopOnly: true,
        ),
        const SettingsSearchItem(
          id: 'shell-login',
          section: .shell,
          panelId: 'shell-default',
          panelTitle: 'Default Shell',
          title: 'Run as login shell (-l)',
          keywords: 'login shell -l profile environment',
          desktopOnly: true,
        ),

        // System
        const SettingsSearchItem(
          id: 'system-perf-hud',
          section: .system,
          panelId: 'system-graphics',
          panelTitle: 'Graphics & Performance',
          title: 'Performance HUD (FPS • Ctrl+Shift+F9)',
          keywords: 'perf hud fps vram frame timing overlay diagnostics',
        ),
        const SettingsSearchItem(
          id: 'system-gpu-driver',
          section: .system,
          panelId: 'system-graphics',
          panelTitle: 'Graphics & Performance',
          title: 'Graphics Driver (Desktop GPU Adapter)',
          keywords:
              'gpu graphics adapter discrete integrated high performance '
              'power saving dxgi windows restart',
          desktopOnly: true,
          windowsOnly: true,
        ),
        const SettingsSearchItem(
          id: 'system-audio-mute',
          section: .system,
          panelId: 'system-sound',
          panelTitle: 'Sound',
          title: 'Mute terminal bell & APC audio',
          keywords: 'sound audio bell beep apc mute silence',
        ),
        const SettingsSearchItem(
          id: 'system-audio-volume',
          section: .system,
          panelId: 'system-sound',
          panelTitle: 'Sound',
          title: 'Output Volume',
          keywords: 'sound audio output volume gain loudness slider',
        ),

        // Automation (desktop)
        const SettingsSearchItem(
          id: 'automation-enable',
          section: .automation,
          panelId: 'automation-driver',
          panelTitle: 'HTTP Automation Driver',
          title: 'Enable HTTP Automation Driver',
          keywords: 'automation http server loopback driver enable api',
          desktopOnly: true,
        ),
        const SettingsSearchItem(
          id: 'automation-port',
          section: .automation,
          panelId: 'automation-network',
          panelTitle: 'Network & Authentication',
          title: 'Loopback Port',
          keywords: 'port 127.0.0.1 localhost tcp automation http',
          desktopOnly: true,
        ),
        const SettingsSearchItem(
          id: 'automation-password',
          section: .automation,
          panelId: 'automation-network',
          panelTitle: 'Network & Authentication',
          title: 'Bearer Password',
          keywords: 'bearer token password auth header regenerate copy secret',
          desktopOnly: true,
        ),
        const SettingsSearchItem(
          id: 'automation-pty-scope',
          section: .automation,
          panelId: 'automation-scope',
          panelTitle: 'Terminal Access Scope',
          title: 'Allow PTY input, shell spawning & screen readback',
          keywords: 'pty input spawn readback mouse security automation',
          desktopOnly: true,
        ),

        // Updates (desktop)
        const SettingsSearchItem(
          id: 'updates-check',
          section: .updates,
          panelId: 'updates-application',
          panelTitle: 'Application Updates',
          title: 'Check for Updates',
          keywords: 'update check version release github download upgrade',
          desktopOnly: true,
        ),
        const SettingsSearchItem(
          id: 'updates-daily',
          section: .updates,
          panelId: 'updates-application',
          panelTitle: 'Application Updates',
          title: 'Check daily for updates',
          keywords: 'daily automatic background update check',
          desktopOnly: true,
        ),
        const SettingsSearchItem(
          id: 'updates-prereleases',
          section: .updates,
          panelId: 'updates-application',
          panelTitle: 'Application Updates',
          title: 'Include pre-releases',
          keywords: 'prerelease pre-release beta rc canary update',
          desktopOnly: true,
        ),
      ]);

  static final List<_IndexedSearchItem> _indexedSearchItems =
      List<_IndexedSearchItem>.unmodifiable(<_IndexedSearchItem>[
        for (final item in allSearchItems)
          (
            item: item,
            sectionMeta: metaFor(item.section),
            haystack:
                '${metaFor(item.section).label} ${item.panelTitle} '
                        '${item.title} ${item.keywords}'
                    .toLowerCase(),
          ),
      ]);

  /// Executes a multi-token case-insensitive search across all visible
  /// sections and returns grouped panel matches plus per-section badge counts.
  static SettingsSearchResult search(
    String rawQuery, {
    required bool isWeb,
    required bool isDesktopHost,
    required bool supportsUpdates,
    required bool isWindows,
  }) {
    final tokens = <String>[
      for (final part in rawQuery.trim().toLowerCase().split(_whitespace))
        if (part.isNotEmpty) part,
    ];
    if (tokens.isEmpty) {
      return const SettingsSearchResult(
        sectionMatchCounts: <FtermSettingsSection, int>{},
        panelMatches: <SettingsSearchPanelMatch>[],
        totalMatches: 0,
      );
    }

    final counts = <FtermSettingsSection, int>{};
    final panelItemIds = <String, Set<String>>{};
    final panelOrder = <String>[];
    final panelMeta = <String, (SettingsSectionMeta, String)>{};
    var total = 0;

    for (final entry in _indexedSearchItems) {
      final item = entry.item;
      if (!_itemVisible(
        item,
        isWeb: isWeb,
        isDesktopHost: isDesktopHost,
        supportsUpdates: supportsUpdates,
        isWindows: isWindows,
      )) {
        continue;
      }
      if (!_matchesAllTokens(entry.haystack, tokens)) continue;

      total++;
      counts[item.section] = (counts[item.section] ?? 0) + 1;
      final bucket = panelItemIds[item.panelId];
      if (bucket == null) {
        panelOrder.add(item.panelId);
        panelItemIds[item.panelId] = <String>{item.id};
        panelMeta[item.panelId] = (entry.sectionMeta, item.panelTitle);
      } else {
        bucket.add(item.id);
      }
    }

    final panelMatches = <SettingsSearchPanelMatch>[
      for (final panelId in panelOrder)
        SettingsSearchPanelMatch(
          sectionMeta: panelMeta[panelId]!.$1,
          panelId: panelId,
          panelTitle: panelMeta[panelId]!.$2,
          matchedItemIds: panelItemIds[panelId]!,
        ),
    ];

    return SettingsSearchResult(
      sectionMatchCounts: counts,
      panelMatches: panelMatches,
      totalMatches: total,
    );
  }

  static bool _itemVisible(
    SettingsSearchItem item, {
    required bool isWeb,
    required bool isDesktopHost,
    required bool supportsUpdates,
    required bool isWindows,
  }) {
    if (!_isSectionVisible(
      item.section,
      isWeb: isWeb,
      isDesktopHost: isDesktopHost,
      supportsUpdates: supportsUpdates,
    )) {
      return false;
    }
    if (item.windowsOnly && (isWeb || !isWindows)) return false;
    if (item.desktopOnly && isWeb) return false;
    return true;
  }

  static bool _matchesAllTokens(String haystack, List<String> tokens) {
    for (final token in tokens) {
      if (!haystack.contains(token)) return false;
    }
    return true;
  }
}
