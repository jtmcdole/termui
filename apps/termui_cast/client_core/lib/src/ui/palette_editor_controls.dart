part of 'palette_editor_dialog.dart';

enum _PaletteControl {
  slotList,
  hexInput,
  redChannel,
  greenChannel,
  blueChannel,
  resetSlot,
  resetAll,
  close,
}

const List<String> _slotLabels = [
  '0  Black',
  '1  Red',
  '2  Green',
  '3  Yellow',
  '4  Blue',
  '5  Magenta',
  '6  Cyan',
  '7  White',
  '8  Brt Black',
  '9  Brt Red',
  '10 Brt Green',
  '11 Brt Yellw',
  '12 Brt Blue',
  '13 Brt Magnt',
  '14 Brt Cyan',
  '15 Brt White',
  'FG Foregrnd',
  'BG Backgrnd',
  'CR Cursor',
  'SL Selection',
];

int _clampInt(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

Color _stepRgb(Color c, _PaletteControl ctrl, int d) => switch (ctrl) {
  .redChannel => Color(_clampInt(c.r + d, 0, 255), c.g, c.b),
  .greenChannel => Color(c.r, _clampInt(c.g + d, 0, 255), c.b),
  .blueChannel => Color(c.r, c.g, _clampInt(c.b + d, 0, 255)),
  _ => c,
};

Color _resolveSlot(TerminalColorTheme t, int i) => switch (i) {
  < 16 => t.ansi[i],
  16 => t.foreground,
  17 => t.background,
  18 => t.cursorColor,
  _ => t.selectionBackground,
};

bool _isSlotOverridden(CustomPaletteOverrides o, int i) => switch (i) {
  < 16 => o.ansiOverrides[i] != null,
  16 => o.foreground != null,
  17 => o.background != null,
  18 => o.cursorColor != null,
  _ => o.selectionBackground != null,
};

CustomPaletteOverrides _withSlotOverride(
  CustomPaletteOverrides o,
  int i,
  Color? c,
) => switch (i) {
  < 16 => o.withAnsiSlot(i, c),
  16 => o.copyWith(foreground: c, clearForeground: c == null),
  17 => o.copyWith(background: c, clearBackground: c == null),
  18 => o.copyWith(cursorColor: c, clearCursorColor: c == null),
  _ => o.copyWith(selectionBackground: c, clearSelectionBackground: c == null),
};

String _formatContrast(Color color, Color bg, int maxWidth) {
  final r = TerminalContrast.contrastRatio(color, bg);
  final tier = r >= 7.0 ? 'AAA' : (r >= 4.5 ? 'AA' : (r >= 3.0 ? 'UI' : 'Low'));
  final full = 'Contrast vs bg: ${r.toStringAsFixed(1)}:1 ($tier)';
  if (full.length <= maxWidth) return full;
  final med = 'Contrast: ${r.toStringAsFixed(1)}:1 ($tier)';
  return med.length <= maxWidth ? med : 'Bg: ${r.toStringAsFixed(1)}:1 ($tier)';
}

({bool compact, int nameW, int hexCol}) _rowMetrics(
  int w, {
  required bool wide,
}) {
  if (wide || w >= 38) return (compact: false, nameW: 12, hexCol: 24);
  final nw = _clampInt(w - 18, 4, 12);
  return (compact: true, nameW: nw, hexCol: nw + 8);
}

final class _SlotListPane extends StatelessWidget implements MouseEventHandler {
  final _PaletteEditorDialogState s;
  final TerminalColorTheme theme;
  final int scroll;
  final int rows;
  final ({bool compact, int nameW, int hexCol}) m;

  const _SlotListPane(this.s, this.theme, this.scroll, this.rows, this.m);

  @override
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    if (event.type != .press) return;
    if (event.button == .wheelUp || event.button == .wheelDown) {
      s._onWheelScroll(event.button == .wheelUp ? -1 : 1);
      return;
    }
    if (event.button == .left) {
      final idx = scroll + localY;
      if (idx >= 0 && idx < _slotLabels.length) {
        s._onRowTap(idx, focusHex: localX >= m.hexCol);
      }
    }
  }

  static (Style, Style) _hexStyles(WorkspaceChromeTheme ch) {
    if (ch == WorkspaceChromeTheme.defaultDark) {
      return (
        const Style(
          foreground: Color(242, 247, 255),
          background: Color(32, 42, 58),
        ),
        const Style(
          foreground: Color(20, 24, 32),
          background: Color(98, 209, 150),
          modifiers: Modifier.bold | Modifier.underline,
        ),
      );
    }
    final bg = ch.panelDecoration.backgroundColor ?? const Color(20, 24, 32);
    final activeBg = WorkspaceChromeTheme.shiftRgb(
      bg,
      TerminalContrast.relativeLuminance(bg) >= 0.5 ? -16 : 16,
    );
    final fg = TerminalContrast.enforceMinimumContrast(
      ch.rowStyle.foreground ?? const Color(210, 220, 235),
      activeBg,
      minRatio: 4.5,
    );
    return (
      Style(foreground: fg, background: activeBg),
      Style(
        foreground: ch.focusedButtonStyle.foreground,
        background: ch.focusedButtonStyle.background,
        modifiers: Modifier.bold | Modifier.underline,
      ),
    );
  }

  Widget _row(WorkspaceChromeTheme ch, (Style, Style) styles, int idx) {
    final color = _resolveSlot(theme, idx);
    final sel = idx == s._selectedSlotIndex;
    final overrides = s.widget.viewModel.themeSettings.customOverrides;
    final mark = _isSlotOverridden(overrides, idx) ? '*' : ' ';
    final label = _slotLabels[idx];
    final padded = label.length > m.nameW
        ? label.substring(0, m.nameW)
        : label.padRight(m.nameW);
    final nameStyle = sel
        ? (s._focusedControl == .slotList
              ? ch.focusedButtonStyle
              : ch.titleStyle)
        : ch.rowStyle;
    final (hexStyle, curStyle) = styles;
    final Widget hexCell = sel && s._focusedControl == .hexInput
        ? SizedBox(
            width: 7,
            height: 1,
            child: TextField(
              controller: s._hexController,
              focusNode: s._hexFocusNode,
              focused: true,
              multiline: false,
              style: hexStyle,
              cursorStyle: curStyle,
              onFocusChange: s._onHexFocusChange,
            ),
          )
        : Text(
            CustomPaletteOverrides.formatHexRgb(color),
            style: ch.rowStyle,
            wrap: false,
          );

    return Row([
      Text('${sel ? '▸ ' : '  '}$padded', style: nameStyle, wrap: false),
      Text(m.compact ? ' [' : ' - [', style: ch.rowStyle, wrap: false),
      Text('██', style: Style(foreground: color), wrap: false),
      Text(m.compact ? '] [' : '] - [', style: ch.rowStyle, wrap: false),
      hexCell,
      Text(']$mark', style: ch.rowStyle, wrap: false),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final ch = WorkspaceChromeScope.of(context);
    final styles = _hexStyles(ch);
    final n = min<int>(rows, max<int>(0, _slotLabels.length - scroll));
    return Column([
      for (var i = 0; i < n; i++) _row(ch, styles, scroll + i),
    ], crossAxisAlignment: .stretch);
  }
}

Widget _stepper(
  _PaletteEditorDialogState s,
  WorkspaceChromeTheme ch,
  String label,
  int val,
  _PaletteControl ctrl, {
  required bool compact,
}) {
  final dec = '$val'.padLeft(3);
  final prefix = compact ? '$label:' : '$label: ';
  final hex = val.toRadixString(16).toUpperCase().padLeft(2, '0');
  final valueText = compact ? '<$dec>' : '< $dec ($hex) >';
  return DialogSelectorTapTarget(
    leftArrowOffset: prefix.length,
    onStep: (d) => s._stepChannel(ctrl, d, focus: true),
    child: Row([
      Text(prefix, style: ch.rowStyle, wrap: false),
      Text(
        valueText,
        style: s._focusedControl == ctrl ? ch.focusedButtonStyle : ch.rowStyle,
        wrap: false,
      ),
    ]),
  );
}

List<Widget> _footerWidgets(
  _PaletteEditorDialogState s,
  WorkspaceChromeTheme ch,
  Color color,
  Color bg,
  int maxW, {
  required bool showContrast,
  required bool allowShortAll,
  required String? hint,
}) {
  final overrides = s.widget.viewModel.themeSettings.customOverrides;
  final overridden = _isSlotOverridden(overrides, s._selectedSlotIndex);
  final fullSlot = maxW >= 34;
  final slotText = fullSlot
      ? (overridden ? 'Reset Slot (r)' : 'Reset Slot')
      : 'Reset';
  final allText = (fullSlot || !allowShortAll)
      ? (!overrides.isEmpty ? 'Reset All *' : 'Reset All')
      : (!overrides.isEmpty ? 'All *' : 'All');
  return [
    if (showContrast)
      Text(_formatContrast(color, bg, maxW), style: ch.hintStyle, wrap: false),
    if (s._hexError != null)
      Text(s._hexError!, style: ch.errorBannerStyle, wrap: false),
    Row([
      Button(
        text: slotText,
        focused: s._focusedControl == .resetSlot,
        onPressed: () => s._reset(all: false),
        style: ch.buttonStyle,
        focusedStyle: ch.focusedButtonStyle,
      ),
      const SizedBox(width: 1),
      Button(
        text: allText,
        focused: s._focusedControl == .resetAll,
        onPressed: () => s._reset(all: true),
        style: ch.buttonStyle,
        focusedStyle: ch.focusedButtonStyle,
      ),
    ]),
    if (hint != null) Text(hint, style: ch.hintStyle, wrap: false),
  ];
}

Widget _buildPaletteBody(
  _PaletteEditorDialogState s,
  WorkspaceChromeTheme ch,
  int maxW,
  int maxR,
) {
  final theme = s.widget.viewModel.activeTerminalTheme;
  final isWide = maxW >= 58 && maxR >= 12;
  final fixed =
      2 +
      (maxR >= 8 ? 1 : 0) +
      (s._hexError != null ? 1 : 0) +
      (maxR >= 9 ? 1 : 0);
  final listRows = isWide
      ? min<int>(_slotLabels.length, maxR)
      : max<int>(1, min<int>(_slotLabels.length, maxR - fixed));
  if (Zone.current[#isMeasuringIntrinsics] != true) s._lastListRows = listRows;
  final maxOff = max<int>(0, _slotLabels.length - listRows);
  var scroll = _clampInt(s._listScrollOffset, 0, maxOff);
  if (s._focusedControl == .hexInput) {
    final lo = max<int>(0, s._selectedSlotIndex - listRows + 1);
    scroll = _clampInt(scroll, lo, min<int>(s._selectedSlotIndex, maxOff));
  }
  final c = _resolveSlot(theme, s._selectedSlotIndex);

  Widget listPane(int paneW, {required bool wide}) => Focus(
    focusNode: s._slotFocusNode,
    autofocus: true,
    child: _SlotListPane(
      s,
      theme,
      scroll,
      listRows,
      _rowMetrics(paneW, wide: wide),
    ),
  );

  if (!isWide) {
    final wideSteppers = maxW >= 50;
    final gap = wideSteppers ? 2 : 1;
    return Column([
      listPane(maxW, wide: false),
      Row([
        _stepper(s, ch, 'R', c.r, .redChannel, compact: !wideSteppers),
        SizedBox(width: gap),
        _stepper(s, ch, 'G', c.g, .greenChannel, compact: !wideSteppers),
        SizedBox(width: gap),
        _stepper(s, ch, 'B', c.b, .blueChannel, compact: !wideSteppers),
      ]),
      ..._footerWidgets(
        s,
        ch,
        c,
        theme.background,
        maxW,
        showContrast: maxR >= 8,
        allowShortAll: false,
        hint: maxR >= 9 ? 'Up/Dn: slot | Tab: next | L/R: RGB' : null,
      ),
    ], crossAxisAlignment: .stretch);
  }

  const leftW = 34;
  final rightW = max<int>(1, maxW - leftW - 3);
  return Row([
    SizedBox(width: leftW, child: listPane(leftW, wide: true)),
    SizedBox(
      width: 3,
      child: Column([
        for (var i = 0; i < maxR; i++)
          Text(' │ ', style: ch.hintStyle, wrap: false),
      ]),
    ),
    Expanded(child: _buildWideRight(s, ch, theme, c, rightW, maxR)),
  ]);
}

Widget _buildWideRight(
  _PaletteEditorDialogState s,
  WorkspaceChromeTheme ch,
  TerminalColorTheme theme,
  Color c,
  int rightW,
  int maxR,
) {
  final twoCol = rightW >= 34;
  final panelBg = ch.panelDecoration.backgroundColor ?? theme.background;
  return Column([
    Expanded(
      child: HsvColorWheelPicker(
        hsvColor: s._workingHsv,
        cellPixelSize: s.widget.viewModel.cellPixelSize,
        panelBackgroundColor: panelBg,
        onChanged: s._onWheelChanged,
      ),
    ),
    if (twoCol)
      Row([
        _stepper(s, ch, 'R', c.r, .redChannel, compact: false),
        const SizedBox(width: 2),
        _stepper(s, ch, 'G', c.g, .greenChannel, compact: false),
      ])
    else ...[
      Row([_stepper(s, ch, 'R', c.r, .redChannel, compact: false)]),
      Row([_stepper(s, ch, 'G', c.g, .greenChannel, compact: false)]),
    ],
    Row([_stepper(s, ch, 'B', c.b, .blueChannel, compact: false)]),
    ..._footerWidgets(
      s,
      ch,
      c,
      theme.background,
      rightW,
      showContrast: true,
      allowShortAll: true,
      hint: maxR >= 14
          ? (twoCol
                ? 'Up/Dn: slot | Tab: next | L/R: RGB'
                : 'Up/Dn:slot L/R:RGB')
          : null,
    ),
  ], crossAxisAlignment: .stretch);
}
