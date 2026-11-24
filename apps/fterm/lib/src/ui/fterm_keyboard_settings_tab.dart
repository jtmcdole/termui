import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:material_ui/material_ui.dart';

import '../settings_storage.dart';
import '../workspace/fterm_workspace_controller.dart';
import 'fterm_overlays.dart';

/// Settings tab configuring Meta/Cmd key policy and keyboard host toggles.
final class FtermKeyboardSettingsTab extends StatelessWidget {
  /// Backing workspace controller mutated by keyboard settings controls.
  final FtermWorkspaceController workspace;

  /// Overlay color palette derived from the active terminal theme.
  final FtermOverlayPalette palette;

  /// Whether the host is running on Web/Wasm.
  final bool isWeb;

  /// Optional platform override for hermetic cross-platform testing.
  final TargetPlatform? platformOverride;

  /// Creates the Keyboard tab rendered inside the `fterm` Settings modal.
  const FtermKeyboardSettingsTab({
    super.key,
    required this.workspace,
    required this.palette,
    required this.isWeb,
    this.platformOverride,
  });

  @override
  Widget build(BuildContext context) {
    final platform = platformOverride ?? defaultTargetPlatform;
    return ListenableBuilder(
      listenable: workspace.chromeNotifier,
      builder: (_, _) {
        final prefs = workspace.preferences;
        return Column(
          mainAxisSize: .min,
          crossAxisAlignment: .stretch,
          children: [
            _MetaKeyPolicySection(
              mode: prefs.metaKeyMode,
              platform: platform,
              isWeb: isWeb,
              palette: palette,
              onSelected: (mode) => workspace.updatePreferences(
                prefs.copyWith(metaKeyMode: mode),
              ),
            ),
            const SizedBox(height: 10),
            _KeyboardTogglesSection(workspace: workspace),
          ],
        );
      },
    );
  }
}

final class _MetaKeyPolicySection extends StatelessWidget {
  static const List<(FtermMetaKeyMode, String)> _modes = [
    (.auto, 'Auto'),
    (.passThrough, 'Always Pass Through'),
    (.kitty, 'Kitty Only'),
  ];

  final FtermMetaKeyMode mode;
  final TargetPlatform platform;
  final bool isWeb;
  final FtermOverlayPalette palette;
  final ValueChanged<FtermMetaKeyMode> onSelected;

  const _MetaKeyPolicySection({
    required this.mode,
    required this.platform,
    required this.isWeb,
    required this.palette,
    required this.onSelected,
  });

  static String _summaryText({
    required FtermMetaKeyMode mode,
    required TargetPlatform platform,
    required bool isWeb,
  }) => switch (mode) {
    .passThrough =>
      isWeb
          ? 'Always passes unhandled Meta/Cmd chords to the browser.'
          : 'Always passes unhandled Meta/Cmd chords to the OS.',
    .kitty =>
      'Claims unhandled Meta/Cmd chords when Kitty keyboard protocol is active; '
          'passes through in legacy mode.',
    .auto when isWeb =>
      'Auto (Web): passes unhandled Meta/Cmd chords to the browser.',
    .auto when platform == .macOS =>
      'Auto (macOS): passes unhandled Cmd chords to macOS.',
    .auto =>
      'Auto (Desktop): claims unhandled Meta chords when Kitty keyboard '
          'protocol is active.',
  };

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: .min,
    crossAxisAlignment: .stretch,
    children: [
      Text(
        'Meta / Cmd Key Policy',
        style: TextStyle(color: palette.muted, fontSize: 11),
      ),
      const SizedBox(height: 6),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final (candidate, label) in _modes)
            ChoiceChip(
              key: ValueKey('settings-meta-mode-${candidate.name}'),
              label: Text(label),
              selected: mode == candidate,
              onSelected: (_) => onSelected(candidate),
            ),
        ],
      ),
      const SizedBox(height: 6),
      Text(
        _summaryText(mode: mode, platform: platform, isWeb: isWeb),
        key: const ValueKey('settings-meta-mode-summary'),
        style: TextStyle(color: palette.muted, fontSize: 11),
      ),
    ],
  );
}

final class _KeyboardTogglesSection extends StatelessWidget {
  final FtermWorkspaceController workspace;

  const _KeyboardTogglesSection({required this.workspace});

  @override
  Widget build(BuildContext context) {
    final prefs = workspace.preferences;
    final wsSettings = workspace.workspaceSettings;
    return Column(
      mainAxisSize: .min,
      crossAxisAlignment: .stretch,
      children: [
        SwitchListTile.adaptive(
          key: const ValueKey('settings-macos-option-as-alt'),
          dense: true,
          contentPadding: .zero,
          title: const Text('macOS Option key acts as Alt'),
          value: prefs.macosOptionAsAlt,
          onChanged: (v) =>
              workspace.updatePreferences(prefs.copyWith(macosOptionAsAlt: v)),
        ),
        SwitchListTile.adaptive(
          key: const ValueKey('settings-f12-toggle'),
          dense: true,
          contentPadding: .zero,
          title: const Text('Enable F12 host shortcuts (screenshot/atlas)'),
          value: wsSettings.f12ShortcutsEnabled,
          onChanged: workspace.setF12ShortcutsEnabled,
        ),
      ],
    );
  }
}
