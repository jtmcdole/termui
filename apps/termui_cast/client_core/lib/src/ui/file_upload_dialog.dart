import 'dart:async';
import 'dart:math';

import 'package:termui/termui.dart';

import '../cast_workspace_view_model.dart';
import '../file_upload_coordinator.dart';
import '../models.dart';
import 'dialog_theme.dart';

/// Pure-Dart `termui` modal dialog confirming browser-to-host file drops and
/// rendering a live multi-stop gradient [LinearProgressIndicator] during upload.
final class FileUploadDialog extends StatefulWidget {
  /// Backing workspace view model coordinating the file transfer.
  final CastWorkspaceViewModel viewModel;

  /// Dropped file sources captured from the browser or desktop drop event.
  final List<DroppedFileSource> droppedFiles;

  /// Maximum allowed byte size per file (`256 MiB` by default).
  final int maxUploadBytes;

  /// Creates a file upload confirmation and progress modal dialog.
  const FileUploadDialog({
    super.key,
    required this.viewModel,
    required this.droppedFiles,
    this.maxUploadBytes = FileUploadCoordinator.maxUploadBytes,
  });

  /// Displays a centered [FileUploadDialog] on [sceneManager] and returns `true`
  /// when the upload batch completes, or `false`/`null` when cancelled.
  static Future<bool?> show(
    SceneManager sceneManager, {
    required CastWorkspaceViewModel viewModel,
    required List<DroppedFileSource> droppedFiles,
    int maxUploadBytes = FileUploadCoordinator.maxUploadBytes,
    TerminalColorTheme? terminalTheme,
    WorkspaceChromeTheme? chromeTheme,
    Color? barrierColor,
    Color? defaultForeground,
    Color? defaultBackground,
    bool barrierDismissible = true,
  }) {
    final size = clampDialogSize(
      sceneManager.terminal.backend.size,
      preferredWidth: 68,
      minWidth: 28,
      preferredHeight: 16,
      minHeight: 9,
    );
    return showThemedDialog<bool>(
      sceneManager,
      width: size.x,
      height: size.y,
      terminalTheme: terminalTheme ?? viewModel.activeTerminalTheme,
      chromeTheme: chromeTheme,
      barrierColor: barrierColor,
      defaultForeground: defaultForeground,
      defaultBackground: defaultBackground,
      barrierDismissible: barrierDismissible,
      builder: (_) => FileUploadDialog(
        viewModel: viewModel,
        droppedFiles: droppedFiles,
        maxUploadBytes: maxUploadBytes,
      ),
    );
  }

  @override
  State<FileUploadDialog> createState() => _FileUploadDialogState();
}

final class _FileUploadDialogState extends State<FileUploadDialog>
    implements Focusable, KeyEventHandler {
  static const Style _defaultNoteStyle = Style(
    foreground: Color(130, 218, 255),
  );
  static const Style _defaultWarnStyle = Style(
    foreground: Color(235, 185, 78),
    modifiers: Modifier.bold,
  );
  static const Style _defaultProgressTrackStyle = Style(
    foreground: Color(255, 255, 255),
    background: Color(26, 32, 44),
    modifiers: Modifier.bold,
  );
  static const List<GradientStop> _progressGradientStops = [
    (color: Color(72, 187, 255), stop: 0.0),
    (color: Color(98, 209, 150), stop: 0.5),
    (color: Color(255, 220, 120), stop: 1.0),
  ];

  late final List<DroppedFileSource> _validFiles;
  late final int _skippedDirectories;
  late final int _skippedOversized;
  late final int _totalValidBytes;
  late final void Function() _removeVisualListener;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    final valid = <DroppedFileSource>[];
    var dirs = 0;
    var oversized = 0;
    var sumBytes = 0;
    for (final file in widget.droppedFiles) {
      if (file.isDirectory) {
        dirs++;
      } else if (file.size < 0 || file.size > widget.maxUploadBytes) {
        oversized++;
      } else {
        valid.add(file);
        sumBytes += file.size;
      }
    }
    _validFiles = List<DroppedFileSource>.unmodifiable(valid);
    _skippedDirectories = dirs;
    _skippedOversized = oversized;
    _totalValidBytes = sumBytes;
    _removeVisualListener = widget.viewModel.addVisualListener(_onVmChanged);
  }

  @override
  void dispose() {
    _removeVisualListener();
    super.dispose();
  }

  void _onVmChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  static ({Style note, Style warn, Style track}) _resolveUploadStyles(
    WorkspaceChromeTheme chrome,
  ) {
    if (chrome == WorkspaceChromeTheme.defaultDark) {
      return (
        note: _defaultNoteStyle,
        warn: _defaultWarnStyle,
        track: _defaultProgressTrackStyle,
      );
    }
    final panelBg =
        chrome.panelDecoration.backgroundColor ?? const Color(20, 24, 32);
    final isLight = TerminalContrast.relativeLuminance(panelBg) >= 0.5;
    final trackBg = WorkspaceChromeTheme.shiftRgb(panelBg, isLight ? -16 : 8);
    final noteFg = TerminalContrast.enforceMinimumContrast(
      chrome.actionButtonStyle.foreground ?? const Color(9, 105, 218),
      panelBg,
      minRatio: 4.5,
    );
    final warnFg = TerminalContrast.enforceMinimumContrast(
      chrome.warningBannerStyle.background ?? const Color(154, 103, 0),
      panelBg,
      minRatio: 4.5,
    );
    final trackFg = TerminalContrast.ensureReadableTextOn(
      chrome.rowStyle.foreground ?? Colors.white,
      trackBg,
    );
    return (
      note: Style(foreground: noteFg),
      warn: Style(foreground: warnFg, modifiers: Modifier.bold),
      track: Style(
        foreground: trackFg,
        background: trackBg,
        modifiers: Modifier.bold,
      ),
    );
  }

  Future<void> _confirmAndStartUpload(BuildContext context) async {
    if (_uploading) return;
    if (_validFiles.isEmpty) {
      PromptScope.of(context)?.done(false);
      return;
    }
    setState(() {
      _uploading = true;
    });
    final ok = await widget.viewModel.uploadDroppedFiles(_validFiles);
    if (!mounted) return;
    PromptScope.of(context)?.done(ok);
  }

  void _cancelOrDismiss(BuildContext context) {
    if (_uploading) {
      widget.viewModel.cancelActiveFileUpload();
    }
    PromptScope.of(context)?.done(false);
  }

  @override
  bool get focused => true;

  @override
  bool handleKeyEvent(KeyEvent event) => _handleKeyEvent(context, event);

  bool _handleKeyEvent(BuildContext context, KeyEvent event) {
    if (_uploading) return _handleUploadingKey(context, event);
    if (_isCancelKey(event)) {
      _cancelOrDismiss(context);
      return true;
    }
    if (_isConfirmKey(event)) {
      unawaited(_confirmAndStartUpload(context));
      return true;
    }
    return false;
  }

  bool _handleUploadingKey(BuildContext context, KeyEvent event) {
    if (_isCancelKey(event)) {
      _cancelOrDismiss(context);
      return true;
    }
    // Consume Enter/Space while uploading so double-Enter does not abort.
    return event.type == .enter ||
        (event.type == .character && event.key == ' ');
  }

  bool _isConfirmKey(KeyEvent event) =>
      event.type == .enter ||
      (_validFiles.isNotEmpty &&
          event.type == .character &&
          event.key.toLowerCase() == 'y');

  static bool _isCancelKey(KeyEvent event) {
    if (event.type == .escape) return true;
    if (event.type != .character) return false;
    final lower = event.key.toLowerCase();
    return lower == 'n' || lower == 'q';
  }

  @override
  Widget build(BuildContext context) {
    final scopeChrome = WorkspaceChromeScope.of(context);
    final chrome = scopeChrome == WorkspaceChromeTheme.defaultDark
        ? WorkspaceChromeTheme.fromTerminalTheme(
            widget.viewModel.activeTerminalTheme,
          )
        : scopeChrome;
    return DecoratedBox(
      decoration: chrome.panelDecoration,
      child: Padding(
        padding: const .symmetric(horizontal: 2, vertical: 1),
        child: Column([
          Text(
            _uploading
                ? 'Uploading Files to Remote Host'
                : 'Upload Files to Remote Host',
            style: chrome.titleStyle,
            wrap: false,
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (_, constraints) {
                final budget = max(0, constraints.maxHeight);
                final rows = _uploading
                    ? _buildUploadingRows(
                        widget.viewModel.fileUploadProgress,
                        chrome,
                      )
                    : _buildConfirmationRows(chrome);
                return Column([
                  for (var i = 0; i < rows.length && i < budget; i++) rows[i],
                ], crossAxisAlignment: .stretch);
              },
            ),
          ),
          _buildActionRow(context, chrome),
        ], crossAxisAlignment: .stretch),
      ),
    );
  }

  List<Widget> _buildConfirmationRows(WorkspaceChromeTheme chrome) {
    final sessionLabel = widget.viewModel.activeSessionId?.value ?? 'none';
    final styles = _resolveUploadStyles(chrome);
    return [
      Text(
        'Files: ${_validFiles.length} (${formatByteCount(_totalValidBytes)}) -> session $sessionLabel',
        style: chrome.rowStyle,
        wrap: false,
      ),
      for (final file in _validFiles.take(3))
        Text(
          '  - ${FileUploadCoordinator.sanitizeWireFileName(file.name)} (${formatByteCount(file.size)})',
          style: chrome.rowStyle,
          wrap: false,
        ),
      if (_validFiles.length > 3)
        Text(
          '  ... and ${_validFiles.length - 3} more file(s)',
          style: chrome.hintStyle,
          wrap: false,
        ),
      Text(
        'Note: Saves to termui_cast host (not Docker/Podman).',
        style: styles.note,
        wrap: false,
      ),
      if (_skippedDirectories > 0)
        Text(
          'Skipped $_skippedDirectories director${_skippedDirectories == 1 ? 'y' : 'ies'} (v0.1 uploads flat files only).',
          style: styles.warn,
          wrap: false,
        ),
      if (_skippedOversized > 0)
        Text(
          'Skipped $_skippedOversized file(s) exceeding ${formatByteCount(widget.maxUploadBytes)}.',
          style: styles.warn,
          wrap: false,
        ),
      if (_validFiles.isEmpty)
        Text('No eligible files to upload.', style: styles.warn, wrap: false)
      else
        Text(
          'Enter / y: upload | Esc / n: cancel',
          style: chrome.hintStyle,
          wrap: false,
        ),
    ];
  }

  List<Widget> _buildUploadingRows(
    FileUploadProgress? progress,
    WorkspaceChromeTheme chrome,
  ) {
    final fileIdx = progress?.fileIndex ?? 1;
    final fileCnt = progress?.fileCount ?? max(1, _validFiles.length);
    final fileName = progress?.currentFileName ?? '';
    final sent = progress?.overallSentBytes ?? 0;
    final total = progress?.overallTotalBytes ?? _totalValidBytes;
    final fraction = progress?.fraction ?? 0.0;
    final styles = _resolveUploadStyles(chrome);

    return [
      Text(
        'File ($fileIdx/$fileCnt): $fileName',
        style: chrome.rowStyle,
        wrap: false,
      ),
      Text(
        'Progress: ${formatByteCount(sent)} / ${formatByteCount(total)}',
        style: styles.note,
        wrap: false,
      ),
      SizedBox(
        height: 1,
        child: LinearProgressIndicator(
          fraction,
          smooth: true,
          showPercentage: true,
          style: styles.track,
          colorBuilder: (_, _) => const (fg: _progressGradientStops, bg: null),
        ),
      ),
      Text(
        'Host note: Files save to the termui_cast host filesystem.',
        style: chrome.hintStyle,
        wrap: false,
      ),
      Text(
        'Esc / n: cancel active upload',
        style: chrome.hintStyle,
        wrap: false,
      ),
    ];
  }

  Widget _buildActionRow(BuildContext context, WorkspaceChromeTheme chrome) {
    if (_uploading) {
      return Button(
        text: 'Cancel (Esc)',
        focused: false,
        onPressed: () => _cancelOrDismiss(context),
        style: chrome.focusedButtonStyle,
        focusedStyle: chrome.focusedButtonStyle,
      );
    }
    if (_validFiles.isEmpty) {
      return Button(
        text: 'Close (Enter)',
        focused: true,
        onPressed: () => _cancelOrDismiss(context),
        style: chrome.buttonStyle,
        focusedStyle: chrome.focusedButtonStyle,
      );
    }
    return Row([
      Button(
        text: 'Upload (Enter / y)',
        focused: true,
        onPressed: () => unawaited(_confirmAndStartUpload(context)),
        style: chrome.buttonStyle,
        focusedStyle: chrome.focusedButtonStyle,
      ),
      const SizedBox(width: 2),
      Button(
        text: 'Cancel (Esc / n)',
        onPressed: () => _cancelOrDismiss(context),
        style: chrome.buttonStyle,
        focusedStyle: chrome.focusedButtonStyle,
      ),
    ]);
  }

  /// Formats [bytes] into a compact human-readable string (`B`, `KB`, `MB`).
  static String formatByteCount(int bytes) => formatDialogByteCount(bytes);
}
