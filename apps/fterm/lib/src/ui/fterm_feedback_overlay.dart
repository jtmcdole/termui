import 'dart:async';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../feedback/feedback_models.dart';
import '../feedback/feedback_platform.dart';
import '../file_drop_bridge.dart';
import '../font_loader.dart';
import '../workspace/fterm_workspace_controller.dart';
import 'fterm_overlays.dart';

/// Guided GitHub issue & feedback modal pre-populating version and platform
/// metadata with opt-in workspace state, sanitized logs, and pane screenshots.
final class FtermFeedbackOverlay extends StatefulWidget {
  /// Backing workspace coordinator.
  final FtermWorkspaceController workspace;

  /// Resolved overlay colors derived from the active terminal theme.
  final FtermOverlayPalette palette;

  /// External URL launcher opening the pre-filled GitHub new-issue page.
  final UrlOpener onOpenUrl;

  /// Whether running in Web/Wasm mode.
  final bool isWeb;

  /// Optional callback capturing the active terminal pane as a PNG file.
  final Future<String?> Function()? onCaptureScreenshot;

  /// Optional clipboard writer override (defaults to `Clipboard.setData`).
  final Future<void> Function(String text)? onCopyToClipboard;

  /// Optional platform label override for deterministic widget tests.
  final String Function()? platformLabelResolver;

  /// Creates the [FtermFeedbackOverlay].
  const FtermFeedbackOverlay({
    super.key,
    required this.workspace,
    required this.palette,
    required this.onOpenUrl,
    required this.isWeb,
    this.onCaptureScreenshot,
    this.onCopyToClipboard,
    this.platformLabelResolver,
  });

  @override
  State<FtermFeedbackOverlay> createState() => _FtermFeedbackOverlayState();
}

final class _FtermFeedbackOverlayState extends State<FtermFeedbackOverlay> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _detailsCtrl;
  late final String _platformLabel;
  late Listenable _mergedListenable;

  FeedbackCategory _category = FeedbackCategory.bug;
  bool _includeWorkspaceState = false;
  bool _includeDiagnosticLogs = false;
  bool _showPreview = false;
  bool _capturingScreenshot = false;
  String? _savedScreenshotName;
  String? _feedbackNotice;
  bool _noticeIsError = false;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController();
    _detailsCtrl = TextEditingController();
    _platformLabel =
        (widget.platformLabelResolver ?? resolveFeedbackPlatformLabel)();
    _mergedListenable = _buildMergedListenable(widget.workspace);
  }

  @override
  void didUpdateWidget(FtermFeedbackOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.workspace, widget.workspace)) {
      _mergedListenable = _buildMergedListenable(widget.workspace);
    }
  }

  static Listenable _buildMergedListenable(FtermWorkspaceController ws) =>
      Listenable.merge([ws.aboutViewModel, ws.diagnosticLog]);

  @override
  void dispose() {
    _titleCtrl.dispose();
    _detailsCtrl.dispose();
    super.dispose();
  }

  FtermEnvironmentInfo _buildEnvironment() => FtermEnvironmentInfo(
    metadata: widget.workspace.aboutViewModel.metadata,
    platformLabel: _platformLabel,
  );

  FeedbackDraft _buildDraft() => FeedbackDraft(
    category: _category,
    title: _titleCtrl.text,
    details: _detailsCtrl.text,
    includeWorkspaceState: _includeWorkspaceState,
    includeDiagnosticLogs: _includeDiagnosticLogs,
    savedScreenshotName: _savedScreenshotName,
  );

  GitHubIssuePayload _buildPayload() => buildGitHubIssuePayload(
    draft: _buildDraft(),
    environment: _buildEnvironment(),
    workspaceState: _includeWorkspaceState
        ? widget.workspace.buildDiagnosticSummary(isWeb: widget.isWeb)
        : null,
    diagnosticLogs: _includeDiagnosticLogs
        ? widget.workspace.diagnosticLog.entries
        : const [],
  );

  Future<void> _copyText(String text) async {
    final copyFn = widget.onCopyToClipboard;
    if (copyFn != null) {
      await copyFn(text);
    } else {
      await Clipboard.setData(ClipboardData(text: text));
    }
  }

  Future<void> _handleCaptureScreenshot() async {
    final capture = widget.onCaptureScreenshot;
    if (capture == null || _capturingScreenshot) return;
    setState(() {
      _capturingScreenshot = true;
      _feedbackNotice = null;
      _noticeIsError = false;
    });
    try {
      final saved = await capture();
      if (!mounted) return;
      if (saved == null || saved.trim().isEmpty) {
        setState(() {
          _feedbackNotice = 'Unable to capture screenshot of the active pane.';
          _noticeIsError = true;
        });
        return;
      }
      final trimmedPath = saved.trim();
      final name = _extractScreenshotBasename(trimmedPath);
      setState(() {
        _savedScreenshotName = name;
        _feedbackNotice =
            'Saved to $trimmedPath — review before dragging onto the GitHub issue.';
        _noticeIsError = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _feedbackNotice = 'Unable to capture screenshot of the active pane.';
        _noticeIsError = true;
      });
    } finally {
      if (mounted) {
        setState(() => _capturingScreenshot = false);
      }
    }
  }

  static String _extractScreenshotBasename(String savedPath) {
    final normalized = savedPath.trim();
    final ctx = normalized.contains('\\') ? p.windows : p.context;
    return ctx.basename(normalized);
  }

  Future<void> _handleCopyReport() async {
    final payload = _buildPayload();
    try {
      await _copyText(payload.fullMarkdown);
      if (!mounted) return;
      setState(() {
        _feedbackNotice = 'Copied issue report markdown to clipboard.';
        _noticeIsError = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _feedbackNotice = 'Unable to copy report to clipboard.';
        _noticeIsError = true;
      });
    }
  }

  Future<void> _handleOpenOnGitHub() async {
    final payload = _buildPayload();
    var copied = false;
    if (payload.bodyTruncated) {
      try {
        await _copyText(payload.fullMarkdown);
        copied = true;
      } on Object {
        copied = false;
      }
    }
    widget.onOpenUrl(payload.uri);
    if (!mounted) return;
    setState(() {
      if (payload.bodyTruncated && !copied) {
        _feedbackNotice =
            'Opened GitHub issue, but clipboard copy failed — click Copy Report.';
        _noticeIsError = true;
      } else {
        _feedbackNotice = payload.bodyTruncated
            ? 'Opened GitHub issue — full diagnostics copied to clipboard.'
            : 'Opened pre-filled GitHub issue in your browser.';
        _noticeIsError = false;
      }
    });
  }

  void _onFieldChanged(String _) {
    if (_showPreview) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return ListenableBuilder(
      listenable: _mergedListenable,
      builder: (_, _) {
        final env = _buildEnvironment();
        final logCount = widget.workspace.diagnosticLog.length;
        final canScreenshot =
            widget.onCaptureScreenshot != null &&
            widget.workspace.focusedPane != null;

        return Padding(
          padding: const EdgeInsets.all(16),
          child: FocusTraversalGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                buildFtermOverlayHeader(
                  title: 'Send Feedback & Report Issue',
                  palette: p,
                  onClose: widget.workspace.dismissOverlay,
                ),
                const SizedBox(height: 6),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Opens a pre-filled GitHub issue in your browser. '
                          'Nothing is sent automatically; relay URLs, tokens, '
                          'and terminal contents are never included unless '
                          'you attach a screenshot.',
                          style: TextStyle(color: p.muted, fontSize: 11),
                        ),
                        const SizedBox(height: 10),
                        _EnvironmentSummaryChip(
                          summary: env.compactSummary,
                          palette: p,
                        ),
                        const SizedBox(height: 10),
                        _FeedbackCategorySelector(
                          selected: _category,
                          onSelected: (c) => setState(() => _category = c),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          key: const ValueKey('feedback-title-field'),
                          controller: _titleCtrl,
                          decoration: _inputDeco(
                            label: 'Short summary (optional)',
                            hint: 'Brief title for the GitHub issue',
                            palette: p,
                          ),
                          onChanged: _onFieldChanged,
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          key: const ValueKey('feedback-details-field'),
                          controller: _detailsCtrl,
                          minLines: 3,
                          maxLines: 5,
                          decoration: _inputDeco(
                            label: '${_category.detailsHeading} (optional)',
                            hint: _category.detailsHint,
                            palette: p,
                          ),
                          onChanged: _onFieldChanged,
                        ),
                        const SizedBox(height: 6),
                        _FeedbackDiagnosticToggles(
                          palette: p,
                          includeWorkspaceState: _includeWorkspaceState,
                          includeDiagnosticLogs: _includeDiagnosticLogs,
                          logCount: logCount,
                          onWorkspaceStateChanged: (v) =>
                              setState(() => _includeWorkspaceState = v),
                          onDiagnosticLogsChanged: (v) =>
                              setState(() => _includeDiagnosticLogs = v),
                        ),
                        _FeedbackPreviewSection(
                          palette: p,
                          expanded: _showPreview,
                          markdown: _showPreview
                              ? _buildPayload().fullMarkdown
                              : null,
                          onToggle: () =>
                              setState(() => _showPreview = !_showPreview),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_feedbackNotice case final notice?) ...[
                  const SizedBox(height: 8),
                  _FeedbackNoticeBanner(
                    notice: notice,
                    isError: _noticeIsError,
                    palette: p,
                  ),
                ],
                const SizedBox(height: 10),
                _FeedbackActionBar(
                  canScreenshot: canScreenshot,
                  capturingScreenshot: _capturingScreenshot,
                  onCaptureScreenshot: () =>
                      unawaited(_handleCaptureScreenshot()),
                  onCopyReport: () => unawaited(_handleCopyReport()),
                  onOpenGitHub: () => unawaited(_handleOpenOnGitHub()),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static InputDecoration _inputDeco({
    required String label,
    required String hint,
    required FtermOverlayPalette palette,
  }) => InputDecoration(
    labelText: label,
    hintText: hint,
    labelStyle: TextStyle(color: palette.muted, fontSize: 11),
    hintStyle: TextStyle(
      color: palette.muted.withValues(alpha: 0.7),
      fontSize: 11,
    ),
    isDense: true,
    border: OutlineInputBorder(borderSide: BorderSide(color: palette.border)),
    enabledBorder: OutlineInputBorder(
      borderSide: BorderSide(color: palette.border),
    ),
  );
}

final class _FeedbackCategorySelector extends StatelessWidget {
  final FeedbackCategory selected;
  final ValueChanged<FeedbackCategory> onSelected;

  const _FeedbackCategorySelector({
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final category in FeedbackCategory.values)
          ChoiceChip(
            key: ValueKey('feedback-category-${category.name}'),
            label: Text(category.label),
            selected: selected == category,
            onSelected: (_) => onSelected(category),
          ),
      ],
    );
  }
}

final class _FeedbackDiagnosticToggles extends StatelessWidget {
  final FtermOverlayPalette palette;
  final bool includeWorkspaceState;
  final bool includeDiagnosticLogs;
  final int logCount;
  final ValueChanged<bool> onWorkspaceStateChanged;
  final ValueChanged<bool> onDiagnosticLogsChanged;

  const _FeedbackDiagnosticToggles({
    required this.palette,
    required this.includeWorkspaceState,
    required this.includeDiagnosticLogs,
    required this.logCount,
    required this.onWorkspaceStateChanged,
    required this.onDiagnosticLogsChanged,
  });

  @override
  Widget build(BuildContext context) {
    final hasLogs = logCount > 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CheckboxListTile(
          key: const ValueKey('feedback-include-state'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text(
            'Include workspace state (tabs, layout, theme, PTY size)',
            style: TextStyle(fontSize: 11.5),
          ),
          value: includeWorkspaceState,
          onChanged: (v) => onWorkspaceStateChanged(v ?? false),
        ),
        CheckboxListTile(
          key: const ValueKey('feedback-include-logs'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(
            hasLogs
                ? 'Include recent event codes ($logCount, no text/URLs)'
                : 'Include recent event codes (none recorded)',
            style: TextStyle(
              fontSize: 11.5,
              color: hasLogs ? palette.foreground : palette.muted,
            ),
          ),
          value: hasLogs && includeDiagnosticLogs,
          onChanged: hasLogs
              ? (v) => onDiagnosticLogsChanged(v ?? false)
              : null,
        ),
      ],
    );
  }
}

final class _FeedbackPreviewSection extends StatelessWidget {
  final FtermOverlayPalette palette;
  final bool expanded;
  final String? markdown;
  final VoidCallback onToggle;

  const _FeedbackPreviewSection({
    required this.palette,
    required this.expanded,
    required this.markdown,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('feedback-toggle-preview'),
            onPressed: onToggle,
            icon: Icon(
              expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
              size: 15,
            ),
            label: Text(
              expanded ? 'Hide issue preview' : 'Preview issue body',
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ),
        if (expanded && markdown != null) ...[
          Container(
            key: const ValueKey('feedback-preview-box'),
            constraints: const BoxConstraints(maxHeight: 140),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: palette.surfaceAlt,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: palette.border),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                markdown!,
                style: TextStyle(
                  color: palette.foreground,
                  fontFamily: castPrimaryFontFamily,
                  fontSize: 10.5,
                  height: 1.35,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

final class _FeedbackNoticeBanner extends StatelessWidget {
  final String notice;
  final bool isError;
  final FtermOverlayPalette palette;

  const _FeedbackNoticeBanner({
    required this.notice,
    required this.isError,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    final tint = isError ? palette.danger : palette.accent;
    return Container(
      key: const ValueKey('feedback-status-notice'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: tint.withValues(alpha: 0.35)),
      ),
      child: Text(
        notice,
        style: TextStyle(
          color: isError ? palette.danger : palette.foreground,
          fontSize: 11,
        ),
      ),
    );
  }
}

final class _FeedbackActionBar extends StatelessWidget {
  final bool canScreenshot;
  final bool capturingScreenshot;
  final VoidCallback onCaptureScreenshot;
  final VoidCallback onCopyReport;
  final VoidCallback onOpenGitHub;

  const _FeedbackActionBar({
    required this.canScreenshot,
    required this.capturingScreenshot,
    required this.onCaptureScreenshot,
    required this.onCopyReport,
    required this.onOpenGitHub,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 8,
      children: [
        if (canScreenshot)
          OutlinedButton.icon(
            key: const ValueKey('feedback-save-screenshot'),
            onPressed: capturingScreenshot ? null : onCaptureScreenshot,
            icon: const Icon(Icons.camera_alt_outlined, size: 14),
            label: Text(capturingScreenshot ? 'Saving...' : 'Save Screenshot'),
          ),
        OutlinedButton.icon(
          key: const ValueKey('feedback-copy-report'),
          onPressed: onCopyReport,
          icon: const Icon(Icons.copy_outlined, size: 14),
          label: const Text('Copy Report'),
        ),
        FilledButton.icon(
          key: const ValueKey('feedback-open-github'),
          onPressed: onOpenGitHub,
          icon: const Icon(Icons.open_in_new, size: 14),
          label: const Text('Open GitHub Issue'),
        ),
      ],
    );
  }
}

final class _EnvironmentSummaryChip extends StatelessWidget {
  final String summary;
  final FtermOverlayPalette palette;

  const _EnvironmentSummaryChip({required this.summary, required this.palette});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('feedback-env-summary'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: palette.surfaceAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        children: [
          Icon(Icons.verified_outlined, size: 13, color: palette.accent),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              summary,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.foreground, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}
