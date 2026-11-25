import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show ChangeNotifier, Listenable, ValueListenable, VoidCallback;
import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:termui/syntax.dart';
import 'package:termui/terminal/event.dart' as ev;
import 'package:termui/termui.dart' as tui;
import 'package:termui_flutter/termui_flutter.dart';

import 'shader_editor_controller.dart';
import 'shader_editor_view.dart';

final class _EditorBufferNotifier extends ChangeNotifier
    implements TerminalBufferChangeSignal {
  int _cellContentRevision = 0;

  @override
  int get cellContentRevision => _cellContentRevision;

  void emitCellChange() {
    _cellContentRevision += 1;
    notifyListeners();
  }
}

final class _EditorBufferValueListenable
    implements ValueListenable<tui.Buffer>, TerminalBufferChangeSignal {
  final _EditorBufferNotifier _notifier;
  final tui.Buffer Function() _readBuffer;

  _EditorBufferValueListenable(this._notifier, this._readBuffer);

  @override
  int get cellContentRevision => _notifier.cellContentRevision;

  @override
  tui.Buffer get value => _readBuffer();

  @override
  void addListener(VoidCallback listener) => _notifier.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _notifier.removeListener(listener);
}

/// Hosts [ShaderEditorView] inside an in-process `termui` root [tui.Element]
/// and [tui.Buffer] with no PTY subprocess.
///
/// Exposes the buffer, cursor, viewport, input, and preview shader contracts
/// required by `TerminalSurface` and `fterm` workspace tabs.
final class ShaderEditorPane {
  /// Stable pane identifier within the workspace split/tab tree.
  final String paneId;

  /// Reactive shader editor state controller.
  final ShaderEditorController controller;

  /// Per-pane GPU frame watchdog protecting against slow or hanging drafts.
  final GpuFrameWatchdog gpuFrameWatchdog;

  final _EditorBufferNotifier _bufferNotifier = _EditorBufferNotifier();
  late final ValueListenable<tui.Buffer> _bufferListenable;
  late final SyntaxTextHighlighter _highlighter;
  late final tui.BuildOwner _buildOwner;
  late final VoidCallback? _onCloseConfirmed;

  late tui.TerminalColorTheme _theme;
  tui.Element? _rootElement;
  tui.Buffer _buffer;
  int _cols;
  int _rows;
  bool _focused = true;
  bool _isRendering = false;
  bool _disposed = false;

  /// Creates an in-process [ShaderEditorPane] backed by [controller].
  ShaderEditorPane({
    required this.paneId,
    required this.controller,
    tui.TerminalColorTheme theme = tui.TerminalColorTheme.termuiDark,
    int initialCols = 80,
    int initialRows = 24,
    GpuFrameWatchdog? gpuFrameWatchdog,
    VoidCallback? onCloseConfirmed,
  }) : _cols = math.max(1, initialCols),
       _rows = math.max(1, initialRows),
       gpuFrameWatchdog = gpuFrameWatchdog ?? GpuFrameWatchdog(),
       _buffer = tui.Buffer.blank(
         math.max(1, initialCols),
         math.max(1, initialRows),
       ) {
    _theme = theme;
    _onCloseConfirmed = onCloseConfirmed;
    _highlighter = SyntaxTextHighlighter(
      language: kGlslLanguageId,
      theme: _theme,
    );
    _buildOwner = tui.BuildOwner(onNeedVisualUpdate: _renderIfReady);
    _bufferListenable = _EditorBufferValueListenable(
      _bufferNotifier,
      readDisplayBuffer,
    );
    controller.addListener(_handleControllerChanged);
    _mountAndRender(notify: false);
  }

  /// Stable pass identifier used when registering this pane's preview shader.
  String get previewPassId => 'editor:$paneId';

  /// Display filename or logical shader name.
  String get shaderName => controller.shaderName;

  /// Optional backing path or storage key.
  String? get sourcePath => controller.sourcePath;

  /// Current GLSL source text.
  String get source => controller.source;

  /// Whether the editor holds unsaved changes.
  bool get isDirty => controller.isDirty;

  /// Active preview background opacity (`0.75` in BG mode, `1.0` in OFF/FG).
  double get previewBackgroundOpacity => controller.previewBackgroundOpacity;

  /// Optional preview background color override for contrast inspection.
  tui.Color? get previewBackgroundColorOverride =>
      controller.previewBackgroundColorOverride;

  /// Active draft [ShaderPassSpec], or `null` when preview is off.
  ShaderPassSpec? get activePreviewPassSpec =>
      controller.buildPreviewPassSpec(previewPassId);

  /// Listenable notified whenever the rendered `termui` [tui.Buffer] updates.
  ValueListenable<tui.Buffer> get bufferListenable => _bufferListenable;

  /// Listenable notified whenever live preview settings or compiled draft
  /// shaders change.
  Listenable get previewConfigListenable => controller.previewListenable;

  /// Current rendered terminal buffer snapshot for `TerminalSurface`.
  tui.Buffer readDisplayBuffer() => _buffer;

  /// Current zero-based `(col, row)` cursor coordinates inside the viewport.
  ({int col, int row}) readCursorPosition() {
    final lines = controller.textController.value.lines;
    final sel = controller.textController.value.selection;
    final lineIdx = sel.cursorLine.clamp(0, lines.length - 1);
    final gutterW = ShaderEditorView.gutterWidthForLines(lines.length);
    final relRow = lineIdx - controller.textController.scrollOffset;
    final displayCol =
        _displayColumnAt(lines[lineIdx], sel.cursorColumn) -
        controller.textController.horizontalScrollOffset;
    return (
      col: (gutterW + displayCol).clamp(0, math.max(0, _cols - 1)),
      row: (2 + relRow).clamp(0, math.max(0, _rows - 1)),
    );
  }

  /// Whether the editor cursor is currently visible within the code viewport.
  bool readCursorVisible() {
    if (!_focused || controller.confirmingClose || controller.promptingSaveAs) {
      return false;
    }
    final lines = controller.textController.value.lines;
    final sel = controller.textController.value.selection;
    final lineIdx = sel.cursorLine.clamp(0, lines.length - 1);
    final relRow = lineIdx - controller.textController.scrollOffset;
    final footerRows = ShaderEditorView.footerHeightForDiagnostics(
      controller.diagnostics.length,
    );
    final bodyRows = math.max(0, _rows - 2 - footerRows);
    if (relRow < 0 || relRow >= bodyRows) return false;

    final gutterW = ShaderEditorView.gutterWidthForLines(lines.length);
    final bodyCols = math.max(0, _cols - gutterW);
    final displayCol =
        _displayColumnAt(lines[lineIdx], sel.cursorColumn) -
        controller.textController.horizontalScrollOffset;
    return displayCol >= 0 && displayCol < bodyCols;
  }

  /// Resolves the effective [TerminalShaderConfig] for this editor pane.
  ///
  /// - When E-Stop is active (`!workspaceConfig.enabled`), disables all passes.
  /// - When [ShaderEditorPreviewMode.off] is selected, disables preview passes.
  /// - In [ShaderEditorChainComposition.solo] mode (default), overrides
  ///   workspace chains so only this draft shader renders.
  /// - In [ShaderEditorChainComposition.blendWithWorkspace] mode, appends this
  ///   draft pass onto the active workspace BG/FG chains.
  TerminalShaderConfig resolvePreviewShaderConfig(
    TerminalShaderConfig workspaceConfig,
  ) {
    if (!workspaceConfig.enabled) {
      return workspaceConfig.copyWith(
        enabled: false,
        backgroundPasses: const <ShaderPassSpec>[],
        foregroundPasses: const <ShaderPassSpec>[],
      );
    }

    final draftPass = activePreviewPassSpec;
    if (draftPass == null) {
      return workspaceConfig.copyWith(
        enabled: false,
        backgroundPasses: const <ShaderPassSpec>[],
        foregroundPasses: const <ShaderPassSpec>[],
        backgroundOpacity: 1.0,
      );
    }

    final isBg = draftPass.stage == TerminalShaderStage.background;
    if (controller.chainComposition == ShaderEditorChainComposition.solo) {
      return workspaceConfig.copyWith(
        enabled: true,
        backgroundPasses: isBg ? <ShaderPassSpec>[draftPass] : const [],
        foregroundPasses: isBg ? const [] : <ShaderPassSpec>[draftPass],
        backgroundOpacity: controller.previewBackgroundOpacity,
      );
    }

    return workspaceConfig.copyWith(
      enabled: true,
      backgroundPasses: _mergeDraftPass(
        workspaceConfig.backgroundPasses,
        draftPass,
        append: isBg,
      ),
      foregroundPasses: _mergeDraftPass(
        workspaceConfig.foregroundPasses,
        draftPass,
        append: !isBg,
      ),
      backgroundOpacity: controller.previewBackgroundOpacity,
    );
  }

  static List<ShaderPassSpec> _mergeDraftPass(
    List<ShaderPassSpec> existing,
    ShaderPassSpec draftPass, {
    required bool append,
  }) => <ShaderPassSpec>[
    for (final pass in existing)
      if (pass.id != draftPass.id) pass,
    if (append) draftPass,
  ];

  /// Updates the viewport grid dimensions and re-renders the `termui` buffer.
  void updateViewportSize(
    int cols,
    int rows,
    double cellWidth,
    double cellHeight,
  ) {
    if (_disposed || cols <= 0 || rows <= 0) return;
    if (cols == _cols && rows == _rows) return;
    _cols = cols;
    _rows = rows;
    _render(notify: true);
  }

  /// Updates the active terminal color theme and refreshes syntax coloring.
  void setTheme(tui.TerminalColorTheme nextTheme) {
    if (_disposed || _theme == nextTheme) return;
    _theme = nextTheme;
    _highlighter.setTheme(nextTheme);
    _render(notify: true);
  }

  /// Updates whether this editor pane currently holds keyboard focus.
  void setFocused(bool focused) {
    if (_disposed || _focused == focused) return;
    _focused = focused;
    _render(notify: true);
  }

  /// Routes a high-level `termui` [event] to the editor chrome or `TextField`.
  bool handleInputEvent(ev.InputEvent event) {
    if (_disposed) return false;
    final handled = switch (event) {
      ev.FocusInEvent() => _onFocusEvent(true),
      ev.FocusOutEvent() => _onFocusEvent(false),
      ev.PasteEvent() => _handlePaste(event.text),
      ev.MouseEvent() => _handleMouse(event),
      ev.KeyEvent() => _handleKey(event),
      ev.CursorPositionReportEvent() ||
      ev.KittyGraphicsEvent() ||
      ev.KittyKeyboardEvent() ||
      ev.AudioApcReplyEvent() ||
      ev.ShaderCapabilitiesEvent() => false,
    };
    if (handled) {
      _render(notify: true);
    }
    return handled;
  }

  /// Inserts committed IME or printable UTF-8 text into the active editor.
  void handleCommittedText(String text) {
    if (_disposed || text.isEmpty) return;
    if (controller.confirmingClose) {
      _handleConfirmCloseChar(text);
      _render(notify: true);
      return;
    }
    if (controller.promptingSaveAs) {
      controller.appendSaveAsText(text);
      _render(notify: true);
      return;
    }
    if (text.characters.length == 1 && text != '\n' && text != '\r') {
      _dispatchKeyToTextField(ev.KeyEvent(text, ev.KeyType.character));
    } else {
      controller.textController.insertText(text, multiline: true);
    }
    _render(notify: true);
  }

  bool _onFocusEvent(bool focused) {
    _focused = focused;
    return true;
  }

  bool _handlePaste(String text) {
    if (controller.confirmingClose) return true;
    if (controller.promptingSaveAs) {
      controller.appendSaveAsText(text);
      return true;
    }
    controller.textController.insertText(text, multiline: true);
    return true;
  }

  bool _handleMouse(ev.MouseEvent event) {
    final root = _rootElement;
    if (root == null) return false;
    return _routeMouseEvent(root, event, tui.Offset.zero);
  }

  bool _handleKey(ev.KeyEvent event) {
    if (event.eventType == ev.KeyEventType.release) return false;
    if (controller.confirmingClose) {
      return _handleConfirmCloseKey(event);
    }
    if (controller.promptingSaveAs) {
      return _handleSaveAsKey(event);
    }
    if (_handleEditorShortcut(event)) return true;
    return _dispatchKeyToTextField(event);
  }

  bool _handleSaveAsKey(ev.KeyEvent event) {
    if (event.type == ev.KeyType.escape) {
      controller.cancelSaveAs();
      return true;
    }
    if (event.type == ev.KeyType.enter) {
      unawaited(controller.confirmSaveAs());
      return true;
    }
    if (event.type == ev.KeyType.backspace) {
      controller.backspaceSaveAsChar();
      return true;
    }
    if (event.type == ev.KeyType.character &&
        event.key.toLowerCase() == 'u' &&
        event.modifiers.length == 1 &&
        event.modifiers.contains(ev.Modifier.control)) {
      controller.clearSaveAsDraft();
      return true;
    }
    final hasCmdMod =
        event.modifiers.contains(ev.Modifier.control) ||
        event.modifiers.contains(ev.Modifier.alt) ||
        event.modifiers.contains(ev.Modifier.meta);
    if (event.type == ev.KeyType.character && !hasCmdMod) {
      controller.appendSaveAsText(event.key);
    }
    return true;
  }

  bool _handleEditorShortcut(ev.KeyEvent event) {
    if (event.type == ev.KeyType.f2 && event.modifiers.isEmpty) {
      controller.cycleStageAnnotation();
      return true;
    }
    if (event.type == ev.KeyType.f4 && event.modifiers.isEmpty) {
      controller.jumpToNextDiagnostic();
      return true;
    }
    if (event.type != ev.KeyType.character || event.key.toLowerCase() != 's') {
      return false;
    }
    final hasAlt = event.modifiers.contains(ev.Modifier.alt);
    final hasCtrl = event.modifiers.contains(ev.Modifier.control);
    if (hasAlt == hasCtrl) return false;
    if (event.modifiers.length == 1) {
      unawaited(controller.save());
      return true;
    }
    if (event.modifiers.length == 2 &&
        event.modifiers.contains(ev.Modifier.shift)) {
      controller.beginSaveAs();
      return true;
    }
    return false;
  }

  bool _handleConfirmCloseKey(ev.KeyEvent event) {
    if (event.type == ev.KeyType.escape) {
      controller.cancelCloseConfirmation();
      return true;
    }
    if (event.type == ev.KeyType.character) {
      _handleConfirmCloseChar(event.key);
    }
    return true;
  }

  void _handleConfirmCloseChar(String raw) {
    final lower = raw.toLowerCase();
    if (lower == 'y') {
      unawaited(_saveAndConfirmClose());
    } else if (lower == 'n') {
      controller.cancelCloseConfirmation();
      _onCloseConfirmed?.call();
    }
  }

  Future<void> _saveAndConfirmClose() async {
    final saved = await controller.save();
    if (saved && !_disposed) {
      _onCloseConfirmed?.call();
    }
  }

  bool _dispatchKeyToTextField(ev.KeyEvent event) {
    final root = _rootElement;
    if (root == null) return false;
    final field = _findTextField(root);
    if (field == null) return false;
    return field.handleKeyEvent(event);
  }

  static tui.TextField? _findTextField(tui.Element element) {
    if (element.widget case final tui.TextField field) return field;
    tui.TextField? found;
    element.visitChildren((child) {
      found ??= _findTextField(child);
    });
    return found;
  }

  static bool _routeMouseEvent(
    tui.Element element,
    ev.MouseEvent event,
    tui.Offset absoluteOffset,
  ) {
    final sx = event.x - 1;
    final sy = event.y - 1;
    final ox = absoluteOffset.dx;
    final oy = absoluteOffset.dy;
    if (sx < ox ||
        sx >= ox + element.size.width ||
        sy < oy ||
        sy >= oy + element.size.height) {
      return false;
    }

    final children = <tui.Element>[];
    element.visitChildren(children.add);
    for (var i = children.length - 1; i >= 0; i--) {
      final child = children[i];
      if (_routeMouseEvent(
        child,
        event,
        absoluteOffset + child.relativeOffset,
      )) {
        return true;
      }
    }

    final localX = sx - ox;
    final localY = sy - oy;
    if (element case final tui.MouseEventConsumer consumer) {
      return consumer.handleMouseEvent(event, localX, localY);
    }
    return false;
  }

  ShaderEditorView _buildRootWidget() => ShaderEditorView(
    controller: controller,
    highlighter: _highlighter,
    theme: _theme,
    focused: _focused,
    onConfirmSaveAndClose: _onCloseConfirmed,
    onConfirmDiscardAndClose: _onCloseConfirmed,
  );

  void _mountAndRender({required bool notify}) {
    final root = _buildRootWidget().createElement();
    root.owner = _buildOwner;
    root.mount(null);
    _rootElement = root;
    _render(notify: notify);
  }

  void _handleControllerChanged() {
    if (_disposed) return;
    _render(notify: true);
  }

  void _renderIfReady() {
    if (_disposed || _rootElement == null) return;
    _render(notify: true);
  }

  void _render({required bool notify}) {
    if (_disposed || _isRendering) return;
    final root = _rootElement;
    if (root == null) return;
    _isRendering = true;
    try {
      root.update(_buildRootWidget());
      _buildOwner.buildScope();
      root.layout(tui.BoxConstraints.tight(tui.Size(_cols, _rows)));
      final nextBuffer = tui.Buffer.blank(_cols, _rows);
      root.paint(nextBuffer, tui.Offset.zero);
      _buffer = nextBuffer;
    } finally {
      _isRendering = false;
    }
    if (notify) {
      _bufferNotifier.emitCellChange();
    }
  }

  static int _displayColumnAt(String line, int graphemeCol) {
    var col = 0;
    var idx = 0;
    for (final ch in line.characters) {
      if (idx >= graphemeCol) break;
      col += math.max(1, tui.graphemeWidth(ch));
      idx++;
    }
    return col;
  }

  /// Releases the mounted `termui` element tree, controller listeners, and
  /// GPU frame watchdog.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    controller.removeListener(_handleControllerChanged);
    _rootElement?.unmount();
    _rootElement = null;
    gpuFrameWatchdog.dispose();
    controller.dispose();
    _bufferNotifier.dispose();
  }
}
