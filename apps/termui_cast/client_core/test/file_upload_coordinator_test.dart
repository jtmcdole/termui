import 'dart:async';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:test/test.dart';

final class _FakeUploadServer {
  final toClient = StreamController<Uint8List>.broadcast();
  final fromClient = StreamController<Uint8List>();
  final List<CastMessage> received = <CastMessage>[];
  late final StreamSubscription<Uint8List> _sub;

  _FakeUploadServer() {
    _sub = fromClient.stream.listen((raw) {
      received.add(BufferFrameCodec.decode(raw));
    });
  }

  Future<StreamChannel<Uint8List>> openChannel() async =>
      StreamChannel<Uint8List>(toClient.stream, fromClient.sink);

  void send(CastMessage message) =>
      toClient.add(BufferFrameCodec.encode(message));

  Future<void> close() async {
    await _sub.cancel();
    await toClient.close();
    await fromClient.close();
  }
}

void main() {
  group('FileUploadCoordinator pipelining', () {
    test(
      'keeps up to windowChunks (8) chunks in flight and completes hash',
      () async {
        const sessionId = SessionId('pipe-upload');
        final server = _FakeUploadServer();
        final transport = WsClientTransport(channelFactory: server.openChannel);
        final repo = CastClientRepository(
          transport: transport,
          enableReconnect: false,
        );
        await repo.connect();
        server.send(const AuthAcceptedFrame(role: .client));
        await Future<void>.delayed(Duration.zero);

        final errors = <String>[];
        final coordinator = FileUploadCoordinator(
          repository: repo,
          onProgressChanged: () {},
          onError: errors.add,
        );
        void ackListener(CastMessage msg) {
          if (msg is FileUploadAckFrame) {
            coordinator.handleAckFrame(msg);
          }
        }

        clientMessageReceivedEvent.addListener(repo.bus, ackListener);
        addTearDown(
          () =>
              clientMessageReceivedEvent.removeListener(repo.bus, ackListener),
        );

        const chunkBytes = FileUploadCoordinator.chunkSizeBytes;
        const totalChunks = 10;
        final payload = Uint8List.fromList(
          List<int>.generate(chunkBytes * totalChunks, (i) => i & 0xFF),
        );

        final uploadFuture = coordinator.uploadFiles(sessionId, [
          MemoryDroppedFileSource(name: 'big.bin', bytes: payload),
        ]);

        // Wait for FileUploadStartFrame.
        await Future<void>.delayed(Duration.zero);
        final startFrame = server.received
            .whereType<FileUploadStartFrame>()
            .single;
        final transferId = startFrame.transferId;

        server.send(
          FileUploadAckFrame(
            sessionId: sessionId,
            transferId: transferId,
            status: .ready,
            nextOffset: 0,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        // Before any chunk ACK arrives, exactly windowChunks (8) must be in flight.
        final initialChunks = server.received
            .whereType<FileUploadChunkFrame>()
            .toList();
        check(initialChunks).length.equals(FileUploadCoordinator.windowChunks);
        check(initialChunks.last.offset).equals(7 * chunkBytes);

        // Acknowledge chunks 0..7 as they finish.
        for (var i = 0; i < totalChunks; i++) {
          final ackOffset = (i + 1) * chunkBytes;
          server.send(
            FileUploadAckFrame(
              sessionId: sessionId,
              transferId: transferId,
              status: .chunkAck,
              nextOffset: ackOffset,
            ),
          );
          await Future<void>.delayed(Duration.zero);
        }

        final endFrame = server.received.whereType<FileUploadEndFrame>().single;
        check(endFrame.aborted).isFalse();
        server.send(
          FileUploadAckFrame(
            sessionId: sessionId,
            transferId: transferId,
            status: .completed,
            nextOffset: payload.length,
          ),
        );

        final ok = await uploadFuture;
        check(ok).isTrue();
        check(errors).isEmpty();

        await repo.dispose();
        await server.close();
      },
    );

    test(
      'aborts pipelined upload immediately when rejected ACK arrives mid-window',
      () async {
        const sessionId = SessionId('pipe-reject');
        final server = _FakeUploadServer();
        final transport = WsClientTransport(channelFactory: server.openChannel);
        final repo = CastClientRepository(
          transport: transport,
          enableReconnect: false,
        );
        await repo.connect();
        server.send(const AuthAcceptedFrame(role: .client));
        await Future<void>.delayed(Duration.zero);

        final errors = <String>[];
        final coordinator = FileUploadCoordinator(
          repository: repo,
          onProgressChanged: () {},
          onError: errors.add,
        );
        void ackListener(CastMessage msg) {
          if (msg is FileUploadAckFrame) {
            coordinator.handleAckFrame(msg);
          }
        }

        clientMessageReceivedEvent.addListener(repo.bus, ackListener);
        addTearDown(
          () =>
              clientMessageReceivedEvent.removeListener(repo.bus, ackListener),
        );

        const chunkBytes = FileUploadCoordinator.chunkSizeBytes;
        final payload = Uint8List(chunkBytes * 12);
        final uploadFuture = coordinator.uploadFiles(sessionId, [
          MemoryDroppedFileSource(name: 'fail.bin', bytes: payload),
        ]);

        await Future<void>.delayed(Duration.zero);
        final transferId = server.received
            .whereType<FileUploadStartFrame>()
            .single
            .transferId;

        server.send(
          FileUploadAckFrame(
            sessionId: sessionId,
            transferId: transferId,
            status: .ready,
            nextOffset: 0,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        check(
          server.received.whereType<FileUploadChunkFrame>(),
        ).length.equals(FileUploadCoordinator.windowChunks);

        // Reject first in-flight chunk -> must stop without sending chunks 8..11.
        server.send(
          FileUploadAckFrame(
            sessionId: sessionId,
            transferId: transferId,
            status: .rejected,
            nextOffset: 0,
            message: 'Quota exceeded mid-window',
          ),
        );

        final ok = await uploadFuture;
        check(ok).isFalse();
        check(errors).deepEquals(const ['Quota exceeded mid-window']);
        check(
          server.received.whereType<FileUploadChunkFrame>(),
        ).length.equals(FileUploadCoordinator.windowChunks);

        await repo.dispose();
        await server.close();
      },
    );
  });
}
