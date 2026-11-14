import 'dart:async';

import 'package:termui/termui.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';

import '../models.dart';
import 'dialog_theme.dart';

/// Pure-Dart `termui` modal dialog collecting a validated `ws://` / `wss://`
/// server endpoint and masked bearer token with `Tab` / `Shift+Tab` focus traversal.
final class ConnectionPromptDialog extends StatefulWidget {
  /// Initial server URL pre-populated in the URL field.
  final String initialServerUrl;

  /// Initial bearer token pre-populated in the token field.
  final String initialToken;

  /// Optional initial authentication or connection error displayed on open.
  final String? initialError;

  /// Invoked with the validated [CastEndpoint] when submitted.
  final void Function(CastEndpoint endpoint) onSubmit;

  /// Creates an interactive connection prompt dialog widget.
  const ConnectionPromptDialog({
    super.key,
    this.initialServerUrl = defaultClientServerUrl,
    this.initialToken = '',
    this.initialError,
    required this.onSubmit,
  });

  /// Displays a centered [ConnectionPromptDialog] on [sceneManager] and
  /// resolves with the submitted [CastEndpoint] (or `null` if [barrierDismissible]
  /// is `true` and dismissed via `Escape` or clicking the backdrop barrier).
  static Future<CastEndpoint?> show(
    SceneManager sceneManager, {
    String initialServerUrl = defaultClientServerUrl,
    String initialToken = '',
    String? initialError,
    TerminalColorTheme? terminalTheme,
    WorkspaceChromeTheme? chromeTheme,
    Color? barrierColor,
    Color? defaultForeground,
    Color? defaultBackground,
    bool barrierDismissible = true,
  }) {
    final size = clampDialogSize(
      sceneManager.terminal.backend.size,
      preferredWidth: 64,
      minWidth: 36,
      horizontalMargin: 6,
      preferredHeight: 15,
      minHeight: 15,
      verticalMargin: 0,
    );
    return showThemedDialog<CastEndpoint>(
      sceneManager,
      width: size.x,
      height: size.y,
      terminalTheme: terminalTheme,
      chromeTheme: chromeTheme,
      barrierColor: barrierColor,
      defaultForeground: defaultForeground,
      defaultBackground: defaultBackground,
      barrierDismissible: barrierDismissible,
      builder: (context) => ConnectionPromptDialog(
        initialServerUrl: initialServerUrl,
        initialToken: initialToken,
        initialError: initialError,
        onSubmit: (endpoint) => PromptScope.of(context)?.done(endpoint),
      ),
    );
  }

  @override
  State<ConnectionPromptDialog> createState() => _ConnectionPromptDialogState();
}

final class _ConnectionPromptDialogState extends State<ConnectionPromptDialog> {
  late final TextEditingController _serverCtrl;
  late final TextEditingController _tokenCtrl;
  late final FocusNode _serverFocus;
  late final FocusNode _tokenFocus;
  bool _initialFocusPending = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _errorMessage = widget.initialError;
    _serverCtrl = TextEditingController(text: widget.initialServerUrl)
      ..addListener(_clearErrorOnEdit);
    _tokenCtrl = TextEditingController(text: widget.initialToken)
      ..addListener(_clearErrorOnEdit);
    _serverFocus = FocusNode(id: 'connection_server_url');
    _tokenFocus = FocusNode(id: 'connection_bearer_token');
  }

  @override
  void dispose() {
    _serverCtrl.removeListener(_clearErrorOnEdit);
    _tokenCtrl.removeListener(_clearErrorOnEdit);
    _serverFocus.dispose();
    _tokenFocus.dispose();
    super.dispose();
  }

  void _clearErrorOnEdit() {
    if (_errorMessage != null && mounted) {
      setState(() {
        _errorMessage = null;
      });
    }
  }

  void _onFieldFocusChanged(bool _) {
    _initialFocusPending = false;
    if (mounted) {
      setState(() {});
    }
  }

  void _submit() {
    try {
      final parsedUri = parseCastWebSocketUri(
        _serverCtrl.text,
        defaultPath: '/v1/client',
        normalizeCasterPath: true,
      );
      widget.onSubmit((serverUri: parsedUri, token: _tokenCtrl.text.trim()));
    } on FormatException {
      setState(() {
        _errorMessage = 'Invalid URL: enter a ws:// or wss:// host.';
      });
    }
  }

  Widget _buildHeader(
    WorkspaceChromeTheme chrome,
    String? statusLine, {
    required bool showHint,
  }) {
    if (statusLine != null && !showHint) {
      return SizedBox(
        height: 1,
        child: Text(statusLine, style: chrome.inlineErrorStyle),
      );
    }
    return Text('TermUI Caster Viewer', style: chrome.titleStyle);
  }

  Widget _buildStatusOrHint(WorkspaceChromeTheme chrome, String? statusLine) {
    if (statusLine != null) {
      return SizedBox(
        height: 1,
        child: Text(statusLine, style: chrome.inlineErrorStyle),
      );
    }
    return SizedBox(
      height: 1,
      child: Text(
        'Tab: switch | Enter: connect | Esc: dismiss',
        style: chrome.hintStyle,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chrome = WorkspaceChromeScope.of(context);
    final statusLine = _errorMessage;
    return DecoratedBox(
      decoration: chrome.panelDecoration,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxH = constraints.maxHeight;
          final verticalPadding = maxH >= 13 ? 1 : 0;
          final showLabels = maxH >= 11;
          final showHint = maxH >= 9;
          return Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 2,
              vertical: verticalPadding,
            ),
            child: FocusScope(
              onKeyEvent: (event) {
                if (event.type == .enter) {
                  _submit();
                  return true;
                }
                return false;
              },
              child: Column([
                _buildHeader(chrome, statusLine, showHint: showHint),
                if (showLabels)
                  Text('Server WebSocket URL:', style: chrome.labelStyle),
                DialogInputField(
                  controller: _serverCtrl,
                  focusNode: _serverFocus,
                  isFocused: _initialFocusPending || _serverFocus.hasFocus,
                  onFocusChange: _onFieldFocusChanged,
                ),
                if (showLabels)
                  Text('Bearer Token (optional):', style: chrome.labelStyle),
                DialogInputField(
                  controller: _tokenCtrl,
                  focusNode: _tokenFocus,
                  obscureText: true,
                  placeholder: '(none)',
                  isFocused: _tokenFocus.hasFocus,
                  onFocusChange: _onFieldFocusChanged,
                ),
                if (showHint) _buildStatusOrHint(chrome, statusLine),
                Button(
                  text: 'Connect (Enter)',
                  onPressed: _submit,
                  style: chrome.buttonStyle,
                  focusedStyle: chrome.focusedButtonStyle,
                ),
              ], crossAxisAlignment: .stretch),
            ),
          );
        },
      ),
    );
  }
}
