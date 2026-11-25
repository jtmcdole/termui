import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/font_loader.dart';
import 'package:fterm/src/launch_config.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/shader_profile_store.dart';
import 'package:fterm/src/ui/fterm_shell_scaffold.dart';
import 'package:fterm/src/workspace/cli_shader_state.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver.dart';
import 'package:material_ui/material_ui.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_flutter/termui_flutter.dart';
import 'package:termui_pty/termui_pty.dart';

const String _validCustomGlslA =
    'void mainImage(out vec4 fragColor, in vec2 fragCoord) { '
    'fragColor = vec4(1.0, 0.4, 0.1, 1.0); }';

const String _validCustomGlslB =
    'void mainImage(out vec4 fragColor, in vec2 fragCoord) { '
    'fragColor = vec4(0.1, 0.8, 1.0, 1.0); }';

final class _MemorySettingsStorage implements SettingsStorage {
  final Map<String, String> values = <String, String>{};

  @override
  String? getItem(String key) => values[key];

  @override
  void setItem(String key, String value) => values[key] = value;
}

final class _FakeShaderHandle implements CompiledShaderHandle {
  @override
  final String id;

  @override
  final bool usesPrevFrame;

  bool disposed = false;

  _FakeShaderHandle(this.id, {this.usesPrevFrame = false});

  @override
  void dispose() {
    disposed = true;
  }
}

final class _FakeShaderBackend implements TerminalShaderBackend {
  final List<String> compiledIds = <String>[];

  @override
  ShaderBackendKind get kind => ShaderBackendKind.flutterGpu;

  @override
  bool get supportsCustomGlsl => true;

  @override
  bool get supportsSyncBackground => true;

  @override
  Future<CompiledShaderHandle> compile(
    String id,
    String shadertoyGlsl, {
    bool usesPrevFrame = false,
  }) async {
    compiledIds.add(id);
    return _FakeShaderHandle(id, usesPrevFrame: usesPrevFrame);
  }

  @override
  Future<void> reload(
    CompiledShaderHandle handle,
    String shadertoyGlsl,
  ) async {}

  @override
  ui.Image? renderBackgroundSync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? wallpaperImage,
    GpuFrameWatchdog? watchdog,
  }) => null;

  @override
  Future<ui.Image?> renderPassesAsync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? inputImage,
    ui.Image? wallpaperImage,
    GpuFrameWatchdog? watchdog,
  }) async => null;

  @override
  void dispose() {}
}

final class _InMemoryShaderProfileStore implements ShaderProfileStore {
  @override
  String? get shadersDirectoryPath => null;

  @override
  Future<List<String>> listShaderFiles() async => const <String>[];

  @override
  Future<String> loadShaderSource(String path) async => _validCustomGlslA;

  @override
  Future<void> saveShaderSource(String name, String source) async {}

  @override
  Future<Uint8List> loadWallpaperBytes(String pathOrKey) async => Uint8List(0);

  @override
  Future<void> saveWallpaperBytes(String key, Uint8List bytes) async {}

  @override
  Stream<ShaderDirectoryChange> watchShaderDirectory() =>
      const Stream<ShaderDirectoryChange>.empty();

  @override
  void dispose() {}
}

final class _VtBackedPort implements TerminalPort {
  final VirtualTerminal vt;
  final Set<void Function()> _listeners = {};
  final Set<void Function(String)> _titleListeners = {};
  final Set<void Function()> _bellListeners = {};
  final Set<void Function(TerminalAudioEvent)> _audioListeners = {};
  final Set<void Function(TerminalShaderApcEvent)> _shaderListeners = {};
  final Set<void Function(String, String)> _clipboardListeners = {};
  final List<String> replies = [];
  final Completer<int> _exitCode = Completer<int>();
  int _renderRevision = 0;
  final int _fullSyncRevision = 0;
  List<DirtyCellSpan> _dirtySpans = const [];

  _VtBackedPort({int cols = 40, int rows = 12})
    : vt = VirtualTerminal(width: cols, height: rows) {
    vt.onReply = replies.add;
    vt.onShaderEvent = (event) {
      for (final fn in [..._shaderListeners]) {
        fn(event);
      }
    };
  }

  void feed(String text, {bool dirtyCells = true}) {
    vt.write(utf8.encode(text));
    _renderRevision += 1;
    _dirtySpans = dirtyCells
        ? [(revision: _renderRevision, start: 0, length: cols)]
        : const [];
    for (final fn in [..._listeners]) {
      fn();
    }
  }

  void completeExit([int code = 0]) {
    if (!_exitCode.isCompleted) _exitCode.complete(code);
  }

  @override
  String get id => 'vt-port';

  @override
  tui.Buffer get buffer => vt.buffer;

  @override
  int get cols => vt.width;

  @override
  int get rows => vt.height;

  @override
  (int cols, int rows) get activePtySize => (vt.width, vt.height);

  @override
  CursorStateData get cursor =>
      CursorStateData(x: vt.cursorX, y: vt.cursorY, visible: vt.cursorVisible);

  @override
  TerminalPortModes get modes =>
      TerminalPortModes(altScreen: vt.isUsingAlternateScreen);

  @override
  ScrollbackWindowData get scrollbackWindow =>
      const (clearSeq: 0, oldestLine: 0, totalLines: 0);

  @override
  int get renderRevision => _renderRevision;

  @override
  int get fullSyncRevision => _fullSyncRevision;

  @override
  List<DirtyCellSpan> get dirtySpans => _dirtySpans;

  @override
  String get windowTitle => 'local-vt';

  @override
  String? get workingDirectory => '/tmp';

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  void addListener(void Function() listener) => _listeners.add(listener);

  @override
  void removeListener(void Function() listener) => _listeners.remove(listener);

  @override
  void addTitleListener(void Function(String title) listener) =>
      _titleListeners.add(listener);

  @override
  void removeTitleListener(void Function(String title) listener) =>
      _titleListeners.remove(listener);

  @override
  void addBellListener(void Function() listener) =>
      _bellListeners.add(listener);

  @override
  void removeBellListener(void Function() listener) =>
      _bellListeners.remove(listener);

  @override
  void addAudioListener(void Function(TerminalAudioEvent event) listener) =>
      _audioListeners.add(listener);

  @override
  void removeAudioListener(void Function(TerminalAudioEvent event) listener) =>
      _audioListeners.remove(listener);

  @override
  void addShaderListener(
    void Function(TerminalShaderApcEvent event) listener,
  ) => _shaderListeners.add(listener);

  @override
  void removeShaderListener(
    void Function(TerminalShaderApcEvent event) listener,
  ) => _shaderListeners.remove(listener);

  @override
  void setShaderCapabilities(TerminalShaderCapabilities capabilities) =>
      vt.setShaderCapabilities(capabilities);

  @override
  void addClipboardListener(
    void Function(String selection, String text) listener,
  ) => _clipboardListeners.add(listener);

  @override
  void removeClipboardListener(
    void Function(String selection, String text) listener,
  ) => _clipboardListeners.remove(listener);

  @override
  void sendInput(Uint8List utf8Bytes) {}

  @override
  void setViewportSize(
    int cols,
    int rows, {
    int cellPixelWidth = 0,
    int cellPixelHeight = 0,
  }) {}

  @override
  List<ScrollbackLine?> readScrollbackSlice(int startLine, int count) =>
      const [];

  @override
  Future<void> dispose() async {
    completeExit(0);
  }
}

final class _FakeLocalPaneHost implements LocalPaneHost {
  @override
  final String id;

  @override
  final _VtBackedPort port;

  final StreamController<LocalShareSnapshot> _shareCtrl =
      StreamController<LocalShareSnapshot>.broadcast();

  _FakeLocalPaneHost(this.id, this.port);

  @override
  Future<int> get exitCode => port.exitCode;

  @override
  LocalShareSnapshot get shareSnapshot => LocalShareSnapshot.unshared;

  @override
  Stream<LocalShareSnapshot> get shareUpdates => _shareCtrl.stream;

  @override
  void setColorScheme(tui.TerminalBrightness brightness) {}

  @override
  bool isLiveRowWrapped(int row) => false;

  @override
  Future<SessionId> startShare({
    required Uri serverUri,
    required String casterToken,
    required String title,
    String? uploadDirPath,
    IapTokenProvider? iapTokenProvider,
    CasterTransportOpener? channelOpener,
  }) async => SessionId('shared-$id');

  @override
  Future<void> stopShare() async {}

  @override
  Future<void> dispose() async {
    await port.dispose();
    await _shareCtrl.close();
  }
}

final class _FakeLocalHostDriver implements LocalHostDriver {
  final List<_VtBackedPort> openedPorts = [];
  int _counter = 0;

  @override
  bool get isSupported => true;

  @override
  Future<LocalPaneHost> openShell(LocalShellConfig config) async {
    final port = _VtBackedPort();
    openedPorts.add(port);
    return _FakeLocalPaneHost('local-${++_counter}', port);
  }

  @override
  Future<void> dispose() async {}
}

final class _LoopbackRelayPair {
  final StreamChannelController<Uint8List> controller =
      StreamChannelController<Uint8List>();
  bool _opened = false;

  Future<StreamChannel<Uint8List>> openClientChannel() async {
    _opened = true;
    return controller.local;
  }

  void deliver(CastMessage message) {
    controller.foreign.sink.add(BufferFrameCodec.encode(message));
  }

  Future<void> close() async {
    if (_opened) {
      await controller.foreign.sink.close();
    }
  }
}

FtermWorkspaceController _createWorkspace({
  required _FakeLocalHostDriver driver,
  required _LoopbackRelayPair relay,
  required _MemorySettingsStorage storage,
  required _FakeShaderBackend backend,
}) {
  final transport = WsClientTransport(
    serverUri: Uri.parse('ws://127.0.0.1:8420/v1/client'),
    token: 'test-token',
    channelFactory: relay.openClientChannel,
  );
  final repo = CastClientRepository(
    transport: transport,
    enableReconnect: false,
  );
  return FtermWorkspaceController(
    launchConfig: CastLaunchConfig(
      serverUri: Uri.parse('ws://127.0.0.1:8420/v1/client'),
      token: 'test-token',
      promptForConnection: false,
    ),
    repository: repo,
    localHostDriver: driver,
    audioController: FtermAudioController(),
    storage: storage,
    resizeDebounce: Duration.zero,
    shaderController: TerminalShaderController(backend: backend),
    shaderProfileStore: _InMemoryShaderProfileStore(),
  );
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadCastFonts();
  });

  group('FtermPreferences CLI shader policy persistence', () {
    test('defaults and JSON round-trip preserve local/remote policy, stacking mode, and trusted hashes', () {
      const defaults = FtermPreferences.defaults;
      expect(defaults.localCliShaderPolicy, CliShaderPolicy.promptCustomGlsl);
      expect(defaults.remoteCliShaderPolicy, CliShaderPolicy.disabled);
      expect(
        defaults.cliFullPaneShaderMode,
        CliFullPaneShaderMode.cliBeforeUser,
      );
      expect(defaults.trustedCliShaderHashes, isEmpty);

      final hash = PaneCliShaderState.computeSha256(_validCustomGlslA);
      final custom = defaults.copyWith(
        localCliShaderPolicy: CliShaderPolicy.allowLocalCustomGlsl,
        remoteCliShaderPolicy: CliShaderPolicy.presetsAndTransforms,
        cliFullPaneShaderMode: CliFullPaneShaderMode.askOnConflict,
        trustedCliShaderHashes: {hash, 'not-a-hash'},
      );
      expect(custom.trustedCliShaderHashes, {hash});

      final roundTripped = FtermPreferences.fromJsonString(
        custom.toJsonString(),
      );
      expect(roundTripped, custom);
    });
  });

  group('Local & remote CLI shader policy, SHA-256 trust & watchdog', () {
    test('local defaults allow presets & clamped transforms and retain metadata across incremental recomposites', () async {
      final driver = _FakeLocalHostDriver();
      final relay = _LoopbackRelayPair();
      final storage = _MemorySettingsStorage();
      final backend = _FakeShaderBackend();
      final ws = _createWorkspace(
        driver: driver,
        relay: relay,
        storage: storage,
        backend: backend,
      );
      addTearDown(() async {
        await ws.dispose();
        await relay.close();
      });

      await ws.openLocalShellTab();
      final port = driver.openedPorts.single;
      final pane = ws.focusedPane!;

      // a=query advertises flutter_gpu + glsl=1 + region=1 + xform=1 under default promptCustomGlsl.
      port.feed(tui.ShaderApcEncoder.encodeQuery());
      expect(
        port.replies.single,
        contains(
          'backend=flutter_gpu,glsl=1,xform=1,region=1,max_slots=16,max_regions=8',
        ),
      );

      // Attach built-in 'fire' region + out-of-range scale/duration transform (must clamp).
      port.feed('Hello fire!');
      port.feed(
        '\x1b_Sa=region,id=r1,s=fire,rects=6:0:4:1,pad=2:1:0:1,stage=over\x1b\\',
      );
      port.feed(
        '\x1b_Sa=xform,c=0,r=0,dx=2.0,dy=-1.0,sx=9.0,sy=1.0,aid=5,edy=8.0,dur=99.0\x1b\\',
      );

      expect(pane.displayBuffer.shaderRegions.length, 1);
      expect(pane.displayBuffer.shaderRegions.single.shaderId, 'fire');
      final xf = pane.displayBuffer.getCellTransform(0, 0)!;
      expect(xf.scaleX, 4.0);
      expect(xf.tween!.durationSec, 30.0);

      // Subsequent incremental PTY text update must NOT drop active regions or transforms!
      port.feed(' more text');
      expect(pane.displayBuffer.shaderRegions.length, 1);
      expect(pane.displayBuffer.getCellTransform(0, 0), isNotNull);

      // Entering and exiting ?1049 alt-screen cleans up alt-screen CLI effects without leaking.
      port.feed('\x1b[?1049h');
      port.feed('\x1b_Sa=region,id=alt_r,s=neon_pulse,rects=0:0:4:1\x1b\\');
      expect(
        pane.displayBuffer.shaderRegions.any((r) => r.id == 'alt_r'),
        isTrue,
      );
      port.feed('\x1b[?1049l');
      expect(
        pane.displayBuffer.shaderRegions.any((r) => r.id == 'alt_r'),
        isFalse,
      );

      // RIS (ESC c) resets all CLI regions and transforms.
      port.feed('\x1bc');
      expect(pane.displayBuffer.shaderRegions, isEmpty);
      expect(pane.displayBuffer.hasCellTransforms, isFalse);
    });

    test('enforces <= 4 pending SHA-256 prompts, pinned-hash approval, remembered bypass, and Deny All', () async {
      final driver = _FakeLocalHostDriver();
      final relay = _LoopbackRelayPair();
      final storage = _MemorySettingsStorage();
      final backend = _FakeShaderBackend();
      final ws = _createWorkspace(
        driver: driver,
        relay: relay,
        storage: storage,
        backend: backend,
      );
      addTearDown(() async {
        await ws.dispose();
        await relay.close();
      });

      await ws.openLocalShellTab();
      final port = driver.openedPorts.single;
      final pane = ws.focusedPane!;

      // Send 6 distinct custom GLSL shaders: only first 4 may queue prompts.
      for (var i = 0; i < 6; i++) {
        final src =
            'void mainImage(out vec4 c, in vec2 u) { c = vec4(0.$i, 0.2, 0.3, 1.0); }';
        for (final frame in tui.ShaderApcEncoder.encodeDefine(
          id: 'custom_$i',
          glslSource: src,
        )) {
          port.feed(frame);
        }
      }
      expect(ws.pendingCliShaderApprovals.length, 4);

      // Region referencing unapproved custom_0 must NOT appear on displayBuffer yet.
      port.feed('\x1b_Sa=region,id=cr0,s=custom_0,rects=0:0:5:1\x1b\\');
      expect(pane.displayBuffer.shaderRegions, isEmpty);

      // Approving a mismatched hash (TOCTOU protection) must NOT activate custom_0.
      ws.approveCliShaderHash('0' * 64, remember: false);
      expect(pane.displayBuffer.shaderRegions, isEmpty);
      expect(ws.pendingCliShaderApprovals.length, 4);

      // Approve custom_0 strictly by its pinned SHA-256 with remember: true.
      final firstApproval = ws.pendingCliShaderApprovals.first;
      ws.approveCliShaderHash(firstApproval.sha256, remember: true);
      await Future<void>.delayed(Duration.zero);

      expect(ws.trustedCliShaderHashes, contains(firstApproval.sha256));
      expect(pane.displayBuffer.shaderRegions.length, 1);
      expect(pane.displayBuffer.shaderRegions.single.shaderId, 'custom_0');
      expect(backend.compiledIds, contains('custom_0'));

      // Deny All clears remaining queued prompts on the pane.
      ws.denyAllPendingCliShaders(pane.paneId);
      expect(ws.pendingCliShaderApprovals, isEmpty);

      // Re-uploading the remembered hash bypasses the prompt immediately.
      for (final frame in tui.ShaderApcEncoder.encodeDefine(
        id: 'custom_0_reused',
        glslSource: firstApproval.glslSource,
      )) {
        port.feed(frame);
      }
      expect(ws.pendingCliShaderApprovals, isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(backend.compiledIds, contains('custom_0_reused'));

      // Pane exit clears all CLI shader state cleanly.
      port.completeExit(0);
      await Future<void>.delayed(Duration.zero);
      expect(pane.displayBuffer.shaderRegions, isEmpty);
      expect(pane.cliShaderRegistry.activeCustomShaderIds, isEmpty);
    });

    test('supports CliFullPaneShaderMode (cliBeforeUser, cliReplacesUser, askOnConflict)', () async {
      final driver = _FakeLocalHostDriver();
      final relay = _LoopbackRelayPair();
      final storage = _MemorySettingsStorage();
      final backend = _FakeShaderBackend();
      final ws = _createWorkspace(
        driver: driver,
        relay: relay,
        storage: storage,
        backend: backend,
      );
      addTearDown(() async {
        await ws.dispose();
        await relay.close();
      });

      await ws.setForegroundShaderChain(['crt_lottes']);
      await ws.openLocalShellTab();
      final port = driver.openedPorts.single;
      final pane = ws.focusedPane!;

      // CLI activates built-in 'scanline_overlay' preset on post/fg stage.
      port.feed('\x1b_Sa=set,stage=post,preset=scanline_overlay,p0=0.75\x1b\\');

      // Default mode = cliBeforeUser -> CLI scanline_overlay runs BEFORE user crt_lottes.
      var resolved = pane.resolveShaderConfig(ws.activeShaderConfig);
      expect(resolved.foregroundPasses.length, 2);
      expect(
        resolved.foregroundPasses[0].preset,
        TerminalShaderPreset.scanlineOverlay,
      );
      expect(
        resolved.foregroundPasses[1].preset,
        TerminalShaderPreset.crtLottes,
      );

      // cliReplacesUser -> CLI scanline_overlay replaces user chain while active.
      ws.setCliFullPaneShaderMode(CliFullPaneShaderMode.cliReplacesUser);
      resolved = pane.resolveShaderConfig(ws.activeShaderConfig);
      expect(resolved.foregroundPasses.length, 1);
      expect(
        resolved.foregroundPasses[0].preset,
        TerminalShaderPreset.scanlineOverlay,
      );

      // askOnConflict -> holds pending conflict banner until user picks.
      ws.setCliFullPaneShaderMode(CliFullPaneShaderMode.askOnConflict);
      expect(ws.activeCliFullPaneConflict, isNotNull);
      resolved = pane.resolveShaderConfig(ws.activeShaderConfig);
      expect(resolved.foregroundPasses.length, 1);
      expect(
        resolved.foregroundPasses[0].preset,
        TerminalShaderPreset.crtLottes,
      );

      ws.resolveCliFullPaneConflict(
        pane.paneId,
        CliFullPaneConflictChoice.cliBeforeUser,
      );
      expect(ws.activeCliFullPaneConflict, isNull);
      resolved = pane.resolveShaderConfig(ws.activeShaderConfig);
      expect(resolved.foregroundPasses.length, 2);
      expect(
        resolved.foregroundPasses[0].preset,
        TerminalShaderPreset.scanlineOverlay,
      );
    });

    test('blocks remote termui_cast 0x1C shaders by default and allows presets when opted in', () async {
      final driver = _FakeLocalHostDriver();
      final relay = _LoopbackRelayPair();
      final storage = _MemorySettingsStorage();
      final backend = _FakeShaderBackend();
      final ws = _createWorkspace(
        driver: driver,
        relay: relay,
        storage: storage,
        backend: backend,
      );
      addTearDown(() async {
        await ws.dispose();
        await relay.close();
      });

      const sessionId = SessionId('remote-sess');
      await ws.repository.connect(retryOnFailure: false);
      relay.deliver(const AuthAcceptedFrame(role: .client, shaderFrames: true));
      relay.deliver(
        const SessionDirectoryFrame(
          sessions: [
            SessionSummary(
              id: sessionId,
              title: 'remote-box',
              cols: 40,
              rows: 12,
            ),
          ],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      ws.openRemoteSessionTab(sessionId);
      final pane = ws.focusedPane!;
      expect(pane.isLocal, isFalse);

      // Deliver initial buffer snapshot so the session slot is synchronized.
      final snapBuf = tui.Buffer.blank(40, 12)
        ..writeString(0, 0, 'Remote', tui.Style.empty);
      relay.deliver(
        BufferSnapshotFrame(
          snapshot: BufferSnapshot.fromBuffer(
            sessionId: sessionId,
            seq: 1,
            buffer: snapBuf,
            cursor: CursorState.origin,
            modes: TerminalModes.defaults,
          ),
        ),
      );
      // Remote 0x1C region + transform must be blocked under default remoteCliShaderPolicy.disabled.
      relay.deliver(
        ShaderFrame(
          sessionId: sessionId,
          payload: CastRegionShaderPayload(
            id: 'rem_fire',
            region: tui.ShaderRegion(
              id: 'rem_fire',
              shaderId: 'fire',
              sourceRects: const [tui.Rect(0, 0, 6, 1)],
            ),
          ),
        ),
      );
      relay.deliver(
        ShaderFrame(
          sessionId: sessionId,
          payload: CastTransformsShaderPayload(
            entries: const [
              (col: 0, row: 0, transform: tui.CellTransform(dx: 1.0)),
            ],
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(pane.displayBuffer.shaderRegions, isEmpty);
      expect(pane.displayBuffer.hasCellTransforms, isFalse);

      // Upgrading remote policy to presetsAndTransforms enables presets & transforms on next event.
      ws.setRemoteCliShaderPolicy(CliShaderPolicy.presetsAndTransforms);
      relay.deliver(
        ShaderFrame(
          sessionId: sessionId,
          payload: CastRegionShaderPayload(
            id: 'rem_fire',
            region: tui.ShaderRegion(
              id: 'rem_fire',
              shaderId: 'fire',
              sourceRects: const [tui.Rect(0, 0, 6, 1)],
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(pane.displayBuffer.shaderRegions.length, 1);

      // Downgrading remote policy back to disabled immediately clears active remote regions.
      ws.setRemoteCliShaderPolicy(CliShaderPolicy.disabled);
      expect(pane.displayBuffer.shaderRegions, isEmpty);
    });

    test('quarantines only offending custom CLI shader ID on watchdog trip and surfaces banner', () async {
      final driver = _FakeLocalHostDriver();
      final relay = _LoopbackRelayPair();
      final storage = _MemorySettingsStorage();
      final backend = _FakeShaderBackend();
      final ws = _createWorkspace(
        driver: driver,
        relay: relay,
        storage: storage,
        backend: backend,
      );
      addTearDown(() async {
        await ws.dispose();
        await relay.close();
      });

      ws.setLocalCliShaderPolicy(CliShaderPolicy.allowLocalCustomGlsl);
      await ws.openLocalShellTab();
      final port = driver.openedPorts.single;
      final pane = ws.focusedPane!;

      for (final frame in tui.ShaderApcEncoder.encodeDefine(
        id: 'slow_custom',
        glslSource: _validCustomGlslA,
      )) {
        port.feed(frame);
      }
      port.feed('\x1b_Sa=region,id=r_custom,s=slow_custom,rects=0:0:4:1\x1b\\');
      port.feed('\x1b_Sa=region,id=r_preset,s=fire,rects=5:0:4:1\x1b\\');
      port.feed('\x1b_Sa=xform,c=0,r=0,dx=1.5\x1b\\');
      await Future<void>.delayed(Duration.zero);

      expect(pane.displayBuffer.shaderRegions.length, 2);
      expect(
        pane.gpuFrameWatchdog.activeCustomShaderIds,
        contains('slow_custom'),
      );

      // Trip watchdog with warmup + 3 consecutive >33ms frames on slow_custom.
      final totalSlowFrames =
          pane.gpuFrameWatchdog.warmupFramesRemainingFor('slow_custom') + 3;
      for (var i = 0; i < totalSlowFrames; i++) {
        pane.gpuFrameWatchdog.recordShaderFrameDuration(
          'slow_custom',
          const Duration(milliseconds: 50),
        );
      }

      expect(pane.cliShaderRegistry.isQuarantined('slow_custom'), isTrue);
      expect(ws.statusBanner, contains('slow_custom'));
      // Custom region removed; built-in 'fire' preset and cell transform remain intact!
      expect(pane.displayBuffer.shaderRegions.map((r) => r.shaderId).toList(), [
        'fire',
      ]);
      expect(pane.displayBuffer.getCellTransform(0, 0), isNotNull);
    });

    test('coalesces local a=xforms recomposites, preserves cellContentRevision/regionRevision, and activates all pending IDs sharing a SHA-256 (H2, L1, L3)', () async {
      final driver = _FakeLocalHostDriver();
      final relay = _LoopbackRelayPair();
      final storage = _MemorySettingsStorage();
      final backend = _FakeShaderBackend();
      final ws = _createWorkspace(
        driver: driver,
        relay: relay,
        storage: storage,
        backend: backend,
      );
      addTearDown(() async {
        await ws.dispose();
        await relay.close();
      });

      await ws.openLocalShellTab();
      final port = driver.openedPorts.single;
      final pane = ws.focusedPane!;

      // Attach a built-in fire region and settle initial compile.
      port.feed('HELLO');
      port.feed('\x1b_Sa=region,id=r_fire,s=fire,rects=0:0:5:1\x1b\\');
      await Future<void>.delayed(Duration.zero);
      expect(pane.cliShaderRegistry.handleForShader('fire'), isNotNull);
      final compileCountAfterFire = backend.compiledIds.length;
      final signal = pane.bufferListenable as TerminalBufferChangeSignal;
      final contentRevBefore = signal.cellContentRevision;
      final regionRevBefore = pane.displayBuffer.regionRevision;

      var visualNotifications = 0;
      pane.bufferListenable.addListener(() => visualNotifications++);

      // Feed a pure a=xforms keyframe burst (no cell text changes).
      port.feed('\x1b_Sa=xform,c=0,r=0,dx=1.5,dy=0.5\x1b\\', dirtyCells: false);
      await Future<void>.delayed(Duration.zero);

      // H2: Coalesced to 1 notification, cellContentRevision & regionRevision unchanged.
      expect(visualNotifications, equals(1));
      expect(signal.cellContentRevision, equals(contentRevBefore));
      expect(pane.displayBuffer.regionRevision, equals(regionRevBefore));
      // L3: Already-compiled preset is not re-compiled.
      expect(backend.compiledIds.length, equals(compileCountAfterFire));

      // L1: Two distinct shader IDs uploading identical GLSL share one prompt
      // and BOTH activate on approval.
      for (final frame in tui.ShaderApcEncoder.encodeDefine(
        id: 'alias_a',
        glslSource: _validCustomGlslA,
      )) {
        port.feed(frame);
      }
      for (final frame in tui.ShaderApcEncoder.encodeDefine(
        id: 'alias_b',
        glslSource: _validCustomGlslA,
      )) {
        port.feed(frame);
      }
      final hash = PaneCliShaderState.computeSha256(_validCustomGlslA);
      expect(ws.pendingCliShaderApprovals.length, equals(1));
      ws.approveCliShaderHash(hash, remember: false);
      await Future<void>.delayed(Duration.zero);

      expect(pane.cliShaderRegistry.handleForShader('alias_a'), isNotNull);
      expect(pane.cliShaderRegistry.handleForShader('alias_b'), isNotNull);
    });

    test('H7: local pane trusts src exclusively on altScreen and scroll-off without ghost overlays, and preserves primary custom GLSL across altScreen exit', () async {
      final driver = _FakeLocalHostDriver();
      final relay = _LoopbackRelayPair();
      final storage = _MemorySettingsStorage();
      final backend = _FakeShaderBackend();
      final ws = _createWorkspace(
        driver: driver,
        relay: relay,
        storage: storage,
        backend: backend,
      );
      addTearDown(() async {
        await ws.dispose();
        await relay.close();
      });

      ws.setLocalCliShaderPolicy(CliShaderPolicy.allowLocalCustomGlsl);
      await ws.openLocalShellTab();
      final port = driver.openedPorts.single;
      final pane = ws.focusedPane!;

      // 1. Primary screen: define custom shader + attach region + transform.
      for (final frame in tui.ShaderApcEncoder.encodeDefine(
        id: 'primary_fx',
        glslSource: _validCustomGlslA,
      )) {
        port.feed(frame);
      }
      port.feed('PRIMARY');
      port.feed('\x1b_Sa=region,id=r_prim,s=primary_fx,rects=0:0:7:1\x1b\\');
      port.feed('\x1b_Sa=xform,c=0,r=0,dx=2.0\x1b\\');
      await Future<void>.delayed(Duration.zero);
      expect(pane.displayBuffer.shaderRegions.map((r) => r.id), ['r_prim']);
      expect(pane.displayBuffer.getCellTransform(0, 0), isNotNull);

      // 2. Enter altScreen: primary overlays must NOT leak as ghosts!
      port.feed('\x1b[?1049h');
      expect(pane.displayBuffer.shaderRegions, isEmpty);
      expect(pane.displayBuffer.hasCellTransforms, isFalse);

      // Define an alt-screen-only custom shader and exit altScreen.
      for (final frame in tui.ShaderApcEncoder.encodeDefine(
        id: 'alt_only_fx',
        glslSource: _validCustomGlslB,
      )) {
        port.feed(frame);
      }
      await Future<void>.delayed(Duration.zero);
      expect(pane.cliShaderRegistry.handleForShader('alt_only_fx'), isNotNull);

      port.feed('\x1b[?1049l');
      await Future<void>.delayed(Duration.zero);

      // Alt-only shader removed; primary custom GLSL + region + transform preserved!
      expect(pane.cliShaderRegistry.handleForShader('alt_only_fx'), isNull);
      expect(pane.cliShaderRegistry.handleForShader('primary_fx'), isNotNull);
      expect(pane.displayBuffer.shaderRegions.map((r) => r.id), ['r_prim']);
      expect(pane.displayBuffer.getCellTransform(0, 0), isNotNull);

      // 3. Scroll the region completely off-screen -> must disappear (no ghost!).
      port.feed('\n' * 20);
      expect(pane.displayBuffer.shaderRegions, isEmpty);
      expect(pane.displayBuffer.hasCellTransforms, isFalse);
    });
  });

  group('FtermShellScaffold trust banner & Settings policy UI', () {
    testWidgets(
      'shows non-blocking SHA-256 trust banner and Settings policy controls',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1024, 768));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final driver = _FakeLocalHostDriver();
        final relay = _LoopbackRelayPair();
        final storage = _MemorySettingsStorage();
        final backend = _FakeShaderBackend();
        final ws = _createWorkspace(
          driver: driver,
          relay: relay,
          storage: storage,
          backend: backend,
        );
        addTearDown(() async {
          await ws.dispose();
          await relay.close();
        });

        await ws.openLocalShellTab();
        final port = driver.openedPorts.single;

        await tester.pumpWidget(
          MaterialApp(
            home: FtermShellScaffold(
              workspace: ws,
              onOpenUrl: (_) {},
              platformOverride: TargetPlatform.linux,
              isWebOverride: false,
            ),
          ),
        );
        await tester.pump();

        // Upload custom GLSL -> non-blocking SHA-256 approval banner appears.
        for (final frame in tui.ShaderApcEncoder.encodeDefine(
          id: 'banner_shader',
          glslSource: _validCustomGlslB,
        )) {
          port.feed(frame);
        }
        await tester.pump();

        expect(
          find.byKey(const ValueKey('cli-shader-approval-banner')),
          findsOneWidget,
        );
        expect(find.textContaining('banner_shader'), findsOneWidget);

        // Tap "Always Trust Hash" -> dismisses banner and persists hash.
        await tester.tap(find.byKey(const ValueKey('cli-shader-trust-hash')));
        await tester.pump();

        expect(
          find.byKey(const ValueKey('cli-shader-approval-banner')),
          findsNothing,
        );
        expect(
          ws.trustedCliShaderHashes,
          contains(PaneCliShaderState.computeSha256(_validCustomGlslB)),
        );

        // Open Settings overlay -> CLI policy section and trusted hash reset appear.
        ws.setOverlay(FtermOverlay.settings);
        await tester.pump();

        expect(
          find.byKey(const ValueKey('settings-cli-shader-policy-section')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('settings-local-cli-shader-policy')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('settings-remote-cli-shader-policy')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('settings-cli-dev-auto-trust')),
          findsOneWidget,
        );

        // Reset Trusted Hashes clears persisted hashes.
        await tester.ensureVisible(
          find.byKey(const ValueKey('settings-reset-trusted-cli-hashes')),
        );
        await tester.tap(
          find.byKey(const ValueKey('settings-reset-trusted-cli-hashes')),
        );
        await tester.pump();
        expect(ws.trustedCliShaderHashes, isEmpty);
      },
    );

    testWidgets(
      'surfaces blocked remote 0x1C shader banner, enables policy with keyframe replay, and forwards DECTCEM cursorVisibleProvider to TerminalSurface',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1024, 768));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final driver = _FakeLocalHostDriver();
        final relay = _LoopbackRelayPair();
        final storage = _MemorySettingsStorage();
        final backend = _FakeShaderBackend();
        final sentByClient = <CastMessage>[];
        final clientSub = relay.controller.foreign.stream.listen((bytes) {
          sentByClient.add(BufferFrameCodec.decode(bytes));
        });
        final ws = _createWorkspace(
          driver: driver,
          relay: relay,
          storage: storage,
          backend: backend,
        );
        addTearDown(() async {
          await clientSub.cancel();
          unawaited(relay.close());
          await ws.dispose();
        });

        await ws.openLocalShellTab();
        final localPort = driver.openedPorts.single;
        final localPane = ws.focusedPane!;

        await tester.pumpWidget(
          MaterialApp(
            home: FtermShellScaffold(
              workspace: ws,
              onOpenUrl: (_) {},
              platformOverride: TargetPlatform.linux,
              isWebOverride: false,
            ),
          ),
        );
        await tester.pump();

        // TerminalSurface must receive cursorVisibleProvider wired to DECTCEM (?25l / ?25h).
        final surface = tester.widget<TerminalSurface>(
          find.byType(TerminalSurface),
        );
        expect(surface.cursorVisibleProvider, isNotNull);
        expect(surface.cursorVisibleProvider!(), isTrue);
        expect(localPane.cursorVisible, isTrue);

        localPort.feed('\x1b[?25l');
        expect(localPane.cursorVisible, isFalse);
        expect(surface.cursorVisibleProvider!(), isFalse);

        localPort.feed('\x1b[?25h');
        expect(localPane.cursorVisible, isTrue);
        expect(surface.cursorVisibleProvider!(), isTrue);

        // Connect remote session and deliver a blocked 0x1C ShaderFrame under default disabled policy.
        const sessionId = SessionId('remote-shader-banner');
        await ws.repository.connect(retryOnFailure: false);
        relay.deliver(
          const AuthAcceptedFrame(role: .client, shaderFrames: true),
        );
        relay.deliver(
          const SessionDirectoryFrame(
            sessions: [
              SessionSummary(
                id: sessionId,
                title: 'cast-fire',
                cols: 40,
                rows: 12,
              ),
            ],
          ),
        );
        await tester.pump(const Duration(milliseconds: 20));

        ws.openRemoteSessionTab(sessionId);
        await tester.pump();

        relay.deliver(
          ShaderFrame(
            sessionId: sessionId,
            payload: CastRegionShaderPayload(
              id: 'r_fire',
              region: tui.ShaderRegion(
                id: 'r_fire',
                shaderId: 'fire',
                sourceRects: const [tui.Rect(0, 0, 5, 1)],
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 20));

        expect(ws.activeBlockedRemoteShadersNotice, isNotNull);
        expect(
          find.byKey(const ValueKey('cli-remote-shaders-blocked-banner')),
          findsOneWidget,
        );

        // Tapping "Allow & Prompt Custom GLSL" upgrades policy, dismisses notice,
        // and sends a RequestKeyframeFrame so the caster replays active shaders.
        sentByClient.clear();
        await tester.tap(
          find.byKey(const ValueKey('cli-remote-enable-prompt-glsl')),
        );
        await tester.pump(const Duration(milliseconds: 20));

        expect(ws.remoteCliShaderPolicy, CliShaderPolicy.promptCustomGlsl);
        expect(ws.activeBlockedRemoteShadersNotice, isNull);
        expect(
          find.byKey(const ValueKey('cli-remote-shaders-blocked-banner')),
          findsNothing,
        );
        expect(
          sentByClient.any(
            (m) => m is RequestKeyframeFrame && m.sessionId == sessionId,
          ),
          isTrue,
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );

    test('CliShaderPolicy.presetsAndTransforms allows one_ring, vortex, forge_spark, water_ripple regions and retro_phosphor full-pane preset', () async {
      final driver = _FakeLocalHostDriver();
      final relay = _LoopbackRelayPair();
      final storage = _MemorySettingsStorage();
      final backend = _FakeShaderBackend();
      final ws = _createWorkspace(
        driver: driver,
        relay: relay,
        storage: storage,
        backend: backend,
      );
      addTearDown(() async {
        await ws.dispose();
        await relay.close();
      });

      ws.setLocalCliShaderPolicy(CliShaderPolicy.presetsAndTransforms);
      await ws.openLocalShellTab();
      final port = driver.openedPorts.single;
      final pane = ws.focusedPane!;

      const presets = <String>[
        'one_ring',
        'vortex',
        'forge_spark',
        'water_ripple',
      ];
      for (var i = 0; i < presets.length; i++) {
        final id = presets[i];
        port.feed(
          '\x1b_Sa=region,id=r_$id,s=$id,rects=${i * 4}:0:4:1,stage=over\x1b\\',
        );
      }
      port.feed('\x1b_Sa=set,stage=post,preset=retro_phosphor,p0=0.2\x1b\\');

      expect(
        pane.displayBuffer.shaderRegions.map((r) => r.shaderId).toSet(),
        equals(presets.toSet()),
      );
      final effective = pane.resolveShaderConfig(ws.activeShaderConfig);
      expect(
        effective.foregroundPasses.map((p) => p.preset),
        contains(TerminalShaderPreset.retroPhosphor),
      );
    });

    test('M1: applyOverlaysToBuffer does not bump transformRevision on unchanged recomposites', () {
      // Local pane path: src buffer carries active transforms.
      final localState = PaneCliShaderState(
        paneId: 'pane-local',
        isLocal: true,
        initialPolicy: CliShaderPolicy.promptCustomGlsl,
        initialFullPaneMode: CliFullPaneShaderMode.cliBeforeUser,
        trustedHashes: const <String>{},
        readPaneLabel: () => 'local',
        onVisualStateChanged: () {},
        onPolicyUiChanged: () {},
      );
      addTearDown(localState.dispose);

      final localSrc = tui.Buffer.blank(20, 8)
        ..setCellTransform(1, 1, const tui.CellTransform(dx: 2.0));
      final localOut = tui.Buffer.blank(20, 8);

      localState.applyOverlaysToBuffer(localOut, localSrc);
      expect(localOut.getCellTransform(1, 1), isNotNull);
      final localRev1 = localOut.transformRevision;

      // Second recomposite with unchanged src (e.g. cursor blink).
      localState.applyOverlaysToBuffer(localOut, localSrc);
      expect(localOut.transformRevision, equals(localRev1));

      // Toggling policy disabled -> enabled invalidates cache and reapplies cleanly.
      localState.updatePolicy(
        policy: CliShaderPolicy.disabled,
        fullPaneMode: CliFullPaneShaderMode.cliBeforeUser,
        trustedHashes: const <String>{},
        userHasFullPaneShaders: false,
      );
      localState.applyOverlaysToBuffer(localOut, localSrc);
      expect(localOut.hasCellTransforms, isFalse);

      localState.updatePolicy(
        policy: CliShaderPolicy.promptCustomGlsl,
        fullPaneMode: CliFullPaneShaderMode.cliBeforeUser,
        trustedHashes: const <String>{},
        userHasFullPaneShaders: false,
      );
      localState.applyOverlaysToBuffer(localOut, localSrc);
      expect(localOut.getCellTransform(1, 1), isNotNull);

      // Mutating src transform still propagates to out.
      localSrc.setCellTransform(1, 1, const tui.CellTransform(dx: 3.0));
      localState.applyOverlaysToBuffer(localOut, localSrc);
      expect(localOut.getCellTransform(1, 1)?.dx, equals(3.0));

      // Remote pane path: _activeTransforms carries active transforms.
      final remoteState = PaneCliShaderState(
        paneId: 'pane-remote',
        isLocal: false,
        initialPolicy: CliShaderPolicy.presetsAndTransforms,
        initialFullPaneMode: CliFullPaneShaderMode.cliBeforeUser,
        trustedHashes: const <String>{},
        readPaneLabel: () => 'remote',
        onVisualStateChanged: () {},
        onPolicyUiChanged: () {},
      );
      addTearDown(remoteState.dispose);

      remoteState.handleShaderEvent(
        TerminalShaderTransformBatchEvent(
          entries: const [
            (col: 2, row: 1, transform: tui.CellTransform(dx: 1.5)),
          ],
        ),
      );
      final remoteSrc = tui.Buffer.blank(20, 8);
      final remoteOut = tui.Buffer.blank(20, 8);

      remoteState.applyOverlaysToBuffer(remoteOut, remoteSrc);
      expect(remoteOut.getCellTransform(2, 1), isNotNull);
      final remoteRev1 = remoteOut.transformRevision;

      remoteState.applyOverlaysToBuffer(remoteOut, remoteSrc);
      expect(remoteOut.transformRevision, equals(remoteRev1));
    });

    test('M7: user-approved alt-screen custom GLSL shaders are evicted on altScreenExit', () async {
      final backend = _FakeShaderBackend();
      final state = PaneCliShaderState(
        paneId: 'pane-m7',
        isLocal: true,
        initialPolicy: CliShaderPolicy.promptCustomGlsl,
        initialFullPaneMode: CliFullPaneShaderMode.cliBeforeUser,
        trustedHashes: const <String>{},
        readPaneLabel: () => 'local',
        onVisualStateChanged: () {},
        onPolicyUiChanged: () {},
        backend: backend,
      );
      addTearDown(state.dispose);

      // Path 1: approveHash on a pending custom GLSL defined while onAltScreen: true.
      state.handleShaderEvent(
        const TerminalShaderDefineEvent(
          id: 'alt_fx',
          glslSource: _validCustomGlslA,
        ),
        onAltScreen: true,
      );
      final hashA = PaneCliShaderState.computeSha256(_validCustomGlslA);
      expect(state.approveHash(hashA, remember: false), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(state.registry.handleForShader('alt_fx'), isNotNull);

      state.handleShaderEvent(
        const TerminalResetShaderEvent(
          target: ShaderResetTarget.all,
          altScreenExit: true,
        ),
      );
      expect(state.registry.handleForShader('alt_fx'), isNull);

      // Path 2: _promoteNowTrustedPending via updatePolicy on a pending alt-screen shader.
      state.handleShaderEvent(
        const TerminalShaderDefineEvent(
          id: 'alt_fx_promoted',
          glslSource: _validCustomGlslB,
        ),
        onAltScreen: true,
      );
      final hashB = PaneCliShaderState.computeSha256(_validCustomGlslB);
      state.updatePolicy(
        policy: CliShaderPolicy.promptCustomGlsl,
        fullPaneMode: CliFullPaneShaderMode.cliBeforeUser,
        trustedHashes: <String>{hashB},
        userHasFullPaneShaders: false,
      );
      await Future<void>.delayed(Duration.zero);
      expect(state.registry.handleForShader('alt_fx_promoted'), isNotNull);

      state.handleShaderEvent(
        const TerminalResetShaderEvent(
          target: ShaderResetTarget.all,
          altScreenExit: true,
        ),
      );
      expect(state.registry.handleForShader('alt_fx_promoted'), isNull);
    });
  });
}
