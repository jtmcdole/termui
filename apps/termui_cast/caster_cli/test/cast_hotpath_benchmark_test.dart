import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:crypto/crypto.dart';
import 'package:fake_async/fake_async.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_caster_cli/termui_caster_cli.dart';
import 'package:test/test.dart';

void main() {
  group('Cast hot-path microbenchmarks', () {
    test(
      'AuthoritativeTerminal.writeString vs utf8.encode + writeBytes on 10 MB mixed ASCII/CJK/SGR',
      () {
        const chunk =
            '\x1b[38;2;120;200;255mhello world \u4e2d\u6587\u6d4b\u8bd5 \x1b[0mstatus=ok\r\n';
        final chunkBytes = utf8.encode(chunk);
        final repeatCount = (10 * 1024 * 1024) ~/ chunkBytes.length;

        final termBytes = AuthoritativeTerminal(
          sessionId: const SessionId('bench-bytes'),
          initialCols: 120,
          initialRows: 40,
        );
        final termString = AuthoritativeTerminal(
          sessionId: const SessionId('bench-string'),
          initialCols: 120,
          initialRows: 40,
        );
        addTearDown(termBytes.dispose);
        addTearDown(termString.dispose);

        for (var i = 0; i < 50; i++) {
          termBytes.writeOutput(utf8.encode(chunk));
          termString.writeString(chunk);
        }

        final swBytes = Stopwatch()..start();
        for (var i = 0; i < repeatCount; i++) {
          termBytes.writeOutput(utf8.encode(chunk));
        }
        swBytes.stop();

        final swString = Stopwatch()..start();
        for (var i = 0; i < repeatCount; i++) {
          termString.writeString(chunk);
        }
        swString.stop();

        final totalMb = (repeatCount * chunkBytes.length) / (1024 * 1024);
        stdout.writeln(
          'BENCH writeString vs utf8.encode+writeOutput (${totalMb.toStringAsFixed(2)} MB): '
          'encode+writeBytes=${swBytes.elapsedMilliseconds}ms, '
          'writeString=${swString.elapsedMilliseconds}ms',
        );
        check(swString.elapsedMicroseconds).isGreaterThan(0);
        check(swBytes.elapsedMicroseconds).isGreaterThan(0);
      },
    );

    test(
      'BufferFrameCodec 400x200 keyframe encode/decode & ~3 MiB scrollback reqId patch',
      () {
        const cols = 400;
        const rows = 200;
        const cellCount = cols * rows;
        final chars = List<String>.generate(
          cellCount,
          (i) => String.fromCharCode(0x41 + (i % 26)),
        );
        final attrs = Uint32List(cellCount * 3);
        for (var i = 0; i < attrs.length; i++) {
          attrs[i] = i & 0xFF;
        }
        final snapshot = BufferSnapshot(
          sessionId: const SessionId('bench-snap'),
          seq: 42,
          cols: cols,
          rows: rows,
          cursor: const CursorState(x: 10, y: 5, visible: true),
          modes: const TerminalModes(),
          scrollback: const ScrollbackWindow(
            clearSeq: 0,
            oldestLine: 0,
            totalLines: 5000,
          ),
          characters: chars,
          attributes: attrs,
        );
        final keyframe = BufferSnapshotFrame(snapshot: snapshot);

        for (var i = 0; i < 5; i++) {
          BufferFrameCodec.decode(BufferFrameCodec.encode(keyframe));
        }

        const iterations = 50;
        final swEncode = Stopwatch()..start();
        late Uint8List lastEncoded;
        for (var i = 0; i < iterations; i++) {
          lastEncoded = BufferFrameCodec.encode(keyframe);
        }
        swEncode.stop();

        final swDecode = Stopwatch()..start();
        for (var i = 0; i < iterations; i++) {
          BufferFrameCodec.decode(lastEncoded);
        }
        swDecode.stop();

        // Multi-chunk ScrollbackChunkFrame requestId patch throughput at maxChunkRows.
        final sbAttrs = Uint32List(400 * 3);
        for (var i = 0; i < sbAttrs.length; i++) {
          sbAttrs[i] = (i * 7 + 3) & 0x00FFFFFF;
        }
        final wideRow = EncodedScrollbackRow(
          isWrapped: false,
          characters: List<String>.generate(
            400,
            (i) => String.fromCharCode(0x41 + (i % 26)),
          ),
          attributes: sbAttrs,
          uriRuns: const <UriRun>[
            (
              start: 0,
              length: 20,
              uri: 'https://example.com/scrollback-benchmark',
            ),
          ],
        );
        final rowsList = List<EncodedScrollbackRow>.filled(
          ScrollbackChunkFrame.maxChunkRows,
          wideRow,
        );
        final sbFrame = ScrollbackChunkFrame(
          sessionId: const SessionId('bench-sb'),
          requestId: 1,
          clearSeq: 0,
          startLine: 0,
          rows: rowsList,
        );
        final sbEncoded = BufferFrameCodec.encode(sbFrame);
        for (var i = 0; i < 10; i++) {
          BufferFrameCodec.rewriteScrollbackChunkRequestId(
            sbEncoded,
            expectedSession: const SessionId('bench-sb'),
            newRequestId: i + 100,
          );
        }
        final swPatch = Stopwatch()..start();
        for (var i = 0; i < 500; i++) {
          final patched = BufferFrameCodec.rewriteScrollbackChunkRequestId(
            sbEncoded,
            expectedSession: const SessionId('bench-sb'),
            newRequestId: i + 1000,
          );
          check(patched).isNotNull();
        }
        swPatch.stop();

        stdout.writeln(
          'BENCH BufferFrameCodec 400x200 ($iterations iters, ${lastEncoded.length}B): '
          'encode=${swEncode.elapsedMilliseconds}ms, decode=${swDecode.elapsedMilliseconds}ms; '
          'scrollback patch (500 iters, ${sbEncoded.length}B)=${swPatch.elapsedMilliseconds}ms',
        );
        check(lastEncoded.length).isGreaterThan(0);
      },
    );

    test(
      'Pipelined (window=8) vs stop-and-wait (window=1) 16 MiB upload over 50 ms RTT StreamChannel',
      () {
        const totalBytes = 16 * 1024 * 1024;
        const chunkBytes = 64 * 1024;
        final payload = Uint8List(totalBytes);
        for (var i = 0; i < payload.length; i += 4097) {
          payload[i] = (i * 31) & 0xFF;
        }
        final digest = Uint8List.fromList(sha256.convert(payload).bytes);

        Duration runSimulatedUpload({required int windowChunks}) {
          late Duration elapsed;
          fakeAsync((async) {
            final dir = Directory.systemTemp.createTempSync('bench_up_');
            final receiver = FileUploadReceiver(
              sessionId: const SessionId('bench-up'),
              uploadDir: dir,
              maxUploadBytes: totalBytes,
            );
            final clientToRelay = StreamChannelController<Uint8List>();
            var ackedOffset = 0;
            var sentOffset = 0;
            var inFlight = 0;
            var endSent = false;
            final done = Completer<void>();

            // 50 ms RTT link simulation (25 ms one-way in each direction).
            clientToRelay.foreign.stream.listen((raw) {
              Timer(const Duration(milliseconds: 25), () {
                final msg = BufferFrameCodec.decode(raw);
                final CastMessage reply;
                switch (msg) {
                  case FileUploadStartFrame():
                    reply = receiver.handleStart(msg);
                  case FileUploadChunkFrame():
                    reply = receiver.handleChunk(msg);
                  case FileUploadEndFrame():
                    final (endAck, _) = receiver.handleEnd(msg);
                    reply = endAck;
                  default:
                    return;
                }
                final replyBytes = BufferFrameCodec.encode(reply);
                Timer(const Duration(milliseconds: 25), () {
                  clientToRelay.foreign.sink.add(replyBytes);
                });
              });
            });

            void pumpWindow() {
              while (inFlight < windowChunks && sentOffset < totalBytes) {
                final end = (sentOffset + chunkBytes) > totalBytes
                    ? totalBytes
                    : sentOffset + chunkBytes;
                clientToRelay.local.sink.add(
                  BufferFrameCodec.encode(
                    FileUploadChunkFrame(
                      sessionId: const SessionId('bench-up'),
                      transferId: 1,
                      offset: sentOffset,
                      data: Uint8List.sublistView(payload, sentOffset, end),
                    ),
                  ),
                );
                sentOffset = end;
                inFlight++;
              }
              if (sentOffset == totalBytes &&
                  ackedOffset == totalBytes &&
                  !endSent) {
                endSent = true;
                clientToRelay.local.sink.add(
                  BufferFrameCodec.encode(
                    FileUploadEndFrame(
                      sessionId: const SessionId('bench-up'),
                      transferId: 1,
                      sha256: digest,
                    ),
                  ),
                );
              }
            }

            clientToRelay.local.stream.listen((raw) {
              final ack = BufferFrameCodec.decode(raw) as FileUploadAckFrame;
              if (ack.status == .ready) {
                pumpWindow();
              } else if (ack.status == .chunkAck) {
                inFlight = (inFlight - 1).clamp(0, windowChunks);
                ackedOffset = ack.nextOffset;
                pumpWindow();
              } else if (ack.status == .completed) {
                elapsed = async.elapsed;
                if (!done.isCompleted) done.complete();
              }
            });

            clientToRelay.local.sink.add(
              BufferFrameCodec.encode(
                FileUploadStartFrame(
                  sessionId: const SessionId('bench-up'),
                  transferId: 1,
                  fileName: 'bench16m.bin',
                  totalBytes: totalBytes,
                ),
              ),
            );

            while (!done.isCompleted) {
              async.elapse(const Duration(milliseconds: 25));
            }
            receiver.dispose();
            dir.deleteSync(recursive: true);
          });
          return elapsed;
        }

        final stopAndWait = runSimulatedUpload(windowChunks: 1);
        final pipelined = runSimulatedUpload(windowChunks: 8);
        stdout.writeln(
          'BENCH 16 MiB upload @ 50ms RTT: '
          'stop-and-wait(w=1)=${stopAndWait.inMilliseconds}ms, '
          'pipelined(w=8)=${pipelined.inMilliseconds}ms '
          '(${(stopAndWait.inMilliseconds / pipelined.inMilliseconds).toStringAsFixed(2)}x speedup)',
        );
        check(pipelined.inMilliseconds).isLessThan(stopAndWait.inMilliseconds);
      },
    );
  });
}
