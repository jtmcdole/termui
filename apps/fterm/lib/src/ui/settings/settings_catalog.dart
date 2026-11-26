import 'package:material_ui/material_ui.dart';

import '../../commands/descriptor_adapters.dart';
import '../../commands/fterm_capability_context.dart';
import '../../commands/fterm_descriptor_models.dart';
import '../../commands/settings_descriptors.dart';
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

  /// Optional runtime feature flag required to surface this setting.
  final String? featureFlag;

  /// Optional runtime availability predicate evaluated against capabilities.
  final bool Function(FtermCapabilityContext ctx)? isAvailable;

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
    this.featureFlag,
    this.isAvailable,
  });

  /// Maps a pure [SettingsSearchEntry] projected from declarative descriptors
  /// into a [SettingsSearchItem].
  factory SettingsSearchItem.fromEntry(SettingsSearchEntry entry) =>
      SettingsSearchItem(
        id: entry.id,
        section: entry.section,
        panelId: entry.panelId,
        panelTitle: entry.panelTitle,
        title: entry.title,
        keywords: entry.keywords,
        desktopOnly: entry.desktopOnly,
        windowsOnly: entry.windowsOnly,
        featureFlag: entry.featureFlag,
        isAvailable: entry.isAvailable,
      );
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

  /// Full unmodifiable list of searchable settings items across all sections
  /// and panels, projected directly from [allSettingDescriptors].
  static final List<SettingsSearchItem> allSearchItems =
      List<SettingsSearchItem>.unmodifiable(<SettingsSearchItem>[
        for (final entry in projectDescriptorsToSettingsSearchEntries(
          allSettingDescriptors,
        ))
          SettingsSearchItem.fromEntry(entry),
      ]);

  static List<_IndexedSearchItem> _indexItems(List<SettingsSearchItem> items) =>
      List<_IndexedSearchItem>.unmodifiable(<_IndexedSearchItem>[
        for (final item in items)
          (
            item: item,
            sectionMeta: metaFor(item.section),
            haystack:
                '${metaFor(item.section).label} ${item.panelTitle} '
                        '${item.title} ${item.keywords}'
                    .toLowerCase(),
          ),
      ]);

  static final List<_IndexedSearchItem> _indexedSearchItems = _indexItems(
    allSearchItems,
  );

  /// Executes a multi-token case-insensitive search across all visible
  /// sections and returns grouped panel matches plus per-section badge counts.
  static SettingsSearchResult search(
    String rawQuery, {
    required bool isWeb,
    required bool isDesktopHost,
    required bool supportsUpdates,
    required bool isWindows,
    TargetPlatform? platform,
    Set<String> enabledFeatures = const <String>{},
    List<SettingsSearchItem>? items,
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

    final capabilities = FtermCapabilityContext(
      isWeb: isWeb,
      platform: platform ?? (isWindows ? .windows : .linux),
      isDesktopHost: isDesktopHost,
      supportsUpdates: supportsUpdates,
      enabledFeatures: enabledFeatures,
    );
    final indexed = items == null ? _indexedSearchItems : _indexItems(items);

    final counts = <FtermSettingsSection, int>{};
    final panelItemIds = <String, Set<String>>{};
    final panelOrder = <String>[];
    final panelMeta = <String, (SettingsSectionMeta, String)>{};
    var total = 0;

    for (final entry in indexed) {
      final item = entry.item;
      if (!_itemVisible(item, capabilities: capabilities)) continue;
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
    required FtermCapabilityContext capabilities,
  }) {
    if (!_isSectionVisible(
      item.section,
      isWeb: capabilities.isWeb,
      isDesktopHost: capabilities.isDesktopHost,
      supportsUpdates: capabilities.supportsUpdates,
    )) {
      return false;
    }
    if (item.windowsOnly && !capabilities.isWindowsDesktop) return false;
    if (item.desktopOnly && capabilities.isWeb) return false;
    if (item.featureFlag case final flag?
        when !capabilities.isFeatureEnabled(flag)) {
      return false;
    }
    if (item.isAvailable case final predicate? when !predicate(capabilities)) {
      return false;
    }
    return true;
  }

  static bool _matchesAllTokens(String haystack, List<String> tokens) {
    for (final token in tokens) {
      if (!haystack.contains(token)) return false;
    }
    return true;
  }
}
