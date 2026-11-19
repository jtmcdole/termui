import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier;

/// Allowlisted, zero-PII diagnostic event categories recorded during an
/// `fterm` session.
///
/// Using a closed enum rather than raw exception strings guarantees that relay
/// URLs, hostnames, bearer tokens, file paths, usernames, and terminal output
/// can never leak into user-submitted GitHub issue reports.
enum DiagnosticEventKind {
  /// Transport failed while dialing or upgrading a relay connection.
  relayConnectFailed('relay_connect_failed'),

  /// Relay transport disconnected unexpectedly.
  relayDisconnected('relay_disconnected'),

  /// Relay rejected client authentication.
  relayAuthFailed('relay_auth_failed'),

  /// Relay returned a non-fatal protocol error frame.
  relayProtocolError('relay_protocol_error'),

  /// Local pane relay broadcast failed to start or stay connected.
  localShareFailed('local_share_failed'),

  /// Drag-and-drop file upload encountered an error.
  fileUploadFailed('file_upload_failed'),

  /// Self-update check or download encountered an error.
  updateError('update_error');

  /// Stable machine-readable event code written into `<details>` diagnostics.
  final String code;

  const DiagnosticEventKind(this.code);
}

/// Immutable allowlisted diagnostic event recorded during an `fterm` session.
final class DiagnosticLogEntry {
  /// UTC timestamp when the diagnostic event occurred.
  final DateTime timestampUtc;

  /// Allowlisted event kind (never holds arbitrary strings, URLs, or paths).
  final DiagnosticEventKind kind;

  /// Creates a [DiagnosticLogEntry].
  const DiagnosticLogEntry({required this.timestampUtc, required this.kind});

  /// Formats this entry as a compact, leak-free UTC event line.
  String formatLine() {
    final dt = timestampUtc.toUtc();
    final hh = '${dt.hour}'.padLeft(2, '0');
    final mm = '${dt.minute}'.padLeft(2, '0');
    final ss = '${dt.second}'.padLeft(2, '0');
    return '[$hh:$mm:${ss}Z] ${kind.code}';
  }
}

/// Bounded in-memory ring buffer holding recent allowlisted diagnostic event
/// codes for optional user-approved inclusion in GitHub issue reports.
final class FtermDiagnosticLog extends ChangeNotifier {
  /// Default maximum number of retained entries.
  static const int defaultMaxEntries = 40;

  final int _maxEntries;
  final Clock _clock;
  final List<DiagnosticLogEntry> _entries = <DiagnosticLogEntry>[];

  /// Creates an [FtermDiagnosticLog] with optional capacity and [clock].
  FtermDiagnosticLog({int maxEntries = defaultMaxEntries, Clock? clock})
    : _maxEntries = maxEntries < 1 ? 1 : maxEntries,
      _clock = clock ?? const Clock();

  /// Read-only snapshot of recorded diagnostic entries in chronological order.
  List<DiagnosticLogEntry> get entries =>
      List<DiagnosticLogEntry>.unmodifiable(_entries);

  /// Number of recorded diagnostic entries currently buffered.
  int get length => _entries.length;

  /// Records an allowlisted diagnostic [kind].
  void record(DiagnosticEventKind kind) {
    if (_entries.length >= _maxEntries) {
      _entries.removeAt(0);
    }
    _entries.add(
      DiagnosticLogEntry(timestampUtc: _clock.now().toUtc(), kind: kind),
    );
    notifyListeners();
  }
}
