import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/automation/automation_models.dart';
import 'package:fterm/src/automation/automation_router.dart';
import 'package:fterm/src/font_loader.dart';
import 'package:fterm/src/launch_config.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/shader_profile_store.dart';
import 'package:fterm/src/ui/fterm_shell_scaffold.dart';
import 'package:fterm/src/ui/fterm_shortcut_dispatcher.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver.dart';
import 'package:material_ui/material_ui.dart';
import 'package:termui/terminal/event.dart' as ev;
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_flutter/src/rendering/search_highlight.dart';
import 'package:termui_flutter/termui_flutter.dart';
import 'package:termui_pty/termui_pty.dart';

final class _MemStorage implements SettingsStorage {
  final Map<String, String> data = <String, String>{};

  @override
  String? getItem(String key) => data[key];

  @override
  void setItem(String key, String value) => data[key] = value;
}

final class _FakeScrollbackPort implements TerminalPort {
  @override
  final String id;

  @override
  final String windowTitle;

  final tui.Buffer _buffer;
  final List<ScrollbackLine> scrollbackRows = <ScrollbackLine>[];
  final List<Uint8List> sentInputs = <Uint8List>[];
  final Set<void Function()> _listeners = <void Function()>{};
  final Completer<int> _exitCode = Completer<int>();

  int oldestLine = 0;

  _FakeScrollbackPort({
    required this.id,
    int cols = 60,
    int rows = 10,
    this.windowTitle = 'zsh',
  }) : _buffer = tui.Buffer.blank(cols, rows);

  void writeLiveRow(int row, String text) {
    if (row < 0 || row >= _buffer.height) return;
    _buffer.writeString(0, row, text, const tui.Style());
  }

  void appendScrollbackLine(String text) {
    final width = _buffer.width;
    final chars = List<String>.filled(width, ' ');
    var col = 0;
    for (final ch in text.characters) {
      if (col >= width) break;
      chars[col++] = ch;
    }
    scrollbackRows.add(
      ScrollbackLine(
        width: width,
        characters: chars,
        attributes: Uint32List(width * 3),
        isWrapped: false,
      ),
    );
  }

  @override
  tui.Buffer get buffer => _buffer;

  @override
  int get cols => _buffer.width;

  @override
  int get rows => _buffer.height;

  @override
  int get renderRevision => 0;

  @override
  int get fullSyncRevision => 0;

  @override
  List<DirtyCellSpan> get dirtySpans => const <DirtyCellSpan>[];

  @override
  (int cols, int rows) get activePtySize => (_buffer.width, _buffer.height);

  @override
  CursorStateData get cursor => CursorStateData.origin;

  @override
  TerminalPortModes get modes => TerminalPortModes.defaults;

  @override
  ScrollbackWindowData get scrollbackWindow => (
    clearSeq: 0,
    oldestLine: oldestLine,
    totalLines: oldestLine + scrollbackRows.length,
  );

  @override
  List<ScrollbackLine> readScrollbackSlice(int startLine, int count) {
    final result = <ScrollbackLine>[];
    for (var i = 0; i < count; i++) {
      final idx = startLine + i - oldestLine;
      if (idx >= 0 && idx < scrollbackRows.length) {
        result.add(scrollbackRows[idx]);
      }
    }
    return result;
  }

  @override
  void setViewportSize(
    int cols,
    int rows, {
    int cellPixelWidth = 0,
    int cellPixelHeight = 0,
  }) {}

  @override
  void sendInput(Uint8List data) => sentInputs.add(Uint8List.fromList(data));

  @override
  void setShaderCapabilities(TerminalShaderCapabilities capabilities) {}

  @override
  void addListener(void Function() listener) => _listeners.add(listener);

  @override
  void removeListener(void Function() listener) => _listeners.remove(listener);

  @override
  void addBellListener(void Function() listener) {}

  @override
  void removeBellListener(void Function() listener) {}

  @override
  void addAudioListener(void Function(TerminalAudioEvent event) listener) {}

  @override
  void removeAudioListener(void Function(TerminalAudioEvent event) listener) {}

  @override
  void addShaderListener(
    void Function(TerminalShaderApcEvent event) listener,
  ) {}

  @override
  void removeShaderListener(
    void Function(TerminalShaderApcEvent event) listener,
  ) {}

  @override
  void addTitleListener(void Function(String title) listener) {}

  @override
  void removeTitleListener(void Function(String title) listener) {}

  @override
  void addClipboardListener(
    void Function(String selection, String text) listener,
  ) {}

  @override
  void removeClipboardListener(
    void Function(String selection, String text) listener,
  ) {}

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  String? get workingDirectory => '/workspace/project';

  @override
  Future<void> dispose() async {
    if (!_exitCode.isCompleted) _exitCode.complete(0);
  }
}

final class _FakePromptLocalHost implements PromptIndexedPaneHost {
  @override
  final String id;

  final _FakeScrollbackPort fakePort;

  @override
  final List<int> promptLines;

  final StreamController<LocalShareSnapshot> _shareUpdates =
      StreamController<LocalShareSnapshot>.broadcast();

  _FakePromptLocalHost({
    required this.id,
    required this.fakePort,
    this.promptLines = const <int>[],
  });

  @override
  TerminalPort get port => fakePort;

  @override
  Future<int> get exitCode => fakePort.exitCode;

  @override
  LocalShareSnapshot get shareSnapshot => LocalShareSnapshot.unshared;

  @override
  Stream<LocalShareSnapshot> get shareUpdates => _shareUpdates.stream;

  @override
  Future<SessionId> startShare({
    required Uri serverUri,
    required String casterToken,
    required String title,
    String? uploadDirPath,
    IapTokenProvider? iapTokenProvider,
    CasterTransportOpener? channelOpener,
  }) => Future<SessionId>.error(UnsupportedError('unused'));

  @override
  Future<void> stopShare() async {}

  @override
  void setColorScheme(tui.TerminalBrightness brightness) {}

  @override
  bool isLiveRowWrapped(int row) => false;

  @override
  Future<void> dispose() async {
    await _shareUpdates.close();
    await fakePort.dispose();
  }
}

final class _FakeLocalDriver implements LocalHostDriver {
  final List<_FakePromptLocalHost> hosts = <_FakePromptLocalHost>[];
  final void Function(_FakeScrollbackPort port, List<int> prompts)?
  onPopulatePort;
  int _counter = 0;

  @override
  final bool isSupported;

  _FakeLocalDriver({this.isSupported = true, this.onPopulatePort});

  @override
  Future<LocalPaneHost> openShell(LocalShellConfig config) async {
    _counter++;
    final port = _FakeScrollbackPort(
      id: 'local-$_counter',
      windowTitle: 'shell-$_counter',
    );
    final prompts = <int>[];
    onPopulatePort?.call(port, prompts);
    final host = _FakePromptLocalHost(
      id: 'host-$_counter',
      fakePort: port,
      promptLines: prompts,
    );
    hosts.add(host);
    return host;
  }

  @override
  Future<void> dispose() async {
    for (final host in hosts) {
      await host.dispose();
    }
  }
}

final class _FakeShaderProfileStore implements ShaderProfileStore {
  @override
  String? get shadersDirectoryPath => '/tmp/fterm/shaders';

  final Map<String, String> _shaders = <String, String>{};

  @override
  Future<List<String>> listShaderFiles() async => [..._shaders.keys]..sort();

  @override
  Future<String> loadShaderSource(String pathOrKey) async =>
      _shaders[pathOrKey] ??
      (throw ShaderAssetException('Not found', pathOrKey: pathOrKey));

  @override
  Future<Uint8List> loadWallpaperBytes(String pathOrKey) =>
      throw ShaderAssetException('Not found', pathOrKey: pathOrKey);

  @override
  Future<void> saveShaderSource(String name, String glslSource) async {
    _shaders[name] = glslSource;
  }

  @override
  Future<void> saveWallpaperBytes(String key, Uint8List bytes) async {}

  @override
  Stream<ShaderDirectoryChange> watchShaderDirectory() =>
      const Stream<ShaderDirectoryChange>.empty();

  @override
  void dispose() {}
}

Future<
  ({
    FtermWorkspaceController workspace,
    _FakeLocalDriver driver,
    ShaderProfileStore profileStore,
  })
>
_mountShell(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.linux,
  bool isWeb = false,
  Size surfaceSize = const Size(960, 720),
  void Function(_FakeScrollbackPort port, List<int> prompts)? onPopulatePort,
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final storage = _MemStorage();
  final driver = _FakeLocalDriver(
    isSupported: !isWeb,
    onPopulatePort: onPopulatePort,
  );
  final repo = CastClientRepository(
    transport: WsClientTransport(
      serverUri: CastLaunchConfig.defaultServerUri,
      token: '',
    ),
  );
  final audio = FtermAudioController(
    initialMuted: false,
    requireUserGesture: false,
  );
  final shaderController = TerminalShaderController(
    backendFactory: (_) => const DisabledShaderBackend(),
  );
  final profileStore = _FakeShaderProfileStore();
  final workspace = FtermWorkspaceController(
    launchConfig: CastLaunchConfig(
      serverUri: Uri.parse('ws://127.0.0.1:9999/ws'),
      promptForConnection: false,
    ),
    repository: repo,
    localHostDriver: driver,
    audioController: audio,
    storage: storage,
    resizeDebounce: Duration.zero,
    shaderController: shaderController,
    shaderProfileStore: profileStore,
  );

  if (!isWeb) {
    await workspace.openLocalShellTab();
  }

  addTearDown(() async {
    await tester.runAsync(workspace.dispose);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FtermShellScaffold(
          workspace: workspace,
          onOpenUrl: (_) async => true,
          isWebOverride: isWeb,
          platformOverride: platform,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  return (workspace: workspace, driver: driver, profileStore: profileStore);
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadCastFonts();
  });

  group('Command Palette entry hotkeys, toolbar button & PTY safety', () {
    testWidgets(
      'opens via Ctrl+Shift+P on Linux/Win, toggles off on re-press, keeps Ctrl+P bound to PTY, and works via top bar & left rail buttons',
      (tester) async {
        final env = await _mountShell(tester, platform: TargetPlatform.linux);
        final ws = env.workspace;
        final port = env.driver.hosts.first.fakePort;

        // Plain Ctrl+P must pass straight through to the PTY (0x10).
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(ws.activeOverlay, FtermOverlay.none);
        expect(port.sentInputs.any((bytes) => bytes.contains(0x10)), isTrue);

        // Ctrl+Shift+P opens Command Palette in '>' mode.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();

        expect(ws.activeOverlay, FtermOverlay.commandPalette);
        final inputField = tester.widget<TextField>(
          find.byKey(const ValueKey('palette-input')),
        );
        expect(inputField.controller?.text, '>');

        // Re-pressing Ctrl+Shift+P toggles/dismisses the palette cleanly.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(ws.activeOverlay, FtermOverlay.none);

        // Toolbar button in top bar opens palette.
        await tester.tap(
          find.byKey(const ValueKey('fterm-command-palette-button')),
        );
        await tester.pumpAndSettle();
        expect(ws.activeOverlay, FtermOverlay.commandPalette);
        ws.dismissOverlay();
        await tester.pumpAndSettle();

        // Toolbar button also exists in left tab rail.
        ws.setDockPosition(DockPosition.left);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('fterm-command-palette-button')),
        );
        await tester.pumpAndSettle();
        expect(ws.activeOverlay, FtermOverlay.commandPalette);
      },
    );

    testWidgets(
      'opens via Cmd+Shift+P on macOS desktop and toggles off cleanly while leaving Cmd+P unbound',
      (tester) async {
        final env = await _mountShell(tester, platform: TargetPlatform.macOS);
        final ws = env.workspace;
        final dispatcher = FtermShortcutDispatcher(
          workspace: ws,
          platformOverride: TargetPlatform.macOS,
          isWebOverride: false,
        );

        // Plain Cmd+P must NOT open command palette.
        final plainCmdP = dispatcher.handleHostShortcut(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.keyP,
            logicalKey: LogicalKeyboardKey.keyP,
            timeStamp: Duration.zero,
          ),
          const {ev.Modifier.meta},
        );
        expect(plainCmdP, HostShortcutResult.unhandled);
        expect(ws.activeOverlay, FtermOverlay.none);

        // Cmd+Shift+P opens palette.
        final cmdShiftP = dispatcher.handleHostShortcut(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.keyP,
            logicalKey: LogicalKeyboardKey.keyP,
            timeStamp: Duration.zero,
          ),
          const {ev.Modifier.meta, ev.Modifier.shift},
        );
        expect(cmdShiftP, HostShortcutResult.handled);
        expect(ws.activeOverlay, FtermOverlay.commandPalette);

        // Re-pressing Cmd+Shift+P toggles off.
        final toggleOff = dispatcher.handleHostShortcut(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.keyP,
            logicalKey: LogicalKeyboardKey.keyP,
            timeStamp: Duration.zero,
          ),
          const {ev.Modifier.meta, ev.Modifier.shift},
        );
        expect(toggleOff, HostShortcutResult.handled);
        expect(ws.activeOverlay, FtermOverlay.none);
      },
    );

    testWidgets(
      'Ctrl+\\ Shift+P opens palette on Web & desktop while lowercase Ctrl+\\ p cycles previous tab (CapsLock-safe)',
      (tester) async {
        final env = await _mountShell(tester, platform: TargetPlatform.linux);
        final ws = env.workspace;
        await ws.openLocalShellTab();
        await tester.pumpAndSettle();
        expect(ws.activeTabIndex, 1);

        final webDispatcher = FtermShortcutDispatcher(
          workspace: ws,
          platformOverride: TargetPlatform.linux,
          isWebOverride: true,
        );

        // Arm leader, then press lowercase 'p' (even with uppercase character
        // as if CapsLock were on, without shift modifier): must cycle tab!
        webDispatcher.handleHostShortcut(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.backslash,
            logicalKey: LogicalKeyboardKey.backslash,
            timeStamp: Duration.zero,
          ),
          const {ev.Modifier.control},
        );
        webDispatcher.handleHostShortcut(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.keyP,
            logicalKey: LogicalKeyboardKey.keyP,
            character: 'P',
            timeStamp: Duration.zero,
          ),
          const <ev.Modifier>{},
        );
        expect(ws.activeOverlay, FtermOverlay.none);
        expect(ws.activeTabIndex, 0);

        // Arm leader, then press Shift+P: opens Command Palette on Web!
        webDispatcher.handleHostShortcut(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.backslash,
            logicalKey: LogicalKeyboardKey.backslash,
            timeStamp: Duration.zero,
          ),
          const {ev.Modifier.control},
        );
        webDispatcher.handleHostShortcut(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.keyP,
            logicalKey: LogicalKeyboardKey.keyP,
            character: 'P',
            timeStamp: Duration.zero,
          ),
          const {ev.Modifier.shift},
        );
        expect(ws.activeOverlay, FtermOverlay.commandPalette);
      },
    );

    testWidgets(
      'Help overlay lists Command Palette shortcuts and AutomationRouter parses commandPalette overlay',
      (tester) async {
        final env = await _mountShell(tester, platform: TargetPlatform.linux);
        final ws = env.workspace;

        ws.setOverlay(FtermOverlay.help);
        await tester.pumpAndSettle();
        expect(find.text('Ctrl+Shift+P / Cmd+Shift+P'), findsOneWidget);
        expect(find.text(r'Ctrl+\ then Shift+P'), findsOneWidget);

        final router = AutomationRouter(
          workspace: ws,
          windowBridge: const UnsupportedAutomationWindowBridge(),
          readPointerDispatcher: () => null,
          awaitFrameSettle: () async {},
        );
        final res = await router.handleRequest(
          const AutomationHttpRequest(
            method: 'POST',
            path: '/v1/ui',
            body: <String, Object?>{'overlay': 'commandPalette'},
          ),
        );
        expect(res.statusCode, 200);
        expect(ws.activeOverlay, FtermOverlay.commandPalette);
      },
    );
  });

  group('Top-anchored layout, transparent scrim, modes, commands & MRU', () {
    testWidgets(
      'renders top-anchored with transparent click-to-dismiss scrim that rolls back uncommitted scroll preview safely',
      (tester) async {
        final env = await _mountShell(
          tester,
          onPopulatePort: (port, prompts) {
            for (var i = 0; i < 60; i++) {
              port.appendScrollbackLine('history line $i');
            }
          },
        );
        final ws = env.workspace;
        final pane = ws.focusedPane!;
        expect(pane.scrollOffsetLines, 0);

        ws.openCommandPalette(initialInput: ':');
        await tester.pumpAndSettle();

        // Top-anchored near y=36 (well above vertical midpoint 360).
        final paletteRect = tester.getRect(
          find.byKey(const ValueKey('fterm-overlay-commandPalette')),
        );
        expect(paletteRect.top, lessThan(80.0));

        // Scrim is transparent so terminal scrollback remains visible behind it.
        final scrimBox = tester.widget<ColoredBox>(
          find.descendant(
            of: find.byKey(const ValueKey('fterm-overlay-scrim')),
            matching: find.byType(ColoredBox),
          ),
        );
        expect(scrimBox.color, Colors.transparent);

        // Live preview scroll to :50%.
        await tester.enterText(
          find.byKey(const ValueKey('palette-input')),
          ':50%',
        );
        await tester.pumpAndSettle();
        expect(pane.scrollOffsetLines, greaterThan(0));

        // Clicking scrim outside palette rolls back scroll without tree-lock error.
        await tester.tapAt(const Offset(40, 680));
        await tester.pumpAndSettle();

        expect(ws.activeOverlay, FtermOverlay.none);
        expect(pane.scrollOffsetLines, 0);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'switches modes live, highlights fuzzy characters, navigates with Arrow/Ctrl+N/Ctrl+P, executes flat commands, and pins MRU',
      (tester) async {
        final env = await _mountShell(tester, platform: TargetPlatform.linux);
        final ws = env.workspace;

        ws.openCommandPalette(initialInput: '>');
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('palette-mode-badge')),
            matching: find.text('Commands'),
          ),
          findsOneWidget,
        );

        // Empty input enters Quick Switcher.
        await tester.enterText(find.byKey(const ValueKey('palette-input')), '');
        await tester.pumpAndSettle();
        expect(find.text('Quick Switch'), findsOneWidget);
        expect(find.text('OPEN TABS'), findsOneWidget);

        // ':' enters Go to Line, '%' enters Search, '>' returns to Commands.
        await tester.enterText(
          find.byKey(const ValueKey('palette-input')),
          ':',
        );
        await tester.pumpAndSettle();
        expect(find.text('Go to Line'), findsOneWidget);

        await tester.enterText(
          find.byKey(const ValueKey('palette-input')),
          '%',
        );
        await tester.pumpAndSettle();
        expect(find.text('Search'), findsOneWidget);

        // Execute flat Theme command (opposite brightness light theme).
        await tester.enterText(
          find.byKey(const ValueKey('palette-input')),
          '> sollight',
        );
        await tester.pumpAndSettle();

        // Verify fuzzy matched bold accent span exists inside Text.rich/RichText.
        final richTexts = tester.widgetList<RichText>(find.byType(RichText));
        final hasBoldAccentSpan = richTexts.any((rt) {
          bool containsBold(InlineSpan span) {
            if (span is! TextSpan) return false;
            if (span.style?.fontWeight == FontWeight.w700 &&
                (span.text?.isNotEmpty ?? false)) {
              return true;
            }
            return span.children?.any(containsBold) ?? false;
          }

          return containsBold(rt.text);
        });
        expect(hasBoldAccentSpan, isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();

        expect(ws.activeOverlay, FtermOverlay.none);
        expect(ws.activeTerminalTheme.id, 'solarized_light');
        expect(
          ws.workspaceSettings.themeSettings.appearanceMode,
          ThemeAppearanceMode.light,
        );

        // Reopen '>' -> Solarized Light is pinned under RECENTLY USED.
        ws.openCommandPalette(initialInput: '>');
        await tester.pumpAndSettle();
        expect(find.text('RECENTLY USED'), findsOneWidget);
        expect(ws.recentCommandIds.first, 'theme.preset.solarized_light');

        // Navigate with ArrowDown / ArrowUp / Ctrl+N / Ctrl+P without losing focus.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();

        // Toggle Perf HUD via flat command.
        final perfBefore = ws.showPerfHud;
        await tester.enterText(
          find.byKey(const ValueKey('palette-input')),
          '> Toggle Performance HUD',
        );
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(ws.showPerfHud, !perfBefore);

        // Toggle Mute Audio via flat command.
        final muteBefore = ws.preferences.audioMuted;
        ws.openCommandPalette(initialInput: '> Toggle Mute Audio');
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(ws.preferences.audioMuted, !muteBefore);

        // Toggle a shader preset via flat command.
        ws.openCommandPalette(initialInput: '> Shader: CRT');
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(ws.foregroundShaderChain, isNotEmpty);

        // Open Settings deep-link (Shaders section).
        ws.openCommandPalette(initialInput: '> Open Shaders');
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(ws.activeOverlay, FtermOverlay.settings);
        expect(ws.lastSettingsSection, FtermSettingsSection.shaders);
        ws.dismissOverlay();
        await tester.pumpAndSettle();

        // Open New Local Shell tab via flat command.
        final tabsBefore = ws.tabs.length;
        ws.openCommandPalette(initialInput: '> New Local Shell');
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(ws.tabs.length, tabsBefore + 1);
      },
    );

    testWidgets('hides desktop-only commands in Web mode', (tester) async {
      final env = await _mountShell(
        tester,
        platform: TargetPlatform.linux,
        isWeb: true,
      );
      final ws = env.workspace;

      ws.openCommandPalette(initialInput: '> New Local Shell');
      await tester.pumpAndSettle();
      expect(find.text('No matching commands.'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('palette-input')),
        '> Open Shaders Folder',
      );
      await tester.pumpAndSettle();
      expect(find.text('No matching commands.'), findsOneWidget);
    });
  });

  group('Scrollback Jump (:) & Text Search (%) live preview and highlights', () {
    testWidgets(
      ': previews scrollback, lists OSC 133 prompts, reverts on Esc, and commits on Enter',
      (tester) async {
        final env = await _mountShell(
          tester,
          onPopulatePort: (port, prompts) {
            for (var i = 0; i < 60; i++) {
              if (i == 10) {
                port.appendScrollbackLine(r'$ git status');
                prompts.add(i);
              } else if (i == 40) {
                port.appendScrollbackLine(r'$ flutter test');
                prompts.add(i);
              } else {
                port.appendScrollbackLine('log line $i');
              }
            }
          },
        );
        final ws = env.workspace;
        final pane = ws.focusedPane!;

        // Open ':' -> shows landmarks and OSC 133 prompts.
        ws.openCommandPalette(initialInput: ':');
        await tester.pumpAndSettle();
        expect(find.textContaining('git status'), findsOneWidget);
        expect(find.textContaining('flutter test'), findsOneWidget);

        // Filter to 'git status' -> live preview scrolls pane to prompt row 10.
        await tester.enterText(
          find.byKey(const ValueKey('palette-input')),
          ':git',
        );
        await tester.pumpAndSettle();
        expect(pane.scrollOffsetLines, greaterThan(0));

        // Esc reverts scrollback position to 0.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(ws.activeOverlay, FtermOverlay.none);
        expect(pane.scrollOffsetLines, 0);

        // Reopen ':10' and press Enter -> commits scrolled position.
        ws.openCommandPalette(initialInput: ':10');
        await tester.pumpAndSettle();
        final committedOffset = pane.scrollOffsetLines;
        expect(committedOffset, greaterThan(0));

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(ws.activeOverlay, FtermOverlay.none);
        expect(pane.scrollOffsetLines, committedOffset);
      },
    );

    testWidgets(
      '% mounts canvas highlights on TerminalSurface, supports Aa & .* toggles, invalid regex errors, Enter commit & Esc revert',
      (tester) async {
        final env = await _mountShell(
          tester,
          onPopulatePort: (port, prompts) {
            for (var i = 0; i < 40; i++) {
              if (i == 5) {
                port.appendScrollbackLine('Alpha needle first');
              } else if (i == 25) {
                port.appendScrollbackLine('Beta NEEDLE second');
              } else {
                port.appendScrollbackLine('line $i filler');
              }
            }
            port.writeLiveRow(0, 'live needle third');
          },
        );
        final ws = env.workspace;
        final pane = ws.focusedPane!;

        Finder searchHighlightOverlayFinder() => find.byWidgetPredicate(
          (w) =>
              w is CustomPaint && w.painter is TerminalSearchHighlightPainter,
        );

        // Idle: zero search highlight overlay mounted.
        expect(searchHighlightOverlayFinder(), findsNothing);

        // Type '% needle' -> 3 matches, mounts TerminalSearchHighlightPainter.
        ws.openCommandPalette(initialInput: '%');
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('palette-input')),
          '% needle',
        );
        await tester.pumpAndSettle();

        expect(find.text('1 of 3 matches'), findsOneWidget);
        expect(pane.readSearchHighlights(), hasLength(3));
        expect(pane.readSearchHighlights()[0].isActive, isTrue);
        expect(searchHighlightOverlayFinder(), findsOneWidget);

        // ArrowDown advances active highlight to match 2.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(find.text('2 of 3 matches'), findsOneWidget);
        expect(pane.readSearchHighlights()[1].isActive, isTrue);

        // Toggle Aa (case sensitive) -> drops 'NEEDLE', leaving 2 matches.
        await tester.tap(
          find.byKey(const ValueKey('palette-search-case-toggle')),
        );
        await tester.pumpAndSettle();
        expect(find.text('1 of 2 matches'), findsOneWidget);

        // Toggle .* (regex) and enter invalid regex '% [' -> error shown, no crash.
        await tester.tap(
          find.byKey(const ValueKey('palette-search-regex-toggle')),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('palette-input')),
          '% [',
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('palette-error-message')),
          findsOneWidget,
        );
        expect(pane.readSearchHighlights(), isEmpty);

        // Enter valid regex '% (Alpha|Beta)' and press Esc -> reverts scroll & clears highlights.
        await tester.enterText(
          find.byKey(const ValueKey('palette-input')),
          '% (Alpha|Beta)',
        );
        await tester.pumpAndSettle();
        expect(find.text('1 of 2 matches'), findsOneWidget);
        expect(pane.scrollOffsetLines, greaterThan(0));

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(ws.activeOverlay, FtermOverlay.none);
        expect(pane.scrollOffsetLines, 0);
        expect(pane.readSearchHighlights(), isEmpty);
        expect(searchHighlightOverlayFinder(), findsNothing);

        // Reopen '% Alpha' and press Enter -> keeps scrolled position & clears highlights.
        ws.openCommandPalette(initialInput: '% Alpha');
        await tester.pumpAndSettle();
        final matchScroll = pane.scrollOffsetLines;
        expect(matchScroll, greaterThan(0));
        expect(searchHighlightOverlayFinder(), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(ws.activeOverlay, FtermOverlay.none);
        expect(pane.scrollOffsetLines, matchScroll);
        expect(pane.readSearchHighlights(), isEmpty);
        expect(searchHighlightOverlayFinder(), findsNothing);
      },
    );

    testWidgets(
      'supports :line jump and % search in Shader Editor tab with full selection + scrollOffset rollback on Esc',
      (tester) async {
        final env = await _mountShell(tester, platform: TargetPlatform.linux);
        final ws = env.workspace;

        await ws.openShaderEditorTab();
        await tester.pumpAndSettle();
        final editor = ws.focusedEditorPane!;
        final ctrl = editor.controller;

        // Populate a 30-line GLSL buffer and set initial cursor & scrollOffset.
        final sourceLines = <String>[
          for (var i = 1; i <= 30; i++)
            i == 20
                ? 'void mainImage(out vec4 fragColor, in vec2 fragCoord) {'
                : '// glsl line $i',
        ];
        ctrl.textController.value = tui.TextEditingValue(
          text: sourceLines.join('\n'),
          selection: const tui.TextSelection.collapsed(
            offset: 0,
            line: 0,
            column: 0,
          ),
        );
        ctrl.textController.scrollOffset = 3;
        await tester.pumpAndSettle();

        final initialSelection = ctrl.textController.value.selection;
        final initialScroll = ctrl.textController.scrollOffset;

        // Open ':20' -> previews jump to line 20 (0-based 19), Esc restores both!
        ws.openCommandPalette(initialInput: ':20');
        await tester.pumpAndSettle();
        expect(ctrl.textController.value.selection.cursorLine, 19);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(ctrl.textController.value.selection, initialSelection);
        expect(ctrl.textController.scrollOffset, initialScroll);

        // Open '% mainImage' -> previews & selects 'mainImage' on line 20; Enter commits.
        ws.openCommandPalette(initialInput: '% mainImage');
        await tester.pumpAndSettle();
        expect(find.text('1 of 1 matches'), findsOneWidget);
        expect(ctrl.textController.value.selection.cursorLine, 19);
        expect(ctrl.textController.value.selection.isCollapsed, isFalse);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(ws.activeOverlay, FtermOverlay.none);
        expect(ctrl.textController.value.selection.cursorLine, 19);
        expect(ctrl.textController.value.selection.isCollapsed, isFalse);
      },
    );

    testWidgets(
      'renders cleanly in narrow 520x480 viewport across all four modes with zero RenderFlex overflow',
      (tester) async {
        final env = await _mountShell(
          tester,
          platform: TargetPlatform.linux,
          surfaceSize: const Size(520, 480),
          onPopulatePort: (port, prompts) {
            port.appendScrollbackLine(
              'very long scrollback line with searchable token repeated across the width of the narrow viewport',
            );
            prompts.add(0);
          },
        );
        final ws = env.workspace;

        ws.openCommandPalette(initialInput: '>');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        for (final input in const <String>['', ':', '% token', '> theme']) {
          await tester.enterText(
            find.byKey(const ValueKey('palette-input')),
            input,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      },
    );
  });
}
