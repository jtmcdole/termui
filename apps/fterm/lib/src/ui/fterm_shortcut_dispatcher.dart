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
import 'package:termui_flutter/termui_flutter.dart'
    show HostShortcutResult, TerminalMetaKeyPolicy;

import '../commands/action_descriptors.dart';
import '../commands/fterm_capability_context.dart';
import '../commands/fterm_descriptor_models.dart';
import '../commands/fterm_shortcut_spec.dart';
import '../commands/settings_descriptors.dart';
import '../commands/shortcut_catalog.dart';
import '../input/key_chord.dart';
import '../workspace/fterm_workspace_controller.dart';

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

  static final List<FtermDescriptor> _defaultShortcutDescriptors =
      List<FtermDescriptor>.unmodifiable(<FtermDescriptor>[
        for (final descriptor in allActionDescriptors)
          if (descriptor.shortcut != null) descriptor,
        for (final descriptor in allSettingDescriptors)
          if (descriptor is FtermToggleSettingDescriptor &&
              descriptor.shortcut != null)
            descriptor,
      ]);

  /// Backing workspace mutated by recognized shortcuts.
  final FtermWorkspaceController workspace;

  final TargetPlatform? _platformOverride;
  final bool? _isWebOverride;
  final Set<String>? _enabledFeatures;
  final List<FtermDescriptor>? _descriptorsOverride;

  /// Creates a shortcut dispatcher bound to [workspace].
  ///
  /// When `enabledFeatures` is omitted, inherits `workspace.enabledFeatures`.
  const FtermShortcutDispatcher({
    required this.workspace,
    this._platformOverride,
    this._isWebOverride,
    this._enabledFeatures,
    this._descriptorsOverride,
  });

  static const double _fontZoomStep = 1.0;

  TargetPlatform get _platform => _platformOverride ?? defaultTargetPlatform;
  bool get _isMacOs => _platform == TargetPlatform.macOS;
  bool get _isWeb => _isWebOverride ?? kIsWeb;

  FtermCapabilityContext get _capabilities =>
      FtermCapabilityContext.fromWorkspace(
        workspace,
        isWeb: _isWeb,
        platform: _platform,
        enabledFeatures: _enabledFeatures,
      );

  List<FtermDescriptor> get _shortcutDescriptors =>
      _descriptorsOverride ?? _defaultShortcutDescriptors;

  /// Resolves the active [TerminalMetaKeyPolicy] for unhandled `Meta`/`Cmd`
  /// combinations based on `workspace.preferences.metaKeyMode`, platform, and
  /// runtime.
  TerminalMetaKeyPolicy resolveMetaKeyPolicy() =>
      switch (workspace.preferences.metaKeyMode) {
        .passThrough => .passThroughUnhandled,
        .kitty => .claimWhenKittyActive,
        .auto =>
          (_isWeb || _isMacOs) ? .passThroughUnhandled : .claimWhenKittyActive,
      };

  /// Returns `true` when `(key, modifiers)` matches a user-configured
  /// passthrough chord in `workspace.preferences.passthroughShortcuts`.
  bool isPassthroughShortcut(
    LogicalKeyboardKey key,
    Set<ev.Modifier> modifiers,
  ) {
    final shortcuts = workspace.preferences.passthroughShortcuts;
    if (shortcuts.isEmpty) return false;
    for (final chord in shortcuts) {
      if (chord.matches(key, modifiers)) return true;
    }
    final normalized = KeyChord.fromKeyEvent(key, modifiers);
    if (normalized == null || normalized.key == key) return false;
    return shortcuts.contains(normalized);
  }

  /// Handles [event] with active [modifiers], returning
  /// [HostShortcutResult.handled] when consumed as an `fterm` shortcut or
  /// handled F12 passthrough, [HostShortcutResult.passThrough] when matched by
  /// a user-configured passthrough chord, or [HostShortcutResult.unhandled]
  /// otherwise.
  HostShortcutResult handleHostShortcut(
    KeyEvent event,
    Set<ev.Modifier> modifiers,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return .unhandled;
    }
    if (event is KeyDownEvent && workspace.audioController.needsGestureUnlock) {
      unawaited(workspace.audioController.notifyUserGesture());
    }
    if (_handleEmergencyStopShortcut(event, modifiers)) {
      return .handled;
    }
    if (workspace.activeOverlay != FtermOverlay.none) {
      return _handleOverlayKeyEvent(event, modifiers) ? .handled : .unhandled;
    }
    if (workspace.isLeaderArmed) {
      return _handleLeaderChord(event, modifiers) ? .handled : .unhandled;
    }
    if (isPassthroughShortcut(event.logicalKey, modifiers)) {
      return .passThrough;
    }
    return _handleWorkspaceShortcut(event, modifiers) ? .handled : .unhandled;
  }

  bool _handleWorkspaceShortcut(KeyEvent event, Set<ev.Modifier> modifiers) {
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

  bool _handleEmergencyStopShortcut(
    KeyEvent event,
    Set<ev.Modifier> modifiers,
  ) {
    final stroke = FtermShortcuts.emergencyStopShaders.universalDesktopStroke!;
    if (!stroke.matches(event.logicalKey, modifiers)) {
      return false;
    }
    if (!_isDescriptorVisible('shader.emergency_stop', _capabilities)) {
      return false;
    }
    if (event is KeyDownEvent) {
      workspace.setLeaderArmed(false);
      workspace.toggleShaderEmergencyStop();
    }
    return true;
  }

  bool _handleOverlayKeyEvent(KeyEvent event, Set<ev.Modifier> modifiers) {
    if (workspace.isLeaderArmed) {
      return _handleOverlayLeaderChord(event, modifiers);
    }
    if (_isCtrlBackslashLeader(event, modifiers)) {
      if (event is KeyDownEvent) {
        workspace.setLeaderArmed(true);
      }
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      workspace.dismissOverlay();
      return true;
    }
    if (workspace.activeOverlay == FtermOverlay.commandPalette &&
        event is KeyDownEvent &&
        FtermShortcuts.commandPalette.matchesDesktopStroke(
          event.logicalKey,
          modifiers,
          _capabilities,
        )) {
      workspace.dismissOverlay();
      return true;
    }
    // Let modal controls, FocusTraversalGroup (Tab), and DefaultTextEditingShortcuts
    // handle overlay keys while workspace panes stay excluded via ExcludeFocus.
    return false;
  }

  bool _handleOverlayLeaderChord(KeyEvent event, Set<ev.Modifier> modifiers) {
    if (_modifierKeys.contains(event.logicalKey) ||
        (event is KeyRepeatEvent && _isCtrlBackslashLeader(event, modifiers))) {
      return true;
    }
    workspace.setLeaderArmed(false);
    if (event is! KeyDownEvent) return true;
    final shift =
        modifiers.contains(ev.Modifier.shift) ||
        HardwareKeyboard.instance.isShiftPressed;
    if (FtermShortcuts.emergencyStopShaders.leaderChord!.matches(
          event.logicalKey,
          shift: shift,
        ) &&
        _isDescriptorVisible('shader.emergency_stop', _capabilities)) {
      workspace.toggleShaderEmergencyStop();
    } else if (workspace.activeOverlay == FtermOverlay.commandPalette &&
        FtermShortcuts.commandPalette.leaderChord!.matches(
          event.logicalKey,
          shift: shift,
        )) {
      workspace.dismissOverlay();
    }
    return true;
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
    if (_modifierKeys.contains(event.logicalKey) ||
        (event is KeyRepeatEvent && _isCtrlBackslashLeader(event, modifiers))) {
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
    if (_dispatchLeaderSpecialChord(key, ch, shift)) {
      return true;
    }
    if (_dispatchLeaderDescriptor(key, ch, shift, _capabilities)) {
      return true;
    }
    _selectDigitTab(key);
    return true;
  }

  bool _dispatchLeaderSpecialChord(
    LogicalKeyboardKey key,
    String? ch,
    bool shift,
  ) {
    if (FtermShortcuts.commandPalette.leaderChord!.matches(
      key,
      shift: shift,
      character: ch,
    )) {
      workspace.openCommandPalette(initialInput: '>');
      return true;
    }
    if (FtermShortcuts.openSettings.leaderChord!.matches(
      key,
      shift: shift,
      character: ch,
    )) {
      workspace.setOverlay(FtermOverlay.settings);
      return true;
    }
    return false;
  }

  bool _dispatchLeaderDescriptor(
    LogicalKeyboardKey key,
    String? ch,
    bool shift,
    FtermCapabilityContext ctx,
  ) {
    for (final descriptor in _shortcutDescriptors) {
      final chord = _shortcutOf(descriptor)?.leaderChord;
      if (chord == null || !chord.matches(key, shift: shift, character: ch)) {
        continue;
      }
      if (!descriptor.isVisibleFor(ctx)) continue;
      _executeDescriptor(descriptor);
      return true;
    }
    return false;
  }

  bool _selectDigitTab(LogicalKeyboardKey key) {
    final digit = _digitIndices[key];
    if (digit == null) return false;
    if (digit < workspace.tabs.length) {
      workspace.selectTab(digit);
    }
    return true;
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
    final ctx = _capabilities;
    if (ctx.isWeb) return false;
    final key = event.logicalKey;

    if (_dispatchDesktopSpecialShortcut(key, modifiers, ctx)) {
      return true;
    }
    if (_handleDesktopDigitTab(key, modifiers, ctx)) {
      return true;
    }
    return _dispatchDesktopDescriptor(key, modifiers, ctx);
  }

  bool _dispatchDesktopSpecialShortcut(
    LogicalKeyboardKey key,
    Set<ev.Modifier> modifiers,
    FtermCapabilityContext ctx,
  ) {
    if (FtermShortcuts.commandPalette.matchesDesktopStroke(
      key,
      modifiers,
      ctx,
    )) {
      workspace.openCommandPalette(initialInput: '>');
      return true;
    }
    if (FtermShortcuts.openSettings.matchesDesktopStroke(key, modifiers, ctx)) {
      workspace.setOverlay(FtermOverlay.settings);
      return true;
    }
    if (ctx.isMacOs &&
        FtermShortcuts.saveShader.matchesDesktopStroke(key, modifiers, ctx)) {
      return _handleEditorSaveShortcut(shift: false);
    }
    if (ctx.isMacOs &&
        FtermShortcuts.saveShaderAs.matchesDesktopStroke(key, modifiers, ctx)) {
      return _handleEditorSaveShortcut(shift: true);
    }
    if (FtermShortcuts.newLocalShell.matchesDesktopStroke(
      key,
      modifiers,
      ctx,
    )) {
      return _dispatchNewTabDesktopShortcut(ctx);
    }
    return false;
  }

  bool _dispatchNewTabDesktopShortcut(FtermCapabilityContext ctx) {
    if (_isDescriptorVisible('workspace.new_local_shell', ctx)) {
      unawaited(workspace.openLocalShellTab());
      return true;
    }
    if (!workspace.isDesktopHost) {
      workspace.setOverlay(FtermOverlay.sessionPicker);
      return true;
    }
    return false;
  }

  bool _handleDesktopDigitTab(
    LogicalKeyboardKey key,
    Set<ev.Modifier> modifiers,
    FtermCapabilityContext ctx,
  ) {
    final digit = _digitIndices[key];
    if (digit == null) return false;
    final isMacCmdOnly =
        ctx.isMacOs &&
        modifiers.contains(ev.Modifier.meta) &&
        !modifiers.contains(ev.Modifier.shift) &&
        !modifiers.contains(ev.Modifier.control) &&
        !modifiers.contains(ev.Modifier.alt);
    final isLinuxWinCtrlShift =
        (ctx.isLinux || ctx.isWindows) &&
        modifiers.contains(ev.Modifier.control) &&
        modifiers.contains(ev.Modifier.shift) &&
        !modifiers.contains(ev.Modifier.alt) &&
        !modifiers.contains(ev.Modifier.meta);
    if (!isMacCmdOnly && !isLinuxWinCtrlShift) return false;
    if (digit < workspace.tabs.length) {
      workspace.selectTab(digit);
    }
    return true;
  }

  bool _dispatchDesktopDescriptor(
    LogicalKeyboardKey key,
    Set<ev.Modifier> modifiers,
    FtermCapabilityContext ctx,
  ) {
    for (final descriptor in _shortcutDescriptors) {
      final binding = _shortcutOf(descriptor);
      if (binding == null ||
          !binding.matchesDesktopStroke(key, modifiers, ctx)) {
        continue;
      }
      if (!descriptor.isVisibleFor(ctx)) continue;
      _executeDescriptor(descriptor);
      return true;
    }
    return false;
  }

  bool _isDescriptorVisible(String id, FtermCapabilityContext ctx) {
    final descriptor = _findDescriptorById(id);
    return descriptor != null && descriptor.isVisibleFor(ctx);
  }

  FtermDescriptor? _findDescriptorById(String id) {
    if (_descriptorsOverride case final custom?) {
      for (final descriptor in custom) {
        if (descriptor.id == id) return descriptor;
      }
      return null;
    }
    return actionDescriptorById(id) ?? settingDescriptorById(id);
  }

  static FtermShortcutBinding? _shortcutOf(FtermDescriptor descriptor) =>
      switch (descriptor) {
        FtermActionDescriptor(:final shortcut) => shortcut,
        FtermToggleSettingDescriptor(:final shortcut) => shortcut,
        FtermEnumSettingDescriptor<Object?>() ||
        FtermSliderSettingDescriptor() ||
        FtermCustomSettingDescriptor() => null,
      };

  void _executeDescriptor(FtermDescriptor descriptor) {
    switch (descriptor) {
      case FtermActionDescriptor():
        final result = descriptor.execute(workspace);
        if (result is Future<void>) unawaited(result);
      case FtermToggleSettingDescriptor():
        final result = descriptor.write(workspace, !descriptor.read(workspace));
        if (result is Future<void>) unawaited(result);
      case FtermEnumSettingDescriptor<Object?>() ||
          FtermSliderSettingDescriptor() ||
          FtermCustomSettingDescriptor():
        break;
    }
  }

  bool _handleEditorSaveShortcut({required bool shift}) {
    final editor = workspace.focusedEditorPane;
    if (editor == null) return false;
    final ctrl = editor.controller;
    if (ctrl.confirmingClose || ctrl.promptingSaveAs) return true;
    if (shift) {
      ctrl.beginSaveAs();
    } else {
      unawaited(ctrl.save());
    }
    return true;
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
