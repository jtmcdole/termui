@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:termui/termui.dart';
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_cast_server/termui_cast_server.dart';
import 'package:termui_caster_cli/termui_caster_cli.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:test/test.dart';

String _bufferText(Buffer buffer) {
  final sb = StringBuffer();
  for (var y = 0; y < buffer.height; y++) {
    for (var x = 0; x < buffer.width; x++) {
      sb.write(buffer.getCharacter(x, y));
    }
    sb.writeln();
  }
  return '$sb';
}

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  group('Live CastServer + pty2 + WsClientTransport E2E roundtrip', () {
    setUpAll(() async {
      final warnings = <String>[];
      final resolved = await Pty2Session.ensureConPtyReady(
        download: true,
        onWarning: warnings.add,
      );
      if (Platform.isWindows) {
        check(
          resolved,
          because: 'Windows E2E PTY tests require ConPtyBundle: $warnings',
        ).isNotNull();
      }
    });

    test(
      'streams multiple live pty2 sessions via RemoteTerminalPort, routes input, and clamps smallest viewport',
      () async {
        final server = await CastServer.bind(
          ServerConfig(
            host: InternetAddress.loopbackIPv4,
            port: 0,
            casterToken: 'caster-tok',
            clientToken: 'client-tok',
          ),
        );

        CasterService? caster1;
        CasterService? caster2;
        CastClientRepository? repo1;
        CastClientRepository? repo2;
        RemoteTerminalPort? v1Port1;
        RemoteTerminalPort? v1Port2;
        RemoteTerminalPort? v2Port1;

        final tempDir = await Directory.systemTemp.createTemp('e2e_cast_pty_');
        addTearDown(() => tempDir.delete(recursive: true));
        final workerScript = File('${tempDir.path}/echo_worker.dart');
        await workerScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final tag = args.first;
  final markerDir = args[1];
  stdout.writeln('READY:\$tag');
  stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((raw) {
        final line = raw.trim();
        stdout.writeln('ECHO:\$tag:\$line');
        if (line == 'EXIT') {
          File('\$markerDir/exit_\$tag').writeAsStringSync('0', flush: true);
          exit(0);
        }
      });
}
''');

        try {
          final pty1 = Pty2Session.start(
            Platform.resolvedExecutable,
            [workerScript.path, 'ONE', tempDir.path],
            initialCols: 80,
            initialRows: 24,
          );
          final pty2 = Pty2Session.start(
            Platform.resolvedExecutable,
            [workerScript.path, 'TWO', tempDir.path],
            initialCols: 80,
            initialRows: 24,
          );

          caster1 = CasterService(
            config: CasterConfig(
              serverUri: server.casterUri,
              token: 'caster-tok',
              sessionId: const SessionId('live-1'),
              title: 'worker-1',
              command: const ['dart'],
            ),
            pty: pty1,
          );
          caster2 = CasterService(
            config: CasterConfig(
              serverUri: server.casterUri,
              token: 'caster-tok',
              sessionId: const SessionId('live-2'),
              title: 'worker-2',
              command: const ['dart'],
            ),
            pty: pty2,
          );
          await caster1.start();
          await _waitUntil(
            () => server.registry.sessions.any(
              (s) => s.id == const SessionId('live-1'),
            ),
          );
          await caster2.start();
          await _waitUntil(() => server.registry.sessions.length == 2);

          repo1 = CastClientRepository(
            transport: WsClientTransport(
              serverUri: server.clientUri,
              token: 'client-tok',
            ),
          );
          await repo1.connect();
          v1Port1 = repo1.openTerminalPort(
            const SessionId('live-1'),
            initialCols: 80,
            initialRows: 24,
          );
          await _waitUntil(
            () => _bufferText(v1Port1!.buffer).contains('READY:ONE'),
          );

          // Viewer 2 joins at 60x18 while Viewer 1 is 80x24: relay clamps
          // live-1 to min(80, 60) x min(24, 18) = 60x18 across all subscribers.
          repo2 = CastClientRepository(
            transport: WsClientTransport(
              serverUri: server.clientUri,
              token: 'client-tok',
            ),
          );
          await repo2.connect();
          v2Port1 = repo2.openTerminalPort(
            const SessionId('live-1'),
            initialCols: 60,
            initialRows: 18,
          );
          await _waitUntil(
            () => _bufferText(v2Port1!.buffer).contains('READY:ONE'),
          );
          await _waitUntil(
            () => caster1!.terminal.cols == 60 && caster1.terminal.rows == 18,
          );

          // Viewer 2 sends input while clamped at 60x18; both viewers observe echo.
          v2Port1.sendInput(Uint8List.fromList('ping-from-v2\r'.codeUnits));
          await _waitUntil(
            () =>
                _bufferText(v1Port1!.buffer).contains('ECHO:ONE:ping-from-v2'),
          );

          // Viewer 2 disconnects -> live-1 automatically restores to Viewer 1's 80x24.
          await v2Port1.dispose();
          v2Port1 = null;
          await repo2.dispose();
          repo2 = null;
          await _waitUntil(
            () => caster1!.terminal.cols == 80 && caster1.terminal.rows == 24,
          );

          // Remaining Viewer 1 can expand live-1 up to 92x28 before shutting down live-1.
          v1Port1.setViewportSize(92, 28);
          await _waitUntil(
            () => caster1!.terminal.cols == 92 && caster1.terminal.rows == 28,
          );
          v1Port1.sendInput(Uint8List.fromList('EXIT\r'.codeUnits));

          // Viewer 1 opens live-2 and sends input + clean exit.
          v1Port2 = repo1.openTerminalPort(
            const SessionId('live-2'),
            initialCols: 80,
            initialRows: 24,
          );
          await _waitUntil(
            () => _bufferText(v1Port2!.buffer).contains('READY:TWO'),
          );
          v1Port2.sendInput(Uint8List.fromList('hello-two\r'.codeUnits));
          await _waitUntil(
            () => _bufferText(v1Port2!.buffer).contains('ECHO:TWO:hello-two'),
          );

          v1Port2.sendInput(Uint8List.fromList('EXIT\r'.codeUnits));
          final exitCodes = await [caster1.done, caster2.done].wait;
          for (final tag in const ['ONE', 'TWO']) {
            check(
              File('${tempDir.path}/exit_$tag').readAsStringSync(),
            ).equals('0');
          }
          for (final code in exitCodes) {
            check(const [0, -1]).contains(code);
          }
        } finally {
          await v1Port2?.dispose();
          await v1Port1?.dispose();
          await v2Port1?.dispose();
          await repo1?.dispose();
          await repo2?.dispose();
          await caster1?.stop(killPty: true);
          await caster2?.stop(killPty: true);
          await server.close();
        }
      },
    );

    test(
      'uploads multiple dropped files E2E to caster host and injects escaped paths into PTY',
      () async {
        final server = await CastServer.bind(
          ServerConfig(
            host: InternetAddress.loopbackIPv4,
            port: 0,
            casterToken: 'caster-tok',
            clientToken: 'client-tok',
          ),
        );
        final tempDir = await Directory.systemTemp.createTemp(
          'e2e_upload_pty_',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final uploadDir = Directory('${tempDir.path}/uploads')..createSync();
        final workerScript = File('${tempDir.path}/echo_worker.dart');
        await workerScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

void main() {
  stdout.writeln('READY:UPLOAD');
  stdin.listen((chunk) {
    stdout.writeln('PTY_IN:\${utf8.decode(chunk, allowMalformed: true)}');
  });
}
''');

        CasterService? caster;
        CastClientRepository? repo;
        RemoteTerminalPort? port;
        FileUploadCoordinator? uploader;
        void Function(CastMessage)? ackListener;
        try {
          final pty = Pty2Session.start(
            Platform.resolvedExecutable,
            [workerScript.path],
            initialCols: 100,
            initialRows: 24,
          );
          const sessionId = SessionId('upload-live');
          caster = CasterService(
            config: CasterConfig(
              serverUri: server.casterUri,
              token: 'caster-tok',
              sessionId: sessionId,
              title: 'upload-worker',
              uploadDirPath: uploadDir.path,
              command: const ['dart'],
            ),
            pty: pty,
          );
          await caster.start();
          await _waitUntil(() => server.registry.sessions.length == 1);

          repo = CastClientRepository(
            transport: WsClientTransport(
              serverUri: server.clientUri,
              token: 'client-tok',
            ),
          );
          final uploadErrors = <String>[];
          uploader = FileUploadCoordinator(
            repository: repo,
            onProgressChanged: () {},
            onError: uploadErrors.add,
          );
          ackListener = (msg) {
            if (msg is FileUploadAckFrame) {
              uploader!.handleAckFrame(msg);
            }
          };
          clientMessageReceivedEvent.addListener(repo.bus, ackListener);
          await repo.connect();
          port = repo.openTerminalPort(
            sessionId,
            initialCols: 100,
            initialRows: 24,
          );
          await _waitUntil(
            () => _bufferText(port!.buffer).contains('READY:UPLOAD'),
          );

          final multiChunkBytes = Uint8List.fromList(
            List<int>.generate(150000, (i) => i & 0xFF),
          );
          final files = <DroppedFileSource>[
            MemoryDroppedFileSource(
              name: 'payload.bin',
              bytes: multiChunkBytes,
            ),
            MemoryDroppedFileSource(
              name: 'empty note.txt',
              bytes: Uint8List(0),
            ),
          ];

          final ok = await uploader.uploadFiles(sessionId, files);
          check(ok).isTrue();
          check(uploadErrors).isEmpty();
          check(
            File('${uploadDir.path}/payload.bin').readAsBytesSync(),
          ).deepEquals(multiChunkBytes);
          check(
            File('${uploadDir.path}/empty note.txt').lengthSync(),
          ).equals(0);

          await _waitUntil(
            () =>
                _bufferText(port!.buffer).contains('payload.bin') &&
                _bufferText(port.buffer).contains('empty note.txt'),
          );
        } finally {
          if (repo != null && ackListener != null) {
            clientMessageReceivedEvent.removeListener(repo.bus, ackListener);
          }
          await port?.dispose();
          await repo?.dispose();
          await caster?.stop(killPty: true);
          await server.close();
        }
      },
    );

    test(
      'FileUploadCoordinator handles mid-upload cancel, C1 sanitization, directory/oversize filtering, caster rejection, and readSlice errors',
      () async {
        // 1. sanitizeWireFileName strips C0/C1 controls, paths, '.', '..', and truncates >255 UTF-8 bytes.
        check(
          FileUploadCoordinator.sanitizeWireFileName('..'),
        ).equals('upload.bin');
        check(
          FileUploadCoordinator.sanitizeWireFileName('/tmp/a\x00\x85\x9Fb.txt'),
        ).equals('a___b.txt');
        final longMultiByte = '${'é' * 200}.txt';
        final truncated = FileUploadCoordinator.sanitizeWireFileName(
          longMultiByte,
        );
        check(utf8.encode(truncated).length).isLessOrEqual(255);

        final channelCtrl = StreamChannelController<Uint8List>();
        final transport = WsClientTransport(
          serverUri: Uri.parse('ws://127.0.0.1:8420/v1/client'),
          token: 'secret',
          channelFactory: () async => channelCtrl.local,
        );
        final repo = CastClientRepository(
          transport: transport,
          enableReconnect: false,
        );
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
        RemoteTerminalPort? port;
        addTearDown(() async {
          clientMessageReceivedEvent.removeListener(repo.bus, ackListener);
          await port?.dispose();
          await repo.dispose();
        });

        const sessionId = SessionId('edge-1');
        final sentClientFrames = <CastMessage>[];
        var ackMode = 'ready_only';

        channelCtrl.foreign.stream.listen((bytes) {
          final msg = BufferFrameCodec.decode(bytes);
          sentClientFrames.add(msg);
          if (msg is AuthFrame) {
            channelCtrl.foreign.sink.add(
              BufferFrameCodec.encode(const AuthAcceptedFrame(role: .client)),
            );
            channelCtrl.foreign.sink.add(
              BufferFrameCodec.encode(
                const SessionDirectoryFrame(
                  sessions: [
                    SessionSummary(
                      id: sessionId,
                      title: 'zsh',
                      cols: 80,
                      rows: 23,
                      subscriberCount: 1,
                    ),
                  ],
                ),
              ),
            );
          } else if (msg is SubscribeSessionFrame) {
            channelCtrl.foreign.sink.add(
              BufferFrameCodec.encode(
                BufferSnapshotFrame(
                  snapshot: BufferSnapshot.fromBuffer(
                    sessionId: sessionId,
                    seq: 1,
                    buffer: Buffer.blank(80, 23),
                    cursor: CursorState.origin,
                    modes: const TerminalModes(bracketedPaste: true),
                  ),
                ),
              ),
            );
          } else if (msg is FileUploadStartFrame) {
            final reject = ackMode == 'reject_start';
            channelCtrl.foreign.sink.add(
              BufferFrameCodec.encode(
                FileUploadAckFrame(
                  sessionId: sessionId,
                  transferId: msg.transferId,
                  status: reject ? .rejected : .ready,
                  nextOffset: 0,
                  message: reject ? 'disk full' : '',
                ),
              ),
            );
          }
        });

        await repo.connect();
        port = repo.openTerminalPort(
          sessionId,
          initialCols: 80,
          initialRows: 23,
        );
        await _waitUntil(() => port!.slot.state == .synchronized);

        // 2. Mid-upload cancel sends FileUploadEndFrame(aborted: true).
        final inFlight = coordinator.uploadFiles(sessionId, [
          MemoryDroppedFileSource(
            name: 'report.txt',
            bytes: Uint8List.fromList(utf8.encode('hello')),
          ),
        ]);
        await _waitUntil(
          () => sentClientFrames.whereType<FileUploadChunkFrame>().isNotEmpty,
        );
        coordinator.cancel();
        check(await inFlight).isFalse();
        check(
          sentClientFrames.whereType<FileUploadEndFrame>().single.aborted,
        ).isTrue();

        // 3. Direct uploadFiles filters out directories cleanly.
        final dirOnlyOk = await coordinator.uploadFiles(sessionId, [
          MemoryDroppedFileSource(
            name: 'folder',
            bytes: Uint8List(0),
            isDirectory: true,
          ),
        ]);
        check(dirOnlyOk).isFalse();

        // 4. Caster rejection surfaces error callback.
        ackMode = 'reject_start';
        final rejectedOk = await coordinator.uploadFiles(sessionId, [
          MemoryDroppedFileSource(
            name: 'rejected.txt',
            bytes: Uint8List.fromList([1, 2, 3]),
          ),
        ]);
        check(rejectedOk).isFalse();
        check(errors.last).equals('disk full');

        // 5. readSlice throwing sends FileUploadEndFrame(aborted: true) and reports error.
        ackMode = 'ready_only';
        sentClientFrames.clear();
        final brokenOk = await coordinator.uploadFiles(sessionId, [
          const _ThrowingDroppedFileSource(name: 'broken.txt', size: 16),
        ]);
        await pumpEventQueue();
        check(brokenOk).isFalse();
        check(
          sentClientFrames.whereType<FileUploadEndFrame>().single.aborted,
        ).isTrue();
        check(errors.last).contains('Failed to read dropped file "broken.txt"');
      },
    );

    test(
      'three-way caster-relay-client round-trip streams OSC 8, SGR 58, APC G Kitty graphics, Kitty keyboard mode, and box selection',
      () async {
        final server = await CastServer.bind(
          ServerConfig(
            host: InternetAddress.loopbackIPv4,
            port: 0,
            casterToken: 'caster-tok',
            clientToken: 'client-tok',
          ),
        );
        final tempDir = await Directory.systemTemp.createTemp('e2e_v5_ktty_');
        addTearDown(() => tempDir.delete(recursive: true));
        final workerScript = File('${tempDir.path}/v5_worker.dart');
        await workerScript.writeAsString(r'''
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

void main() {
  stdin.echoMode = false;
  stdin.lineMode = false;
  final rgba = Uint8List.fromList(List<int>.filled(16, 0xCC));
  final b64 = base64Encode(rgba);
  stdout.write(
    '\x1b[>11u'
    '\x1b_Gi=77,s=2,v=2,a=T,t=d,f=32,c=2,r=1,q=2;$b64\x1b\\'
    '\r\n\x1b]8;;https://dart.dev\x1b\\\x1b[4:3;58;2;40;210;120mDartDocs\x1b[0m\x1b]8;;\x1b\\'
    '\r\nROW1_ABCD'
    '\r\nROW2_EFGH'
    '\r\nREADY_V5\r\n',
  );
  final seen = StringBuffer();
  stdin.listen((bytes) {
    seen.write(latin1.decode(bytes));
    if ('$seen'.contains(';1:3u')) {
      stdout.write('GOT_RELEASE\r\n');
    }
  });
}
''');

        CasterService? caster;
        CastClientRepository? repo;
        RemoteTerminalPort? port;

        try {
          final pty = Pty2Session.start(
            Platform.resolvedExecutable,
            [workerScript.path],
            initialCols: 60,
            initialRows: 12,
          );
          const sessionId = SessionId('v5-live');
          caster = CasterService(
            config: CasterConfig(
              serverUri: server.casterUri,
              token: 'caster-tok',
              sessionId: sessionId,
              title: 'ktty-e2e',
              initialCols: 60,
              initialRows: 12,
              command: const ['dart'],
            ),
            pty: pty,
          );
          await caster.start();
          await _waitUntil(() => server.registry.sessions.length == 1);

          repo = CastClientRepository(
            transport: WsClientTransport(
              serverUri: server.clientUri,
              token: 'client-tok',
            ),
          );
          await repo.connect();
          port = repo.openTerminalPort(
            sessionId,
            initialCols: 60,
            initialRows: 12,
          );

          await _waitUntil(
            () => _bufferText(port!.buffer).contains('READY_V5'),
          );

          final buf = port.buffer;
          check(port.modes.kittyKeyboardFlags).equals(11);
          check(buf.lookupKittyImage(0, 0, 77)).isNotNull();
          check(buf.getUri(0, 1)).equals('https://dart.dev');
          check(
            buf.getUnderlineColor(0, 1),
          ).equals(const Color(40, 210, 120).argb);

          // Link span resolution across RemoteTerminalPort + WorkspaceBufferCompositor.
          final matched = TerminalSelection.matchUrlAt(
            (y) => WorkspaceBufferCompositor.lookupVirtualLine(
              port!.slot,
              port.buffer,
              y,
            ),
            virtualX: 2,
            virtualY: 1,
            cols: port.cols,
          );
          check(matched).isNotNull();
          check(matched!.url).equals(Uri.parse('https://dart.dev'));

          // Box selection over 'ABCD\nEFGH' extracts rectangular block cleanly.
          const boxSel = TerminalSelection(
            anchor: Point<int>(5, 2),
            focus: Point<int>(8, 3),
            mode: .box,
          );
          final boxText = boxSel.extractVirtualText(
            (y) => WorkspaceBufferCompositor.lookupVirtualLine(
              port!.slot,
              port.buffer,
              y,
            ),
            cols: port.cols,
          );
          check(boxText).equals('ABCD\nEFGH');

          // Sending Kitty CSI u key release reaches PTY.
          port.sendInput(Uint8List.fromList(utf8.encode('\x1b[107;1:3u')));
          await _waitUntil(
            () => _bufferText(port!.buffer).contains('GOT_RELEASE'),
          );
        } finally {
          await port?.dispose();
          await repo?.dispose();
          await caster?.stop(killPty: true);
          await server.close();
        }
      },
    );

    test(
      'RemoteTerminalPort streams live OSC 2 title, BEL, and APC audio over real WebSocket with ref-counted split panes',
      () async {
        final server = await CastServer.bind(
          ServerConfig(
            host: InternetAddress.loopbackIPv4,
            port: 0,
            casterToken: 'caster-tok',
            clientToken: 'client-tok',
          ),
        );
        const sessionId = SessionId('signal-port');
        CasterService? caster;
        CastClientRepository? repo;
        RemoteTerminalPort? port1;
        RemoteTerminalPort? port2;

        final tempDir = await Directory.systemTemp.createTemp(
          'e2e_signal_pty_',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final scriptFile = File('${tempDir.path}/signal_worker.dart');
        await scriptFile.writeAsString('''
import 'dart:convert';
import 'dart:io';

void main() {
  stdout.writeln('SIGNAL_READY');
  stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        final cmd = line.trim();
        if (cmd == 'SIGNALS') {
          stdout.write('\\x1b]2;Live Signal Shell\\x07');
          stdout.write('\\x07');
          stdout.write('\\x1b_Aa=tone,w=sine,f=523,d=80\\x1b\\\\');
          stdout.writeln('SIGNALS_EMITTED');
        } else if (cmd == 'EXIT') {
          exit(0);
        }
      });
}
''');

        try {
          final pty = Pty2Session.start(
            Platform.resolvedExecutable,
            [scriptFile.path],
            initialCols: 80,
            initialRows: 24,
          );
          caster = CasterService(
            config: CasterConfig(
              serverUri: server.casterUri,
              token: 'caster-tok',
              sessionId: sessionId,
              title: 'signal-init',
              command: const ['dart'],
            ),
            pty: pty,
          );
          await caster.start();
          await _waitUntil(() => server.registry.sessions.length == 1);

          repo = CastClientRepository(
            transport: WsClientTransport(
              serverUri: server.clientUri,
              token: 'client-tok',
            ),
          );
          await repo.connect();

          final titles = <String>[];
          var bellEvents = 0;
          final audioEvents = <TerminalAudioEvent>[];
          final streamTitles = <ShellTitleFrame>[];
          final streamBells = <BellFrame>[];
          final streamAudios = <AudioFrame>[];
          final titleSub = repo.shellTitleFrames.listen(streamTitles.add);
          final bellSub = repo.bellFrames.listen(streamBells.add);
          final audioSub = repo.audioFrames.listen(streamAudios.add);
          addTearDown(() async {
            await titleSub.cancel();
            await bellSub.cancel();
            await audioSub.cancel();
          });

          port1 = repo.openTerminalPort(
            sessionId,
            portId: 'left',
            initialCols: 90,
            initialRows: 28,
          );
          port1.addTitleListener(titles.add);
          port1.addBellListener(() => bellEvents++);
          port1.addAudioListener(audioEvents.add);

          await _waitUntil(
            () => _bufferText(port1!.buffer).contains('SIGNAL_READY'),
          );
          check(repo.attachedPortCount(sessionId)).equals(1);

          // Attaching a smaller split pane shrinks PTY to (72, 22) and notifies
          // activePtySize while preserving shared session state.
          port2 = repo.openTerminalPort(
            sessionId,
            portId: 'right',
            initialCols: 72,
            initialRows: 22,
          );
          check(repo.attachedPortCount(sessionId)).equals(2);
          await _waitUntil(
            () =>
                caster!.terminal.cols == 72 &&
                caster.terminal.rows == 22 &&
                port1!.activePtySize == (72, 22),
          );

          port1.sendInput(Uint8List.fromList(utf8.encode('SIGNALS\r\n')));
          await _waitUntil(
            () =>
                titles.contains('Live Signal Shell') &&
                bellEvents >= 1 &&
                audioEvents.isNotEmpty &&
                _bufferText(port1!.buffer).contains('SIGNALS_EMITTED'),
          );
          check(port1.shellTitle).equals('Live Signal Shell');
          check(port1.displayTitle).equals('Live Signal Shell');
          check(port2.bellCount).equals(bellEvents);
          check(streamTitles.last.title).equals('Live Signal Shell');
          check(streamBells.isNotEmpty).isTrue();
          check(streamAudios.isNotEmpty).isTrue();
          final audioEvent = audioEvents.single;
          check(audioEvent).isA<TerminalToneAudioEvent>()
            ..has((e) => e.waveform, 'waveform').equals('sine')
            ..has((e) => e.frequencyHz, 'frequencyHz').equals(523.0);

          // Closing port2 (2 -> 1) must NOT unsubscribe; PTY expands to 90x28.
          await port2.dispose();
          port2 = null;
          check(repo.attachedPortCount(sessionId)).equals(1);
          await _waitUntil(
            () => caster!.terminal.cols == 90 && caster.terminal.rows == 28,
          );

          // Clean exit completes port1.exitCode and closing last port unsubscribes.
          port1.sendInput(Uint8List.fromList(utf8.encode('EXIT\r\n')));
          final exitCode = await port1.exitCode;
          check(const [0, -1]).contains(exitCode);

          await port1.dispose();
          port1 = null;
          check(repo.attachedPortCount(sessionId)).equals(0);
        } finally {
          await port2?.dispose();
          await port1?.dispose();
          await repo?.dispose();
          await caster?.stop(killPty: true);
          await server.close();
        }
      },
    );

    test(
      'live 3-way viewer requestSpawnSession spawns child shell via CasterSupervisor into SessionDirectoryFrame',
      () async {
        final server = await CastServer.bind(
          ServerConfig(
            host: InternetAddress.loopbackIPv4,
            port: 0,
            casterToken: 'caster-tok',
            clientToken: 'client-tok',
          ),
        );
        const primaryId = SessionId('spawn-primary');
        final startedPtys = <_E2eFakePtySession>[];
        CasterSupervisor? supervisor;
        CastClientRepository? repo;
        RemoteTerminalPort? childPort;
        void Function(CastMessage)? dirListener;

        try {
          supervisor = CasterSupervisor(
            primaryConfig: CasterConfig(
              serverUri: server.casterUri,
              token: 'caster-tok',
              sessionId: primaryId,
              title: 'zsh',
              initialCols: 80,
              initialRows: 24,
              command: const ['/bin/zsh'],
            ),
            environment: const <String, String>{'SHELL': '/bin/zsh'},
            isWindows: false,
            random: Random(19),
            ptyStarter: (config) async {
              final pty = _E2eFakePtySession(tag: config.title);
              startedPtys.add(pty);
              return pty;
            },
          );
          check(await supervisor.start()).isTrue();
          await _waitUntil(
            () => server.registry.sessions.any(
              (s) => s.id == primaryId && s.allowSpawn,
            ),
          );

          repo = CastClientRepository(
            transport: WsClientTransport(
              serverUri: server.clientUri,
              token: 'client-tok',
            ),
            enableReconnect: false,
          );
          final latestDirectory = <SessionSummary>[];
          dirListener = (msg) {
            if (msg is SessionDirectoryFrame) {
              latestDirectory
                ..clear()
                ..addAll(msg.sessions);
            }
          };
          clientMessageReceivedEvent.addListener(repo.bus, dirListener);
          await repo.connect();
          await _waitUntil(
            () => latestDirectory.any((s) => s.id == primaryId && s.allowSpawn),
          );

          check(repo.requestSpawnSession(primaryId)).isTrue();
          await _waitUntil(() => latestDirectory.length == 2);

          final spawnedSummary = latestDirectory.singleWhere(
            (s) => s.id != primaryId,
          );
          check(spawnedSummary.title).equals('zsh #2');
          check(spawnedSummary.allowSpawn).isTrue();
          check(startedPtys.length).equals(2);

          // Viewer can open a RemoteTerminalPort on the spawned child and exchange I/O.
          childPort = repo.openTerminalPort(
            spawnedSummary.id,
            initialCols: 80,
            initialRows: 24,
          );
          await _waitUntil(() => childPort!.slot.state == .synchronized);
          startedPtys[1].emitText('BOOT:zsh #2\r\n');
          await _waitUntil(
            () => _bufferText(childPort!.buffer).contains('BOOT:zsh #2'),
          );
          childPort.sendInput(Uint8List.fromList(utf8.encode('hello-child\r')));
          await _waitUntil(
            () => startedPtys[1].writtenText.contains('hello-child'),
          );
        } finally {
          if (repo != null && dirListener != null) {
            clientMessageReceivedEvent.removeListener(repo.bus, dirListener);
          }
          await childPort?.dispose();
          await repo?.dispose();
          await supervisor?.stop(killPty: true);
          await server.close();
        }
      },
    );
  });
}

final class _E2eFakePtySession implements PtySession {
  final String tag;
  final StreamController<Uint8List> _output =
      StreamController<Uint8List>.broadcast();
  final Completer<int> _exitCode = Completer<int>();
  final StringBuffer _written = StringBuffer();

  _E2eFakePtySession({required this.tag});

  String get writtenText => '$_written';

  void emitText(String text) {
    if (!_output.isClosed) {
      _output.add(Uint8List.fromList(utf8.encode(text)));
    }
  }

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  void writeBytes(Uint8List data) {
    _written.write(utf8.decode(data, allowMalformed: true));
  }

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}

  @override
  bool kill([ProcessSignal signal = .sigterm]) {
    if (!_output.isClosed) unawaited(_output.close());
    if (!_exitCode.isCompleted) _exitCode.complete(-1);
    return true;
  }
}

final class _ThrowingDroppedFileSource implements DroppedFileSource {
  @override
  final String name;

  @override
  final int size;

  const _ThrowingDroppedFileSource({required this.name, required this.size});

  @override
  bool get isDirectory => false;

  @override
  Future<Uint8List> readSlice(int start, int end) async {
    throw StateError('Simulated Blob read failure');
  }
}
