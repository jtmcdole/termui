import 'package:material_ui/material_ui.dart';

import '../../workspace/fterm_workspace_controller.dart';
import '../fterm_overlays.dart';
import 'settings_catalog.dart';

/// Returns a crisp foreground text/icon color that contrasts cleanly against
/// [background] (used for accent-filled Blender controls).
Color settingsContrastingOnColor(Color background) =>
    ThemeData.estimateBrightnessForColor(background) == .dark
    ? const Color(0xFFFFFFFF)
    : const Color(0xFF111111);

/// Immutable visibility, expansion, and search-filtering configuration passed
/// into Settings section widgets.
final class SettingsPanelFilter {
  /// Returns whether a given collapsible panel identifier is expanded.
  final bool Function(String panelId) isPanelExpanded;

  /// Callback invoked when a collapsible panel header is tapped (`null` locks
  /// panels open, such as during unified search).
  final void Function(String panelId)? onTogglePanel;

  /// Optional single panel identifier to render when displaying search results.
  final String? onlyPanelId;

  /// Optional subset of item identifiers to render inside [onlyPanelId].
  final Set<String>? visibleItemIds;

  /// Optional category breadcrumb prefixed to panel headers during search.
  final String? categoryBreadcrumb;

  /// Creates a panel filter configuration.
  const SettingsPanelFilter({
    this.isPanelExpanded = _alwaysExpanded,
    this.onTogglePanel,
    this.onlyPanelId,
    this.visibleItemIds,
    this.categoryBreadcrumb,
  });

  /// Default filter showing all panels and items expanded with no collapsing.
  const SettingsPanelFilter.showAll()
    : isPanelExpanded = _alwaysExpanded,
      onTogglePanel = null,
      onlyPanelId = null,
      visibleItemIds = null,
      categoryBreadcrumb = null;

  static bool _alwaysExpanded(String _) => true;

  /// Whether the panel with identifier [id] should be rendered.
  bool showPanel(String id) => onlyPanelId == null || onlyPanelId == id;

  /// Whether the item with identifier [id] should be rendered.
  bool showItem(String id) =>
      visibleItemIds == null || visibleItemIds!.contains(id);

  /// Whether the panel with identifier [id] is currently expanded.
  bool panelExpanded(String id) => isPanelExpanded(id);

  /// Returns the toggle callback for panel [id], or `null` when non-collapsible.
  VoidCallback? toggleFor(String id) {
    final handler = onTogglePanel;
    return handler == null ? null : () => handler(id);
  }
}

/// Vertical column that inserts uniform vertical [spacing] only between
/// actually-present [children], preventing orphaned spacers during filtering.
final class SettingsSpacedColumn extends StatelessWidget {
  /// Vertical gap inserted between adjacent [children].
  final double spacing;

  /// Ordered child widgets to stack vertically.
  final List<Widget> children;

  /// Creates a spaced vertical settings column.
  const SettingsSpacedColumn({
    super.key,
    this.spacing = 10,
    required this.children,
  });

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: .min,
    crossAxisAlignment: .stretch,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) SizedBox(height: spacing),
        children[i],
      ],
    ],
  );
}

/// Blender-inspired collapsible panel hosting a logical group of settings.
final class BlenderSettingsPanel extends StatelessWidget {
  /// Stable panel identifier used for test keys (`settings-panel-$id`).
  final String id;

  /// Panel header title.
  final String title;

  /// Optional category breadcrumb shown before [title] in unified search views.
  final String? categoryBreadcrumb;

  /// Whether the panel body is currently expanded.
  final bool expanded;

  /// Callback invoked when the header is clicked; when `null`, the panel stays
  /// expanded and does not toggle.
  final VoidCallback? onToggleExpanded;

  /// Optional trailing widget rendered on the right side of the header bar.
  final Widget? trailing;

  /// Active overlay palette derived from the terminal theme.
  final FtermOverlayPalette palette;

  /// Panel body rendered when [expanded] is `true`.
  final Widget child;

  /// Creates a Blender-inspired collapsible settings panel.
  const BlenderSettingsPanel({
    super.key,
    required this.id,
    required this.title,
    required this.expanded,
    required this.palette,
    required this.child,
    this.categoryBreadcrumb,
    this.onToggleExpanded,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final headerBg = Color.lerp(palette.surfaceAlt, palette.foreground, 0.04)!;
    final bodyBg = Color.lerp(palette.surface, palette.surfaceAlt, 0.55)!;
    return Container(
      key: ValueKey('settings-panel-$id'),
      decoration: BoxDecoration(
        color: bodyBg,
        borderRadius: .circular(6),
        border: .all(color: palette.border),
      ),
      clipBehavior: .antiAlias,
      child: Column(
        mainAxisSize: .min,
        crossAxisAlignment: .stretch,
        children: [
          Material(
            color: headerBg,
            child: InkWell(
              key: ValueKey('settings-panel-header-$id'),
              onTap: onToggleExpanded,
              child: Padding(
                padding: const .symmetric(horizontal: 10, vertical: 7),
                child: Row(
                  children: [
                    Icon(
                      expanded ? Icons.arrow_drop_down : Icons.arrow_right,
                      size: 16,
                      color: palette.muted,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Row(
                        children: [
                          if (categoryBreadcrumb case final crumb?) ...[
                            Text(
                              '$crumb  ›  ',
                              style: TextStyle(
                                color: palette.accent,
                                fontSize: 11,
                                fontWeight: .w600,
                              ),
                            ),
                          ],
                          Flexible(
                            child: Text(
                              title,
                              overflow: .ellipsis,
                              style: TextStyle(
                                color: palette.foreground,
                                fontSize: 11.5,
                                fontWeight: .w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (trailing case final trailingWidget?) ...[
                      const SizedBox(width: 8),
                      trailingWidget,
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (expanded) ...[
            Divider(height: 1, thickness: 1, color: palette.border),
            Padding(padding: const .fromLTRB(12, 10, 12, 12), child: child),
          ],
        ],
      ),
    );
  }
}

/// Blender-inspired two-column property row: right-aligned label on the left,
/// left-aligned compact control on the right.
///
/// Stacks vertically automatically when constrained below 340 logical pixels.
final class BlenderPropertyRow extends StatelessWidget {
  /// Property label displayed in the left column.
  final String label;

  /// Interactive control displayed in the right column.
  final Widget control;

  /// Optional muted helper or status text shown directly below [control].
  final Widget? hint;

  /// Active overlay color palette.
  final FtermOverlayPalette palette;

  /// Vertical alignment of label vs. control row.
  final CrossAxisAlignment crossAxisAlignment;

  /// Creates a two-column Blender property row.
  const BlenderPropertyRow({
    super.key,
    required this.label,
    required this.control,
    required this.palette,
    this.hint,
    this.crossAxisAlignment = .center,
  });

  @override
  Widget build(BuildContext context) {
    final labelStyle = TextStyle(
      color: palette.foreground.withValues(alpha: 0.86),
      fontSize: 11.5,
    );
    final controlColumn = Column(
      mainAxisSize: .min,
      crossAxisAlignment: .stretch,
      children: [
        control,
        if (hint case final hintWidget?) ...[
          const SizedBox(height: 4),
          hintWidget,
        ],
      ],
    );

    return LayoutBuilder(
      builder: (_, constraints) {
        if (constraints.maxWidth < 340) {
          return Column(
            mainAxisSize: .min,
            crossAxisAlignment: .stretch,
            children: [
              Text(label, style: labelStyle),
              const SizedBox(height: 4),
              controlColumn,
            ],
          );
        }
        return Row(
          crossAxisAlignment: crossAxisAlignment,
          children: [
            Expanded(
              flex: 38,
              child: Align(
                alignment: .centerRight,
                child: Padding(
                  padding: crossAxisAlignment == .start
                      ? const .only(top: 6)
                      : .zero,
                  child: Text(label, textAlign: .right, style: labelStyle),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(flex: 62, child: controlColumn),
          ],
        );
      },
    );
  }
}

/// Option descriptor for [BlenderSegmentedControl].
final class BlenderSegmentedOption<T> {
  /// Value represented by this segment.
  final T value;

  /// Display label rendered inside the segment.
  final String label;

  /// Optional key attached to this segment's interactive widget.
  final Key? key;

  /// Creates a segment option.
  const BlenderSegmentedOption({
    required this.value,
    required this.label,
    this.key,
  });
}

/// Compact contiguous Blender-style segmented toggle for 2–4 mutually
/// exclusive choices.
final class BlenderSegmentedControl<T> extends StatelessWidget {
  /// Ordered segment definitions.
  final List<BlenderSegmentedOption<T>> options;

  /// Currently selected value.
  final T value;

  /// Callback invoked when a segment is clicked.
  final ValueChanged<T>? onChanged;

  /// Active overlay palette.
  final FtermOverlayPalette palette;

  /// Whether segments expand equally to fill available width.
  final bool expand;

  /// Creates a Blender-style segmented control.
  const BlenderSegmentedControl({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    required this.palette,
    this.expand = true,
  });

  @override
  Widget build(BuildContext context) {
    final selectedFg = settingsContrastingOnColor(palette.accent);
    final segments = <Widget>[
      for (var i = 0; i < options.length; i++) ...[
        if (i > 0) Container(width: 1, height: 26, color: palette.border),
        _SegmentedOptionTile<T>(
          option: options[i],
          isSelected: options[i].value == value,
          selectedFg: selectedFg,
          palette: palette,
          expand: expand,
          onTap: onChanged == null ? null : () => onChanged!(options[i].value),
        ),
      ],
    ];

    return Container(
      decoration: BoxDecoration(
        borderRadius: .circular(5),
        border: .all(color: palette.border),
      ),
      clipBehavior: .antiAlias,
      child: Row(mainAxisSize: expand ? .max : .min, children: segments),
    );
  }
}

final class _SegmentedOptionTile<T> extends StatelessWidget {
  final BlenderSegmentedOption<T> option;
  final bool isSelected;
  final Color selectedFg;
  final FtermOverlayPalette palette;
  final bool expand;
  final VoidCallback? onTap;

  const _SegmentedOptionTile({
    required this.option,
    required this.isSelected,
    required this.selectedFg,
    required this.palette,
    required this.expand,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tile = Semantics(
      button: true,
      selected: isSelected,
      child: Material(
        color: isSelected ? palette.accent : palette.surface,
        child: InkWell(
          key: option.key,
          onTap: onTap,
          child: Container(
            height: 26,
            padding: const .symmetric(horizontal: 10),
            alignment: .center,
            child: Text(
              option.label,
              maxLines: 1,
              overflow: .ellipsis,
              style: TextStyle(
                color: isSelected
                    ? selectedFg
                    : palette.foreground.withValues(alpha: 0.85),
                fontSize: 11,
                fontWeight: isSelected ? .w600 : .w400,
              ),
            ),
          ),
        ),
      ),
    );
    return expand ? Expanded(child: tile) : tile;
  }
}

/// Compact Blender-styled dropdown container wrapping [DropdownButton].
final class BlenderDropdown<T> extends StatelessWidget {
  /// Key applied to the inner [DropdownButton].
  final Key? dropdownKey;

  /// Currently selected value (nullable when active value is not in [items]).
  final T? value;

  /// Selectable dropdown menu items.
  final List<DropdownMenuItem<T>> items;

  /// Callback invoked when the user chooses a value.
  final ValueChanged<T?>? onChanged;

  /// Active overlay palette.
  final FtermOverlayPalette palette;

  /// Creates a compact Blender-styled dropdown.
  const BlenderDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    required this.palette,
    this.dropdownKey,
  });

  @override
  Widget build(BuildContext context) => Container(
    height: 28,
    padding: const .symmetric(horizontal: 9),
    decoration: BoxDecoration(
      color: palette.surface,
      borderRadius: .circular(5),
      border: .all(color: palette.border),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        key: dropdownKey,
        value: value,
        isDense: true,
        isExpanded: true,
        dropdownColor: palette.surfaceAlt,
        iconEnabledColor: palette.muted,
        iconSize: 16,
        style: TextStyle(color: palette.foreground, fontSize: 11.5),
        items: items,
        onChanged: onChanged,
      ),
    ),
  );
}

/// Two-column property row displaying a compact checkbox with an optional
/// inline caption or status label.
final class BlenderCheckboxRow extends StatelessWidget {
  /// Property label in the left column.
  final String label;

  /// Current boolean value.
  final bool value;

  /// Callback invoked when toggled (`null` disables the control).
  final ValueChanged<bool>? onChanged;

  /// Key applied directly to the interactive [Checkbox].
  final Key? controlKey;

  /// Optional inline caption rendered to the right of the checkbox.
  final String? caption;

  /// Optional color override for [caption].
  final Color? captionColor;

  /// Optional key attached to the inline caption [Text].
  final Key? captionKey;

  /// Active overlay palette.
  final FtermOverlayPalette palette;

  /// Creates a Blender-style checkbox property row.
  const BlenderCheckboxRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.palette,
    this.controlKey,
    this.caption,
    this.captionColor,
    this.captionKey,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return BlenderPropertyRow(
      label: label,
      palette: palette,
      control: InkWell(
        borderRadius: .circular(4),
        onTap: enabled ? () => onChanged!(!value) : null,
        child: Padding(
          padding: const .symmetric(vertical: 2),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: Checkbox(
                  key: controlKey,
                  value: value,
                  activeColor: palette.accent,
                  checkColor: settingsContrastingOnColor(palette.accent),
                  side: BorderSide(color: palette.border, width: 1.4),
                  visualDensity: .compact,
                  materialTapTargetSize: .shrinkWrap,
                  onChanged: enabled ? (v) => onChanged!(v ?? false) : null,
                ),
              ),
              if (caption case final text?) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    key: captionKey,
                    style: TextStyle(
                      color: captionColor ?? palette.muted,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Two-column property row displaying a compact slider with a numeric readout.
final class BlenderSliderRow extends StatelessWidget {
  /// Property label in the left column.
  final String label;

  /// Current slider value.
  final double value;

  /// Minimum slider bound.
  final double min;

  /// Maximum slider bound.
  final double max;

  /// Formatted readout displayed to the right of the slider (e.g. `70%`).
  final String valueLabel;

  /// Optional key for the [Slider].
  final Key? sliderKey;

  /// Optional key for the readout [Text].
  final Key? valueKey;

  /// Callback invoked as the slider moves.
  final ValueChanged<double>? onChanged;

  /// Active overlay palette.
  final FtermOverlayPalette palette;

  /// Creates a Blender-style slider property row.
  const BlenderSliderRow({
    super.key,
    required this.label,
    required this.value,
    required this.valueLabel,
    required this.onChanged,
    required this.palette,
    this.min = 0.0,
    this.max = 1.0,
    this.sliderKey,
    this.valueKey,
  });

  @override
  Widget build(BuildContext context) => BlenderPropertyRow(
    label: label,
    palette: palette,
    control: Row(
      children: [
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: palette.accent,
              inactiveTrackColor: palette.surface,
              thumbColor: palette.foreground,
            ),
            child: Slider(
              key: sliderKey,
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 42,
          child: Text(
            valueLabel,
            key: valueKey,
            textAlign: .right,
            style: TextStyle(
              color: palette.foreground,
              fontSize: 11,
              fontWeight: .w500,
            ),
          ),
        ),
      ],
    ),
  );
}

/// Compact Blender-styled single-line text input decoration.
InputDecoration blenderInputDecoration({
  required FtermOverlayPalette palette,
  String? hintText,
  String? labelText,
}) => InputDecoration(
  isDense: true,
  filled: true,
  fillColor: palette.surface,
  hintText: hintText,
  labelText: labelText,
  contentPadding: const .symmetric(horizontal: 9, vertical: 7),
  labelStyle: TextStyle(color: palette.muted, fontSize: 11),
  hintStyle: TextStyle(
    color: palette.muted.withValues(alpha: 0.7),
    fontSize: 11,
  ),
  border: OutlineInputBorder(
    borderRadius: .circular(5),
    borderSide: BorderSide(color: palette.border),
  ),
  enabledBorder: OutlineInputBorder(
    borderRadius: .circular(5),
    borderSide: BorderSide(color: palette.border),
  ),
  focusedBorder: OutlineInputBorder(
    borderRadius: .circular(5),
    borderSide: BorderSide(color: palette.accent, width: 1.2),
  ),
);

/// Action chosen from the Blender-style bottom-left `☰` settings menu.
enum SettingsPrefsMenuAction {
  /// Re-read settings from persistent storage.
  reloadFromStorage,

  /// Prompt to reset all preferences and workspace settings to factory defaults.
  resetAllToDefaults,
}

/// Left vertical navigation rail styled after Blender Preferences: grouped
/// contiguous rounded stacks with gaps between clusters and a pinned bottom-left
/// `☰` settings action menu.
final class BlenderSidebarRail extends StatelessWidget {
  /// Visible sidebar sections in display order.
  final List<SettingsSectionMeta> sections;

  /// Currently selected section (highlighted when not searching).
  final FtermSettingsSection activeSection;

  /// Whether a search query is currently active.
  final bool isSearching;

  /// Optional per-section search match counts when [isSearching] is `true`.
  final Map<FtermSettingsSection, int> searchMatchCounts;

  /// Whether an actionable desktop update is available (shows dot on Updates).
  final bool showUpdateDot;

  /// Active overlay color palette.
  final FtermOverlayPalette palette;

  /// Invoked when the user clicks a sidebar tab.
  final ValueChanged<FtermSettingsSection> onSelectSection;

  /// Invoked when the user picks an item from the bottom-left `☰` menu.
  final ValueChanged<SettingsPrefsMenuAction> onMenuAction;

  /// Optional callback invoked when the `☰` menu is dismissed without a choice.
  final VoidCallback? onMenuCanceled;

  /// Creates the Blender-style left sidebar rail.
  const BlenderSidebarRail({
    super.key,
    required this.sections,
    required this.activeSection,
    required this.isSearching,
    required this.searchMatchCounts,
    required this.showUpdateDot,
    required this.palette,
    required this.onSelectSection,
    required this.onMenuAction,
    this.onMenuCanceled,
  });

  List<List<SettingsSectionMeta>> _groupByCluster() {
    final grouped = <int, List<SettingsSectionMeta>>{};
    for (final meta in sections) {
      (grouped[meta.cluster] ??= <SettingsSectionMeta>[]).add(meta);
    }
    final keys = [...grouped.keys]..sort();
    return [for (final k in keys) grouped[k]!];
  }

  @override
  Widget build(BuildContext context) {
    final clusters = _groupByCluster();
    return Container(
      width: 172,
      color: Color.lerp(palette.surface, palette.surfaceAlt, 0.35),
      child: Column(
        crossAxisAlignment: .stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const .fromLTRB(10, 10, 10, 8),
              child: SettingsSpacedColumn(
                spacing: 10,
                children: [
                  for (final cluster in clusters)
                    _SidebarClusterCard(
                      items: cluster,
                      activeSection: activeSection,
                      isSearching: isSearching,
                      searchMatchCounts: searchMatchCounts,
                      showUpdateDot: showUpdateDot,
                      palette: palette,
                      onSelectSection: onSelectSection,
                    ),
                ],
              ),
            ),
          ),
          Divider(height: 1, thickness: 1, color: palette.border),
          Padding(
            padding: const .symmetric(horizontal: 8, vertical: 6),
            child: Align(
              alignment: .centerLeft,
              child: PopupMenuButton<SettingsPrefsMenuAction>(
                key: const ValueKey('settings-prefs-menu'),
                tooltip: 'Settings Actions',
                color: palette.surfaceAlt,
                constraints: const BoxConstraints(minWidth: 210),
                onSelected: onMenuAction,
                onCanceled: onMenuCanceled,
                itemBuilder: (_) => [
                  PopupMenuItem<SettingsPrefsMenuAction>(
                    key: const ValueKey('settings-reload-storage'),
                    value: .reloadFromStorage,
                    height: 34,
                    child: Row(
                      children: [
                        Icon(
                          Icons.refresh,
                          size: 15,
                          color: palette.foreground,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Reload from Storage',
                            overflow: .ellipsis,
                            style: TextStyle(
                              color: palette.foreground,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuItem<SettingsPrefsMenuAction>(
                    key: const ValueKey('settings-reset-defaults-menu-item'),
                    value: .resetAllToDefaults,
                    height: 34,
                    child: Row(
                      children: [
                        Icon(Icons.restore, size: 15, color: palette.danger),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Reset All to Defaults…',
                            overflow: .ellipsis,
                            style: TextStyle(
                              color: palette.danger,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                child: Container(
                  width: 30,
                  height: 26,
                  decoration: BoxDecoration(
                    color: palette.surface,
                    borderRadius: .circular(5),
                    border: .all(color: palette.border),
                  ),
                  alignment: .center,
                  child: Icon(Icons.menu, size: 16, color: palette.foreground),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _SidebarClusterCard extends StatelessWidget {
  final List<SettingsSectionMeta> items;
  final FtermSettingsSection activeSection;
  final bool isSearching;
  final Map<FtermSettingsSection, int> searchMatchCounts;
  final bool showUpdateDot;
  final FtermOverlayPalette palette;
  final ValueChanged<FtermSettingsSection> onSelectSection;

  const _SidebarClusterCard({
    required this.items,
    required this.activeSection,
    required this.isSearching,
    required this.searchMatchCounts,
    required this.showUpdateDot,
    required this.palette,
    required this.onSelectSection,
  });

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      borderRadius: .circular(6),
      border: .all(color: palette.border),
    ),
    clipBehavior: .antiAlias,
    child: Column(
      mainAxisSize: .min,
      crossAxisAlignment: .stretch,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) Divider(height: 1, thickness: 1, color: palette.border),
          _SidebarNavTile(
            meta: items[i],
            selected: !isSearching && items[i].section == activeSection,
            isSearching: isSearching,
            matchCount: searchMatchCounts[items[i].section] ?? 0,
            showUpdateDot: showUpdateDot && items[i].section == .updates,
            palette: palette,
            onTap: () => onSelectSection(items[i].section),
          ),
        ],
      ],
    ),
  );
}

final class _SidebarNavTile extends StatelessWidget {
  final SettingsSectionMeta meta;
  final bool selected;
  final bool isSearching;
  final int matchCount;
  final bool showUpdateDot;
  final FtermOverlayPalette palette;
  final VoidCallback onTap;

  const _SidebarNavTile({
    required this.meta,
    required this.selected,
    required this.isSearching,
    required this.matchCount,
    required this.showUpdateDot,
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final dimmed = isSearching && matchCount == 0;
    final selectedFg = settingsContrastingOnColor(palette.accent);
    final fgColor = switch ((selected, dimmed)) {
      (true, _) => selectedFg,
      (false, true) => palette.muted.withValues(alpha: 0.45),
      (false, false) => palette.foreground.withValues(alpha: 0.9),
    };
    final iconColor = switch ((selected, dimmed)) {
      (true, _) => selectedFg,
      (false, true) => palette.muted.withValues(alpha: 0.4),
      (false, false) => palette.muted,
    };

    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? palette.accent : palette.surfaceAlt,
        child: InkWell(
          key: ValueKey('settings-tab-${meta.section.name}'),
          onTap: onTap,
          child: Padding(
            padding: const .symmetric(horizontal: 10, vertical: 7),
            child: Row(
              children: [
                Icon(meta.icon, size: 14, color: iconColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    meta.label,
                    maxLines: 1,
                    overflow: .ellipsis,
                    style: TextStyle(
                      color: fgColor,
                      fontSize: 11.5,
                      fontWeight: selected ? .w600 : .w400,
                    ),
                  ),
                ),
                if (showUpdateDot) ...[
                  const SizedBox(width: 6),
                  Container(
                    key: const ValueKey('settings-tab-updates-dot'),
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: selected ? selectedFg : palette.accent,
                      shape: .circle,
                    ),
                  ),
                ],
                if (isSearching && matchCount > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    key: ValueKey('settings-tab-count-${meta.section.name}'),
                    padding: const .symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: palette.accent.withValues(alpha: 0.2),
                      borderRadius: .circular(8),
                    ),
                    child: Text(
                      '$matchCount',
                      style: TextStyle(
                        color: palette.accent,
                        fontSize: 10,
                        fontWeight: .w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
