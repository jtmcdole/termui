import 'dart:async';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/font_loader.dart';
import 'package:fterm/src/fterm_app.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/update/update_service.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver.dart';
import 'package:material_ui/material_ui.dart';
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_pty/termui_pty.dart';

import 'support/app_three_way_harness.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadCastFonts();
  });

  group('Desktop Updates UI, badges, corner pills, and lifecycle checks', () {
    testWidgets(
      'shows Settings badge dot, UPDATE / RESTART TO UPDATE corner pill in autoHideSingleTab, isolated progress ticks, session warning, and Apply on Quit',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(960, 680));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final storage = _MemorySettingsStorage();
        final fakeUpdate = _ControllableUpdateService(
          capability: SelfUpdateCapability.supported,
        );
        final localDriver = _FakeDesktopLocalHostDriver();
        final openedUrls = <Uri>[];

        FtermWorkspaceController? workspace;
        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(),
            localHostDriver: localDriver,
            settingsStorage: storage,
            updateService: fakeUpdate,
            onOpenUrl: openedUrls.add,
            isWebOverride: false,
            resizeDebounce: Duration.zero,
            onWorkspaceCreated: (ws) => workspace = ws,
          ),
        );
        await settleCastApp(tester);

        // No badge dot before check.
        expect(
          find.byKey(const ValueKey('fterm-settings-update-dot')),
          findsNothing,
        );

        // Enable autoHideSingleTab so single-tab workspace hides the top tab bar.
        workspace!.updatePreferences(
          workspace!.preferences.copyWith(autoHideSingleTab: true),
        );
        await tester.pump();
        expect(workspace!.shouldShowTabBar, isFalse);

        // Open Settings -> Updates and click "Check for Updates".
        workspace!.openSettingsOverlay(initialSection: .updates);
        await tester.pump();
        expect(
          find.byKey(const ValueKey('settings-updates-section')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('settings-update-current-version')),
          findsOneWidget,
        );

        await tester.ensureVisible(
          find.byKey(const ValueKey('settings-update-check')),
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('settings-update-check')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));

        expect(
          workspace!.updateViewModel.status,
          equals(UpdateStatus.available),
        );
        expect(find.textContaining('fterm v0.3.0 available'), findsOneWidget);

        // Release Notes link invokes onOpenUrl.
        await tester.ensureVisible(
          find.byKey(const ValueKey('settings-update-release-link')),
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('settings-update-release-link')),
        );
        await tester.pump();
        expect(
          openedUrls,
          contains(
            Uri.parse(
              'https://github.com/jtmcdole/termui/releases/tag/fterm-v0.3.0',
            ),
          ),
        );

        // Dismiss Settings: verify corner pill displays 'UPDATE' while tab bar is hidden,
        // and Settings icon displays badge dot once a 2nd tab makes the tab bar visible.
        workspace!.dismissOverlay();
        await tester.pump();
        final firstPaneId = workspace!.focusedPane!.paneId;
        final pillTextBefore = tester.widget<Text>(
          find.descendant(
            of: find.byKey(ValueKey('pane-pill-$firstPaneId')),
            matching: find.byType(Text),
          ),
        );
        expect(pillTextBefore.data, contains('UPDATE'));

        // Open 2nd local shell tab + mark it live-shared so tab bar is visible AND session counts are (2 shells, 1 broadcast).
        await tester.runAsync(() => workspace!.openLocalShellTab());
        localDriver.hosts.last.setLiveBroadcast();
        await tester.pump();
        expect(workspace!.shouldShowTabBar, isTrue);
        expect(
          find.byKey(const ValueKey('fterm-settings-update-dot')),
          findsOneWidget,
        );

        // Re-open Settings and click Download Update; verify progress ticks do NOT fire chromeNotifier!
        workspace!.setOverlay(FtermOverlay.settings);
        await tester.pump();

        var chromeTicksDuringChunks = 0;
        void countChrome() => chromeTicksDuringChunks += 1;

        await tester.ensureVisible(
          find.byKey(const ValueKey('settings-update-download')),
        );
        await tester.tap(
          find.byKey(const ValueKey('settings-update-download')),
        );
        await tester.pump();
        expect(
          workspace!.updateViewModel.status,
          equals(UpdateStatus.downloading),
        );
        expect(
          find.byKey(const ValueKey('settings-update-progress')),
          findsOneWidget,
        );

        workspace!.chromeNotifier.addListener(countChrome);
        fakeUpdate.emitProgress(256, 1024);
        await tester.pump();
        fakeUpdate.emitProgress(768, 1024);
        await tester.pump();
        expect(chromeTicksDuringChunks, equals(0));
        workspace!.chromeNotifier.removeListener(countChrome);

        // Complete staging -> readyToRestart.
        fakeUpdate.completeStage();
        await tester.pump();
        await tester.pump();
        expect(
          workspace!.updateViewModel.status,
          equals(UpdateStatus.readyToRestart),
        );

        // Collapse back to 1 tab to verify corner pill updates to 'RESTART TO UPDATE'!
        workspace!.dismissOverlay();
        await tester.runAsync(() => workspace!.closeTab(0));
        await tester.pump();
        expect(workspace!.shouldShowTabBar, isFalse);
        final remainingPaneId = workspace!.focusedPane!.paneId;
        final pillTextReady = tester.widget<Text>(
          find.descendant(
            of: find.byKey(ValueKey('pane-pill-$remainingPaneId')),
            matching: find.byType(Text),
          ),
        );
        expect(pillTextReady.data, contains('RESTART TO UPDATE'));

        // Re-open Settings: clicking Restart to Update with 1 active shell + 1 live broadcast shows confirmation warning first!
        workspace!.setOverlay(FtermOverlay.settings);
        await tester.pump();
        await tester.ensureVisible(
          find.byKey(const ValueKey('settings-update-restart')),
        );
        await tester.tap(find.byKey(const ValueKey('settings-update-restart')));
        await tester.pump();

        expect(fakeUpdate.applyCalls, isEmpty);
        final warningText = tester.widget<Text>(
          find.byKey(const ValueKey('settings-update-restart-warning')),
        );
        expect(warningText.data, contains('1 active local shell'));
        expect(warningText.data, contains('1 live broadcast'));

        // Cancel confirmation, arm "Apply update on quit", and request app exit!
        await tester.tap(
          find.byKey(const ValueKey('settings-update-cancel-restart')),
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('settings-update-apply-on-quit')),
        );
        await tester.pump();
        expect(workspace!.updateViewModel.applyOnQuit, isTrue);

        await tester.runAsync(() => tester.binding.handleRequestAppExit());
        expect(fakeUpdate.applyCalls, hasLength(1));
        expect(fakeUpdate.applyCalls.single.relaunch, isFalse);

        await tester.runAsync(() => workspace!.dispose());
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'hides Updates section on Web, supports Skip Version + read-only release link, and runs 10s daily + 24h resumed checks with zero leaked timers',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        // 1. Web host hides Updates section completely.
        final harness = AppThreeWayWsHarness();
        FtermWorkspaceController? webWs;
        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(token: harness.token),
            channelFactory: harness.openClientChannel,
            isWebOverride: true,
            resizeDebounce: Duration.zero,
            onWorkspaceCreated: (ws) => webWs = ws,
          ),
        );
        await settleCastApp(tester);
        webWs!.setOverlay(FtermOverlay.settings);
        await tester.pump();
        expect(
          find.byKey(const ValueKey('settings-updates-section')),
          findsNothing,
        );
        await tester.runAsync(() => webWs!.dispose());
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(harness.dispose);

        // 2. Desktop daily mode delays 10s, skips skippedUpdateVersion on background checks,
        //    and re-checks on AppLifecycleState.resumed after >= 24h.
        var now = DateTime.utc(2026, 11, 16, 12, 0);
        final clock = Clock(() => now);
        final storage = _MemorySettingsStorage();
        saveStoredPreferences(
          storage,
          const FtermPreferences(updateCheckMode: UpdateCheckMode.daily),
        );
        final readOnlyUpdate = _ControllableUpdateService(
          capability: SelfUpdateCapability.readOnlyOrNonPortable,
        );

        FtermWorkspaceController? desktopWs;
        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(),
            settingsStorage: storage,
            updateService: readOnlyUpdate,
            clock: clock,
            isWebOverride: false,
            resizeDebounce: Duration.zero,
            onWorkspaceCreated: (ws) => desktopWs = ws,
          ),
        );
        await tester.pump();

        // Before 10s elapses, automatic daily check has NOT fired yet.
        await tester.pump(const Duration(seconds: 9));
        expect(readOnlyUpdate.checkCount, equals(0));

        // At 10s, daily check fires and discovers v0.3.0.
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(readOnlyUpdate.checkCount, equals(1));
        expect(
          desktopWs!.updateViewModel.status,
          equals(UpdateStatus.available),
        );

        // Read-only install shows "Open GitHub Release" instead of "Download Update", plus "Skip Version".
        desktopWs!.openSettingsOverlay(initialSection: .updates);
        await tester.pump();
        expect(
          find.byKey(const ValueKey('settings-update-open-release')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('settings-update-download')),
          findsNothing,
        );

        // Click Skip Version -> clears available state and persists skippedUpdateVersion = '0.3.0'.
        await tester.ensureVisible(
          find.byKey(const ValueKey('settings-update-skip')),
        );
        await tester.tap(find.byKey(const ValueKey('settings-update-skip')));
        await tester.pump();
        expect(desktopWs!.updateViewModel.status, equals(UpdateStatus.idle));
        expect(desktopWs!.preferences.skippedUpdateVersion, equals('0.3.0'));

        // Advance clock by 25 hours and simulate AppLifecycleState.resumed:
        // check fires, sees skipped 0.3.0 on background check, and stays idle!
        now = now.add(const Duration(hours: 25));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(readOnlyUpdate.checkCount, equals(2));
        expect(desktopWs!.updateViewModel.status, equals(UpdateStatus.idle));

        // Clean unmount with zero pending timers!
        await tester.runAsync(() => desktopWs!.dispose());
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'surfaces Reveal Staged App in Finder when macOS App Management TCC blocks in-place .app swap',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final tccService = _ControllableUpdateService(
          capability: SelfUpdateCapability.supported,
          simulateMacosTccDeniedOnApply: true,
        );
        FtermWorkspaceController? ws;
        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(),
            updateService: tccService,
            isWebOverride: false,
            resizeDebounce: Duration.zero,
            onWorkspaceCreated: (created) => ws = created,
          ),
        );
        await tester.pump();

        await ws!.updateViewModel.checkForUpdates();
        unawaited(ws!.updateViewModel.downloadAvailableUpdate());
        await tester.pump();
        tccService.completeStage();
        await tester.pump();
        expect(ws!.updateViewModel.status, equals(UpdateStatus.readyToRestart));

        // Open Settings -> Updates and click Restart to Update (0 local shells -> runs immediately, hits TCC EPERM!).
        ws!.openSettingsOverlay(initialSection: .updates);
        await tester.pump();
        await tester.ensureVisible(
          find.byKey(const ValueKey('settings-update-restart')),
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('settings-update-restart')));
        await tester.pump();
        await tester.pump();

        expect(ws!.updateViewModel.status, equals(UpdateStatus.error));
        expect(
          find.byKey(const ValueKey('settings-update-reveal-finder')),
          findsOneWidget,
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('settings-update-reveal-finder')),
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('settings-update-reveal-finder')),
        );
        await tester.pump();
        expect(tccService.revealedCount, equals(1));

        await tester.runAsync(() => ws!.dispose());
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });
}

final class _MemorySettingsStorage implements SettingsStorage {
  final Map<String, String> _map = {};

  @override
  String? getItem(String key) => _map[key];

  @override
  void setItem(String key, String value) => _map[key] = value;
}

final class _ControllableUpdateService implements UpdateService {
  @override
  final FtermSemVer currentVersion = FtermSemVer.parse('0.2.2');

  @override
  SelfUpdateCapability capability;

  final bool simulateMacosTccDeniedOnApply;
  int checkCount = 0;
  int revealedCount = 0;
  void Function(DownloadProgress progress)? _progressListener;
  Completer<StagedUpdate>? _stageCompleter;
  final List<({StagedUpdate staged, bool relaunch})> applyCalls = [];

  _ControllableUpdateService({
    required this.capability,
    this.simulateMacosTccDeniedOnApply = false,
  });

  AvailableUpdate get _sampleRelease => AvailableUpdate(
    version: FtermSemVer.parse('0.3.0'),
    tagName: 'fterm-v0.3.0',
    htmlUrl: Uri.parse(
      'https://github.com/jtmcdole/termui/releases/tag/fterm-v0.3.0',
    ),
    notes: '## 0.3.0\nPortable desktop updates and faster rendering.',
    asset: ReleaseAssetInfo(
      name: 'fterm-windows-x64.zip',
      browserDownloadUrl: Uri.parse('https://example.com/fterm.zip'),
      size: 1024,
      sha256Hex: 'a' * 64,
    ),
  );

  @override
  Future<UpdateCheckOutcome> checkForUpdates({
    required bool includePrereleases,
    String? lastEtag,
    List<String> cachedTags = const [],
  }) async {
    checkCount += 1;
    return UpdateCheckOutcome(
      availableUpdate: _sampleRelease,
      tagEtag: 'W/"etag"',
      cachedTags: const ['fterm-v0.3.0'],
      cacheTagState: true,
    );
  }

  @override
  Future<StagedUpdate> stageUpdate(
    AvailableUpdate update, {
    void Function(DownloadProgress progress)? onProgress,
  }) {
    _progressListener = onProgress;
    final completer = Completer<StagedUpdate>();
    _stageCompleter = completer;
    return completer.future;
  }

  void emitProgress(int received, int total) {
    _progressListener?.call(
      DownloadProgress(receivedBytes: received, totalBytes: total),
    );
  }

  void completeStage() {
    _stageCompleter?.complete(
      StagedUpdate(
        update: _sampleRelease,
        stagingDirPath: '/tmp/.fterm-update',
        stagedPayloadPath: '/tmp/.fterm-update/extracted',
        portableRootPath: '/tmp/fterm',
        manifestEntries: const ['fterm.exe'],
      ),
    );
  }

  @override
  bool hasSiblingInstances() => false;

  @override
  bool prepareExclusiveSwapLock() => true;

  @override
  void cancelExclusiveSwapLock() {}

  @override
  Future<void> applyStagedUpdateAndExit(
    StagedUpdate staged, {
    required bool relaunch,
    List<String> relaunchArgs = const [],
    Future<void> Function()? beforeExitTeardown,
  }) async {
    if (beforeExitTeardown != null) {
      await beforeExitTeardown();
    }
    if (simulateMacosTccDeniedOnApply) {
      capability = SelfUpdateCapability.macosAppManagementDenied;
      throw const UpdateException(
        'App Management permission required.',
        isMacosPermissionDenied: true,
      );
    }
    applyCalls.add((staged: staged, relaunch: relaunch));
  }

  @override
  Future<void> revealStagedInFinder(StagedUpdate staged) async {
    revealedCount += 1;
  }

  @override
  Future<void> runStartupCleanup() async {}

  @override
  void dispose() {}
}

final class _FakeDesktopLocalHostDriver implements LocalHostDriver {
  final PtyRouter _router = PtyRouter();
  final List<_FakeLocalPaneHost> hosts = [];
  int _counter = 0;

  @override
  bool get isSupported => true;

  @override
  Future<LocalPaneHost> openShell(LocalShellConfig config) async {
    final session = _router.createSession(
      backend: _UiStubPtyBackend(),
      initialCols: 80,
      initialRows: 24,
    );
    final port = session.openPort(initialCols: 80, initialRows: 24);
    final host = _FakeLocalPaneHost('local-${++_counter}', session, port);
    hosts.add(host);
    return host;
  }

  @override
  Future<void> dispose() async {
    for (final h in hosts) {
      await h.dispose();
    }
    await _router.dispose();
  }
}

final class _UiStubPtyBackend implements RoutedPtyBackend {
  final StreamController<Uint8List> _out =
      StreamController<Uint8List>.broadcast();
  final Completer<int> _exit = Completer<int>();

  @override
  Stream<Uint8List> get output => _out.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  void write(Uint8List data) {}

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}

  @override
  void kill() {
    if (!_exit.isCompleted) {
      _exit.complete(0);
    }
  }

  @override
  Future<void> dispose() async {
    kill();
    await _out.close();
  }
}

final class _FakeLocalPaneHost implements LocalPaneHost {
  @override
  final String id;

  final PtyRouterSession _session;
  @override
  final TerminalPort port;

  final StreamController<LocalShareSnapshot> _shareCtrl =
      StreamController<LocalShareSnapshot>.broadcast();
  LocalShareSnapshot _share = LocalShareSnapshot.unshared;
  bool _disposed = false;

  _FakeLocalPaneHost(this.id, this._session, this.port);

  @override
  Future<int> get exitCode => _session.exitCode;

  @override
  LocalShareSnapshot get shareSnapshot => _share;

  @override
  Stream<LocalShareSnapshot> get shareUpdates => _shareCtrl.stream;

  void setLiveBroadcast() {
    _share = const LocalShareSnapshot(
      state: LocalShareState.live,
      sessionId: SessionId('live-1'),
      subscriberCount: 2,
    );
    _shareCtrl.add(_share);
  }

  @override
  Future<SessionId> startShare({
    required Uri serverUri,
    required String casterToken,
    required String title,
    String? uploadDirPath,
    IapTokenProvider? iapTokenProvider,
    CasterTransportOpener? channelOpener,
  }) async {
    setLiveBroadcast();
    return const SessionId('live-1');
  }

  @override
  Future<void> stopShare() async {
    _share = LocalShareSnapshot.unshared;
    if (!_shareCtrl.isClosed) {
      _shareCtrl.add(_share);
    }
  }

  @override
  void setColorScheme(tui.TerminalBrightness brightness) {}

  @override
  bool isLiveRowWrapped(int row) => false;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await port.dispose();
    await _session.dispose();
    await _shareCtrl.close();
  }
}
