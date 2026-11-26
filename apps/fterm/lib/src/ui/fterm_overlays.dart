import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show TargetPlatform, listEquals;
import 'package:material_ui/material_ui.dart';
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';

import '../file_drop_bridge.dart';
import '../font_loader.dart';
import '../launch_config.dart';
import '../workspace/fterm_workspace_controller.dart';
import '../workspace/split_tree_model.dart';
import 'fterm_about_overlay.dart';
import 'fterm_feedback_overlay.dart';
import 'settings/fterm_settings_overlay.dart';

/// Modal overlays rendered over the terminal workspace when [FtermOverlay] !=
/// [FtermOverlay.none].
final class FtermOverlayHost extends StatelessWidget {
  /// Backing workspace coordinator.
  final FtermWorkspaceController workspace;

  /// External URL launcher invoked for release links.
  final UrlOpener onOpenUrl;

  /// Whether this host renders in Web mode (hides native desktop update UI).
  final bool isWeb;

  /// Optional platform override forwarded to platform-aware modal tabs.
  final TargetPlatform? platformOverride;

  /// Optional callback capturing the active terminal pane as a [ui.Image]
  /// (ownership transfers to the caller for annotation and disposal).
  final Future<ui.Image?> Function()? onCaptureScreenshot;

  /// Creates the active modal overlay layer, or `SizedBox.shrink()` when idle.
  const FtermOverlayHost({
    super.key,
    required this.workspace,
    this.onOpenUrl = openExternalUrl,
    this.isWeb = false,
    this.platformOverride,
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
      FtermOverlay.settings => (820.0, 620.0),
      FtermOverlay.licenses => (680.0, 560.0),
      FtermOverlay.about => (540.0, 560.0),
      FtermOverlay.feedback => (560.0, 620.0),
      FtermOverlay.whatsNew => (580.0, 580.0),
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
              onTap:
                  overlay == FtermOverlay.about ||
                      overlay == FtermOverlay.whatsNew
                  ? workspace.dismissOverlay
                  : null,
              child: ColoredBox(
                color: overlay == FtermOverlay.whatsNew
                    ? const Color(0x4D000000)
                    : const Color(0x99000000),
              ),
            ),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
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
                      FtermOverlay.settings => FtermSettingsOverlay(
                        workspace: workspace,
                        palette: palette,
                        onOpenUrl: onOpenUrl,
                        isWeb: isWeb,
                        platformOverride: platformOverride,
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
                      FtermOverlay.whatsNew => _WhatsNewOverlay(
                        workspace: workspace,
                        palette: palette,
                        isWeb: isWeb,
                      ),
                    },
                  ),
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

enum _ConnectIapMode { none, serviceAccount, keyFile }

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
  late final TextEditingController _iapSaCtrl;
  late final TextEditingController _iapKeyCtrl;
  late final TextEditingController _gcloudPathCtrl;
  late _ConnectIapMode _iapMode;
  String? _probedGcloudPath;
  String? _validationError;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    final ws = widget.workspace;
    _urlCtrl = TextEditingController(text: ws.activeRelayUri.toString());
    _clientTokenCtrl = TextEditingController(text: ws.activeClientToken);
    _casterTokenCtrl = TextEditingController(text: ws.activeCasterToken);
    _iapSaCtrl = TextEditingController(text: ws.activeIapServiceAccount);
    _iapKeyCtrl = TextEditingController(text: ws.activeIapKeyFilePath);
    _gcloudPathCtrl = TextEditingController(text: ws.activeGcloudPath);
    if (ws.activeIapKeyFilePath.isNotEmpty) {
      _iapMode = _ConnectIapMode.keyFile;
    } else if (ws.activeIapServiceAccount.isNotEmpty) {
      _iapMode = _ConnectIapMode.serviceAccount;
    } else {
      _iapMode = _ConnectIapMode.none;
    }
    if (ws.isDesktopHost) {
      _probedGcloudPath = ws.probeGcloudExecutable();
    }
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _clientTokenCtrl.dispose();
    _casterTokenCtrl.dispose();
    _iapSaCtrl.dispose();
    _iapKeyCtrl.dispose();
    _gcloudPathCtrl.dispose();
    super.dispose();
  }

  ({String? serviceAccount, String? keyFilePath, String? gcloudPath})
  _resolveSubmitIapFields() {
    if (!widget.workspace.isDesktopHost) {
      return (serviceAccount: null, keyFilePath: null, gcloudPath: null);
    }
    final gcloudOverride = _gcloudPathCtrl.text.trim();
    switch (_iapMode) {
      case _ConnectIapMode.none:
        return (
          serviceAccount: '',
          keyFilePath: '',
          gcloudPath: gcloudOverride,
        );
      case _ConnectIapMode.serviceAccount:
        final sa = _iapSaCtrl.text.trim();
        if (sa.isEmpty) {
          throw const FormatException(
            'Enter a GCP service account email or select None.',
          );
        }
        return (
          serviceAccount: sa,
          keyFilePath: '',
          gcloudPath: gcloudOverride,
        );
      case _ConnectIapMode.keyFile:
        final keyPath = _iapKeyCtrl.text.trim();
        if (keyPath.isEmpty) {
          throw const FormatException(
            'Enter a service account JSON key file path or select None.',
          );
        }
        return (
          serviceAccount: '',
          keyFilePath: keyPath,
          gcloudPath: gcloudOverride,
        );
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final Uri parsed;
    final ({String? serviceAccount, String? keyFilePath, String? gcloudPath})
    iapFields;
    try {
      parsed = CastLaunchConfig.parseRelayUri(_urlCtrl.text);
      iapFields = _resolveSubmitIapFields();
    } on FormatException catch (e) {
      setState(() => _validationError = e.message);
      return;
    }
    setState(() {
      _validationError = null;
      _submitting = true;
    });
    try {
      await widget.workspace.connectRelay(
        serverUri: parsed,
        clientToken: _clientTokenCtrl.text,
        casterToken: _casterTokenCtrl.text,
        iapServiceAccount: iapFields.serviceAccount,
        iapKeyFilePath: iapFields.keyFilePath,
        gcloudPath: iapFields.gcloudPath,
      );
    } on FormatException catch (e) {
      if (mounted) {
        setState(() => _validationError = e.message);
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() => _validationError = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
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
              const SizedBox(height: 12),
              _ConnectIapSection(
                palette: p,
                mode: _iapMode,
                saController: _iapSaCtrl,
                keyController: _iapKeyCtrl,
                gcloudPathController: _gcloudPathCtrl,
                probedGcloudPath: _probedGcloudPath,
                onModeChanged: (next) => setState(() {
                  _iapMode = next;
                  _validationError = null;
                }),
                onGcloudPathChanged: (_) => setState(() {}),
                onSubmit: () => unawaited(_submit()),
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

  static InputDecoration _inputDeco(
    String label,
    FtermOverlayPalette p, {
    String? hint,
  }) => InputDecoration(
    labelText: label,
    hintText: hint,
    labelStyle: TextStyle(color: p.muted, fontSize: 11),
    hintStyle: TextStyle(color: p.muted.withValues(alpha: 0.6), fontSize: 11),
    isDense: true,
    border: OutlineInputBorder(borderSide: BorderSide(color: p.border)),
    enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: p.border)),
  );
}

final class _ConnectIapSection extends StatelessWidget {
  final FtermOverlayPalette palette;
  final _ConnectIapMode mode;
  final TextEditingController saController;
  final TextEditingController keyController;
  final TextEditingController gcloudPathController;
  final String? probedGcloudPath;
  final ValueChanged<_ConnectIapMode> onModeChanged;
  final ValueChanged<String> onGcloudPathChanged;
  final VoidCallback onSubmit;

  const _ConnectIapSection({
    required this.palette,
    required this.mode,
    required this.saController,
    required this.keyController,
    required this.gcloudPathController,
    required this.probedGcloudPath,
    required this.onModeChanged,
    required this.onGcloudPathChanged,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final hasCustomGcloud = gcloudPathController.text.trim().isNotEmpty;
    final (helperText, helperColor) = _gcloudHelperTextAndColor(
      hasCustomGcloud: hasCustomGcloud,
      probedGcloudPath: probedGcloudPath,
      palette: p,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Cloud Run IAP', style: TextStyle(color: p.muted, fontSize: 11)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            ChoiceChip(
              key: const ValueKey('connect-iap-mode-none'),
              label: const Text('None'),
              selected: mode == _ConnectIapMode.none,
              onSelected: (_) => onModeChanged(_ConnectIapMode.none),
            ),
            ChoiceChip(
              key: const ValueKey('connect-iap-mode-sa'),
              label: const Text('Service Account'),
              selected: mode == _ConnectIapMode.serviceAccount,
              onSelected: (_) => onModeChanged(_ConnectIapMode.serviceAccount),
            ),
            ChoiceChip(
              key: const ValueKey('connect-iap-mode-key'),
              label: const Text('JSON Key File'),
              selected: mode == _ConnectIapMode.keyFile,
              onSelected: (_) => onModeChanged(_ConnectIapMode.keyFile),
            ),
          ],
        ),
        if (mode == _ConnectIapMode.serviceAccount) ...[
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('connect-iap-sa-field'),
            controller: saController,
            decoration: _ConnectOverlayState._inputDeco(
              'IAP Service Account Email',
              p,
              hint: 'name@project.iam.gserviceaccount.com',
            ),
            onSubmitted: (_) => onSubmit(),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('connect-gcloud-path-field'),
            controller: gcloudPathController,
            decoration: _ConnectOverlayState._inputDeco(
              'gcloud Path Override (optional)',
              p,
              hint: '/path/to/google-cloud-sdk/bin/gcloud',
            ),
            onChanged: onGcloudPathChanged,
            onSubmitted: (_) => onSubmit(),
          ),
          if (helperText != null) ...[
            const SizedBox(height: 4),
            Text(
              helperText,
              key: const ValueKey('connect-gcloud-probe-hint'),
              style: TextStyle(color: helperColor, fontSize: 10),
            ),
          ],
        ],
        if (mode == _ConnectIapMode.keyFile) ...[
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('connect-iap-key-field'),
            controller: keyController,
            decoration: _ConnectOverlayState._inputDeco(
              'IAP Key File Path',
              p,
              hint: '/path/to/service-account.json',
            ),
            onSubmitted: (_) => onSubmit(),
          ),
        ],
      ],
    );
  }

  static (String?, Color) _gcloudHelperTextAndColor({
    required bool hasCustomGcloud,
    required String? probedGcloudPath,
    required FtermOverlayPalette palette,
  }) {
    if (hasCustomGcloud) {
      return ('Using custom gcloud path', palette.muted);
    }
    if (probedGcloudPath != null) {
      return ('Auto-detected: $probedGcloudPath', palette.muted);
    }
    return (
      'gcloud not found on PATH — enter full path '
          '(e.g. /Users/.../google-cloud-sdk/bin/gcloud)',
      palette.warning,
    );
  }
}

final class _SessionPickerOverlay extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;

  const _SessionPickerOverlay({required this.workspace, required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final remoteSessions = workspace.availableRemoteSessions;
    final spawnableSessionId = workspace.isDesktopHost
        ? null
        : workspace.primarySpawnableRemoteSessionId;
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
              if (spawnableSessionId != null)
                FilledButton.icon(
                  key: const ValueKey('picker-new-remote-shell'),
                  onPressed: () {
                    if (workspace.requestRemoteShellSpawn(spawnableSessionId)) {
                      workspace.dismissOverlay();
                    }
                  },
                  icon: const Icon(Icons.add_box_outlined, size: 14),
                  label: const Text('New Remote Shell'),
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
              if (session.allowSpawn)
                IconButton(
                  key: ValueKey('picker-spawn-${session.id.value}'),
                  tooltip: 'New Shell',
                  icon: Icon(Icons.add_box_outlined, size: 15, color: p.accent),
                  onPressed: () {
                    if (workspace.requestRemoteShellSpawn(session.id)) {
                      workspace.dismissOverlay();
                    }
                  },
                ),
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
    (r'Ctrl+\ then e', 'Open GLSL Shader Editor tab'),
    ('Alt+S / Cmd+S (Shift: As)', 'Save active GLSL shader in editor'),
    (r'Ctrl+\ then , / i / ? / a', 'Settings / Stats / Help / About'),
    ('Cmd+T/W/D/Shift+D/1..9', 'Native macOS Desktop shortcuts'),
    ('Cmd+= / Cmd+- / Cmd+0', 'Zoom font in / out / reset (macOS)'),
    ('Ctrl+Shift+T/W/D/E', 'Native Linux / Windows shortcuts'),
    ('Ctrl+= / Ctrl+- / Ctrl+0', 'Zoom font in / out / reset (Linux/Win)'),
    ('Ctrl+Shift+F5', 'Reload custom fragment shaders (Desktop)'),
    (r'Ctrl+Shift+F6 / Ctrl+\ 0', 'Emergency Stop / Resume GPU shaders'),
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
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const ValueKey('help-whats-new-button'),
              onPressed: workspace.openWhatsNew,
              icon: const Icon(Icons.auto_awesome, size: 14),
              label: Text("What's New in v${workspace.currentWhatsNewVersion}"),
            ),
          ),
        ],
      ),
    );
  }
}

final class _WhatsNewOverlay extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final bool isWeb;

  const _WhatsNewOverlay({
    required this.workspace,
    required this.palette,
    required this.isWeb,
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: workspace.chromeNotifier,
    builder: (_, _) {
      final p = palette;
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            buildFtermOverlayHeader(
              title: "What's New in v${workspace.currentWhatsNewVersion}",
              palette: p,
              onClose: workspace.dismissOverlay,
            ),
            const SizedBox(height: 4),
            Text(
              'Try live GPU shader presets below — changes preview on the '
              'terminal behind this modal and can be reverted in one click.',
              style: TextStyle(color: p.muted, fontSize: 11),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _WhatsNewCard(
                      palette: p,
                      icon: Icons.auto_awesome,
                      title: 'Ghostty GLSL Shaders & Built-In Presets',
                      description:
                          'Drop Ghostty .glsl shaders into your shaders folder or '
                          'stack built-in GPU passes (flutter_gpu on desktop, '
                          'WebGL2 on web).',
                      footer: _WhatsNewTryItRow(
                        workspace: workspace,
                        palette: p,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _WhatsNewCard(
                      palette: p,
                      icon: Icons.terminal,
                      title: 'CLI Artistic Shaders (ESC _ S) & Safe Trust',
                      description:
                          'Built-in region presets (fire, one_ring, vortex, '
                          'ice_frost, neon_pulse, glitch_tear, forge_spark), '
                          '120–240 Hz GPU cell transforms, and SHA-256 trust prompts '
                          'for custom CLI GLSL.',
                    ),
                    const SizedBox(height: 10),
                    _WhatsNewCard(
                      palette: p,
                      icon: Icons.speed,
                      title: 'GPU Adapter Picker, FPS Cap & Performance HUD',
                      description:
                          'Switch integrated vs. discrete GPU on Windows (with '
                          '1-click restart), cap ambient shader FPS, monitor live '
                          'FPS/GPU/VRAM (Ctrl+Shift+F9), and record Chrome traces '
                          '(Ctrl+Shift+F10).',
                    ),
                    const SizedBox(height: 10),
                    _WhatsNewCard(
                      palette: p,
                      icon: Icons.add_box_outlined,
                      title:
                          'Remote Shell Spawning, Nerd Font v3 & Layout Resume',
                      description:
                          'Spawn fresh remote shells from fterm Web (picker or '
                          'pane splits) via multi-PTY termui_cast, restore tabs '
                          'and splits across refreshes via sessionStorage, and '
                          'render Nerd Font v3 icons plus offline COLRv1 emoji.',
                    ),
                    const SizedBox(height: 10),
                    _WhatsNewCard(
                      palette: p,
                      icon: Icons.public,
                      title: 'Self-Hosted Web Relay, Compression & Subpaths',
                      description:
                          'Gzip/Brotli static WASM and font serving, loopback '
                          '--allowed-origin proxy support, --trust-proxy-client-auth '
                          'one-step reloads, --base-path subpath hosting, and an '
                          'About-styled Web loading splash.',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            _WhatsNewActionBar(workspace: workspace, palette: p, isWeb: isWeb),
          ],
        ),
      );
    },
  );
}

final class _WhatsNewCard extends StatelessWidget {
  final FtermOverlayPalette palette;
  final IconData icon;
  final String title;
  final String description;
  final Widget? footer;

  const _WhatsNewCard({
    required this.palette,
    required this.icon,
    required this.title,
    required this.description,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.surfaceAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: p.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: p.accent),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: p.foreground,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            description,
            style: TextStyle(color: p.muted, fontSize: 11, height: 1.35),
          ),
          if (footer case final footerWidget?) ...[
            const SizedBox(height: 10),
            footerWidget,
          ],
        ],
      ),
    );
  }
}

final class _WhatsNewTryItRow extends StatelessWidget {
  static const List<String> _waveBg = ['wallpaper_wave'];
  static const List<String> _waveFg = ['cursor_glow'];
  static const List<String> _crtBg = [];
  static const List<String> _crtFg = ['retro_phosphor'];

  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;

  const _WhatsNewTryItRow({required this.workspace, required this.palette});

  @override
  Widget build(BuildContext context) {
    final isWaveActive =
        listEquals(workspace.backgroundShaderChain, _waveBg) &&
        listEquals(workspace.foregroundShaderChain, _waveFg);
    final isCrtActive =
        listEquals(workspace.backgroundShaderChain, _crtBg) &&
        listEquals(workspace.foregroundShaderChain, _crtFg);

    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        _buildTryChip(
          key: const ValueKey('whats-new-try-wave-glow'),
          label: 'Try Wave + Glow',
          active: isWaveActive,
          onPressed: () => unawaited(
            workspace.applyWhatsNewShaderPreview(
              backgroundChain: _waveBg,
              foregroundChain: _waveFg,
            ),
          ),
        ),
        _buildTryChip(
          key: const ValueKey('whats-new-try-retro-crt'),
          label: 'Try Retro Phosphor CRT',
          active: isCrtActive,
          onPressed: () => unawaited(
            workspace.applyWhatsNewShaderPreview(
              backgroundChain: _crtBg,
              foregroundChain: _crtFg,
            ),
          ),
        ),
        if (workspace.hasWhatsNewPreviewChanges)
          TextButton.icon(
            key: const ValueKey('whats-new-revert-preview'),
            onPressed: () => unawaited(workspace.revertWhatsNewPreview()),
            icon: Icon(Icons.undo, size: 14, color: palette.warning),
            label: Text(
              'Revert',
              style: TextStyle(color: palette.warning, fontSize: 11),
            ),
          ),
      ],
    );
  }

  Widget _buildTryChip({
    required Key key,
    required String label,
    required bool active,
    required VoidCallback onPressed,
  }) {
    if (active) {
      return FilledButton.icon(
        key: key,
        onPressed: onPressed,
        icon: const Icon(Icons.check, size: 14),
        label: Text(label, style: const TextStyle(fontSize: 11)),
      );
    }
    return OutlinedButton.icon(
      key: key,
      onPressed: onPressed,
      icon: const Icon(Icons.play_arrow, size: 14),
      label: Text(label, style: const TextStyle(fontSize: 11)),
    );
  }
}

final class _WhatsNewActionBar extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final bool isWeb;

  const _WhatsNewActionBar({
    required this.workspace,
    required this.palette,
    required this.isWeb,
  });

  @override
  Widget build(BuildContext context) {
    final hudActive = workspace.showPerfHud;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('whats-new-toggle-perf-hud'),
              onPressed: workspace.togglePerfHud,
              icon: Icon(
                Icons.speed,
                size: 14,
                color: hudActive ? palette.accent : null,
              ),
              label: Text(
                hudActive ? 'Perf HUD: On' : 'Toggle Perf HUD',
                style: const TextStyle(fontSize: 11),
              ),
            ),
            OutlinedButton.icon(
              key: const ValueKey('whats-new-open-settings'),
              onPressed: () =>
                  workspace.openSettingsOverlay(initialSection: .shaders),
              icon: const Icon(Icons.tune, size: 14),
              label: const Text(
                'Shader Settings',
                style: TextStyle(fontSize: 11),
              ),
            ),
            if (!isWeb)
              OutlinedButton.icon(
                key: const ValueKey('whats-new-open-shaders-folder'),
                onPressed: () => unawaited(workspace.openShadersFolder()),
                icon: const Icon(Icons.folder_open, size: 14),
                label: const Text(
                  'Shaders Folder',
                  style: TextStyle(fontSize: 11),
                ),
              ),
          ],
        ),
        FilledButton(
          key: const ValueKey('whats-new-done'),
          onPressed: workspace.dismissOverlay,
          child: const Text('Done'),
        ),
      ],
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
