import 'dart:async' show FutureOr, unawaited;

import 'package:material_ui/material_ui.dart';

import '../../commands/fterm_capability_context.dart';
import '../../commands/fterm_descriptor_models.dart';
import '../../workspace/fterm_workspace_controller.dart';
import '../fterm_overlays.dart';
import 'settings_primitives.dart';

/// Builds the Blender-style Settings widget for [descriptor] under
/// [capabilities].
///
/// Returns `SizedBox.shrink()` when [descriptor] is hidden for [capabilities],
/// is an [FtermActionDescriptor] or [FtermCustomSettingDescriptor], is an
/// [FtermSliderSettingDescriptor] with `usesCustomSettingsWidget == true`, or
/// is an [FtermEnumSettingDescriptor] with zero visible options.
///
/// Any [Future] returned by a descriptor's `write` callback is wrapped in
/// [unawaited] so UI handlers remain fire-and-forget safe. When provided,
/// [onBeforeWrite] runs immediately before invoking `write` (for example to
/// clear transient confirmation state on GPU adapter changes).
Widget buildSettingDescriptorWidget(
  FtermDescriptor descriptor, {
  required FtermWorkspaceController workspace,
  required FtermOverlayPalette palette,
  required FtermCapabilityContext capabilities,
  VoidCallback? onBeforeWrite,
}) {
  if (!descriptor.isVisibleFor(capabilities)) {
    return const SizedBox.shrink();
  }
  return switch (descriptor) {
    FtermToggleSettingDescriptor() => _buildToggleWidget(
      descriptor,
      workspace: workspace,
      palette: palette,
      onBeforeWrite: onBeforeWrite,
    ),
    FtermEnumSettingDescriptor() => descriptor.accept(
      _BlenderEnumSettingRenderer(
        workspace: workspace,
        palette: palette,
        capabilities: capabilities,
        onBeforeWrite: onBeforeWrite,
      ),
    ),
    FtermSliderSettingDescriptor() => _buildSliderWidget(
      descriptor,
      workspace: workspace,
      palette: palette,
      onBeforeWrite: onBeforeWrite,
    ),
    FtermCustomSettingDescriptor() ||
    FtermActionDescriptor() => const SizedBox.shrink(),
  };
}

void _dispatchWrite(FutureOr<void> result) {
  if (result is Future<void>) {
    unawaited(result);
  }
}

Widget _buildToggleWidget(
  FtermToggleSettingDescriptor descriptor, {
  required FtermWorkspaceController workspace,
  required FtermOverlayPalette palette,
  required VoidCallback? onBeforeWrite,
}) => BlenderCheckboxRow(
  label: descriptor.settingsLabel,
  caption: descriptor.settingsCaption,
  value: descriptor.read(workspace),
  controlKey: descriptor.controlKey,
  palette: palette,
  onChanged: (next) {
    onBeforeWrite?.call();
    _dispatchWrite(descriptor.write(workspace, next));
  },
);

Widget _buildSliderWidget(
  FtermSliderSettingDescriptor descriptor, {
  required FtermWorkspaceController workspace,
  required FtermOverlayPalette palette,
  required VoidCallback? onBeforeWrite,
}) {
  if (descriptor.usesCustomSettingsWidget) {
    return const SizedBox.shrink();
  }
  final current = descriptor.read(workspace);
  return BlenderSliderRow(
    label: descriptor.label,
    value: current,
    min: descriptor.min,
    max: descriptor.max,
    valueLabel: descriptor.formatValue(current),
    sliderKey: descriptor.sliderKey,
    valueKey: descriptor.valueKey,
    palette: palette,
    onChanged: (next) {
      onBeforeWrite?.call();
      descriptor.write(workspace, next);
    },
  );
}

final class _BlenderEnumSettingRenderer
    implements FtermEnumDescriptorVisitor<Widget> {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final FtermCapabilityContext capabilities;
  final VoidCallback? onBeforeWrite;

  const _BlenderEnumSettingRenderer({
    required this.workspace,
    required this.palette,
    required this.capabilities,
    required this.onBeforeWrite,
  });

  @override
  Widget visitEnum<T>(FtermEnumSettingDescriptor<T> descriptor) {
    final visibleOptions = <FtermEnumOption<T>>[
      for (final option in descriptor.optionsBuilder(capabilities))
        if (option.isVisibleFor(capabilities)) option,
    ];
    if (visibleOptions.isEmpty) {
      return const SizedBox.shrink();
    }

    final hintText = descriptor.settingsHintBuilder?.call(
      workspace,
      capabilities,
    );
    final hint = hintText == null
        ? null
        : Text(
            hintText,
            key: descriptor.settingsHintKey,
            style: TextStyle(color: palette.muted, fontSize: 10.5),
          );

    final control = switch (descriptor.renderStyle) {
      .segmented => _buildSegmentedControl<T>(descriptor, visibleOptions),
      .dropdown => _buildDropdownControl<T>(descriptor, visibleOptions),
    };

    return BlenderPropertyRow(
      label: descriptor.settingsLabel,
      palette: palette,
      hint: hint,
      control: control,
    );
  }

  Widget _buildSegmentedControl<T>(
    FtermEnumSettingDescriptor<T> descriptor,
    List<FtermEnumOption<T>> options,
  ) => BlenderSegmentedControl<T>(
    value: descriptor.read(workspace),
    palette: palette,
    options: <BlenderSegmentedOption<T>>[
      for (final option in options)
        BlenderSegmentedOption<T>(
          key: option.settingsKey,
          value: option.value,
          label: option.label,
        ),
    ],
    onChanged: (next) {
      onBeforeWrite?.call();
      _dispatchWrite(descriptor.write(workspace, next));
    },
  );

  Widget _buildDropdownControl<T>(
    FtermEnumSettingDescriptor<T> descriptor,
    List<FtermEnumOption<T>> options,
  ) {
    final current = descriptor.read(workspace);
    final hasCurrent = options.any((option) => option.value == current);
    return BlenderDropdown<T>(
      dropdownKey: descriptor.dropdownKey,
      value: hasCurrent ? current : null,
      palette: palette,
      items: <DropdownMenuItem<T>>[
        for (final option in options)
          DropdownMenuItem<T>(
            key: option.settingsKey,
            value: option.value,
            child: Text(option.label, overflow: .ellipsis),
          ),
      ],
      onChanged: (next) {
        if (next case final T selected) {
          onBeforeWrite?.call();
          _dispatchWrite(descriptor.write(workspace, selected));
        }
      },
    );
  }
}
