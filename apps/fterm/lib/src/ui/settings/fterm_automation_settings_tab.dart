import 'dart:async';

import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, HardwareKeyboard;
import 'package:material_ui/material_ui.dart';

import '../../automation/automation_models.dart';
import '../fterm_overlays.dart';
import 'settings_primitives.dart';

/// Settings section configuring the loopback-only HTTP automation driver.
///
/// Renders controls backed by [AutomationDriverViewModel] without owning any
/// server or persistence logic directly.
final class FtermAutomationSettingsTab extends StatefulWidget {
  /// Observable view model exposing driver state and actions.
  final AutomationDriverViewModel driver;

  /// Overlay color palette derived from the active terminal theme.
  final FtermOverlayPalette palette;

  /// Optional clipboard writer injected for hermetic testing.
  ///
  /// Defaults to writing text via [Clipboard.setData].
  final Future<void> Function(String text)? onCopyText;

  /// Optional Shift-key predicate injected for hermetic testing.
  ///
  /// Defaults to reading [HardwareKeyboard.isShiftPressed] on
  /// [HardwareKeyboard.instance].
  final bool Function()? isShiftPressed;

  /// Panel visibility, collapse state, and search-filter configuration.
  final SettingsPanelFilter filter;

  /// Creates the Automation section rendered inside the `fterm` Settings modal.
  const FtermAutomationSettingsTab({
    super.key,
    required this.driver,
    required this.palette,
    this.onCopyText,
    this.isShiftPressed,
    this.filter = const SettingsPanelFilter.showAll(),
  });

  @override
  State<FtermAutomationSettingsTab> createState() =>
      _FtermAutomationSettingsTabState();
}

enum _PasswordFeedback { none, copiedPassword, copiedHeader, regenerated }

final class _FtermAutomationSettingsTabState
    extends State<FtermAutomationSettingsTab> {
  static const Duration _feedbackDuration = Duration(seconds: 2);

  static Future<void> _defaultCopyText(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  static bool _defaultIsShiftPressed() =>
      HardwareKeyboard.instance.isShiftPressed;

  late final TextEditingController _portController;
  late final TextEditingController _passwordController;
  late int _lastSyncedPort;

  Timer? _feedbackTimer;
  _PasswordFeedback _feedback = .none;
  bool _showPassword = false;
  bool _isToggling = false;
  String? _portError;

  @override
  void initState() {
    super.initState();
    _lastSyncedPort = widget.driver.port;
    _portController = TextEditingController(text: '${widget.driver.port}');
    _passwordController = TextEditingController(text: widget.driver.password);
    widget.driver.addListener(_onDriverChanged);
  }

  @override
  void didUpdateWidget(FtermAutomationSettingsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.driver, widget.driver)) {
      oldWidget.driver.removeListener(_onDriverChanged);
      widget.driver.addListener(_onDriverChanged);
      _syncControllersFromDriver(forcePortSync: true);
    }
  }

  @override
  void dispose() {
    widget.driver.removeListener(_onDriverChanged);
    _feedbackTimer?.cancel();
    _portController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _onDriverChanged() {
    if (!mounted) return;
    _syncControllersFromDriver();
    setState(() {});
  }

  void _syncControllersFromDriver({bool forcePortSync = false}) {
    final driver = widget.driver;
    final driverPort = driver.port;
    if (forcePortSync || driver.isRunning || driverPort != _lastSyncedPort) {
      _lastSyncedPort = driverPort;
      final expectedPort = '$driverPort';
      if (_portController.text != expectedPort) {
        _portController.text = expectedPort;
      }
      _portError = null;
    }
    final expectedPassword = driver.password;
    if (_passwordController.text != expectedPassword) {
      _passwordController.text = expectedPassword;
    }
  }

  Future<void> _toggleEnabled(bool enabled) async {
    if (_isToggling || !widget.driver.isSupported) return;
    setState(() => _isToggling = true);
    try {
      await widget.driver.setEnabled(enabled);
    } finally {
      if (mounted) {
        setState(() => _isToggling = false);
      }
    }
  }

  void _handlePortInput(String raw) {
    if (widget.driver.isRunning || !widget.driver.isSupported) return;
    final parsed = int.tryParse(raw.trim());
    if (parsed == null || !AutomationDriverConfig.isValidPort(parsed)) {
      const message =
          'Enter a valid port between '
          '${AutomationDriverConfig.minPort} and '
          '${AutomationDriverConfig.maxPort}.';
      if (_portError != message) {
        setState(() => _portError = message);
      }
      return;
    }
    if (_portError != null) {
      setState(() => _portError = null);
    }
    if (parsed != widget.driver.port) {
      _lastSyncedPort = parsed;
      widget.driver.setPort(parsed);
    }
  }

  void _togglePasswordVisibility() {
    setState(() => _showPassword = !_showPassword);
  }

  Future<void> _copyPassword() async {
    final driver = widget.driver;
    final includeHeader = (widget.isShiftPressed ?? _defaultIsShiftPressed)();
    final payload = includeHeader
        ? 'http://127.0.0.1:${driver.port}\n'
              'Authorization: Bearer ${driver.password}'
        : driver.password;
    final copy = widget.onCopyText ?? _defaultCopyText;
    await copy(payload);
    if (!mounted) return;
    _showFeedback(includeHeader ? .copiedHeader : .copiedPassword);
  }

  void _regeneratePassword() {
    final driver = widget.driver;
    if (!driver.isSupported || driver.hasEphemeralTokenOverride) return;
    final updated = driver.regeneratePassword();
    if (_passwordController.text != updated) {
      _passwordController.text = updated;
    }
    _showFeedback(.regenerated);
  }

  void _showFeedback(_PasswordFeedback next) {
    _feedbackTimer?.cancel();
    setState(() => _feedback = next);
    _feedbackTimer = Timer(_feedbackDuration, () {
      if (!mounted) return;
      setState(() => _feedback = .none);
    });
  }

  @override
  Widget build(BuildContext context) {
    final filter = widget.filter;
    final driver = widget.driver;
    final palette = widget.palette;
    final showNetwork =
        filter.showPanel('automation-network') &&
        (filter.showItem('automation-port') ||
            filter.showItem('automation-password'));

    return SettingsSpacedColumn(
      children: [
        if (filter.showPanel('automation-driver'))
          _AutomationDriverPanel(
            driver: driver,
            isToggling: _isToggling,
            palette: palette,
            filter: filter,
            onToggleEnabled: _toggleEnabled,
          ),
        if (showNetwork)
          _AutomationNetworkPanel(
            driver: driver,
            portController: _portController,
            passwordController: _passwordController,
            portError: _portError,
            showPassword: _showPassword,
            feedback: _feedback,
            palette: palette,
            filter: filter,
            onPortInput: _handlePortInput,
            onTogglePasswordVisibility: _togglePasswordVisibility,
            onCopyPassword: _copyPassword,
            onRegeneratePassword: _regeneratePassword,
          ),
        if (filter.showPanel('automation-scope'))
          _AutomationScopePanel(
            driver: driver,
            palette: palette,
            filter: filter,
          ),
      ],
    );
  }
}

final class _AutomationDriverPanel extends StatelessWidget {
  final AutomationDriverViewModel driver;
  final bool isToggling;
  final FtermOverlayPalette palette;
  final SettingsPanelFilter filter;
  final ValueChanged<bool> onToggleEnabled;

  const _AutomationDriverPanel({
    required this.driver,
    required this.isToggling,
    required this.palette,
    required this.filter,
    required this.onToggleEnabled,
  });

  @override
  Widget build(BuildContext context) {
    final lastError = driver.lastError?.trim();
    return BlenderSettingsPanel(
      id: 'automation-driver',
      title: 'HTTP Automation Driver',
      categoryBreadcrumb: filter.categoryBreadcrumb,
      expanded: filter.panelExpanded('automation-driver'),
      onToggleExpanded: filter.toggleFor('automation-driver'),
      palette: palette,
      child: SettingsSpacedColumn(
        spacing: 8,
        children: [
          _AutomationEnableSection(
            isSupported: driver.isSupported,
            isRunning: driver.isRunning,
            isToggling: isToggling,
            port: driver.port,
            palette: palette,
            onChanged: onToggleEnabled,
          ),
          if (lastError != null && lastError.isNotEmpty)
            _AutomationErrorBanner(message: lastError, palette: palette),
        ],
      ),
    );
  }
}

final class _AutomationNetworkPanel extends StatelessWidget {
  final AutomationDriverViewModel driver;
  final TextEditingController portController;
  final TextEditingController passwordController;
  final String? portError;
  final bool showPassword;
  final _PasswordFeedback feedback;
  final FtermOverlayPalette palette;
  final SettingsPanelFilter filter;
  final ValueChanged<String> onPortInput;
  final VoidCallback onTogglePasswordVisibility;
  final VoidCallback onCopyPassword;
  final VoidCallback onRegeneratePassword;

  const _AutomationNetworkPanel({
    required this.driver,
    required this.portController,
    required this.passwordController,
    required this.portError,
    required this.showPassword,
    required this.feedback,
    required this.palette,
    required this.filter,
    required this.onPortInput,
    required this.onTogglePasswordVisibility,
    required this.onCopyPassword,
    required this.onRegeneratePassword,
  });

  @override
  Widget build(BuildContext context) => BlenderSettingsPanel(
    id: 'automation-network',
    title: 'Network & Authentication',
    categoryBreadcrumb: filter.categoryBreadcrumb,
    expanded: filter.panelExpanded('automation-network'),
    onToggleExpanded: filter.toggleFor('automation-network'),
    palette: palette,
    child: SettingsSpacedColumn(
      children: [
        if (filter.showItem('automation-port'))
          _AutomationPortSection(
            controller: portController,
            enabled: driver.isSupported && !driver.isRunning,
            isRunning: driver.isRunning,
            errorText: portError,
            palette: palette,
            onChanged: onPortInput,
            onSubmitted: onPortInput,
          ),
        if (filter.showItem('automation-password'))
          _AutomationPasswordSection(
            controller: passwordController,
            showPassword: showPassword,
            isSupported: driver.isSupported,
            hasEphemeralTokenOverride: driver.hasEphemeralTokenOverride,
            feedback: feedback,
            palette: palette,
            onToggleVisibility: onTogglePasswordVisibility,
            onCopy: onCopyPassword,
            onRegenerate: onRegeneratePassword,
          ),
      ],
    ),
  );
}

final class _AutomationScopePanel extends StatelessWidget {
  final AutomationDriverViewModel driver;
  final FtermOverlayPalette palette;
  final SettingsPanelFilter filter;

  const _AutomationScopePanel({
    required this.driver,
    required this.palette,
    required this.filter,
  });

  @override
  Widget build(BuildContext context) => BlenderSettingsPanel(
    id: 'automation-scope',
    title: 'Terminal Access Scope',
    categoryBreadcrumb: filter.categoryBreadcrumb,
    expanded: filter.panelExpanded('automation-scope'),
    onToggleExpanded: filter.toggleFor('automation-scope'),
    palette: palette,
    child: _AutomationPtyScopeSection(
      allowPty: driver.allowPty,
      enabled: driver.isSupported,
      palette: palette,
      onChanged: driver.setAllowPty,
    ),
  );
}

final class _AutomationEnableSection extends StatelessWidget {
  final bool isSupported;
  final bool isRunning;
  final bool isToggling;
  final int port;
  final FtermOverlayPalette palette;
  final ValueChanged<bool> onChanged;

  const _AutomationEnableSection({
    required this.isSupported,
    required this.isRunning,
    required this.isToggling,
    required this.port,
    required this.palette,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final (statusText, statusColor) = switch ((isSupported, isRunning)) {
      (false, _) => (
        'HTTP automation driver is only available on desktop builds.',
        palette.muted,
      ),
      (true, true) => ('Listening on 127.0.0.1:$port', palette.accent),
      (true, false) => (
        'Stopped — loopback 127.0.0.1 only; resets off on restart.',
        palette.muted,
      ),
    };
    return BlenderCheckboxRow(
      label: 'Enable HTTP Driver',
      caption: statusText,
      captionColor: statusColor,
      captionKey: const ValueKey('automation-status-label'),
      controlKey: const ValueKey('automation-enable-switch'),
      value: isRunning,
      palette: palette,
      onChanged: isSupported && !isToggling ? onChanged : null,
    );
  }
}

final class _AutomationErrorBanner extends StatelessWidget {
  final String message;
  final FtermOverlayPalette palette;

  const _AutomationErrorBanner({required this.message, required this.palette});

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('automation-error-banner'),
    padding: const .symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: palette.danger.withValues(alpha: 0.14),
      borderRadius: .circular(6),
      border: .all(color: palette.danger.withValues(alpha: 0.6)),
    ),
    child: Row(
      crossAxisAlignment: .start,
      children: [
        Icon(Icons.error_outline, size: 16, color: palette.danger),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: TextStyle(color: palette.danger, fontSize: 11),
          ),
        ),
      ],
    ),
  );
}

final class _AutomationPortSection extends StatelessWidget {
  final TextEditingController controller;
  final bool enabled;
  final bool isRunning;
  final String? errorText;
  final FtermOverlayPalette palette;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  const _AutomationPortSection({
    required this.controller,
    required this.enabled,
    required this.isRunning,
    required this.errorText,
    required this.palette,
    required this.onChanged,
    required this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) => BlenderPropertyRow(
    label: 'Loopback Port',
    palette: palette,
    hint: errorText == null
        ? null
        : Text(
            errorText!,
            key: const ValueKey('automation-port-error'),
            style: TextStyle(color: palette.danger, fontSize: 11),
          ),
    control: Row(
      children: [
        Text(
          '127.0.0.1 :',
          style: TextStyle(color: palette.foreground, fontSize: 11.5),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 110,
          child: TextField(
            key: const ValueKey('automation-port-field'),
            controller: controller,
            enabled: enabled,
            keyboardType: .number,
            style: TextStyle(color: palette.foreground, fontSize: 11.5),
            decoration: blenderInputDecoration(
              palette: palette,
              hintText: '${AutomationDriverConfig.defaultPort}',
            ),
            onChanged: onChanged,
            onSubmitted: onSubmitted,
          ),
        ),
        if (isRunning) ...[
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Stop driver to edit port',
              style: TextStyle(color: palette.muted, fontSize: 10.5),
            ),
          ),
        ],
      ],
    ),
  );
}

final class _AutomationPasswordSection extends StatelessWidget {
  final TextEditingController controller;
  final bool showPassword;
  final bool isSupported;
  final bool hasEphemeralTokenOverride;
  final _PasswordFeedback feedback;
  final FtermOverlayPalette palette;
  final VoidCallback onToggleVisibility;
  final VoidCallback onCopy;
  final VoidCallback onRegenerate;

  const _AutomationPasswordSection({
    required this.controller,
    required this.showPassword,
    required this.isSupported,
    required this.hasEphemeralTokenOverride,
    required this.feedback,
    required this.palette,
    required this.onToggleVisibility,
    required this.onCopy,
    required this.onRegenerate,
  });

  String? get _feedbackText => switch (feedback) {
    .none => null,
    .copiedPassword => 'Password copied to clipboard.',
    .copiedHeader => 'Copied URL and Authorization header.',
    .regenerated => 'Password regenerated.',
  };

  Widget _buildHint() {
    if (_feedbackText case final message?) {
      return Text(
        message,
        key: const ValueKey('automation-password-feedback'),
        style: TextStyle(color: palette.accent, fontSize: 10.5),
      );
    }
    if (hasEphemeralTokenOverride) {
      return Text(
        'Using ephemeral token from FTERM_AUTOMATION_TOKEN.',
        key: const ValueKey('automation-ephemeral-token-hint'),
        style: TextStyle(color: palette.warning, fontSize: 10.5),
      );
    }
    return Text(
      'Shift+click Copy to copy base URL and Authorization header.',
      style: TextStyle(color: palette.muted, fontSize: 10),
    );
  }

  @override
  Widget build(BuildContext context) {
    final copyConfirmed =
        feedback == .copiedPassword || feedback == .copiedHeader;
    final regenEnabled = isSupported && !hasEphemeralTokenOverride;
    final regenTooltip = hasEphemeralTokenOverride
        ? 'Disabled while FTERM_AUTOMATION_TOKEN environment override is active'
        : 'Regenerate password';
    return BlenderPropertyRow(
      label: 'Bearer Password',
      palette: palette,
      hint: _buildHint(),
      control: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('automation-password-field'),
              controller: controller,
              readOnly: true,
              obscureText: !showPassword,
              style: TextStyle(color: palette.foreground, fontSize: 11.5),
              decoration: blenderInputDecoration(palette: palette),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            key: const ValueKey('automation-password-visibility-btn'),
            visualDensity: .compact,
            tooltip: showPassword ? 'Hide password' : 'Show password',
            icon: Icon(
              showPassword
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              size: 16,
            ),
            onPressed: onToggleVisibility,
          ),
          IconButton(
            key: const ValueKey('automation-password-copy-btn'),
            visualDensity: .compact,
            tooltip: 'Copy password (Shift+click to copy URL & Authorization header)',
            icon: Icon(
              copyConfirmed ? Icons.check : Icons.content_copy_outlined,
              size: 16,
              color: copyConfirmed ? palette.accent : null,
            ),
            onPressed: onCopy,
          ),
          IconButton(
            key: const ValueKey('automation-password-regen-btn'),
            visualDensity: .compact,
            tooltip: regenTooltip,
            icon: const Icon(Icons.refresh, size: 16),
            onPressed: regenEnabled ? onRegenerate : null,
          ),
        ],
      ),
    );
  }
}

final class _AutomationPtyScopeSection extends StatelessWidget {
  final bool allowPty;
  final bool enabled;
  final FtermOverlayPalette palette;
  final ValueChanged<bool> onChanged;

  const _AutomationPtyScopeSection({
    required this.allowPty,
    required this.enabled,
    required this.palette,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => SettingsSpacedColumn(
    spacing: 8,
    children: [
      BlenderCheckboxRow(
        label: 'Allow PTY Access',
        caption: 'Allow PTY input, shell spawning & screen readback',
        controlKey: const ValueKey('automation-allow-pty-checkbox'),
        value: allowPty,
        palette: palette,
        onChanged: enabled ? onChanged : null,
      ),
      Container(
        key: const ValueKey('automation-pty-warning'),
        padding: const .symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: palette.warning.withValues(alpha: 0.12),
          borderRadius: .circular(6),
          border: .all(color: palette.warning.withValues(alpha: 0.45)),
        ),
        child: Row(
          crossAxisAlignment: .start,
          children: [
            Icon(Icons.warning_amber_rounded, size: 15, color: palette.warning),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Warning: Enabling PTY access lets local clients with the '
                'Bearer token type into shells, spawn commands, send mouse '
                'input, and read visible terminal text. Resets off on restart.',
                style: TextStyle(color: palette.warning, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}
