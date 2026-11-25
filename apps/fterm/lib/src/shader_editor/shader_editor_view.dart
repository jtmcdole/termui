import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:termui/syntax.dart';
import 'package:termui/terminal/event.dart' as ev;
import 'package:termui/termui.dart' as tui;
import 'package:termui_flutter/termui_flutter.dart';

import 'shader_editor_controller.dart';

/// Pure `termui` widget tree rendering the in-app GLSL shader editor.
///
/// Composes four vertical bands using [tui.RichText] and a styled multiline
/// [tui.TextField]:
/// 1. 1-row clickable header bar (`[OFF|BG|FG]`, `[Solo|Blend]`, opacity,
///    backdrop swatch, `[Save Alt+S]`, and E-Stop shortcut hint).
/// 2. 1-row stage annotation and uniform hint ribbon (`[F2]` + compile status).
/// 3. Expanded code body pairing a scroll-synced line-number diagnostic gutter
///    with a multiline `TextField(tabSize: 2, spanBuilder: ...)`.
/// 4. Auto-collapsible diagnostics footer (0 to 5 rows, clickable or `F4`).
final class ShaderEditorView extends tui.StatelessWidget {
  /// Maximum number of diagnostic rows rendered in the footer.
  static const int maxFooterRows = 5;

  /// Controller owning editor text, diagnostics, and preview configuration.
  final ShaderEditorController controller;

  /// Cached GLSL TextMate-to-`TextSpan` highlighter.
  final SyntaxTextHighlighter highlighter;

  /// Active terminal color palette for chrome and syntax styling.
  final tui.TerminalColorTheme theme;

  /// Whether the editor pane currently owns keyboard focus.
  final bool focused;

  /// Available viewport width in terminal columns.
  final int viewportCols;

  /// Available viewport height in terminal rows.
  final int viewportRows;

  /// Optional callback invoked when the user confirms saving and closing.
  final void Function()? onConfirmSaveAndClose;

  /// Optional callback invoked when the user confirms discarding and closing.
  final void Function()? onConfirmDiscardAndClose;

  /// Optional callback invoked when the user cancels close confirmation.
  final void Function()? onCancelCloseConfirmation;

  /// Creates a [ShaderEditorView].
  const ShaderEditorView({
    super.key,
    required this.controller,
    required this.highlighter,
    required this.theme,
    this.focused = true,
    this.viewportCols = 80,
    this.viewportRows = 24,
    this.onConfirmSaveAndClose,
    this.onConfirmDiscardAndClose,
    this.onCancelCloseConfirmation,
  });

  /// Returns the column width reserved for the line-number gutter given
  /// [lineCount].
  static int gutterWidthForLines(int lineCount) {
    final digits = math.max(2, lineCount.toString().length);
    return digits + 3; // "<marker> <digits> "
  }

  /// Whether the line-number gutter fits within [viewportCols] alongside at
  /// least one column of code body.
  static bool showGutterForViewport(int lineCount, int viewportCols) =>
      viewportCols > gutterWidthForLines(lineCount);

  /// Effective gutter column width rendered for [lineCount] and [viewportCols].
  static int effectiveGutterWidth(int lineCount, int viewportCols) =>
      showGutterForViewport(lineCount, viewportCols)
      ? gutterWidthForLines(lineCount)
      : 0;

  /// Whether the 1-row hint ribbon is rendered for [viewportRows].
  static bool showRibbonForViewport(int viewportRows) => viewportRows > 2;

  /// Number of top chrome rows rendered above the code body for [viewportRows].
  static int topChromeRowsForViewport(int viewportRows) =>
      showRibbonForViewport(viewportRows) ? 2 : 1;

  /// Returns the number of rows currently occupied by the diagnostics footer,
  /// optionally clamped so the code body keeps at least 1 row inside
  /// [viewportRows].
  static int footerHeightForDiagnostics(
    int diagnosticCount, {
    int? viewportRows,
  }) {
    final desired = math.min(maxFooterRows, math.max(0, diagnosticCount));
    if (viewportRows == null) return desired;
    final reservedTop = topChromeRowsForViewport(viewportRows);
    final maxFooter = math.max(0, viewportRows - reservedTop - 1);
    return math.min(desired, maxFooter);
  }

  @override
  tui.Widget build(tui.BuildContext context) {
    final palette = _EditorChromePalette.fromTheme(theme);
    final diagnosticSpans = _toTextDiagnosticSpans(
      controller.diagnostics,
      palette,
    );
    final showRibbon = showRibbonForViewport(viewportRows);
    final footerRows = footerHeightForDiagnostics(
      controller.diagnostics.length,
      viewportRows: viewportRows,
    );
    final showGutter = showGutterForViewport(
      controller.textController.value.lines.length,
      viewportCols,
    );

    return tui.Column(<tui.Widget>[
      _EditorHeaderBar(
        controller: controller,
        palette: palette,
        viewportCols: viewportCols,
        onConfirmSaveAndClose: onConfirmSaveAndClose,
        onConfirmDiscardAndClose: onConfirmDiscardAndClose,
        onCancelCloseConfirmation: onCancelCloseConfirmation,
      ),
      if (showRibbon)
        _EditorHintRibbon(controller: controller, palette: palette),
      if (viewportRows > 1)
        tui.Expanded(
          child: tui.Row(<tui.Widget>[
            if (showGutter)
              _EditorGutter(controller: controller, palette: palette),
            tui.Expanded(
              child: tui.TextField(
                controller: controller.textController,
                multiline: true,
                tabSize: 2,
                focused:
                    focused &&
                    !controller.confirmingClose &&
                    !controller.promptingSaveAs,
                // Leave background null (bg == 0) so TerminalSurface applies
                // previewBackgroundColorOverride and previewBackgroundOpacity,
                // allowing background shaders to shine through in BG mode.
                style: tui.Style(foreground: theme.foreground),
                cursorStyle: tui.Style(
                  foreground: theme.cursorTextColor,
                  background: theme.cursorColor,
                ),
                selectionStyle: tui.Style(
                  foreground: palette.activeChipFg,
                  background: palette.activeChipBg,
                ),
                spanBuilder: (text, baseStyle) => highlighter.buildFieldSpan(
                  text,
                  baseStyle,
                  diagnostics: diagnosticSpans,
                ),
              ),
            ),
          ], crossAxisAlignment: tui.CrossAxisAlignment.stretch),
        ),
      if (footerRows > 0)
        _EditorDiagnosticsFooter(
          controller: controller,
          palette: palette,
          rowCount: footerRows,
        ),
    ], crossAxisAlignment: tui.CrossAxisAlignment.stretch);
  }

  static List<TextDiagnosticSpan> _toTextDiagnosticSpans(
    List<ShaderDiagnostic> diagnostics,
    _EditorChromePalette palette,
  ) {
    final spans = <TextDiagnosticSpan>[];
    for (final diag in diagnostics) {
      final line = diag.line;
      if (line == null) continue;
      spans.add(
        TextDiagnosticSpan(
          line: line,
          column: diag.column ?? 1,
          length: diag.length < 1 ? 1 : diag.length,
          underlineColor: palette.colorForSeverity(diag.severity),
          underlineStyle: diag.severity == ShaderDiagnosticSeverity.info
              ? tui.UnderlineStyle.dotted
              : tui.UnderlineStyle.curly,
        ),
      );
    }
    return spans;
  }
}

final class _EditorChromePalette {
  final tui.Color barBg;
  final tui.Color ribbonBg;
  final tui.Color footerBg;
  final tui.Color gutterBg;
  final tui.Color fg;
  final tui.Color mutedFg;
  final tui.Color accentFg;
  final tui.Color activeChipBg;
  final tui.Color activeChipFg;
  final tui.Color errorFg;
  final tui.Color warningFg;
  final tui.Color infoFg;
  final tui.Color okFg;

  const _EditorChromePalette({
    required this.barBg,
    required this.ribbonBg,
    required this.footerBg,
    required this.gutterBg,
    required this.fg,
    required this.mutedFg,
    required this.accentFg,
    required this.activeChipBg,
    required this.activeChipFg,
    required this.errorFg,
    required this.warningFg,
    required this.infoFg,
    required this.okFg,
  });

  factory _EditorChromePalette.fromTheme(tui.TerminalColorTheme theme) {
    final isDark = theme.brightness == tui.TerminalBrightness.dark;
    final barBg = isDark
        ? _shiftChannel(theme.background, 18)
        : _shiftChannel(theme.background, -18);
    final ribbonBg = isDark
        ? _shiftChannel(theme.background, 10)
        : _shiftChannel(theme.background, -10);
    final gutterBg = isDark
        ? _shiftChannel(theme.background, 6)
        : _shiftChannel(theme.background, -6);
    final activeBg = theme.ansi[4];
    final activeFg = tui.TerminalContrast.ensureReadableTextOn(
      theme.background,
      activeBg,
    );
    return _EditorChromePalette(
      barBg: barBg,
      ribbonBg: ribbonBg,
      footerBg: barBg,
      gutterBg: gutterBg,
      fg: theme.foreground,
      mutedFg: tui.TerminalContrast.enforceMinimumContrast(
        theme.ansi[8],
        barBg,
        minRatio: 3.0,
      ),
      accentFg: tui.TerminalContrast.enforceMinimumContrast(
        theme.ansi[6],
        barBg,
        minRatio: 4.5,
      ),
      activeChipBg: activeBg,
      activeChipFg: activeFg,
      errorFg: tui.TerminalContrast.enforceMinimumContrast(
        theme.ansi[9],
        barBg,
        minRatio: 4.5,
      ),
      warningFg: tui.TerminalContrast.enforceMinimumContrast(
        theme.ansi[11],
        barBg,
        minRatio: 4.5,
      ),
      infoFg: tui.TerminalContrast.enforceMinimumContrast(
        theme.ansi[14],
        barBg,
        minRatio: 4.5,
      ),
      okFg: tui.TerminalContrast.enforceMinimumContrast(
        theme.ansi[10],
        barBg,
        minRatio: 4.5,
      ),
    );
  }

  tui.Color colorForSeverity(ShaderDiagnosticSeverity severity) =>
      switch (severity) {
        ShaderDiagnosticSeverity.error => errorFg,
        ShaderDiagnosticSeverity.warning => warningFg,
        ShaderDiagnosticSeverity.info => infoFg,
      };

  static tui.Color _shiftChannel(tui.Color c, int delta) => tui.Color(
    (c.r + delta).clamp(0, 255),
    (c.g + delta).clamp(0, 255),
    (c.b + delta).clamp(0, 255),
  );
}

final RegExp _controlWhitespace = RegExp(r'[\r\n\t]+');

String _singleLine(String raw) => raw.replaceAll(_controlWhitespace, ' ');

int _paintStyledText(
  tui.Buffer buffer,
  int startX,
  int y,
  int maxWidth,
  int col,
  String text, {
  required int fg,
  required int bg,
  required int modifiers,
  required int underlineColor,
}) {
  var x = col;
  for (final ch in text.characters) {
    final w = math.max(1, tui.graphemeWidth(ch));
    if (x + w > maxWidth) break;
    buffer.setAttributes(
      startX + x,
      y,
      char: ch,
      fg: fg,
      bg: bg,
      modifiers: modifiers,
      underlineColor: underlineColor,
    );
    for (var pad = 1; pad < w; pad++) {
      buffer.setAttributes(
        startX + x + pad,
        y,
        char: '',
        fg: fg,
        bg: bg,
        modifiers: modifiers,
        underlineColor: underlineColor,
      );
    }
    x += w;
  }
  return x;
}

int _paintSpanTree(
  tui.Buffer buffer,
  int startX,
  int y,
  int maxWidth,
  int col,
  tui.TextSpan span,
  tui.Style inherited,
) {
  final style = span.style;
  final effective = tui.Style(
    foreground: style?.foreground ?? inherited.foreground,
    background: style?.background ?? inherited.background,
    modifiers: style != null
        ? (inherited.modifiers | style.modifiers)
        : inherited.modifiers,
    underlineColor: style?.underlineColor ?? inherited.underlineColor,
  );
  var x = col;
  if (span.text case final text? when text.isNotEmpty && x < maxWidth) {
    x = _paintStyledText(
      buffer,
      startX,
      y,
      maxWidth,
      x,
      text,
      fg: effective.foreground?.argb ?? 0,
      bg: effective.background?.argb ?? 0,
      modifiers: effective.modifiers,
      underlineColor: effective.underlineColor?.argb ?? 0,
    );
  }
  for (final child in span.children) {
    if (x >= maxWidth) break;
    x = _paintSpanTree(buffer, startX, y, maxWidth, x, child, effective);
  }
  return x;
}

final class _HitRange {
  final int startX;
  final int endX;
  final void Function() onTap;

  const _HitRange(this.startX, this.endX, this.onTap);
}

final class _ClickableStrip extends tui.Widget {
  final tui.TextSpan span;
  final tui.Color background;
  final List<_HitRange> hits;

  const _ClickableStrip({
    required this.span,
    required this.background,
    required this.hits,
  });

  @override
  tui.Element createElement() => _ClickableStripElement(this);

  @override
  int getIntrinsicHeight(int width) => 1;
}

final class _ClickableStripElement extends tui.Element
    implements tui.MouseEventConsumer {
  _ClickableStripElement(_ClickableStrip super.widget);

  @override
  tui.Size performLayout(tui.BoxConstraints constraints) {
    final width = constraints.hasBoundedWidth ? constraints.maxWidth : 80;
    return constraints.constrain(tui.Size(width, 1));
  }

  @override
  void performPaint(tui.Buffer buffer, tui.Offset offset) {
    final strip = widget as _ClickableStrip;
    final bgArgb = strip.background.argb;
    for (var x = 0; x < size.width; x++) {
      buffer.setAttributes(
        offset.dx + x,
        offset.dy,
        char: ' ',
        fg: 0,
        bg: bgArgb,
        modifiers: tui.Modifier.none,
        underlineColor: 0,
      );
    }
    _paintSpanTree(
      buffer,
      offset.dx,
      offset.dy,
      size.width,
      0,
      strip.span,
      tui.Style(background: strip.background),
    );
  }

  @override
  bool handleMouseEvent(ev.MouseEvent event, int localX, int localY) {
    if (localY != 0 ||
        event.type != ev.MouseEventType.press ||
        event.button != ev.MouseButton.left) {
      return false;
    }
    final strip = widget as _ClickableStrip;
    for (final hit in strip.hits) {
      if (localX >= hit.startX && localX < hit.endX) {
        hit.onTap();
        return true;
      }
    }
    return false;
  }
}

final class _StripBuilder {
  final List<tui.TextSpan> spans = <tui.TextSpan>[];
  final List<_HitRange> hits = <_HitRange>[];
  int _col = 0;

  void add(String text, tui.Style style, {void Function()? onTap}) {
    final clean = _singleLine(text);
    final start = _col;
    spans.add(tui.TextSpan(text: clean, style: style));
    _col += _displayWidth(clean);
    if (onTap != null) {
      hits.add(_HitRange(start, _col, onTap));
    }
  }

  static int _displayWidth(String text) {
    var w = 0;
    for (final ch in text.characters) {
      w += math.max(1, tui.graphemeWidth(ch));
    }
    return w;
  }

  static String tailFit(String text, int maxCols) {
    final clean = _singleLine(text);
    if (maxCols <= 0) return '';
    if (_displayWidth(clean) <= maxCols) return clean;
    if (maxCols == 1) return '…';
    final chars = clean.characters.toList(growable: false);
    var width = 1; // leading '…'
    var start = chars.length;
    for (var i = chars.length - 1; i >= 0; i--) {
      final w = math.max(1, tui.graphemeWidth(chars[i]));
      if (width + w > maxCols) break;
      width += w;
      start = i;
    }
    return '…${chars.sublist(start).join()}';
  }
}

final class _EditorHeaderBar extends tui.StatelessWidget {
  final ShaderEditorController controller;
  final _EditorChromePalette palette;
  final int viewportCols;
  final void Function()? onConfirmSaveAndClose;
  final void Function()? onConfirmDiscardAndClose;
  final void Function()? onCancelCloseConfirmation;

  const _EditorHeaderBar({
    required this.controller,
    required this.palette,
    required this.viewportCols,
    this.onConfirmSaveAndClose,
    this.onConfirmDiscardAndClose,
    this.onCancelCloseConfirmation,
  });

  @override
  tui.Widget build(tui.BuildContext context) {
    final b = _StripBuilder();
    if (controller.confirmingClose) {
      _buildCloseConfirmRow(b);
    } else if (controller.promptingSaveAs) {
      _buildSaveAsRow(b);
    } else {
      _buildNormalHeaderRow(b);
    }
    return _ClickableStrip(
      span: tui.TextSpan(children: b.spans),
      background: palette.barBg,
      hits: b.hits,
    );
  }

  void _buildCloseConfirmRow(_StripBuilder b) {
    final warnStyle = tui.Style(
      foreground: palette.warningFg,
      background: palette.barBg,
      modifiers: tui.Modifier.bold,
    );
    final actionStyle = tui.Style(
      foreground: palette.activeChipFg,
      background: palette.activeChipBg,
      modifiers: tui.Modifier.bold,
    );
    final normalStyle = tui.Style(
      foreground: palette.fg,
      background: palette.barBg,
    );
    b.add(' Unsaved changes in ${controller.shaderName}: ', warnStyle);
    b.add('[Y: Save & Close]', actionStyle, onTap: onConfirmSaveAndClose);
    b.add(' ', normalStyle);
    b.add(
      '[N: Discard]',
      tui.Style(
        foreground: palette.errorFg,
        background: palette.barBg,
        modifiers: tui.Modifier.bold,
      ),
      onTap: () {
        if (onConfirmDiscardAndClose != null) {
          onConfirmDiscardAndClose!();
        } else {
          controller.cancelCloseConfirmation();
        }
      },
    );
    b.add(' ', normalStyle);
    b.add(
      '[Esc: Cancel]',
      normalStyle,
      onTap: onCancelCloseConfirmation ?? controller.cancelCloseConfirmation,
    );
  }

  void _buildSaveAsRow(_StripBuilder b) {
    final labelStyle = tui.Style(
      foreground: palette.accentFg,
      background: palette.barBg,
      modifiers: tui.Modifier.bold,
    );
    final inputStyle = tui.Style(
      foreground: palette.activeChipFg,
      background: palette.activeChipBg,
      modifiers: tui.Modifier.bold,
    );
    final normalStyle = tui.Style(
      foreground: palette.fg,
      background: palette.barBg,
    );
    final err = controller.saveAsError;
    final compactButtons = err != null && viewportCols < 90;
    final enterLabel = compactButtons ? '[Enter]' : '[Enter: Save]';
    final escLabel = compactButtons ? '[Esc]' : '[Esc: Cancel]';
    final prefix = ' Save As: ';
    final fixedChromeWidth =
        prefix.length + 3 + 1 + enterLabel.length + 1 + escLabel.length;
    final reservedErrorCols = err == null
        ? 0
        : math.min(
            _StripBuilder._displayWidth(' $err'),
            math.max(0, viewportCols - 32),
          );
    final maxDraftCols = math.max(
      4,
      viewportCols - fixedChromeWidth - reservedErrorCols,
    );
    final visibleDraft = _StripBuilder.tailFit(
      controller.saveAsDraftName,
      maxDraftCols,
    );
    b.add(prefix, labelStyle);
    b.add(' $visibleDraft█ ', inputStyle);
    b.add(' ', normalStyle);
    b.add(
      enterLabel,
      tui.Style(
        foreground: palette.okFg,
        background: palette.barBg,
        modifiers: tui.Modifier.bold,
      ),
      onTap: () => unawaited(controller.confirmSaveAs()),
    );
    b.add(' ', normalStyle);
    b.add(escLabel, normalStyle, onTap: controller.cancelSaveAs);
    if (err != null) {
      b.add(
        compactButtons ? ' $err' : '  $err',
        tui.Style(
          foreground: palette.errorFg,
          background: palette.barBg,
          modifiers: tui.Modifier.bold,
        ),
      );
    }
  }

  void _buildNormalHeaderRow(_StripBuilder b) {
    final baseStyle = tui.Style(
      foreground: palette.fg,
      background: palette.barBg,
    );
    final titleStyle = tui.Style(
      foreground: controller.isDirty ? palette.warningFg : palette.fg,
      background: palette.barBg,
      modifiers: tui.Modifier.bold,
    );
    final dirtyMarker = controller.isDirty ? '*' : '';
    b.add(' ${controller.shaderName}$dirtyMarker ', titleStyle);

    _addPreviewToggle(b, baseStyle);
    b.add(' ', baseStyle);
    _addCompositionToggle(b);
    b.add(' ', baseStyle);
    _addOpacityAndBackdropControls(b, baseStyle);
    b.add(' ', baseStyle);
    b.add(
      '[Save Alt+S]',
      tui.Style(
        foreground: controller.isDirty ? palette.okFg : palette.mutedFg,
        background: palette.barBg,
        modifiers: controller.isDirty ? tui.Modifier.bold : tui.Modifier.none,
      ),
      onTap: () => unawaited(controller.save()),
    );
    b.add(' ', baseStyle);
    final isUntitled = controller.sourcePath == null;
    b.add(
      '[Save As]',
      tui.Style(
        foreground: isUntitled ? palette.accentFg : palette.mutedFg,
        background: palette.barBg,
        modifiers: isUntitled ? tui.Modifier.bold : tui.Modifier.none,
      ),
      onTap: controller.beginSaveAs,
    );
    b.add(
      ' E-Stop:Ctrl+Shift+F6',
      tui.Style(foreground: palette.mutedFg, background: palette.barBg),
    );
  }

  void _addPreviewToggle(_StripBuilder b, tui.Style baseStyle) {
    b.add('[', baseStyle);
    const modes = ShaderEditorPreviewMode.values;
    for (var i = 0; i < modes.length; i++) {
      final mode = modes[i];
      if (i > 0) b.add('|', baseStyle);
      final active = controller.previewMode == mode;
      b.add(
        mode.label,
        active
            ? tui.Style(
                foreground: palette.activeChipFg,
                background: palette.activeChipBg,
                modifiers: tui.Modifier.bold,
              )
            : tui.Style(foreground: palette.mutedFg, background: palette.barBg),
        onTap: () => controller.setPreviewMode(mode),
      );
    }
    b.add(']', baseStyle);
  }

  void _addCompositionToggle(_StripBuilder b) {
    final isBlend =
        controller.chainComposition ==
        ShaderEditorChainComposition.blendWithWorkspace;
    b.add(
      '[${controller.chainComposition.label}]',
      tui.Style(
        foreground: isBlend ? palette.accentFg : palette.fg,
        background: palette.barBg,
        modifiers: tui.Modifier.bold,
      ),
      onTap: controller.toggleChainComposition,
    );
  }

  void _addOpacityAndBackdropControls(_StripBuilder b, tui.Style baseStyle) {
    final pct = (controller.previewBackgroundOpacity * 100).round();
    b.add('Op:$pct%', baseStyle);
    b.add(
      '[-]',
      tui.Style(foreground: palette.accentFg, background: palette.barBg),
      onTap: () => controller.adjustPreviewOpacity(-0.05),
    );
    b.add(
      '[+]',
      tui.Style(foreground: palette.accentFg, background: palette.barBg),
      onTap: () => controller.adjustPreviewOpacity(0.05),
    );
    b.add(' ', baseStyle);
    b.add(
      '[BG:${controller.previewBackgroundPreset.label}]',
      tui.Style(foreground: palette.accentFg, background: palette.barBg),
      onTap: controller.cycleBackgroundPreset,
    );
  }
}

final class _EditorHintRibbon extends tui.StatelessWidget {
  final ShaderEditorController controller;
  final _EditorChromePalette palette;

  const _EditorHintRibbon({required this.controller, required this.palette});

  @override
  tui.Widget build(tui.BuildContext context) {
    final b = _StripBuilder();
    final bg = palette.ribbonBg;
    if (controller.promptingSaveAs && controller.saveAsError != null) {
      b.add(
        ' ${controller.saveAsError} ',
        tui.Style(
          foreground: palette.errorFg,
          background: bg,
          modifiers: tui.Modifier.bold,
        ),
      );
      return _ClickableStrip(
        span: tui.TextSpan(children: b.spans),
        background: bg,
        hits: b.hits,
      );
    }
    final stageText = controller.hasExplicitStageDirective
        ? ' [F2] @fterm-stage:${controller.detectedStageHint.shortLabel}'
        : ' [F2] Insert @fterm-stage';
    b.add(
      stageText,
      tui.Style(
        foreground: palette.accentFg,
        background: bg,
        modifiers: tui.Modifier.bold,
      ),
      onTap: controller.cycleStageAnnotation,
    );

    final uniforms = controller.activeUniformLabels;
    final uniformSummary = uniforms.isEmpty
        ? 'iTime iChannel0 iPrevFrame uParams0 iCursor'
        : uniforms.join(' ');
    b.add(
      ' | Uniforms: $uniformSummary | ',
      tui.Style(foreground: palette.mutedFg, background: bg),
    );

    _appendCompileStatus(b, bg);
    return _ClickableStrip(
      span: tui.TextSpan(children: b.spans),
      background: bg,
      hits: b.hits,
    );
  }

  void _appendCompileStatus(_StripBuilder b, tui.Color bg) {
    if (controller.isCompiling) {
      b.add(
        'Compiling...',
        tui.Style(foreground: palette.warningFg, background: bg),
      );
      return;
    }
    final errors = controller.errorCount;
    final warnings = controller.warningCount;
    if (errors > 0 || warnings > 0) {
      final summary = _formatDiagnosticCounts(errors, warnings);
      b.add(
        '$summary [F4]',
        tui.Style(
          foreground: errors > 0 ? palette.errorFg : palette.warningFg,
          background: bg,
          modifiers: tui.Modifier.bold,
        ),
        onTap: controller.jumpToNextDiagnostic,
      );
      return;
    }
    final ms = controller.lastCompileDurationMs;
    final label = ms == null ? 'OK' : 'OK ${ms}ms';
    b.add(
      label,
      tui.Style(
        foreground: palette.okFg,
        background: bg,
        modifiers: tui.Modifier.bold,
      ),
    );
  }

  static String _formatDiagnosticCounts(int errors, int warnings) {
    final parts = <String>[
      if (errors > 0) _pluralize(errors, 'error'),
      if (warnings > 0) _pluralize(warnings, 'warning'),
    ];
    return parts.join(', ');
  }

  static String _pluralize(int count, String noun) =>
      count == 1 ? '1 $noun' : '$count ${noun}s';
}

final class _EditorGutter extends tui.Widget {
  final ShaderEditorController controller;
  final _EditorChromePalette palette;

  const _EditorGutter({required this.controller, required this.palette});

  @override
  tui.Element createElement() => _EditorGutterElement(this);

  @override
  int getIntrinsicWidth(int height) => ShaderEditorView.gutterWidthForLines(
    controller.textController.value.lines.length,
  );
}

final class _EditorGutterElement extends tui.Element {
  _EditorGutterElement(_EditorGutter super.widget);

  @override
  tui.Size performLayout(tui.BoxConstraints constraints) {
    final gutter = widget as _EditorGutter;
    final lineCount = gutter.controller.textController.value.lines.length;
    final width = ShaderEditorView.gutterWidthForLines(lineCount);
    final height = constraints.hasBoundedHeight
        ? constraints.maxHeight
        : math.max(1, lineCount);
    return constraints.constrain(tui.Size(width, height));
  }

  @override
  void performPaint(tui.Buffer buffer, tui.Offset offset) {
    final gutter = widget as _EditorGutter;
    final ctrl = gutter.controller;
    final palette = gutter.palette;
    final lines = ctrl.textController.value.lines;
    final scroll = ctrl.textController.scrollOffset;
    final cursorLine = ctrl.textController.value.selection.cursorLine;
    final severityByLine = _severityByLine(ctrl.diagnostics);
    final digitsWidth = math.max(2, size.width - 3);

    final bgPreviewActive =
        ctrl.previewMode == ShaderEditorPreviewMode.background;
    for (var y = 0; y < size.height; y++) {
      final lineIdx = scroll + y;
      final rowY = offset.dy + y;
      _paintGutterRow(
        buffer,
        offset.dx,
        rowY,
        lineIdx,
        lines.length,
        cursorLine,
        digitsWidth,
        severityByLine[lineIdx + 1],
        palette,
        bgArgb: bgPreviewActive ? 0 : palette.gutterBg.argb,
      );
    }
  }

  void _paintGutterRow(
    tui.Buffer buffer,
    int startX,
    int rowY,
    int lineIdx,
    int lineCount,
    int cursorLine,
    int digitsWidth,
    ShaderDiagnosticSeverity? severity,
    _EditorChromePalette palette, {
    required int bgArgb,
  }) {
    for (var x = 0; x < size.width; x++) {
      buffer.setAttributes(
        startX + x,
        rowY,
        char: ' ',
        fg: palette.mutedFg.argb,
        bg: bgArgb,
        modifiers: tui.Modifier.none,
        underlineColor: 0,
      );
    }
    if (lineIdx >= lineCount) return;

    if (severity != null) {
      final marker = switch (severity) {
        ShaderDiagnosticSeverity.error => '●',
        ShaderDiagnosticSeverity.warning => '▲',
        ShaderDiagnosticSeverity.info => 'i',
      };
      buffer.setAttributes(
        startX,
        rowY,
        char: marker,
        fg: palette.colorForSeverity(severity).argb,
        bg: bgArgb,
        modifiers: tui.Modifier.bold,
        underlineColor: 0,
      );
    }

    final numText = '${lineIdx + 1}'.padLeft(digitsWidth);
    final isCurrent = lineIdx == cursorLine;
    final fg = isCurrent ? palette.fg : palette.mutedFg;
    final mods = isCurrent ? tui.Modifier.bold : tui.Modifier.none;
    for (var i = 0; i < numText.length && i + 2 < size.width; i++) {
      buffer.setAttributes(
        startX + 2 + i,
        rowY,
        char: numText[i],
        fg: fg.argb,
        bg: bgArgb,
        modifiers: mods,
        underlineColor: 0,
      );
    }
  }

  static Map<int, ShaderDiagnosticSeverity> _severityByLine(
    List<ShaderDiagnostic> diagnostics,
  ) {
    final map = <int, ShaderDiagnosticSeverity>{};
    for (final diag in diagnostics) {
      final line = diag.line;
      if (line == null) continue;
      final existing = map[line];
      if (existing == null || diag.severity.index < existing.index) {
        map[line] = diag.severity;
      }
    }
    return map;
  }
}

final class _EditorDiagnosticsFooter extends tui.Widget {
  final ShaderEditorController controller;
  final _EditorChromePalette palette;
  final int rowCount;

  const _EditorDiagnosticsFooter({
    required this.controller,
    required this.palette,
    required this.rowCount,
  });

  @override
  tui.Element createElement() => _EditorDiagnosticsFooterElement(this);

  @override
  int getIntrinsicHeight(int width) => rowCount;
}

final class _EditorDiagnosticsFooterElement extends tui.Element
    implements tui.MouseEventConsumer {
  _EditorDiagnosticsFooterElement(_EditorDiagnosticsFooter super.widget);

  @override
  tui.Size performLayout(tui.BoxConstraints constraints) {
    final footer = widget as _EditorDiagnosticsFooter;
    final width = constraints.hasBoundedWidth ? constraints.maxWidth : 80;
    return constraints.constrain(tui.Size(width, footer.rowCount));
  }

  int _windowStart(_EditorDiagnosticsFooter footer) {
    final total = footer.controller.diagnostics.length;
    if (total <= footer.rowCount) return 0;
    final sel = footer.controller.selectedDiagnosticIndex;
    if (sel < 0) return 0;
    return (sel - footer.rowCount + 1).clamp(0, total - footer.rowCount);
  }

  @override
  void performPaint(tui.Buffer buffer, tui.Offset offset) {
    final footer = widget as _EditorDiagnosticsFooter;
    final diags = footer.controller.diagnostics;
    final palette = footer.palette;
    final start = _windowStart(footer);

    for (var row = 0; row < size.height; row++) {
      final idx = start + row;
      final rowY = offset.dy + row;
      final isSelected = idx == footer.controller.selectedDiagnosticIndex;
      final rowBg = isSelected ? palette.activeChipBg : palette.footerBg;
      for (var x = 0; x < size.width; x++) {
        buffer.setAttributes(
          offset.dx + x,
          rowY,
          char: ' ',
          fg: palette.fg.argb,
          bg: rowBg.argb,
          modifiers: tui.Modifier.none,
          underlineColor: 0,
        );
      }
      if (idx >= diags.length) continue;
      _paintDiagnosticRow(
        buffer,
        tui.Offset(offset.dx, rowY),
        diags[idx],
        palette,
        isSelected: isSelected,
      );
    }
  }

  void _paintDiagnosticRow(
    tui.Buffer buffer,
    tui.Offset rowOffset,
    ShaderDiagnostic diag,
    _EditorChromePalette palette, {
    required bool isSelected,
  }) {
    final bg = isSelected ? palette.activeChipBg : palette.footerBg;
    final textFg = isSelected ? palette.activeChipFg : palette.fg;
    final iconFg = isSelected
        ? palette.activeChipFg
        : palette.colorForSeverity(diag.severity);
    final icon = switch (diag.severity) {
      ShaderDiagnosticSeverity.error => '●',
      ShaderDiagnosticSeverity.warning => '▲',
      ShaderDiagnosticSeverity.info => 'i',
    };
    final loc = diag.line == null ? '?:?' : '${diag.line}:${diag.column ?? 1}';
    final message = _singleLine(diag.message);
    final hintSuffix = diag.hint == null
        ? ''
        : '  Hint: ${_singleLine(diag.hint!)}';
    final bgArgb = bg.argb;
    final locFg = isSelected ? palette.activeChipFg : palette.accentFg;
    var x = _paintStyledText(
      buffer,
      rowOffset.dx,
      rowOffset.dy,
      size.width,
      0,
      ' $icon ',
      fg: iconFg.argb,
      bg: bgArgb,
      modifiers: tui.Modifier.bold,
      underlineColor: 0,
    );
    x = _paintStyledText(
      buffer,
      rowOffset.dx,
      rowOffset.dy,
      size.width,
      x,
      '$loc ',
      fg: locFg.argb,
      bg: bgArgb,
      modifiers: tui.Modifier.bold,
      underlineColor: 0,
    );
    _paintStyledText(
      buffer,
      rowOffset.dx,
      rowOffset.dy,
      size.width,
      x,
      '$message$hintSuffix',
      fg: textFg.argb,
      bg: bgArgb,
      modifiers: tui.Modifier.none,
      underlineColor: 0,
    );
  }

  @override
  bool handleMouseEvent(ev.MouseEvent event, int localX, int localY) {
    if (event.type != ev.MouseEventType.press ||
        event.button != ev.MouseButton.left) {
      return false;
    }
    final footer = widget as _EditorDiagnosticsFooter;
    final idx = _windowStart(footer) + localY;
    return footer.controller.jumpToDiagnostic(idx);
  }
}
