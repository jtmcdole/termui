import '../ui/palette/palette_models.dart';
import '../workspace/fterm_workspace_controller.dart';
import 'fterm_capability_context.dart';
import 'fterm_descriptor_models.dart';

/// Projects declarative [descriptors] into flat single-step Command Palette
/// [PaletteItem] entries for [workspace] under [capabilities].
///
/// Descriptors failing [FtermDescriptor.isVisibleFor] are omitted,
/// [FtermCustomSettingDescriptor] entries are skipped, and individual
/// [FtermEnumOption] entries are filtered through
/// [FtermEnumOption.isVisibleFor] via [FtermEnumDescriptorVisitor] so exact
/// generic type `T` is preserved with full static typing.
List<PaletteItem> projectDescriptorsToPaletteItems(
  List<FtermDescriptor> descriptors,
  FtermWorkspaceController workspace,
  FtermCapabilityContext capabilities,
) {
  final enumVisitor = _PaletteEnumVisitor(
    workspace: workspace,
    capabilities: capabilities,
  );
  return List<PaletteItem>.unmodifiable(<PaletteItem>[
    for (final descriptor in descriptors)
      if (descriptor.isVisibleFor(capabilities))
        ...switch (descriptor) {
          FtermActionDescriptor() => <PaletteItem>[
            _projectAction(descriptor, workspace, capabilities),
          ],
          FtermToggleSettingDescriptor() => <PaletteItem>[
            _projectToggle(descriptor, workspace, capabilities),
          ],
          FtermEnumSettingDescriptor<Object?>() => descriptor.accept(
            enumVisitor,
          ),
          FtermSliderSettingDescriptor() => <PaletteItem>[
            _projectSlider(descriptor, workspace),
          ],
          FtermCustomSettingDescriptor() => const <PaletteItem>[],
        },
  ]);
}

/// Projects setting descriptors in [descriptors] into pure
/// [SettingsSearchEntry] records for `SettingsCatalog`.
///
/// [FtermActionDescriptor] entries are skipped. Each emitted entry resolves
/// `title` from `searchTitle ?? settingsLabel` (or `label` / `title` for slider
/// and custom descriptors), sets `desktopOnly` whenever
/// `descriptor.visibility != .always`, sets `windowsOnly` when
/// `descriptor.visibility == .windowsDesktop`, and propagates `featureFlag` and
/// `isAvailable`.
List<SettingsSearchEntry> projectDescriptorsToSettingsSearchEntries(
  List<FtermDescriptor> descriptors,
) => List<SettingsSearchEntry>.unmodifiable(<SettingsSearchEntry>[
  for (final descriptor in descriptors)
    ?_projectSettingsSearchEntry(descriptor),
]);

PaletteItem _projectAction(
  FtermActionDescriptor descriptor,
  FtermWorkspaceController workspace,
  FtermCapabilityContext capabilities,
) => PaletteItem(
  id: descriptor.id,
  category: descriptor.category,
  title: descriptor.dynamicTitleBuilder?.call(workspace) ?? descriptor.title,
  subtitle: descriptor.subtitleBuilder?.call(workspace),
  shortcutHint: descriptor.shortcut?.formatPaletteHint(capabilities),
  activeBadge: descriptor.activeBadgeBuilder?.call(workspace),
  keywords: descriptor.keywords,
  icon: descriptor.dynamicIconBuilder?.call(workspace) ?? descriptor.icon,
  onExecute: () => descriptor.execute(workspace),
);

PaletteItem _projectToggle(
  FtermToggleSettingDescriptor descriptor,
  FtermWorkspaceController workspace,
  FtermCapabilityContext capabilities,
) {
  final isEnabled = descriptor.read(workspace);
  return PaletteItem(
    id: descriptor.paletteId,
    category: descriptor.paletteCategory,
    title: descriptor.paletteTitle,
    shortcutHint: descriptor.shortcut?.formatPaletteHint(capabilities),
    activeBadge: isEnabled ? 'On' : 'Off',
    keywords: descriptor.keywords,
    icon: isEnabled
        ? (descriptor.activeIcon ?? descriptor.icon)
        : descriptor.icon,
    onExecute: () => descriptor.write(workspace, !descriptor.read(workspace)),
  );
}

PaletteItem _projectSlider(
  FtermSliderSettingDescriptor descriptor,
  FtermWorkspaceController workspace,
) => PaletteItem(
  id: descriptor.paletteId,
  category: descriptor.paletteCategory,
  title: descriptor.label,
  keywords: descriptor.keywords,
  icon: descriptor.icon,
  slider: PaletteSliderSpec(
    value: _clampSliderValue(descriptor.read(workspace), descriptor),
    min: descriptor.min,
    max: descriptor.max,
    step: descriptor.step,
    divisions: descriptor.divisions,
    formatValue: descriptor.formatValue,
    onChanged: (value) =>
        descriptor.write(workspace, _clampSliderValue(value, descriptor)),
  ),
);

double _clampSliderValue(
  double value,
  FtermSliderSettingDescriptor descriptor,
) => value.isNaN ? descriptor.min : value.clamp(descriptor.min, descriptor.max);

final class _PaletteEnumVisitor
    implements FtermEnumDescriptorVisitor<List<PaletteItem>> {
  final FtermWorkspaceController workspace;
  final FtermCapabilityContext capabilities;

  const _PaletteEnumVisitor({
    required this.workspace,
    required this.capabilities,
  });

  @override
  List<PaletteItem> visitEnum<T>(FtermEnumSettingDescriptor<T> descriptor) {
    final visibleOptions = <FtermEnumOption<T>>[
      for (final option in descriptor.optionsBuilder(capabilities))
        if (option.isVisibleFor(capabilities)) option,
    ];
    if (visibleOptions.isEmpty) return const <PaletteItem>[];

    final currentValue = descriptor.read(workspace);
    return <PaletteItem>[
      for (final option in visibleOptions)
        PaletteItem(
          id: '${descriptor.paletteIdPrefix}.${option.idSuffix}',
          category: descriptor.paletteCategory,
          title: '${descriptor.paletteTitlePrefix}: ${option.label}',
          activeBadge: currentValue == option.value ? 'Active' : null,
          keywords: _joinKeywords(descriptor.keywords, option.extraKeywords),
          icon: descriptor.icon,
          onExecute: () => descriptor.write(workspace, option.value),
        ),
    ];
  }
}

String _joinKeywords(String base, String extra) {
  final trimmedBase = base.trim();
  final trimmedExtra = extra.trim();
  if (trimmedBase.isEmpty) return trimmedExtra;
  if (trimmedExtra.isEmpty) return trimmedBase;
  return '$trimmedBase $trimmedExtra';
}

SettingsSearchEntry? _projectSettingsSearchEntry(FtermDescriptor descriptor) =>
    switch (descriptor) {
      FtermActionDescriptor() => null,
      FtermToggleSettingDescriptor() => _buildSettingsSearchEntry(
        descriptor: descriptor,
        section: descriptor.section,
        panelId: descriptor.panelId,
        panelTitle: descriptor.panelTitle,
        title: descriptor.searchTitle ?? descriptor.settingsLabel,
      ),
      FtermEnumSettingDescriptor<Object?>() => _buildSettingsSearchEntry(
        descriptor: descriptor,
        section: descriptor.section,
        panelId: descriptor.panelId,
        panelTitle: descriptor.panelTitle,
        title: descriptor.searchTitle ?? descriptor.settingsLabel,
      ),
      FtermSliderSettingDescriptor() => _buildSettingsSearchEntry(
        descriptor: descriptor,
        section: descriptor.section,
        panelId: descriptor.panelId,
        panelTitle: descriptor.panelTitle,
        title: descriptor.searchTitle ?? descriptor.label,
      ),
      FtermCustomSettingDescriptor() => _buildSettingsSearchEntry(
        descriptor: descriptor,
        section: descriptor.section,
        panelId: descriptor.panelId,
        panelTitle: descriptor.panelTitle,
        title: descriptor.title,
      ),
    };

SettingsSearchEntry _buildSettingsSearchEntry({
  required FtermDescriptor descriptor,
  required FtermSettingsSection section,
  required String panelId,
  required String panelTitle,
  required String title,
}) => (
  id: descriptor.id,
  section: section,
  panelId: panelId,
  panelTitle: panelTitle,
  title: title,
  keywords: descriptor.keywords,
  desktopOnly: descriptor.visibility != .always,
  windowsOnly: descriptor.visibility == .windowsDesktop,
  featureFlag: descriptor.featureFlag,
  isAvailable: descriptor.isAvailable,
);
