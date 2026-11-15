import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_cast_server/termui_cast_server.dart';
import 'package:termui_caster_cli/termui_caster_cli.dart';
import 'package:test/test.dart';

void main() {
  group('CasterService tab rename sync, resumeToken, and close reason', () {
    test(
      'preserves resumeToken and renamed title across reconnects without logging raw title, and emits SessionCloseReason.exited',
      () async {
        // CasterConfig trims valid titles and rejects control/bidi characters.
        final trimmedCfg = CasterConfig(
          sessionId: const SessionId('trim-id'),
          title: '  clean-tab  ',
          command: const ['sh'],
        );
        check(trimmedCfg.title).equals('clean-tab');
        for (final bad in ['esc\x1btitle', 'bidi\u202etitle', '   ']) {
          check(
            () => CasterConfig(
              sessionId: const SessionId('bad-title'),
              title: bad,
              command: const ['sh'],
            ),
          ).throws<FormatException>();
        }

        // Reject wrong-length or all-zero explicit resumeToken; verify default CSPRNG token ignores jitter Random.
        final pty = _FakePtySession();
        for (final badToken in [Uint8List(8), Uint8List(16)]) {
          check(
            () => CasterService(
              config: trimmedCfg,
              pty: pty,
              resumeToken: badToken,
            ),
          ).throws<ArgumentError>();
        }

        final csprngServiceA = CasterService(
          config: trimmedCfg,
          pty: _FakePtySession(),
          random: const _ConstantRandom(0),
        );
        final csprngServiceB = CasterService(
          config: trimmedCfg,
          pty: _FakePtySession(),
          random: const _ConstantRandom(0),
        );
        check(csprngServiceA.resumeToken).length.equals(16);
        check(csprngServiceA.resumeToken.any((b) => b != 0)).isTrue();
        check(
          csprngServiceA.resumeToken,
        ).not((it) => it.deepEquals(csprngServiceB.resumeToken));
        await csprngServiceA.stop();
        await csprngServiceB.stop();

        // Full reconnect + RenameSessionFrame + clean exit round-trip.
        final serverSides = <StreamChannel<Uint8List>>[];
        final registerFrames = <RegisterSessionFrame>[];
        final closedFrames = <SessionClosedFrame>[];
        final logs = <String>[];
        final explicitToken = Uint8List.fromList(
          List<int>.generate(16, (i) => i + 10),
        );

        final service = CasterService(
          config: CasterConfig(
            sessionId: const SessionId('rename-persist'),
            title: 'initial-shell',
            command: const ['sh'],
          ),
          pty: pty,
          resumeToken: explicitToken,
          onLog: logs.add,
          baseReconnectDelay: const Duration(milliseconds: 10),
          channelOpener: () async {
            final ctrl = StreamChannelController<Uint8List>();
            serverSides.add(ctrl.foreign);
            ctrl.foreign.stream.listen((raw) {
              switch (BufferFrameCodec.decode(raw)) {
                case AuthFrame():
                  ctrl.foreign.sink.add(
                    BufferFrameCodec.encode(
                      const AuthAcceptedFrame(role: .caster),
                    ),
                  );
                case final RegisterSessionFrame reg:
                  registerFrames.add(reg);
                case final SessionClosedFrame closed:
                  closedFrames.add(closed);
                default:
                  break;
              }
            });
            return ctrl.local;
          },
        );

        await service.start();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        check(registerFrames).length.equals(1);
        check(registerFrames.first.title).equals('initial-shell');
        check(registerFrames.first.resumeToken).deepEquals(explicitToken);

        // Mismatched sessionId RenameSessionFrame is ignored; matching sessionId updates currentTitle without logging it.
        serverSides.first.sink.add(
          BufferFrameCodec.encode(
            const RenameSessionFrame(
              sessionId: SessionId('other-session'),
              title: 'ignored-title',
            ),
          ),
        );
        serverSides.first.sink.add(
          BufferFrameCodec.encode(
            const RenameSessionFrame(
              sessionId: SessionId('rename-persist'),
              title: 'secret-custom-tab 🚀',
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        check(service.currentTitle).equals('secret-custom-tab 🚀');
        for (final line in logs) {
          check(line).not((it) => it.contains('secret-custom-tab'));
        }

        // 3. Clearing pin via RenameSessionFrame(clearPin: true) restores live shellTitle (or initial title fallback).
        serverSides.first.sink.add(
          BufferFrameCodec.encode(
            const RenameSessionFrame(
              sessionId: SessionId('rename-persist'),
              title: '',
              clearPin: true,
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        check(service.currentTitle).equals('initial-shell');

        // Live OSC 2 shell title updates currentTitle when unpinned, and clearPin restores latest shellTitle after re-pin.
        pty.emitText('\x1b]2;nvim Cargo.toml\x07');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        check(service.currentTitle).equals('nvim Cargo.toml');

        serverSides.first.sink.add(
          BufferFrameCodec.encode(
            const RenameSessionFrame(
              sessionId: SessionId('rename-persist'),
              title: 'secret-custom-tab 🚀',
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        check(service.currentTitle).equals('secret-custom-tab 🚀');

        serverSides.first.sink.add(
          BufferFrameCodec.encode(
            const RenameSessionFrame(
              sessionId: SessionId('rename-persist'),
              title: '',
              clearPin: true,
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        check(service.currentTitle).equals('nvim Cargo.toml');

        // Drop transport -> caster reconnects and re-registers with updated title and identical resumeToken.
        await serverSides.first.sink.close();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        check(registerFrames).length.equals(2);
        check(registerFrames[1].title).equals('nvim Cargo.toml');
        check(registerFrames[1].resumeToken).deepEquals(explicitToken);

        // Clean PTY exit sends SessionClosedFrame(reason: exited, exitCode: 0).
        await pty.finish(0);
        final exitCode = await service.done.timeout(const Duration(seconds: 2));
        check(exitCode).equals(0);
        check(closedFrames).length.equals(1);
        check(closedFrames.single.reason).equals(SessionCloseReason.exited);
        check(closedFrames.single.exitCode).equals(0);
      },
    );

    test(
      'end-to-end CasterService + WsRelayHandler seamless resumeToken takeover preserves custom rename without false close',
      () async {
        final registry = SessionRegistry();
        addTearDown(registry.close);
        final handler = WsRelayHandler(
          registry: registry,
          authenticator: TokenAuthenticator(),
        );

        final pty = _FakePtySession();
        final peers = <_HalfOpenablePeer>[];
        final service = CasterService(
          config: CasterConfig(
            sessionId: const SessionId('e2e-takeover'),
            title: 'zsh',
            command: const ['zsh'],
          ),
          pty: pty,
          baseReconnectDelay: const Duration(milliseconds: 10),
          channelOpener: () async {
            final peer = _HalfOpenablePeer();
            addTearDown(peer.dispose);
            peers.add(peer);
            handler.attachCasterChannel(peer.foreign);
            return peer.local;
          },
        );
        addTearDown(service.stop);

        final clientPipe = StreamChannelController<Uint8List>();
        handler.attachClientChannel(clientPipe.foreign);
        final clientInbox = <CastMessage>[];
        addTearDown(
          clientPipe.local.stream.listen((b) {
            clientInbox.add(BufferFrameCodec.decode(b));
          }).cancel,
        );
        clientPipe.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );

        await service.start();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        check(registry.sessions).length.equals(1);
        check(registry.sessions.single.title).equals('zsh');

        clientPipe.local.sink.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(
              sessionId: SessionId('e2e-takeover'),
              cols: 80,
              rows: 24,
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Viewer renames tab -> propagated to CasterService and directory.
        clientPipe.local.sink.add(
          BufferFrameCodec.encode(
            const RenameSessionFrame(
              sessionId: SessionId('e2e-takeover'),
              title: 'deploy-prod',
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        check(service.currentTitle).equals('deploy-prod');
        check(registry.sessions.single.title).equals('deploy-prod');
        clientInbox.clear();

        // Sever only the caster's local side while relay's foreign side stays half-open -> exercises real resumeToken takeover!
        await peers.first.sever();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        check(peers).length.equals(2);
        check(clientInbox.whereType<SessionClosedFrame>()).isEmpty();
        check(registry.sessions).length.equals(1);
        check(registry.sessions.single.title).equals('deploy-prod');
      },
    );
  });
}

final class _FakePtySession implements PtySession {
  final _outputController = StreamController<Uint8List>.broadcast();
  final _exitCompleter = Completer<int>();

  @override
  Stream<Uint8List> get output => _outputController.stream;

  @override
  Future<int> get exitCode => _exitCompleter.future;

  Future<void> finish(int code) async {
    if (!_exitCompleter.isCompleted) {
      _exitCompleter.complete(code);
    }
    await _outputController.close();
  }

  void emitText(String text) {
    _outputController.add(Uint8List.fromList(text.codeUnits));
  }

  @override
  void writeBytes(Uint8List data) {}

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    unawaited(finish(-1));
    return true;
  }
}

final class _ConstantRandom implements Random {
  final int value;

  const _ConstantRandom(this.value);

  @override
  bool nextBool() => value != 0;

  @override
  double nextDouble() => 0.0;

  @override
  int nextInt(int max) => value % max;
}

final class _HalfOpenablePeer {
  final _ctrl = StreamChannelController<Uint8List>();
  final _localIn = StreamController<Uint8List>();
  final _localOut = StreamController<Uint8List>();
  bool _severed = false;

  _HalfOpenablePeer() {
    _ctrl.local.stream.listen(
      _forwardInbound,
      onError: _forwardInboundError,
      onDone: _closeInbound,
    );
    _localOut.stream.listen(_forwardOutbound, onDone: _closeOutbound);
  }

  StreamChannel<Uint8List> get foreign => _ctrl.foreign;

  StreamChannel<Uint8List> get local =>
      StreamChannel<Uint8List>(_localIn.stream, _localOut.sink);

  Future<void> sever() async {
    _severed = true;
    if (!_localIn.isClosed) await _localIn.close();
  }

  Future<void> dispose() => _ctrl.local.sink.close().catchError((Object _) {});

  void _forwardInbound(Uint8List bytes) {
    if (!_severed && !_localIn.isClosed) _localIn.add(bytes);
  }

  void _forwardInboundError(Object error, StackTrace stackTrace) {
    if (!_severed && !_localIn.isClosed) _localIn.addError(error, stackTrace);
  }

  void _closeInbound() {
    if (!_localIn.isClosed) unawaited(_localIn.close());
  }

  void _forwardOutbound(Uint8List bytes) {
    if (!_severed) _ctrl.local.sink.add(bytes);
  }

  void _closeOutbound() {
    if (!_severed) unawaited(_ctrl.local.sink.close());
  }
}
