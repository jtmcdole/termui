import 'package:flutter/widgets.dart' show Characters;

import '../about/about_models.dart';
import 'diagnostic_log.dart';

/// GitHub repository new-issue endpoint for `termui` / `fterm`.
const String kFtermNewIssueUrl = '$kFtermRepoUrl/issues/new';

/// Default conservative URL length cap compatible with Windows
/// `rundll32 url.dll,FileProtocolHandler`, macOS `open`, Linux `xdg-open`,
/// and web browsers.
const int kMaxGitHubIssueUrlLength = 1900;

const int _maxIssueTitleGraphemes = 120;

final Uri _newIssueBaseUri = Uri.parse(kFtermNewIssueUrl);

/// User-selected category for a GitHub feedback / issue report.
enum FeedbackCategory {
  /// Defect report pre-tagged with the `bug` label.
  bug(
    label: 'Bug Report',
    githubLabel: 'bug',
    detailsHeading: 'What happened',
    detailsHint: 'Describe what went wrong and how to reproduce it...',
  ),

  /// Feature or UX suggestion pre-tagged with the `enhancement` label.
  feature(
    label: 'Feature / Idea',
    githubLabel: 'enhancement',
    detailsHeading: 'Idea',
    detailsHint: 'Describe the improvement or workflow you want...',
  ),

  /// Open-ended feedback without a forced label.
  general(
    label: 'General',
    githubLabel: null,
    detailsHeading: 'Feedback',
    detailsHint: 'Share any notes, friction points, or suggestions...',
  );

  /// Display chip label shown in the Feedback overlay.
  final String label;

  /// Optional GitHub issue label query value (`bug`, `enhancement`, or `null`).
  final String? githubLabel;

  /// Markdown section heading placed above user-entered details.
  final String detailsHeading;

  /// Hint text displayed in the details field.
  final String detailsHint;

  const FeedbackCategory({
    required this.label,
    required this.githubLabel,
    required this.detailsHeading,
    required this.detailsHint,
  });
}

/// Minimal, zero-PII environment metadata included in every report.
final class FtermEnvironmentInfo {
  /// Build version, optional build date, and Flutter/Dart SDK info.
  final FtermBuildMetadata metadata;

  /// Compact client OS + version label (for example `macOS 15.4` or `Web`).
  final String platformLabel;

  /// Creates an [FtermEnvironmentInfo].
  const FtermEnvironmentInfo({
    required this.metadata,
    required this.platformLabel,
  });

  /// Single-line badge summarizing what is pre-populated in the issue body.
  String get compactSummary {
    final parts = <String>[
      'fterm ${metadata.displayVersion}',
      platformLabel,
      ?metadata.runtimeToolchainLabel,
    ];
    return parts.join(' · ');
  }
}

/// Opt-in, allowlisted workspace summary formatted inside a collapsible
/// `<details>` block (never includes URLs, hostnames, tokens, paths, or
/// terminal buffer text).
final class FtermWorkspaceDiagnosticSummary {
  /// Open tab count.
  final int tabCount;

  /// Pane count in the active tab.
  final int paneCount;

  /// Focused pane mode (`local shell`, `remote session (via relay)`, or `none`).
  final String focusedPaneKind;

  /// Whether any pane in this workspace is using or sharing through a relay.
  final bool usesRelay;

  /// Focused pane PTY grid size (`cols x rows`), if a pane is active.
  final String? activePtySize;

  /// Active terminal color theme identifier.
  final String themeId;

  /// Active appearance mode (`system`, `dark`, `light`).
  final String appearanceMode;

  /// Effective terminal font size in logical points.
  final double fontSize;

  /// Active tab bar dock position (`top`, `left`, `hidden`).
  final String dockPosition;

  /// Relay client connection state name (`unconnected`, `authenticated`, etc.).
  final String connectionState;

  /// Whether the audio engine has been initialized.
  final bool audioInitialized;

  /// Whether running in Web/Wasm mode.
  final bool isWeb;

  /// Optional desktop updater status name.
  final String? updateStatus;

  /// Creates an immutable [FtermWorkspaceDiagnosticSummary].
  const FtermWorkspaceDiagnosticSummary({
    required this.tabCount,
    required this.paneCount,
    required this.focusedPaneKind,
    required this.usesRelay,
    required this.activePtySize,
    required this.themeId,
    required this.appearanceMode,
    required this.fontSize,
    required this.dockPosition,
    required this.connectionState,
    required this.audioInitialized,
    required this.isWeb,
    this.updateStatus,
  });

  /// Formats the summary as a compact, leak-free Markdown bullet list.
  String toMarkdown() {
    final sizeLabel = fontSize == fontSize.roundToDouble()
        ? '${fontSize.toInt()}pt'
        : '${fontSize.toStringAsFixed(1)}pt';
    final relaySummary = usesRelay
        ? 'via relay ($connectionState)'
        : 'local only ($connectionState)';
    final lines = <String>[
      '- Session: $focusedPaneKind'
          '${activePtySize != null ? ' ($activePtySize)' : ''}',
      '- Connection: $relaySummary',
      '- Tabs / Panes: $tabCount / $paneCount',
      '- Theme / Font: $themeId ($appearanceMode) · $sizeLabel · dock $dockPosition',
      '- Audio: ${audioInitialized ? 'initialized' : 'standby'}'
          '${!isWeb && updateStatus != null ? ' · Updater: $updateStatus' : ''}',
    ];
    return lines.join('\n');
  }
}

/// User-authored inputs and opt-in diagnostic selections for a feedback report.
final class FeedbackDraft {
  /// Selected issue category.
  final FeedbackCategory category;

  /// Optional short issue title.
  final String title;

  /// Optional free-form issue description.
  final String details;

  /// Whether to attach [FtermWorkspaceDiagnosticSummary] in `<details>`.
  final bool includeWorkspaceState;

  /// Whether to attach recent allowlisted [DiagnosticLogEntry] event codes in `<details>`.
  final bool includeDiagnosticLogs;

  /// Optional basename of a screenshot saved during this feedback flow.
  final String? savedScreenshotName;

  /// Creates an immutable [FeedbackDraft].
  const FeedbackDraft({
    this.category = FeedbackCategory.bug,
    this.title = '',
    this.details = '',
    this.includeWorkspaceState = false,
    this.includeDiagnosticLogs = false,
    this.savedScreenshotName,
  });
}

/// Generated GitHub new-issue URL plus full Markdown body and truncation flag.
final class GitHubIssuePayload {
  /// Pre-filled `https://github.com/jtmcdole/termui/issues/new?...` URI.
  final Uri uri;

  /// Complete Markdown report body (untruncated, ready for clipboard copy).
  final String fullMarkdown;

  /// Whether the `body` query parameter had to be shortened to stay within
  /// cross-platform URL length limits.
  final bool bodyTruncated;

  /// Creates a [GitHubIssuePayload].
  const GitHubIssuePayload({
    required this.uri,
    required this.fullMarkdown,
    required this.bodyTruncated,
  });
}

/// Builds the full Markdown body for a GitHub issue from [draft] and opt-in context.
String buildFeedbackMarkdown({
  required FeedbackDraft draft,
  required FtermEnvironmentInfo environment,
  FtermWorkspaceDiagnosticSummary? workspaceState,
  List<DiagnosticLogEntry> diagnosticLogs = const [],
}) {
  final sb = StringBuffer()..writeln('### ${draft.category.detailsHeading}');
  final trimmedDetails = draft.details.trim();
  sb.writeln(
    trimmedDetails.isNotEmpty ? trimmedDetails : '<!-- Add details here -->',
  );
  if (draft.savedScreenshotName case final shot? when shot.trim().isNotEmpty) {
    sb
      ..writeln()
      ..writeln('### Screenshot')
      ..writeln('<!-- Drag and drop `$shot` here to attach -->');
  }
  _writeEnvironmentSection(sb, environment);
  _writeDiagnosticsSection(
    sb,
    workspaceState: draft.includeWorkspaceState ? workspaceState : null,
    diagnosticLogs: draft.includeDiagnosticLogs ? diagnosticLogs : const [],
  );
  return '$sb'.trimRight();
}

void _writeEnvironmentSection(
  StringBuffer sb,
  FtermEnvironmentInfo environment,
) {
  sb
    ..writeln()
    ..writeln('### Environment')
    ..writeln('- App: fterm ${environment.metadata.displayVersion}')
    ..writeln('- Client: ${environment.platformLabel}');
  if (environment.metadata.formattedBuildDate case final built?) {
    sb.writeln('- Built: $built');
  }
  if (environment.metadata.runtimeToolchainLabel case final sdk?) {
    sb.writeln('- SDK: $sdk');
  }
}

void _writeDiagnosticsSection(
  StringBuffer sb, {
  required FtermWorkspaceDiagnosticSummary? workspaceState,
  required List<DiagnosticLogEntry> diagnosticLogs,
}) {
  if (workspaceState == null && diagnosticLogs.isEmpty) return;
  sb
    ..writeln()
    ..writeln('<details>')
    ..writeln('<summary>Diagnostics (opt-in)</summary>')
    ..writeln();
  if (workspaceState != null) {
    sb.writeln(workspaceState.toMarkdown());
  }
  if (diagnosticLogs.isNotEmpty) {
    if (workspaceState != null) sb.writeln();
    sb
      ..writeln('```text')
      ..writeln([for (final e in diagnosticLogs) e.formatLine()].join('\n'))
      ..writeln('```');
  }
  sb.writeln('</details>');
}

/// Builds the pre-filled GitHub issue [Uri] while respecting [maxUrlLength].
GitHubIssuePayload buildGitHubIssuePayload({
  required FeedbackDraft draft,
  required FtermEnvironmentInfo environment,
  FtermWorkspaceDiagnosticSummary? workspaceState,
  List<DiagnosticLogEntry> diagnosticLogs = const [],
  int maxUrlLength = kMaxGitHubIssueUrlLength,
}) {
  final fullMarkdown = buildFeedbackMarkdown(
    draft: draft,
    environment: environment,
    workspaceState: workspaceState,
    diagnosticLogs: diagnosticLogs,
  );
  final maxTitleUrlChars = (maxUrlLength ~/ 3).clamp(32, 240);
  final issueTitle = _fitTitleToUrlBudget(
    draft.title.trim(),
    maxEncodedLength: maxTitleUrlChars,
  );

  Uri buildUri(String bodyText) => _newIssueBaseUri.replace(
    queryParameters: <String, String>{
      'title': issueTitle,
      'labels': ?draft.category.githubLabel,
      'body': bodyText,
    },
  );

  final fullUri = buildUri(fullMarkdown);
  if ('$fullUri'.length <= maxUrlLength) {
    return GitHubIssuePayload(
      uri: fullUri,
      fullMarkdown: fullMarkdown,
      bodyTruncated: false,
    );
  }

  const notice =
      '\n\n_(Full diagnostics copied to clipboard — paste here if needed.)_';
  final withoutDiagnostics = buildFeedbackMarkdown(
    draft: draft,
    environment: environment,
  );
  final baseForTrim = withoutDiagnostics.length < fullMarkdown.length
      ? withoutDiagnostics
      : fullMarkdown;
  final truncatedBody = _fitBodyToUrlBudget(
    markdown: baseForTrim,
    notice: notice,
    buildUri: buildUri,
    maxUrlLength: maxUrlLength,
  );
  return GitHubIssuePayload(
    uri: buildUri(truncatedBody),
    fullMarkdown: fullMarkdown,
    bodyTruncated: true,
  );
}

String _fitTitleToUrlBudget(String trimmed, {required int maxEncodedLength}) {
  if (trimmed.isEmpty) return '[fterm] ';
  final graphemes = [...Characters(trimmed).take(_maxIssueTitleGraphemes)];
  var low = 0;
  var high = graphemes.length;
  var best = 0;
  while (low <= high) {
    final mid = (low + high) ~/ 2;
    final candidate = mid == 0
        ? '[fterm] '
        : '[fterm] ${graphemes.sublist(0, mid).join()}';
    if (Uri.encodeQueryComponent(candidate).length <= maxEncodedLength) {
      best = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return best == 0
      ? '[fterm] '
      : '[fterm] ${graphemes.sublist(0, best).join()}';
}

String _fitBodyToUrlBudget({
  required String markdown,
  required String notice,
  required Uri Function(String body) buildUri,
  required int maxUrlLength,
}) {
  if ('${buildUri(notice.trim())}'.length > maxUrlLength) {
    return '';
  }
  final graphemes = [...Characters(markdown)];
  var low = 0;
  var high = graphemes.length;
  var best = 0;
  while (low <= high) {
    final mid = (low + high) ~/ 2;
    final prefix = graphemes.sublist(0, mid).join().trimRight();
    final candidate = prefix.isEmpty ? notice.trim() : '$prefix$notice';
    if ('${buildUri(candidate)}'.length <= maxUrlLength) {
      best = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  final prefix = graphemes.sublist(0, best).join().trimRight();
  return prefix.isEmpty ? notice.trim() : '$prefix$notice';
}
