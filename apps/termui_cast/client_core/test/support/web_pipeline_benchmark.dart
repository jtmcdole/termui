import 'dart:async';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:termui/termui.dart';
import 'package:termui_cast_client_core/src/session_slot.dart';
import 'package:termui_cast_client_core/src/transport/ws_channel_adapter.dart';
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Pure-Dart benchmark measuring `200x60` color-resolved composition, 1-cell and
/// 1-row delta handling, and `adaptBinaryWebSocketChannel` frame throughput on
/// the Dart VM and `dart compile wasm`.
Future<void> main() async {
  try {
    const cols = 200;
    const rows = 60;
    final slot = await _createHydratedSlot(cols, rows);
    final resolver = TerminalColorResolver(
      theme: TerminalColorTheme.solarizedDark,
      settings: const TerminalThemeSettings(
        minimumContrast: 4.5,
        boldIsBright: true,
      ),
    );

    var sinkChecksum = 0;
    final fullComposeUs = _benchFullCompose(
      slot,
      cols,
      rows,
      resolver,
      (buf) => sinkChecksum ^=
          buf.attributes[0] ^ buf.attributes[buf.attributes.length - 1],
    );
    final oneCellUs = await _benchDeltaCompose(
      slot,
      cols,
      rows,
      resolver,
      cellCount: 1,
      iterations: 300,
      startSeq: 2,
      onComposed: (buf) => sinkChecksum ^= buf.attributes[0],
    );
    final oneRowUs = await _benchDeltaCompose(
      slot,
      cols,
      rows,
      resolver,
      cellCount: cols,
      iterations: 200,
      startSeq: 302,
      onComposed: (buf) => sinkChecksum ^= buf.attributes[0],
    );
    final wsThroughputUs = await _benchWsChannelAdapter(frameCount: 1000);

    slot.dispose();
    if (sinkChecksum == -1) {
      throw StateError('unreachable');
    }

    print(
      'web_pipeline_benchmark (200x60): '
      'fullCompose=${fullComposeUs.toStringAsFixed(1)}us/op, '
      'oneCellDeltaCompose=${oneCellUs.toStringAsFixed(1)}us/op, '
      'oneRowDeltaCompose=${oneRowUs.toStringAsFixed(1)}us/op, '
      'wsAdapter1000Frames=${wsThroughputUs.toStringAsFixed(1)}us/1000frames '
      '(${(wsThroughputUs / 1000).toStringAsFixed(3)}us/frame)',
    );
  } catch (e, st) {
    print('BENCH_ERROR: $e\n$st');
    rethrow;
  }
}

Future<SessionSlot> _createHydratedSlot(int cols, int rows) async {
  final slot = SessionSlot(
    id: const SessionId('bench'),
    clock: const Clock(),
    requestTimeout: const Duration(seconds: 2),
    onVisualChange: () {},
    onClearSelection: () {},
    onRequestKeyframe: () {},
    onRequestScrollback: (_) {},
  );
  final buf = Buffer.blank(cols, rows);
  var seed = 1234567;
  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < cols; x++) {
      seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
      final ch = String.fromCharCode(0x21 + (seed % 94));
      final fg = switch (seed % 4) {
        0 => 0,
        1 => Color.ansi(seed % 16).argb,
        2 => Color.ansi(16 + (seed % 240)).argb,
        _ => Color((seed >> 8) & 0xFF, (seed >> 16) & 0xFF, seed & 0xFF).argb,
      };
      final bg = switch ((seed >> 3) % 4) {
        0 => 0,
        1 => Color.ansi((seed >> 2) % 16).argb,
        2 => Color.ansi(16 + ((seed >> 4) % 240)).argb,
        _ => Color((seed >> 4) & 0xFF, (seed >> 12) & 0xFF, seed & 0xFF).argb,
      };
      final mods = (seed % 5 == 0)
          ? Modifier.bold | Modifier.reverse
          : (seed % 8);
      buf.setCell(x, y, ch, fg, bg, mods);
    }
  }
  await slot.machine.handle(.subscribe);
  await slot.machine.handle(
    .snapshot,
    BufferSnapshot.fromBuffer(
      sessionId: const SessionId('bench'),
      seq: 1,
      buffer: buf,
      cursor: const CursorState(x: 10, y: 10),
      modes: TerminalModes.defaults,
      scrollback: ScrollbackWindow.empty,
    ),
  );
  return slot;
}

double _benchFullCompose(
  SessionSlot slot,
  int cols,
  int rows,
  TerminalColorResolver resolver,
  void Function(Buffer) onComposed,
) {
  for (var i = 0; i < 20; i++) {
    onComposed(
      WorkspaceBufferCompositor.compose(
        slot: slot,
        viewportCols: cols,
        viewportRows: rows,
        hoveredLink: null,
        activeSelection: null,
        theme: resolver.theme,
        themeSettings: resolver.settings,
        colorResolver: resolver,
        nowMs: 0,
        hiddenClipboardNotice: null,
      ),
    );
  }
  const iterations = 200;
  final sw = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    onComposed(
      WorkspaceBufferCompositor.compose(
        slot: slot,
        viewportCols: cols,
        viewportRows: rows,
        hoveredLink: null,
        activeSelection: null,
        theme: resolver.theme,
        themeSettings: resolver.settings,
        colorResolver: resolver,
        nowMs: 0,
        hiddenClipboardNotice: null,
      ),
    );
  }
  sw.stop();
  return sw.elapsedMicroseconds / iterations;
}

Future<double> _benchDeltaCompose(
  SessionSlot slot,
  int cols,
  int rows,
  TerminalColorResolver resolver, {
  required int cellCount,
  required int iterations,
  required int startSeq,
  required void Function(Buffer) onComposed,
}) async {
  final chars = List<String>.filled(cellCount, 'X');
  final attrs = Uint32List(cellCount * 3);
  for (var i = 0; i < cellCount; i++) {
    attrs[i * 3] = const Color.ansi(2).argb;
    attrs[i * 3 + 1] = const Color.ansi(0).argb;
    attrs[i * 3 + 2] = Modifier.bold;
  }
  var seq = startSeq;
  for (var i = 0; i < 20; i++) {
    final delta = _buildDelta(cols, rows, seq - 1, seq, chars, attrs, i % cols);
    seq++;
    await slot.machine.handle(.delta, delta);
    onComposed(
      WorkspaceBufferCompositor.compose(
        slot: slot,
        viewportCols: cols,
        viewportRows: rows,
        hoveredLink: null,
        activeSelection: null,
        theme: resolver.theme,
        themeSettings: resolver.settings,
        colorResolver: resolver,
        nowMs: 0,
        hiddenClipboardNotice: null,
      ),
    );
  }

  final sw = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final delta = _buildDelta(cols, rows, seq - 1, seq, chars, attrs, i % cols);
    seq++;
    await slot.machine.handle(.delta, delta);
    onComposed(
      WorkspaceBufferCompositor.compose(
        slot: slot,
        viewportCols: cols,
        viewportRows: rows,
        hoveredLink: null,
        activeSelection: null,
        theme: resolver.theme,
        themeSettings: resolver.settings,
        colorResolver: resolver,
        nowMs: 0,
        hiddenClipboardNotice: null,
      ),
    );
  }
  sw.stop();
  return sw.elapsedMicroseconds / iterations;
}

BufferDelta _buildDelta(
  int cols,
  int rows,
  int baseSeq,
  int seq,
  List<String> chars,
  Uint32List attrs,
  int cursorX,
) {
  return BufferDelta(
    sessionId: const SessionId('bench'),
    baseSeq: baseSeq,
    seq: seq,
    cols: cols,
    rows: rows,
    cursor: CursorState(x: cursorX, y: 12),
    modes: TerminalModes.defaults,
    scrollback: ScrollbackWindow.empty,
    runs: [
      CellRun(
        startIndex: chars.length == 1 ? 12 * cols + cursorX : 12 * cols,
        characters: chars,
        attributes: attrs,
      ),
    ],
  );
}

Future<double> _benchWsChannelAdapter({required int frameCount}) async {
  final payload = Uint8List.fromList(List<int>.generate(64, (i) => i & 0xFF));
  // Warmup
  await _runWsAdapterBatch(payload, 100);
  const batches = 10;
  var totalUs = 0;
  for (var b = 0; b < batches; b++) {
    totalUs += await _runWsAdapterBatch(payload, frameCount);
  }
  return totalUs / batches;
}

Future<int> _runWsAdapterBatch(Uint8List payload, int frameCount) async {
  final incoming = StreamController<Object?>(sync: true);
  var outboundCount = 0;
  final fakeWs = _BenchWebSocketChannel(
    stream: incoming.stream,
    onAdd: (_) => outboundCount++,
  );
  final adapted = adaptBinaryWebSocketChannel(fakeWs);
  var inboundCount = 0;
  final done = Completer<void>();
  final sub = adapted.stream.listen((_) {
    inboundCount++;
    if (inboundCount == frameCount && !done.isCompleted) {
      done.complete();
    }
  });
  final sw = Stopwatch()..start();
  for (var i = 0; i < frameCount; i++) {
    incoming.add(payload);
    adapted.sink.add(payload);
  }
  await done.future;
  sw.stop();
  if (outboundCount < 0) {
    throw StateError('unreachable');
  }
  await incoming.close();
  await sub.cancel();
  await adapted.sink.close();
  return sw.elapsedMicroseconds;
}

final class _BenchWebSocketChannel extends StreamChannelMixin<Object?>
    implements WebSocketChannel {
  @override
  final Stream<Object?> stream;

  @override
  final WebSocketSink sink;

  _BenchWebSocketChannel({
    required this.stream,
    required void Function(Object? data) onAdd,
  }) : sink = _BenchWebSocketSink(onAdd);

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready => Future<void>.value();
}

final class _BenchWebSocketSink implements WebSocketSink {
  final void Function(Object? data) _onAdd;

  _BenchWebSocketSink(this._onAdd);

  @override
  final Future<void> done = Future<void>.value();

  @override
  void add(Object? data) => _onAdd(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<Object?> stream) => stream.forEach(_onAdd);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}
}
