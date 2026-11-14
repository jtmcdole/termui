import 'dart:async';
import 'dart:math';

import 'package:termui/terminal/event.dart' as ev;
import 'package:termui/termui.dart';

/// Shared panel border and background decoration for workspace modal dialogs.
const BoxDecoration dialogPanelDecoration = BoxDecoration(
  backgroundColor: Color(20, 24, 32),
  border: Border.all(Style(foreground: Color(98, 209, 150))),
);

/// Shared bold header title style for workspace modal dialogs.
const Style dialogTitleStyle = Style(
  foreground: Color(255, 220, 120),
  modifiers: Modifier.bold,
);

/// Shared body text style for workspace modal dialogs.
const Style dialogRowStyle = Style(foreground: Color(210, 220, 235));

/// Shared footer hint style for workspace modal dialogs.
const Style dialogHintStyle = Style(foreground: Color(120, 134, 156));

/// Shared unfocused action button style for workspace modal dialogs.
const Style dialogButtonStyle = Style(
  foreground: Color(98, 209, 150),
  modifiers: Modifier.bold,
);

/// Shared focused action button style for workspace modal dialogs.
const Style dialogFocusedButtonStyle = Style(
  foreground: Color(20, 24, 32),
  background: Color(98, 209, 150),
  modifiers: Modifier.bold,
);

const Style _defaultDialogLabelStyle = Style(foreground: Color(180, 192, 210));

const Style _defaultDialogInlineErrorStyle = Style(
  foreground: Color(255, 110, 110),
  modifiers: Modifier.bold,
);

/// Modal backdrop dimming arguments derived from the active terminal theme.
typedef ModalBackdropArgs = ({
  Color? barrierColor,
  Color? defaultForeground,
  Color? defaultBackground,
  TerminalColorTheme? palette,
});

/// Coordinated chrome, dialog, and dock bar styling derived from a [TerminalColorTheme].
final class WorkspaceChromeTheme {
  /// Default dark chrome matching existing TermUI Dark constants.
  static const WorkspaceChromeTheme defaultDark = WorkspaceChromeTheme(
    panelDecoration: dialogPanelDecoration,
    titleStyle: dialogTitleStyle,
    rowStyle: dialogRowStyle,
    labelStyle: _defaultDialogLabelStyle,
    hintStyle: dialogHintStyle,
    inlineErrorStyle: _defaultDialogInlineErrorStyle,
    buttonStyle: dialogButtonStyle,
    focusedButtonStyle: dialogFocusedButtonStyle,
    barStyle: Style(
      foreground: Color(200, 210, 225),
      background: Color(24, 28, 36),
    ),
    activeTabStyle: Style(
      foreground: Color(20, 24, 32),
      background: Color(98, 209, 150),
      modifiers: Modifier.bold,
    ),
    inactiveTabStyle: Style(
      foreground: Color(190, 200, 216),
      background: Color(38, 44, 56),
    ),
    toggleStyle: Style(
      foreground: Color(255, 220, 120),
      background: Color(48, 56, 72),
      modifiers: Modifier.bold,
    ),
    actionButtonStyle: Style(
      foreground: Color(130, 218, 255),
      background: Color(38, 46, 62),
      modifiers: Modifier.bold,
    ),
    disabledOverflowStyle: Style(
      foreground: Color(96, 108, 128),
      background: Color(28, 33, 44),
    ),
    warningBannerStyle: Style(
      foreground: Color(20, 24, 32),
      background: Color(235, 185, 78),
      modifiers: Modifier.bold,
    ),
    errorBannerStyle: Style(
      foreground: Color(255, 245, 245),
      background: Color(156, 36, 48),
      modifiers: Modifier.bold,
    ),
    barrierColor: null,
  );

  /// Panel background and border.
  final BoxDecoration panelDecoration;

  /// Header title style.
  final Style titleStyle;

  /// Body text style.
  final Style rowStyle;

  /// Input field label style.
  final Style labelStyle;

  /// Footer hint style.
  final Style hintStyle;

  /// Inline validation error text style on dialog panels.
  final Style inlineErrorStyle;

  /// Unfocused button style.
  final Style buttonStyle;

  /// Focused button style.
  final Style focusedButtonStyle;

  /// Tab bar / dock background and default text style.
  final Style barStyle;

  /// Active tab style.
  final Style activeTabStyle;

  /// Inactive tab style.
  final Style inactiveTabStyle;

  /// Toggle button (`[Dock]`) style.
  final Style toggleStyle;

  /// Action button (`[?]`, `[Stats]`, `[⚙]`) style.
  final Style actionButtonStyle;

  /// Disabled overflow arrow button style.
  final Style disabledOverflowStyle;

  /// Warning banner style.
  final Style warningBannerStyle;

  /// Error banner style.
  final Style errorBannerStyle;

  /// Modal dialog backdrop barrier tint color (`null` for default black dim).
  final Color? barrierColor;

  /// Creates an immutable workspace chrome theme.
  const WorkspaceChromeTheme({
    required this.panelDecoration,
    required this.titleStyle,
    required this.rowStyle,
    this.labelStyle = _defaultDialogLabelStyle,
    required this.hintStyle,
    this.inlineErrorStyle = _defaultDialogInlineErrorStyle,
    required this.buttonStyle,
    required this.focusedButtonStyle,
    required this.barStyle,
    required this.activeTabStyle,
    required this.inactiveTabStyle,
    required this.toggleStyle,
    required this.actionButtonStyle,
    required this.disabledOverflowStyle,
    required this.warningBannerStyle,
    required this.errorBannerStyle,
    this.barrierColor,
  });

  /// Shifts each RGB channel of [color] by [delta], clamping to `0..255`.
  static Color shiftRgb(Color color, int delta) => Color(
    (color.r + delta).clamp(0, 255),
    (color.g + delta).clamp(0, 255),
    (color.b + delta).clamp(0, 255),
  );

  static Color _contrastOn(Color candidate, Color bg, double minRatio) {
    final seed = candidate == bg
        ? (TerminalContrast.relativeLuminance(bg) < 0.5
              ? Colors.white
              : Colors.black)
        : candidate;
    return TerminalContrast.enforceMinimumContrast(
      seed,
      bg,
      minRatio: minRatio,
    );
  }

  static Color _panelBackgroundFor(Color bg, {required bool isDark}) => isDark
      ? Color(
          (bg.r ~/ 2).clamp(0, 255),
          (bg.g ~/ 2).clamp(0, 255),
          (bg.b ~/ 2).clamp(0, 255),
        )
      : Color(
          ((bg.r + 255) ~/ 2).clamp(0, 255),
          ((bg.g + 255) ~/ 2).clamp(0, 255),
          ((bg.b + 255) ~/ 2).clamp(0, 255),
        );

  static Color _barBackgroundFor(Color bg, {required bool isDark}) => isDark
      ? Color(
          (bg.r * 3 ~/ 4).clamp(0, 255),
          (bg.g * 3 ~/ 4).clamp(0, 255),
          (bg.b * 3 ~/ 4).clamp(0, 255),
        )
      : Color(
          ((bg.r + 200) ~/ 2).clamp(0, 255),
          ((bg.g + 200) ~/ 2).clamp(0, 255),
          ((bg.b + 200) ~/ 2).clamp(0, 255),
        );

  /// Derives chrome styles from [theme], returning exact [defaultDark] constants for `termui_dark`.
  factory WorkspaceChromeTheme.fromTerminalTheme(TerminalColorTheme theme) {
    if (theme.id == 'termui_dark' && theme == TerminalColorTheme.termuiDark) {
      return defaultDark;
    }

    final isDark = theme.brightness == .dark;
    final bg = theme.background;
    final fg = theme.foreground;
    final accent = theme.cursorColor;
    final panelBg = _panelBackgroundFor(bg, isDark: isDark);
    final barBg = _barBackgroundFor(bg, isDark: isDark);
    final inactiveTabBg = shiftRgb(bg, isDark ? 20 : -20);

    final borderColor = _contrastOn(
      isDark ? theme.ansi[2] : theme.ansi[4],
      panelBg,
      3.5,
    );
    final rowFg = _contrastOn(fg, panelBg, 4.5);
    final titleFg = _contrastOn(
      isDark ? theme.ansi[3] : theme.ansi[11],
      panelBg,
      4.5,
    );
    final hintFg = _contrastOn(theme.ansi[8], panelBg, 3.5);
    final inlineErrorFg = _contrastOn(theme.ansi[1], panelBg, 4.5);
    final focusedBtnFg = TerminalContrast.ensureReadableTextOn(bg, borderColor);
    final activeTabFg = TerminalContrast.ensureReadableTextOn(bg, accent);
    final warnBg = theme.ansi[3];
    final errBg = theme.ansi[1];

    return WorkspaceChromeTheme(
      panelDecoration: BoxDecoration(
        backgroundColor: panelBg,
        border: Border.all(Style(foreground: borderColor)),
      ),
      titleStyle: Style(foreground: titleFg, modifiers: Modifier.bold),
      rowStyle: Style(foreground: rowFg),
      labelStyle: Style(foreground: rowFg),
      hintStyle: Style(foreground: hintFg),
      inlineErrorStyle: Style(
        foreground: inlineErrorFg,
        modifiers: Modifier.bold,
      ),
      buttonStyle: Style(foreground: borderColor, modifiers: Modifier.bold),
      focusedButtonStyle: Style(
        foreground: focusedBtnFg,
        background: borderColor,
        modifiers: Modifier.bold,
      ),
      barStyle: Style(
        foreground: _contrastOn(fg, barBg, 3.5),
        background: barBg,
      ),
      activeTabStyle: Style(
        foreground: activeTabFg,
        background: accent,
        modifiers: Modifier.bold,
      ),
      inactiveTabStyle: Style(
        foreground: _contrastOn(fg, inactiveTabBg, 3.5),
        background: inactiveTabBg,
      ),
      toggleStyle: Style(
        foreground: _contrastOn(theme.ansi[3], inactiveTabBg, 3.0),
        background: inactiveTabBg,
        modifiers: Modifier.bold,
      ),
      actionButtonStyle: Style(
        foreground: _contrastOn(theme.ansi[4], inactiveTabBg, 3.0),
        background: inactiveTabBg,
        modifiers: Modifier.bold,
      ),
      disabledOverflowStyle: Style(
        foreground: _contrastOn(theme.ansi[8], barBg, 2.5),
        background: barBg,
      ),
      warningBannerStyle: Style(
        foreground: TerminalContrast.ensureReadableTextOn(
          const Color(20, 24, 32),
          warnBg,
        ),
        background: warnBg,
        modifiers: Modifier.bold,
      ),
      errorBannerStyle: Style(
        foreground: TerminalContrast.ensureReadableTextOn(
          const Color(255, 255, 255),
          errBg,
        ),
        background: errBg,
        modifiers: Modifier.bold,
      ),
      barrierColor: isDark ? null : const Color(200, 205, 215),
    );
  }

  /// Resolves modal dimming backdrop arguments for [theme], keeping default
  /// `termui_dark` backdrops byte-identical while theming light and non-default
  /// dark presets (such as `solarized_dark`).
  ModalBackdropArgs backdropArgsFor(TerminalColorTheme theme) {
    if (theme.id == 'termui_dark' &&
        theme.background == TerminalColorTheme.termuiDark.background) {
      return (
        barrierColor: null,
        defaultForeground: null,
        defaultBackground: null,
        palette: null,
      );
    }
    return (
      barrierColor: barrierColor,
      defaultForeground: theme.foreground,
      defaultBackground: theme.background,
      palette: theme,
    );
  }

  static bool _sameDecoration(BoxDecoration a, BoxDecoration b) =>
      a.backgroundColor == b.backgroundColor &&
      a.backgroundStyle == b.backgroundStyle &&
      a.border?.style == b.border?.style &&
      a.border?.topChar == b.border?.topChar;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkspaceChromeTheme &&
          _sameDecoration(panelDecoration, other.panelDecoration) &&
          titleStyle == other.titleStyle &&
          rowStyle == other.rowStyle &&
          labelStyle == other.labelStyle &&
          hintStyle == other.hintStyle &&
          inlineErrorStyle == other.inlineErrorStyle &&
          buttonStyle == other.buttonStyle &&
          focusedButtonStyle == other.focusedButtonStyle &&
          barStyle == other.barStyle &&
          activeTabStyle == other.activeTabStyle &&
          inactiveTabStyle == other.inactiveTabStyle &&
          toggleStyle == other.toggleStyle &&
          actionButtonStyle == other.actionButtonStyle &&
          disabledOverflowStyle == other.disabledOverflowStyle &&
          warningBannerStyle == other.warningBannerStyle &&
          errorBannerStyle == other.errorBannerStyle &&
          barrierColor == other.barrierColor;

  @override
  int get hashCode => Object.hash(
    panelDecoration.backgroundColor,
    panelDecoration.border?.style,
    titleStyle,
    rowStyle,
    labelStyle,
    hintStyle,
    inlineErrorStyle,
    buttonStyle,
    focusedButtonStyle,
    barStyle,
    activeTabStyle,
    inactiveTabStyle,
    toggleStyle,
    actionButtonStyle,
    disabledOverflowStyle,
    warningBannerStyle,
    errorBannerStyle,
    barrierColor,
  );
}

/// Provides [WorkspaceChromeTheme] down the `termui` widget tree via [InheritedWidget].
final class WorkspaceChromeScope extends InheritedWidget {
  /// Active chrome theme.
  final WorkspaceChromeTheme theme;

  /// Creates a workspace chrome scope.
  const WorkspaceChromeScope({required this.theme, required super.child});

  /// Retrieves the ambient [WorkspaceChromeTheme] from [context], or [WorkspaceChromeTheme.defaultDark].
  static WorkspaceChromeTheme of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<WorkspaceChromeScope>();
    return scope?.theme ?? WorkspaceChromeTheme.defaultDark;
  }

  @override
  bool updateShouldNotify(WorkspaceChromeScope oldWidget) =>
      theme != oldWidget.theme;
}

/// Displays a centered modal dialog on [sceneManager] wrapped in [WorkspaceChromeScope]
/// with backdrop arguments derived from [terminalTheme] or explicit overrides.
Future<T?> showThemedDialog<T>(
  SceneManager sceneManager, {
  required int width,
  required int height,
  TerminalColorTheme? terminalTheme,
  WorkspaceChromeTheme? chromeTheme,
  Color? barrierColor,
  Color? defaultForeground,
  Color? defaultBackground,
  bool barrierDismissible = true,
  required WidgetBuilder builder,
}) {
  final chrome =
      chromeTheme ??
      (terminalTheme != null
          ? WorkspaceChromeTheme.fromTerminalTheme(terminalTheme)
          : WorkspaceChromeTheme.defaultDark);
  final backdrop = terminalTheme != null
      ? chrome.backdropArgsFor(terminalTheme)
      : (
          barrierColor: chrome.barrierColor,
          defaultForeground: null,
          defaultBackground: null,
          palette: null,
        );
  return sceneManager.showDialog<T>(
    width: width,
    height: height,
    barrierColor: barrierColor ?? backdrop.barrierColor,
    defaultForeground: defaultForeground ?? backdrop.defaultForeground,
    defaultBackground: defaultBackground ?? backdrop.defaultBackground,
    palette: backdrop.palette ?? TerminalColorTheme.legacyVga,
    barrierDismissible: barrierDismissible,
    builder: (context) =>
        WorkspaceChromeScope(theme: chrome, child: builder(context)),
  );
}

/// Returns the index in [steps] whose value is closest to [value].
int nearestStepIndex(List<double> steps, double value) {
  var bestIdx = 0;
  var bestDiff = (value - steps[0]).abs();
  for (var i = 1; i < steps.length; i++) {
    final diff = (value - steps[i]).abs();
    if (diff < bestDiff) {
      bestDiff = diff;
      bestIdx = i;
    }
  }
  return bestIdx;
}

/// Returns `-1` for previous-focus keys (`Up`/`Shift+Tab`), `1` for next-focus
/// keys (`Down`/`Tab`), or `0` otherwise.
int dialogFocusDelta(KeyEvent event) {
  if (event.type == .down) return 1;
  if (event.type == .up || event.key == 'backtab') return -1;
  if (event.type == .tab || event.key == '\t') {
    return event.modifiers.contains(ev.Modifier.shift) ? -1 : 1;
  }
  return 0;
}

/// Whether [event] is a modal control activation key (`Enter` or `Space`).
bool isDialogActivateKey(KeyEvent event) =>
    event.type == .enter || (event.type == .character && event.key == ' ');

/// Returns `-1` or `1` when [event] steps a `< ... >` selector, or `0` otherwise.
int dialogSelectorStepDelta(
  KeyEvent event, {
  bool spaceAndEnterStepForward = false,
}) {
  if (event.type == .left ||
      (event.type == .character && event.key.toLowerCase() == 'h')) {
    return -1;
  }
  if (event.type == .right ||
      (event.type == .character && event.key.toLowerCase() == 'l') ||
      (spaceAndEnterStepForward && isDialogActivateKey(event))) {
    return 1;
  }
  return 0;
}

/// Clamps a modal dialog's `(width, height)` within [terminalSize].
Point<int> clampDialogSize(
  Point<int> terminalSize, {
  required int preferredWidth,
  required int minWidth,
  int horizontalMargin = 4,
  required int preferredHeight,
  int minHeight = 8,
  int verticalMargin = 2,
}) {
  final maxW = max(1, terminalSize.x);
  final maxH = max(1, terminalSize.y);
  final dialogW = min(
    preferredWidth,
    max(minWidth, maxW - horizontalMargin),
  ).clamp(1, maxW);
  final dialogH = min(
    preferredHeight,
    max(minHeight, maxH - verticalMargin),
  ).clamp(1, maxH);
  return Point<int>(dialogW, dialogH);
}

/// Formats a byte count into `B`, `KB`, or `MB` for modal dialog labels.
String formatDialogByteCount(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
}

/// Shared 3-row boxed single-line [TextField] used in modal dialogs.
final class DialogInputField extends StatelessWidget {
  static const BoxDecoration _focusedBox = BoxDecoration(
    backgroundColor: Color(32, 42, 58),
    border: Border.all(
      Style(foreground: Color(98, 209, 150), modifiers: Modifier.bold),
    ),
  );
  static const BoxDecoration _unfocusedBox = BoxDecoration(
    backgroundColor: Color(24, 29, 40),
    border: Border.all(Style(foreground: Color(76, 88, 108))),
  );
  static const Style _focusedTextStyle = Style(
    foreground: Color(242, 247, 255),
    background: Color(32, 42, 58),
  );
  static const Style _unfocusedTextStyle = Style(
    foreground: Color(210, 220, 235),
    background: Color(24, 29, 40),
  );
  static const Style _placeholderStyle = Style(
    foreground: Color(116, 130, 152),
    background: Color(24, 29, 40),
  );
  static const Style _cursorStyle = Style(
    foreground: Color(20, 24, 32),
    background: Color(98, 209, 150),
    modifiers: Modifier.bold | Modifier.underline,
  );

  /// Backing text editing controller.
  final TextEditingController controller;

  /// Backing focus node for the text field.
  final FocusNode focusNode;

  /// Whether input characters should be masked with `*`.
  final bool obscureText;

  /// Placeholder text rendered when unfocused and empty.
  final String placeholder;

  /// Whether the field is currently focused.
  final bool isFocused;

  /// Callback invoked when the field's focus state changes.
  final void Function(bool hasFocus) onFocusChange;

  /// Creates a boxed modal input field.
  const DialogInputField({
    super.key,
    required this.controller,
    required this.focusNode,
    this.obscureText = false,
    this.placeholder = '',
    required this.isFocused,
    required this.onFocusChange,
  });

  static ({
    BoxDecoration box,
    Style textStyle,
    Style placeholderStyle,
    Style cursorStyle,
  })
  _resolveStyles(WorkspaceChromeTheme chrome, {required bool isFocused}) {
    if (chrome == WorkspaceChromeTheme.defaultDark) {
      return (
        box: isFocused ? _focusedBox : _unfocusedBox,
        textStyle: isFocused ? _focusedTextStyle : _unfocusedTextStyle,
        placeholderStyle: _placeholderStyle,
        cursorStyle: _cursorStyle,
      );
    }

    final panelBg =
        chrome.panelDecoration.backgroundColor ?? const Color(20, 24, 32);
    final isLightPanel = TerminalContrast.relativeLuminance(panelBg) >= 0.5;
    final unfocusedBg = WorkspaceChromeTheme.shiftRgb(
      panelBg,
      isLightPanel ? -8 : 8,
    );
    final focusedBg = WorkspaceChromeTheme.shiftRgb(
      panelBg,
      isLightPanel ? -16 : 16,
    );
    final activeBg = isFocused ? focusedBg : unfocusedBg;
    final textFg = TerminalContrast.enforceMinimumContrast(
      chrome.rowStyle.foreground ?? const Color(210, 220, 235),
      activeBg,
      minRatio: 4.5,
    );
    final placeholderFg = TerminalContrast.enforceMinimumContrast(
      chrome.hintStyle.foreground ?? const Color(116, 130, 152),
      unfocusedBg,
      minRatio: 3.5,
    );
    final borderStyle = isFocused
        ? Style(
            foreground: chrome.buttonStyle.foreground,
            modifiers: Modifier.bold,
          )
        : Style(foreground: chrome.hintStyle.foreground);

    return (
      box: BoxDecoration(
        backgroundColor: activeBg,
        border: Border.all(borderStyle),
      ),
      textStyle: Style(foreground: textFg, background: activeBg),
      placeholderStyle: Style(
        foreground: placeholderFg,
        background: unfocusedBg,
      ),
      cursorStyle: Style(
        foreground: chrome.focusedButtonStyle.foreground,
        background: chrome.focusedButtonStyle.background,
        modifiers: Modifier.bold | Modifier.underline,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chrome = WorkspaceChromeScope.of(context);
    final styles = _resolveStyles(chrome, isFocused: isFocused);
    return SizedBox(
      height: 3,
      child: DialogFocusOnTap(
        focusNode: focusNode,
        child: DecoratedBox(
          decoration: styles.box,
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            focused: isFocused,
            multiline: false,
            obscureText: obscureText,
            obscuringCharacter: '*',
            placeholder: isFocused ? '' : placeholder,
            style: styles.textStyle,
            placeholderStyle: styles.placeholderStyle,
            cursorStyle: styles.cursorStyle,
            onFocusChange: onFocusChange,
          ),
        ),
      ),
    );
  }
}

/// Requests focus on [focusNode] when clicked with the primary mouse button.
final class DialogFocusOnTap extends StatelessWidget
    implements MouseEventHandler {
  /// Focus node to activate on left mouse press.
  final FocusNode focusNode;

  /// Wrapped child widget.
  final Widget child;

  /// Creates a click-to-focus wrapper.
  const DialogFocusOnTap({
    super.key,
    required this.focusNode,
    required this.child,
  });

  @override
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    if (event.type == .press && event.button == .left) {
      focusNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) => child;
}

/// Wraps a `< ... >` selector row so left-clicking focuses it and steps the
/// value (`-1` when clicking `<` at [leftArrowOffset], `+1` elsewhere).
final class DialogSelectorTapTarget extends StatelessWidget
    implements MouseEventHandler {
  /// 0-based column offset of the `<` character inside [child].
  final int leftArrowOffset;

  /// Callback invoked with `-1` or `1` on primary mouse press.
  final void Function(int delta) onStep;

  /// Wrapped selector row widget.
  final Widget child;

  /// Creates a clickable selector wrapper.
  const DialogSelectorTapTarget({
    super.key,
    required this.leftArrowOffset,
    required this.onStep,
    required this.child,
  });

  @override
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    if (event.type == .press && event.button == .left) {
      onStep(localX == leftArrowOffset ? -1 : 1);
    }
  }

  @override
  Widget build(BuildContext context) => child;
}
