import 'dart:async';
import 'dart:math';

import 'package:termui/terminal/backend/terminal_backend.dart';

import 'ktty_probe_report.dart';
import 'ktty_reply_interceptor.dart';

/// Pure-Dart wire-protocol [TerminalBackend] that routes rendered ANSI/APC/OSC
/// output through [onWriteWire] and pre-filters incoming bytes with
/// [KttyReplyInterceptor] to populate [report].
final class KttyWireTerminalBackend implements TerminalBackend {
  static const Duration _escDisambiguationDelay = Duration(milliseconds: 15);

  @override
  final bool isWindows;

  /// Callback receiving every raw escape sequence and rendered frame written by `termui`.
  final void Function(String data) onWriteWire;

  /// Optional hook invoked when `Terminal` requests raw mode.
  final void Function()? onEnableRawMode;

  /// Optional hook invoked when `Terminal` exits raw mode.
  final void Function()? onDisableRawMode;

  /// Capability report populated by [interceptor] as wire replies arrive.
  final KttyProbeReport report;

  /// Stateful wire-reply pre-filter attached to [rawInput].
  final KttyReplyInterceptor interceptor;

  final StreamController<List<int>> _filteredInput =
      StreamController<List<int>>.broadcast();
  final StreamController<Point<int>> _sizeChanges =
      StreamController<Point<int>>.broadcast();

  StreamSubscription<List<int>>? _wireInputSub;
  StreamSubscription<Point<int>>? _externalResizeSub;
  Timer? _escTimer;
  Point<int> _size;
  bool _disposed = false;

  /// Creates a [KttyWireTerminalBackend] bound to [wireInput] and [onWriteWire].
  KttyWireTerminalBackend({
    required Stream<List<int>> wireInput,
    required this.onWriteWire,
    required this.report,
    Point<int> initialSize = const Point<int>(100, 30),
    Stream<Point<int>>? externalResizeStream,
    this.onEnableRawMode,
    this.onDisableRawMode,
    this.isWindows = false,
  }) : _size = initialSize,
       interceptor = KttyReplyInterceptor(report) {
    _wireInputSub = wireInput.listen(_onWireChunk, onDone: _onWireDone);
    if (externalResizeStream != null) {
      _externalResizeSub = externalResizeStream.listen((next) {
        updateSize(next.x, next.y);
      });
    }
  }

  void _onWireChunk(List<int> chunk) {
    if (_disposed) return;
    _escTimer?.cancel();
    _escTimer = null;

    final passthrough = interceptor.processChunk(chunk);
    if (passthrough.isNotEmpty && !_filteredInput.isClosed) {
      _filteredInput.add(passthrough);
    }

    if (interceptor.hasPendingBareEsc) {
      _escTimer = Timer(_escDisambiguationDelay, _flushBareEsc);
    }
  }

  void _flushBareEsc() {
    _escTimer = null;
    if (_disposed || _filteredInput.isClosed) return;
    final esc = interceptor.flushPendingEsc();
    if (esc.isNotEmpty) {
      _filteredInput.add(esc);
    }
  }

  void _onWireDone() {
    _escTimer?.cancel();
    _flushBareEsc();
    if (!_filteredInput.isClosed) {
      _filteredInput.close();
    }
  }

  @override
  Stream<List<int>> get rawInput => _filteredInput.stream;

  @override
  void write(String data) {
    if (_disposed || data.isEmpty) return;
    onWriteWire(data);
  }

  @override
  Point<int> get size => _size;

  /// Updates the terminal grid dimensions and notifies [watchSize] listeners.
  void updateSize(int width, int height) {
    if (_disposed || width <= 0 || height <= 0) return;
    final next = Point<int>(width, height);
    if (next == _size) return;
    _size = next;
    if (!_sizeChanges.isClosed) {
      _sizeChanges.add(next);
    }
  }

  @override
  Stream<Point<int>> watchSize() => _sizeChanges.stream;

  @override
  void enableRawMode() => onEnableRawMode?.call();

  @override
  void disableRawMode() => onDisableRawMode?.call();

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _escTimer?.cancel();
    _escTimer = null;
    _wireInputSub?.cancel();
    _wireInputSub = null;
    _externalResizeSub?.cancel();
    _externalResizeSub = null;
    if (!_filteredInput.isClosed) {
      _filteredInput.close();
    }
    if (!_sizeChanges.isClosed) {
      _sizeChanges.close();
    }
  }
}
