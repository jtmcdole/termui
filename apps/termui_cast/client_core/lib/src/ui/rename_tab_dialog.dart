import 'dart:async';

import 'package:termui/termui.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';

import 'dialog_theme.dart';

/// Pure-Dart `termui` modal dialog for renaming a live session tab.
///
/// Validates that the submitted title is non-empty after trimming, at most
/// [maxTitleGraphemes] user-perceived characters, at most [maxTitleUtf8Bytes]
/// UTF-8 bytes, and free of C0/C1 control characters and Unicode bidi overrides.
final class RenameTabDialog extends StatefulWidget {
  /// Maximum grapheme cluster length accepted by the rename input modal.
  static const int maxTitleGraphemes = maxSessionTitleGraphemes;

  /// Maximum UTF-8 byte length accepted by the wire protocol.
  static const int maxTitleUtf8Bytes = BufferFrameCodec.maxTitleBytes;

  static final RegExp _forbiddenChars = RegExp(
    r'[\x00-\x1F\x7F-\x9F\u202A-\u202E\u2066-\u2069]',
  );

  /// Initial tab title pre-populated in the text field.
  final String initialTitle;

  /// Callback invoked with the validated trimmed title on submission.
  final void Function(String newTitle) onSubmit;

  /// Creates an interactive tab rename modal dialog widget.
  const RenameTabDialog({
    super.key,
    required this.initialTitle,
    required this.onSubmit,
  });

  /// Validates and trims a raw session [input] string against UI and wire bounds.
  static SessionTitleValidation validateTitle(String input) =>
      validateSessionTitle(input);

  /// Displays a centered [RenameTabDialog] on [sceneManager] and resolves with
  /// the validated title string (or `null` when cancelled via `Escape` or barrier).
  static Future<String?> show(
    SceneManager sceneManager, {
    required String initialTitle,
    TerminalColorTheme? terminalTheme,
    WorkspaceChromeTheme? chromeTheme,
    Color? barrierColor,
    Color? defaultForeground,
    Color? defaultBackground,
    bool barrierDismissible = true,
  }) {
    final size = clampDialogSize(
      sceneManager.terminal.backend.size,
      preferredWidth: 56,
      minWidth: 32,
      horizontalMargin: 6,
      preferredHeight: 11,
      minHeight: 11,
      verticalMargin: 0,
    );
    return showThemedDialog<String>(
      sceneManager,
      width: size.x,
      height: size.y,
      terminalTheme: terminalTheme,
      chromeTheme: chromeTheme,
      barrierColor: barrierColor,
      defaultForeground: defaultForeground,
      defaultBackground: defaultBackground,
      barrierDismissible: barrierDismissible,
      builder: (context) => RenameTabDialog(
        initialTitle: initialTitle,
        onSubmit: (title) => PromptScope.of(context)?.done(title),
      ),
    );
  }

  @override
  State<RenameTabDialog> createState() => _RenameTabDialogState();
}

final class _RenameTabDialogState extends State<RenameTabDialog> {
  late final TextEditingController _titleCtrl;
  late final FocusNode _titleFocus;
  bool _initialFocusPending = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    final safeInitial = widget.initialTitle.replaceAll(
      RenameTabDialog._forbiddenChars,
      '',
    );
    _titleCtrl = TextEditingController(text: safeInitial)
      ..addListener(_clearErrorOnEdit);
    _titleFocus = FocusNode(id: 'rename_tab_title');
  }

  @override
  void dispose() {
    _titleCtrl.removeListener(_clearErrorOnEdit);
    _titleFocus.dispose();
    super.dispose();
  }

  void _clearErrorOnEdit() {
    if (_errorMessage != null && mounted) {
      setState(() {
        _errorMessage = null;
      });
    }
  }

  void _onFocusChanged(bool _) {
    _initialFocusPending = false;
    if (mounted) {
      setState(() {});
    }
  }

  void _submit() {
    final (:title, :error) = RenameTabDialog.validateTitle(_titleCtrl.text);
    if (title == null) {
      setState(() {
        _errorMessage = error;
      });
      return;
    }
    widget.onSubmit(title);
  }

  @override
  Widget build(BuildContext context) {
    final chrome = WorkspaceChromeScope.of(context);
    final isFocused = _initialFocusPending || _titleFocus.hasFocus;
    final statusLine = _errorMessage;
    return DecoratedBox(
      decoration: chrome.panelDecoration,
      child: Padding(
        padding: const .symmetric(horizontal: 2, vertical: 1),
        child: FocusScope(
          onKeyEvent: (event) {
            if (event.type == .enter) {
              _submit();
              return true;
            }
            return false;
          },
          child: Column([
            Text('Rename Session Tab', style: chrome.titleStyle),
            Text('New tab title:', style: chrome.labelStyle),
            DialogInputField(
              controller: _titleCtrl,
              focusNode: _titleFocus,
              isFocused: isFocused,
              onFocusChange: _onFocusChanged,
            ),
            if (statusLine != null)
              SizedBox(
                height: 1,
                child: Text(statusLine, style: chrome.inlineErrorStyle),
              )
            else
              SizedBox(
                height: 1,
                child: Text(
                  'Enter: rename | Esc: cancel',
                  style: chrome.hintStyle,
                ),
              ),
            Button(
              text: 'Rename (Enter)',
              onPressed: _submit,
              style: chrome.buttonStyle,
              focusedStyle: chrome.focusedButtonStyle,
            ),
          ], crossAxisAlignment: .stretch),
        ),
      ),
    );
  }
}
