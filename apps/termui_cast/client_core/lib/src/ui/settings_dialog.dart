import 'dart:async';
import 'dart:math';

import 'package:termui/termui.dart';

import '../cast_workspace_view_model.dart';
import '../terminal_theme_settings.dart';
import 'dialog_theme.dart';

enum _SettingsControl {
  copyOnSelect,
  debugOverlay,
  f12Shortcuts,
  appearance,
  darkPreset,
  lightPreset,
  ansiContrast,
  boldIsBright,
  faintOpacity,
  smartCursor,
  customizePalette,
  reloadFromStorage,
  close,
}

/// Pure-Dart `termui` modal dialog exposing interactive workspace settings
/// toggles, theme selectors, ANSI contrast controls, storage reload, and palette customization.
final class SettingsDialog extends StatefulWidget {
  /// Backing workspace view model whose settings are displayed and mutated.
  final CastWorkspaceViewModel viewModel;

  /// Optional callback invoked when the user selects `Customize ANSI Palette...`.
  final VoidCallback? onOpenPaletteEditor;

  /// Optional override callback invoked when the user selects `Reload from Storage`.
  final VoidCallback? onReloadSettings;

  /// Creates an interactive workspace settings dialog widget.
  const SettingsDialog({
    super.key,
    required this.viewModel,
    this.onOpenPaletteEditor,
    this.onReloadSettings,
  });

  /// Displays a centered [SettingsDialog] on [sceneManager] and completes when
  /// dismissed via `Escape`, `q`, `,`, the `Close (Esc)` button, or clicking
  /// the backdrop barrier.
  static Future<void> show(
    SceneManager sceneManager, {
    required CastWorkspaceViewModel viewModel,
    VoidCallback? onOpenPaletteEditor,
    VoidCallback? onReloadSettings,
    bool barrierDismissible = true,
  }) async {
    final size = clampDialogSize(
      sceneManager.terminal.backend.size,
      preferredWidth: 68,
      minWidth: 24,
      preferredHeight: 21,
      minHeight: 10,
      verticalMargin: 0,
    );
    await showThemedDialog<void>(
      sceneManager,
      width: size.x,
      height: size.y,
      terminalTheme: viewModel.activeTerminalTheme,
      barrierDismissible: barrierDismissible,
      builder: (_) => SettingsDialog(
        viewModel: viewModel,
        onOpenPaletteEditor: onOpenPaletteEditor,
        onReloadSettings: onReloadSettings,
      ),
    );
  }

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

final class _SettingsDialogState extends State<SettingsDialog> {
  static const List<double> _contrastSteps = [
    1.0,
    3.0,
    4.5,
    7.0,
    10.0,
    14.0,
    21.0,
  ];
  static const List<double> _faintSteps = [0.40, 0.55, 0.75, 0.90, 1.00];

  late final void Function() _removeVisualListener;
  _SettingsControl _focusedControl = .copyOnSelect;

  @override
  void initState() {
    super.initState();
    _removeVisualListener = widget.viewModel.addVisualListener(_onModelChanged);
  }

  @override
  void dispose() {
    _removeVisualListener();
    super.dispose();
  }

  void _onModelChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _setFocus(_SettingsControl control) {
    if (_focusedControl == control || !mounted) return;
    setState(() {
      _focusedControl = control;
    });
  }

  void _stepFocus(int delta) {
    if (!mounted) return;
    const controls = _SettingsControl.values;
    setState(() {
      final nextIdx =
          (_focusedControl.index + delta + controls.length) % controls.length;
      _focusedControl = controls[nextIdx];
    });
  }

  static void _dismiss(BuildContext context) {
    PromptScope.of(context)?.done();
  }

  void _openPaletteEditor(BuildContext context) {
    widget.onOpenPaletteEditor?.call();
    _dismiss(context);
  }

  void _triggerReloadSettings() {
    if (widget.onReloadSettings case final callback?) {
      callback();
      return;
    }
    widget.viewModel.reloadSettingsFromStorage();
  }

  void _cycleAppearance(int delta) {
    const modes = ThemeAppearanceMode.values;
    final current = widget.viewModel.themeSettings.appearanceMode;
    final next = modes[(current.index + delta + modes.length) % modes.length];
    widget.viewModel.updateThemeSettings(
      widget.viewModel.themeSettings.copyWith(appearanceMode: next),
    );
  }

  void _cyclePreset({required bool isDark, required int delta}) {
    final TerminalBrightness targetBrightness = isDark ? .dark : .light;
    final filtered = [
      for (final preset in TerminalColorTheme.presets)
        if (preset.brightness == targetBrightness) preset,
    ];
    if (filtered.isEmpty) return;

    final currentId = isDark
        ? widget.viewModel.themeSettings.darkThemeId
        : widget.viewModel.themeSettings.lightThemeId;
    var idx = 0;
    for (var i = 0; i < filtered.length; i++) {
      if (filtered[i].id == currentId) {
        idx = i;
        break;
      }
    }
    final next = filtered[(idx + delta + filtered.length) % filtered.length];
    widget.viewModel.updateThemeSettings(
      isDark
          ? widget.viewModel.themeSettings.copyWith(darkThemeId: next.id)
          : widget.viewModel.themeSettings.copyWith(lightThemeId: next.id),
    );
  }

  void _cycleContrast(int delta) {
    final current = widget.viewModel.themeSettings.minimumContrast;
    final bestIdx = nearestStepIndex(_contrastSteps, current);
    final nextIdx =
        (bestIdx + delta + _contrastSteps.length) % _contrastSteps.length;
    widget.viewModel.updateThemeSettings(
      widget.viewModel.themeSettings.copyWith(
        minimumContrast: _contrastSteps[nextIdx],
      ),
    );
  }

  void _cycleFaint(int delta) {
    final current = widget.viewModel.themeSettings.faintOpacity;
    final bestIdx = nearestStepIndex(_faintSteps, current);
    final nextIdx = (bestIdx + delta + _faintSteps.length) % _faintSteps.length;
    widget.viewModel.updateThemeSettings(
      widget.viewModel.themeSettings.copyWith(
        faintOpacity: _faintSteps[nextIdx],
      ),
    );
  }

  bool _handleKeyEvent(BuildContext context, KeyEvent event) {
    if (_isDismissKey(event)) {
      _dismiss(context);
      return true;
    }
    final focusDelta = dialogFocusDelta(event);
    if (focusDelta != 0) {
      _stepFocus(focusDelta);
      return true;
    }
    return _dispatchControlKey(context, _focusedControl, event);
  }

  bool _dispatchControlKey(
    BuildContext context,
    _SettingsControl control,
    KeyEvent event,
  ) {
    final step = dialogSelectorStepDelta(event, spaceAndEnterStepForward: true);
    if (_applySelectorStep(control, step)) return true;
    if (!isDialogActivateKey(event)) return false;
    _activateControl(context, control);
    return true;
  }

  bool _applySelectorStep(_SettingsControl control, int step) {
    if (step == 0) return false;
    switch (control) {
      case .appearance:
        _cycleAppearance(step);
      case .darkPreset:
        _cyclePreset(isDark: true, delta: step);
      case .lightPreset:
        _cyclePreset(isDark: false, delta: step);
      case .ansiContrast:
        _cycleContrast(step);
      case .faintOpacity:
        _cycleFaint(step);
      default:
        return false;
    }
    return true;
  }

  void _activateControl(BuildContext context, _SettingsControl control) {
    final vm = widget.viewModel;
    final ts = vm.themeSettings;
    switch (control) {
      case .copyOnSelect:
        vm.setCopyOnSelect(!vm.copyOnSelect);
      case .debugOverlay:
        vm.setDebugOverlayEnabled(!vm.debugOverlayEnabled);
      case .f12Shortcuts:
        vm.setF12ShortcutsEnabled(!vm.f12ShortcutsEnabled);
      case .boldIsBright:
        vm.updateThemeSettings(ts.copyWith(boldIsBright: !ts.boldIsBright));
      case .smartCursor:
        vm.updateThemeSettings(
          ts.copyWith(smartCursorColor: !ts.smartCursorColor),
        );
      case .customizePalette:
        _openPaletteEditor(context);
      case .reloadFromStorage:
        _triggerReloadSettings();
      case .close:
        _dismiss(context);
      case .appearance ||
          .darkPreset ||
          .lightPreset ||
          .ansiContrast ||
          .faintOpacity:
        break;
    }
  }

  static bool _isDismissKey(KeyEvent event) {
    if (event.type == .escape) return true;
    if (event.type != .character) return false;
    final key = event.key.toLowerCase();
    return key == 'q' || key == ',';
  }

  static String _formatContrastTier(double minimumContrast) {
    final tier = switch (minimumContrast) {
      <= 1.0 => 'Exact',
      <= 3.0 => 'UI',
      <= 4.5 => 'AA',
      <= 7.0 => 'AAA',
      <= 10.0 => 'High',
      <= 14.0 => 'Ultra',
      _ => 'Max',
    };
    return '${minimumContrast.toStringAsFixed(1)}x ($tier)';
  }

  static double _minAnsiChromaticContrast(
    TerminalColorTheme theme,
    double minimumContrast,
  ) {
    var lowest = 21.0;
    final bg = theme.background;
    for (var i = 1; i <= 6; i++) {
      final raw = theme.ansi[i];
      final effective = minimumContrast > 1.0
          ? TerminalContrast.enforceMinimumContrast(
              raw,
              bg,
              minRatio: minimumContrast,
            )
          : raw;
      final ratio = TerminalContrast.contrastRatio(effective, bg);
      if (ratio < lowest) lowest = ratio;
    }
    return lowest;
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.viewModel;
    final activeTheme = vm.activeTerminalTheme;
    final chrome = WorkspaceChromeTheme.fromTerminalTheme(activeTheme);

    return WorkspaceChromeScope(
      theme: chrome,
      child: DecoratedBox(
        decoration: chrome.panelDecoration,
        child: LayoutBuilder(
          builder: (_, outerConstraints) {
            final horizontalPad = outerConstraints.maxWidth < 36 ? 1 : 2;
            final verticalPad = outerConstraints.maxHeight < 14 ? 0 : 1;
            return Padding(
              padding: EdgeInsets.symmetric(
                horizontal: horizontalPad,
                vertical: verticalPad,
              ),
              child: FocusScope(
                autofocus: true,
                onKeyEvent: (event) => _handleKeyEvent(context, event),
                child: LayoutBuilder(
                  builder: (_, constraints) {
                    final maxAvailableRows = max(0, constraints.maxHeight - 2);
                    return Column([
                      Text(
                        'TermUI Caster - Settings',
                        style: chrome.titleStyle,
                        wrap: false,
                      ),
                      Expanded(
                        child: _buildBody(
                          vm: vm,
                          activeTheme: activeTheme,
                          chrome: chrome,
                          maxWidth: constraints.maxWidth,
                          maxRows: maxAvailableRows,
                        ),
                      ),
                      Button(
                        text: 'Close (Esc)',
                        focused: _focusedControl == .close,
                        onPressed: () => _dismiss(context),
                        style: chrome.buttonStyle,
                        focusedStyle: chrome.focusedButtonStyle,
                      ),
                    ], crossAxisAlignment: .stretch);
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSelectorRow({
    required _SettingsControl control,
    required String prefix,
    required String valueLabel,
    String? trailingInfo,
    required WorkspaceChromeTheme chrome,
    required void Function(int delta) onStep,
  }) {
    final valueStyle = _focusedControl == control
        ? chrome.focusedButtonStyle
        : chrome.rowStyle;
    return DialogSelectorTapTarget(
      leftArrowOffset: prefix.length,
      onStep: (delta) {
        _setFocus(control);
        onStep(delta);
      },
      child: Row([
        Text(prefix, style: chrome.rowStyle, wrap: false),
        if (trailingInfo == null)
          Expanded(
            child: Text('< $valueLabel >', style: valueStyle, wrap: false),
          )
        else ...[
          Text('< $valueLabel >', style: valueStyle, wrap: false),
          Expanded(
            child: Text(trailingInfo, style: chrome.hintStyle, wrap: false),
          ),
        ],
      ]),
    );
  }

  List<Widget> _buildAllControls({
    required CastWorkspaceViewModel vm,
    required TerminalColorTheme activeTheme,
    required WorkspaceChromeTheme chrome,
    required int maxWidth,
  }) {
    final ts = vm.themeSettings;
    final appearanceLabel = switch (ts.appearanceMode) {
      .system => 'System',
      .dark => 'Dark',
      .light => 'Light',
    };
    final darkPreset =
        TerminalColorTheme.byId(ts.darkThemeId) ??
        TerminalColorTheme.termuiDark;
    final lightPreset =
        TerminalColorTheme.byId(ts.lightThemeId) ??
        TerminalColorTheme.termuiLight;
    final minAnsi = _minAnsiChromaticContrast(activeTheme, ts.minimumContrast);
    final showInlineMinAnsi = maxWidth >= 48;

    return <Widget>[
      Checkbox(
        value: vm.copyOnSelect,
        label: r'Copy selection on release (Ctrl+\ o)',
        focused: _focusedControl == .copyOnSelect,
        style: chrome.rowStyle,
        focusedStyle: chrome.focusedButtonStyle,
        onChanged: (enabled) {
          _setFocus(.copyOnSelect);
          vm.setCopyOnSelect(enabled);
        },
      ),
      Checkbox(
        value: vm.debugOverlayEnabled,
        label: 'Debug overlay: layer borders, hover & touches',
        focused: _focusedControl == .debugOverlay,
        style: chrome.rowStyle,
        focusedStyle: chrome.focusedButtonStyle,
        onChanged: (enabled) {
          _setFocus(.debugOverlay);
          vm.setDebugOverlayEnabled(enabled);
        },
      ),
      Checkbox(
        value: vm.f12ShortcutsEnabled,
        label: 'Enable F12 screenshot & Shift+F12 atlas reload',
        focused: _focusedControl == .f12Shortcuts,
        style: chrome.rowStyle,
        focusedStyle: chrome.focusedButtonStyle,
        onChanged: (enabled) {
          _setFocus(.f12Shortcuts);
          vm.setF12ShortcutsEnabled(enabled);
        },
      ),
      _buildSelectorRow(
        control: .appearance,
        prefix: 'Appearance:    ',
        valueLabel: appearanceLabel,
        chrome: chrome,
        onStep: _cycleAppearance,
      ),
      _buildSelectorRow(
        control: .darkPreset,
        prefix: 'Dark Preset:   ',
        valueLabel: darkPreset.name,
        chrome: chrome,
        onStep: (delta) => _cyclePreset(isDark: true, delta: delta),
      ),
      _buildSelectorRow(
        control: .lightPreset,
        prefix: 'Light Preset:  ',
        valueLabel: lightPreset.name,
        chrome: chrome,
        onStep: (delta) => _cyclePreset(isDark: false, delta: delta),
      ),
      _buildSelectorRow(
        control: .ansiContrast,
        prefix: 'ANSI Contrast: ',
        valueLabel: _formatContrastTier(ts.minimumContrast),
        trailingInfo: showInlineMinAnsi
            ? '  min ANSI contrast: ${minAnsi.toStringAsFixed(1)}:1'
            : null,
        chrome: chrome,
        onStep: _cycleContrast,
      ),
      Checkbox(
        value: ts.boldIsBright,
        label: 'Bold uses Bright ANSI colors (0..7 -> 8..15)',
        focused: _focusedControl == .boldIsBright,
        style: chrome.rowStyle,
        focusedStyle: chrome.focusedButtonStyle,
        onChanged: (enabled) {
          _setFocus(.boldIsBright);
          vm.updateThemeSettings(ts.copyWith(boldIsBright: enabled));
        },
      ),
      _buildSelectorRow(
        control: .faintOpacity,
        prefix: 'Faint Opacity: ',
        valueLabel: '${(ts.faintOpacity * 100).round()}%',
        chrome: chrome,
        onStep: _cycleFaint,
      ),
      Checkbox(
        value: ts.smartCursorColor,
        label: 'Smart Cursor: invert block cursor on matching cell',
        focused: _focusedControl == .smartCursor,
        style: chrome.rowStyle,
        focusedStyle: chrome.focusedButtonStyle,
        onChanged: (enabled) {
          _setFocus(.smartCursor);
          vm.updateThemeSettings(ts.copyWith(smartCursorColor: enabled));
        },
      ),
      Button(
        text: 'Customize ANSI Palette...',
        focused: _focusedControl == .customizePalette,
        onPressed: () {
          _setFocus(.customizePalette);
          _openPaletteEditor(context);
        },
        style: chrome.buttonStyle,
        focusedStyle: chrome.focusedButtonStyle,
      ),
      Button(
        text: 'Reload from Storage',
        focused: _focusedControl == .reloadFromStorage,
        onPressed: () {
          _setFocus(.reloadFromStorage);
          _triggerReloadSettings();
        },
        style: chrome.buttonStyle,
        focusedStyle: chrome.focusedButtonStyle,
      ),
    ];
  }

  Widget _buildBody({
    required CastWorkspaceViewModel vm,
    required TerminalColorTheme activeTheme,
    required WorkspaceChromeTheme chrome,
    required int maxWidth,
    required int maxRows,
  }) {
    final controls = _buildAllControls(
      vm: vm,
      activeTheme: activeTheme,
      chrome: chrome,
      maxWidth: maxWidth,
    );
    if (controls.isEmpty || maxRows <= 0) {
      return const SizedBox.shrink();
    }

    final hasHint = maxRows >= 6;
    final controlBudget = hasHint ? maxRows - 1 : maxRows;
    final visibleCount = min(controlBudget, controls.length);

    final targetFocus = _focusedControl == .close
        ? controls.length - 1
        : _focusedControl.index;
    var startIdx = 0;
    if (targetFocus >= visibleCount) {
      startIdx = targetFocus - visibleCount + 1;
    }
    if (startIdx + visibleCount > controls.length) {
      startIdx = max(0, controls.length - visibleCount);
    }

    return Column([
      for (var i = 0; i < visibleCount; i++) controls[startIdx + i],
      if (hasHint)
        Text(
          'Tab/Up/Dn: move | Left/Right/Space: change | Esc: close',
          style: chrome.hintStyle,
          wrap: false,
        ),
    ], crossAxisAlignment: .stretch);
  }
}
