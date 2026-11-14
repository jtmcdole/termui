import 'dart:async';
import 'dart:math';

import 'package:termui/termui.dart';

import 'dialog_theme.dart';

/// Pure-Dart `termui` modal dialog listing all `Ctrl+\` leader chords and
/// workspace shortcuts.
final class ChordsHelpDialog extends StatelessWidget {
  static const String _leaderLine =
      r'Leader: Ctrl+\ (press twice to send literal 0x1c)';

  static const List<String> _chordLines = [
    r'  Ctrl+\ c                  Open connection dialog',
    r'  Ctrl+\ n / ] / Tab        Switch to next session',
    r'  Ctrl+\ p / [ / Shift+Tab  Switch to previous session',
    r'  Ctrl+\ 1 .. 9             Jump to session 1..9',
    r'  Ctrl+\ r / Double-Click   Rename active live tab',
    r'  Ctrl+\ x / [x]            Dismiss ended session tab',
    r'  Ctrl+\ d / Space          Cycle dock (top/left/hidden)',
    r'  Ctrl+\ y / Cmd+C          Copy active selection',
    r'  Ctrl+\ v / Cmd+V          Paste from clipboard',
    r'  Ctrl+\ o                  Toggle copy-on-select',
    '  Drag / Shift+Drag         Select text (Alt = box mode)',
    '  Shift+Wheel / PgUp/Dn     Scroll/page primary history',
    r'  Arrows / Esc / Ctrl+\ g   Pan/scroll or exit history',
    r'  Ctrl+\ s / i              Open Stats for Nerds',
    r'  Ctrl+\ ,                  Open Settings dialog',
    r'  Ctrl+\ t                  Cycle color theme preset',
    r'  Ctrl+\ ? / h              Open Chords Help dialog',
  ];

  static const String _closeHintLine = 'Enter / Esc / q / ? / h: close';

  /// Creates a chords help modal dialog widget.
  const ChordsHelpDialog({super.key});

  /// Displays a centered [ChordsHelpDialog] on [sceneManager] and completes
  /// when dismissed via `Enter`, `Escape`, `q`, `?`, `h`, button press, or
  /// clicking the backdrop barrier.
  static Future<void> show(
    SceneManager sceneManager, {
    TerminalColorTheme? terminalTheme,
    WorkspaceChromeTheme? chromeTheme,
    Color? barrierColor,
    Color? defaultForeground,
    Color? defaultBackground,
    bool barrierDismissible = true,
  }) async {
    final size = clampDialogSize(
      sceneManager.terminal.backend.size,
      preferredWidth: 64,
      minWidth: 24,
      preferredHeight: 24,
      verticalMargin: 0,
    );
    await showThemedDialog<void>(
      sceneManager,
      width: size.x,
      height: size.y,
      terminalTheme: terminalTheme,
      chromeTheme: chromeTheme,
      barrierColor: barrierColor,
      defaultForeground: defaultForeground,
      defaultBackground: defaultBackground,
      barrierDismissible: barrierDismissible,
      builder: (_) => const ChordsHelpDialog(),
    );
  }

  static void _dismiss(BuildContext context) {
    PromptScope.of(context)?.done();
  }

  static List<Widget> _buildBodyRows(WorkspaceChromeTheme chrome) => [
    Text(_leaderLine, style: chrome.buttonStyle, wrap: false),
    for (final line in _chordLines)
      Text(line, style: chrome.rowStyle, wrap: false),
    Text(_closeHintLine, style: chrome.hintStyle, wrap: false),
  ];

  @override
  Widget build(BuildContext context) {
    final chrome = WorkspaceChromeScope.of(context);
    final rows = _buildBodyRows(chrome);
    return DecoratedBox(
      decoration: chrome.panelDecoration,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final verticalPadding = constraints.maxHeight >= 25 ? 1 : 0;
          return Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 2,
              vertical: verticalPadding,
            ),
            child: FocusScope(
              autofocus: true,
              onKeyEvent: (event) {
                if (_isDismissKey(event)) {
                  _dismiss(context);
                  return true;
                }
                return false;
              },
              child: Column([
                Text(
                  'TermUI Caster - Leader Chords & Shortcuts',
                  style: chrome.titleStyle,
                  wrap: false,
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (_, innerConstraints) {
                      final budget = max(0, innerConstraints.maxHeight);
                      return Column([
                        for (var i = 0; i < rows.length && i < budget; i++)
                          rows[i],
                      ], crossAxisAlignment: .stretch);
                    },
                  ),
                ),
                Button(
                  text: 'Close (Enter)',
                  focused: true,
                  onPressed: () => _dismiss(context),
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

  static bool _isDismissKey(KeyEvent event) {
    if (event.type == .enter) return true;
    if (event.type != .character) return false;
    final key = event.key.toLowerCase();
    return key == 'q' || key == '?' || key == '/' || key == 'h';
  }
}
