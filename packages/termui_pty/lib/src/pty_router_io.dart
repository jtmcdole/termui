import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pty2/pty2.dart';

import 'pty_router.dart';

final class _Utf8InputDecoder {
  final ByteConversionSink _byteSink;
  bool _closed = false;

  _Utf8InputDecoder(void Function(String text) onText)
    : _byteSink = const Utf8Decoder(
        allowMalformed: true,
      ).startChunkedConversion(_ImmediateTextSink(onText));

  void add(Uint8List chunk) {
    if (_closed || chunk.isEmpty) return;
    _byteSink.add(chunk);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _byteSink.close();
  }
}

final class _ImmediateTextSink extends StringConversionSinkBase {
  final void Function(String text) _onText;

  _ImmediateTextSink(this._onText);

  @override
  void addSlice(String str, int start, int end, bool isLast) {
    if (start < end) {
      _onText(str.substring(start, end));
    }
  }

  @override
  void close() {}
}

/// `dart:io` [RoutedPtyBackend] backed by `package:pty2`'s [PseudoTerminal].
final class Pty2RoutedBackend implements RoutedPtyBackend {
  static const Set<String> _strippedHostEnvVars = {
    'TMUX',
    'TMUX_PANE',
    'TERM_PROGRAM',
    'TERM_PROGRAM_VERSION',
  };

  final PseudoTerminal _pty;
  final bool _ackProcessed;
  final _Utf8InputDecoder _inputDecoder;
  late final StreamController<Uint8List> _controller;

  StreamSubscription<String>? _outSub;
  bool _ackScheduled = false;
  bool _waitingForResumeToAck = false;
  bool _cancelled = false;
  bool _done = false;
  bool _exited = false;
  bool _disposed = false;

  Pty2RoutedBackend._(this._pty, {required bool ackProcessed})
    : _ackProcessed = ackProcessed,
      _inputDecoder = _Utf8InputDecoder(_pty.write) {
    unawaited(
      _pty.exitCode.whenComplete(() {
        _exited = true;
      }),
    );
    _controller = StreamController<Uint8List>(
      sync: true,
      onListen: _onListen,
      onPause: _onPause,
      onResume: _onResume,
      onCancel: _onCancel,
    );
  }

  static bool _shouldStripHostEnvVar(String key) =>
      _strippedHostEnvVars.contains(key) ||
      key.startsWith('TERMUI_CAST_') ||
      key.startsWith('CAST_');

  /// Builds the child PTY environment from [baseEnvironment], stripping
  /// inherited multiplexer/caster variables, defaulting `TERM` to
  /// `xterm-256color`, and enabling `TERMUI_AUDIO_APC=1` unless opted out.
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

  /// Ensures Windows ConPTY redistributables are staged when [download] is `true`.
  static Future<String?> ensureConPtyReady({
    bool download = false,
    void Function(String message)? onWarning,
  }) => PseudoTerminal.ensureConPtyReady(
    download: download,
    onWarning: onWarning,
  );

  /// Spawns [executable] with [arguments] inside a `pty2` [PseudoTerminal].
  factory Pty2RoutedBackend.start(
    String executable,
    List<String> arguments, {
    int initialCols = 80,
    int initialRows = 24,
    int pixelWidth = 0,
    int pixelHeight = 0,
    String? workingDirectory,
    Map<String, String>? environment,
    bool ackProcessed = true,
    bool raw = false,
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
      ackProcessed: ackProcessed,
      raw: raw,
    );
    try {
      pty.resize(
        math.max(1, initialCols),
        math.max(1, initialRows),
        pixelWidth: pixelWidth.clamp(0, 65535),
        pixelHeight: pixelHeight.clamp(0, 65535),
      );
    } on Object catch (_) {}
    return Pty2RoutedBackend._(pty, ackProcessed: ackProcessed);
  }

  /// Wraps an already-started [PseudoTerminal] instance.
  factory Pty2RoutedBackend.wrap(
    PseudoTerminal pty, {
    bool ackProcessed = true,
  }) => Pty2RoutedBackend._(pty, ackProcessed: ackProcessed);

  @override
  Stream<Uint8List> get output => _controller.stream;

  @override
  Future<int> get exitCode => _pty.exitCode;

  void _ackIfEnabled() {
    if (_ackProcessed) {
      _pty.ackProcessed();
    }
  }

  void _onListen() {
    if (_outSub != null) return;
    _outSub = _pty.out.listen(_onChunk, onError: _onError, onDone: _onDone);
  }

  void _onChunk(String chunk) {
    if (_done || _cancelled) {
      _ackIfEnabled();
      return;
    }
    try {
      _controller.add(utf8.encode(chunk));
    } finally {
      if (_done || _cancelled) {
        _ackIfEnabled();
      } else if (_controller.isPaused) {
        _waitingForResumeToAck = true;
      } else {
        _scheduleAck();
      }
    }
  }

  void _scheduleAck() {
    if (!_ackProcessed || _ackScheduled || _done) return;
    _ackScheduled = true;
    Timer.run(_flushScheduledAck);
  }

  void _flushScheduledAck() {
    _ackScheduled = false;
    if (_done) return;
    if (_cancelled) {
      _ackIfEnabled();
      return;
    }
    if (_controller.isPaused) {
      _waitingForResumeToAck = true;
      return;
    }
    _ackIfEnabled();
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
      if (!_done) _ackIfEnabled();
    }
  }

  void _onError(Object error, StackTrace stackTrace) {
    if (!_cancelled && !_controller.isClosed) {
      _controller.addError(error, stackTrace);
    }
    if (!_done) _ackIfEnabled();
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
  void write(Uint8List bytes) {
    if (_disposed || bytes.isEmpty) return;
    _inputDecoder.add(bytes);
  }

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {
    if (_disposed) return;
    _pty.resize(
      math.max(1, cols),
      math.max(1, rows),
      pixelWidth: pixelWidth.clamp(0, 65535),
      pixelHeight: pixelHeight.clamp(0, 65535),
    );
  }

  @override
  void kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    _inputDecoder.close();
    if (_outSub == null && !_done) {
      _cancelled = true;
      _onListen();
    }
    _pty.kill(signal);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (!_exited) {
      kill(ProcessSignal.sigterm);
    } else {
      _inputDecoder.close();
    }
    await _outSub?.cancel();
    _outSub = null;
    if (!_done) {
      _ackIfEnabled();
    }
    if (!_exited) {
      await _pty.exitCode
          .then<void>((_) {}, onError: (Object _) {})
          .timeout(const Duration(milliseconds: 250), onTimeout: () {});
    }
    if (!_exited) {
      _pty.kill(ProcessSignal.sigkill);
      await _pty.exitCode
          .then<void>((_) {}, onError: (Object _) {})
          .timeout(const Duration(milliseconds: 500), onTimeout: () {});
    }
    if (!_controller.isClosed) {
      final closeFuture = _controller.close();
      if (_controller.hasListener && !_controller.isPaused) {
        await closeFuture;
      }
    }
  }
}
