import 'dart:async';
import 'dart:typed_data';

import 'package:stream_channel/stream_channel.dart';
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_pty/termui_pty.dart';

/// Signature for opening a binary caster transport channel (test/custom seam).
typedef CasterTransportOpener = Future<StreamChannel<Uint8List>> Function();

/// Configuration for spawning a local interactive shell via [LocalHostDriver].
final class LocalShellConfig {
  /// Optional explicit shell executable path/name (defaults to user shell).
  final String? executable;

  /// Optional arguments forwarded to [executable].
  final List<String> arguments;

  /// Optional login-shell override (`-l` on POSIX): `null` preserves the driver
  /// default (`true` when [executable] is `null`, `false` otherwise).
  final bool? loginShell;

  /// Optional starting working directory.
  final String? workingDirectory;

  /// Initial PTY column count.
  final int initialCols;

  /// Initial PTY row count.
  final int initialRows;

  /// Cell width in pixels for `TIOCSWINSZ` pixel geometry.
  final int cellPixelWidth;

  /// Cell height in pixels for `TIOCSWINSZ` pixel geometry.
  final int cellPixelHeight;

  /// Initial terminal color scheme polarity answered to `CSI ? 996 n` queries.
  final tui.TerminalBrightness colorScheme;

  /// Maximum primary scrollback lines retained in the local [PtyRouter].
  final int maxScrollbackLines;

  /// Whether Kitty Graphics Protocol local temp-file transfers (`APC t=t`) are
  /// permitted on the spawned local shell.
  final bool allowLocalKittyMedia;

  /// Whether Kitty Graphics Protocol POSIX shared-memory transfers (`APC t=s`)
  /// are permitted on the spawned local shell.
  final bool allowLocalKittyShm;

  /// Creates a local shell spawn configuration.
  const LocalShellConfig({
    this.executable,
    this.arguments = const [],
    this.loginShell,
    this.workingDirectory,
    this.initialCols = 80,
    this.initialRows = 24,
    this.cellPixelWidth = 8,
    this.cellPixelHeight = 16,
    this.colorScheme = .dark,
    this.maxScrollbackLines = 5000,
    this.allowLocalKittyMedia = true,
    this.allowLocalKittyShm = true,
  });
}

/// Lifecycle states of a local pane's optional relay share.
enum LocalShareState {
  /// Local pane is private and not broadcasting to a relay.
  unshared,

  /// Dialing relay WebSocket and authenticating session registration.
  connecting,

  /// Actively streaming live frames to the relay server.
  live,

  /// Share registration or connection failed.
  error,
}

/// Immutable status snapshot of a local pane's optional relay broadcast.
final class LocalShareSnapshot {
  /// Default idle snapshot when a local pane is unshared.
  static const LocalShareSnapshot unshared = LocalShareSnapshot();

  /// Current sharing connection state.
  final LocalShareState state;

  /// Relay session ID assigned when sharing is active or connecting.
  final SessionId? sessionId;

  /// Current remote subscriber count reported by the relay.
  final int subscriberCount;

  /// Non-empty diagnostic message when [state] is [LocalShareState.error].
  final String? errorMessage;

  /// Creates an immutable [LocalShareSnapshot].
  const LocalShareSnapshot({
    this.state = LocalShareState.unshared,
    this.sessionId,
    this.subscriberCount = 0,
    this.errorMessage,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocalShareSnapshot &&
          other.state == state &&
          other.sessionId == sessionId &&
          other.subscriberCount == subscriberCount &&
          other.errorMessage == errorMessage;

  @override
  int get hashCode =>
      Object.hash(state, sessionId, subscriberCount, errorMessage);
}

/// Live local shell pane owned by `fterm` on desktop hosts.
abstract interface class LocalPaneHost {
  /// Unique local host pane identifier.
  String get id;

  /// Primary interactive [TerminalPort] attached to this local shell.
  TerminalPort get port;

  /// Completes with the shell process exit code once terminated.
  Future<int> get exitCode;

  /// Current relay broadcast status snapshot.
  LocalShareSnapshot get shareSnapshot;

  /// Broadcast stream of [shareSnapshot] transitions.
  Stream<LocalShareSnapshot> get shareUpdates;

  /// Starts sharing this local shell pane to [serverUri] using [casterToken].
  ///
  /// The returned [SessionId] is registered cleanly even if the relay handshake
  /// settles asynchronously, allowing self-cast filtering immediately.
  Future<SessionId> startShare({
    required Uri serverUri,
    required String casterToken,
    required String title,
    String? uploadDirPath,
    IapTokenProvider? iapTokenProvider,
    CasterTransportOpener? channelOpener,
  });

  /// Stops sharing this local pane without killing the running local shell.
  Future<void> stopShare();

  /// Updates the color-scheme polarity answered to child terminal queries.
  void setColorScheme(tui.TerminalBrightness brightness);

  /// Whether primary-screen live row [row] soft-wrapped from the previous row.
  bool isLiveRowWrapped(int row);

  /// Stops any active share and closes this local shell pane cleanly.
  Future<void> dispose();
}

/// Opt-in [LocalPaneHost] capability exposing OSC 133;A shell prompt line
/// indices in primary scrollback.
abstract interface class PromptIndexedPaneHost implements LocalPaneHost {
  /// Monotonic line indices of OSC 133;A shell prompts in primary scrollback.
  List<int> get promptLines;
}

/// Opt-in [LocalPaneHost] capability allowing live runtime updates to Kitty
/// Graphics Protocol local transmission media (`t=t` temp files and `t=s`
/// POSIX shared memory).
abstract interface class KittyMediaConfigurablePaneHost
    implements LocalPaneHost {
  /// Updates whether local temp-file (`t=t`) and POSIX shared-memory (`t=s`)
  /// Kitty Graphics transfers are permitted on this local shell pane.
  void setKittyLocalMediaPolicy({
    required bool allowTempFiles,
    required bool allowSharedMemory,
  });
}

/// Platform seam spawning local interactive shells and optional relay shares.
abstract interface class LocalHostDriver {
  /// Whether this host supports spawning local native PTY shells (`true` on
  /// desktop outside isolated tests; `false` on Web).
  bool get isSupported;

  /// Spawns a local interactive shell pane.
  Future<LocalPaneHost> openShell(LocalShellConfig config);

  /// Disposes the driver and any remaining owned local shell panes.
  Future<void> dispose();
}
