import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/font_loader.dart';
import 'package:fterm/src/launch_config.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/ui/fterm_shell_scaffold.dart';
import 'package:fterm/src/workspace/fterm_pane_controller.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver_io.dart';
import 'package:material_ui/material_ui.dart';
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart'
    show
        CastClientRepository,
        TerminalColorResolver,
        TerminalThemeSettings,
        WsClientTransport;
import 'package:termui_flutter/termui_flutter.dart';
import 'package:termui_pty/termui_pty.dart';

final class _InMemoryRoutedPtyBackend implements RoutedPtyBackend {
  final StreamController<Uint8List> _output =
      StreamController<Uint8List>.broadcast(sync: true);
  final Completer<int> _exitCode = Completer<int>();

  void emitAnsi(String payload) {
    if (!_output.isClosed) {
      _output.add(Uint8List.fromList(utf8.encode(payload)));
    }
  }

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  void write(Uint8List bytes) {}

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

final class _MemorySettingsStorage implements SettingsStorage {
  final Map<String, String> _values = <String, String>{};

  @override
  String? getItem(String key) => _values[key];

  @override
  void setItem(String key, String value) {
    _values[key] = value;
  }
}

MouseCursor _readSurfaceMouseCursor(WidgetTester tester) {
  final region = tester.widget<MouseRegion>(
    find.descendant(
      of: find.byType(TerminalSurface),
      matching: find.byType(MouseRegion),
    ),
  );
  return region.cursor;
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadCastFonts();
  });

  group('OSC 22 live pointer wiring in fterm', () {
    testWidgets(
      'FtermPaneController forwards VirtualTerminal OSC 22 push/pop/set/reset to TerminalSurface MouseRegion.cursor',
      (tester) async {
        final backend = _InMemoryRoutedPtyBackend();
        final router = PtyRouter();
        final session = router.createSession(
          backend: backend,
          initialCols: 20,
          initialRows: 6,
        );
        final port = session.openPort(initialCols: 20, initialRows: 6);
        final pane = FtermPaneController(
          paneId: 'osc22-pane',
          port: port,
          colorResolver: TerminalColorResolver(
            theme: tui.TerminalColorTheme.termuiDark,
            settings: const TerminalThemeSettings(),
          ),
          resizeDebounce: Duration.zero,
        );
        addTearDown(() async {
          await pane.dispose(disposePort: false);
          await port.dispose();
          await router.dispose();
        });

        final atlasController = GlyphAtlasController(
          fontSize: 13.0,
          fontFamily: castPrimaryFontFamily,
          devicePixelRatio: 1.0,
        );
        addTearDown(atlasController.dispose);
        await tester.runAsync(atlasController.ensureInitialized);
        expect(atlasController.atlas, isNotNull);

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 320,
              height: 160,
              child: TerminalSurface(
                atlasController: atlasController,
                bufferProvider: pane.readDisplayBuffer,
                bufferListenable: pane.bufferListenable,
                cursorPositionProvider: pane.readCursorPosition,
                mouseCursorNameProvider: pane.readMouseCursorShape,
              ),
            ),
          ),
        );
        await tester.pump();

        expect(pane.mouseCursorShape, isNull);
        expect(pane.readMouseCursorShape(), isNull);
        expect(
          _readSurfaceMouseCursor(tester),
          equals(SystemMouseCursors.basic),
        );

        final signal = pane.bufferListenable as TerminalBufferChangeSignal;
        final revBeforeOsc22 = signal.cellContentRevision;

        // Push 'pointer' -> SystemMouseCursors.click without bumping cellContentRevision.
        backend.emitAnsi('\x1b]22;>pointer\x1b\\');
        await tester.pump();
        expect(pane.mouseCursorShape, equals('pointer'));
        expect(pane.readMouseCursorShape(), equals('pointer'));
        expect(
          _readSurfaceMouseCursor(tester),
          equals(SystemMouseCursors.click),
        );
        expect(signal.cellContentRevision, equals(revBeforeOsc22));

        // Push 'nesw-resize' -> SystemMouseCursors.resizeUpRightDownLeft.
        backend.emitAnsi('\x1b]22;>nesw-resize\x1b\\');
        await tester.pump();
        expect(pane.mouseCursorShape, equals('nesw-resize'));
        expect(
          _readSurfaceMouseCursor(tester),
          equals(SystemMouseCursors.resizeUpRightDownLeft),
        );

        // Pop -> restores 'pointer' / SystemMouseCursors.click.
        backend.emitAnsi('\x1b]22;<\x1b\\');
        await tester.pump();
        expect(pane.mouseCursorShape, equals('pointer'));
        expect(
          _readSurfaceMouseCursor(tester),
          equals(SystemMouseCursors.click),
        );

        // Pop -> restores default (null) / SystemMouseCursors.basic.
        backend.emitAnsi('\x1b]22;<\x1b\\');
        await tester.pump();
        expect(pane.mouseCursorShape, isNull);
        expect(
          _readSurfaceMouseCursor(tester),
          equals(SystemMouseCursors.basic),
        );

        // Direct set and empty reset also flow end to end.
        backend.emitAnsi('\x1b]22;text\x1b\\');
        await tester.pump();
        expect(pane.mouseCursorShape, equals('text'));
        expect(
          _readSurfaceMouseCursor(tester),
          equals(SystemMouseCursors.text),
        );

        backend.emitAnsi('\x1b]22;\x1b\\');
        await tester.pump();
        expect(pane.mouseCursorShape, isNull);
        expect(
          _readSurfaceMouseCursor(tester),
          equals(SystemMouseCursors.basic),
        );
      },
    );

    testWidgets(
      'FtermShellScaffold wires pane.readMouseCursorShape into TerminalSurface so PTY OSC 22 updates live cursor',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(640, 400));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final backend = _InMemoryRoutedPtyBackend();
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
        final repo = CastClientRepository(
          transport: WsClientTransport(
            serverUri: CastLaunchConfig.defaultServerUri,
            token: '',
          ),
        );
        final audio = FtermAudioController(
          initialMuted: true,
          requireUserGesture: false,
        );
        final shaderController = TerminalShaderController(
          backendFactory: (_) => const DisabledShaderBackend(),
        );
        final workspace = FtermWorkspaceController(
          launchConfig: CastLaunchConfig(
            serverUri: Uri.parse('ws://127.0.0.1:9999/ws'),
            promptForConnection: false,
          ),
          repository: repo,
          localHostDriver: driver,
          audioController: audio,
          storage: _MemorySettingsStorage(),
          resizeDebounce: Duration.zero,
          shaderController: shaderController,
        );
        addTearDown(() async {
          await tester.runAsync(workspace.dispose);
          await tester.pumpWidget(const SizedBox.shrink());
        });

        await tester.runAsync(workspace.openLocalShellTab);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: FtermShellScaffold(
                workspace: workspace,
                onOpenUrl: (_) {},
                isWebOverride: false,
                platformOverride: TargetPlatform.linux,
              ),
            ),
          ),
        );

        await tester.runAsync<void>(() async {
          final surfaceState = tester.state<TerminalSurfaceState>(
            find.byType(TerminalSurface),
          );
          for (
            var i = 0;
            i < 40 && surfaceState.atlasController.atlas == null;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
          expect(surfaceState.atlasController.atlas, isNotNull);
        });
        await tester.pump();

        final surface = tester.widget<TerminalSurface>(
          find.byType(TerminalSurface),
        );
        expect(surface.mouseCursorNameProvider, isNotNull);
        expect(
          _readSurfaceMouseCursor(tester),
          equals(SystemMouseCursors.basic),
        );

        backend.emitAnsi('\x1b]22;>pointer\x1b\\');
        await tester.pump();
        expect(
          _readSurfaceMouseCursor(tester),
          equals(SystemMouseCursors.click),
        );

        backend.emitAnsi('\x1b]22;<\x1b\\');
        await tester.pump();
        expect(
          _readSurfaceMouseCursor(tester),
          equals(SystemMouseCursors.basic),
        );
      },
    );
  });
}
