import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pty2/pty2.dart';
import 'package:termui_pty/termui_pty.dart';

/// Seam over a spawned pseudo-terminal child process.
abstract interface class PtySession {
  /// Raw UTF-8 output byte stream emitted by the child PTY.
  Stream<Uint8List> get output;

  /// Process exit code future completing when the child exits.
  Future<int> get exitCode;

  /// Writes raw input [data] to the PTY master descriptor.
  void writeBytes(Uint8List data);

  /// Resizes the PTY window to [cols] by [rows] and optional pixel dimensions.
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0});

  /// Sends [signal] to terminate the child process.
  bool kill([ProcessSignal signal = .sigterm]);
}

/// Stateful UTF-8 byte-to-string decoder forwarding decoded text chunks
/// without corrupting multi-byte sequences split across input frames.
final class Utf8ChunkDecoder {
  final ByteConversionSink _byteSink;
  bool _closed = false;

  /// Creates a chunked UTF-8 decoder emitting decoded text to [onText].
  Utf8ChunkDecoder(void Function(String text) onText)
    : _byteSink = const Utf8Decoder(
        allowMalformed: true,
      ).startChunkedConversion(_ImmediateStringSink(onText));

  /// Feeds a raw [chunk] of UTF-8 input bytes.
  void add(Uint8List chunk) {
    if (_closed || chunk.isEmpty) return;
    _byteSink.add(chunk);
  }

  /// Flushes any trailing incomplete sequence and closes the sink.
  void close() {
    if (_closed) return;
    _closed = true;
    _byteSink.close();
  }
}

final class _ImmediateStringSink extends StringConversionSinkBase {
  final void Function(String text) _onText;

  _ImmediateStringSink(this._onText);

  @override
  void addSlice(String str, int start, int end, bool isLast) {
    if (start < end) {
      _onText(str.substring(start, end));
    }
  }

  @override
  void close() {}
}

/// Production [PtySession] backed by `package:pty2`'s `PseudoTerminal`.
final class Pty2Session implements PtySession {
  /// Default horizontal cell extent in pixels matching [VirtualTerminal].
  static const int defaultCellPixelWidth = 8;

  /// Default vertical cell extent in pixels matching [VirtualTerminal].
  static const int defaultCellPixelHeight = 16;

  final PseudoTerminal _pty;
  final int _cellPixelWidth;
  final int _cellPixelHeight;
  final Utf8ChunkDecoder _inputDecoder;
  late final StreamController<Uint8List> _controller;
  late final StreamController<String> _textController;
  StreamSubscription<String>? _outSub;
  bool _ackScheduled = false;
  bool _waitingForResumeToAck = false;
  bool _cancelled = false;
  bool _done = false;
  bool _byteListenerActive = false;
  bool _textListenerActive = false;

  Pty2Session._(
    this._pty, {
    int cellPixelWidth = defaultCellPixelWidth,
    int cellPixelHeight = defaultCellPixelHeight,
  }) : _cellPixelWidth = max(1, cellPixelWidth),
       _cellPixelHeight = max(1, cellPixelHeight),
       _inputDecoder = Utf8ChunkDecoder(_pty.write) {
    _controller = StreamController<Uint8List>(
      sync: true,
      onListen: _onListenBytes,
      onPause: _onPause,
      onResume: _onResume,
      onCancel: _onCancelBytes,
    );
    _textController = StreamController<String>(
      sync: true,
      onListen: _onListenText,
      onPause: _onPause,
      onResume: _onResume,
      onCancel: _onCancelText,
    );
  }

  /// Wraps an already-started [PseudoTerminal] instance.
  factory Pty2Session.wrap(
    PseudoTerminal pty, {
    int cellPixelWidth = defaultCellPixelWidth,
    int cellPixelHeight = defaultCellPixelHeight,
  }) => Pty2Session._(
    pty,
    cellPixelWidth: cellPixelWidth,
    cellPixelHeight: cellPixelHeight,
  );

  /// Computes clamped `(pixelWidth, pixelHeight)` (`1..65535`) for `TIOCSWINSZ`,
  /// falling back to `cols * cellPixelWidth` and `rows * cellPixelHeight` when zero.
  static (int pixelWidth, int pixelHeight) resolvePixelDimensions(
    int cols,
    int rows, {
    int pixelWidth = 0,
    int pixelHeight = 0,
    int cellPixelWidth = defaultCellPixelWidth,
    int cellPixelHeight = defaultCellPixelHeight,
  }) {
    final int safeCols = max(1, cols);
    final int safeRows = max(1, rows);
    final int pxW = pixelWidth > 0
        ? pixelWidth
        : safeCols * max<int>(1, cellPixelWidth);
    final int pxH = pixelHeight > 0
        ? pixelHeight
        : safeRows * max<int>(1, cellPixelHeight);
    return (min(65535, max(1, pxW)), min(65535, max(1, pxH)));
  }

  /// Direct decoded UTF-16 string stream from the underlying PTY, avoiding
  /// a redundant `utf8.encode` -> `utf8.decode` round-trip when feeding
  /// `AuthoritativeTerminal.writeString`.
  Stream<String> get textOutput => _textController.stream;

  /// Ensures the Windows `conpty.dll` + `OpenConsole.exe` sidecar is staged
  /// when [download] is `true`, reporting non-fatal fallback warnings via
  /// [onWarning].
  static Future<String?> ensureConPtyReady({
    bool download = false,
    void Function(String message)? onWarning,
  }) => PseudoTerminal.ensureConPtyReady(
    download: download,
    onWarning: onWarning,
  );

  /// Builds the child PTY environment from [baseEnvironment], stripping
  /// inherited host multiplexer/terminal and caster variables (`TMUX`,
  /// `TMUX_PANE`, `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`, `TERMUI_CAST_*`)
  /// unless explicitly re-supplied in [overrides], defaulting `TERMUI_AUDIO_APC`
  /// to `'1'` (preserving explicit host or override values) and `TERM` to
  /// `xterm-256color`.
  static Map<String, String> buildChildEnvironment({
    required Map<String, String> baseEnvironment,
    Map<String, String>? overrides,
  }) => sanitizeChildEnvironment(
    baseEnvironment: baseEnvironment,
    overrides: overrides,
  );

  /// Spawns [executable] with [arguments] inside a `pty2` pseudo-terminal.
  factory Pty2Session.start(
    String executable,
    List<String> arguments, {
    required int initialCols,
    required int initialRows,
    int cellPixelWidth = defaultCellPixelWidth,
    int cellPixelHeight = defaultCellPixelHeight,
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    final mergedEnv = buildChildEnvironment(
      baseEnvironment: Platform.environment,
      overrides: environment,
    );
    final pty = PseudoTerminal.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: mergedEnv,
      ackProcessed: true,
    );
    final safeCols = max(1, initialCols);
    final safeRows = max(1, initialRows);
    final (pxW, pxH) = resolvePixelDimensions(
      safeCols,
      safeRows,
      cellPixelWidth: cellPixelWidth,
      cellPixelHeight: cellPixelHeight,
    );
    try {
      pty.resize(safeCols, safeRows, pixelWidth: pxW, pixelHeight: pxH);
    } on Object catch (_) {}

    return Pty2Session._(
      pty,
      cellPixelWidth: cellPixelWidth,
      cellPixelHeight: cellPixelHeight,
    );
  }

  @override
  Stream<Uint8List> get output => _controller.stream;

  void _onListenBytes() {
    _byteListenerActive = true;
    _attachOutSub();
  }

  void _onListenText() {
    _textListenerActive = true;
    _attachOutSub();
  }

  void _attachOutSub() {
    if (_outSub != null) return;
    _outSub = _pty.out.listen(_onChunk, onError: _onError, onDone: _onDone);
  }

  bool get _anyPaused =>
      (_byteListenerActive && _controller.isPaused) ||
      (_textListenerActive && _textController.isPaused);

  void _onChunk(String chunk) {
    if (_done || _cancelled) {
      _pty.ackProcessed();
      return;
    }
    try {
      if (_textListenerActive && !_textController.isClosed) {
        _textController.add(chunk);
      }
      if (_byteListenerActive && !_controller.isClosed) {
        _controller.add(utf8.encode(chunk));
      }
    } finally {
      if (_done || _cancelled) {
        _pty.ackProcessed();
      } else if (_anyPaused) {
        _waitingForResumeToAck = true;
      } else {
        _scheduleAck();
      }
    }
  }

  void _scheduleAck() {
    if (_ackScheduled || _done) return;
    _ackScheduled = true;
    Timer.run(_flushScheduledAck);
  }

  void _flushScheduledAck() {
    _ackScheduled = false;
    if (_done) return;
    if (_cancelled) {
      _pty.ackProcessed();
      return;
    }
    if (_anyPaused) {
      _waitingForResumeToAck = true;
      return;
    }
    _pty.ackProcessed();
  }

  void _onPause() {
    if (_anyPaused) {
      _outSub?.pause();
    }
  }

  void _onResume() {
    if (_anyPaused) return;
    _outSub?.resume();
    if (_waitingForResumeToAck) {
      _waitingForResumeToAck = false;
      _scheduleAck();
    }
  }

  void _onCancelBytes() {
    _byteListenerActive = false;
    _handleCancelIfNoListeners();
  }

  void _onCancelText() {
    _textListenerActive = false;
    _handleCancelIfNoListeners();
  }

  void _handleCancelIfNoListeners() {
    if (_byteListenerActive || _textListenerActive) {
      _onResume();
      return;
    }
    _cancelled = true;
    _outSub?.resume();
    if (_waitingForResumeToAck) {
      _waitingForResumeToAck = false;
      if (!_done) _pty.ackProcessed();
    }
  }

  void _onError(Object error, StackTrace stackTrace) {
    if (!_cancelled) {
      if (_byteListenerActive && !_controller.isClosed) {
        _controller.addError(error, stackTrace);
      }
      if (_textListenerActive && !_textController.isClosed) {
        _textController.addError(error, stackTrace);
      }
    }
    if (!_done) _pty.ackProcessed();
  }

  void _onDone() {
    _done = true;
    _waitingForResumeToAck = false;
    _outSub = null;
    if (!_controller.isClosed) {
      unawaited(_controller.close());
    }
    if (!_textController.isClosed) {
      unawaited(_textController.close());
    }
  }

  @override
  Future<int> get exitCode => _pty.exitCode;

  @override
  void writeBytes(Uint8List data) {
    _inputDecoder.add(data);
  }

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {
    final safeCols = max(1, cols);
    final safeRows = max(1, rows);
    final (pxW, pxH) = resolvePixelDimensions(
      safeCols,
      safeRows,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      cellPixelWidth: _cellPixelWidth,
      cellPixelHeight: _cellPixelHeight,
    );
    _pty.resize(safeCols, safeRows, pixelWidth: pxW, pixelHeight: pxH);
  }

  @override
  bool kill([ProcessSignal signal = .sigterm]) {
    _inputDecoder.close();
    if (_outSub == null && !_done) {
      _cancelled = true;
      _attachOutSub();
    }
    return _pty.kill(signal);
  }
}
