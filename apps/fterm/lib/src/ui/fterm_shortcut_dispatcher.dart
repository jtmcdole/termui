import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart'
    show
        HardwareKeyboard,
        KeyDownEvent,
        KeyEvent,
        KeyRepeatEvent,
        LogicalKeyboardKey;
import 'package:termui/terminal/event.dart' as ev;

import '../workspace/fterm_workspace_controller.dart';
import '../workspace/split_tree_model.dart';

/// Dispatches `fterm` modal `Ctrl+\` chords, desktop OS shortcuts, and `F12`
/// capture/passthrough rules ahead of `TerminalSurface` IME encoding.
final class FtermShortcutDispatcher {
  static final Map<LogicalKeyboardKey, int> _digitIndices = {
    LogicalKeyboardKey.digit1: 0,
    LogicalKeyboardKey.digit2: 1,
    LogicalKeyboardKey.digit3: 2,
    LogicalKeyboardKey.digit4: 3,
    LogicalKeyboardKey.digit5: 4,
    LogicalKeyboardKey.digit6: 5,
    LogicalKeyboardKey.digit7: 6,
    LogicalKeyboardKey.digit8: 7,
    LogicalKeyboardKey.digit9: 8,
    LogicalKeyboardKey.numpad1: 0,
    LogicalKeyboardKey.numpad2: 1,
    LogicalKeyboardKey.numpad3: 2,
    LogicalKeyboardKey.numpad4: 3,
    LogicalKeyboardKey.numpad5: 4,
    LogicalKeyboardKey.numpad6: 5,
    LogicalKeyboardKey.numpad7: 6,
    LogicalKeyboardKey.numpad8: 7,
    LogicalKeyboardKey.numpad9: 8,
  };

  static final Set<LogicalKeyboardKey> _modifierKeys = {
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.meta,
    LogicalKeyboardKey.capsLock,
  };

  /// Backing workspace mutated by recognized shortcuts.
  final FtermWorkspaceController workspace;

  final TargetPlatform? _platformOverride;
  final bool? _isWebOverride;

  /// Creates a shortcut dispatcher bound to [workspace].
  const FtermShortcutDispatcher({
    required this.workspace,
    this._platformOverride,
    this._isWebOverride,
  });

  static const double _fontZoomStep = 1.0;

  TargetPlatform get _platform => _platformOverride ?? defaultTargetPlatform;
  bool get _isMacOs => _platform == TargetPlatform.macOS;
  bool get _isWeb => _isWebOverride ?? kIsWeb;

  /// Handles [event] with active [modifiers], returning `true` when the event
  /// was consumed as an `fterm` shortcut or handled F12 passthrough.
  bool handleHostShortcut(KeyEvent event, Set<ev.Modifier> modifiers) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return false;
    }
    if (event is KeyDownEvent && workspace.audioController.needsGestureUnlock) {
      unawaited(workspace.audioController.notifyUserGesture());
    }

    if (workspace.activeOverlay != FtermOverlay.none) {
      return _handleOverlayKeyEvent(event);
    }

    if (workspace.isLeaderArmed) {
      return _handleLeaderChord(event, modifiers);
    }

    if (_isCtrlBackslashLeader(event, modifiers)) {
      if (event is KeyDownEvent) {
        workspace.setLeaderArmed(true);
      }
      return true;
    }

    if (_handleFontZoomShortcut(event, modifiers)) {
      return true;
    }

    if (event is KeyDownEvent && _handleDesktopShortcut(event, modifiers)) {
      return true;
    }

    return _handleF12Gate(event, modifiers);
  }

  bool _handleOverlayKeyEvent(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      workspace.dismissOverlay();
      return true;
    }
    // Let modal controls, FocusTraversalGroup (Tab), and DefaultTextEditingShortcuts
    // handle overlay keys while workspace panes stay excluded via ExcludeFocus.
    return false;
  }

  bool _isCtrlBackslashLeader(KeyEvent event, Set<ev.Modifier> modifiers) {
    final ctrlOnly =
        modifiers.contains(ev.Modifier.control) &&
        !modifiers.contains(ev.Modifier.alt) &&
        !modifiers.contains(ev.Modifier.meta) &&
        !modifiers.contains(ev.Modifier.shift);
    if (!ctrlOnly) return false;
    return event.logicalKey == LogicalKeyboardKey.backslash ||
        event.character == '\x1c';
  }

  bool _handleLeaderChord(KeyEvent event, Set<ev.Modifier> modifiers) {
    if (_modifierKeys.contains(event.logicalKey)) {
      return true;
    }
    workspace.setLeaderArmed(false);
    if (event is! KeyDownEvent) return true;

    final key = event.logicalKey;
    final ch = event.character;
    final shift =
        modifiers.contains(ev.Modifier.shift) ||
        HardwareKeyboard.instance.isShiftPressed;

    if ((!shift && key == LogicalKeyboardKey.backslash) ||
        ch == '\\' ||
        ch == '\x1c') {
      workspace.focusedPane?.sendCommittedText('\x1c');
      return true;
    }
    if (key == LogicalKeyboardKey.escape) {
      return true;
    }
    if (_dispatchSplitOrFocusChord(key, ch, shift)) {
      return true;
    }
    if (_dispatchTabOrModalChord(key, ch, shift)) {
      return true;
    }
    return true;
  }

  bool _dispatchSplitOrFocusChord(
    LogicalKeyboardKey key,
    String? ch,
    bool shift,
  ) {
    final isHorizSplit =
        ch == '|' ||
        ch == '%' ||
        key == LogicalKeyboardKey.bar ||
        key == LogicalKeyboardKey.percent ||
        (shift &&
            (key == LogicalKeyboardKey.backslash ||
                key == LogicalKeyboardKey.digit5));
    if (isHorizSplit) {
      unawaited(workspace.splitFocusedPane(SplitAxis.horizontal));
      return true;
    }

    final isVertSplit =
        ch == '-' ||
        ch == '"' ||
        key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.quote ||
        (shift && key == LogicalKeyboardKey.quoteSingle);
    if (isVertSplit) {
      unawaited(workspace.splitFocusedPane(SplitAxis.vertical));
      return true;
    }

    final direction = _mapFocusDirection(key);
    if (direction != null) {
      workspace.focusDirection(direction);
      return true;
    }

    if (key == LogicalKeyboardKey.keyZ) {
      workspace.toggleZoom();
      return true;
    }
    if (key == LogicalKeyboardKey.keyB) {
      unawaited(workspace.togglePaneShare());
      return true;
    }
    return false;
  }

  bool _dispatchTabOrModalChord(
    LogicalKeyboardKey key,
    String? ch,
    bool shift,
  ) {
    final digit = _digitIndices[key];
    if (digit != null) {
      if (digit < workspace.tabs.length) {
        workspace.selectTab(digit);
      }
      return true;
    }
    final modalOverlay = _mapModalOverlay(key, ch, shift);
    if (modalOverlay != null) {
      workspace.setOverlay(modalOverlay);
      return true;
    }
    if (key == LogicalKeyboardKey.keyN) {
      workspace.cycleTab();
      return true;
    }
    if (key == LogicalKeyboardKey.keyP) {
      workspace.cycleTab(reverse: true);
      return true;
    }
    if (key == LogicalKeyboardKey.keyX) {
      unawaited(workspace.closePane());
      return true;
    }
    if (key == LogicalKeyboardKey.keyD || key == LogicalKeyboardKey.space) {
      workspace.cycleDockPosition();
      return true;
    }
    return false;
  }

  FocusDirection? _mapFocusDirection(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.keyH || key == LogicalKeyboardKey.arrowLeft) {
      return FocusDirection.left;
    }
    if (key == LogicalKeyboardKey.keyJ || key == LogicalKeyboardKey.arrowDown) {
      return FocusDirection.down;
    }
    if (key == LogicalKeyboardKey.keyK || key == LogicalKeyboardKey.arrowUp) {
      return FocusDirection.up;
    }
    if (key == LogicalKeyboardKey.keyL ||
        key == LogicalKeyboardKey.arrowRight) {
      return FocusDirection.right;
    }
    return null;
  }

  FtermOverlay? _mapModalOverlay(
    LogicalKeyboardKey key,
    String? ch,
    bool shift,
  ) {
    if (key == LogicalKeyboardKey.keyC) return FtermOverlay.sessionPicker;
    if (key == LogicalKeyboardKey.keyR) return FtermOverlay.rename;
    if (key == LogicalKeyboardKey.comma || ch == ',') {
      return FtermOverlay.settings;
    }
    if (key == LogicalKeyboardKey.keyI) return FtermOverlay.stats;
    if (key == LogicalKeyboardKey.keyA) return FtermOverlay.about;
    final isQuestion =
        ch == '?' ||
        key == LogicalKeyboardKey.question ||
        (shift && key == LogicalKeyboardKey.slash);
    if (isQuestion) return FtermOverlay.help;
    return null;
  }

  bool _hasZoomModifiers(Set<ev.Modifier> modifiers) {
    final forbidAlt = !modifiers.contains(ev.Modifier.alt);
    if (_isMacOs) {
      return forbidAlt &&
          modifiers.contains(ev.Modifier.meta) &&
          !modifiers.contains(ev.Modifier.control);
    }
    return forbidAlt &&
        modifiers.contains(ev.Modifier.control) &&
        !modifiers.contains(ev.Modifier.meta);
  }

  bool _handleFontZoomShortcut(KeyEvent event, Set<ev.Modifier> modifiers) {
    if (!_hasZoomModifiers(modifiers)) return false;
    final key = event.logicalKey;
    final shift = modifiers.contains(ev.Modifier.shift);
    if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.numpadAdd) {
      workspace.adjustFontSize(_fontZoomStep);
      return true;
    }
    if (shift) return false;
    if (key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.numpadSubtract) {
      workspace.adjustFontSize(-_fontZoomStep);
      return true;
    }
    if (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0) {
      workspace.resetFontSize();
      return true;
    }
    return false;
  }

  bool _handleDesktopShortcut(KeyDownEvent event, Set<ev.Modifier> modifiers) {
    if (_isWeb) return false;
    if (_isCtrlShiftF5(event.logicalKey, modifiers)) {
      unawaited(workspace.reloadShaders());
      return true;
    }
    if (_platform == TargetPlatform.macOS) {
      return _handleMacOsShortcut(event.logicalKey, modifiers);
    }
    if (_platform == TargetPlatform.linux ||
        _platform == TargetPlatform.windows) {
      return _handleLinuxWindowsShortcut(event.logicalKey, modifiers);
    }
    return false;
  }

  static bool _isCtrlShiftF5(
    LogicalKeyboardKey key,
    Set<ev.Modifier> modifiers,
  ) =>
      key == LogicalKeyboardKey.f5 &&
      modifiers.contains(ev.Modifier.control) &&
      modifiers.contains(ev.Modifier.shift) &&
      !modifiers.contains(ev.Modifier.alt) &&
      !modifiers.contains(ev.Modifier.meta);

  bool _handleMacOsShortcut(
    LogicalKeyboardKey key,
    Set<ev.Modifier> modifiers,
  ) {
    final cmdOnly =
        modifiers.contains(ev.Modifier.meta) &&
        !modifiers.contains(ev.Modifier.control) &&
        !modifiers.contains(ev.Modifier.alt);
    if (!cmdOnly) return false;

    final shift = modifiers.contains(ev.Modifier.shift);
    if (!shift) {
      final digit = _digitIndices[key];
      if (digit != null) {
        if (digit < workspace.tabs.length) {
          workspace.selectTab(digit);
        }
        return true;
      }
      if (key == LogicalKeyboardKey.comma) {
        workspace.setOverlay(FtermOverlay.settings);
        return true;
      }
    }
    return _dispatchCommonNewCloseSplit(key, shift: shift);
  }

  bool _handleLinuxWindowsShortcut(
    LogicalKeyboardKey key,
    Set<ev.Modifier> modifiers,
  ) {
    final ctrlShiftOnly =
        modifiers.contains(ev.Modifier.control) &&
        modifiers.contains(ev.Modifier.shift) &&
        !modifiers.contains(ev.Modifier.alt) &&
        !modifiers.contains(ev.Modifier.meta);
    if (!ctrlShiftOnly) return false;

    final digit = _digitIndices[key];
    if (digit != null) {
      if (digit < workspace.tabs.length) {
        workspace.selectTab(digit);
      }
      return true;
    }
    if (key == LogicalKeyboardKey.comma) {
      workspace.setOverlay(FtermOverlay.settings);
      return true;
    }
    if (key == LogicalKeyboardKey.keyE) {
      unawaited(workspace.splitFocusedPane(SplitAxis.vertical));
      return true;
    }
    return _dispatchCommonNewCloseSplit(key, shift: false);
  }

  bool _dispatchCommonNewCloseSplit(
    LogicalKeyboardKey key, {
    required bool shift,
  }) {
    if (key == LogicalKeyboardKey.keyT && !shift) {
      if (workspace.isDesktopHost) {
        unawaited(workspace.openLocalShellTab());
      } else {
        workspace.setOverlay(FtermOverlay.sessionPicker);
      }
      return true;
    }
    if (key == LogicalKeyboardKey.keyW && !shift) {
      unawaited(workspace.closePane());
      return true;
    }
    if (key == LogicalKeyboardKey.keyD) {
      unawaited(
        workspace.splitFocusedPane(
          shift ? SplitAxis.vertical : SplitAxis.horizontal,
        ),
      );
      return true;
    }
    return false;
  }

  bool _handleF12Gate(KeyEvent event, Set<ev.Modifier> modifiers) {
    if (event.logicalKey != LogicalKeyboardKey.f12) return false;
    final onlyShiftOrNone = modifiers.difference(const {
      ev.Modifier.shift,
    }).isEmpty;
    if (workspace.f12ShortcutsEnabled && onlyShiftOrNone) {
      return false;
    }
    final pane = workspace.focusedPane;
    if (pane == null) return false;
    final eventType = event is KeyRepeatEvent
        ? ev.KeyEventType.repeat
        : ev.KeyEventType.press;
    pane.sendInputEvent(
      ev.KeyEvent(
        'f12',
        ev.KeyType.f12,
        modifiers: modifiers,
        eventType: eventType,
      ),
    );
    return true;
  }
}
