import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart'
    show ChangeNotifier, Listenable, StringCharacters;
import 'package:source_span/source_span.dart';
import 'package:termui/termui.dart' as tui;
import 'package:termui_flutter/termui_flutter.dart';

/// Live preview target stage for the shader editor pane.
enum ShaderEditorPreviewMode {
  /// Disables live shader preview on the editor pane.
  off('OFF'),

  /// Previews the draft shader behind the editor canvas.
  background('BG'),

  /// Previews the draft shader over the editor canvas via `iChannel0`.
  foreground('FG');

  /// Compact badge label displayed in the editor header bar.
  final String label;

  const ShaderEditorPreviewMode(this.label);
}

/// How the editor tab's draft preview composes with workspace shader chains.
enum ShaderEditorChainComposition {
  /// Overrides workspace shaders so only the editor's draft shader renders.
  solo('Solo'),

  /// Appends the draft shader to active workspace BG/FG shader chains.
  blendWithWorkspace('Blend');

  /// Compact toggle label displayed in the editor header bar.
  final String label;

  const ShaderEditorChainComposition(this.label);
}

/// Optional background color swatch applied to the editor preview canvas.
enum ShaderEditorBackgroundPreset {
  /// Uses the active terminal theme background color.
  themeDefault('Theme', null),

  /// Forces a dark charcoal backdrop to inspect light/neon shaders.
  dark('Dark', tui.Color(0x14, 0x17, 0x1F)),

  /// Forces a light backdrop to inspect dark or low-contrast shaders.
  light('Light', tui.Color(0xF6, 0xF8, 0xFA)),

  /// Forces pure black for maximum contrast inspection.
  highContrast('HiCon', tui.Color(0x00, 0x00, 0x00));

  /// Compact label shown on the header bar swatch chip.
  final String label;

  /// Explicit background color override, or `null` to follow the active theme.
  final tui.Color? colorOverride;

  const ShaderEditorBackgroundPreset(this.label, this.colorOverride);
}

/// Asynchronous draft compilation hook invoked after the edit debounce window.
///
/// May return compiler [ShaderDiagnostic]s directly or throw a
/// [ShaderCompileException].
typedef ShaderEditorCompileCallback = Future<List<ShaderDiagnostic>> Function(
  String source,
  ShaderEditorPreviewMode mode,
);

/// Asynchronous persistence hook invoked by [ShaderEditorController.save].
typedef ShaderEditorSaveCallback = Future<bool> Function(
  String shaderName,
  String? sourcePath,
  String source,
);

final class _PreviewChangeNotifier extends ChangeNotifier {
  void emit() => notifyListeners();
}

/// Reactive state controller for the in-app GLSL shader editor.
///
/// Manages source text, dirty tracking, 350ms debounced compilation with
/// monotonic generation gating, live preview mode, Solo vs Blend-with-Workspace
/// chain override, background opacity auto-reveal, stage annotations,
/// diagnostic navigation, and unsaved-close confirmation.
final class ShaderEditorController extends ChangeNotifier {
  /// Default debounce delay between edits and GPU compilation.
  static const Duration defaultDebounce = Duration(milliseconds: 350);

  /// Character count above which static GLSL analysis is debounced during
  /// typing to keep keystroke latency within a single frame budget.
  static const int largeBufferStaticCheckThreshold = 8192;

  /// Debounce delay for static GLSL analysis on large buffers.
  static const Duration staticCheckDebounce = Duration(milliseconds: 120);

  /// Default background opacity used to reveal background shaders in BG mode.
  static const double defaultBackgroundPreviewOpacity = 0.75;

  static final RegExp _stageDirectiveLine = RegExp(
    r'^\s*//\s*@(?:fterm-)?stage\s*:\s*(background|bg|foreground|fg|both|any)\b',
    caseSensitive: false,
  );
  static final RegExp _paramsUniformPattern = RegExp(r'\buParams[01]\b');

  final _PreviewChangeNotifier _previewNotifier = _PreviewChangeNotifier();
  late final ShaderEditorCompileCallback? _onCompile;
  late final ShaderEditorSaveCallback? _onSave;

  /// Debounce duration applied before invoking async draft compilation.
  final Duration debounceDuration;

  /// Backing `termui` multiline text controller (owns text, selection, scroll).
  final tui.TextEditingController textController;

  String _shaderName;
  String? _sourcePath;
  String _savedSource;
  String _lastObservedText;
  ShaderEditorPreviewMode _previewMode;
  ShaderEditorChainComposition _chainComposition;
  ShaderEditorBackgroundPreset _previewBackgroundPreset;
  double _bgPreviewOpacity;

  List<ShaderDiagnostic> _staticDiagnostics = const <ShaderDiagnostic>[];
  List<ShaderDiagnostic> _compilerDiagnostics = const <ShaderDiagnostic>[];
  List<ShaderDiagnostic> _runtimeDiagnostics = const <ShaderDiagnostic>[];
  ShaderCompileException? _lastRuntimeError;
  List<ShaderDiagnostic> _diagnostics = const <ShaderDiagnostic>[];
  ShadertoyGlslAnalysis? _lastAnalysis;
  int? _lastCompileDurationMs;
  bool _isCompiling = false;
  bool _confirmingClose = false;
  bool _promptingSaveAs = false;
  String _saveAsDraftName = '';
  String? _saveAsError;
  int _selectedDiagnosticIndex = -1;
  int _compileGeneration = 0;
  int _saveGeneration = 0;
  Timer? _debounceTimer;
  Timer? _staticCheckTimer;
  bool _disposed = false;

  /// Creates a [ShaderEditorController].
  ShaderEditorController({
    required this._shaderName,
    this._sourcePath,
    String initialSource = '',
    ShaderEditorPreviewMode initialPreviewMode = ShaderEditorPreviewMode.off,
    ShaderEditorChainComposition initialChainComposition =
        ShaderEditorChainComposition.solo,
    ShaderEditorBackgroundPreset initialBackgroundPreset =
        ShaderEditorBackgroundPreset.themeDefault,
    double initialBackgroundOpacity = defaultBackgroundPreviewOpacity,
    this.debounceDuration = defaultDebounce,
    ShaderEditorCompileCallback? onCompile,
    ShaderEditorSaveCallback? onSave,
  }) : _savedSource = initialSource,
       _lastObservedText = initialSource,
       _previewMode = initialPreviewMode,
       _chainComposition = initialChainComposition,
       _previewBackgroundPreset = initialBackgroundPreset,
       _bgPreviewOpacity = initialBackgroundOpacity.clamp(0.1, 1.0),
       textController = tui.TextEditingController(
         text: initialSource,
         undoCoalesceWindow: const Duration(milliseconds: 500),
       ) {
    _onCompile = onCompile;
    _onSave = onSave;
    textController.value = tui.TextEditingValue(
      text: initialSource,
      selection: const tui.TextSelection.collapsed(offset: 0),
    );
    textController.addListener(_handleTextControllerChanged);
    _refreshStaticDiagnostics();
  }

  /// Display filename or logical shader name (e.g. `'my_shader.glsl'`).
  String get shaderName => _shaderName;

  /// Optional filesystem path or Web storage key for saving.
  String? get sourcePath => _sourcePath;

  /// Current GLSL source text in the editor buffer.
  String get source => textController.text;

  /// Total number of lines in the current editor buffer.
  int get lineCount => textController.value.lines.length;

  /// Whether the buffer has unsaved edits relative to the last saved snapshot.
  bool get isDirty => textController.text != _savedSource;

  /// Active live preview mode (`off`, `background`, or `foreground`).
  ShaderEditorPreviewMode get previewMode => _previewMode;

  /// Active preview chain composition (`solo` by default, or
  /// `blendWithWorkspace`).
  ShaderEditorChainComposition get chainComposition => _chainComposition;

  /// Effective background opacity for the editor surface.
  ///
  /// Automatically reveals background shaders at [backgroundModeOpacity]
  /// (`0.75` by default) in [ShaderEditorPreviewMode.background], and stays
  /// opaque (`1.0`) in `off` and `foreground` modes.
  double get previewBackgroundOpacity =>
      _previewMode == ShaderEditorPreviewMode.background
      ? _bgPreviewOpacity
      : 1.0;

  /// Tuned opacity value applied whenever [previewMode] is `background`.
  double get backgroundModeOpacity => _bgPreviewOpacity;

  /// Active background color swatch preset for contrast testing.
  ShaderEditorBackgroundPreset get previewBackgroundPreset =>
      _previewBackgroundPreset;

  /// Optional background color override from [previewBackgroundPreset].
  tui.Color? get previewBackgroundColorOverride =>
      _previewBackgroundPreset.colorOverride;

  /// Duration of the most recent completed compilation pass in milliseconds.
  int? get lastCompileDurationMs => _lastCompileDurationMs;

  /// Whether an asynchronous compile pass is currently in flight.
  bool get isCompiling => _isCompiling;

  /// Most recent successful static GLSL analysis, if any.
  ShadertoyGlslAnalysis? get lastAnalysis => _lastAnalysis;

  /// Merged and sorted compiler, shim, and linter diagnostics.
  List<ShaderDiagnostic> get diagnostics =>
      List<ShaderDiagnostic>.unmodifiable(_diagnostics);

  /// Count of error-severity diagnostics.
  int get errorCount => _countBySeverity(ShaderDiagnosticSeverity.error);

  /// Count of warning-severity diagnostics.
  int get warningCount => _countBySeverity(ShaderDiagnosticSeverity.warning);

  /// Count of info-severity diagnostics.
  int get infoCount => _countBySeverity(ShaderDiagnosticSeverity.info);

  /// Currently focused diagnostic index (`-1` when none selected).
  int get selectedDiagnosticIndex => _selectedDiagnosticIndex;

  /// Whether the inline unsaved-changes close confirmation bar is active.
  bool get confirmingClose => _confirmingClose;

  /// Whether the inline Save As filename prompt is currently active.
  bool get promptingSaveAs => _promptingSaveAs;

  /// Current draft filename typed into the inline Save As prompt.
  String get saveAsDraftName => _saveAsDraftName;

  /// Validation error for the current Save As draft filename, if any.
  String? get saveAsError => _saveAsError;

  /// Monotonic compile generation counter incremented on each compile start.
  int get compileGeneration => _compileGeneration;

  /// Listenable notified whenever preview mode, composition, opacity, backdrop,
  /// or compiled draft output changes.
  Listenable get previewListenable => _previewNotifier;

  /// Whether the current source contains an explicit `// @fterm-stage:` or
  /// `// @stage:` annotation.
  bool get hasExplicitStageDirective {
    for (final line in textController.value.lines) {
      if (_stageDirectiveLine.hasMatch(line)) return true;
    }
    return false;
  }

  /// Stage hint detected from directive or static uniform analysis.
  ShaderStageHint get detectedStageHint =>
      _lastAnalysis?.stageHint ??
      _parseExplicitStageDirective(textController.value.lines) ??
      ShaderStageHint.any;

  /// Compact list of active uniforms detected in the current shader.
  List<String> get activeUniformLabels {
    final analysis = _lastAnalysis;
    if (analysis == null) return const <String>[];
    return <String>[
      if (analysis.usesTime) 'iTime',
      if (analysis.samplesChannel0) 'iChannel0',
      if (analysis.samplesChannel1) 'iChannel1',
      if (analysis.usesPrevFrame) 'iPrevFrame',
      if (analysis.usesCursorUniforms) 'iCursor',
      if (analysis.usesMouse) 'iMouse',
      if (_paramsUniformPattern.hasMatch(source)) 'uParams',
    ];
  }

  /// Resolves [diagnostic] to a `source_span` [FileSpan] against [source].
  FileSpan? spanForDiagnostic(ShaderDiagnostic diagnostic) {
    final file = SourceFile.fromString(source, url: sourcePath ?? shaderName);
    return diagnostic.toSourceSpan(file);
  }

  /// Builds the live preview [ShaderPassSpec] using [passId], or `null` when
  /// [previewMode] is [ShaderEditorPreviewMode.off] or the source is empty.
  ShaderPassSpec? buildPreviewPassSpec(String passId) {
    if (_previewMode == ShaderEditorPreviewMode.off) return null;
    if (source.trim().isEmpty) return null;
    return ShaderPassSpec(
      id: passId,
      stage: _previewMode == ShaderEditorPreviewMode.foreground
          ? TerminalShaderStage.foreground
          : TerminalShaderStage.background,
      inlineGlsl: source,
      usesPrevFrame: _lastAnalysis?.usesPrevFrame ?? false,
    );
  }

  /// Switches the live preview mode and triggers recompilation when active.
  void setPreviewMode(ShaderEditorPreviewMode mode) {
    if (_disposed || _previewMode == mode) return;
    _previewMode = mode;
    _compileGeneration++;
    _isCompiling = false;
    if (mode == ShaderEditorPreviewMode.off) {
      _debounceTimer?.cancel();
      _debounceTimer = null;
      _runtimeDiagnostics = const <ShaderDiagnostic>[];
      _lastRuntimeError = null;
    }
    _staticCheckTimer?.cancel();
    _staticCheckTimer = null;
    _refreshStaticDiagnostics();
    _previewNotifier.emit();
    notifyListeners();
    if (mode != ShaderEditorPreviewMode.off) {
      _scheduleDebouncedCompile();
    }
  }

  /// Adjusts background preview opacity by [delta] (`0.1..1.0`).
  void adjustPreviewOpacity(double delta) {
    if (_disposed) return;
    final next = ((_bgPreviewOpacity + delta) * 20).round() / 20.0;
    final clamped = next.clamp(0.1, 1.0);
    if (clamped == _bgPreviewOpacity) return;
    _bgPreviewOpacity = clamped;
    if (_previewMode == ShaderEditorPreviewMode.background) {
      _previewNotifier.emit();
    }
    notifyListeners();
  }

  /// Sets [chainComposition] (`solo` or `blendWithWorkspace`).
  void setChainComposition(ShaderEditorChainComposition mode) {
    if (_disposed || _chainComposition == mode) return;
    _chainComposition = mode;
    _previewNotifier.emit();
    notifyListeners();
  }

  /// Toggles between [ShaderEditorChainComposition.solo] and
  /// [ShaderEditorChainComposition.blendWithWorkspace].
  void toggleChainComposition() {
    setChainComposition(
      _chainComposition == ShaderEditorChainComposition.solo
          ? ShaderEditorChainComposition.blendWithWorkspace
          : ShaderEditorChainComposition.solo,
    );
  }

  /// Sets the preview background swatch preset.
  void setBackgroundPreset(ShaderEditorBackgroundPreset preset) {
    if (_disposed || _previewBackgroundPreset == preset) return;
    _previewBackgroundPreset = preset;
    _previewNotifier.emit();
    notifyListeners();
  }

  /// Cycles through [ShaderEditorBackgroundPreset.values].
  void cycleBackgroundPreset() {
    const values = ShaderEditorBackgroundPreset.values;
    final nextIndex = (_previewBackgroundPreset.index + 1) % values.length;
    setBackgroundPreset(values[nextIndex]);
  }

  /// Inserts or replaces the `// @fterm-stage:` directive at the top of the
  /// shader source.
  void insertStageAnnotation(ShaderStageHint hint) {
    if (_disposed) return;
    final directive = switch (hint) {
      ShaderStageHint.background => '// @fterm-stage: bg',
      ShaderStageHint.foreground => '// @fterm-stage: fg',
      ShaderStageHint.any => '// @fterm-stage: both',
    };
    textController.saveStateToHistory();
    final lines = List<String>.from(textController.value.lines);
    final sel = textController.value.selection;
    final existingIdx = _findStageDirectiveLine(lines);
    final int nextLine;
    if (existingIdx != null) {
      final hasCr =
          existingIdx < lines.length - 1 && lines[existingIdx].endsWith('\r');
      lines[existingIdx] = hasCr ? '$directive\r' : directive;
      nextLine = sel.cursorLine;
    } else {
      final hasCr = lines.length > 1 && lines[0].endsWith('\r');
      lines.insert(0, hasCr ? '$directive\r' : directive);
      nextLine = sel.cursorLine + 1;
    }
    final clampedLine = nextLine.clamp(0, lines.length - 1);
    final clampedCol = sel.cursorColumn.clamp(
      0,
      _lineGraphemeLength(lines, clampedLine),
    );
    final nextText = lines.join('\n');
    textController.value = tui.TextEditingValue(
      text: nextText,
      selection: tui.TextSelection.collapsed(
        offset: _graphemeOffset(lines, clampedLine, clampedCol),
        line: clampedLine,
        column: clampedCol,
      ),
    );
  }

  /// Inserts the inferred stage annotation when absent, or cycles through
  /// `bg -> fg -> both` when one is already present.
  void cycleStageAnnotation() {
    final explicit = _parseExplicitStageDirective(textController.value.lines);
    if (explicit == null) {
      insertStageAnnotation(detectedStageHint);
      return;
    }
    final next = switch (explicit) {
      ShaderStageHint.background => ShaderStageHint.foreground,
      ShaderStageHint.foreground => ShaderStageHint.any,
      ShaderStageHint.any => ShaderStageHint.background,
    };
    insertStageAnnotation(next);
  }

  /// Moves the editor cursor directly to diagnostic at [index].
  bool jumpToDiagnostic(int index) {
    if (_disposed || index < 0 || index >= _diagnostics.length) return false;
    final diag = _diagnostics[index];
    final lines = textController.value.lines;
    final lineIdx = ((diag.line ?? 1) - 1).clamp(0, lines.length - 1);
    final colIdx = _utf16ColumnToGraphemeColumn(
      _lineContent(lines, lineIdx),
      (diag.column ?? 1) - 1,
    );
    textController.breakUndoBurst();
    textController.value = tui.TextEditingValue(
      text: textController.value.text,
      selection: tui.TextSelection.collapsed(
        offset: _graphemeOffset(lines, lineIdx, colIdx),
        line: lineIdx,
        column: colIdx,
      ),
    );
    _selectedDiagnosticIndex = index;
    notifyListeners();
    return true;
  }

  /// Advances to and focuses the next diagnostic in [diagnostics].
  bool jumpToNextDiagnostic() {
    if (_diagnostics.isEmpty) return false;
    final next = (_selectedDiagnosticIndex + 1) % _diagnostics.length;
    return jumpToDiagnostic(next);
  }

  /// Captures the current cursor selection and vertical scroll offset so live
  /// navigation previews can be restored cleanly on cancel.
  ({tui.TextSelection selection, int scrollOffset})
  captureNavigationSnapshot() => (
    selection: textController.value.selection,
    scrollOffset: textController.scrollOffset,
  );

  /// Restores a previously captured cursor selection and vertical scroll
  /// offset without breaking undo history.
  void restoreNavigationSnapshot(
    ({tui.TextSelection selection, int scrollOffset}) snapshot,
  ) {
    if (_disposed) return;
    final current = textController.value;
    final lines = current.lines;
    final maxOffset = current.text.characters.length;
    final clampedLine = snapshot.selection.cursorLine.clamp(
      0,
      lines.length - 1,
    );
    final clampedCol = snapshot.selection.cursorColumn.clamp(
      0,
      _lineGraphemeLength(lines, clampedLine),
    );
    final restoredSelection = tui.TextSelection(
      baseOffset: snapshot.selection.baseOffset.clamp(0, maxOffset),
      extentOffset: snapshot.selection.extentOffset.clamp(0, maxOffset),
      cursorLine: clampedLine,
      cursorColumn: clampedCol,
    );
    textController.value = tui.TextEditingValue(
      text: current.text,
      selection: restoredSelection,
    );
    textController.scrollOffset = snapshot.scrollOffset;
  }

  /// Moves the editor cursor to 1-based [oneBasedLine] and [oneBasedColumn],
  /// optionally selecting [selectionLength] UTF-16 code units forward on that
  /// line.
  bool jumpToLine(
    int oneBasedLine, {
    int oneBasedColumn = 1,
    int selectionLength = 0,
  }) {
    if (_disposed) return false;
    final lines = textController.value.lines;
    if (lines.isEmpty) return false;
    final lineIdx = (oneBasedLine - 1).clamp(0, lines.length - 1);
    final lineText = _lineContent(lines, lineIdx);
    final startUtf16 = oneBasedColumn > 1 ? oneBasedColumn - 1 : 0;
    final startCol = _utf16ColumnToGraphemeColumn(lineText, startUtf16);
    final baseOffset = _graphemeOffset(lines, lineIdx, startCol);
    final tui.TextSelection nextSelection;
    if (selectionLength > 0) {
      final endCol = _utf16ColumnToGraphemeColumn(
        lineText,
        startUtf16 + selectionLength,
      );
      final extentOffset = _graphemeOffset(lines, lineIdx, endCol);
      nextSelection = tui.TextSelection(
        baseOffset: baseOffset,
        extentOffset: extentOffset,
        cursorLine: lineIdx,
        cursorColumn: endCol,
      );
    } else {
      nextSelection = tui.TextSelection.collapsed(
        offset: baseOffset,
        line: lineIdx,
        column: startCol,
      );
    }
    textController.breakUndoBurst();
    final nextValue = tui.TextEditingValue(
      text: textController.value.text,
      selection: nextSelection,
    );
    if (textController.value != nextValue) {
      textController.value = nextValue;
    } else {
      notifyListeners();
    }
    return true;
  }

  /// Requests closing this editor tab.
  ///
  /// Returns `true` if the buffer is clean and can close immediately, or sets
  /// [confirmingClose] to `true` and returns `false` when unsaved edits exist.
  bool requestClose() {
    if (_disposed) return true;
    if (!isDirty) return true;
    if (!_confirmingClose) {
      _confirmingClose = true;
      notifyListeners();
    }
    return false;
  }

  /// Dismisses the inline unsaved-changes close prompt.
  void cancelCloseConfirmation() {
    if (_disposed || !_confirmingClose) return;
    _confirmingClose = false;
    notifyListeners();
  }

  /// Opens the inline Save As filename prompt pre-filled with [shaderName].
  void beginSaveAs() {
    if (_disposed) return;
    _confirmingClose = false;
    _promptingSaveAs = true;
    _saveAsDraftName = _shaderName;
    _saveAsError = null;
    notifyListeners();
  }

  /// Dismisses the inline Save As filename prompt without saving.
  void cancelSaveAs() {
    if (_disposed || !_promptingSaveAs) return;
    _promptingSaveAs = false;
    _saveAsError = null;
    notifyListeners();
  }

  /// Appends printable characters from [text] into [saveAsDraftName].
  void appendSaveAsText(String text) {
    if (_disposed || !_promptingSaveAs || text.isEmpty) return;
    final sanitized = text.replaceAll('\r', '').replaceAll('\n', '');
    if (sanitized.isEmpty) return;
    _saveAsDraftName = '$_saveAsDraftName$sanitized';
    _saveAsError = null;
    notifyListeners();
  }

  /// Removes the final grapheme cluster from [saveAsDraftName].
  void backspaceSaveAsChar() {
    if (_disposed || !_promptingSaveAs || _saveAsDraftName.isEmpty) return;
    final chars = _saveAsDraftName.characters;
    _saveAsDraftName = chars.take(chars.length - 1).string;
    _saveAsError = null;
    notifyListeners();
  }

  /// Clears [saveAsDraftName] so the user can type a fresh filename.
  void clearSaveAsDraft() {
    if (_disposed || !_promptingSaveAs || _saveAsDraftName.isEmpty) return;
    _saveAsDraftName = '';
    _saveAsError = null;
    notifyListeners();
  }

  /// Validates and persists the active Save As draft filename.
  Future<bool> confirmSaveAs() {
    if (_disposed || !_promptingSaveAs) return Future<bool>.value(false);
    return saveAs(_saveAsDraftName);
  }

  /// Persists the current buffer under [targetName] via the configured save
  /// callback, updating [shaderName] and [sourcePath] on success.
  Future<bool> saveAs(String targetName) async {
    if (_disposed) return false;
    final normalized = normalizeSaveAsFilename(targetName);
    if (normalized == null) {
      _saveAsError = 'Enter a valid filename without / or \\.';
      notifyListeners();
      return false;
    }
    final gen = ++_saveGeneration;
    final snapshot = textController.text;
    final saved = _onSave == null
        ? true
        : await _onSave(normalized, null, snapshot);
    if (_disposed || gen != _saveGeneration) return false;
    if (!saved) {
      _saveAsError = 'Unable to save "$normalized".';
      notifyListeners();
      return false;
    }
    _shaderName = normalized;
    _sourcePath = normalized;
    _savedSource = snapshot;
    if (!isDirty) {
      _confirmingClose = false;
    }
    _promptingSaveAs = false;
    _saveAsError = null;
    notifyListeners();
    return true;
  }

  static final RegExp _illegalFilenameChars = RegExp(r'[\x00-\x1F\x7F:<>"|?*]');
  static final RegExp _winReservedStem = RegExp(
    r'^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])$',
    caseSensitive: false,
  );

  /// Validates and normalizes a user-supplied Save As [rawName], appending
  /// `.glsl` when no supported shader extension is present.
  ///
  /// Returns `null` for empty names, empty-stem dotfiles (`.glsl`/`.frag`),
  /// leading/trailing dots or whitespace on the stem, Windows reserved device
  /// names (`CON`, `PRN`, `AUX`, `NUL`, `COM1..9`, `LPT1..9`), path
  /// separators, traversal segments, or illegal control/filename characters.
  static String? normalizeSaveAsFilename(String rawName) {
    final trimmed = rawName.trim();
    if (trimmed.isEmpty ||
        trimmed.contains('/') ||
        trimmed.contains(r'\') ||
        _illegalFilenameChars.hasMatch(trimmed)) {
      return null;
    }
    final lower = trimmed.toLowerCase();
    final hasExt = lower.endsWith('.glsl') || lower.endsWith('.frag');
    final stem = hasExt ? trimmed.substring(0, trimmed.length - 5) : trimmed;
    if (stem.isEmpty ||
        stem.startsWith('.') ||
        stem.endsWith('.') ||
        stem.trim() != stem) {
      return null;
    }
    final baseStem = stem.split('.').first;
    if (_winReservedStem.hasMatch(stem) ||
        _winReservedStem.hasMatch(baseStem)) {
      return null;
    }
    return hasExt ? trimmed : '$stem.glsl';
  }

  /// Persists the current buffer via the configured save callback and marks
  /// the buffer clean on success.
  Future<bool> save() async {
    if (_disposed) return false;
    final gen = ++_saveGeneration;
    final snapshot = textController.text;
    final saved = _onSave == null
        ? true
        : await _onSave(_shaderName, _sourcePath, snapshot);
    if (_disposed || !saved || gen != _saveGeneration) return false;
    _savedSource = snapshot;
    if (!isDirty) {
      _confirmingClose = false;
    }
    _promptingSaveAs = false;
    _saveAsError = null;
    notifyListeners();
    return true;
  }

  /// Marks the current buffer text as saved without invoking a save callback.
  void markSaved() {
    if (_disposed) return;
    _saveGeneration++;
    _savedSource = textController.text;
    _confirmingClose = false;
    notifyListeners();
  }

  /// Cancels any pending debounce timer and runs a compile pass immediately.
  Future<void> triggerCompileNow() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _staticCheckTimer?.cancel();
    _staticCheckTimer = null;
    return _runCompilePass();
  }

  /// Records or clears a runtime GPU pipeline link or draw [error] surfaced
  /// after static and offline compilation succeeded.
  ///
  /// Repeated calls with an equivalent error (or `null` when already clear)
  /// are no-ops so workspace controller updates never trigger rebuild loops.
  void setRuntimeCompileError(ShaderCompileException? error) {
    if (_disposed) return;
    if (_isSameRuntimeError(_lastRuntimeError, error)) return;
    _lastRuntimeError = error;
    _runtimeDiagnostics = error == null
        ? const <ShaderDiagnostic>[]
        : _diagnosticsFromCompileException(error);
    _rebuildDiagnostics();
    notifyListeners();
  }

  static bool _isSameRuntimeError(
    ShaderCompileException? a,
    ShaderCompileException? b,
  ) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    return a.shaderId == b.shaderId &&
        a.lineNumber == b.lineNumber &&
        a.message == b.message &&
        a.compilerLog == b.compilerLog &&
        listEquals(a.diagnostics, b.diagnostics);
  }

  void _handleTextControllerChanged() {
    if (_disposed) return;
    final currentText = textController.text;
    if (currentText == _lastObservedText) {
      notifyListeners();
      return;
    }
    _lastObservedText = currentText;
    if (_confirmingClose) {
      _confirmingClose = false;
    }
    _compileGeneration++;
    _isCompiling = false;
    _compilerDiagnostics = const <ShaderDiagnostic>[];
    _runtimeDiagnostics = const <ShaderDiagnostic>[];
    _lastRuntimeError = null;
    if (currentText.length >= largeBufferStaticCheckThreshold) {
      _scheduleDebouncedStaticCheck();
    } else {
      _staticCheckTimer?.cancel();
      _staticCheckTimer = null;
      _refreshStaticDiagnostics();
    }
    _scheduleDebouncedCompile();
    notifyListeners();
  }

  void _scheduleDebouncedStaticCheck() {
    _staticCheckTimer?.cancel();
    _staticCheckTimer = Timer(staticCheckDebounce, () {
      _staticCheckTimer = null;
      if (_disposed) return;
      _refreshStaticDiagnostics();
      notifyListeners();
    });
  }

  void _scheduleDebouncedCompile() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounceDuration, () {
      unawaited(_runCompilePass());
    });
  }

  void _refreshStaticDiagnostics() {
    final snapshot = textController.text;
    final staticResult = _evaluateStaticChecks(snapshot);
    _lastAnalysis = staticResult.analysis;
    _staticDiagnostics = staticResult.diagnostics;
    _rebuildDiagnostics();
  }

  Future<void> _runCompilePass() async {
    if (_disposed) return;
    _staticCheckTimer?.cancel();
    _staticCheckTimer = null;
    final gen = ++_compileGeneration;
    final snapshot = textController.text;
    final mode = _previewMode;
    final startedAt = clock.now();

    final staticResult = _evaluateStaticChecks(snapshot);
    _lastAnalysis = staticResult.analysis;
    _staticDiagnostics = staticResult.diagnostics;
    _runtimeDiagnostics = const <ShaderDiagnostic>[];
    _lastRuntimeError = null;

    if (staticResult.hasShimError || _onCompile == null) {
      _lastCompileDurationMs = clock.now().difference(startedAt).inMilliseconds;
      _isCompiling = false;
      _compilerDiagnostics = const <ShaderDiagnostic>[];
      _rebuildDiagnostics();
      if (!staticResult.hasShimError && mode != ShaderEditorPreviewMode.off) {
        _previewNotifier.emit();
      }
      notifyListeners();
      return;
    }

    _isCompiling = true;
    notifyListeners();

    final compilerDiags = await _invokeCompileCallback(snapshot, mode);
    if (_disposed || gen != _compileGeneration) return;

    _lastCompileDurationMs = clock.now().difference(startedAt).inMilliseconds;
    _isCompiling = false;
    _compilerDiagnostics = compilerDiags;
    _rebuildDiagnostics();
    if (mode != ShaderEditorPreviewMode.off &&
        _previewMode != ShaderEditorPreviewMode.off) {
      _previewNotifier.emit();
    }
    notifyListeners();
  }

  Future<List<ShaderDiagnostic>> _invokeCompileCallback(
    String snapshot,
    ShaderEditorPreviewMode mode,
  ) async {
    try {
      return await _onCompile!(snapshot, mode);
    } on ShaderCompileException catch (error) {
      return _diagnosticsFromCompileException(error);
    } on Object catch (error) {
      return <ShaderDiagnostic>[
        ShaderDiagnostic(
          severity: ShaderDiagnosticSeverity.error,
          origin: ShaderDiagnosticOrigin.compiler,
          message: '$error',
        ),
      ];
    }
  }

  static List<ShaderDiagnostic> _diagnosticsFromCompileException(
    ShaderCompileException error,
  ) {
    if (error.diagnostics.isNotEmpty) return error.diagnostics;
    return <ShaderDiagnostic>[
      ShaderDiagnostic(
        severity: ShaderDiagnosticSeverity.error,
        origin: ShaderDiagnosticOrigin.compiler,
        message: error.message,
        line: error.lineNumber,
      ),
    ];
  }

  ({
    ShadertoyGlslAnalysis? analysis,
    List<ShaderDiagnostic> diagnostics,
    bool hasShimError,
  })
  _evaluateStaticChecks(String snapshot) {
    ShadertoyGlslAnalysis? analysis;
    final shimErrors = <ShaderDiagnostic>[];
    try {
      analysis = ShadertoyGlslShim.analyze(snapshot, shaderId: shaderName);
    } on ShaderCompileException catch (error) {
      if (error.diagnostics.isNotEmpty) {
        shimErrors.addAll(error.diagnostics);
      } else {
        shimErrors.add(
          ShaderDiagnostic(
            severity: ShaderDiagnosticSeverity.error,
            origin: ShaderDiagnosticOrigin.shim,
            message: error.message,
            line: error.lineNumber,
          ),
        );
      }
    }

    final lintStage = _resolveLintStage(analysis);
    final lintDiags = ShadertoyGlslShim.lint(snapshot, stage: lintStage);
    return (
      analysis: analysis,
      diagnostics: <ShaderDiagnostic>[...shimErrors, ...lintDiags],
      hasShimError: shimErrors.isNotEmpty,
    );
  }

  TerminalShaderStage _resolveLintStage(ShadertoyGlslAnalysis? analysis) =>
      switch (_previewMode) {
        ShaderEditorPreviewMode.background => TerminalShaderStage.background,
        ShaderEditorPreviewMode.foreground => TerminalShaderStage.foreground,
        ShaderEditorPreviewMode.off =>
          analysis?.stageHint == ShaderStageHint.foreground
              ? TerminalShaderStage.foreground
              : TerminalShaderStage.background,
      };

  void _rebuildDiagnostics() {
    final seen = <(ShaderDiagnosticSeverity, int?, int?, String)>{};
    final merged = <ShaderDiagnostic>[];
    for (final diag in <ShaderDiagnostic>[
      ..._compilerDiagnostics,
      ..._runtimeDiagnostics,
      ..._staticDiagnostics,
    ]) {
      final key = (diag.severity, diag.line, diag.column, diag.message);
      if (seen.add(key)) {
        merged.add(diag);
      }
    }
    merged.sort(_compareDiagnostics);
    _diagnostics = merged;
    if (_diagnostics.isEmpty) {
      _selectedDiagnosticIndex = -1;
    } else if (_selectedDiagnosticIndex >= _diagnostics.length) {
      _selectedDiagnosticIndex = _diagnostics.length - 1;
    }
  }

  int _countBySeverity(ShaderDiagnosticSeverity severity) {
    var count = 0;
    for (final diag in _diagnostics) {
      if (diag.severity == severity) count++;
    }
    return count;
  }

  static int? _findStageDirectiveLine(List<String> lines) {
    for (var i = 0; i < lines.length; i++) {
      if (_stageDirectiveLine.hasMatch(lines[i])) return i;
    }
    return null;
  }

  static ShaderStageHint? _parseExplicitStageDirective(List<String> lines) {
    final idx = _findStageDirectiveLine(lines);
    if (idx == null) return null;
    final raw = _stageDirectiveLine
        .firstMatch(lines[idx])
        ?.group(1)
        ?.toLowerCase();
    return switch (raw) {
      'background' || 'bg' => ShaderStageHint.background,
      'foreground' || 'fg' => ShaderStageHint.foreground,
      'both' || 'any' => ShaderStageHint.any,
      _ => null,
    };
  }

  static int _compareDiagnostics(ShaderDiagnostic a, ShaderDiagnostic b) {
    final lineCmp = (a.line ?? 0).compareTo(b.line ?? 0);
    if (lineCmp != 0) return lineCmp;
    final colCmp = (a.column ?? 0).compareTo(b.column ?? 0);
    if (colCmp != 0) return colCmp;
    return a.severity.index.compareTo(b.severity.index);
  }

  static String _lineContent(List<String> lines, int index) {
    final line = lines[index];
    return index < lines.length - 1 && line.endsWith('\r')
        ? line.substring(0, line.length - 1)
        : line;
  }

  static int _lineGraphemeLength(List<String> lines, int index) =>
      _lineContent(lines, index).characters.length;

  static int _graphemeOffset(List<String> lines, int line, int column) {
    var offset = 0;
    for (var i = 0; i < line; i++) {
      offset += _lineGraphemeLength(lines, i) + 1;
    }
    return offset + column.clamp(0, _lineGraphemeLength(lines, line));
  }

  static int _utf16ColumnToGraphemeColumn(String line, int utf16Col) {
    if (utf16Col <= 0) return 0;
    var units = 0;
    var graphemeIdx = 0;
    for (final ch in line.characters) {
      if (units >= utf16Col) break;
      units += ch.length;
      graphemeIdx++;
    }
    return graphemeIdx;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _staticCheckTimer?.cancel();
    _staticCheckTimer = null;
    textController.removeListener(_handleTextControllerChanged);
    _previewNotifier.dispose();
    super.dispose();
  }
}
