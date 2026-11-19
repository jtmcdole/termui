import 'dart:io' show Directory, File;
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/about/about_models.dart';
import 'package:fterm/src/about/about_service_stub.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/feedback/diagnostic_log.dart';
import 'package:fterm/src/feedback/feedback_models.dart';
import 'package:fterm/src/feedback/feedback_platform_io.dart';
import 'package:fterm/src/feedback/feedback_screenshot_io.dart';
import 'package:fterm/src/font_loader.dart';
import 'package:fterm/src/fterm_app.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/ui/fterm_feedback_overlay.dart';
import 'package:fterm/src/ui/fterm_overlays.dart';
import 'package:fterm/src/update/update_service.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart'
    show
        CastClientRepository,
        WsClientTransport,
        clientDisconnectedEvent,
        clientMessageReceivedEvent;
import 'package:termui_cast_protocol/termui_cast_protocol.dart';

import 'support/app_three_way_harness.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadCastFonts();
  });

  group('FtermDiagnosticLog, platform labels, and screenshot saver', () {
    test(
      'FtermDiagnosticLog uses injected Clock, records allowlisted event codes, and enforces ring-buffer capacity',
      () {
        var tick = 0;
        final log = FtermDiagnosticLog(
          maxEntries: 3,
          clock: Clock(() => DateTime.utc(2026, 11, 19, 12, 0, tick++)),
        );
        addTearDown(log.dispose);

        log.record(DiagnosticEventKind.relayConnectFailed);
        log.record(DiagnosticEventKind.relayAuthFailed);
        log.record(DiagnosticEventKind.localShareFailed);
        log.record(DiagnosticEventKind.updateError);

        expect(log.length, equals(3));
        expect(
          [for (final e in log.entries) e.formatLine()],
          equals([
            '[12:00:01Z] relay_auth_failed',
            '[12:00:02Z] local_share_failed',
            '[12:00:03Z] update_error',
          ]),
        );
      },
    );

    test(
      'resolvePlatformFeedbackLabel emits OS family and numeric version without hostnames',
      () {
        expect(
          resolvePlatformFeedbackLabel(
            operatingSystem: 'macos',
            operatingSystemVersion: 'Version 15.4 (Build 24E248)',
          ),
          equals('macOS 15.4'),
        );
        expect(
          resolvePlatformFeedbackLabel(
            operatingSystem: 'windows',
            operatingSystemVersion: '"Windows 11 Pro" 10.0 (Build 22631)',
          ),
          equals('Windows 10.0'),
        );
        expect(
          resolvePlatformFeedbackLabel(
            operatingSystem: 'linux',
            operatingSystemVersion:
                '#1 SMP PREEMPT Debian 6.8.0 (builder@corp-host.internal)',
          ),
          equals('Linux 6.8.0'),
        );
        expect(
          resolvePlatformFeedbackLabel(
            operatingSystem: 'linux',
            operatingSystemVersion: '',
          ),
          equals('Linux'),
        );
        expect(
          resolvePlatformFeedbackLabel(
            operatingSystem: 'fuchsia',
            operatingSystemVersion: '',
          ),
          equals('Unknown OS'),
        );
      },
    );

    test(
      'savePlatformFeedbackScreenshot prefers ~/Downloads, falls back to temp, and rejects invalid names',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'fterm-feedback-shot-',
        );
        addTearDown(() async {
          if (sandbox.existsSync()) await sandbox.delete(recursive: true);
        });
        final homeDir = Directory(p.join(sandbox.path, 'home'))..createSync();
        final downloadsDir = Directory(p.join(homeDir.path, 'Downloads'))
          ..createSync();
        final tempDir = Directory(p.join(sandbox.path, 'tmp'))..createSync();
        final pngBytes = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);

        // 1. Writes into ~/Downloads when present.
        final savedInDownloads = await savePlatformFeedbackScreenshot(
          'shot_1.png',
          pngBytes,
          environment: {'HOME': homeDir.path},
          tempDirectory: tempDir,
        );
        expect(
          savedInDownloads,
          equals(p.join(downloadsDir.path, 'shot_1.png')),
        );
        expect(File(savedInDownloads!).readAsBytesSync(), equals(pngBytes));

        // 2. Falls back to tempDirectory when Downloads does not exist.
        downloadsDir.deleteSync(recursive: true);
        final savedInTemp = await savePlatformFeedbackScreenshot(
          'nested/dir/shot_2.png',
          pngBytes,
          environment: {'HOME': homeDir.path},
          tempDirectory: tempDir,
        );
        expect(savedInTemp, equals(p.join(tempDir.path, 'shot_2.png')));
        expect(File(savedInTemp!).readAsBytesSync(), equals(pngBytes));

        // 3. Rejects empty / dot filenames.
        expect(
          await savePlatformFeedbackScreenshot(
            '..',
            pngBytes,
            environment: {'HOME': homeDir.path},
            tempDirectory: tempDir,
          ),
          isNull,
        );
      },
    );
  });

  group('buildGitHubIssuePayload budget, grapheme safety, and diagnostics', () {
    final env = FtermEnvironmentInfo(
      metadata: FtermBuildMetadata(
        version: '0.5.0',
        buildDateUtc: DateTime.utc(2026, 11, 19, 10, 30),
        flutterVersion: '3.41.0',
        flutterChannel: 'stable',
        dartVersion: '3.11.0',
      ),
      platformLabel: 'macOS 15.4',
    );
    const state = FtermWorkspaceDiagnosticSummary(
      tabCount: 2,
      paneCount: 3,
      focusedPaneKind: 'remote session (via relay)',
      usesRelay: true,
      activePtySize: '120x40',
      themeId: 'termui-dark',
      appearanceMode: 'dark',
      fontSize: 14.0,
      dockPosition: 'top',
      connectionState: 'authenticated',
      audioInitialized: false,
      isWeb: false,
      updateStatus: 'idle',
    );

    test(
      'keeps default payload minimal and wraps opt-in state and event codes in <details> with zero URLs',
      () {
        final minimal = buildGitHubIssuePayload(
          draft: const FeedbackDraft(
            category: FeedbackCategory.bug,
            title: 'Wrapped URL click',
            details: 'Only first row highlights.',
          ),
          environment: env,
          workspaceState: state,
        );
        expect(minimal.bodyTruncated, isFalse);
        expect(
          '${minimal.uri}',
          startsWith('https://github.com/jtmcdole/termui/issues/new?'),
        );
        expect(
          minimal.uri.queryParameters['title'],
          equals('[fterm] Wrapped URL click'),
        );
        expect(minimal.uri.queryParameters['labels'], equals('bug'));
        expect(minimal.fullMarkdown, contains('- App: fterm v0.5.0'));
        expect(minimal.fullMarkdown, contains('- Client: macOS 15.4'));
        expect(minimal.fullMarkdown, isNot(contains('<details>')));

        final logs = [
          DiagnosticLogEntry(
            timestampUtc: DateTime.utc(2026, 11, 19, 11, 0, 5),
            kind: DiagnosticEventKind.localShareFailed,
          ),
        ];
        final rich = buildGitHubIssuePayload(
          draft: const FeedbackDraft(
            category: FeedbackCategory.feature,
            title: 'Add feedback button',
            details: 'Pre-fill version metadata.',
            includeWorkspaceState: true,
            includeDiagnosticLogs: true,
            savedScreenshotName: 'screenshot_123.png',
          ),
          environment: env,
          workspaceState: state,
          diagnosticLogs: logs,
        );
        expect(rich.uri.queryParameters['labels'], equals('enhancement'));
        expect(rich.fullMarkdown, contains('<details>'));
        expect(
          rich.fullMarkdown,
          contains('<summary>Diagnostics (opt-in)</summary>'),
        );
        expect(rich.fullMarkdown, contains('via relay (authenticated)'));
        expect(rich.fullMarkdown, contains('[11:00:05Z] local_share_failed'));
        expect(rich.fullMarkdown, contains('</details>'));
        expect(rich.fullMarkdown, contains('screenshot_123.png'));
        expect(rich.fullMarkdown, isNot(contains('ws://')));
        expect(rich.fullMarkdown, isNot(contains('wss://')));
        expect(rich.fullMarkdown, isNot(contains('http://')));
        expect(rich.fullMarkdown, isNot(contains('https://')));

        final general = buildGitHubIssuePayload(
          draft: const FeedbackDraft(category: FeedbackCategory.general),
          environment: env,
        );
        expect(general.uri.queryParameters.containsKey('labels'), isFalse);
      },
    );

    test(
      'caps long titles, drops diagnostics cleanly without unclosed fences, and never splits emoji surrogates',
      () {
        final manyLogs = [
          for (var i = 0; i < 35; i++)
            DiagnosticLogEntry(
              timestampUtc: DateTime.utc(2026, 11, 19, 11, 0, i),
              kind: DiagnosticEventKind.relayProtocolError,
            ),
        ];

        // 1. Long logs drop <details> first so URL body never leaves unclosed fences.
        final truncated = buildGitHubIssuePayload(
          draft: const FeedbackDraft(
            category: FeedbackCategory.bug,
            title: 'Long log report',
            details: 'Some details here.',
            includeWorkspaceState: true,
            includeDiagnosticLogs: true,
          ),
          environment: env,
          workspaceState: state,
          diagnosticLogs: manyLogs,
          maxUrlLength: 900,
        );
        expect(truncated.bodyTruncated, isTrue);
        expect('${truncated.uri}'.length, lessThanOrEqualTo(900));
        final urlBody = truncated.uri.queryParameters['body']!;
        expect(urlBody, isNot(contains('<details>')));
        expect(urlBody, isNot(contains('```text')));
        expect(urlBody, contains('Full diagnostics copied to clipboard'));
        expect(
          truncated.fullMarkdown,
          contains('[11:00:34Z] relay_protocol_error'),
        );

        // 2. Emoji-heavy details never emit U+FFFD replacement chars at any truncation boundary.
        final emojiDraft = FeedbackDraft(
          category: FeedbackCategory.bug,
          title: '🚀' * 2500,
          details: List<String>.filled(40, '🔥🚀👨‍👩‍👧‍👦').join(' '),
        );
        for (final budget in [360, 420, 500, 780, 792, 1900]) {
          final payload = buildGitHubIssuePayload(
            draft: emojiDraft,
            environment: env,
            maxUrlLength: budget,
          );
          expect(payload.bodyTruncated, isTrue);
          expect(
            '${payload.uri}'.length,
            lessThanOrEqualTo(budget),
            reason: 'budget=$budget exceeded',
          );
          final body = payload.uri.queryParameters['body'] ?? '';
          expect(body.contains('\uFFFD'), isFalse, reason: 'budget=$budget');
        }
      },
    );
  });

  group('Workspace diagnostic events', () {
    test(
      'FtermWorkspaceController records relayProtocolError, relayDisconnected, and remote buildDiagnosticSummary',
      () async {
        final harness = AppThreeWayWsHarness();
        await harness.startCaster(id: 's1', title: 'diag-shell');
        addTearDown(harness.dispose);

        final ws = FtermWorkspaceController(
          launchConfig: CastLaunchConfig(token: harness.token),
          repository: CastClientRepository(
            transport: WsClientTransport(
              serverUri: CastLaunchConfig.defaultServerUri,
              token: harness.token,
              channelFactory: harness.openClientChannel,
            ),
          ),
          localHostDriver: createLocalHostDriver(),
          audioController: FtermAudioController(),
          storage: _MemorySettingsStorage(),
          updateService: createPlatformUpdateService(),
          resizeDebounce: Duration.zero,
        );
        addTearDown(ws.dispose);
        await ws.start();

        // Wait deterministically for remote session pane to mount.
        for (var i = 0; i < 40 && ws.focusedPane == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(ws.focusedPane, isNotNull);

        final summary = ws.buildDiagnosticSummary(isWeb: false);
        expect(summary.usesRelay, isTrue);
        expect(summary.focusedPaneKind, equals('remote session (via relay)'));
        expect(summary.activePtySize, isNotNull);

        // Emit non-fatal protocol error & disconnect events onto repository bus.
        clientMessageReceivedEvent.post(
          ws.repository.bus,
          const ErrorFrame(code: 'rate_limited', message: 'slow down'),
        );
        clientDisconnectedEvent.post(ws.repository.bus, true);

        final kinds = [for (final e in ws.diagnosticLog.entries) e.kind];
        expect(kinds, contains(DiagnosticEventKind.relayProtocolError));
        expect(kinds, contains(DiagnosticEventKind.relayDisconnected));
      },
    );
  });

  group('FtermFeedbackOverlay widget & entry points', () {
    testWidgets(
      'FtermFeedbackOverlay previews <details>, copies report, opens GitHub, and warns if truncated clipboard copy fails',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 820));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final launchedUris = <Uri>[];
        final copiedTexts = <String>[];
        var failClipboard = false;

        final ws = _createWorkspace(
          aboutService: WebAboutService(
            compileTimeMetadataOverride: FtermBuildMetadata(
              version: '0.5.0',
              buildDateUtc: DateTime.utc(2026, 11, 19, 9, 0),
              flutterVersion: '3.41.0',
              flutterChannel: 'stable',
              dartVersion: '3.11.0',
            ),
          ),
        );
        addTearDown(() => tester.runAsync(ws.dispose));

        ws.diagnosticLog.record(DiagnosticEventKind.relayConnectFailed);
        final palette = FtermOverlayPalette.fromTerminalTheme(
          ws.activeTerminalTheme,
        );

        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 560,
                  height: 620,
                  child: FtermFeedbackOverlay(
                    workspace: ws,
                    palette: palette,
                    onOpenUrl: launchedUris.add,
                    isWeb: false,
                    onCopyToClipboard: (text) async {
                      if (failClipboard) throw StateError('clipboard denied');
                      copiedTexts.add(text);
                    },
                    platformLabelResolver: () => 'macOS 15.4',
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('fterm v0.5.0'), findsOneWidget);
        expect(find.textContaining('macOS 15.4'), findsOneWidget);

        await tester.enterText(
          find.byKey(const ValueKey('feedback-title-field')),
          'Rainbow road wrap',
        );
        await tester.enterText(
          find.byKey(const ValueKey('feedback-details-field')),
          'Hard-wrapped gcloud URLs work now.',
        );
        await tester.tap(find.byKey(const ValueKey('feedback-include-state')));
        await tester.tap(find.byKey(const ValueKey('feedback-include-logs')));
        final togglePreview = find.byKey(
          const ValueKey('feedback-toggle-preview'),
        );
        await tester.ensureVisible(togglePreview);
        await tester.tap(togglePreview);
        await tester.pumpAndSettle();

        final previewBox = find.byKey(const ValueKey('feedback-preview-box'));
        expect(previewBox, findsOneWidget);
        expect(
          find.descendant(
            of: previewBox,
            matching: find.textContaining('<details>'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: previewBox,
            matching: find.textContaining('relay_connect_failed'),
          ),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const ValueKey('feedback-copy-report')));
        await tester.pumpAndSettle();
        expect(copiedTexts, hasLength(1));
        expect(copiedTexts.single, contains('<details>'));

        await tester.tap(find.byKey(const ValueKey('feedback-open-github')));
        await tester.pumpAndSettle();
        expect(launchedUris, hasLength(1));
        expect(
          launchedUris.single.queryParameters['title'],
          equals('[fterm] Rainbow road wrap'),
        );
        expect(
          launchedUris.single.queryParameters['body'],
          contains('relay_connect_failed'),
        );

        // When URL body truncates and clipboard fails, show an actionable warning (not a false success).
        failClipboard = true;
        await tester.enterText(
          find.byKey(const ValueKey('feedback-details-field')),
          'x' * 2200,
        );
        await tester.tap(find.byKey(const ValueKey('feedback-open-github')));
        await tester.pumpAndSettle();
        expect(find.textContaining('clipboard copy failed'), findsOneWidget);
      },
    );

    testWidgets(
      'Top chrome button and About link open Feedback overlay, Save Screenshot captures focused pane, and Esc dismisses',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 820));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final harness = AppThreeWayWsHarness();
        await tester.runAsync(
          () => harness.startCaster(id: 's1', title: 'feedback-shell'),
        );
        addTearDown(() => tester.runAsync(harness.dispose));

        final launchedUris = <Uri>[];
        FtermWorkspaceController? workspace;
        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(token: harness.token),
            channelFactory: harness.openClientChannel,
            settingsStorage: _MemorySettingsStorage(),
            onOpenUrl: launchedUris.add,
            resizeDebounce: Duration.zero,
            onWorkspaceCreated: (ws) => workspace = ws,
          ),
        );
        await settleCastApp(tester);

        // 1. Open About -> tap Send Feedback / Report Issue -> lands on Feedback overlay.
        await tester.tap(find.byKey(const ValueKey('fterm-about-button')));
        await settleCastApp(tester, cycles: 2);
        await tester.tap(find.byKey(const ValueKey('about-send-feedback')));
        await settleCastApp(tester, cycles: 2);
        expect(workspace!.activeOverlay, equals(FtermOverlay.feedback));

        // 2. Dismiss with Escape, then re-open via top chrome feedback button.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
        await settleCastApp(tester, cycles: 2);
        expect(workspace!.activeOverlay, equals(FtermOverlay.none));

        await tester.tap(find.byKey(const ValueKey('fterm-feedback-button')));
        await settleCastApp(tester, cycles: 2);
        expect(workspace!.activeOverlay, equals(FtermOverlay.feedback));
        expect(
          find.byKey(const ValueKey('feedback-save-screenshot')),
          findsOneWidget,
        );

        // 3. Tap Save Screenshot to exercise FtermShellScaffold._captureFocusedPaneScreenshot.
        await tester.tap(
          find.byKey(const ValueKey('feedback-save-screenshot')),
        );
        await tester.pump();
        for (var i = 0; i < 40; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump();
          if (find
              .byKey(const ValueKey('feedback-status-notice'))
              .evaluate()
              .isNotEmpty) {
            break;
          }
        }
        final notice = find.byKey(const ValueKey('feedback-status-notice'));
        expect(notice, findsOneWidget);
        final noticeText = tester.widget<Text>(
          find.descendant(of: notice, matching: find.byType(Text)),
        );
        final savedMatch = RegExp(
          r'Saved to (.+?) —',
        ).firstMatch(noticeText.data ?? '');
        if (savedMatch != null) {
          final savedFile = File(savedMatch.group(1)!);
          expect(savedFile.existsSync(), isTrue);
          addTearDown(() async {
            if (savedFile.existsSync()) await savedFile.delete();
          });
        }
        expect(launchedUris, isEmpty);
      },
    );

    testWidgets(
      'Save Screenshot attaches basename only to Markdown and surfaces capture failure cleanly',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 820));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final harness = AppThreeWayWsHarness();
        await tester.runAsync(
          () => harness.startCaster(id: 's1', title: 'shot-shell'),
        );
        addTearDown(() => tester.runAsync(harness.dispose));

        final launchedUris = <Uri>[];
        var shouldThrow = false;

        final ws = FtermWorkspaceController(
          launchConfig: CastLaunchConfig(token: harness.token),
          repository: CastClientRepository(
            transport: WsClientTransport(
              serverUri: CastLaunchConfig.defaultServerUri,
              token: harness.token,
              channelFactory: harness.openClientChannel,
            ),
          ),
          localHostDriver: createLocalHostDriver(),
          audioController: FtermAudioController(),
          storage: _MemorySettingsStorage(),
          updateService: createPlatformUpdateService(),
          aboutService: const WebAboutService(
            compileTimeMetadataOverride: FtermBuildMetadata(version: '0.5.0'),
          ),
          resizeDebounce: Duration.zero,
        );
        addTearDown(() => tester.runAsync(ws.dispose));
        await tester.runAsync(() async {
          await ws.start();
          for (var i = 0; i < 40 && ws.focusedPane == null; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        ws.setOverlay(FtermOverlay.feedback);

        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: ListenableBuilder(
                listenable: ws.chromeNotifier,
                builder: (_, _) => FtermOverlayHost(
                  workspace: ws,
                  onOpenUrl: launchedUris.add,
                  onCaptureScreenshot: () async {
                    if (shouldThrow) throw StateError('disk full');
                    return r'C:\Users\alice/screenshot_99.png';
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const ValueKey('feedback-save-screenshot')),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('screenshot_99.png'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('feedback-open-github')));
        await tester.pumpAndSettle();
        expect(launchedUris, hasLength(1));
        final body = launchedUris.single.queryParameters['body']!;
        expect(body, contains('screenshot_99.png'));
        expect(body, isNot(contains('alice')));

        shouldThrow = true;
        await tester.tap(
          find.byKey(const ValueKey('feedback-save-screenshot')),
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Unable to capture screenshot'),
          findsOneWidget,
        );
      },
    );
  });
}

FtermWorkspaceController _createWorkspace({
  required WebAboutService aboutService,
}) {
  final transport = WsClientTransport(
    serverUri: Uri.parse('ws://127.0.0.1:9/v1/client'),
  );
  return FtermWorkspaceController(
    launchConfig: CastLaunchConfig(),
    repository: CastClientRepository(transport: transport),
    localHostDriver: createLocalHostDriver(),
    audioController: FtermAudioController(),
    storage: _MemorySettingsStorage(),
    updateService: createPlatformUpdateService(),
    aboutService: aboutService,
    initialBrightness: tui.TerminalBrightness.dark,
  );
}

final class _MemorySettingsStorage implements SettingsStorage {
  final Map<String, String> _values = {};

  @override
  String? getItem(String key) => _values[key];

  @override
  void setItem(String key, String value) {
    _values[key] = value;
  }
}
