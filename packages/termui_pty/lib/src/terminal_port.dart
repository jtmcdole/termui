import 'dart:async';
import 'dart:typed_data';

import 'package:termui/termui.dart';

import 'audio_apc_handler.dart';
import 'scrollback_buffer.dart';
import 'virtual_terminal.dart';

/// Immutable metadata describing the retained primary-screen scrollback window.
typedef ScrollbackWindowData = ({int clearSeq, int oldestLine, int totalLines});

/// Immutable snapshot of terminal cursor coordinates, visibility, and visual shape.
final class CursorStateData {
  /// Zero-indexed cursor column coordinate.
  final int x;

  /// Zero-indexed cursor row coordinate.
  final int y;

  /// Whether the cursor is visible (`DECTCEM`).
  final bool visible;

  /// Active visual cursor shape selected via `DECSCUSR`.
  final TerminalCursorShape shape;

  /// Creates an immutable cursor state snapshot.
  const CursorStateData({
    required this.x,
    required this.y,
    this.visible = true,
    this.shape = TerminalCursorShape.defaultShape,
  });

  /// Default origin cursor at `(0, 0)` with visibility enabled.
  static const CursorStateData origin = CursorStateData(x: 0, y: 0);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CursorStateData &&
          other.x == x &&
          other.y == y &&
          other.visible == visible &&
          other.shape == shape;

  @override
  int get hashCode => Object.hash(x, y, visible, shape);
}

/// Immutable snapshot of active terminal screen and input reporting modes.
final class TerminalPortModes {
  /// Whether DECSET mouse tracking (`1000`, `1002`, `1003`, or `9`) is enabled.
  final bool mouseTracking;

  /// Whether SGR extended mouse reporting (`DECSET 1006`) is enabled.
  final bool sgrMouse;

  /// Whether SGR-Pixels mouse reporting (`DECSET 1016`) is enabled.
  final bool sgrPixelsMouse;

  /// Whether bracketed paste mode (`DECSET 2004`) is enabled.
  final bool bracketedPaste;

  /// Whether the alternate screen buffer (`?47`, `?1047`, or `?1049`) is active.
  final bool altScreen;

  /// Whether application cursor keys (`DECCKM`, `?1h`) are active.
  final bool appCursorKeys;

  /// Whether alternate scroll mode (`DECSET 1007`) is enabled.
  final bool alternateScroll;

  /// Whether focus in/out reporting (`DECSET 1004`) is enabled.
  final bool focusReporting;

  /// Active Kitty keyboard protocol progressive enhancement flags (`CSI > flags u`).
  final int kittyKeyboardFlags;

  /// Creates an immutable terminal modes snapshot.
  const TerminalPortModes({
    this.mouseTracking = false,
    this.sgrMouse = false,
    this.sgrPixelsMouse = false,
    this.bracketedPaste = false,
    this.altScreen = false,
    this.appCursorKeys = false,
    this.alternateScroll = true,
    this.focusReporting = false,
    this.kittyKeyboardFlags = 0,
  });

  /// Default inactive terminal modes.
  static const TerminalPortModes defaults = TerminalPortModes();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalPortModes &&
          other.mouseTracking == mouseTracking &&
          other.sgrMouse == sgrMouse &&
          other.sgrPixelsMouse == sgrPixelsMouse &&
          other.bracketedPaste == bracketedPaste &&
          other.altScreen == altScreen &&
          other.appCursorKeys == appCursorKeys &&
          other.alternateScroll == alternateScroll &&
          other.focusReporting == focusReporting &&
          other.kittyKeyboardFlags == kittyKeyboardFlags;

  @override
  int get hashCode => Object.hash(
    mouseTracking,
    sgrMouse,
    sgrPixelsMouse,
    bracketedPaste,
    altScreen,
    appCursorKeys,
    alternateScroll,
    focusReporting,
    kittyKeyboardFlags,
  );
}

/// Pure-Dart in-process byte pipe pairing a [Stream<Uint8List>] and [StreamSink<Uint8List>].
final class RouterBytePipe {
  final Stream<Uint8List> _stream;
  final StreamSink<Uint8List> _sink;
  final Future<void> Function()? _onClose;
  bool _closed = false;

  /// Inbound byte stream delivered to this pipe endpoint.
  Stream<Uint8List> get stream => _stream;

  /// Outbound byte sink written by this pipe endpoint.
  StreamSink<Uint8List> get sink => _sink;

  /// Whether [close] has been invoked on this pipe endpoint.
  bool get isClosed => _closed;

  /// Creates a unidirectional [RouterBytePipe] where writes to [sink] arrive on [stream].
  factory RouterBytePipe({bool sync = false, bool broadcast = false}) {
    final controller = broadcast
        ? StreamController<Uint8List>.broadcast(sync: sync)
        : StreamController<Uint8List>(sync: sync);
    return RouterBytePipe._(
      stream: controller.stream,
      sink: controller.sink,
      onClose: () => _closeControllerSafely(controller),
    );
  }

  static Future<void> _closeControllerSafely(
    StreamController<Uint8List> controller,
  ) {
    if (controller.isClosed) return Future<void>.value();
    final future = controller.close();
    return (controller.hasListener && !controller.isPaused)
        ? future
        : Future<void>.value();
  }

  /// Wraps an existing [stream] and [sink] pair as a [RouterBytePipe].
  RouterBytePipe.fromStreamAndSink({
    required Stream<Uint8List> stream,
    required StreamSink<Uint8List> sink,
    Future<void> Function()? onClose,
  }) : _stream = stream,
       _sink = sink,
       _onClose = onClose;

  RouterBytePipe._({
    required Stream<Uint8List> stream,
    required StreamSink<Uint8List> sink,
    Future<void> Function()? onClose,
  }) : _stream = stream,
       _sink = sink,
       _onClose = onClose;

  /// Creates a cross-wired bidirectional pair `(local, remote)` of [RouterBytePipe]s.
  static (RouterBytePipe local, RouterBytePipe remote) duplex({
    bool sync = false,
  }) {
    final localToRemote = StreamController<Uint8List>(sync: sync);
    final remoteToLocal = StreamController<Uint8List>(sync: sync);
    final local = RouterBytePipe._(
      stream: remoteToLocal.stream,
      sink: localToRemote.sink,
      onClose: () => _closeControllerSafely(localToRemote),
    );
    final remote = RouterBytePipe._(
      stream: localToRemote.stream,
      sink: remoteToLocal.sink,
      onClose: () => _closeControllerSafely(remoteToLocal),
    );
    return (local, remote);
  }

  /// Idempotently closes the outbound [sink] of this pipe.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final closeHandler = _onClose;
    if (closeHandler != null) {
      await closeHandler();
    } else {
      await _sink.close();
    }
  }
}

/// Platform-agnostic terminal endpoint shared by local `PtyRouter` panes and
/// remote `RemoteTerminalPort` viewers.
abstract interface class TerminalPort {
  /// Unique identifier for this port instance.
  String get id;

  /// Active terminal screen buffer.
  Buffer get buffer;

  /// Current active grid width in columns.
  int get cols;

  /// Current active grid height in rows.
  int get rows;

  /// Active PTY grid dimensions; when clamped smaller than viewport, painters
  /// dim cells outside `(cols, rows)`.
  (int cols, int rows) get activePtySize;

  /// Current cursor coordinates, visibility, and visual shape.
  CursorStateData get cursor;

  /// Current terminal screen and input reporting modes.
  TerminalPortModes get modes;

  /// Current primary-screen scrollback window metadata.
  ScrollbackWindowData get scrollbackWindow;

  /// Current window title (`OSC 0` / `OSC 2` / `CSI 23 t`).
  String get windowTitle;

  /// Current working directory (`OSC 7`), or `null` if unset.
  String? get workingDirectory;

  /// Future completing with the underlying process exit code on termination.
  Future<int> get exitCode;

  /// Registers a visual buffer/state change listener.
  void addListener(void Function() listener);

  /// Unregisters a visual buffer/state change listener.
  void removeListener(void Function() listener);

  /// Registers a listener for window title changes (`OSC 0` / `OSC 2`).
  void addTitleListener(void Function(String title) listener);

  /// Unregisters a window title change listener.
  void removeTitleListener(void Function(String title) listener);

  /// Registers a listener for terminal bell (`BEL`, `0x07`) events.
  void addBellListener(void Function() listener);

  /// Unregisters a terminal bell listener.
  void removeBellListener(void Function() listener);

  /// Registers a listener for decoded `ESC _ A` audio events.
  void addAudioListener(void Function(TerminalAudioEvent event) listener);

  /// Unregisters an audio event listener.
  void removeAudioListener(void Function(TerminalAudioEvent event) listener);

  /// Registers a listener for `OSC 52` clipboard write events.
  void addClipboardListener(
    void Function(String selection, String text) listener,
  );

  /// Unregisters an `OSC 52` clipboard write listener.
  void removeClipboardListener(
    void Function(String selection, String text) listener,
  );

  /// Sends UTF-8 or VT escape sequence input bytes to the terminal session.
  void sendInput(Uint8List utf8Bytes);

  /// Reports this observer's desired grid dimensions and optional cell pixel size.
  void setViewportSize(
    int cols,
    int rows, {
    int cellPixelWidth = 0,
    int cellPixelHeight = 0,
  });

  /// Reads up to [count] primary-screen scrollback lines starting at [startLine].
  List<ScrollbackLine?> readScrollbackSlice(int startLine, int count);

  /// Detaches this port and releases its listeners and viewport endpoint.
  Future<void> dispose();
}
