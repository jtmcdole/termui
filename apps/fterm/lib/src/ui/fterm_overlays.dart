import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';

import '../font_loader.dart';
import '../launch_config.dart';
import '../workspace/fterm_workspace_controller.dart';
import '../workspace/split_tree_model.dart';

/// Modal overlays rendered over the terminal workspace when [FtermOverlay] !=
/// [FtermOverlay.none].
final class FtermOverlayHost extends StatelessWidget {
  /// Backing workspace coordinator.
  final FtermWorkspaceController workspace;

  /// Creates the active modal overlay layer, or `SizedBox.shrink()` when idle.
  const FtermOverlayHost({super.key, required this.workspace});

  @override
  Widget build(BuildContext context) {
    final overlay = workspace.activeOverlay;
    if (overlay == FtermOverlay.none) {
      return const SizedBox.shrink();
    }
    final theme = workspace.activeTerminalTheme;
    final palette = _OverlayColors.fromTerminalTheme(theme);

    return ColoredBox(
      color: const Color(0x99000000),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 540),
          child: Material(
            key: ValueKey('fterm-overlay-${overlay.name}'),
            color: palette.surface,
            elevation: 16,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: palette.border),
            ),
            child: DefaultTextStyle(
              style: TextStyle(
                color: palette.foreground,
                fontFamily: castPrimaryFontFamily,
                fontSize: 12,
              ),
              child: switch (overlay) {
                FtermOverlay.none => const SizedBox.shrink(),
                FtermOverlay.connect => _ConnectOverlay(
                  workspace: workspace,
                  palette: palette,
                ),
                FtermOverlay.sessionPicker => _SessionPickerOverlay(
                  workspace: workspace,
                  palette: palette,
                ),
                FtermOverlay.settings => _SettingsOverlay(
                  workspace: workspace,
                  palette: palette,
                ),
                FtermOverlay.stats => _StatsOverlay(
                  workspace: workspace,
                  palette: palette,
                ),
                FtermOverlay.rename => _RenameOverlay(
                  workspace: workspace,
                  palette: palette,
                ),
                FtermOverlay.help => _HelpOverlay(
                  workspace: workspace,
                  palette: palette,
                ),
                FtermOverlay.fileUpload => _FileUploadOverlay(
                  workspace: workspace,
                  palette: palette,
                ),
              },
            ),
          ),
        ),
      ),
    );
  }
}

final class _OverlayColors {
  final Color surface;
  final Color surfaceAlt;
  final Color foreground;
  final Color muted;
  final Color accent;
  final Color border;
  final Color danger;

  const _OverlayColors({
    required this.surface,
    required this.surfaceAlt,
    required this.foreground,
    required this.muted,
    required this.accent,
    required this.border,
    required this.danger,
  });

  factory _OverlayColors.fromTerminalTheme(tui.TerminalColorTheme theme) {
    final bg = Color(theme.background.argb);
    final fg = Color(theme.foreground.argb);
    final accent = Color(theme.resolveAnsi256(4).argb);
    final isDark = theme.brightness == tui.TerminalBrightness.dark;
    return _OverlayColors(
      surface: isDark
          ? Color.lerp(bg, const Color(0xFFFFFFFF), 0.06)!
          : Color.lerp(bg, const Color(0xFF000000), 0.03)!,
      surfaceAlt: isDark
          ? Color.lerp(bg, const Color(0xFFFFFFFF), 0.11)!
          : Color.lerp(bg, const Color(0xFF000000), 0.07)!,
      foreground: fg,
      muted: fg.withValues(alpha: 0.65),
      accent: accent,
      border: fg.withValues(alpha: 0.2),
      danger: Color(theme.resolveAnsi256(1).argb),
    );
  }
}

Widget _overlayHeader({
  required String title,
  required _OverlayColors palette,
  required VoidCallback onClose,
}) {
  return Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: TextStyle(
            color: palette.foreground,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
      ),
      IconButton(
        onPressed: onClose,
        icon: Icon(Icons.close, size: 16, color: palette.muted),
        tooltip: 'Close (Esc)',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 26, height: 26),
      ),
    ],
  );
}

final class _ConnectOverlay extends StatefulWidget {
  final FtermWorkspaceController workspace;
  final _OverlayColors palette;

  const _ConnectOverlay({required this.workspace, required this.palette});

  @override
  State<_ConnectOverlay> createState() => _ConnectOverlayState();
}

final class _ConnectOverlayState extends State<_ConnectOverlay> {
  late final TextEditingController _urlCtrl;
  late final TextEditingController _clientTokenCtrl;
  late final TextEditingController _casterTokenCtrl;
  String? _validationError;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(
      text: widget.workspace.activeRelayUri.toString(),
    );
    _clientTokenCtrl = TextEditingController(
      text: widget.workspace.activeClientToken,
    );
    _casterTokenCtrl = TextEditingController(
      text: widget.workspace.activeCasterToken,
    );
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _clientTokenCtrl.dispose();
    _casterTokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final Uri parsed;
    try {
      parsed = CastLaunchConfig.parseRelayUri(_urlCtrl.text);
    } on FormatException catch (e) {
      setState(() => _validationError = e.message);
      return;
    }
    setState(() {
      _validationError = null;
      _submitting = true;
    });
    await widget.workspace.connectRelay(
      serverUri: parsed,
      clientToken: _clientTokenCtrl.text,
      casterToken: _casterTokenCtrl.text,
    );
    if (mounted) {
      setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final statusMsg = _validationError ?? widget.workspace.statusBanner;
    final remoteCount = widget.workspace.availableRemoteSessions.length;
    final showSessionsButton =
        widget.workspace.connectionState ==
            ClientConnectionState.authenticated ||
        remoteCount > 0;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: FocusTraversalGroup(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _overlayHeader(
              title: 'Connect to Relay',
              palette: p,
              onClose: widget.workspace.dismissOverlay,
            ),
            if (statusMsg != null) ...[
              const SizedBox(height: 8),
              Text(statusMsg, style: TextStyle(color: p.danger, fontSize: 11)),
            ],
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('connect-url-field'),
              controller: _urlCtrl,
              autofocus: true,
              decoration: _inputDeco(
                'Relay Host or URL (host, https://, ws://, wss://)',
                p,
              ),
              onSubmitted: (_) => unawaited(_submit()),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('connect-token-field'),
              controller: _clientTokenCtrl,
              obscureText: true,
              decoration: _inputDeco('Viewer Bearer Token', p),
              onSubmitted: (_) => unawaited(_submit()),
            ),
            if (widget.workspace.isDesktopHost) ...[
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('connect-caster-token-field'),
                controller: _casterTokenCtrl,
                obscureText: true,
                decoration: _inputDeco(
                  'Caster Token (optional, for local pane sharing)',
                  p,
                ),
                onSubmitted: (_) => unawaited(_submit()),
              ),
            ],
            const SizedBox(height: 14),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (showSessionsButton)
                  OutlinedButton.icon(
                    key: const ValueKey('connect-open-sessions'),
                    onPressed: () =>
                        widget.workspace.setOverlay(FtermOverlay.sessionPicker),
                    icon: const Icon(Icons.dns_outlined, size: 14),
                    label: Text('Remote Sessions ($remoteCount)'),
                  ),
                TextButton(
                  onPressed: widget.workspace.dismissOverlay,
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  key: const ValueKey('connect-submit-button'),
                  onPressed: _submitting ? null : _submit,
                  child: Text(_submitting ? 'Connecting...' : 'Connect'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static InputDecoration _inputDeco(String label, _OverlayColors p) =>
      InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: p.muted, fontSize: 11),
        isDense: true,
        border: OutlineInputBorder(borderSide: BorderSide(color: p.border)),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: p.border),
        ),
      );
}

final class _SessionPickerOverlay extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final _OverlayColors palette;

  const _SessionPickerOverlay({required this.workspace, required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final remoteSessions = workspace.availableRemoteSessions;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _overlayHeader(
            title: 'Sessions & Shells',
            palette: p,
            onClose: workspace.dismissOverlay,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (workspace.isDesktopHost)
                FilledButton.icon(
                  key: const ValueKey('picker-new-shell'),
                  onPressed: () => unawaited(workspace.openLocalShellTab()),
                  icon: const Icon(Icons.terminal, size: 14),
                  label: const Text('New Local Shell'),
                ),
              OutlinedButton.icon(
                key: const ValueKey('picker-connect-relay'),
                onPressed: () => workspace.setOverlay(FtermOverlay.connect),
                icon: const Icon(Icons.link, size: 14),
                label: const Text('Relay Settings'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Remote Relay Sessions (${remoteSessions.length})',
            style: TextStyle(color: p.muted, fontSize: 11),
          ),
          const SizedBox(height: 6),
          if (remoteSessions.isEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: p.surfaceAlt,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(switch (workspace.connectionState) {
                ClientConnectionState.authenticated =>
                  'Connected to ${workspace.activeRelayUri.host} — no remote sessions active.',
                ClientConnectionState.connecting ||
                ClientConnectionState.reconnecting =>
                  'Connecting to ${workspace.activeRelayUri.host}...',
                ClientConnectionState.authFailed =>
                  workspace.authErrorMessage ??
                      'Relay authentication failed — open Relay Settings.',
                ClientConnectionState.unconnected =>
                  'Not connected to a relay — open Relay Settings to connect.',
              }, style: TextStyle(color: p.muted)),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: remoteSessions.length,
                itemBuilder: (_, index) {
                  final session = remoteSessions[index];
                  return _buildSessionTile(session, p);
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSessionTile(SessionSummary session, _OverlayColors p) {
    final subtitle =
        '${session.cols}x${session.rows} • ${session.subscriberCount} viewers';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: p.surfaceAlt,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          key: ValueKey('picker-session-${session.id.value}'),
          dense: true,
          title: Text(
            session.title,
            style: TextStyle(color: p.foreground, fontSize: 12),
          ),
          subtitle: Text(
            subtitle,
            style: TextStyle(color: p.muted, fontSize: 10),
          ),
          onTap: () => workspace.openRemoteSessionTab(session.id),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Split right',
                icon: Icon(Icons.vertical_split, size: 15, color: p.muted),
                onPressed: () => unawaited(
                  workspace.splitFocusedPane(
                    SplitAxis.horizontal,
                    remoteSessionId: session.id,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Split down',
                icon: Icon(Icons.horizontal_split, size: 15, color: p.muted),
                onPressed: () => unawaited(
                  workspace.splitFocusedPane(
                    SplitAxis.vertical,
                    remoteSessionId: session.id,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _SettingsOverlay extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final _OverlayColors palette;

  const _SettingsOverlay({required this.workspace, required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final wsSettings = workspace.workspaceSettings;
    final themeSettings = wsSettings.themeSettings;
    final prefs = workspace.preferences;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _overlayHeader(
              title: 'Settings',
              palette: p,
              onClose: workspace.dismissOverlay,
            ),
            const SizedBox(height: 12),
            Text('Appearance', style: TextStyle(color: p.muted, fontSize: 11)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              children: [
                for (final mode in ThemeAppearanceMode.values)
                  ChoiceChip(
                    key: ValueKey('settings-appearance-${mode.name}'),
                    label: Text(mode.name),
                    selected: themeSettings.appearanceMode == mode,
                    onSelected: (_) => workspace.setThemeSettings(
                      themeSettings.copyWith(appearanceMode: mode),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Theme Preset',
              style: TextStyle(color: p.muted, fontSize: 11),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final preset in tui.TerminalColorTheme.presets)
                  ChoiceChip(
                    key: ValueKey('settings-theme-${preset.id}'),
                    label: Text(preset.id),
                    selected: workspace.activeTerminalTheme.id == preset.id,
                    onSelected: (_) {
                      final next = preset.brightness == .light
                          ? themeSettings.copyWith(lightThemeId: preset.id)
                          : themeSettings.copyWith(darkThemeId: preset.id);
                      workspace.setThemeSettings(next);
                    },
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Tab Bar Position',
              style: TextStyle(color: p.muted, fontSize: 11),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              children: [
                for (final pos in DockPosition.values)
                  ChoiceChip(
                    key: ValueKey('settings-dock-${pos.name}'),
                    label: Text(pos.name),
                    selected: wsSettings.dockPosition == pos,
                    onSelected: (_) => workspace.setDockPosition(pos),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile.adaptive(
              key: const ValueKey('settings-auto-hide-single'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto-hide tab bar on single tab'),
              value: prefs.autoHideSingleTab,
              onChanged: (v) => workspace.updatePreferences(
                prefs.copyWith(autoHideSingleTab: v),
              ),
            ),
            SwitchListTile.adaptive(
              key: const ValueKey('settings-copy-on-select'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Copy on mouse selection'),
              value: wsSettings.copyOnSelect,
              onChanged: workspace.setCopyOnSelect,
            ),
            SwitchListTile.adaptive(
              key: const ValueKey('settings-f12-toggle'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Enable F12 host shortcuts (screenshot/atlas)'),
              value: wsSettings.f12ShortcutsEnabled,
              onChanged: workspace.setF12ShortcutsEnabled,
            ),
            SwitchListTile.adaptive(
              key: const ValueKey('settings-audio-mute'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Mute terminal bell & APC audio'),
              value: prefs.audioMuted,
              onChanged: (v) =>
                  workspace.updatePreferences(prefs.copyWith(audioMuted: v)),
            ),
            Row(
              children: [
                Text('Volume', style: TextStyle(color: p.muted, fontSize: 11)),
                Expanded(
                  child: Slider(
                    value: prefs.audioVolume,
                    onChanged: (v) => workspace.updatePreferences(
                      prefs.copyWith(audioVolume: v),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('settings-open-connect'),
                  onPressed: () => workspace.setOverlay(FtermOverlay.connect),
                  icon: const Icon(Icons.cloud_outlined, size: 14),
                  label: const Text('Relay Connection...'),
                ),
                TextButton(
                  key: const ValueKey('settings-reload-storage'),
                  onPressed: workspace.reloadSettingsFromStorage,
                  child: const Text('Reload from Storage'),
                ),
                FilledButton(
                  onPressed: workspace.dismissOverlay,
                  child: const Text('Done'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

final class _StatsOverlay extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final _OverlayColors palette;

  const _StatsOverlay({required this.workspace, required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final repo = workspace.repository;
    final focused = workspace.focusedPane;
    final rows = <(String, String)>[
      ('Relay', workspace.activeRelayUri.toString()),
      ('Connection', workspace.connectionState.name),
      (
        'Tabs / Panes',
        '${workspace.tabs.length} / ${workspace.activeSplitTree?.paneCount ?? 0}',
      ),
      ('RX / TX bytes', '${repo.totalRxBytes} / ${repo.totalTxBytes}'),
      (
        'Bell / Audio / Titles',
        '${workspace.bellEventsCount} / ${workspace.audioEventsCount} / ${workspace.titleEventsCount}',
      ),
      (
        'Audio Engine',
        workspace.audioController.isInitialized ? 'initialized' : 'standby',
      ),
      if (focused != null) ...[
        ('Focused Kind', focused.isLocal ? 'local shell' : 'remote session'),
        (
          'Active PTY',
          '${focused.activePtySize.$1}x${focused.activePtySize.$2}',
        ),
        ('Shared Viewers', '${focused.shareSnapshot.subscriberCount}'),
      ],
    ];
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _overlayHeader(
            title: 'Session & Telemetry Stats',
            palette: p,
            onClose: workspace.dismissOverlay,
          ),
          const SizedBox(height: 12),
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 150,
                    child: Text(label, style: TextStyle(color: p.muted)),
                  ),
                  Expanded(
                    child: Text(
                      value,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.foreground),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

final class _RenameOverlay extends StatefulWidget {
  final FtermWorkspaceController workspace;
  final _OverlayColors palette;

  const _RenameOverlay({required this.workspace, required this.palette});

  @override
  State<_RenameOverlay> createState() => _RenameOverlayState();
}

final class _RenameOverlayState extends State<_RenameOverlay> {
  late final TextEditingController _ctrl;
  bool _clearPin = false;

  @override
  void initState() {
    super.initState();
    final tab = widget.workspace.activeTab;
    _ctrl = TextEditingController(text: tab?.pinnedTitle ?? '');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _apply() {
    widget.workspace.renameTab(title: _ctrl.text, clearPin: _clearPin);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _overlayHeader(
            title: 'Rename Tab',
            palette: p,
            onClose: widget.workspace.dismissOverlay,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('rename-title-field'),
            controller: _ctrl,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Custom pinned tab title',
              labelStyle: TextStyle(color: p.muted, fontSize: 11),
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _apply(),
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            key: const ValueKey('rename-clear-pin'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Clear pin (follow live shell title)'),
            value: _clearPin,
            onChanged: (v) => setState(() => _clearPin = v ?? false),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: widget.workspace.dismissOverlay,
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('rename-submit'),
                onPressed: _apply,
                child: const Text('Apply'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

final class _HelpOverlay extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final _OverlayColors palette;

  const _HelpOverlay({required this.workspace, required this.palette});

  static const List<(String, String)> _entries = [
    (r'Ctrl+\ then | or %', 'Split pane left | right'),
    (r'Ctrl+\ then - or "', 'Split pane top / bottom'),
    (r'Ctrl+\ then h j k l / Arrows', 'Focus adjacent split pane'),
    (r'Ctrl+\ then z', 'Toggle pane zoom'),
    (r'Ctrl+\ then b', 'Toggle local pane relay share'),
    (r'Ctrl+\ then c', 'Sessions & Shells picker'),
    (r'Ctrl+\ then n / p / 1..9', 'Next / Prev / Nth tab'),
    (r'Ctrl+\ then r', 'Rename tab or clear title pin'),
    (r'Ctrl+\ then x', 'Close focused pane / tab'),
    (r'Ctrl+\ then d / Space', 'Cycle tab bar (top -> left -> hidden)'),
    (r'Ctrl+\ then , / i / ?', 'Settings / Stats / Help'),
    ('Cmd+T/W/D/Shift+D/1..9', 'Native macOS Desktop shortcuts'),
    ('Ctrl+Shift+T/W/D/E', 'Native Linux / Windows shortcuts'),
  ];

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _overlayHeader(
            title: 'fterm Keyboard Shortcuts',
            palette: p,
            onClose: workspace.dismissOverlay,
          ),
          const SizedBox(height: 10),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _entries.length,
              itemBuilder: (_, idx) {
                final (chord, desc) = _entries[idx];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 210,
                        child: Text(chord, style: TextStyle(color: p.accent)),
                      ),
                      Expanded(child: Text(desc)),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

final class _FileUploadOverlay extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final _OverlayColors palette;

  const _FileUploadOverlay({required this.workspace, required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final files = workspace.pendingUploadFiles;
    final progress = workspace.uploadCoordinator.progress;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _overlayHeader(
            title: 'Upload Dropped Files (${files.length})',
            palette: p,
            onClose: workspace.dismissOverlay,
          ),
          const SizedBox(height: 10),
          for (final file in files.take(6))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text('${file.name} (${file.size} bytes)'),
            ),
          if (progress != null) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(value: progress.fraction),
          ],
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: workspace.dismissOverlay,
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('upload-submit'),
                onPressed: progress != null
                    ? null
                    : () => unawaited(workspace.confirmFileUpload()),
                child: Text(progress != null ? 'Uploading...' : 'Upload'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
