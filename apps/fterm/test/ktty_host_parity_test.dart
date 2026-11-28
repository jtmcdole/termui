import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/workspace/fterm_pane_controller.dart';
import 'package:fterm/src/workspace/local_host_driver_io.dart';
import 'package:path/path.dart' as p;
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart'
    show TerminalColorResolver, TerminalThemeSettings;
import 'package:termui_cast_protocol/termui_cast_protocol.dart' show SessionId;
import 'package:termui_pty/termui_pty.dart';

final class _RecordingRoutedPtyBackend implements RoutedPtyBackend {
  final StreamController<Uint8List> _output =
      StreamController<Uint8List>.broadcast(sync: true);
  final Completer<int> _exitCode = Completer<int>();
  final List<String> writtenReplies = <String>[];

  void emitAnsi(String payload) {
    if (!_output.isClosed) {
      _output.add(Uint8List.fromList(utf8.encode(payload)));
    }
  }

  String get joinedReplies => writtenReplies.join();

  void clearReplies() => writtenReplies.clear();

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  void write(Uint8List bytes) {
    writtenReplies.add(utf8.decode(bytes, allowMalformed: true));
  }

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}

  @override
  void kill() {
    if (!_exitCode.isCompleted) _exitCode.complete(0);
  }

  @override
  Future<void> dispose() async {
    kill();
    if (!_output.isClosed) {
      await _output.close();
    }
  }
}

TerminalColorResolver _resolverFor(tui.TerminalColorTheme theme) =>
    TerminalColorResolver(
      theme: theme,
      settings: const TerminalThemeSettings(),
    );

void main() {
  group('fterm KTTY host parity', () {
    test('setColorScheme via FtermPaneController.setColorResolver emits CSI ? 997 ; 2 n when DECSET 2031 is enabled', () async {
      final backend = _RecordingRoutedPtyBackend();
      final driver = IoLocalHostDriver(
        backendFactory: ({
          required executable,
          required arguments,
          required initialCols,
          required initialRows,
          required pixelWidth,
          required pixelHeight,
          workingDirectory,
          environment,
        }) => backend,
        isWindows: false,
      );
      final host = await driver.openShell(
        const LocalShellConfig(
          executable: '/bin/sh',
          initialCols: 40,
          initialRows: 12,
          colorScheme: .dark,
        ),
      );
      final pane = FtermPaneController(
        paneId: 'theme-pane',
        port: host.port,
        localHost: host,
        colorResolver: _resolverFor(tui.TerminalColorTheme.termuiDark),
        resizeDebounce: Duration.zero,
      );
      addTearDown(() async {
        await pane.dispose();
        await driver.dispose();
      });

      // Subscribe to DECSET 2031 color scheme change notifications.
      backend.emitAnsi('\x1b[?2031h');
      backend.clearReplies();

      // Transition dark -> light: must emit CSI ? 997 ; 2 n.
      pane.setColorResolver(_resolverFor(tui.TerminalColorTheme.termuiLight));
      expect(backend.writtenReplies, equals(['\x1b[?997;2n']));

      // Redundant light -> light update emits nothing.
      backend.clearReplies();
      pane.setColorResolver(
        _resolverFor(tui.TerminalColorTheme.solarizedLight),
      );
      expect(backend.writtenReplies, isEmpty);

      // Transition light -> dark: must emit CSI ? 997 ; 1 n.
      pane.setColorResolver(_resolverFor(tui.TerminalColorTheme.termuiDark));
      expect(backend.writtenReplies, equals(['\x1b[?997;1n']));

      // Disabling DECSET 2031 suppresses subsequent unsolicited reports.
      backend.emitAnsi('\x1b[?2031l');
      backend.clearReplies();
      pane.setColorResolver(_resolverFor(tui.TerminalColorTheme.termuiLight));
      expect(backend.writtenReplies, isEmpty);
    });

    test('OSC 5522 base64 text/plain writes route to pane onClipboard with status=DONE while type=read replies status=EPERM', () async {
      final backend = _RecordingRoutedPtyBackend();
      final driver = IoLocalHostDriver(
        backendFactory: ({
          required executable,
          required arguments,
          required initialCols,
          required initialRows,
          required pixelWidth,
          required pixelHeight,
          workingDirectory,
          environment,
        }) => backend,
        isWindows: false,
      );
      final host = await driver.openShell(
        const LocalShellConfig(
          executable: '/bin/sh',
          initialCols: 40,
          initialRows: 12,
        ),
      );
      final clipboardWrites =
          <(String paneId, String selection, String text)>[];
      final pane = FtermPaneController(
        paneId: 'clip-pane',
        port: host.port,
        localHost: host,
        colorResolver: _resolverFor(tui.TerminalColorTheme.termuiDark),
        resizeDebounce: Duration.zero,
        onClipboard: (paneId, selection, text) {
          clipboardWrites.add((paneId, selection, text));
        },
      );
      addTearDown(() async {
        await pane.dispose();
        await driver.dispose();
      });

      const plainMimeB64 = 'dGV4dC9wbGFpbg==';
      final secretB64 = base64Encode(utf8.encode('secret clipboard token'));

      // Single-shot write to system clipboard.
      backend.emitAnsi(
        '\x1b]5522;type=write:mime=$plainMimeB64;$secretB64\x1b\\',
      );
      expect(
        clipboardWrites,
        equals([('clip-pane', 'c', 'secret clipboard token')]),
      );
      expect(
        backend.writtenReplies,
        equals(['\x1b]5522;type=write:status=DONE\x1b\\']),
      );

      // Chunked write to primary selection with request id.
      backend.clearReplies();
      final part1 = base64Encode(utf8.encode('chunked '));
      final part2 = base64Encode(utf8.encode('ktty text'));
      backend.emitAnsi(
        '\x1b]5522;type=write:loc=primary:id=w42;\x1b\\'
        '\x1b]5522;type=wdata:mime=$plainMimeB64;$part1\x1b\\'
        '\x1b]5522;type=wdata;$part2\x1b\\'
        '\x1b]5522;type=wdata;\x1b\\',
      );
      expect(
        clipboardWrites,
        equals([
          ('clip-pane', 'c', 'secret clipboard token'),
          ('clip-pane', 'p', 'chunked ktty text'),
        ]),
      );
      expect(
        backend.writtenReplies,
        equals(['\x1b]5522;type=write:status=DONE:id=w42\x1b\\']),
      );

      // Read attempts must reply status=EPERM and never leak clipboard contents.
      backend.clearReplies();
      backend.emitAnsi(
        '\x1b]5522;type=read:id=r7;\x1b\\'
        '\x1b]5522;type=read:loc=primary;\x1b\\',
      );
      expect(
        backend.writtenReplies,
        equals([
          '\x1b]5522;type=read:status=EPERM:id=r7\x1b\\',
          '\x1b]5522;type=read:status=EPERM\x1b\\',
        ]),
      );
      expect(backend.joinedReplies, isNot(contains('secret clipboard token')));
      expect(backend.joinedReplies, isNot(contains('chunked ktty text')));
      expect(clipboardWrites, hasLength(2));
    });

    test('local IoLocalHostDriver enables non-unlinking t=f uploads while default/remote PtyRouter sessions reject t=f', () async {
      final tempDir = Directory.systemTemp.createTempSync('fterm_ktty_tf_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      final rgba = Uint8List.fromList([
        255, 0, 0, 255, // (0,0) red
        0, 255, 0, 255, // (1,0) green
        0, 0, 255, 255, // (0,1) blue
        255, 255, 0, 255, // (1,1) yellow
      ]);
      final imageFile = File(p.join(tempDir.path, 'local_sample.rgba'))
        ..writeAsBytesSync(rgba);
      final pathB64 = base64Encode(utf8.encode(imageFile.path));

      // 1. Local desktop host opts in to allowLocalKittyFiles: true.
      final localBackend = _RecordingRoutedPtyBackend();
      final driver = IoLocalHostDriver(
        backendFactory: ({
          required executable,
          required arguments,
          required initialCols,
          required initialRows,
          required pixelWidth,
          required pixelHeight,
          workingDirectory,
          environment,
        }) => localBackend,
        isWindows: false,
      );
      final localHost = await driver.openShell(
        const LocalShellConfig(
          executable: '/bin/sh',
          initialCols: 20,
          initialRows: 6,
        ),
      );
      final localPane = FtermPaneController(
        paneId: 'local-tf-pane',
        port: localHost.port,
        localHost: localHost,
        colorResolver: _resolverFor(tui.TerminalColorTheme.termuiDark),
        resizeDebounce: Duration.zero,
      );
      addTearDown(() async {
        await localPane.dispose();
        await driver.dispose();
      });

      localBackend.emitAnsi('\x1b_Ga=q,i=70,t=f,f=32,s=2,v=2;$pathB64\x1b\\');
      expect(localBackend.writtenReplies, equals(['\x1b_Gi=70;OK\x1b\\']));
      expect(imageFile.existsSync(), isTrue);

      localBackend.clearReplies();
      localBackend.emitAnsi('\x1b_Ga=t,i=71,t=f,f=32,s=2,v=2;$pathB64\x1b\\');
      expect(localBackend.writtenReplies, equals(['\x1b_Gi=71;OK\x1b\\']));
      expect(imageFile.existsSync(), isTrue);
      final uploaded = localPane.readDisplayBuffer().lookupKittyImage(0, 0, 71);
      expect(uploaded, isNotNull);
      expect(uploaded!.pixelWidth, equals(2));
      expect(uploaded.pixelHeight, equals(2));
      expect(uploaded.rgbaPixels, equals(rgba));

      // 2. Default / remote PtyRouter session keeps allowLocalKittyFiles=false.
      final remoteBackend = _RecordingRoutedPtyBackend();
      final remoteRouter = PtyRouter();
      final remoteSession = remoteRouter.createSession(
        backend: remoteBackend,
        initialCols: 20,
        initialRows: 6,
      );
      final remotePort = remoteSession.openPort(
        initialCols: 20,
        initialRows: 6,
      );
      final remotePane = FtermPaneController(
        paneId: 'remote-tf-pane',
        port: remotePort,
        colorResolver: _resolverFor(tui.TerminalColorTheme.termuiDark),
        resizeDebounce: Duration.zero,
      );
      addTearDown(() async {
        await remotePane.dispose(disposePort: false);
        await remotePort.dispose();
        await remoteRouter.dispose();
      });

      remoteBackend.emitAnsi('\x1b_Ga=t,i=72,t=f,f=32,s=2,v=2;$pathB64\x1b\\');
      expect(
        remoteBackend.writtenReplies,
        equals(['\x1b_Gi=72;EINVAL:unsupported transmission medium\x1b\\']),
      );
      expect(imageFile.existsSync(), isTrue);
      expect(remotePane.readDisplayBuffer().lookupKittyImage(0, 0, 72), isNull);
    });

    test('FtermPaneController preserves OSC 66 text sizing across scrollback recomposition', () async {
      final backend = _RecordingRoutedPtyBackend();
      final router = PtyRouter();
      final session = router.createSession(
        backend: backend,
        initialCols: 16,
        initialRows: 4,
        maxScrollbackLines: 20,
      );
      final port = session.openPort(initialCols: 16, initialRows: 4);
      final pane = FtermPaneController(
        paneId: 'osc66-scroll-pane',
        port: port,
        colorResolver: _resolverFor(tui.TerminalColorTheme.termuiDark),
        resizeDebounce: Duration.zero,
      );
      addTearDown(() async {
        await pane.dispose(disposePort: false);
        await port.dispose();
        await router.dispose();
      });

      backend.emitAnsi(
        '\x1b]66;s=2;H\x1b\\\r\n\r\nline1\r\nline2\r\nline3\r\n',
      );
      pane.scrollLines(2);

      final scrolledBuf = pane.readDisplayBuffer();
      expect(scrolledBuf.hasTextSizing, isTrue);
      final anchor = tui.KittyTextSizing(scrolledBuf.getTextSizing(0, 0));
      expect(anchor.isAnchor, isTrue);
      expect(anchor.scale, equals(2));
      expect(scrolledBuf.getCharacter(0, 0), equals('H'));
      final cont = tui.KittyTextSizing(scrolledBuf.getTextSizing(1, 1));
      expect(cont.isContinuation, isTrue);
      expect(cont.originDx, equals(1));
      expect(cont.originDy, equals(1));
    });

    test('FtermPaneController syncs KittyImageRegistry.viewportScrollOffset during scrollback for local panes without mutating remote panes', () async {
      final backend = _RecordingRoutedPtyBackend();
      final driver = IoLocalHostDriver(
        backendFactory: ({
          required executable,
          required arguments,
          required initialCols,
          required initialRows,
          required pixelWidth,
          required pixelHeight,
          workingDirectory,
          environment,
        }) => backend,
        isWindows: false,
      );
      final host = await driver.openShell(
        const LocalShellConfig(
          executable: '/bin/sh',
          initialCols: 16,
          initialRows: 4,
          maxScrollbackLines: 20,
        ),
      );
      final pane = FtermPaneController(
        paneId: 'kitty-scroll-pane',
        port: host.port,
        localHost: host,
        colorResolver: _resolverFor(tui.TerminalColorTheme.termuiDark),
        resizeDebounce: Duration.zero,
      );
      addTearDown(() async {
        await pane.dispose(disposePort: false);
        await driver.dispose();
      });

      final pxB64 = base64Encode(Uint8List.fromList([10, 20, 30, 255]));
      // Place a layered direct Kitty image (z=-1) at row 0, then push it into scrollback.
      backend.emitAnsi(
        '\x1b[1;1H\x1b_Ga=T,i=80,p=1,f=32,s=1,v=1,c=2,r=2,z=-1,C=1;$pxB64\x1b\\'
        'r0\r\nr1\r\nr2\r\nr3\r\nr4\r\nr5\r\n',
      );

      final liveBuf = pane.readDisplayBuffer();
      final registry = liveBuf.lookupKittyRegistry(0, 0);
      expect(identical(registry, tui.KittyImageRegistry.global), isFalse);
      final placement = registry.lookupPlacement(80, 1);
      expect(placement, isNotNull);
      expect(placement!.isVirtual, isFalse);
      expect(placement.zIndex, equals(-1));
      expect(placement.gridRow, lessThan(0));
      expect(registry.viewportScrollOffset, equals(0));

      // Scroll back up so the placement shifts back into visible viewport rows.
      final scrollNeeded = -placement.gridRow;
      pane.scrollLines(scrollNeeded);
      final scrolledBuf = pane.readDisplayBuffer();
      expect(
        identical(scrolledBuf.lookupKittyRegistry(0, 0), registry),
        isTrue,
      );
      expect(registry.viewportScrollOffset, equals(scrollNeeded));
      expect(placement.gridRow + registry.viewportScrollOffset, equals(0));

      // Returning to live bottom resets viewportScrollOffset to 0.
      pane.jumpToBottom();
      expect(registry.viewportScrollOffset, equals(0));

      // Disposing while scrolled up also resets viewportScrollOffset to 0.
      pane.scrollLines(2);
      expect(registry.viewportScrollOffset, equals(2));
      await pane.dispose(disposePort: false);
      expect(registry.viewportScrollOffset, equals(0));

      // Remote-scoped panes must not mutate a shared registry's viewportScrollOffset.
      final remoteBackend = _RecordingRoutedPtyBackend();
      final remoteRouter = PtyRouter();
      final remoteSession = remoteRouter.createSession(
        backend: remoteBackend,
        initialCols: 16,
        initialRows: 4,
        maxScrollbackLines: 20,
      );
      final remotePort = remoteSession.openPort(
        initialCols: 16,
        initialRows: 4,
      );
      final remotePane = FtermPaneController(
        paneId: 'remote-scroll-pane',
        port: remotePort,
        remoteSessionId: const SessionId('remote-session-1'),
        colorResolver: _resolverFor(tui.TerminalColorTheme.termuiDark),
        resizeDebounce: Duration.zero,
      );
      addTearDown(() async {
        await remotePane.dispose(disposePort: false);
        await remotePort.dispose();
        await remoteRouter.dispose();
      });

      remoteBackend.emitAnsi('a\r\nb\r\nc\r\nd\r\ne\r\nf\r\n');
      final sharedRegistry = remoteSession.terminal.imageRegistry;
      remotePane.scrollLines(2);
      expect(remotePane.scrollOffsetLines, equals(2));
      expect(sharedRegistry.viewportScrollOffset, equals(0));
    });
  });
}
