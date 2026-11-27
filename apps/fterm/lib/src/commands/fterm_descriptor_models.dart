import 'dart:async' show FutureOr;

import 'package:flutter/foundation.dart' show Key;
import 'package:material_ui/material_ui.dart' show IconData;

import '../workspace/fterm_workspace_controller.dart';
import 'fterm_capability_context.dart';
import 'fterm_shortcut_spec.dart';

/// Type-safe generic visitor avoiding contravariant cast errors when projecting
/// or rendering heterogeneous [FtermEnumSettingDescriptor] entries stored inside
/// `List<FtermDescriptor>`.
abstract interface class FtermEnumDescriptorVisitor<R> {
  /// Visits a strongly typed [descriptor] with its concrete value type [T].
  R visitEnum<T>(FtermEnumSettingDescriptor<T> descriptor);
}

/// Pure settings search projection record mapped into `SettingsSearchItem` by
/// `SettingsCatalog` without introducing circular `commands/` <-> `ui/settings/`
/// imports.
typedef SettingsSearchEntry = ({
  String id,
  FtermSettingsSection section,
  String panelId,
  String panelTitle,
  String title,
  String keywords,
  bool desktopOnly,
  bool windowsOnly,
  FtermVisibility visibility,
  String? featureFlag,
  bool Function(FtermCapabilityContext ctx)? isAvailable,
});

/// Sealed declarative descriptor for any `fterm` command or setting.
sealed class FtermDescriptor {
  /// Stable unique identifier for this descriptor.
  final String id;

  /// Platform and capability visibility rule shared across all surfaces.
  final FtermVisibility visibility;

  /// Optional runtime feature flag required to surface this descriptor.
  final String? featureFlag;

  /// Optional runtime availability predicate evaluated against capabilities.
  final bool Function(FtermCapabilityContext ctx)? isAvailable;

  /// Space-separated search synonyms and terms used by Settings and Palette.
  final String keywords;

  /// Creates an immutable [FtermDescriptor].
  const FtermDescriptor({
    required this.id,
    this.visibility = .always,
    this.featureFlag,
    this.isAvailable,
    this.keywords = '',
  }) : assert(id != '', 'Descriptor id must not be empty');

  /// Evaluates whether this descriptor should be exposed under [ctx] across
  /// Settings UI, Settings search, Command Palette, and Shortcut Dispatch.
  bool isVisibleFor(FtermCapabilityContext ctx) {
    if (!visibility.isVisible(ctx)) return false;
    if (featureFlag case final flag? when !ctx.isFeatureEnabled(flag)) {
      return false;
    }
    if (isAvailable case final predicate? when !predicate(ctx)) return false;
    return true;
  }
}

/// Declarative descriptor for an executable workspace, pane, tab, shader,
/// diagnostic, or overlay action.
final class FtermActionDescriptor extends FtermDescriptor {
  /// Command Palette category prefix (for example `Workspace`, `Pane`, `Shader`).
  final String category;

  /// Default display title shown in the Command Palette.
  final String title;

  /// Default Material icon displayed beside the action row.
  final IconData icon;

  /// Optional canonical keyboard shortcut binding for hint rendering and dispatch.
  final FtermShortcutBinding? shortcut;

  /// Optional computed subtitle builder evaluated against the workspace.
  final String? Function(FtermWorkspaceController ws)? subtitleBuilder;

  /// Optional computed active status badge builder (for example `Zoomed`, `Recording`).
  final String? Function(FtermWorkspaceController ws)? activeBadgeBuilder;

  /// Optional computed title override (for example `Resume Shaders` vs
  /// `Emergency Stop Shaders`).
  final String Function(FtermWorkspaceController ws)? dynamicTitleBuilder;

  /// Optional computed icon override evaluated against the workspace.
  final IconData Function(FtermWorkspaceController ws)? dynamicIconBuilder;

  /// Action invoked when the user triggers this command.
  final FutureOr<void> Function(FtermWorkspaceController ws) execute;

  /// Creates an immutable [FtermActionDescriptor].
  const FtermActionDescriptor({
    required super.id,
    required this.category,
    required this.title,
    required this.icon,
    required this.execute,
    super.keywords,
    super.visibility,
    super.featureFlag,
    super.isAvailable,
    this.shortcut,
    this.subtitleBuilder,
    this.activeBadgeBuilder,
    this.dynamicTitleBuilder,
    this.dynamicIconBuilder,
  }) : assert(category != '', 'Action category must not be empty'),
       assert(title != '', 'Action title must not be empty');
}

/// Declarative descriptor for a boolean toggle setting rendered as a Blender
/// checkbox in Settings and a toggle command in the Command Palette.
final class FtermToggleSettingDescriptor extends FtermDescriptor {
  /// Stable Command Palette command identifier (for example `settings.toggle.perf_hud`).
  final String paletteId;

  /// Owning sidebar section inside Settings.
  final FtermSettingsSection section;

  /// Owning collapsible panel identifier inside [section].
  final String panelId;

  /// Display title of the owning collapsible panel.
  final String panelTitle;

  /// Widget key preserved on the rendered Settings checkbox control.
  final Key controlKey;

  /// Primary label rendered inside the Settings panel.
  final String settingsLabel;

  /// Explanatory caption rendered beneath [settingsLabel] in Settings.
  final String settingsCaption;

  /// Optional Settings search title overriding [settingsLabel].
  final String? searchTitle;

  /// Command Palette category label.
  final String paletteCategory;

  /// Command Palette command title.
  final String paletteTitle;

  /// Default icon displayed in the Command Palette.
  final IconData icon;

  /// Optional icon displayed in the Command Palette when the toggle is enabled.
  final IconData? activeIcon;

  /// Optional canonical keyboard shortcut binding.
  final FtermShortcutBinding? shortcut;

  /// Reads the current boolean state from `ws`.
  final bool Function(FtermWorkspaceController ws) read;

  /// Writes a new boolean state to `ws`.
  final FutureOr<void> Function(FtermWorkspaceController ws, bool value) write;

  /// Creates an immutable [FtermToggleSettingDescriptor].
  const FtermToggleSettingDescriptor({
    required super.id,
    required this.paletteId,
    required this.section,
    required this.panelId,
    required this.panelTitle,
    required this.controlKey,
    required this.settingsLabel,
    required this.settingsCaption,
    required this.paletteCategory,
    required this.paletteTitle,
    required this.icon,
    required this.read,
    required this.write,
    this.searchTitle,
    super.keywords,
    this.activeIcon,
    super.visibility,
    super.featureFlag,
    super.isAvailable,
    this.shortcut,
  }) : assert(paletteId != '', 'Toggle paletteId must not be empty'),
       assert(panelId != '', 'Toggle panelId must not be empty'),
       assert(panelTitle != '', 'Toggle panelTitle must not be empty'),
       assert(settingsLabel != '', 'Toggle settingsLabel must not be empty'),
       assert(
         paletteCategory != '',
         'Toggle paletteCategory must not be empty',
       ),
       assert(paletteTitle != '', 'Toggle paletteTitle must not be empty');
}

/// Visual control style used to render an [FtermEnumSettingDescriptor] in
/// Blender-style Settings.
enum FtermEnumRenderStyle {
  /// Compact horizontal segmented pill bar (`BlenderSegmentedControl`).
  segmented,

  /// Dropdown menu control (`BlenderDropdown`).
  dropdown,
}

/// Strongly typed choice entry belonging to an [FtermEnumSettingDescriptor].
final class FtermEnumOption<T> {
  /// Suffix appended to `paletteIdPrefix` to form a stable Command Palette ID.
  final String idSuffix;

  /// Strongly typed option value (may be nullable when `T` is nullable).
  final T value;

  /// Human-readable option label shown in Settings and Command Palette.
  final String label;

  /// Optional widget key preserved on the corresponding segmented option button.
  final Key? settingsKey;

  /// Additional option-specific search keywords appended during projection.
  final String extraKeywords;

  /// Visibility gate controlling whether this individual option is surfaced.
  final FtermVisibility visibility;

  /// Optional runtime feature flag required for this individual option.
  final String? featureFlag;

  /// Optional runtime availability predicate for this individual option.
  final bool Function(FtermCapabilityContext ctx)? isAvailable;

  /// Creates an immutable [FtermEnumOption].
  const FtermEnumOption({
    required this.idSuffix,
    required this.value,
    required this.label,
    this.settingsKey,
    this.extraKeywords = '',
    this.visibility = .always,
    this.featureFlag,
    this.isAvailable,
  }) : assert(idSuffix != '', 'Enum option idSuffix must not be empty'),
       assert(label != '', 'Enum option label must not be empty');

  /// Evaluates whether this individual option should be surfaced under [ctx].
  bool isVisibleFor(FtermCapabilityContext ctx) {
    if (!visibility.isVisible(ctx)) return false;
    if (featureFlag case final flag? when !ctx.isFeatureEnabled(flag)) {
      return false;
    }
    if (isAvailable case final predicate? when !predicate(ctx)) return false;
    return true;
  }
}

/// Declarative descriptor for an enumerated or discrete-choice setting of type
/// [T] (supporting both nullable and non-nullable value types).
final class FtermEnumSettingDescriptor<T> extends FtermDescriptor {
  /// Prefix combined with each option's `idSuffix` for Command Palette IDs.
  final String paletteIdPrefix;

  /// Owning sidebar section inside Settings.
  final FtermSettingsSection section;

  /// Owning collapsible panel identifier inside [section].
  final String panelId;

  /// Display title of the owning collapsible panel.
  final String panelTitle;

  /// Primary label rendered inside the Settings panel.
  final String settingsLabel;

  /// Optional Settings search title overriding [settingsLabel].
  final String? searchTitle;

  /// Optional computed caption/hint builder rendered beneath the control in
  /// Settings (for example the active Meta key behavior summary).
  final String? Function(
    FtermWorkspaceController ws,
    FtermCapabilityContext ctx,
  )?
  settingsHintBuilder;

  /// Optional widget key attached to the rendered [settingsHintBuilder] text.
  final Key? settingsHintKey;

  /// Optional widget key attached to a [FtermEnumRenderStyle.dropdown] control.
  final Key? dropdownKey;

  /// Settings UI control style (`segmented` or `dropdown`).
  final FtermEnumRenderStyle renderStyle;

  /// Command Palette category label.
  final String paletteCategory;

  /// Prefix prepended to each option's `label` in the Command Palette (for
  /// example `'Dock Position'` -> `'Dock Position: Top'`).
  final String paletteTitlePrefix;

  /// Material icon displayed beside projected Command Palette items.
  final IconData icon;

  /// Produces the ordered list of candidate options for `ctx`.
  final List<FtermEnumOption<T>> Function(FtermCapabilityContext ctx)
  optionsBuilder;

  /// Reads the current value of type [T] from `ws`.
  final T Function(FtermWorkspaceController ws) read;

  /// Writes a newly selected value of type [T] to `ws`.
  final FutureOr<void> Function(FtermWorkspaceController ws, T value) write;

  /// Creates an immutable [FtermEnumSettingDescriptor].
  const FtermEnumSettingDescriptor({
    required super.id,
    required this.paletteIdPrefix,
    required this.section,
    required this.panelId,
    required this.panelTitle,
    required this.settingsLabel,
    required this.renderStyle,
    required this.paletteCategory,
    required this.paletteTitlePrefix,
    required this.icon,
    required this.optionsBuilder,
    required this.read,
    required this.write,
    this.searchTitle,
    this.settingsHintBuilder,
    this.settingsHintKey,
    this.dropdownKey,
    super.keywords,
    super.visibility,
    super.featureFlag,
    super.isAvailable,
  }) : assert(paletteIdPrefix != '', 'Enum paletteIdPrefix must not be empty'),
       assert(panelId != '', 'Enum panelId must not be empty'),
       assert(panelTitle != '', 'Enum panelTitle must not be empty'),
       assert(settingsLabel != '', 'Enum settingsLabel must not be empty'),
       assert(paletteCategory != '', 'Enum paletteCategory must not be empty'),
       assert(
         paletteTitlePrefix != '',
         'Enum paletteTitlePrefix must not be empty',
       );

  /// Dispatches to [visitor] while preserving concrete static type [T].
  R accept<R>(FtermEnumDescriptorVisitor<R> visitor) =>
      visitor.visitEnum<T>(this);
}

/// Declarative descriptor for a continuous or stepped numeric slider setting.
final class FtermSliderSettingDescriptor extends FtermDescriptor {
  /// Stable Command Palette command identifier (for example `appearance.background_opacity`).
  final String paletteId;

  /// Owning sidebar section inside Settings.
  final FtermSettingsSection section;

  /// Owning collapsible panel identifier inside [section].
  final String panelId;

  /// Display title of the owning collapsible panel.
  final String panelTitle;

  /// Primary label rendered in Settings and the Command Palette.
  final String label;

  /// Optional Settings search title overriding [label].
  final String? searchTitle;

  /// Command Palette category label.
  final String paletteCategory;

  /// Material icon displayed beside the Command Palette slider row.
  final IconData icon;

  /// Inclusive minimum slider bound.
  final double min;

  /// Inclusive maximum slider bound.
  final double max;

  /// Keyboard / stepper increment applied in the Command Palette.
  final double step;

  /// Optional discrete division count passed to Flutter's `Slider`.
  final int? divisions;

  /// Optional widget key attached to the Settings `Slider` widget (`null` when
  /// [usesCustomSettingsWidget] is `true`).
  final Key? sliderKey;

  /// Optional widget key attached to the Settings readout label (`null` when
  /// [usesCustomSettingsWidget] is `true`).
  final Key? valueKey;

  /// Whether Settings renders a bespoke widget (such as the Font Size stepper)
  /// instead of a standard `BlenderSliderRow`, while still projecting an inline
  /// slider to the Command Palette and search metadata to `SettingsCatalog`.
  final bool usesCustomSettingsWidget;

  /// Formats the current numeric value for Settings and Palette readouts.
  final String Function(double value) formatValue;

  /// Reads the current numeric value from `ws`.
  final double Function(FtermWorkspaceController ws) read;

  /// Writes an updated numeric value to `ws`.
  final void Function(FtermWorkspaceController ws, double value) write;

  /// Creates an immutable [FtermSliderSettingDescriptor].
  const FtermSliderSettingDescriptor({
    required super.id,
    required this.paletteId,
    required this.section,
    required this.panelId,
    required this.panelTitle,
    required this.label,
    required this.paletteCategory,
    required this.icon,
    required this.min,
    required this.max,
    required this.step,
    required this.formatValue,
    required this.read,
    required this.write,
    this.searchTitle,
    super.keywords,
    super.visibility,
    super.featureFlag,
    super.isAvailable,
    this.divisions,
    this.sliderKey,
    this.valueKey,
    this.usesCustomSettingsWidget = false,
  }) : assert(paletteId != '', 'Slider paletteId must not be empty'),
       assert(panelId != '', 'Slider panelId must not be empty'),
       assert(panelTitle != '', 'Slider panelTitle must not be empty'),
       assert(label != '', 'Slider label must not be empty'),
       assert(
         paletteCategory != '',
         'Slider paletteCategory must not be empty',
       ),
       assert(max > min, 'Slider max must be greater than min'),
       assert(step > 0, 'Slider step must be positive'),
       assert(
         divisions == null || divisions > 0,
         'Slider divisions must be positive when provided',
       );
}

/// Declarative search-and-parity descriptor for bespoke multi-widget Settings
/// editors (such as Theme Preset swatches, Wallpaper picker, Ignored Chords
/// recorder, or Automation port/password inputs).
final class FtermCustomSettingDescriptor extends FtermDescriptor {
  /// Owning sidebar section inside Settings.
  final FtermSettingsSection section;

  /// Owning collapsible panel identifier inside [section].
  final String panelId;

  /// Display title of the owning collapsible panel.
  final String panelTitle;

  /// Searchable setting title displayed in Settings.
  final String title;

  /// Documented rationale when this setting intentionally has no Command
  /// Palette projection (for example free-form text/password inputs); `null`
  /// when runtime Command Palette builders supply matching items.
  final String? paletteExcludedReason;

  /// Creates an immutable [FtermCustomSettingDescriptor].
  const FtermCustomSettingDescriptor({
    required super.id,
    required this.section,
    required this.panelId,
    required this.panelTitle,
    required this.title,
    super.keywords,
    super.visibility,
    super.featureFlag,
    super.isAvailable,
    this.paletteExcludedReason,
  }) : assert(panelId != '', 'Custom setting panelId must not be empty'),
       assert(panelTitle != '', 'Custom setting panelTitle must not be empty'),
       assert(title != '', 'Custom setting title must not be empty');
}
