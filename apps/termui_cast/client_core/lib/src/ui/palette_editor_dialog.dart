import 'dart:async';
import 'dart:math';

import 'package:termui/terminal/event.dart' as ev;
import 'package:termui/termui.dart';

import '../cast_workspace_view_model.dart';
import 'dialog_theme.dart';
import 'hsv_color_wheel_picker.dart';

part 'palette_editor_controls.dart';

/// Pure-Dart `termui` modal dialog editing ANSI slots `0..15` plus Foreground,
/// Background, Cursor, and Selection (`CustomPaletteOverrides`).
final class PaletteEditorDialog extends StatefulWidget {
  /// Backing workspace view model whose theme settings are displayed and mutated.
  final CastWorkspaceViewModel viewModel;

  /// Creates a palette editor dialog widget.
  const PaletteEditorDialog({super.key, required this.viewModel});

  /// Displays a centered [PaletteEditorDialog] on [sceneManager] and completes
  /// when dismissed via `Escape`, `q`, the `Close` button, or clicking the backdrop barrier.
  static Future<void> show(
    SceneManager sceneManager, {
    required CastWorkspaceViewModel viewModel,
    bool barrierDismissible = true,
  }) async {
    final size = clampDialogSize(
      sceneManager.terminal.backend.size,
      preferredWidth: 88,
      minWidth: 32,
      preferredHeight: 26,
      minHeight: 10,
      horizontalMargin: 2,
      verticalMargin: 0,
    );
    await showThemedDialog<void>(
      sceneManager,
      width: size.x,
      height: size.y,
      terminalTheme: viewModel.activeTerminalTheme,
      barrierDismissible: barrierDismissible,
      builder: (_) => PaletteEditorDialog(viewModel: viewModel),
    );
  }

  @override
  State<PaletteEditorDialog> createState() => _PaletteEditorDialogState();
}

final class _PaletteEditorDialogState extends State<PaletteEditorDialog> {
  final _hexController = TextEditingController();
  final _slotFocusNode = FocusNode(id: 'palette_slot_list');
  final _hexFocusNode = FocusNode(id: 'palette_hex_input');
  late final void Function() _removeVisualListener;

  int _selectedSlotIndex = 0;
  int _listScrollOffset = 0;
  int _lastListRows = _slotLabels.length;
  _PaletteControl _focusedControl = .slotList;
  late HsvColor _workingHsv = HsvColor.fromColor(_currentColor);
  String? _hexError;
  Object? _lastModelKey;
  bool _updatingFromWheel = false;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _syncSlot();
    _lastModelKey = _modelKey;
    _removeVisualListener = widget.viewModel.addVisualListener(_onModelChanged);
  }

  @override
  void dispose() {
    _removeVisualListener();
    _slotFocusNode.dispose();
    _hexFocusNode.dispose();
    super.dispose();
  }

  Color get _currentColor =>
      _resolveSlot(widget.viewModel.activeTerminalTheme, _selectedSlotIndex);

  Object get _modelKey {
    final vm = widget.viewModel;
    return (
      vm.activeTerminalTheme,
      vm.themeSettings.customOverrides,
      vm.cellPixelSize,
    );
  }

  void _onModelChanged() {
    if (!mounted) return;
    final key = _modelKey;
    if (key == _lastModelKey) return;
    _lastModelKey = key;
    if (_focusedControl != .hexInput) _syncHex();
    if (!_updatingFromWheel && _workingHsv.toColor() != _currentColor) {
      _syncSlot();
    }
    setState(() {});
  }

  void _syncHex() {
    final next = CustomPaletteOverrides.formatHexRgb(_currentColor);
    if (_hexController.text != next) _hexController.text = next;
    _hexError = null;
  }

  void _syncSlot() {
    if (_focusedControl != .hexInput) _syncHex();
    _workingHsv = HsvColor.fromColor(
      _currentColor,
      fallbackHue: _workingHsv.hue,
      fallbackSaturation: _workingHsv.saturation,
    );
  }

  void _applySlotColor(Color? color) {
    final s = widget.viewModel.themeSettings;
    final o = _withSlotOverride(s.customOverrides, _selectedSlotIndex, color);
    widget.viewModel.updateThemeSettings(s.copyWith(customOverrides: o));
  }

  void _commitOrDiscardPendingHex() {
    if (_focusedControl != .hexInput) return;
    final parsed = CustomPaletteOverrides.parseHexRgb(_hexController.text);
    if (parsed != null && parsed != _currentColor) _applySlotColor(parsed);
    _syncHex();
  }

  void _setControl(_PaletteControl control) {
    if (control == .hexInput) {
      _focusedControl = .hexInput;
      _ensureVisible();
      _hexFocusNode.requestFocus();
      return;
    }
    if (_hexFocusNode.hasFocus) _hexFocusNode.unfocus();
    if (control == .slotList) _slotFocusNode.requestFocus();
    _focusedControl = control;
  }

  void _onHexFocusChange(bool focused) {
    if (!mounted || _dismissing) return;
    if (focused && _focusedControl != .hexInput) {
      setState(() => _focusedControl = .hexInput);
    }
  }

  void _applyHexInput() {
    final parsed = CustomPaletteOverrides.parseHexRgb(_hexController.text);
    if (parsed == null) {
      setState(() => _hexError = 'Invalid hex (use #RRGGBB)');
      return;
    }
    _hexError = null;
    if (parsed != _currentColor) _applySlotColor(parsed);
    setState(() {
      _syncHex();
      _syncSlot();
    });
  }

  void _onWheelChanged(HsvColor next) {
    if (_focusedControl == .hexInput) _setControl(.slotList);
    _workingHsv = next;
    final rgb = next.toColor();
    if (rgb != _currentColor) {
      _updatingFromWheel = true;
      try {
        _applySlotColor(rgb);
      } finally {
        _updatingFromWheel = false;
      }
    }
    setState(_syncHex);
  }

  void _stepChannel(_PaletteControl ctrl, int delta, {bool focus = false}) {
    _commitOrDiscardPendingHex();
    setState(() {
      if (focus) _setControl(ctrl);
      final c = _currentColor;
      final next = _stepRgb(c, ctrl, delta);
      if (next != c) {
        _applySlotColor(next);
        _syncSlot();
      }
    });
  }

  void _reset({required bool all, bool focusButton = true}) {
    if (_hexFocusNode.hasFocus) _hexFocusNode.unfocus();
    if (focusButton) _focusedControl = all ? .resetAll : .resetSlot;
    if (all) {
      final s = widget.viewModel.themeSettings;
      widget.viewModel.updateThemeSettings(
        s.copyWith(customOverrides: CustomPaletteOverrides.empty),
      );
    } else {
      _applySlotColor(null);
    }
    setState(_syncSlot);
  }

  void _ensureVisible() {
    final vis = max<int>(1, _lastListRows);
    final lo = max<int>(0, _selectedSlotIndex - vis + 1);
    final hi = min<int>(
      _selectedSlotIndex,
      max<int>(0, _slotLabels.length - vis),
    );
    _listScrollOffset = _clampInt(_listScrollOffset, lo, hi);
  }

  void _stepSlot(int delta) => setState(() {
    _selectedSlotIndex =
        (_selectedSlotIndex + delta + _slotLabels.length) % _slotLabels.length;
    _ensureVisible();
    _syncSlot();
  });

  void _onRowTap(int idx, {required bool focusHex}) {
    if (focusHex && idx == _selectedSlotIndex && _focusedControl == .hexInput) {
      _hexFocusNode.requestFocus();
      return;
    }
    _commitOrDiscardPendingHex();
    setState(() {
      _selectedSlotIndex = idx;
      _syncHex();
      _syncSlot();
      _setControl(focusHex ? .hexInput : .slotList);
      _ensureVisible();
    });
  }

  void _onWheelScroll(int delta) {
    final maxOff = max<int>(0, _slotLabels.length - max<int>(1, _lastListRows));
    final next = _clampInt(_listScrollOffset + delta, 0, maxOff);
    if (next == _listScrollOffset) return;
    if (_focusedControl == .hexInput) {
      _commitOrDiscardPendingHex();
      _setControl(.slotList);
    }
    setState(() => _listScrollOffset = next);
  }

  void _stepFocus(int delta) {
    const c = _PaletteControl.values;
    _commitOrDiscardPendingHex();
    setState(
      () =>
          _setControl(c[(_focusedControl.index + delta + c.length) % c.length]),
    );
  }

  void _dismiss(BuildContext context) {
    _dismissing = true;
    PromptScope.of(context)?.done();
  }

  bool _handleKeyEvent(BuildContext context, KeyEvent event) {
    if (_focusedControl == .hexInput) return _handleHexKey(context, event);
    if (event.type == .escape ||
        (event.type == .character && event.key.toLowerCase() == 'q')) {
      _dismiss(context);
      return true;
    }
    if (event.type == .tab || event.key == '\t' || event.key == 'backtab') {
      final s =
          event.key == 'backtab' || event.modifiers.contains(ev.Modifier.shift);
      _stepFocus(s ? -1 : 1);
      return true;
    }
    if (_focusedControl == .slotList) return _handleSlotListKey(event);
    final d = dialogFocusDelta(event);
    if (d != 0) {
      _stepFocus(d);
      return true;
    }
    return _handleControlKey(context, event);
  }

  bool _handleHexKey(BuildContext context, KeyEvent event) {
    final d = dialogFocusDelta(event);
    if (d != 0) {
      _stepFocus(d);
    } else if (event.type == .enter) {
      _applyHexInput();
    } else if (event.type == .escape) {
      _dismiss(context);
    } else {
      return false;
    }
    return true;
  }

  bool _handleSlotListKey(KeyEvent event) {
    final key = event.type == .character ? event.key.toLowerCase() : '';
    if (event.type == .enter) {
      setState(() => _setControl(.hexInput));
    } else if (event.type == .up || key == 'k') {
      _stepSlot(-1);
    } else if (event.type == .down || key == 'j') {
      _stepSlot(1);
    } else if (key == 'r') {
      _reset(all: false, focusButton: false);
    } else {
      return false;
    }
    return true;
  }

  bool _handleControlKey(BuildContext context, KeyEvent event) {
    if (event.type == .character && event.key.toLowerCase() == 'r') {
      _reset(all: false, focusButton: false);
      return true;
    }
    switch (_focusedControl) {
      case .redChannel || .greenChannel || .blueChannel:
        final step = dialogSelectorStepDelta(
          event,
          spaceAndEnterStepForward: true,
        );
        if (step == 0) return false;
        final shift =
            (event.type == .left || event.type == .right) &&
            event.modifiers.contains(ev.Modifier.shift);
        _stepChannel(_focusedControl, step * (shift ? 16 : 1));
      case .resetSlot when isDialogActivateKey(event):
        _reset(all: false);
      case .resetAll when isDialogActivateKey(event):
        _reset(all: true);
      case .close when isDialogActivateKey(event):
        _dismiss(context);
      default:
        return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.viewModel.activeTerminalTheme;
    _lastModelKey = _modelKey;
    final ch = WorkspaceChromeTheme.fromTerminalTheme(theme);
    return WorkspaceChromeScope(
      theme: ch,
      child: DecoratedBox(
        decoration: ch.panelDecoration,
        child: LayoutBuilder(
          builder: (_, o) => Padding(
            padding: EdgeInsets.symmetric(
              horizontal: o.maxWidth < 44 ? 1 : 2,
              vertical: o.maxHeight < 24 ? 0 : 1,
            ),
            child: FocusScope(
              autofocus: true,
              onKeyEvent: (e) => _handleKeyEvent(context, e),
              child: LayoutBuilder(
                builder: (_, c) => Column([
                  Text(
                    'Customize ANSI Palette',
                    style: ch.titleStyle,
                    wrap: false,
                  ),
                  Expanded(
                    child: c.maxHeight <= 2
                        ? const SizedBox.shrink()
                        : _buildPaletteBody(
                            this,
                            ch,
                            c.maxWidth,
                            c.maxHeight - 2,
                          ),
                  ),
                  Button(
                    text: 'Close (Esc)',
                    focused: _focusedControl == .close,
                    onPressed: () => _dismiss(context),
                    style: ch.buttonStyle,
                    focusedStyle: ch.focusedButtonStyle,
                  ),
                ], crossAxisAlignment: .stretch),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
