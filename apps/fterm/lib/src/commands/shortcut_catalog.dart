import 'package:flutter/services.dart' show LogicalKeyboardKey;

import 'fterm_shortcut_spec.dart';

/// Canonical single source of truth for `fterm` keyboard shortcuts shared
/// across Shortcut Dispatcher, Command Palette hints, and the Help overlay.
abstract final class FtermShortcuts {
  /// Opens or toggles the VS Code-style Command Palette (`>` mode).
  static const FtermShortcutBinding commandPalette = FtermShortcutBinding(
    macDesktopLabel: 'Cmd+Shift+P',
    linuxWinDesktopLabel: 'Ctrl+Shift+P',
    leaderChordLabel: r'Ctrl+\ Shift+P',
    macDesktopStroke: FtermKeyStroke(
      LogicalKeyboardKey.keyP,
      meta: true,
      shift: true,
    ),
    linuxWinDesktopStroke: FtermKeyStroke(
      LogicalKeyboardKey.keyP,
      ctrl: true,
      shift: true,
    ),
    leaderChord: FtermLeaderChord(LogicalKeyboardKey.keyP, requireShift: true),
    desktopOnlyHint: true,
  );

  /// Opens a new local desktop shell tab.
  static const FtermShortcutBinding newLocalShell = FtermShortcutBinding(
    macDesktopLabel: 'Cmd+T',
    linuxWinDesktopLabel: 'Ctrl+Shift+T',
    macDesktopStroke: FtermKeyStroke(LogicalKeyboardKey.keyT, meta: true),
    linuxWinDesktopStroke: FtermKeyStroke(
      LogicalKeyboardKey.keyT,
      ctrl: true,
      shift: true,
    ),
    desktopOnlyHint: true,
  );

  /// Opens the Sessions & Shells picker overlay.
  static const FtermShortcutBinding sessionsPicker = FtermShortcutBinding(
    leaderChordLabel: r'Ctrl+\ c',
    leaderChord: FtermLeaderChord(LogicalKeyboardKey.keyC),
  );

  /// Splits the focused pane horizontally (left | right).
  static const FtermShortcutBinding splitRight = FtermShortcutBinding(
    macDesktopLabel: 'Cmd+D',
    linuxWinDesktopLabel: 'Ctrl+Shift+D',
    leaderChordLabel: r'Ctrl+\ |',
    macDesktopStroke: FtermKeyStroke(LogicalKeyboardKey.keyD, meta: true),
    linuxWinDesktopStroke: FtermKeyStroke(
      LogicalKeyboardKey.keyD,
      ctrl: true,
      shift: true,
    ),
    leaderChord: FtermLeaderChord(
      LogicalKeyboardKey.bar,
      alternateKeys: <LogicalKeyboardKey>[LogicalKeyboardKey.percent],
      shiftedKeys: <LogicalKeyboardKey>[
        LogicalKeyboardKey.backslash,
        LogicalKeyboardKey.digit5,
      ],
      characters: <String>['|', '%'],
    ),
    desktopOnlyHint: true,
  );

  /// Splits the focused pane vertically (top / bottom).
  static const FtermShortcutBinding splitDown = FtermShortcutBinding(
    macDesktopLabel: 'Cmd+Shift+D',
    linuxWinDesktopLabel: 'Ctrl+Shift+E',
    leaderChordLabel: r'Ctrl+\ -',
    macDesktopStroke: FtermKeyStroke(
      LogicalKeyboardKey.keyD,
      meta: true,
      shift: true,
    ),
    linuxWinDesktopStroke: FtermKeyStroke(
      LogicalKeyboardKey.keyE,
      ctrl: true,
      shift: true,
    ),
    leaderChord: FtermLeaderChord(
      LogicalKeyboardKey.minus,
      alternateKeys: <LogicalKeyboardKey>[LogicalKeyboardKey.quote],
      shiftedKeys: <LogicalKeyboardKey>[LogicalKeyboardKey.quoteSingle],
      characters: <String>['-', '"'],
    ),
    desktopOnlyHint: true,
  );

  /// Moves pane focus to the adjacent left pane.
  static const FtermShortcutBinding focusLeft = FtermShortcutBinding(
    leaderChordLabel: r'Ctrl+\ h',
    leaderChord: FtermLeaderChord(
      LogicalKeyboardKey.keyH,
      alternateKeys: <LogicalKeyboardKey>[LogicalKeyboardKey.arrowLeft],
    ),
  );

  /// Moves pane focus to the adjacent lower pane.
  static const FtermShortcutBinding focusDown = FtermShortcutBinding(
    leaderChordLabel: r'Ctrl+\ j',
    leaderChord: FtermLeaderChord(
      LogicalKeyboardKey.keyJ,
      alternateKeys: <LogicalKeyboardKey>[LogicalKeyboardKey.arrowDown],
    ),
  );

  /// Moves pane focus to the adjacent upper pane.
  static const FtermShortcutBinding focusUp = FtermShortcutBinding(
    leaderChordLabel: r'Ctrl+\ k',
    leaderChord: FtermLeaderChord(
      LogicalKeyboardKey.keyK,
      alternateKeys: <LogicalKeyboardKey>[LogicalKeyboardKey.arrowUp],
    ),
  );

  /// Moves pane focus to the adjacent right pane.
  static const FtermShortcutBinding focusRight = FtermShortcutBinding(
    leaderChordLabel: r'Ctrl+\ l',
    leaderChord: FtermLeaderChord(
      LogicalKeyboardKey.keyL,
      alternateKeys: <LogicalKeyboardKey>[LogicalKeyboardKey.arrowRight],
    ),
  );

  /// Toggles focused pane zoom inside the active split tree.
  static const FtermShortcutBinding toggleZoom = FtermShortcutBinding(
    leaderChordLabel: r'Ctrl+\ z',
    leaderChord: FtermLeaderChord(LogicalKeyboardKey.keyZ),
  );

  /// Toggles local pane relay broadcast sharing.
  static const FtermShortcutBinding togglePaneShare = FtermShortcutBinding(
    leaderChordLabel: r'Ctrl+\ b',
    leaderChord: FtermLeaderChord(LogicalKeyboardKey.keyB),
  );

  /// Closes the focused pane (or tab when it is the last pane).
  static const FtermShortcutBinding closePane = FtermShortcutBinding(
    macDesktopLabel: 'Cmd+W',
    linuxWinDesktopLabel: 'Ctrl+Shift+W',
    leaderChordLabel: r'Ctrl+\ x',
    macDesktopStroke: FtermKeyStroke(LogicalKeyboardKey.keyW, meta: true),
    linuxWinDesktopStroke: FtermKeyStroke(
      LogicalKeyboardKey.keyW,
      ctrl: true,
      shift: true,
    ),
    leaderChord: FtermLeaderChord(LogicalKeyboardKey.keyX),
    desktopOnlyHint: true,
  );

  /// Switches to the next workspace tab.
  static const FtermShortcutBinding nextTab = FtermShortcutBinding(
    leaderChordLabel: r'Ctrl+\ n',
    leaderChord: FtermLeaderChord(LogicalKeyboardKey.keyN),
  );

  /// Switches to the previous workspace tab (unshifted `p`).
  static const FtermShortcutBinding previousTab = FtermShortcutBinding(
    leaderChordLabel: r'Ctrl+\ p',
    leaderChord: FtermLeaderChord(LogicalKeyboardKey.keyP, forbidShift: true),
  );

  /// Opens the tab rename / clear-pin dialog.
  static const FtermShortcutBinding renameTab = FtermShortcutBinding(
    leaderChordLabel: r'Ctrl+\ r',
    leaderChord: FtermLeaderChord(LogicalKeyboardKey.keyR),
  );

  /// Cycles tab bar dock placement (`top -> left -> hidden`).
  static const FtermShortcutBinding cycleDockPosition = FtermShortcutBinding(
    leaderChordLabel: r'Ctrl+\ d',
    leaderChord: FtermLeaderChord(
      LogicalKeyboardKey.keyD,
      alternateKeys: <LogicalKeyboardKey>[LogicalKeyboardKey.space],
    ),
  );

  /// Increases terminal font size by one step.
  static const FtermShortcutBinding fontIncrease = FtermShortcutBinding(
    macDesktopLabel: 'Cmd+=',
    linuxWinDesktopLabel: 'Ctrl+=',
    macDesktopStroke: FtermKeyStroke(LogicalKeyboardKey.equal, meta: true),
    linuxWinDesktopStroke: FtermKeyStroke(LogicalKeyboardKey.equal, ctrl: true),
  );

  /// Decreases terminal font size by one step.
  static const FtermShortcutBinding fontDecrease = FtermShortcutBinding(
    macDesktopLabel: 'Cmd+-',
    linuxWinDesktopLabel: 'Ctrl+-',
    macDesktopStroke: FtermKeyStroke(LogicalKeyboardKey.minus, meta: true),
    linuxWinDesktopStroke: FtermKeyStroke(LogicalKeyboardKey.minus, ctrl: true),
  );

  /// Resets terminal font size to the workspace default.
  static const FtermShortcutBinding fontReset = FtermShortcutBinding(
    macDesktopLabel: 'Cmd+0',
    linuxWinDesktopLabel: 'Ctrl+0',
    macDesktopStroke: FtermKeyStroke(LogicalKeyboardKey.digit0, meta: true),
    linuxWinDesktopStroke: FtermKeyStroke(
      LogicalKeyboardKey.digit0,
      ctrl: true,
    ),
  );

  /// Opens a new live GLSL Shader Editor tab.
  static const FtermShortcutBinding openShaderEditorTab = FtermShortcutBinding(
    leaderChordLabel: r'Ctrl+\ e',
    leaderChord: FtermLeaderChord(LogicalKeyboardKey.keyE),
  );

  /// Saves the active GLSL shader in the focused shader editor tab.
  static const FtermShortcutBinding saveShader = FtermShortcutBinding(
    macDesktopLabel: 'Cmd+S',
    linuxWinDesktopLabel: 'Alt+S',
    macDesktopStroke: FtermKeyStroke(LogicalKeyboardKey.keyS, meta: true),
    linuxWinDesktopStroke: FtermKeyStroke(LogicalKeyboardKey.keyS, alt: true),
    desktopOnlyHint: true,
  );

  /// Opens the Save As prompt for the active GLSL shader in the editor tab.
  static const FtermShortcutBinding saveShaderAs = FtermShortcutBinding(
    macDesktopLabel: 'Cmd+Shift+S',
    linuxWinDesktopLabel: 'Alt+Shift+S',
    macDesktopStroke: FtermKeyStroke(
      LogicalKeyboardKey.keyS,
      meta: true,
      shift: true,
    ),
    linuxWinDesktopStroke: FtermKeyStroke(
      LogicalKeyboardKey.keyS,
      alt: true,
      shift: true,
    ),
    desktopOnlyHint: true,
  );

  /// Reloads and recompiles custom fragment shaders from disk (Desktop).
  static const FtermShortcutBinding reloadShaders = FtermShortcutBinding(
    macDesktopLabel: 'Ctrl+Shift+F5',
    linuxWinDesktopLabel: 'Ctrl+Shift+F5',
    universalDesktopStroke: FtermKeyStroke(
      LogicalKeyboardKey.f5,
      ctrl: true,
      shift: true,
    ),
    desktopOnlyHint: true,
  );

  /// Emergency-stops or resumes GPU fragment shaders (Desktop & Web).
  static const FtermShortcutBinding emergencyStopShaders = FtermShortcutBinding(
    macDesktopLabel: 'Ctrl+Shift+F6',
    linuxWinDesktopLabel: 'Ctrl+Shift+F6',
    leaderChordLabel: r'Ctrl+\ 0',
    universalDesktopStroke: FtermKeyStroke(
      LogicalKeyboardKey.f6,
      ctrl: true,
      shift: true,
    ),
    leaderChord: FtermLeaderChord(
      LogicalKeyboardKey.digit0,
      alternateKeys: <LogicalKeyboardKey>[LogicalKeyboardKey.numpad0],
    ),
  );

  /// Toggles the floating Performance & GPU Diagnostics HUD (Desktop).
  static const FtermShortcutBinding togglePerfHud = FtermShortcutBinding(
    macDesktopLabel: 'Ctrl+Shift+F9',
    linuxWinDesktopLabel: 'Ctrl+Shift+F9',
    universalDesktopStroke: FtermKeyStroke(
      LogicalKeyboardKey.f9,
      ctrl: true,
      shift: true,
    ),
    desktopOnlyHint: true,
  );

  /// Toggles Perfetto trace recording (Desktop).
  static const FtermShortcutBinding toggleTraceRecording = FtermShortcutBinding(
    macDesktopLabel: 'Ctrl+Shift+F10',
    linuxWinDesktopLabel: 'Ctrl+Shift+F10',
    universalDesktopStroke: FtermKeyStroke(
      LogicalKeyboardKey.f10,
      ctrl: true,
      shift: true,
    ),
    desktopOnlyHint: true,
  );

  /// Opens the Blender-style Settings overlay.
  static const FtermShortcutBinding openSettings = FtermShortcutBinding(
    leaderChordLabel: r'Ctrl+\ ,',
    macDesktopStroke: FtermKeyStroke(LogicalKeyboardKey.comma, meta: true),
    linuxWinDesktopStroke: FtermKeyStroke(
      LogicalKeyboardKey.comma,
      ctrl: true,
      shift: true,
    ),
    leaderChord: FtermLeaderChord(
      LogicalKeyboardKey.comma,
      characters: <String>[','],
    ),
    desktopOnlyHint: true,
  );

  /// Opens the Session Stats telemetry overlay.
  static const FtermShortcutBinding openStats = FtermShortcutBinding(
    leaderChordLabel: r'Ctrl+\ i',
    leaderChord: FtermLeaderChord(LogicalKeyboardKey.keyI),
  );

  /// Opens the Keyboard Shortcuts help overlay.
  static const FtermShortcutBinding openHelp = FtermShortcutBinding(
    leaderChordLabel: r'Ctrl+\ ?',
    leaderChord: FtermLeaderChord(
      LogicalKeyboardKey.question,
      shiftedKeys: <LogicalKeyboardKey>[LogicalKeyboardKey.slash],
      characters: <String>['?'],
    ),
  );

  /// Opens the About `fterm` overlay.
  static const FtermShortcutBinding openAbout = FtermShortcutBinding(
    leaderChordLabel: r'Ctrl+\ a',
    leaderChord: FtermLeaderChord(LogicalKeyboardKey.keyA),
  );
}

final List<HelpShortcutEntry> _canonicalHelpShortcutEntries =
    List<HelpShortcutEntry>.unmodifiable(<HelpShortcutEntry>[
      (
        keys:
            '${FtermShortcuts.commandPalette.linuxWinDesktopLabel} / '
            '${FtermShortcuts.commandPalette.macDesktopLabel}',
        description: 'Command Palette (>, :, %, Quick Switch)',
      ),
      (
        keys: r'Ctrl+\ then Shift+P',
        description: 'Command Palette (Desktop & Web)',
      ),
      (keys: r'Ctrl+\ then | or %', description: 'Split pane left | right'),
      (keys: r'Ctrl+\ then - or "', description: 'Split pane top / bottom'),
      (
        keys: r'Ctrl+\ then h j k l / Arrows',
        description: 'Focus adjacent split pane',
      ),
      (keys: r'Ctrl+\ then z', description: 'Toggle pane zoom'),
      (keys: r'Ctrl+\ then b', description: 'Toggle local pane relay share'),
      (keys: r'Ctrl+\ then c', description: 'Sessions & Shells picker'),
      (keys: r'Ctrl+\ then n / p / 1..9', description: 'Next / Prev / Nth tab'),
      (keys: r'Ctrl+\ then r', description: 'Rename tab or clear title pin'),
      (keys: r'Ctrl+\ then x', description: 'Close focused pane / tab'),
      (
        keys: r'Ctrl+\ then d / Space',
        description: 'Cycle tab bar (top -> left -> hidden)',
      ),
      (keys: r'Ctrl+\ then e', description: 'Open GLSL Shader Editor tab'),
      (
        keys:
            '${FtermShortcuts.saveShader.linuxWinDesktopLabel} / '
            '${FtermShortcuts.saveShader.macDesktopLabel} (Shift: As)',
        description: 'Save active GLSL shader in editor',
      ),
      (
        keys: r'Ctrl+\ then , / i / ? / a',
        description: 'Settings / Stats / Help / About',
      ),
      (
        keys: 'Cmd+T/W/D/Shift+D/1..9',
        description: 'Native macOS Desktop shortcuts',
      ),
      (
        keys:
            '${FtermShortcuts.fontIncrease.macDesktopLabel} / '
            '${FtermShortcuts.fontDecrease.macDesktopLabel} / '
            '${FtermShortcuts.fontReset.macDesktopLabel}',
        description: 'Zoom font in / out / reset (macOS)',
      ),
      (
        keys: 'Ctrl+Shift+T/W/D/E',
        description: 'Native Linux / Windows shortcuts',
      ),
      (
        keys:
            '${FtermShortcuts.fontIncrease.linuxWinDesktopLabel} / '
            '${FtermShortcuts.fontDecrease.linuxWinDesktopLabel} / '
            '${FtermShortcuts.fontReset.linuxWinDesktopLabel}',
        description: 'Zoom font in / out / reset (Linux/Win)',
      ),
      (
        keys: FtermShortcuts.reloadShaders.linuxWinDesktopLabel!,
        description: 'Reload custom fragment shaders (Desktop)',
      ),
      (
        keys:
            '${FtermShortcuts.emergencyStopShaders.linuxWinDesktopLabel} / '
            '${FtermShortcuts.emergencyStopShaders.leaderChordLabel}',
        description: 'Emergency Stop / Resume GPU shaders',
      ),
      (
        keys: FtermShortcuts.togglePerfHud.linuxWinDesktopLabel!,
        description: 'Toggle Performance HUD (Desktop)',
      ),
      (
        keys: FtermShortcuts.toggleTraceRecording.linuxWinDesktopLabel!,
        description: 'Toggle Perfetto trace recording (Desktop)',
      ),
    ]);

/// Returns the canonical grouped Help overlay shortcut table derived from
/// [FtermShortcuts].
List<HelpShortcutEntry> buildHelpShortcutEntries() =>
    _canonicalHelpShortcutEntries;
