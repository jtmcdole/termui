import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:clock/clock.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_cast_server/termui_cast_server.dart';
import 'package:test/test.dart';

void main() {
  group('Tab management relay semantics (rename, close reason, takeover)', () {
    late SessionRegistry registry;
    late WsRelayHandler handler;

    setUp(() {
      registry = SessionRegistry();
      handler = WsRelayHandler(
        registry: registry,
        authenticator: TokenAuthenticator(),
      );
    });

    tearDown(() async {
      await registry.close();
    });

    test(
      'renameSession enforces client subscription, skips no-ops, rejects unknown sessions, and rate-limits per client',
      () async {
        var now = DateTime.utc(2026, 11, 4, 20, 0, 0);
        final timedRegistry = SessionRegistry(
          clock: Clock(() => now),
          maxRenamesPerWindow: 4,
          renameRateWindow: const Duration(seconds: 1),
        );
        addTearDown(timedRegistry.close);
        final timedHandler = WsRelayHandler(
          registry: timedRegistry,
          authenticator: TokenAuthenticator(),
        );

        const sessionId = SessionId('sess-rename');
        final casterPipe = StreamChannelController<Uint8List>();
        timedHandler.attachCasterChannel(casterPipe.foreign);
        final casterInbox = <CastMessage>[];
        addTearDown(
          casterPipe.local.stream.listen((b) {
            casterInbox.add(BufferFrameCodec.decode(b));
          }).cancel,
        );
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .caster, token: '')),
        );
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            RegisterSessionFrame(
              sessionId: sessionId,
              title: 'initial',
              cols: 80,
              rows: 24,
            ),
          ),
        );

        final clientSub = StreamChannelController<Uint8List>();
        final clientUnsub = StreamChannelController<Uint8List>();
        timedHandler.attachClientChannel(clientSub.foreign);
        timedHandler.attachClientChannel(clientUnsub.foreign);
        final inboxSub = <CastMessage>[];
        final inboxUnsub = <CastMessage>[];
        addTearDown(
          clientSub.local.stream.listen((b) {
            inboxSub.add(BufferFrameCodec.decode(b));
          }).cancel,
        );
        addTearDown(
          clientUnsub.local.stream.listen((b) {
            inboxUnsub.add(BufferFrameCodec.decode(b));
          }).cancel,
        );

        clientSub.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        clientUnsub.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        clientSub.local.sink.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(sessionId: sessionId),
          ),
        );
        await pumpEventQueue();
        casterInbox.clear();
        inboxSub.clear();
        inboxUnsub.clear();

        // 1. Unsubscribed client is rejected with rename_rejected; subscribed client renames session -> forwarded and broadcast.
        clientUnsub.local.sink.add(
          BufferFrameCodec.encode(
            const RenameSessionFrame(
              sessionId: sessionId,
              title: 'unsub-attempt',
            ),
          ),
        );
        await pumpEventQueue();
        check(
          inboxUnsub.whereType<ErrorFrame>().single.code,
        ).equals('rename_rejected');
        check(casterInbox).isEmpty();
        inboxUnsub.clear();

        clientSub.local.sink.add(
          BufferFrameCodec.encode(
            const RenameSessionFrame(sessionId: sessionId, title: 'renamed-1'),
          ),
        );
        await pumpEventQueue();

        final forwarded = casterInbox.whereType<RenameSessionFrame>().single;
        check(forwarded.sessionId).equals(sessionId);
        check(forwarded.title).equals('renamed-1');
        check(
          inboxSub
              .whereType<SessionDirectoryFrame>()
              .last
              .sessions
              .single
              .title,
        ).equals('renamed-1');
        check(
          inboxUnsub
              .whereType<SessionDirectoryFrame>()
              .last
              .sessions
              .single
              .title,
        ).equals('renamed-1');

        // 2. No-op rename (identical title) emits nothing and consumes zero rate-limit quota.
        casterInbox.clear();
        inboxSub.clear();
        inboxUnsub.clear();
        for (var i = 0; i < 6; i++) {
          clientSub.local.sink.add(
            BufferFrameCodec.encode(
              const RenameSessionFrame(
                sessionId: sessionId,
                title: 'renamed-1',
              ),
            ),
          );
        }
        await pumpEventQueue();
        check(casterInbox).isEmpty();
        check(inboxSub).isEmpty();
        check(inboxUnsub).isEmpty();

        // 3. Unknown session returns rename_rejected only to the requesting client.
        clientSub.local.sink.add(
          BufferFrameCodec.encode(
            const RenameSessionFrame(
              sessionId: SessionId('unknown'),
              title: 'ghost',
            ),
          ),
        );
        await pumpEventQueue();
        check(
          inboxSub.whereType<ErrorFrame>().single.code,
        ).equals('rename_rejected');
        check(inboxUnsub).isEmpty();
        inboxSub.clear();

        // 4. Consume remaining 3 renames in the 1s window (2, 3, 4 succeed; 5th is rate-limited).
        for (final nextTitle in ['renamed-2', 'renamed-3', 'renamed-4']) {
          clientSub.local.sink.add(
            BufferFrameCodec.encode(
              RenameSessionFrame(sessionId: sessionId, title: nextTitle),
            ),
          );
        }
        await pumpEventQueue();
        check(timedRegistry.sessions.single.title).equals('renamed-4');

        inboxSub.clear();
        inboxUnsub.clear();
        clientSub.local.sink.add(
          BufferFrameCodec.encode(
            const RenameSessionFrame(sessionId: sessionId, title: 'renamed-5'),
          ),
        );
        await pumpEventQueue();
        final rateErr = inboxSub.whereType<ErrorFrame>().single;
        check(rateErr.code).equals('rename_rejected');
        check(rateErr.message).contains('rate limit');
        check(inboxUnsub).isEmpty();
        check(timedRegistry.sessions.single.title).equals('renamed-4');

        // Advancing past the 1s sliding window restores rename quota.
        now = now.add(const Duration(seconds: 1));
        clientSub.local.sink.add(
          BufferFrameCodec.encode(
            const RenameSessionFrame(sessionId: sessionId, title: 'renamed-5'),
          ),
        );
        await pumpEventQueue();
        check(timedRegistry.sessions.single.title).equals('renamed-5');
      },
    );

    test(
      'broadcasts SessionClosedFrame with explicit exited vs disconnected reason to all clients before directory update',
      () async {
        const exitedId = SessionId('sess-clean-exit');
        const droppedId = SessionId('sess-dropped');

        final casterExit = StreamChannelController<Uint8List>();
        final casterDrop = StreamChannelController<Uint8List>();
        handler.attachCasterChannel(casterExit.foreign);
        handler.attachCasterChannel(casterDrop.foreign);
        addTearDown(casterExit.local.stream.listen((_) {}).cancel);
        addTearDown(casterDrop.local.stream.listen((_) {}).cancel);

        for (final (pipe, id) in [
          (casterExit, exitedId),
          (casterDrop, droppedId),
        ]) {
          pipe.local.sink.add(
            BufferFrameCodec.encode(const AuthFrame(role: .caster, token: '')),
          );
          pipe.local.sink.add(
            BufferFrameCodec.encode(
              RegisterSessionFrame(
                sessionId: id,
                title: id.value,
                cols: 80,
                rows: 24,
              ),
            ),
          );
        }

        final subClient = StreamChannelController<Uint8List>();
        final unsubClient = StreamChannelController<Uint8List>();
        handler.attachClientChannel(subClient.foreign);
        handler.attachClientChannel(unsubClient.foreign);
        final subInbox = <CastMessage>[];
        final unsubInbox = <CastMessage>[];
        addTearDown(
          subClient.local.stream.listen((b) {
            subInbox.add(BufferFrameCodec.decode(b));
          }).cancel,
        );
        addTearDown(
          unsubClient.local.stream.listen((b) {
            unsubInbox.add(BufferFrameCodec.decode(b));
          }).cancel,
        );

        subClient.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        unsubClient.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        subClient.local.sink.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(sessionId: exitedId),
          ),
        );
        await pumpEventQueue();
        subInbox.clear();
        unsubInbox.clear();

        // 1. Clean exit broadcasts SessionClosedFrame(reason: exited, exitCode: 17) before SessionDirectoryFrame to BOTH clients.
        casterExit.local.sink.add(
          BufferFrameCodec.encode(
            const SessionClosedFrame(
              sessionId: exitedId,
              reason: .exited,
              exitCode: 17,
            ),
          ),
        );
        await pumpEventQueue();

        for (final inbox in [subInbox, unsubInbox]) {
          check(inbox).length.equals(2);
          final closed = inbox[0] as SessionClosedFrame;
          check(closed.sessionId).equals(exitedId);
          check(closed.reason).equals(SessionCloseReason.exited);
          check(closed.exitCode).equals(17);
          final dir = inbox[1] as SessionDirectoryFrame;
          check([for (final s in dir.sessions) s.id]).deepEquals([droppedId]);
        }

        subInbox.clear();
        unsubInbox.clear();

        // 2. Unexpected caster socket drop broadcasts SessionClosedFrame(reason: disconnected, exitCode: -1) before SessionDirectoryFrame.
        await casterDrop.local.sink.close();
        await pumpEventQueue();

        for (final inbox in [subInbox, unsubInbox]) {
          check(inbox).length.equals(2);
          final closed = inbox[0] as SessionClosedFrame;
          check(closed.sessionId).equals(droppedId);
          check(closed.reason).equals(SessionCloseReason.disconnected);
          check(closed.exitCode).equals(-1);
          final dir = inbox[1] as SessionDirectoryFrame;
          check(dir.sessions).isEmpty();
        }
      },
    );

    test(
      'seamless caster takeover requires matching non-zero resumeToken, detaches stale caster without false close, and pushes title/resize/keyframe',
      () async {
        const sessionId = SessionId('sess-takeover');
        final validToken = Uint8List.fromList(
          List<int>.generate(16, (i) => 0xA0 + i),
        );
        final wrongToken = Uint8List.fromList(
          List<int>.generate(16, (i) => 0xB0 + i),
        );

        final oldCasterPipe = StreamChannelController<Uint8List>();
        handler.attachCasterChannel(oldCasterPipe.foreign);
        addTearDown(oldCasterPipe.local.stream.listen((_) {}).cancel);
        oldCasterPipe.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .caster, token: '')),
        );
        oldCasterPipe.local.sink.add(
          BufferFrameCodec.encode(
            RegisterSessionFrame(
              sessionId: sessionId,
              title: 'original-title',
              cols: 80,
              rows: 24,
              resumeToken: validToken,
            ),
          ),
        );

        final viewerPipe = StreamChannelController<Uint8List>();
        handler.attachClientChannel(viewerPipe.foreign);
        final viewerInbox = <CastMessage>[];
        addTearDown(
          viewerPipe.local.stream.listen((b) {
            viewerInbox.add(BufferFrameCodec.decode(b));
          }).cancel,
        );
        viewerPipe.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        viewerPipe.local.sink.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(
              sessionId: sessionId,
              cols: 120,
              rows: 40,
            ),
          ),
        );
        // Rename while oldCaster socket is half-open and start an upload that must be rejected on takeover.
        viewerPipe.local.sink.add(
          BufferFrameCodec.encode(
            const RenameSessionFrame(
              sessionId: sessionId,
              title: 'renamed-on-relay',
            ),
          ),
        );
        viewerPipe.local.sink.add(
          BufferFrameCodec.encode(
            const FileUploadStartFrame(
              sessionId: sessionId,
              transferId: 77,
              fileName: 'staged.bin',
              totalBytes: 1024,
            ),
          ),
        );
        await pumpEventQueue();
        viewerInbox.clear();

        // 1. All-zero token and wrong token are rejected with duplicate_session.
        for (final badToken in [Uint8List(16), wrongToken]) {
          final roguePipe = StreamChannelController<Uint8List>();
          handler.attachCasterChannel(roguePipe.foreign);
          final rogueInbox = <CastMessage>[];
          addTearDown(
            roguePipe.local.stream.listen((b) {
              rogueInbox.add(BufferFrameCodec.decode(b));
            }).cancel,
          );
          roguePipe.local.sink.add(
            BufferFrameCodec.encode(const AuthFrame(role: .caster, token: '')),
          );
          roguePipe.local.sink.add(
            BufferFrameCodec.encode(
              RegisterSessionFrame(
                sessionId: sessionId,
                title: 'hijack',
                cols: 80,
                rows: 24,
                resumeToken: badToken,
              ),
            ),
          );
          await pumpEventQueue();
          check(
            rogueInbox.whereType<ErrorFrame>().single.code,
          ).equals('duplicate_session');
        }
        check(viewerInbox.whereType<SessionClosedFrame>()).isEmpty();

        // 2. Legitimate caster reconnects with matching validToken while oldCaster socket is still open.
        final newCasterPipe = StreamChannelController<Uint8List>();
        handler.attachCasterChannel(newCasterPipe.foreign);
        final newCasterInbox = <CastMessage>[];
        addTearDown(
          newCasterPipe.local.stream.listen((b) {
            newCasterInbox.add(BufferFrameCodec.decode(b));
          }).cancel,
        );
        newCasterPipe.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .caster, token: '')),
        );
        newCasterPipe.local.sink.add(
          BufferFrameCodec.encode(
            RegisterSessionFrame(
              sessionId: sessionId,
              title: 'original-title',
              cols: 80,
              rows: 24,
              resumeToken: validToken,
            ),
          ),
        );
        await pumpEventQueue();

        // Zero false SessionClosedFrame emitted; stalled upload cleanly rejected so viewer can retry.
        check(viewerInbox.whereType<SessionClosedFrame>()).isEmpty();
        final uploadReject = viewerInbox.whereType<FileUploadAckFrame>().single;
        check(uploadReject.transferId).equals(77);
        check(uploadReject.status).equals(FileUploadStatus.rejected);
        check(registry.sessions.single.title).equals('renamed-on-relay');

        // New caster receives SubscriberCount(1), Resize(120x40), RequestKeyframe, and RenameSession('renamed-on-relay').
        check(
          newCasterInbox
              .whereType<SubscriberCountFrame>()
              .single
              .subscriberCount,
        ).equals(1);
        final resize = newCasterInbox.whereType<ResizeFrame>().single;
        check((resize.cols, resize.rows)).equals((120, 40));
        check(
          newCasterInbox.whereType<RequestKeyframeFrame>().single.sessionId,
        ).equals(sessionId);
        check(
          newCasterInbox.whereType<RenameSessionFrame>().single.title,
        ).equals('renamed-on-relay');

        // Closing the already-evicted oldCaster socket does NOT close the taken-over session!
        await oldCasterPipe.local.sink.close();
        await pumpEventQueue();
        check(viewerInbox.whereType<SessionClosedFrame>()).isEmpty();
        check(registry.sessions).length.equals(1);
      },
    );

    test(
      'tracks shellTitle separately from pinnedTitle, falls back on empty shellTitle, and unpins via clearPin',
      () async {
        const sessionId = SessionId('sess-title-pin');
        final casterPipe = StreamChannelController<Uint8List>();
        handler.attachCasterChannel(casterPipe.foreign);
        final casterInbox = <CastMessage>[];
        addTearDown(
          casterPipe.local.stream
              .listen((b) => casterInbox.add(BufferFrameCodec.decode(b)))
              .cancel,
        );
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .caster, token: '')),
        );
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            const RegisterSessionFrame(
              sessionId: sessionId,
              title: 'zsh-default',
              cols: 80,
              rows: 24,
            ),
          ),
        );

        final clientPipe = StreamChannelController<Uint8List>();
        handler.attachClientChannel(clientPipe.foreign);
        final clientInbox = <CastMessage>[];
        addTearDown(
          clientPipe.local.stream
              .listen((b) => clientInbox.add(BufferFrameCodec.decode(b)))
              .cancel,
        );
        clientPipe.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        clientPipe.local.sink.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(sessionId: sessionId),
          ),
        );
        await pumpEventQueue();

        // 1. Live shell title updates directory title (isUserPinned == false) and notifies subscribers.
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            const ShellTitleFrame(
              sessionId: sessionId,
              title: 'nvim main.dart',
            ),
          ),
        );
        await pumpEventQueue();
        check(registry.sessions.single.title).equals('nvim main.dart');
        check(registry.sessions.single.isUserPinned).isFalse();
        check(
          clientInbox.whereType<ShellTitleFrame>().last.title,
        ).equals('nvim main.dart');

        // 2. User pins custom tab name -> shell title updates no longer overwrite directory title.
        clientPipe.local.sink.add(
          BufferFrameCodec.encode(
            const RenameSessionFrame(
              sessionId: sessionId,
              title: 'pinned-work',
            ),
          ),
        );
        await pumpEventQueue();
        check(registry.sessions.single.title).equals('pinned-work');
        check(registry.sessions.single.isUserPinned).isTrue();

        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            const ShellTitleFrame(sessionId: sessionId, title: 'cargo test'),
          ),
        );
        await pumpEventQueue();
        check(registry.sessions.single.title).equals('pinned-work');
        check(registry.sessions.single.isUserPinned).isTrue();

        // 3. Clearing pin reverts displayTitle to latest shellTitle ('cargo test').
        casterInbox.clear();
        clientPipe.local.sink.add(
          BufferFrameCodec.encode(
            const RenameSessionFrame(
              sessionId: sessionId,
              title: '',
              clearPin: true,
            ),
          ),
        );
        await pumpEventQueue();
        check(registry.sessions.single.title).equals('cargo test');
        check(registry.sessions.single.isUserPinned).isFalse();
        final forwardedClear = casterInbox
            .whereType<RenameSessionFrame>()
            .single;
        check(forwardedClear.clearPin).isTrue();
        check(forwardedClear.title).equals('cargo test');

        // 4. Empty ShellTitleFrame('') falls back to initial registered title ('zsh-default').
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            const ShellTitleFrame(sessionId: sessionId, title: ''),
          ),
        );
        await pumpEventQueue();
        check(registry.sessions.single.title).equals('zsh-default');
      },
    );
  });
}
