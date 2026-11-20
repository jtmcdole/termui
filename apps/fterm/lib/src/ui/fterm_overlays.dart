import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_flutter/termui_flutter.dart'
    show
        ShaderAnimationMode,
        ShaderBackendKind,
        ShaderCompileException,
        ShaderPassSpec,
        ShaderStageHint,
        ShadertoyGlslShim,
        TerminalShaderPreset,
        TerminalShaderStage;

import '../file_drop_bridge.dart';
import '../font_loader.dart';
import '../launch_config.dart';
import '../settings_storage.dart';
import '../update/update_service.dart';
import '../update/update_view_model.dart';
import '../workspace/fterm_workspace_controller.dart';
import '../workspace/split_tree_model.dart';
import 'fterm_about_overlay.dart';
import 'fterm_feedback_overlay.dart';

/// Modal overlays rendered over the terminal workspace when [FtermOverlay] !=
/// [FtermOverlay.none].
final class FtermOverlayHost extends StatelessWidget {
  /// Backing workspace coordinator.
  final FtermWorkspaceController workspace;

  /// External URL launcher invoked for release links.
  final UrlOpener onOpenUrl;

  /// Whether this host renders in Web mode (hides native desktop update UI).
  final bool isWeb;

  /// Optional callback capturing the active terminal pane as a [ui.Image]
  /// (ownership transfers to the caller for annotation and disposal).
  final Future<ui.Image?> Function()? onCaptureScreenshot;

  /// Creates the active modal overlay layer, or `SizedBox.shrink()` when idle.
  const FtermOverlayHost({
    super.key,
    required this.workspace,
    this.onOpenUrl = openExternalUrl,
    this.isWeb = false,
    this.onCaptureScreenshot,
  });

  @override
  Widget build(BuildContext context) {
    final overlay = workspace.activeOverlay;
    if (overlay == FtermOverlay.none) {
      return const SizedBox.shrink();
    }
    final theme = workspace.activeTerminalTheme;
    final palette = FtermOverlayPalette.fromTerminalTheme(theme);
    final (maxWidth, maxHeight) = switch (overlay) {
      FtermOverlay.licenses => (680.0, 560.0),
      FtermOverlay.about => (540.0, 560.0),
      FtermOverlay.feedback => (560.0, 620.0),
      _ => (520.0, 540.0),
    };

    return _ModalFocusGuard(
      overlay: overlay,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: GestureDetector(
              key: const ValueKey('fterm-overlay-scrim'),
              behavior: HitTestBehavior.opaque,
              onTap: overlay == FtermOverlay.about
                  ? workspace.dismissOverlay
                  : null,
              child: const ColoredBox(color: Color(0x99000000)),
            ),
          ),
          Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: maxWidth,
                maxHeight: maxHeight,
              ),
              child: Material(
                key: ValueKey('fterm-overlay-${overlay.name}'),
                color: palette.surface,
                elevation: 16,
                clipBehavior: Clip.antiAlias,
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
                      onOpenUrl: onOpenUrl,
                      isWeb: isWeb,
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
                    FtermOverlay.about => FtermAboutOverlay(
                      workspace: workspace,
                      palette: palette,
                      onOpenUrl: onOpenUrl,
                    ),
                    FtermOverlay.licenses => FtermLicensesOverlay(
                      workspace: workspace,
                      palette: palette,
                    ),
                    FtermOverlay.feedback => FtermFeedbackOverlay(
                      workspace: workspace,
                      palette: palette,
                      onOpenUrl: onOpenUrl,
                      isWeb: isWeb,
                      onCaptureScreenshot: onCaptureScreenshot,
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
        ],
      ),
    );
  }
}

final class _ModalFocusGuard extends StatefulWidget {
  final FtermOverlay overlay;
  final Widget child;

  const _ModalFocusGuard({required this.overlay, required this.child});

  @override
  State<_ModalFocusGuard> createState() => _ModalFocusGuardState();
}

final class _ModalFocusGuardState extends State<_ModalFocusGuard> {
  final FocusScopeNode _scopeNode = FocusScopeNode(
    debugLabel: 'fterm-modal-scope',
  );

  @override
  void initState() {
    super.initState();
    _scheduleFocusRequest();
  }

  @override
  void didUpdateWidget(_ModalFocusGuard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.overlay != widget.overlay) {
      _scheduleFocusRequest();
    }
  }

  void _scheduleFocusRequest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _scopeNode.hasFocus) return;
      _scopeNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _scopeNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FocusScope(node: _scopeNode, autofocus: true, child: widget.child);
}

/// Overlay surface colors derived from the active [tui.TerminalColorTheme].
final class FtermOverlayPalette {
  /// Primary modal surface background color.
  final Color surface;

  /// Elevated secondary panel background color.
  final Color surfaceAlt;

  /// Primary text and icon color.
  final Color foreground;

  /// Secondary muted caption and label color.
  final Color muted;

  /// Accent color for links, selections, and active badges.
  final Color accent;

  /// Subtle 1px modal and card outline color.
  final Color border;

  /// Destructive/error foreground color.
  final Color danger;

  /// Warning/caution foreground and border color.
  final Color warning;

  /// Creates an immutable [FtermOverlayPalette].
  const FtermOverlayPalette({
    required this.surface,
    required this.surfaceAlt,
    required this.foreground,
    required this.muted,
    required this.accent,
    required this.border,
    required this.danger,
    this.warning = const Color(0xFFE0AF68),
  });

  /// Derives overlay colors from [theme].
  factory FtermOverlayPalette.fromTerminalTheme(tui.TerminalColorTheme theme) {
    final bg = Color(theme.background.argb);
    final fg = Color(theme.foreground.argb);
    final accent = Color(theme.resolveAnsi256(4).argb);
    final isDark = theme.brightness == tui.TerminalBrightness.dark;
    return FtermOverlayPalette(
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
      warning: Color(theme.resolveAnsi256(3).argb),
    );
  }
}

/// Builds the standard title + close button row shared by modal overlays.
Widget buildFtermOverlayHeader({
  required String title,
  required FtermOverlayPalette palette,
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
  final FtermOverlayPalette palette;

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
            buildFtermOverlayHeader(
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

  static InputDecoration _inputDeco(String label, FtermOverlayPalette p) =>
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
  final FtermOverlayPalette palette;

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
          buildFtermOverlayHeader(
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

  Widget _buildSessionTile(SessionSummary session, FtermOverlayPalette p) {
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

final class _SettingsOverlay extends StatefulWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final UrlOpener onOpenUrl;
  final bool isWeb;

  const _SettingsOverlay({
    required this.workspace,
    required this.palette,
    required this.onOpenUrl,
    required this.isWeb,
  });

  @override
  State<_SettingsOverlay> createState() => _SettingsOverlayState();
}

final class _SettingsOverlayState extends State<_SettingsOverlay> {
  late final TextEditingController _shellExecCtrl;
  late final TextEditingController _shellArgsCtrl;

  @override
  void initState() {
    super.initState();
    final prefs = widget.workspace.preferences;
    _shellExecCtrl = TextEditingController(text: prefs.shellExecutable ?? '');
    _shellArgsCtrl = TextEditingController(
      text: FtermWorkspaceController.formatShellArguments(prefs.shellArguments),
    );
    widget.workspace.chromeNotifier.addListener(_onWorkspaceChromeChanged);
  }

  @override
  void didUpdateWidget(_SettingsOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.workspace, widget.workspace)) {
      oldWidget.workspace.chromeNotifier.removeListener(
        _onWorkspaceChromeChanged,
      );
      widget.workspace.chromeNotifier.addListener(_onWorkspaceChromeChanged);
    }
    _syncControllersFromPreferences();
  }

  void _onWorkspaceChromeChanged() {
    if (!mounted) return;
    _syncControllersFromPreferences();
    setState(() {});
  }

  void _syncControllersFromPreferences() {
    final prefs = widget.workspace.preferences;
    final expectedExec = prefs.shellExecutable ?? '';
    if (_shellExecCtrl.text.trim() != expectedExec) {
      _shellExecCtrl.text = expectedExec;
    }
    final parsedArgs = FtermWorkspaceController.parseShellArguments(
      _shellArgsCtrl.text,
    );
    if (!listEquals(parsedArgs, prefs.shellArguments)) {
      _shellArgsCtrl.text = FtermWorkspaceController.formatShellArguments(
        prefs.shellArguments,
      );
    }
  }

  @override
  void dispose() {
    widget.workspace.chromeNotifier.removeListener(_onWorkspaceChromeChanged);
    _shellExecCtrl.dispose();
    _shellArgsCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final workspace = widget.workspace;
    final p = widget.palette;
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
            buildFtermOverlayHeader(
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
            _FontSizeControls(workspace: workspace, palette: p),
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
              key: const ValueKey('settings-osc52-toggle'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Allow focused remote OSC 52 clipboard writes'),
              value:
                  wsSettings.osc52Policy == Osc52ClipboardPolicy.allowFocused,
              onChanged: (enabled) => workspace.setOsc52Policy(
                enabled
                    ? Osc52ClipboardPolicy.allowFocused
                    : Osc52ClipboardPolicy.deny,
              ),
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
            const SizedBox(height: 10),
            _ShadersAndBackgroundSection(
              workspace: workspace,
              palette: p,
              isWeb: widget.isWeb,
            ),
            if (workspace.isDesktopHost) ...[
              const SizedBox(height: 8),
              _DesktopShellOverrideSection(
                workspace: workspace,
                palette: p,
                shellExecCtrl: _shellExecCtrl,
                shellArgsCtrl: _shellArgsCtrl,
              ),
            ],
            if (!widget.isWeb &&
                workspace.updateViewModel.isSupportedDesktop) ...[
              const SizedBox(height: 8),
              _DesktopUpdatesSection(
                workspace: workspace,
                palette: p,
                onOpenUrl: widget.onOpenUrl,
              ),
            ],
            const SizedBox(height: 6),
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('settings-open-about'),
                  onPressed: () => workspace.setOverlay(FtermOverlay.about),
                  icon: const Icon(Icons.info_outline, size: 14),
                  label: const Text('About'),
                ),
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

final class _ShadersAndBackgroundSection extends StatefulWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final bool isWeb;

  const _ShadersAndBackgroundSection({
    required this.workspace,
    required this.palette,
    required this.isWeb,
  });

  @override
  State<_ShadersAndBackgroundSection> createState() =>
      _ShadersAndBackgroundSectionState();
}

final class _ShadersAndBackgroundSectionState
    extends State<_ShadersAndBackgroundSection> {
  static const List<TerminalShaderPreset> _bgPresets = <TerminalShaderPreset>[
    TerminalShaderPreset.wallpaperWave,
  ];
  static const List<TerminalShaderPreset> _fgPresets = <TerminalShaderPreset>[
    TerminalShaderPreset.cursorGlow,
    TerminalShaderPreset.scanlineOverlay,
    TerminalShaderPreset.crtLottes,
    TerminalShaderPreset.phosphorGlow,
  ];

  late final TextEditingController _wallpaperCtrl;
  late final TextEditingController _customPathCtrl;
  late final TextEditingController _webNameCtrl;
  late final TextEditingController _webSourceCtrl;
  bool _editingWallpaper = false;
  bool _showCustomPathForm = false;
  bool _showWebGlslForm = false;
  TerminalShaderStage _webUploadStage = TerminalShaderStage.foreground;
  bool _webUploadStageLocked = false;
  ShaderStageHint? _webDetectedStageHint;

  @override
  void initState() {
    super.initState();
    _wallpaperCtrl = TextEditingController(
      text: widget.workspace.backgroundImagePath ?? '',
    );
    _customPathCtrl = TextEditingController();
    _webNameCtrl = TextEditingController(text: 'custom.glsl');
    _webSourceCtrl = TextEditingController();
  }

  @override
  void didUpdateWidget(_ShadersAndBackgroundSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final expected = widget.workspace.backgroundImagePath ?? '';
    if (_wallpaperCtrl.text.trim() != expected) {
      _wallpaperCtrl.text = expected;
    }
  }

  @override
  void dispose() {
    _wallpaperCtrl.dispose();
    _customPathCtrl.dispose();
    _webNameCtrl.dispose();
    _webSourceCtrl.dispose();
    super.dispose();
  }

  void _addCustomShaderPath(TerminalShaderStage stage) {
    final trimmed = _customPathCtrl.text.trim();
    if (trimmed.isEmpty) return;
    _customPathCtrl.clear();
    if (stage == TerminalShaderStage.background) {
      final next = <String>[
        ...widget.workspace.backgroundShaderChain,
        if (!widget.workspace.backgroundShaderChain.contains(trimmed)) trimmed,
      ];
      unawaited(widget.workspace.setBackgroundShaderChain(next));
      return;
    }
    final next = <String>[
      ...widget.workspace.foregroundShaderChain,
      if (!widget.workspace.foregroundShaderChain.contains(trimmed)) trimmed,
    ];
    unawaited(widget.workspace.setForegroundShaderChain(next));
  }

  void _onWebGlslSourceChanged(String source) {
    ShaderStageHint? detected;
    try {
      detected = ShadertoyGlslShim.analyze(source).stageHint;
    } on Object {
      detected = null;
    }
    setState(() {
      _webDetectedStageHint = detected;
      if (!_webUploadStageLocked && detected != null) {
        _webUploadStage = detected == ShaderStageHint.background
            ? TerminalShaderStage.background
            : TerminalShaderStage.foreground;
      }
    });
  }

  void _selectWebUploadStage(TerminalShaderStage stage) {
    setState(() {
      _webUploadStage = stage;
      _webUploadStageLocked = true;
    });
  }

  void _submitWebGlsl() {
    final name = _webNameCtrl.text.trim();
    final source = _webSourceCtrl.text;
    if (name.isEmpty || source.trim().isEmpty) return;
    unawaited(
      widget.workspace.uploadCustomShader(name, source, stage: _webUploadStage),
    );
    setState(() {
      _showWebGlslForm = false;
      _webUploadStageLocked = false;
      _webDetectedStageHint = null;
    });
  }

  ShaderPassSpec? _primaryActivePass() {
    final cfg = widget.workspace.activeShaderConfig;
    if (cfg.foregroundPasses.isNotEmpty) return cfg.foregroundPasses.first;
    if (cfg.backgroundPasses.isNotEmpty) return cfg.backgroundPasses.first;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final ws = widget.workspace;
    final palette = widget.palette;
    final primaryPass = _primaryActivePass();
    return Column(
      key: const ValueKey('settings-shaders-section'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ShaderBackendHeader(workspace: ws, palette: palette),
        if (ws.lastShaderCompileError != null ||
            ws.lastShaderAssetError != null) ...[
          const SizedBox(height: 6),
          _ShaderCompileErrorBanner(
            compileError: ws.lastShaderCompileError,
            assetError: ws.lastShaderAssetError,
            palette: palette,
          ),
        ],
        const SizedBox(height: 8),
        _BackgroundOpacityControl(workspace: ws, palette: palette),
        const SizedBox(height: 6),
        _WallpaperControls(
          workspace: ws,
          palette: palette,
          controller: _wallpaperCtrl,
          isWeb: widget.isWeb,
          isEditing: _editingWallpaper,
          onToggleEdit: () =>
              setState(() => _editingWallpaper = !_editingWallpaper),
          onApply: () {
            unawaited(ws.setBackgroundImagePath(_wallpaperCtrl.text));
            setState(() => _editingWallpaper = false);
          },
        ),
        const SizedBox(height: 8),
        _ShaderRoleLegend(palette: palette),
        const SizedBox(height: 6),
        _ShaderChainSelector(
          title: 'Background Shaders',
          keyPrefix: 'settings-bg-shader',
          stage: TerminalShaderStage.background,
          presets: _bgPresets,
          activeChain: ws.backgroundShaderChain,
          availableCustomShaders: ws.availableCustomShaders,
          samplesChannel0For: (entry) =>
              ws.shaderSamplesChannel0(entry, TerminalShaderStage.background),
          stageHintFor: (entry) =>
              ws.shaderStageHint(entry, TerminalShaderStage.background),
          warningMessage: ws.shaderChainWarningFor(
            TerminalShaderStage.background,
          ),
          palette: palette,
          onToggle: (entry) => unawaited(ws.toggleBackgroundShader(entry)),
          onMove: (from, to) => unawaited(ws.moveBackgroundShader(from, to)),
        ),
        const SizedBox(height: 8),
        _ShaderChainSelector(
          title: 'Foreground Shaders',
          keyPrefix: 'settings-fg-shader',
          stage: TerminalShaderStage.foreground,
          presets: _fgPresets,
          activeChain: ws.foregroundShaderChain,
          availableCustomShaders: ws.availableCustomShaders,
          samplesChannel0For: (entry) =>
              ws.shaderSamplesChannel0(entry, TerminalShaderStage.foreground),
          stageHintFor: (entry) =>
              ws.shaderStageHint(entry, TerminalShaderStage.foreground),
          warningMessage: ws.shaderChainWarningFor(
            TerminalShaderStage.foreground,
          ),
          palette: palette,
          onToggle: (entry) => unawaited(ws.toggleForegroundShader(entry)),
          onMove: (from, to) => unawaited(ws.moveForegroundShader(from, to)),
        ),
        const SizedBox(height: 8),
        _CustomShaderAddRow(
          controller: _customPathCtrl,
          palette: palette,
          isExpanded: _showCustomPathForm,
          onToggleExpanded: () =>
              setState(() => _showCustomPathForm = !_showCustomPathForm),
          onAddBackground: () =>
              _addCustomShaderPath(TerminalShaderStage.background),
          onAddForeground: () =>
              _addCustomShaderPath(TerminalShaderStage.foreground),
        ),
        if (primaryPass != null) ...[
          const SizedBox(height: 8),
          _ShaderParamSliders(
            workspace: ws,
            pass: primaryPass,
            palette: palette,
          ),
        ],
        const SizedBox(height: 8),
        _ShaderAnimationModeSelector(workspace: ws, palette: palette),
        const SizedBox(height: 8),
        _PerfHudToggleRow(workspace: ws, palette: palette),
        const SizedBox(height: 8),
        _ShaderActionsRow(
          workspace: ws,
          isWeb: widget.isWeb,
          onToggleWebUpload: () =>
              setState(() => _showWebGlslForm = !_showWebGlslForm),
        ),
        if (widget.isWeb && _showWebGlslForm) ...[
          const SizedBox(height: 8),
          _WebGlslUploadForm(
            nameController: _webNameCtrl,
            sourceController: _webSourceCtrl,
            stage: _webUploadStage,
            detectedStageHint: _webDetectedStageHint,
            palette: palette,
            onSourceChanged: _onWebGlslSourceChanged,
            onStageSelected: _selectWebUploadStage,
            onSubmit: _submitWebGlsl,
          ),
        ],
      ],
    );
  }
}

final class _ShaderBackendHeader extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;

  const _ShaderBackendHeader({required this.workspace, required this.palette});

  @override
  Widget build(BuildContext context) {
    final activeKind = workspace.shaderController.backendKind;
    final override = workspace.shaderBackendOverride;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              'Shaders & Background',
              style: TextStyle(color: palette.muted, fontSize: 11),
            ),
            const SizedBox(width: 8),
            Container(
              key: const ValueKey('settings-shader-backend-badge'),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: palette.surfaceAlt,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: activeKind == ShaderBackendKind.disabled
                      ? palette.border
                      : palette.accent,
                ),
              ),
              child: Text(
                activeKind.name,
                style: TextStyle(
                  color: activeKind == ShaderBackendKind.disabled
                      ? palette.muted
                      : palette.accent,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Spacer(),
            Wrap(
              spacing: 6,
              children: [
                ChoiceChip(
                  key: const ValueKey('settings-shader-backend-auto'),
                  label: const Text('Auto'),
                  selected: override == null,
                  onSelected: (_) =>
                      unawaited(workspace.setShaderBackendOverride(null)),
                ),
                ChoiceChip(
                  key: const ValueKey('settings-shader-backend-disabled'),
                  label: const Text('Disabled'),
                  selected: override == ShaderBackendKind.disabled,
                  onSelected: (_) => unawaited(
                    workspace.setShaderBackendOverride(
                      ShaderBackendKind.disabled,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

final class _ShaderCompileErrorBanner extends StatelessWidget {
  final ShaderCompileException? compileError;
  final String? assetError;
  final FtermOverlayPalette palette;

  const _ShaderCompileErrorBanner({
    required this.compileError,
    required this.assetError,
    required this.palette,
  });

  String _formatMessage() {
    final err = compileError;
    if (err != null) {
      final loc = err.lineNumber == null ? '' : ' (line ${err.lineNumber})';
      return '${err.shaderId}$loc: ${err.message}';
    }
    return assetError ?? '';
  }

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('settings-shader-compile-error'),
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: palette.danger.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: palette.danger),
    ),
    child: Text(
      _formatMessage(),
      style: TextStyle(color: palette.danger, fontSize: 11),
    ),
  );
}

final class _BackgroundOpacityControl extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;

  const _BackgroundOpacityControl({
    required this.workspace,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    final opacity = workspace.backgroundOpacity;
    return Row(
      children: [
        Text(
          'Background Opacity',
          style: TextStyle(color: palette.muted, fontSize: 11),
        ),
        Expanded(
          child: Slider(
            key: const ValueKey('settings-background-opacity-slider'),
            value: opacity,
            min: 0.0,
            max: 1.0,
            onChanged: workspace.setBackgroundOpacity,
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            '${(opacity * 100).round()}%',
            key: const ValueKey('settings-background-opacity-value'),
            textAlign: TextAlign.right,
            style: TextStyle(color: palette.foreground, fontSize: 11),
          ),
        ),
      ],
    );
  }
}

final class _WallpaperControls extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final TextEditingController controller;
  final bool isWeb;
  final bool isEditing;
  final VoidCallback onToggleEdit;
  final VoidCallback onApply;

  const _WallpaperControls({
    required this.workspace,
    required this.palette,
    required this.controller,
    required this.isWeb,
    required this.isEditing,
    required this.onToggleEdit,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    final currentPath = workspace.backgroundImagePath;
    final hasWallpaper = currentPath != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                hasWallpaper ? 'Wallpaper: $currentPath' : 'Wallpaper: None',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: palette.muted, fontSize: 11),
              ),
            ),
            const SizedBox(width: 6),
            OutlinedButton(
              key: const ValueKey('settings-wallpaper-edit'),
              onPressed: onToggleEdit,
              child: Text(isEditing ? 'Cancel' : 'Set Wallpaper'),
            ),
            const SizedBox(width: 4),
            TextButton(
              key: const ValueKey('settings-wallpaper-clear'),
              onPressed: hasWallpaper
                  ? () {
                      controller.clear();
                      unawaited(workspace.setBackgroundImagePath(null));
                    }
                  : null,
              child: const Text('Clear'),
            ),
          ],
        ),
        if (isEditing) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('settings-wallpaper-path-field'),
                  controller: controller,
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: isWeb
                        ? 'Wallpaper storage key'
                        : 'Wallpaper path',
                    hintText: isWeb
                        ? 'e.g. wallpaper.png'
                        : 'Path to PNG, JPEG, or WebP image',
                    labelStyle: TextStyle(color: palette.muted, fontSize: 11),
                  ),
                  onSubmitted: (_) => onApply(),
                ),
              ),
              const SizedBox(width: 6),
              OutlinedButton(
                key: const ValueKey('settings-wallpaper-apply'),
                onPressed: onApply,
                child: const Text('Apply'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

final class _ShaderRoleLegend extends StatelessWidget {
  final FtermOverlayPalette palette;

  const _ShaderRoleLegend({required this.palette});

  @override
  Widget build(BuildContext context) => Wrap(
    key: const ValueKey('settings-shader-role-legend'),
    spacing: 12,
    runSpacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bolt, size: 12, color: palette.warning),
          const SizedBox(width: 3),
          Text(
            'base (starts chain)',
            style: TextStyle(color: palette.muted, fontSize: 10),
          ),
        ],
      ),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.input, size: 12, color: palette.accent),
          const SizedBox(width: 3),
          Text(
            'chains (reads iChannel0)',
            style: TextStyle(color: palette.muted, fontSize: 10),
          ),
        ],
      ),
    ],
  );
}

final class _ShaderRoleBadge extends StatelessWidget {
  final bool samplesChannel0;
  final FtermOverlayPalette palette;

  const _ShaderRoleBadge({
    super.key,
    required this.samplesChannel0,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    final color = samplesChannel0 ? palette.accent : palette.warning;
    final icon = samplesChannel0 ? Icons.input : Icons.bolt;
    final text = samplesChannel0 ? 'chains' : 'base';
    final tooltip = samplesChannel0
        ? 'Chains from previous pass (reads iChannel0)'
        : 'Base shader (starts chain — ignores iChannel0)';
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 10, color: color),
            const SizedBox(width: 3),
            Text(
              text,
              style: TextStyle(
                color: color,
                fontSize: 9,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _ShaderChainSelector extends StatelessWidget {
  final String title;
  final String keyPrefix;
  final TerminalShaderStage stage;
  final List<TerminalShaderPreset> presets;
  final List<String> activeChain;
  final List<String> availableCustomShaders;
  final bool? Function(String entry) samplesChannel0For;
  final ShaderStageHint? Function(String entry) stageHintFor;
  final String? warningMessage;
  final FtermOverlayPalette palette;
  final void Function(String entry) onToggle;
  final void Function(int fromIndex, int toIndex) onMove;

  const _ShaderChainSelector({
    required this.title,
    required this.keyPrefix,
    required this.stage,
    required this.presets,
    required this.activeChain,
    required this.availableCustomShaders,
    required this.samplesChannel0For,
    required this.stageHintFor,
    required this.warningMessage,
    required this.palette,
    required this.onToggle,
    required this.onMove,
  });

  bool _isRecommendedForStage(ShaderStageHint? hint) => switch (hint) {
    null || ShaderStageHint.any => true,
    ShaderStageHint.background => stage == TerminalShaderStage.background,
    ShaderStageHint.foreground => stage == TerminalShaderStage.foreground,
  };

  List<(String id, String label, bool isCustom)> _collectOptions() {
    final seen = <String>{};
    final options = <(String, String, bool)>[];
    for (final preset in presets) {
      seen.add(preset.wireName);
      options.add((preset.wireName, preset.wireName, false));
    }
    final customMatching = <(String, String, bool)>[];
    final customOther = <(String, String, bool)>[];
    void addCustom(String id) {
      if (!seen.add(id)) return;
      final item = (id, p.basename(id), true);
      if (_isRecommendedForStage(stageHintFor(id))) {
        customMatching.add(item);
      } else {
        customOther.add(item);
      }
    }

    for (final path in availableCustomShaders) {
      addCustom(path);
    }
    for (final active in activeChain) {
      addCustom(active);
    }
    options
      ..addAll(customMatching)
      ..addAll(customOther);
    return options;
  }

  Widget _buildChipLabel(String id, String label, bool isCustom) {
    final samples = samplesChannel0For(id);
    final stageHint = isCustom ? stageHintFor(id) : null;
    if (samples == null && stageHint == null) {
      return Text(label);
    }
    final isStageMatch = _isRecommendedForStage(stageHint);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (samples != null) ...[
          Icon(
            samples ? Icons.input : Icons.bolt,
            size: 12,
            color: samples ? palette.accent : palette.warning,
          ),
          const SizedBox(width: 4),
        ],
        Text(label),
        if (stageHint != null) ...[
          const SizedBox(width: 5),
          Container(
            key: ValueKey('$keyPrefix-stage-hint-$id'),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
            decoration: BoxDecoration(
              color: (isStageMatch ? palette.accent : palette.muted).withValues(
                alpha: 0.14,
              ),
              borderRadius: BorderRadius.circular(3),
              border: Border.all(
                color: (isStageMatch ? palette.accent : palette.muted)
                    .withValues(alpha: 0.45),
              ),
            ),
            child: Text(
              stageHint.shortLabel,
              style: TextStyle(
                color: isStageMatch ? palette.accent : palette.muted,
                fontSize: 9,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );
  }

  String _chipTooltip(String id) {
    final samples = samplesChannel0For(id);
    final hint = stageHintFor(id);
    final stageText = switch (hint) {
      ShaderStageHint.background => 'Designed for Background',
      ShaderStageHint.foreground => 'Designed for Foreground',
      ShaderStageHint.any => 'Works in Background or Foreground',
      null => null,
    };
    final roleText = switch (samples) {
      true => 'chains from previous pass (reads iChannel0)',
      false => 'base shader (starts chain, ignores iChannel0)',
      null => null,
    };
    final details = <String>[?stageText, ?roleText];
    return details.isEmpty ? id : '$id — ${details.join(' • ')}';
  }

  @override
  Widget build(BuildContext context) {
    final options = _collectOptions();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(title, style: TextStyle(color: palette.muted, fontSize: 11)),
            if (activeChain.length > 1) ...[
              const Spacer(),
              Text(
                '${activeChain.length} active • runs top → bottom',
                style: TextStyle(color: palette.muted, fontSize: 10),
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (id, label, isCustom) in options)
              Tooltip(
                message: _chipTooltip(id),
                child: FilterChip(
                  key: ValueKey('$keyPrefix-$id'),
                  label: _buildChipLabel(id, label, isCustom),
                  selected: activeChain.contains(id),
                  onSelected: (_) => onToggle(id),
                ),
              ),
          ],
        ),
        if (warningMessage case final message?) ...[
          const SizedBox(height: 6),
          Container(
            key: ValueKey('$keyPrefix-warning'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: palette.warning.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: palette.warning),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    Icons.warning_amber_rounded,
                    size: 14,
                    color: palette.warning,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    message,
                    style: TextStyle(color: palette.warning, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (activeChain.length > 1) ...[
          const SizedBox(height: 6),
          _ShaderChainOrderList(
            keyPrefix: keyPrefix,
            activeChain: activeChain,
            samplesChannel0For: samplesChannel0For,
            palette: palette,
            onMove: onMove,
            onRemove: onToggle,
          ),
        ],
      ],
    );
  }
}

final class _ShaderChainOrderList extends StatelessWidget {
  final String keyPrefix;
  final List<String> activeChain;
  final bool? Function(String entry) samplesChannel0For;
  final FtermOverlayPalette palette;
  final void Function(int fromIndex, int toIndex) onMove;
  final void Function(String entry) onRemove;

  const _ShaderChainOrderList({
    required this.keyPrefix,
    required this.activeChain,
    required this.samplesChannel0For,
    required this.palette,
    required this.onMove,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) => Container(
    key: ValueKey('$keyPrefix-order-list'),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: palette.surfaceAlt,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: palette.border),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < activeChain.length; i++)
          _ShaderChainOrderRow(
            keyPrefix: keyPrefix,
            index: i,
            totalCount: activeChain.length,
            entry: activeChain[i],
            samplesChannel0: samplesChannel0For(activeChain[i]),
            palette: palette,
            onMove: onMove,
            onRemove: onRemove,
          ),
      ],
    ),
  );
}

final class _ShaderChainOrderRow extends StatelessWidget {
  final String keyPrefix;
  final int index;
  final int totalCount;
  final String entry;
  final bool? samplesChannel0;
  final FtermOverlayPalette palette;
  final void Function(int fromIndex, int toIndex) onMove;
  final void Function(String entry) onRemove;

  const _ShaderChainOrderRow({
    required this.keyPrefix,
    required this.index,
    required this.totalCount,
    required this.entry,
    required this.samplesChannel0,
    required this.palette,
    required this.onMove,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final isFirst = index == 0;
    final isLast = index == totalCount - 1;
    final label = p.basename(entry);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            child: Text(
              '${index + 1}.',
              style: TextStyle(
                color: isLast ? palette.accent : palette.muted,
                fontSize: 11,
                fontWeight: isLast ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.foreground, fontSize: 11),
            ),
          ),
          if (samplesChannel0 case final samples?) ...[
            const SizedBox(width: 6),
            _ShaderRoleBadge(
              key: ValueKey('$keyPrefix-role-$index'),
              samplesChannel0: samples,
              palette: palette,
            ),
          ],
          if (isLast) ...[
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: palette.accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: palette.accent.withValues(alpha: 0.5),
                ),
              ),
              child: Text(
                'final',
                style: TextStyle(
                  color: palette.accent,
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          const SizedBox(width: 4),
          IconButton(
            key: ValueKey('$keyPrefix-move-up-$index'),
            onPressed: isFirst ? null : () => onMove(index, index - 1),
            icon: const Icon(Icons.arrow_upward, size: 14),
            tooltip: 'Move earlier (lower priority)',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
          ),
          IconButton(
            key: ValueKey('$keyPrefix-move-down-$index'),
            onPressed: isLast ? null : () => onMove(index, index + 1),
            icon: const Icon(Icons.arrow_downward, size: 14),
            tooltip: 'Move later (higher priority)',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
          ),
          IconButton(
            key: ValueKey('$keyPrefix-remove-$index'),
            onPressed: () => onRemove(entry),
            icon: const Icon(Icons.close, size: 14),
            tooltip: 'Disable shader',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
          ),
        ],
      ),
    );
  }
}

final class _CustomShaderAddRow extends StatelessWidget {
  final TextEditingController controller;
  final FtermOverlayPalette palette;
  final bool isExpanded;
  final VoidCallback onToggleExpanded;
  final VoidCallback onAddBackground;
  final VoidCallback onAddForeground;

  const _CustomShaderAddRow({
    required this.controller,
    required this.palette,
    required this.isExpanded,
    required this.onToggleExpanded,
    required this.onAddBackground,
    required this.onAddForeground,
  });

  @override
  Widget build(BuildContext context) {
    if (!isExpanded) {
      return Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          key: const ValueKey('settings-custom-shader-toggle'),
          onPressed: onToggleExpanded,
          icon: const Icon(Icons.add, size: 14),
          label: const Text('Add Custom .glsl Path...'),
        ),
      );
    }
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: const ValueKey('settings-custom-shader-path-field'),
            controller: controller,
            decoration: InputDecoration(
              isDense: true,
              labelText: 'Custom .glsl file',
              hintText: 'my_effect.glsl or /path/to/shader.glsl',
              labelStyle: TextStyle(color: palette.muted, fontSize: 11),
            ),
            onSubmitted: (_) => onAddForeground(),
          ),
        ),
        const SizedBox(width: 6),
        OutlinedButton(
          key: const ValueKey('settings-custom-shader-add-bg'),
          onPressed: onAddBackground,
          child: const Text('Add BG'),
        ),
        const SizedBox(width: 4),
        OutlinedButton(
          key: const ValueKey('settings-custom-shader-add-fg'),
          onPressed: onAddForeground,
          child: const Text('Add FG'),
        ),
      ],
    );
  }
}

final class _ShaderParamSliders extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final ShaderPassSpec pass;
  final FtermOverlayPalette palette;

  const _ShaderParamSliders({
    required this.workspace,
    required this.pass,
    required this.palette,
  });

  static const List<String> _labels = <String>[
    'uParams0.x',
    'uParams0.y',
    'uParams0.z',
  ];

  @override
  Widget build(BuildContext context) {
    final values = workspace.shaderParamsFor(pass.id);
    return Column(
      key: const ValueKey('settings-shader-params'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Shader Parameters (${pass.id})',
          style: TextStyle(color: palette.muted, fontSize: 11),
        ),
        for (var i = 0; i < _labels.length; i++)
          Row(
            children: [
              SizedBox(
                width: 72,
                child: Text(
                  _labels[i],
                  style: TextStyle(color: palette.muted, fontSize: 10),
                ),
              ),
              Expanded(
                child: Slider(
                  key: ValueKey('settings-shader-param-$i'),
                  value: values[i].clamp(0.0, 2.0),
                  min: 0.0,
                  max: 2.0,
                  onChanged: (v) => workspace.setShaderParam(pass.id, i, v),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

final class _ShaderAnimationModeSelector extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;

  const _ShaderAnimationModeSelector({
    required this.workspace,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Shader Animation Mode',
        style: TextStyle(color: palette.muted, fontSize: 11),
      ),
      const SizedBox(height: 4),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final mode in ShaderAnimationMode.values)
            ChoiceChip(
              key: ValueKey('settings-shader-anim-${mode.name}'),
              label: Text(mode.name),
              selected: workspace.shaderAnimationMode == mode,
              onSelected: (_) => workspace.setShaderAnimationMode(mode),
            ),
        ],
      ),
    ],
  );
}

final class _PerfHudToggleRow extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;

  const _PerfHudToggleRow({required this.workspace, required this.palette});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          'Performance HUD (FPS • Ctrl+Shift+F9)',
          style: TextStyle(color: palette.muted, fontSize: 11),
        ),
      ),
      Switch(
        key: const ValueKey('settings-perf-hud-switch'),
        value: workspace.showPerfHud,
        onChanged: workspace.setShowPerfHud,
      ),
    ],
  );
}

final class _ShaderActionsRow extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final bool isWeb;
  final VoidCallback onToggleWebUpload;

  const _ShaderActionsRow({
    required this.workspace,
    required this.isWeb,
    required this.onToggleWebUpload,
  });

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 6,
    children: [
      if (isWeb)
        OutlinedButton.icon(
          key: const ValueKey('settings-upload-glsl'),
          onPressed: onToggleWebUpload,
          icon: const Icon(Icons.upload_file, size: 14),
          label: const Text('Upload .glsl'),
        )
      else
        OutlinedButton.icon(
          key: const ValueKey('settings-open-shaders-folder'),
          onPressed: () => unawaited(workspace.openShadersFolder()),
          icon: const Icon(Icons.folder_open, size: 14),
          label: const Text('Open Shaders Folder'),
        ),
      OutlinedButton.icon(
        key: const ValueKey('settings-reload-shaders'),
        onPressed: () => unawaited(workspace.reloadShaders()),
        icon: const Icon(Icons.refresh, size: 14),
        label: const Text('Reload Shaders (Ctrl+Shift+F5)'),
      ),
    ],
  );
}

final class _WebGlslUploadForm extends StatelessWidget {
  final TextEditingController nameController;
  final TextEditingController sourceController;
  final TerminalShaderStage stage;
  final ShaderStageHint? detectedStageHint;
  final FtermOverlayPalette palette;
  final ValueChanged<String> onSourceChanged;
  final ValueChanged<TerminalShaderStage> onStageSelected;
  final VoidCallback onSubmit;

  const _WebGlslUploadForm({
    required this.nameController,
    required this.sourceController,
    required this.stage,
    required this.detectedStageHint,
    required this.palette,
    required this.onSourceChanged,
    required this.onStageSelected,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('settings-web-glsl-form'),
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: palette.surfaceAlt,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: palette.border),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('settings-web-glsl-name'),
          controller: nameController,
          decoration: const InputDecoration(
            isDense: true,
            labelText: 'Shader filename (.glsl)',
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          key: const ValueKey('settings-web-glsl-source'),
          controller: sourceController,
          maxLines: 4,
          onChanged: onSourceChanged,
          decoration: const InputDecoration(
            isDense: true,
            labelText: 'Ghostty Shadertoy GLSL',
            hintText:
                'void mainImage(out vec4 fragColor, in vec2 fragCoord) {}',
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ChoiceChip(
              key: const ValueKey('settings-web-glsl-stage-bg'),
              label: const Text('Background'),
              selected: stage == TerminalShaderStage.background,
              onSelected: (_) =>
                  onStageSelected(TerminalShaderStage.background),
            ),
            ChoiceChip(
              key: const ValueKey('settings-web-glsl-stage-fg'),
              label: const Text('Foreground'),
              selected: stage == TerminalShaderStage.foreground,
              onSelected: (_) =>
                  onStageSelected(TerminalShaderStage.foreground),
            ),
            if (detectedStageHint case final hint?)
              Text(
                'Detected: ${hint.shortLabel}',
                key: const ValueKey('settings-web-glsl-detected-stage'),
                style: TextStyle(color: palette.muted, fontSize: 10),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            key: const ValueKey('settings-web-glsl-save'),
            onPressed: onSubmit,
            child: const Text('Save & Apply'),
          ),
        ),
      ],
    ),
  );
}

final class _FontSizeControls extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;

  const _FontSizeControls({required this.workspace, required this.palette});

  String _formatFontSize(double size) => size == size.roundToDouble()
      ? '${size.toInt()} pt'
      : '${size.toStringAsFixed(1)} pt';

  @override
  Widget build(BuildContext context) {
    final size = workspace.effectiveFontSize;
    final canDecrease = size > FtermPreferences.minFontSize;
    final canIncrease = size < FtermPreferences.maxFontSize;
    final hasOverride = workspace.preferences.fontSize != null;

    return Row(
      children: [
        Text('Font Size', style: TextStyle(color: palette.muted, fontSize: 11)),
        const Spacer(),
        OutlinedButton(
          key: const ValueKey('settings-font-decrease'),
          onPressed: canDecrease ? () => workspace.adjustFontSize(-1.0) : null,
          child: const Text('-'),
        ),
        const SizedBox(width: 8),
        Text(
          _formatFontSize(size),
          key: const ValueKey('settings-font-size-value'),
          style: TextStyle(
            color: palette.foreground,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          key: const ValueKey('settings-font-increase'),
          onPressed: canIncrease ? () => workspace.adjustFontSize(1.0) : null,
          child: const Text('+'),
        ),
        const SizedBox(width: 8),
        TextButton(
          key: const ValueKey('settings-font-reset'),
          onPressed: hasOverride ? workspace.resetFontSize : null,
          child: const Text('Reset'),
        ),
      ],
    );
  }
}

final class _DesktopShellOverrideSection extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final TextEditingController shellExecCtrl;
  final TextEditingController shellArgsCtrl;

  const _DesktopShellOverrideSection({
    required this.workspace,
    required this.palette,
    required this.shellExecCtrl,
    required this.shellArgsCtrl,
  });

  static const List<(String id, String label, String? executable)> _presets = [
    ('default', r'Default ($SHELL)', null),
    ('zsh', 'zsh', 'zsh'),
    ('bash', 'bash', 'bash'),
    ('sh', 'sh', 'sh'),
  ];

  @override
  Widget build(BuildContext context) {
    final prefs = workspace.preferences;
    final activeExec = prefs.shellExecutable;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Shell Override (new tabs & splits)',
          style: TextStyle(color: palette.muted, fontSize: 11),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final preset in _presets)
              ChoiceChip(
                key: ValueKey('settings-shell-preset-${preset.$1}'),
                label: Text(preset.$2),
                selected: activeExec == preset.$3,
                onSelected: (_) => workspace.updatePreferences(
                  workspace.preferences.copyWith(
                    shellExecutable: preset.$3,
                    clearShellExecutable: preset.$3 == null,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('settings-shell-executable'),
          controller: shellExecCtrl,
          decoration: const InputDecoration(
            isDense: true,
            labelText: 'Shell executable',
            hintText: r'Leave blank for $SHELL (e.g. zsh, /bin/zsh)',
          ),
          onChanged: (value) {
            final trimmed = value.trim();
            workspace.updatePreferences(
              workspace.preferences.copyWith(
                shellExecutable: trimmed,
                clearShellExecutable: trimmed.isEmpty,
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('settings-shell-arguments'),
          controller: shellArgsCtrl,
          decoration: const InputDecoration(
            isDense: true,
            labelText: 'Shell arguments',
            hintText: 'Flags (e.g. -l --norc or -c "tmux new")',
          ),
          onChanged: (value) => workspace.updatePreferences(
            workspace.preferences.copyWith(
              shellArguments: FtermWorkspaceController.parseShellArguments(
                value,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        SwitchListTile.adaptive(
          key: const ValueKey('settings-login-shell'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Run as login shell (-l)'),
          value: prefs.loginShell,
          onChanged: (v) => workspace.updatePreferences(
            workspace.preferences.copyWith(loginShell: v),
          ),
        ),
      ],
    );
  }
}

final class _DesktopUpdatesSection extends StatefulWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final UrlOpener onOpenUrl;

  const _DesktopUpdatesSection({
    required this.workspace,
    required this.palette,
    required this.onOpenUrl,
  });

  @override
  State<_DesktopUpdatesSection> createState() => _DesktopUpdatesSectionState();
}

final class _DesktopUpdatesSectionState extends State<_DesktopUpdatesSection> {
  bool _awaitingRestartConfirm = false;

  void _onRestartPressed(UpdateViewModel vm) {
    final counts = widget.workspace.activeLocalSessionCounts;
    if (counts.activeLocalShells > 0 || counts.activeLiveShares > 0) {
      setState(() => _awaitingRestartConfirm = true);
      return;
    }
    unawaited(vm.restartToUpdate());
  }

  void _confirmRestart(UpdateViewModel vm) {
    setState(() => _awaitingRestartConfirm = false);
    unawaited(vm.restartToUpdate());
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.workspace.updateViewModel;
    return ListenableBuilder(
      listenable: vm,
      builder: (_, _) {
        final prefs = widget.workspace.preferences;
        final p = widget.palette;
        final isBusy =
            vm.status == UpdateStatus.checking ||
            vm.status == UpdateStatus.downloading;
        return Column(
          key: const ValueKey('settings-updates-section'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('Updates', style: TextStyle(color: p.muted, fontSize: 11)),
                const SizedBox(width: 8),
                Text(
                  'v${vm.currentVersion}',
                  key: const ValueKey('settings-update-current-version'),
                  style: TextStyle(
                    color: p.foreground,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                OutlinedButton(
                  key: const ValueKey('settings-update-check'),
                  onPressed: isBusy
                      ? null
                      : () => unawaited(vm.checkForUpdates()),
                  child: Text(
                    vm.status == UpdateStatus.checking
                        ? 'Checking...'
                        : 'Check for Updates',
                  ),
                ),
              ],
            ),
            SwitchListTile.adaptive(
              key: const ValueKey('settings-update-daily'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Check daily for updates'),
              value: prefs.updateCheckMode == UpdateCheckMode.daily,
              onChanged: (daily) => widget.workspace.updatePreferences(
                prefs.copyWith(
                  updateCheckMode: daily
                      ? UpdateCheckMode.daily
                      : UpdateCheckMode.manual,
                ),
              ),
            ),
            SwitchListTile.adaptive(
              key: const ValueKey('settings-update-prereleases'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Include pre-releases'),
              value: prefs.includePrereleases,
              onChanged: (inc) => widget.workspace.updatePreferences(
                prefs.copyWith(includePrereleases: inc),
              ),
            ),
            if (vm.statusMessage case final infoMsg?)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  infoMsg,
                  key: const ValueKey('settings-update-status-message'),
                  style: TextStyle(color: p.muted, fontSize: 11),
                ),
              ),
            if (vm.errorMessage case final errMsg?)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  errMsg,
                  key: const ValueKey('settings-update-error-message'),
                  style: TextStyle(color: p.danger, fontSize: 11),
                ),
              ),
            if (vm.availableUpdate case final update?)
              _UpdateReleaseCard(
                workspace: widget.workspace,
                vm: vm,
                update: update,
                palette: p,
                onOpenUrl: widget.onOpenUrl,
                awaitingRestartConfirm: _awaitingRestartConfirm,
                onRestartPressed: () => _onRestartPressed(vm),
                onConfirmRestart: () => _confirmRestart(vm),
                onCancelRestart: () =>
                    setState(() => _awaitingRestartConfirm = false),
              ),
          ],
        );
      },
    );
  }
}

final class _UpdateReleaseCard extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final UpdateViewModel vm;
  final AvailableUpdate update;
  final FtermOverlayPalette palette;
  final UrlOpener onOpenUrl;
  final bool awaitingRestartConfirm;
  final VoidCallback onRestartPressed;
  final VoidCallback onConfirmRestart;
  final VoidCallback onCancelRestart;

  const _UpdateReleaseCard({
    required this.workspace,
    required this.vm,
    required this.update,
    required this.palette,
    required this.onOpenUrl,
    required this.awaitingRestartConfirm,
    required this.onRestartPressed,
    required this.onConfirmRestart,
    required this.onCancelRestart,
  });

  static String _summarizeNotes(String raw) {
    final lines = [
      for (final line in raw.split('\n'))
        if (line.trim() case final t when t.isNotEmpty && !t.startsWith('#')) t,
    ];
    if (lines.isEmpty) return '';
    return lines.take(2).join('\n');
  }

  static String _formatMegabytes(int bytes) =>
      (bytes / (1024 * 1024)).toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final summary = _summarizeNotes(update.notes);
    final progress = vm.downloadProgress;
    return Material(
      color: palette.surfaceAlt,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: palette.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    update.isPrerelease
                        ? 'fterm v${update.version} (pre-release)'
                        : 'fterm v${update.version} available',
                    style: TextStyle(
                      color: palette.foreground,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
                TextButton(
                  key: const ValueKey('settings-update-release-link'),
                  onPressed: () => onOpenUrl(update.htmlUrl),
                  child: const Text('Release Notes'),
                ),
              ],
            ),
            if (summary.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                summary,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: palette.muted, fontSize: 11),
              ),
            ],
            if (update.unavailableAssetReason case final reason?) ...[
              const SizedBox(height: 4),
              Text(
                reason,
                style: TextStyle(color: palette.muted, fontSize: 11),
              ),
            ],
            const SizedBox(height: 8),
            if (vm.status == UpdateStatus.downloading) ...[
              LinearProgressIndicator(
                key: const ValueKey('settings-update-progress'),
                value: (progress != null && progress.totalBytes > 0)
                    ? progress.fraction
                    : null,
              ),
              if (progress != null && progress.totalBytes > 0) ...[
                const SizedBox(height: 4),
                Text(
                  '${_formatMegabytes(progress.receivedBytes)} / '
                  '${_formatMegabytes(progress.totalBytes)} MB',
                  style: TextStyle(color: palette.muted, fontSize: 10),
                ),
              ],
            ] else if (vm.status == UpdateStatus.readyToRestart)
              _UpdateReadyControls(
                workspace: workspace,
                vm: vm,
                palette: palette,
                awaitingRestartConfirm: awaitingRestartConfirm,
                onRestartPressed: onRestartPressed,
                onConfirmRestart: onConfirmRestart,
                onCancelRestart: onCancelRestart,
              )
            else
              _UpdateActionButtons(
                vm: vm,
                update: update,
                onOpenUrl: onOpenUrl,
              ),
          ],
        ),
      ),
    );
  }
}

final class _UpdateReadyControls extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final UpdateViewModel vm;
  final FtermOverlayPalette palette;
  final bool awaitingRestartConfirm;
  final VoidCallback onRestartPressed;
  final VoidCallback onConfirmRestart;
  final VoidCallback onCancelRestart;

  const _UpdateReadyControls({
    required this.workspace,
    required this.vm,
    required this.palette,
    required this.awaitingRestartConfirm,
    required this.onRestartPressed,
    required this.onConfirmRestart,
    required this.onCancelRestart,
  });

  static String _formatSessionWarning(int shells, int shares) {
    final parts = <String>[
      if (shells > 0)
        '$shells active local ${shells == 1 ? 'shell' : 'shells'}',
      if (shares > 0)
        '$shares live ${shares == 1 ? 'broadcast' : 'broadcasts'}',
    ];
    return 'Restarting closes ${parts.join(' and ')}.';
  }

  @override
  Widget build(BuildContext context) {
    final counts = workspace.activeLocalSessionCounts;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile.adaptive(
          key: const ValueKey('settings-update-apply-on-quit'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Apply update on quit'),
          value: vm.applyOnQuit,
          onChanged: vm.setApplyOnQuit,
        ),
        if (awaitingRestartConfirm) ...[
          Text(
            _formatSessionWarning(
              counts.activeLocalShells,
              counts.activeLiveShares,
            ),
            key: const ValueKey('settings-update-restart-warning'),
            style: TextStyle(color: palette.danger, fontSize: 11),
          ),
          const SizedBox(height: 6),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: [
              TextButton(
                key: const ValueKey('settings-update-cancel-restart'),
                onPressed: onCancelRestart,
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const ValueKey('settings-update-confirm-restart'),
                onPressed: onConfirmRestart,
                child: const Text('Confirm Restart'),
              ),
            ],
          ),
        ] else
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const ValueKey('settings-update-restart'),
              onPressed: onRestartPressed,
              child: const Text('Restart to Update'),
            ),
          ),
      ],
    );
  }
}

final class _UpdateActionButtons extends StatelessWidget {
  final UpdateViewModel vm;
  final AvailableUpdate update;
  final UrlOpener onOpenUrl;

  const _UpdateActionButtons({
    required this.vm,
    required this.update,
    required this.onOpenUrl,
  });

  @override
  Widget build(BuildContext context) {
    final canDownload =
        vm.capability == SelfUpdateCapability.supported && update.asset != null;
    final showFinderReveal =
        vm.capability == SelfUpdateCapability.macosAppManagementDenied &&
        vm.stagedUpdate != null;
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 6,
      children: [
        TextButton(
          key: const ValueKey('settings-update-skip'),
          onPressed: vm.skipAvailableVersion,
          child: const Text('Skip Version'),
        ),
        if (showFinderReveal)
          FilledButton(
            key: const ValueKey('settings-update-reveal-finder'),
            onPressed: () => unawaited(vm.revealStagedInFinder()),
            child: const Text('Reveal Staged App in Finder'),
          ),
        if (canDownload)
          FilledButton(
            key: const ValueKey('settings-update-download'),
            onPressed: () => unawaited(vm.downloadAvailableUpdate()),
            child: Text(
              vm.status == UpdateStatus.error
                  ? 'Retry Download'
                  : 'Download Update',
            ),
          )
        else
          OutlinedButton(
            key: const ValueKey('settings-update-open-release'),
            onPressed: () => onOpenUrl(update.htmlUrl),
            child: const Text('Open GitHub Release'),
          ),
      ],
    );
  }
}

final class _StatsOverlay extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;

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
          buildFtermOverlayHeader(
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
  final FtermOverlayPalette palette;

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
          buildFtermOverlayHeader(
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
  final FtermOverlayPalette palette;

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
    (r'Ctrl+\ then , / i / ? / a', 'Settings / Stats / Help / About'),
    ('Cmd+T/W/D/Shift+D/1..9', 'Native macOS Desktop shortcuts'),
    ('Cmd+= / Cmd+- / Cmd+0', 'Zoom font in / out / reset (macOS)'),
    ('Ctrl+Shift+T/W/D/E', 'Native Linux / Windows shortcuts'),
    ('Ctrl+= / Ctrl+- / Ctrl+0', 'Zoom font in / out / reset (Linux/Win)'),
    ('Ctrl+Shift+F5', 'Reload custom fragment shaders (Desktop)'),
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
          buildFtermOverlayHeader(
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
  final FtermOverlayPalette palette;

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
          buildFtermOverlayHeader(
            title: 'Upload Dropped Files (${files.length})',
            palette: p,
            onClose: workspace.cancelFileUpload,
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
                key: const ValueKey('upload-cancel'),
                onPressed: workspace.cancelFileUpload,
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
