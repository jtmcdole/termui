import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pty2/pty2.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:test/test.dart';

final class _FakeAckPseudoTerminal implements PseudoTerminal {
  final StreamController<String> _outController = StreamController<String>();
  final Completer<int> _exitCompleter = Completer<int>();
  Completer<void>? ackCompleter;
  int ackCount = 0;

  @override
  void init() {}

  @override
  Stream<String> get out => _outController.stream;

  @override
  Future<int> get exitCode => _exitCompleter.future;

  @override
  void write(String input) {}

  @override
  void resize(
    int width,
    int height, {
    int pixelWidth = 0,
    int pixelHeight = 0,
  }) {}

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exitCompleter.isCompleted) {
      _exitCompleter.complete(0);
    }
    return true;
  }

  @override
  void ackProcessed() {
    ackCount++;
    final waiter = ackCompleter;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
  }

  void emitChunk(String chunk) => _outController.add(chunk);

  Future<void> close() async {
    if (!_exitCompleter.isCompleted) {
      _exitCompleter.complete(0);
    }
    if (!_outController.isClosed) {
      await _outController.close();
    }
  }
}

final class _TearOffObserver {
  int changes = 0;
  final List<String> titles = [];
  int bells = 0;
  final List<TerminalAudioEvent> audios = [];
  final List<(String, String)> clipboards = [];

  void onChange() => changes++;
  void onTitle(String title) => titles.add(title);
  void onBell() => bells++;
  void onAudio(TerminalAudioEvent event) => audios.add(event);
  void onClipboard(String selection, String text) =>
      clipboards.add((selection, text));
}

final class _FakeRoutedPtyBackend implements RoutedPtyBackend {
  final StreamController<Uint8List> _outputController =
      StreamController<Uint8List>();
  final Completer<int> _exitCompleter = Completer<int>();
  final List<Uint8List> writtenChunks = [];
  final List<({int cols, int rows, int pixelWidth, int pixelHeight})> resizes =
      [];
  bool killed = false;
  bool disposed = false;

  @override
  Stream<Uint8List> get output => _outputController.stream;

  @override
  Future<int> get exitCode => _exitCompleter.future;

  @override
  void write(Uint8List bytes) {
    writtenChunks.add(Uint8List.fromList(bytes));
  }

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {
    resizes.add((
      cols: cols,
      rows: rows,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
    ));
  }

  @override
  void kill() {
    killed = true;
    if (!_exitCompleter.isCompleted) {
      _exitCompleter.complete(0);
    }
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    if (!_outputController.isClosed) {
      await _outputController.close();
    }
  }

  void emitOutput(String text) {
    _outputController.add(Uint8List.fromList(utf8.encode(text)));
  }

  String get writtenText =>
      utf8.decode([for (final chunk in writtenChunks) ...chunk]);
}

void main() {
  group('PtyRouter and TerminalPort', () {
    test(
      'answers DA1 and OSC 11 queries exactly once regardless of attached ports',
      () async {
        final backend = _FakeRoutedPtyBackend();
        final router = PtyRouter();
        final session = router.createSession(id: 'sess-1', backend: backend);
        final port1 = session.openPort();
        final port2 = session.openPort();
        final bytePipe = session.openBytePipe(sync: true);
        addTearDown(router.dispose);

        backend.emitOutput('\x1b[c\x1b]11;?\x07');
        await Future<void>.delayed(Duration.zero);

        expect(backend.writtenChunks, hasLength(2));
        expect(backend.writtenChunks[0], equals(utf8.encode('\x1b[?62;22c')));
        expect(
          utf8.decode(backend.writtenChunks[1]),
          startsWith('\x1b]11;rgb:'),
        );

        await port1.dispose();
        await port2.dispose();
        await bytePipe.close();
      },
    );

    test(
      'isolates throwing observer listeners and unregisters disposed port listeners',
      () async {
        final backend = _FakeRoutedPtyBackend();
        final router = PtyRouter();
        final session = router.createSession(backend: backend);
        final throwingPort = session.openPort();
        final healthyPort = session.openPort();
        addTearDown(router.dispose);

        throwingPort
          ..addListener(() => throw StateError('change'))
          ..addTitleListener((_) => throw StateError('title'))
          ..addBellListener(() => throw StateError('bell'))
          ..addAudioListener((_) => throw StateError('audio'))
          ..addClipboardListener((_, _) => throw StateError('clipboard'));

        var changeCount = 0;
        final titles = <String>[];
        var bells = 0;
        final audios = <TerminalAudioEvent>[];
        final clipboards = <(String, String)>[];

        healthyPort
          ..addListener(() => changeCount++)
          ..addTitleListener(titles.add)
          ..addBellListener(() => bells++)
          ..addAudioListener(audios.add)
          ..addClipboardListener((sel, text) => clipboards.add((sel, text)));

        backend.emitOutput(
          'hello\x1b]2;MyShell\x07\x07'
          '\x1b_Aa=tone,w=sine,f=440,d=100;\x1b\\'
          '\x1b]52;c;aGVsbG8=\x07',
        );
        await Future<void>.delayed(Duration.zero);

        expect(changeCount, greaterThanOrEqualTo(1));
        expect(titles, equals(['MyShell']));
        expect(bells, equals(1));
        expect(audios, hasLength(1));
        expect(clipboards, equals([('c', 'hello')]));

        // Disposing throwingPort keeps healthyPort and session operational.
        await throwingPort.dispose();
        backend.emitOutput('\x07');
        await Future<void>.delayed(Duration.zero);
        expect(bells, equals(2));
        await healthyPort.dispose();
      },
    );

    test(
      'supports mid-session port & byte pipe attachment with warm scrollback',
      () async {
        final backend = _FakeRoutedPtyBackend();
        final router = PtyRouter();
        final session = router.createSession(
          backend: backend,
          initialCols: 12,
          initialRows: 3,
          maxScrollbackLines: 50,
        );
        addTearDown(router.dispose);

        for (var i = 0; i < 8; i++) {
          backend.emitOutput('Line-$i\r\n');
        }
        await Future<void>.delayed(Duration.zero);

        // Attach port and raw byte pipe mid-session.
        final port = session.openPort();
        final pipe = session.openBytePipe(sync: true);
        final pipedChunks = <String>[];
        final sub = pipe.stream.listen((b) => pipedChunks.add(utf8.decode(b)));
        addTearDown(sub.cancel);

        expect(port.scrollbackWindow.totalLines, greaterThan(0));
        final slice = port.readScrollbackSlice(
          port.scrollbackWindow.oldestLine,
          port.scrollbackWindow.totalLines,
        );
        expect(slice, isNotEmpty);
        expect(slice.first?.characters.join(), startsWith('Line-0'));

        port.sendInput(Uint8List.fromList(utf8.encode('pwd\n')));
        pipe.sink.add(Uint8List.fromList(utf8.encode('ls\n')));
        backend.emitOutput('after-attach');
        await Future<void>.delayed(Duration.zero);

        expect(backend.writtenText, equals('pwd\nls\n'));
        expect(pipedChunks.join(), equals('after-attach'));

        await pipe.close();
        await port.dispose();
      },
    );

    test(
      'clamps to smallest viewport, scales pixels, clamps uint16, and restores on detach',
      () async {
        final backend = _FakeRoutedPtyBackend();
        final router = PtyRouter();
        final session = router.createSession(backend: backend);
        final localPort = session.openPort(isPrimary: true);
        addTearDown(router.dispose);

        localPort.setViewportSize(
          120,
          40,
          cellPixelWidth: 9,
          cellPixelHeight: 18,
        );
        expect(session.cols, equals(120));
        expect(session.rows, equals(40));
        expect(localPort.activePtySize, equals((120, 40)));
        expect(
          backend.resizes.last,
          equals((cols: 120, rows: 40, pixelWidth: 1080, pixelHeight: 720)),
        );

        // Non-positive sizes are ignored safely.
        localPort.setViewportSize(0, 0);
        expect(session.cols, equals(120));
        expect(session.rows, equals(40));

        // Smaller remote viewer clamps cols/rows while scaling via primary cell px.
        session.setEndpointViewport('viewer-1', 80, 24);
        expect(session.cols, equals(80));
        expect(session.rows, equals(24));
        expect(localPort.activePtySize, equals((80, 24)));
        expect(
          backend.resizes.last,
          equals((cols: 80, rows: 24, pixelWidth: 720, pixelHeight: 432)),
        );

        // Even smaller second viewer clamps cols further while rows remain 24.
        session.setEndpointViewport('viewer-2', 60, 30);
        expect(session.cols, equals(60));
        expect(session.rows, equals(24));
        expect(
          backend.resizes.last,
          equals((cols: 60, rows: 24, pixelWidth: 540, pixelHeight: 432)),
        );

        // Detaching viewers restores size step-by-step.
        session.removeEndpointViewport('viewer-2');
        expect(
          backend.resizes.last,
          equals((cols: 80, rows: 24, pixelWidth: 720, pixelHeight: 432)),
        );

        session.removeEndpointViewport('viewer-1');
        expect(session.cols, equals(120));
        expect(session.rows, equals(40));
        expect(
          backend.resizes.last,
          equals((cols: 120, rows: 40, pixelWidth: 1080, pixelHeight: 720)),
        );

        // Pixel product clamps cleanly at uint16 max (65535).
        localPort.setViewportSize(
          5000,
          4000,
          cellPixelWidth: 20,
          cellPixelHeight: 20,
        );
        expect(
          backend.resizes.last,
          equals((
            cols: 5000,
            rows: 4000,
            pixelWidth: 65535,
            pixelHeight: 65535,
          )),
        );
        await localPort.dispose();
      },
    );

    test(
      'RouterBytePipe.duplex cross-wires local and remote streams',
      () async {
        final (a, b) = RouterBytePipe.duplex(sync: true);
        final aSeen = <String>[];
        final bSeen = <String>[];
        final subA = a.stream.listen((d) => aSeen.add(utf8.decode(d)));
        final subB = b.stream.listen((d) => bSeen.add(utf8.decode(d)));
        addTearDown(() async {
          await subA.cancel();
          await subB.cancel();
        });

        a.sink.add(Uint8List.fromList(utf8.encode('ping')));
        b.sink.add(Uint8List.fromList(utf8.encode('pong')));

        expect(bSeen, equals(['ping']));
        expect(aSeen, equals(['pong']));

        await a.close();
        await b.close();
        expect(a.isClosed, isTrue);
        expect(b.isClosed, isTrue);
      },
    );

    if (!Platform.isWindows) {
      test('Pty2RoutedBackend integrates with PtyRouter end-to-end', () async {
        final backend = Pty2RoutedBackend.start(
          '/bin/sh',
          ['-c', 'printf "hello-tpr\\n"'],
          initialCols: 40,
          initialRows: 10,
          pixelWidth: 320,
          pixelHeight: 160,
        );
        final router = PtyRouter();
        final session = router.createSession(
          backend: backend,
          initialCols: 40,
          initialRows: 10,
        );
        final port = session.openPort(
          initialCols: 40,
          initialRows: 10,
          cellPixelWidth: 8,
          cellPixelHeight: 16,
        );

        final code = await port.exitCode;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(code, equals(0));
        expect(port.buffer.characters.join(), contains('hello-tpr'));

        await port.dispose();
        await router.dispose();
      });
    }

    test(
      'equal tear-off listeners across sibling ports stay active after disposing one port',
      () async {
        final backend = _FakeRoutedPtyBackend();
        final router = PtyRouter();
        final session = router.createSession(id: 'sess-tear', backend: backend);
        final port1 = session.openPort();
        final port2 = session.openPort();
        addTearDown(router.dispose);

        final observer = _TearOffObserver();
        for (final port in [port1, port2]) {
          port
            ..addListener(observer.onChange)
            ..addTitleListener(observer.onTitle)
            ..addBellListener(observer.onBell)
            ..addAudioListener(observer.onAudio)
            ..addClipboardListener(observer.onClipboard);
        }

        await port1.dispose();

        backend.emitOutput(
          'hi\x1b]2;Surviving\x07\x07'
          '\x1b_Aa=tone,w=sine,f=440,d=100;\x1b\\'
          '\x1b]52;c;dGVzdA==\x07',
        );
        await Future<void>.delayed(Duration.zero);

        expect(observer.changes, greaterThanOrEqualTo(1));
        expect(observer.titles, equals(['Surviving']));
        expect(observer.bells, equals(1));
        expect(observer.audios, hasLength(1));
        expect(observer.clipboards, equals([('c', 'test')]));
        await port2.dispose();
      },
    );

    test(
      'rejects duplicate explicit portId, skips colliding auto-IDs, and namespaces port viewports',
      () async {
        final backend = _FakeRoutedPtyBackend();
        final router = PtyRouter();
        final session = router.createSession(id: 'sess-ids', backend: backend);
        addTearDown(router.dispose);

        final p1 = session.openPort(portId: 'port-1');
        expect(p1.id, equals('sess-ids:port-1'));
        expect(() => session.openPort(portId: 'port-1'), throwsArgumentError);

        final p2 = session.openPort();
        expect(p2.id, equals('sess-ids:port-2'));

        // External endpoint named 'port-1' must not collide with p1's viewport.
        p1.setViewportSize(60, 20);
        session.setEndpointViewport('port-1', 100, 30);
        expect(session.cols, equals(60));
        expect(session.rows, equals(20));
        session.removeEndpointViewport('port-1');
        expect(session.cols, equals(60));
        expect(session.rows, equals(20));

        await p1.dispose();
        await p2.dispose();

        // Re-opening after dispose succeeds.
        final reopened = session.openPort(portId: 'port-1');
        expect(reopened.id, equals('sess-ids:port-1'));
        await reopened.dispose();
      },
    );

    test(
      'Pty2RoutedBackend schedules ack even when a synchronous output listener throws',
      () async {
        final fakePty = _FakeAckPseudoTerminal();
        final backend = Pty2RoutedBackend.wrap(fakePty, ackProcessed: true);
        addTearDown(() async {
          await backend.dispose();
          await fakePty.close();
        });

        final errors = <Object>[];
        final received = <String>[];
        final secondReceived = Completer<void>();

        await runZonedGuarded(
          () async {
            final sub = backend.output.listen((bytes) {
              final text = utf8.decode(bytes);
              if (text == 'first') {
                throw StateError('listener failure');
              }
              received.add(text);
              if (text == 'second' && !secondReceived.isCompleted) {
                secondReceived.complete();
              }
            });
            addTearDown(sub.cancel);

            fakePty.ackCompleter = Completer<void>();
            fakePty.emitChunk('first');
            await fakePty.ackCompleter!.future.timeout(
              const Duration(seconds: 2),
            );
            expect(fakePty.ackCount, equals(1));

            fakePty.ackCompleter = Completer<void>();
            fakePty.emitChunk('second');
            await secondReceived.future.timeout(const Duration(seconds: 2));
            await fakePty.ackCompleter!.future.timeout(
              const Duration(seconds: 2),
            );
          },
          (error, _) {
            errors.add(error);
          },
        );

        expect(errors, hasLength(1));
        expect(received, equals(['second']));
        expect(fakePty.ackCount, equals(2));
      },
    );

    test(
      'Pty2RoutedBackend.dispose escalates to SIGKILL when child ignores SIGTERM/SIGHUP',
      () async {
        final backend = Pty2RoutedBackend.start('/bin/sh', const [
          '-c',
          'trap "" TERM HUP; printf "READY\\n"; sleep 30',
        ]);
        final ready = Completer<void>();
        final sub = backend.output.listen((chunk) {
          if (utf8.decode(chunk).contains('READY') && !ready.isCompleted) {
            ready.complete();
          }
        });
        addTearDown(sub.cancel);
        await ready.future.timeout(const Duration(seconds: 5));

        final sw = Stopwatch()..start();
        await backend.dispose().timeout(const Duration(seconds: 3));
        final exitCode = await backend.exitCode.timeout(
          const Duration(seconds: 2),
        );
        expect(exitCode, isNot(equals(0)));
        expect(sw.elapsedMilliseconds, lessThan(2000));
      },
      testOn: 'posix',
    );

    test(
      'Pty2RoutedBackend.buildChildEnvironment enables TERMUI_AUDIO_APC=1 unless overridden',
      () {
        final env = Pty2RoutedBackend.buildChildEnvironment(
          baseEnvironment: const {'PATH': '/usr/bin', 'TMUX': 'strip-me'},
        );
        expect(
          env,
          equals({
            'PATH': '/usr/bin',
            'TERM': 'xterm-256color',
            'TERMUI_AUDIO_APC': '1',
          }),
        );

        final hostOptOut = Pty2RoutedBackend.buildChildEnvironment(
          baseEnvironment: const {'PATH': '/usr/bin', 'TERMUI_AUDIO_APC': '0'},
        );
        expect(hostOptOut['TERMUI_AUDIO_APC'], equals('0'));

        final overrideOptOut = Pty2RoutedBackend.buildChildEnvironment(
          baseEnvironment: const {'PATH': '/usr/bin'},
          overrides: const {'TERMUI_AUDIO_APC': '0'},
        );
        expect(overrideOptOut['TERMUI_AUDIO_APC'], equals('0'));
      },
    );
  });
}
