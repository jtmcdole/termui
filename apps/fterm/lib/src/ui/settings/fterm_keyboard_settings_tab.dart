import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart'
    show
        HardwareKeyboard,
        KeyDownEvent,
        KeyEvent,
        KeyRepeatEvent,
        LogicalKeyboardKey;
import 'package:material_ui/material_ui.dart';
import 'package:termui/terminal/event.dart' as ev;

import '../../input/key_chord.dart';
import '../../settings_storage.dart';
import '../../workspace/fterm_workspace_controller.dart';
import '../fterm_overlays.dart';
import 'settings_primitives.dart';

/// Settings section configuring Meta/Cmd key policy, user-defined passthrough
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

  /// Panel visibility, collapse state, and search-filter configuration.
  final SettingsPanelFilter filter;

  /// Creates the Keyboard section rendered inside the `fterm` Settings modal.
  const FtermKeyboardSettingsTab({
    super.key,
    required this.workspace,
    required this.palette,
    required this.isWeb,
    this.platformOverride,
    this.filter = const SettingsPanelFilter.showAll(),
  });

  @override
  State<FtermKeyboardSettingsTab> createState() =>
      _FtermKeyboardSettingsTabState();
}

final class _FtermKeyboardSettingsTabState
    extends State<FtermKeyboardSettingsTab> {
  static bool _isModifierKey(LogicalKeyboardKey k) => switch (k) {
    .shiftLeft ||
    .shiftRight ||
    .shift ||
    .controlLeft ||
    .controlRight ||
    .control ||
    .altLeft ||
    .altRight ||
    .alt ||
    .metaLeft ||
    .metaRight ||
    .meta ||
    .capsLock => true,
    _ => false,
  };

  final _chordInputCtrl = TextEditingController();
  final _recordFocusNode = FocusNode(debugLabel: 'fterm-chord-recorder');
  bool _recording = false;
  String? _inputError;

  TargetPlatform get _platform =>
      widget.platformOverride ?? defaultTargetPlatform;

  @override
  void dispose() {
    _chordInputCtrl.dispose();
    _recordFocusNode.dispose();
    super.dispose();
  }

  void _clearError() {
    if (_inputError != null) setState(() => _inputError = null);
  }

  void _addPresetChord(KeyChord chord) {
    final prefs = widget.workspace.preferences;
    if (prefs.passthroughShortcuts.contains(chord)) return;
    widget.workspace.updatePreferences(
      prefs.copyWith(
        passthroughShortcuts: [...prefs.passthroughShortcuts, chord],
      ),
    );
    _clearError();
  }

  void _toggleRecording() {
    final next = !_recording;
    setState(() {
      _recording = next;
      _inputError = null;
    });
    if (next) {
      _recordFocusNode.requestFocus();
    } else if (_recordFocusNode.hasFocus) {
      _recordFocusNode.unfocus();
    }
  }

  KeyEventResult _handleRecordKeyEvent(FocusNode _, KeyEvent event) {
    if (!_recording) return .ignored;
    if (event is KeyRepeatEvent) return .handled;
    if (event is! KeyDownEvent) return .ignored;
    final kb = HardwareKeyboard.instance;
    final mods = <ev.Modifier>{
      if (kb.isControlPressed) .control,
      if (kb.isAltPressed) .alt,
      if (kb.isShiftPressed) .shift,
      if (kb.isMetaPressed) .meta,
    };
    if (event.logicalKey == .escape && mods.isEmpty) {
      setState(() {
        _recording = false;
        _inputError = null;
      });
      return .handled;
    }
    if (_isModifierKey(event.logicalKey)) return .handled;
    _captureRecordedChord(event.logicalKey, mods);
    return .handled;
  }

  void _captureRecordedChord(LogicalKeyboardKey key, Set<ev.Modifier> mods) {
    final chord = KeyChord.fromKeyEvent(key, mods);
    if (chord == null) {
      setState(
        () => _inputError =
            'Chord must include Ctrl, Alt, or Meta '
            '(or Shift with a function/navigation key).',
      );
      return;
    }
    final prefs = widget.workspace.preferences;
    if (prefs.passthroughShortcuts.contains(chord)) {
      final label = chord.toDisplayString(platform: _platform);
      setState(() {
        _recording = false;
        _inputError = 'Chord already configured: $label.';
      });
      return;
    }
    widget.workspace.updatePreferences(
      prefs.copyWith(
        passthroughShortcuts: [...prefs.passthroughShortcuts, chord],
      ),
    );
    setState(() {
      _recording = false;
      _inputError = null;
    });
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
    final filter = widget.filter;
    final palette = widget.palette;
    return ListenableBuilder(
      listenable: widget.workspace.chromeNotifier,
      builder: (_, _) => SettingsSpacedColumn(
        children: [
          if (filter.showPanel('keyboard-meta'))
            _KeyboardMetaPanel(
              workspace: widget.workspace,
              platform: _platform,
              isWeb: widget.isWeb,
              palette: palette,
              filter: filter,
            ),
          if (filter.showPanel('keyboard-passthrough'))
            _KeyboardPassthroughPanel(
              chords: widget.workspace.preferences.passthroughShortcuts,
              platform: _platform,
              isWeb: widget.isWeb,
              palette: palette,
              filter: filter,
              inputController: _chordInputCtrl,
              recordFocusNode: _recordFocusNode,
              isRecording: _recording,
              inputError: _inputError,
              onInputChanged: _clearError,
              onSubmitInput: _submitChordInput,
              onToggleRecording: _toggleRecording,
              onRecordKeyEvent: _handleRecordKeyEvent,
              onRemoveChord: _removeChord,
              onAddPreset: _addPresetChord,
              onClearAll: _clearAllChords,
            ),
          if (filter.showPanel('keyboard-host-keys'))
            _KeyboardHostKeysPanel(
              workspace: widget.workspace,
              palette: palette,
              filter: filter,
            ),
        ],
      ),
    );
  }
}

final class _KeyboardMetaPanel extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final TargetPlatform platform;
  final bool isWeb;
  final FtermOverlayPalette palette;
  final SettingsPanelFilter filter;

  const _KeyboardMetaPanel({
    required this.workspace,
    required this.platform,
    required this.isWeb,
    required this.palette,
    required this.filter,
  });

  @override
  Widget build(BuildContext context) {
    final prefs = workspace.preferences;
    return BlenderSettingsPanel(
      id: 'keyboard-meta',
      title: 'Meta / Cmd Key Policy',
      categoryBreadcrumb: filter.categoryBreadcrumb,
      expanded: filter.panelExpanded('keyboard-meta'),
      onToggleExpanded: filter.toggleFor('keyboard-meta'),
      palette: palette,
      child: _MetaKeyPolicySection(
        mode: prefs.metaKeyMode,
        platform: platform,
        isWeb: isWeb,
        palette: palette,
        onSelected: (mode) =>
            workspace.updatePreferences(prefs.copyWith(metaKeyMode: mode)),
      ),
    );
  }
}

final class _KeyboardPassthroughPanel extends StatelessWidget {
  final List<KeyChord> chords;
  final TargetPlatform platform;
  final bool isWeb;
  final FtermOverlayPalette palette;
  final SettingsPanelFilter filter;
  final TextEditingController inputController;
  final FocusNode recordFocusNode;
  final bool isRecording;
  final String? inputError;
  final VoidCallback onInputChanged;
  final VoidCallback onSubmitInput;
  final VoidCallback onToggleRecording;
  final FocusOnKeyEventCallback onRecordKeyEvent;
  final ValueChanged<KeyChord> onRemoveChord;
  final ValueChanged<KeyChord> onAddPreset;
  final VoidCallback onClearAll;

  const _KeyboardPassthroughPanel({
    required this.chords,
    required this.platform,
    required this.isWeb,
    required this.palette,
    required this.filter,
    required this.inputController,
    required this.recordFocusNode,
    required this.isRecording,
    required this.inputError,
    required this.onInputChanged,
    required this.onSubmitInput,
    required this.onToggleRecording,
    required this.onRecordKeyEvent,
    required this.onRemoveChord,
    required this.onAddPreset,
    required this.onClearAll,
  });

  @override
  Widget build(BuildContext context) => BlenderSettingsPanel(
    id: 'keyboard-passthrough',
    title: 'Ignored Chords (Do Not Intercept)',
    categoryBreadcrumb: filter.categoryBreadcrumb,
    expanded: filter.panelExpanded('keyboard-passthrough'),
    onToggleExpanded: filter.toggleFor('keyboard-passthrough'),
    palette: palette,
    trailing: chords.isNotEmpty
        ? TextButton(
            key: const ValueKey('settings-passthrough-clear-all'),
            onPressed: onClearAll,
            style: TextButton.styleFrom(
              visualDensity: .compact,
              padding: const .symmetric(horizontal: 8, vertical: 2),
              minimumSize: .zero,
              tapTargetSize: .shrinkWrap,
            ),
            child: const Text('Clear all'),
          )
        : null,
    child: _PassthroughShortcutsSection(
      chords: chords,
      platform: platform,
      isWeb: isWeb,
      palette: palette,
      inputController: inputController,
      recordFocusNode: recordFocusNode,
      isRecording: isRecording,
      inputError: inputError,
      onInputChanged: onInputChanged,
      onSubmitInput: onSubmitInput,
      onToggleRecording: onToggleRecording,
      onRecordKeyEvent: onRecordKeyEvent,
      onRemoveChord: onRemoveChord,
      onAddPreset: onAddPreset,
    ),
  );
}

final class _KeyboardHostKeysPanel extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final SettingsPanelFilter filter;

  const _KeyboardHostKeysPanel({
    required this.workspace,
    required this.palette,
    required this.filter,
  });

  @override
  Widget build(BuildContext context) {
    final prefs = workspace.preferences;
    final wsSettings = workspace.workspaceSettings;
    return BlenderSettingsPanel(
      id: 'keyboard-host-keys',
      title: 'Host & Platform Keys',
      categoryBreadcrumb: filter.categoryBreadcrumb,
      expanded: filter.panelExpanded('keyboard-host-keys'),
      onToggleExpanded: filter.toggleFor('keyboard-host-keys'),
      palette: palette,
      child: SettingsSpacedColumn(
        spacing: 8,
        children: [
          if (filter.showItem('keyboard-macos-option'))
            BlenderCheckboxRow(
              label: 'macOS Option as Alt',
              caption:
                  'Emit Alt+key instead of macOS Option dead-key composition',
              value: prefs.macosOptionAsAlt,
              controlKey: const ValueKey('settings-macos-option-as-alt'),
              palette: palette,
              onChanged: (v) => workspace.updatePreferences(
                prefs.copyWith(macosOptionAsAlt: v),
              ),
            ),
          if (filter.showItem('keyboard-f12-shortcuts'))
            BlenderCheckboxRow(
              label: 'F12 Host Shortcuts',
              caption: 'Enable F12 screenshot and Shift+F12 atlas reload keys',
              value: wsSettings.f12ShortcutsEnabled,
              controlKey: const ValueKey('settings-f12-toggle'),
              palette: palette,
              onChanged: workspace.setF12ShortcutsEnabled,
            ),
        ],
      ),
    );
  }
}

final class _MetaKeyPolicySection extends StatelessWidget {
  static const List<(FtermMetaKeyMode, String)> _modes = [
    (.auto, 'Auto'),
    (.passThrough, 'Pass Through'),
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
  Widget build(BuildContext context) => BlenderPropertyRow(
    label: 'Meta / Cmd Mode',
    palette: palette,
    hint: Text(
      _summaryText(mode: mode, platform: platform, isWeb: isWeb),
      key: const ValueKey('settings-meta-mode-summary'),
      style: TextStyle(color: palette.muted, fontSize: 10.5),
    ),
    control: BlenderSegmentedControl<FtermMetaKeyMode>(
      value: mode,
      palette: palette,
      options: [
        for (final (candidate, label) in _modes)
          BlenderSegmentedOption<FtermMetaKeyMode>(
            key: ValueKey('settings-meta-mode-${candidate.name}'),
            value: candidate,
            label: label,
          ),
      ],
      onChanged: onSelected,
    ),
  );
}

final class _PassthroughShortcutsSection extends StatelessWidget {
  final List<KeyChord> chords;
  final TargetPlatform platform;
  final bool isWeb;
  final FtermOverlayPalette palette;
  final TextEditingController inputController;
  final FocusNode recordFocusNode;
  final bool isRecording;
  final String? inputError;
  final VoidCallback onInputChanged;
  final VoidCallback onSubmitInput;
  final VoidCallback onToggleRecording;
  final FocusOnKeyEventCallback onRecordKeyEvent;
  final ValueChanged<KeyChord> onRemoveChord;
  final ValueChanged<KeyChord> onAddPreset;

  const _PassthroughShortcutsSection({
    required this.chords,
    required this.platform,
    required this.isWeb,
    required this.palette,
    required this.inputController,
    required this.recordFocusNode,
    required this.isRecording,
    required this.inputError,
    required this.onInputChanged,
    required this.onSubmitInput,
    required this.onToggleRecording,
    required this.onRecordKeyEvent,
    required this.onRemoveChord,
    required this.onAddPreset,
  });

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: .min,
    crossAxisAlignment: .stretch,
    children: [
      if (chords.isNotEmpty) ...[
        _ActivePassthroughChords(
          chords: chords,
          platform: platform,
          isWeb: isWeb,
          palette: palette,
          onRemoveChord: onRemoveChord,
        ),
        const SizedBox(height: 8),
      ],
      _PassthroughInputRow(
        controller: inputController,
        recordFocusNode: recordFocusNode,
        isRecording: isRecording,
        palette: palette,
        onInputChanged: onInputChanged,
        onSubmitInput: onSubmitInput,
        onToggleRecording: onToggleRecording,
        onRecordKeyEvent: onRecordKeyEvent,
      ),
      if (inputError case final error?) ...[
        const SizedBox(height: 4),
        Text(
          error,
          key: const ValueKey('settings-passthrough-error'),
          style: TextStyle(color: palette.danger, fontSize: 11),
        ),
      ],
      const SizedBox(height: 8),
      _PassthroughPresetsRow(
        configuredChords: chords,
        platform: platform,
        isWeb: isWeb,
        palette: palette,
        onAddPreset: onAddPreset,
      ),
    ],
  );
}

final class _ActivePassthroughChords extends StatelessWidget {
  final List<KeyChord> chords;
  final TargetPlatform platform;
  final bool isWeb;
  final FtermOverlayPalette palette;
  final ValueChanged<KeyChord> onRemoveChord;

  const _ActivePassthroughChords({
    required this.chords,
    required this.platform,
    required this.isWeb,
    required this.palette,
    required this.onRemoveChord,
  });

  @override
  Widget build(BuildContext context) {
    final collisions = <String>[
      for (final chord in chords)
        if (KeyChord.collidesWithBuiltinShortcut(
          chord,
          platform: platform,
          isWeb: isWeb,
        ))
          chord.toDisplayString(platform: platform),
    ];
    return Column(
      mainAxisSize: .min,
      crossAxisAlignment: .stretch,
      children: [
        Wrap(
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
        ),
        if (collisions.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            'Overrides built-in fterm shortcut: ${collisions.join(', ')}',
            key: const ValueKey('settings-passthrough-collision-hint'),
            style: TextStyle(color: palette.warning, fontSize: 11),
          ),
        ],
      ],
    );
  }
}

final class _PassthroughInputRow extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode recordFocusNode;
  final bool isRecording;
  final FtermOverlayPalette palette;
  final VoidCallback onInputChanged;
  final VoidCallback onSubmitInput;
  final VoidCallback onToggleRecording;
  final FocusOnKeyEventCallback onRecordKeyEvent;

  const _PassthroughInputRow({
    required this.controller,
    required this.recordFocusNode,
    required this.isRecording,
    required this.palette,
    required this.onInputChanged,
    required this.onSubmitInput,
    required this.onToggleRecording,
    required this.onRecordKeyEvent,
  });

  @override
  Widget build(BuildContext context) {
    final textField = TextField(
      key: const ValueKey('settings-passthrough-input'),
      controller: controller,
      style: TextStyle(color: palette.foreground, fontSize: 11.5),
      decoration: blenderInputDecoration(
        palette: palette,
        hintText: 'e.g. Ctrl+Shift+I, Alt+F4',
      ),
      onChanged: (_) => onInputChanged(),
      onSubmitted: (_) => onSubmitInput(),
    );
    final addButton = OutlinedButton(
      key: const ValueKey('settings-passthrough-add'),
      onPressed: onSubmitInput,
      child: const Text('Add'),
    );
    final recordButton = OutlinedButton.icon(
      key: const ValueKey('settings-passthrough-record'),
      onPressed: onToggleRecording,
      icon: Icon(
        isRecording
            ? Icons.stop_circle_outlined
            : Icons.fiber_manual_record_outlined,
        size: 14,
      ),
      label: Text(isRecording ? 'Cancel' : 'Record chord'),
    );

    return Column(
      mainAxisSize: .min,
      crossAxisAlignment: .stretch,
      children: [
        LayoutBuilder(
          builder: (_, constraints) {
            if (constraints.maxWidth < 340) {
              return Column(
                mainAxisSize: .min,
                crossAxisAlignment: .stretch,
                children: [
                  textField,
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [addButton, recordButton],
                  ),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: textField),
                const SizedBox(width: 6),
                addButton,
                const SizedBox(width: 6),
                recordButton,
              ],
            );
          },
        ),
        Focus(
          focusNode: recordFocusNode,
          onKeyEvent: onRecordKeyEvent,
          child: isRecording
              ? Padding(
                  padding: const .only(top: 6),
                  child: Text(
                    'Press a chord (Esc to cancel)…',
                    style: TextStyle(color: palette.accent, fontSize: 11),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

final class _PassthroughPresetsRow extends StatelessWidget {
  final List<KeyChord> configuredChords;
  final TargetPlatform platform;
  final bool isWeb;
  final FtermOverlayPalette palette;
  final ValueChanged<KeyChord> onAddPreset;

  const _PassthroughPresetsRow({
    required this.configuredChords,
    required this.platform,
    required this.isWeb,
    required this.palette,
    required this.onAddPreset,
  });

  static List<KeyChord> _presetsFor(TargetPlatform p, bool isWeb) =>
      KeyChord.parseAll(switch ((p, isWeb)) {
        (.macOS, _) => const ['Meta+Equal', 'Alt+Meta+I'],
        (_, true) => const ['Ctrl+Shift+I', 'Alt+ArrowLeft'],
        (.windows, false) => const ['Alt+F4', 'Alt+Space'],
        _ => const ['Alt+F4', 'Ctrl+Shift+I'],
      }).chords;

  @override
  Widget build(BuildContext context) {
    final available = <KeyChord>[
      for (final preset in _presetsFor(platform, isWeb))
        if (!configuredChords.contains(preset)) preset,
    ];
    if (available.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: .min,
      crossAxisAlignment: .stretch,
      children: [
        Text(
          'Quick-add presets',
          style: TextStyle(color: palette.muted, fontSize: 10),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final preset in available)
              ActionChip(
                key: ValueKey(
                  'settings-passthrough-preset-${preset.toCanonicalString()}',
                ),
                avatar: const Icon(Icons.add, size: 14),
                label: Text(preset.toDisplayString(platform: platform)),
                visualDensity: .compact,
                onPressed: () => onAddPreset(preset),
              ),
          ],
        ),
      ],
    );
  }
}
