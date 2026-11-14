import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pty2/pty2.dart';

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
  final PseudoTerminal _pty;
  final Utf8ChunkDecoder _inputDecoder;
  late final StreamController<Uint8List> _controller;
  StreamSubscription<String>? _outSub;
  bool _ackScheduled = false;
  bool _waitingForResumeToAck = false;
  bool _cancelled = false;
  bool _done = false;

  Pty2Session._(this._pty) : _inputDecoder = Utf8ChunkDecoder(_pty.write) {
    _controller = StreamController<Uint8List>(
      sync: true,
      onListen: _onListen,
      onPause: _onPause,
      onResume: _onResume,
      onCancel: _onCancel,
    );
  }

  /// Wraps an already-started [PseudoTerminal] instance.
  factory Pty2Session.wrap(PseudoTerminal pty) => Pty2Session._(pty);

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

  static const Set<String> _strippedHostEnvVars = {
    'TMUX',
    'TMUX_PANE',
    'TERM_PROGRAM',
    'TERM_PROGRAM_VERSION',
  };

  static bool _shouldStripHostEnvVar(String key) =>
      _strippedHostEnvVars.contains(key) ||
      key.startsWith('TERMUI_CAST_') ||
      key.startsWith('CAST_');

  /// Builds the child PTY environment from [baseEnvironment], stripping
  /// inherited host multiplexer/terminal and caster variables (`TMUX`,
  /// `TMUX_PANE`, `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`, `TERMUI_CAST_*`)
  /// unless explicitly re-supplied in [overrides], defaulting `TERMUI_AUDIO_APC`
  /// to `'1'` (preserving explicit host or override values) and `TERM` to
  /// `xterm-256color`.
  static Map<String, String> buildChildEnvironment({
    required Map<String, String> baseEnvironment,
    Map<String, String>? overrides,
  }) => {
    'TERMUI_AUDIO_APC': '1',
    for (final MapEntry(:key, :value) in baseEnvironment.entries)
      if (!_shouldStripHostEnvVar(key)) key: value,
    'TERM': 'xterm-256color',
    ...?overrides,
  };

  /// Spawns [executable] with [arguments] inside a `pty2` pseudo-terminal.
  factory Pty2Session.start(
    String executable,
    List<String> arguments, {
    required int initialCols,
    required int initialRows,
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
    try {
      pty.resize(initialCols, initialRows);
    } on Object catch (_) {}

    return Pty2Session._(pty);
  }

  @override
  Stream<Uint8List> get output => _controller.stream;

  void _onListen() {
    if (_outSub != null) return;
    _outSub = _pty.out.listen(_onChunk, onError: _onError, onDone: _onDone);
  }

  void _onChunk(String chunk) {
    if (_done || _cancelled) {
      _pty.ackProcessed();
      return;
    }
    try {
      _controller.add(utf8.encode(chunk));
    } finally {
      if (_done || _cancelled) {
        _pty.ackProcessed();
      } else if (_controller.isPaused) {
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
    if (_controller.isPaused) {
      _waitingForResumeToAck = true;
      return;
    }
    _pty.ackProcessed();
  }

  void _onPause() {
    _outSub?.pause();
  }

  void _onResume() {
    _outSub?.resume();
    if (_waitingForResumeToAck) {
      _waitingForResumeToAck = false;
      _scheduleAck();
    }
  }

  void _onCancel() {
    _cancelled = true;
    _outSub?.resume();
    if (_waitingForResumeToAck) {
      _waitingForResumeToAck = false;
      if (!_done) _pty.ackProcessed();
    }
  }

  void _onError(Object error, StackTrace stackTrace) {
    if (!_cancelled && !_controller.isClosed) {
      _controller.addError(error, stackTrace);
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
  }

  @override
  Future<int> get exitCode => _pty.exitCode;

  @override
  void writeBytes(Uint8List data) {
    _inputDecoder.add(data);
  }

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {
    _pty.resize(cols, rows, pixelWidth: pixelWidth, pixelHeight: pixelHeight);
  }

  @override
  bool kill([ProcessSignal signal = .sigterm]) {
    _inputDecoder.close();
    if (_outSub == null && !_done) {
      _cancelled = true;
      _onListen();
    }
    return _pty.kill(signal);
  }
}
