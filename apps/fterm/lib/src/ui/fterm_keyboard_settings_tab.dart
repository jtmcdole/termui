import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:material_ui/material_ui.dart';

import '../input/key_chord.dart';
import '../settings_storage.dart';
import '../workspace/fterm_workspace_controller.dart';
import 'fterm_overlays.dart';

/// Settings tab configuring Meta/Cmd key policy, user-defined passthrough
/// ("ignored") key chords, and keyboard host toggles.
final class FtermKeyboardSettingsTab extends StatefulWidget {
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
  State<FtermKeyboardSettingsTab> createState() =>
      _FtermKeyboardSettingsTabState();
}

final class _FtermKeyboardSettingsTabState
    extends State<FtermKeyboardSettingsTab> {
  final TextEditingController _chordInputCtrl = TextEditingController();
  String? _inputError;

  TargetPlatform get _platform =>
      widget.platformOverride ?? defaultTargetPlatform;

  @override
  void dispose() {
    _chordInputCtrl.dispose();
    super.dispose();
  }

  void _clearError() {
    if (_inputError != null) setState(() => _inputError = null);
  }

  void _removeChord(KeyChord target) {
    final prefs = widget.workspace.preferences;
    final remaining = <KeyChord>[
      for (final chord in prefs.passthroughShortcuts)
        if (chord != target) chord,
    ];
    widget.workspace.updatePreferences(
      prefs.copyWith(passthroughShortcuts: remaining),
    );
  }

  void _clearAllChords() {
    final prefs = widget.workspace.preferences;
    widget.workspace.updatePreferences(
      prefs.copyWith(passthroughShortcuts: const []),
    );
    _clearError();
  }

  void _submitChordInput() {
    final rawEntries = <String>[
      for (final seg in _chordInputCtrl.text.trim().split(','))
        if (seg.trim() case final entry when entry.isNotEmpty) entry,
    ];
    if (rawEntries.isEmpty) {
      setState(
        () => _inputError = 'Enter one or more key chords (e.g. Ctrl+Shift+I).',
      );
      return;
    }
    final parsed = KeyChord.parseAll(rawEntries);
    if (parsed.invalid.isNotEmpty) {
      setState(() {
        _inputError =
            'Invalid or unsafe chord: ${parsed.invalid.join(', ')}. '
            'Include Ctrl, Alt, or Meta (or Shift with a function/nav key).';
      });
      return;
    }
    _commitParsedChords(parsed.chords);
  }

  void _commitParsedChords(List<KeyChord> candidates) {
    final prefs = widget.workspace.preferences;
    final existing = prefs.passthroughShortcuts;
    final toAdd = <KeyChord>[
      for (final chord in candidates)
        if (!existing.contains(chord)) chord,
    ];
    if (toAdd.isEmpty) {
      final dup = candidates.first.toDisplayString(platform: _platform);
      setState(() => _inputError = 'Chord already configured: $dup.');
      return;
    }
    widget.workspace.updatePreferences(
      prefs.copyWith(passthroughShortcuts: [...existing, ...toAdd]),
    );
    _chordInputCtrl.clear();
    setState(() => _inputError = null);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.workspace.chromeNotifier,
      builder: (_, _) {
        final workspace = widget.workspace;
        final prefs = workspace.preferences;
        final platform = _platform;
        return Column(
          mainAxisSize: .min,
          crossAxisAlignment: .stretch,
          children: [
            _MetaKeyPolicySection(
              mode: prefs.metaKeyMode,
              platform: platform,
              isWeb: widget.isWeb,
              palette: widget.palette,
              onSelected: (mode) => workspace.updatePreferences(
                prefs.copyWith(metaKeyMode: mode),
              ),
            ),
            const SizedBox(height: 12),
            _PassthroughShortcutsSection(
              chords: prefs.passthroughShortcuts,
              platform: platform,
              palette: widget.palette,
              inputController: _chordInputCtrl,
              inputError: _inputError,
              onInputChanged: _clearError,
              onSubmitInput: _submitChordInput,
              onRemoveChord: _removeChord,
              onClearAll: _clearAllChords,
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

final class _PassthroughShortcutsSection extends StatelessWidget {
  final List<KeyChord> chords;
  final TargetPlatform platform;
  final FtermOverlayPalette palette;
  final TextEditingController inputController;
  final String? inputError;
  final VoidCallback onInputChanged;
  final VoidCallback onSubmitInput;
  final ValueChanged<KeyChord> onRemoveChord;
  final VoidCallback onClearAll;

  const _PassthroughShortcutsSection({
    required this.chords,
    required this.platform,
    required this.palette,
    required this.inputController,
    required this.inputError,
    required this.onInputChanged,
    required this.onSubmitInput,
    required this.onRemoveChord,
    required this.onClearAll,
  });

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: .min,
    crossAxisAlignment: .stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              'Ignored Chords (Do Not Intercept)',
              style: TextStyle(color: palette.muted, fontSize: 11),
            ),
          ),
          if (chords.isNotEmpty)
            TextButton(
              key: const ValueKey('settings-passthrough-clear-all'),
              onPressed: onClearAll,
              style: TextButton.styleFrom(
                visualDensity: .compact,
                padding: const .symmetric(horizontal: 8, vertical: 2),
                minimumSize: .zero,
                tapTargetSize: .shrinkWrap,
              ),
              child: const Text('Clear all'),
            ),
        ],
      ),
      if (chords.isNotEmpty) ...[
        const SizedBox(height: 6),
        _ActivePassthroughChords(
          chords: chords,
          platform: platform,
          onRemoveChord: onRemoveChord,
        ),
      ],
      const SizedBox(height: 8),
      _PassthroughInputRow(
        controller: inputController,
        palette: palette,
        onInputChanged: onInputChanged,
        onSubmitInput: onSubmitInput,
      ),
      if (inputError case final error?) ...[
        const SizedBox(height: 4),
        Text(
          error,
          key: const ValueKey('settings-passthrough-error'),
          style: TextStyle(color: palette.danger, fontSize: 11),
        ),
      ],
    ],
  );
}

final class _ActivePassthroughChords extends StatelessWidget {
  final List<KeyChord> chords;
  final TargetPlatform platform;
  final ValueChanged<KeyChord> onRemoveChord;

  const _ActivePassthroughChords({
    required this.chords,
    required this.platform,
    required this.onRemoveChord,
  });

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final chord in chords)
        InputChip(
          key: ValueKey(
            'settings-passthrough-chip-${chord.toCanonicalString()}',
          ),
          label: Text(chord.toDisplayString(platform: platform)),
          deleteIcon: const Icon(Icons.close, size: 14),
          visualDensity: .compact,
          onDeleted: () => onRemoveChord(chord),
        ),
    ],
  );
}

final class _PassthroughInputRow extends StatelessWidget {
  final TextEditingController controller;
  final FtermOverlayPalette palette;
  final VoidCallback onInputChanged;
  final VoidCallback onSubmitInput;

  const _PassthroughInputRow({
    required this.controller,
    required this.palette,
    required this.onInputChanged,
    required this.onSubmitInput,
  });

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: TextField(
          key: const ValueKey('settings-passthrough-input'),
          controller: controller,
          decoration: InputDecoration(
            isDense: true,
            hintText: 'e.g. Ctrl+Shift+I, Alt+F4',
            hintStyle: TextStyle(color: palette.muted, fontSize: 11),
          ),
          onChanged: (_) => onInputChanged(),
          onSubmitted: (_) => onSubmitInput(),
        ),
      ),
      const SizedBox(width: 6),
      OutlinedButton(
        key: const ValueKey('settings-passthrough-add'),
        onPressed: onSubmitInput,
        child: const Text('Add'),
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
