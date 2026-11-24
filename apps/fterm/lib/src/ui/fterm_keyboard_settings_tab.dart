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
  static final Set<LogicalKeyboardKey> _modifierOnlyKeys = {
    .shiftLeft,
    .shiftRight,
    .shift,
    .controlLeft,
    .controlRight,
    .control,
    .altLeft,
    .altRight,
    .alt,
    .metaLeft,
    .metaRight,
    .meta,
    .capsLock,
  };

  late final TextEditingController _chordInputCtrl;
  late final FocusNode _recordFocusNode;
  bool _recording = false;
  String? _inputError;

  TargetPlatform get _platform =>
      widget.platformOverride ?? defaultTargetPlatform;

  @override
  void initState() {
    super.initState();
    _chordInputCtrl = TextEditingController();
    _recordFocusNode = FocusNode(debugLabel: 'fterm-chord-recorder');
  }

  @override
  void dispose() {
    _chordInputCtrl.dispose();
    _recordFocusNode.dispose();
    super.dispose();
  }

  void _selectMetaMode(FtermMetaKeyMode mode) {
    final prefs = widget.workspace.preferences;
    widget.workspace.updatePreferences(prefs.copyWith(metaKeyMode: mode));
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
    if (_inputError != null) {
      setState(() => _inputError = null);
    }
  }

  void _addPresetChord(KeyChord chord) {
    final prefs = widget.workspace.preferences;
    if (prefs.passthroughShortcuts.contains(chord)) return;
    widget.workspace.updatePreferences(
      prefs.copyWith(
        passthroughShortcuts: [...prefs.passthroughShortcuts, chord],
      ),
    );
    if (_inputError != null) {
      setState(() => _inputError = null);
    }
  }

  void _submitChordInput() {
    final rawEntries = _splitRawEntries(_chordInputCtrl.text);
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

  static List<String> _splitRawEntries(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const [];
    return <String>[
      for (final segment in trimmed.split(','))
        if (segment.trim() case final entry when entry.isNotEmpty) entry,
    ];
  }

  void _commitParsedChords(List<KeyChord> candidates) {
    final prefs = widget.workspace.preferences;
    final existing = prefs.passthroughShortcuts;
    final toAdd = <KeyChord>[
      for (final chord in candidates)
        if (!existing.contains(chord)) chord,
    ];
    if (toAdd.isEmpty) {
      final duplicate = candidates.first.toDisplayString(platform: _platform);
      setState(() => _inputError = 'Chord already configured: $duplicate.');
      return;
    }
    widget.workspace.updatePreferences(
      prefs.copyWith(passthroughShortcuts: [...existing, ...toAdd]),
    );
    _chordInputCtrl.clear();
    setState(() => _inputError = null);
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

  static Set<ev.Modifier> _collectModifiers() {
    final kb = HardwareKeyboard.instance;
    return <ev.Modifier>{
      if (kb.isControlPressed) .control,
      if (kb.isAltPressed) .alt,
      if (kb.isShiftPressed) .shift,
      if (kb.isMetaPressed) .meta,
    };
  }

  KeyEventResult _handleRecordKeyEvent(FocusNode _, KeyEvent event) {
    if (!_recording) return .ignored;
    if (event is KeyRepeatEvent) return .handled;
    if (event is! KeyDownEvent) return .ignored;

    final mods = _collectModifiers();
    if (event.logicalKey == .escape && mods.isEmpty) {
      setState(() {
        _recording = false;
        _inputError = null;
      });
      return .handled;
    }
    if (_modifierOnlyKeys.contains(event.logicalKey)) {
      return .handled;
    }
    _captureRecordedChord(event.logicalKey, mods);
    return .handled;
  }

  void _captureRecordedChord(LogicalKeyboardKey key, Set<ev.Modifier> mods) {
    final chord = KeyChord.fromKeyEvent(key, mods);
    if (chord == null) {
      setState(() {
        _inputError =
            'Chord must include Ctrl, Alt, or Meta '
            '(or Shift with a function/navigation key).';
      });
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.workspace.chromeNotifier,
      builder: (_, _) {
        final workspace = widget.workspace;
        final prefs = workspace.preferences;
        final platform = _platform;
        final palette = widget.palette;
        return Column(
          mainAxisSize: .min,
          crossAxisAlignment: .stretch,
          children: [
            _MetaKeyPolicySection(
              mode: prefs.metaKeyMode,
              platform: platform,
              isWeb: widget.isWeb,
              palette: palette,
              onSelected: _selectMetaMode,
            ),
            const SizedBox(height: 12),
            _PassthroughShortcutsSection(
              chords: prefs.passthroughShortcuts,
              platform: platform,
              isWeb: widget.isWeb,
              palette: palette,
              inputController: _chordInputCtrl,
              recordFocusNode: _recordFocusNode,
              isRecording: _recording,
              inputError: _inputError,
              onInputChanged: () {
                if (_inputError != null) {
                  setState(() => _inputError = null);
                }
              },
              onSubmitInput: _submitChordInput,
              onToggleRecording: _toggleRecording,
              onRecordKeyEvent: _handleRecordKeyEvent,
              onRemoveChord: _removeChord,
              onClearAll: _clearAllChords,
              onAddPreset: _addPresetChord,
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
  static const List<(FtermMetaKeyMode mode, String label)> _modes = [
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
  Widget build(BuildContext context) {
    return Column(
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
  final VoidCallback onClearAll;
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
    required this.onClearAll,
    required this.onAddPreset,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
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
            isWeb: isWeb,
            palette: palette,
            onRemoveChord: onRemoveChord,
          ),
        ],
        const SizedBox(height: 8),
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

  List<String> _collidingLabels() => <String>[
    for (final chord in chords)
      if (KeyChord.collidesWithBuiltinShortcut(
        chord,
        platform: platform,
        isWeb: isWeb,
      ))
        chord.toDisplayString(platform: platform),
  ];

  @override
  Widget build(BuildContext context) {
    final collisions = _collidingLabels();
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
    return Column(
      mainAxisSize: .min,
      crossAxisAlignment: .stretch,
      children: [
        Row(
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
            const SizedBox(width: 6),
            OutlinedButton.icon(
              key: const ValueKey('settings-passthrough-record'),
              onPressed: onToggleRecording,
              icon: Icon(
                isRecording
                    ? Icons.stop_circle_outlined
                    : Icons.fiber_manual_record_outlined,
                size: 14,
              ),
              label: Text(isRecording ? 'Cancel' : 'Record chord'),
            ),
          ],
        ),
        Focus(
          focusNode: recordFocusNode,
          onKeyEvent: onRecordKeyEvent,
          child: isRecording
              ? Padding(
                  padding: const .only(top: 6),
                  child: Text(
                    'Press a chord (Esc to cancel)...',
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
  static final KeyChord _metaEqual = KeyChord(
    key: .equal,
    modifiers: const {.meta},
  );
  static final KeyChord _altMetaI = KeyChord(
    key: .keyI,
    modifiers: const {.alt, .meta},
  );
  static final KeyChord _ctrlShiftI = KeyChord(
    key: .keyI,
    modifiers: const {.control, .shift},
  );
  static final KeyChord _altArrowLeft = KeyChord(
    key: .arrowLeft,
    modifiers: const {.alt},
  );
  static final KeyChord _altF4 = KeyChord(key: .f4, modifiers: const {.alt});
  static final KeyChord _altSpace = KeyChord(
    key: .space,
    modifiers: const {.alt},
  );

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

  static List<KeyChord> _presetsFor(TargetPlatform platform, bool isWeb) {
    if (platform == .macOS) return [_metaEqual, _altMetaI];
    if (isWeb) return [_ctrlShiftI, _altArrowLeft];
    if (platform == .windows) return [_altF4, _altSpace];
    return [_altF4, _ctrlShiftI];
  }

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
