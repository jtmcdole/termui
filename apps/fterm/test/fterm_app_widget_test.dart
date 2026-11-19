import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/file_drop_bridge.dart';
import 'package:fterm/src/font_loader.dart';
import 'package:fterm/src/fterm_app.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/ui/fterm_shortcut_dispatcher.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver.dart';
import 'package:material_ui/material_ui.dart' show Brightness, Color, Scaffold;
import 'package:termui/termui.dart'
    show Buffer, TerminalBrightness, TerminalColorTheme, TermuiBinding;
import 'package:termui_audio_flutter/termui_audio_flutter.dart';
import 'package:termui_cast_client_core/termui_cast_client_core.dart'
    show
        CastClientRepository,
        CastWorkspaceSettings,
        ClientConnectionState,
        DroppedFileSource,
        MemoryDroppedFileSource,
        TerminalThemeSettings,
        ThemeAppearanceMode,
        WsClientTransport;
import 'package:termui_cast_protocol/termui_cast_protocol.dart'
    show IapTokenProvider, SessionId;
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/painter.dart';
import 'package:termui_flutter/termui_flutter.dart';
import 'package:termui_pty/termui_pty.dart'
    show PtyRouter, PtyRouterSession, RoutedPtyBackend, TerminalPort;

import 'support/app_three_way_harness.dart';

final RegExp _sgrPixelsPressPattern = RegExp(r'\x1b\[<0;(\d+);(\d+)M');

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadCastFonts();
  });

  _defineCastLaunchConfigTests();
  _defineMultiPtyAndConnectionOverlayTests();
  _defineInputScrollUploadAndLinkTests();
  _defineThemeLifecycleAndPixelMouseTests();
  _definePersistedPreferencesStartupTests();
}

void _defineCastLaunchConfigTests() {
  group('CastLaunchConfig boundary parsing', () {
    test(
      'parses fragment token and environment settings, ignores ?server=/#server= and query tokens, and rejects non-ws schemes',
      () {
        final fromFragment = CastLaunchConfig.fromEnvironmentAndUri(
          baseUri: Uri.parse(
            'http://localhost:8080/#server=wss%3A%2F%2Fcast.example.com%2Fv1%2Fclient&token=frag-tok',
          ),
        );
        expect(
          fromFragment.serverUri.toString(),
          equals('ws://localhost:8080/v1/client'),
        );
        expect(fromFragment.token, equals('frag-tok'));
        expect(fromFragment.promptForConnection, isFalse);

        final queryServerAndTokenIgnored = CastLaunchConfig.fromEnvironmentAndUri(
          baseUri: Uri.parse(
            'http://localhost:8080/?server=ws%3A%2F%2F127.0.0.1%3A9000%2Fv1%2Fclient&token=leaked-query-tok',
          ),
        );
        expect(
          queryServerAndTokenIgnored.serverUri.toString(),
          equals('ws://localhost:8080/v1/client'),
        );
        expect(queryServerAndTokenIgnored.token, isEmpty);
        expect(queryServerAndTokenIgnored.promptForConnection, isTrue);

        final fragmentServerOverrideIgnored =
            CastLaunchConfig.fromEnvironmentAndUri(
              baseUri: Uri.parse(
                'http://localhost:8080/#server=wss%3A%2F%2Fevil.example%2Fv1%2Fclient',
              ),
              envToken: 'build-env-secret',
            );
        expect(
          fragmentServerOverrideIgnored.serverUri.toString(),
          equals('ws://localhost:8080/v1/client'),
        );
        expect(fragmentServerOverrideIgnored.token, equals('build-env-secret'));
        expect(fragmentServerOverrideIgnored.promptForConnection, isFalse);

        final fromEnv = CastLaunchConfig.fromEnvironmentAndUri(
          baseUri: Uri.parse('http://localhost:8080/'),
          envServerUrl: 'ws://127.0.0.1:9000/v1/client',
          envToken: 'env-tok',
        );
        expect(
          fromEnv.serverUri.toString(),
          equals('ws://127.0.0.1:9000/v1/client'),
        );
        expect(fromEnv.token, equals('env-tok'));
        expect(fromEnv.promptForConnection, isFalse);

        final sameOriginHttps = CastLaunchConfig.fromEnvironmentAndUri(
          baseUri: Uri.parse('https://cast.example.com/app/'),
        );
        expect(
          sameOriginHttps.serverUri,
          equals(Uri.parse('wss://cast.example.com/v1/client')),
        );
        expect(sameOriginHttps.promptForConnection, isTrue);

        final sameOriginHttp = CastLaunchConfig.fromEnvironmentAndUri(
          baseUri: Uri.parse('http://localhost:8080/'),
        );
        expect(
          sameOriginHttp.serverUri,
          equals(Uri.parse('ws://localhost:8080/v1/client')),
        );
        expect(sameOriginHttp.promptForConnection, isTrue);

        final fileBaseFallback = CastLaunchConfig.fromEnvironmentAndUri(
          baseUri: Uri.parse('file:///tmp/index.html'),
        );
        expect(
          fileBaseFallback.serverUri,
          equals(CastLaunchConfig.defaultServerUri),
        );
        expect(fileBaseFallback.promptForConnection, isTrue);

        expect(scrubUrlFragment, returnsNormally);

        expect(
          () => CastLaunchConfig.fromEnvironmentAndUri(
            baseUri: Uri.parse('http://localhost:8080/'),
            envServerUrl: 'ws://',
          ),
          throwsFormatException,
        );
      },
    );
  });
}

void _defineMultiPtyAndConnectionOverlayTests() {
  group('FtermApp multi-PTY scene and connection overlay', () {
    testWidgets(
      'renders multiple sessions, switches tabs on click while keeping PTY focused, and forwards keystrokes',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(720, 420));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final harness = AppThreeWayWsHarness();
        final pty1 = await tester.runAsync(
          () => harness.startCaster(id: 's1', title: 'zsh'),
        );
        final pty2 = await tester.runAsync(
          () => harness.startCaster(id: 's2', title: 'htop'),
        );
        addTearDown(harness.dispose);

        FtermWorkspaceController? workspace;
        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(token: harness.token),
            channelFactory: harness.openClientChannel,
            resizeDebounce: Duration.zero,
            onWorkspaceCreated: (ws) => workspace = ws,
          ),
        );
        await settleCastApp(tester);

        expect(workspace!.tabs, hasLength(2));
        expect(workspace!.activeTabIndex, equals(0));
        expect(find.text('zsh'), findsOneWidget);
        expect(find.text('htop'), findsOneWidget);

        // Switch to tab 2 by clicking its Flutter tab chip.
        await tester.tap(
          find.byKey(ValueKey('fterm-tab-${workspace!.tabs[1].tabId}')),
        );
        await settleCastApp(tester, cycles: 3);
        expect(workspace!.activeTabIndex, equals(1));

        pty2!.writtenInputs.clear();
        await _sendImeDeltaText(tester, 'q');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await settleCastApp(tester, cycles: 3);
        final wire2 = [
          for (final chunk in pty2.writtenInputs) utf8.decode(chunk),
        ].join();
        expect(wire2, contains('q\r'));
        expect(pty1!.writtenInputs, isEmpty);

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'opens Connect overlay when promptForConnection is true, connects on submit, dismisses on Escape, and recovers from auth_failed',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(720, 420));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final harness = AppThreeWayWsHarness();
        await tester.runAsync(
          () => harness.startCaster(id: 's1', title: 'prompted'),
        );
        addTearDown(harness.dispose);

        FtermWorkspaceController? workspace;
        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(promptForConnection: true),
            channelFactory: harness.openClientChannel,
            resizeDebounce: Duration.zero,
            onWorkspaceCreated: (ws) => workspace = ws,
          ),
        );
        await settleCastApp(tester);

        expect(
          find.byKey(const ValueKey('fterm-overlay-connect')),
          findsOneWidget,
        );

        // First submit wrong token -> authFailed re-opens/keeps Connect overlay.
        await tester.enterText(
          find.byKey(const ValueKey('connect-token-field')),
          'wrong-secret',
        );
        await tester.tap(find.byKey(const ValueKey('connect-submit-button')));
        await settleCastApp(tester, cycles: 5);
        expect(
          workspace!.connectionState,
          equals(ClientConnectionState.authFailed),
        );
        expect(
          find.byKey(const ValueKey('fterm-overlay-connect')),
          findsOneWidget,
        );

        // Escape dismisses Connect modal cleanly.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(
          find.byKey(const ValueKey('fterm-overlay-connect')),
          findsNothing,
        );

        // Ctrl+\ c -> Relay Settings -> reject ws://https://... inline, then accept https://... -> wss://.../v1/client.
        await _sendLeaderKey(tester, LogicalKeyboardKey.keyC);
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('picker-connect-relay')));
        await tester.pump();
        await tester.enterText(
          find.byKey(const ValueKey('connect-url-field')),
          'ws://https://relay.run.app',
        );
        await tester.tap(find.byKey(const ValueKey('connect-submit-button')));
        await tester.pump();
        expect(
          find.byKey(const ValueKey('fterm-overlay-connect')),
          findsOneWidget,
        );
        expect(
          workspace!.activeRelayUri,
          equals(CastLaunchConfig.defaultServerUri),
        );

        await tester.enterText(
          find.byKey(const ValueKey('connect-url-field')),
          'https://relay.run.app/v1/caster',
        );
        await tester.enterText(
          find.byKey(const ValueKey('connect-token-field')),
          harness.token,
        );
        await tester.tap(find.byKey(const ValueKey('connect-submit-button')));
        await settleCastApp(tester, cycles: 6);

        expect(
          workspace!.activeRelayUri,
          equals(Uri.parse('wss://relay.run.app/v1/client')),
        );
        expect(
          workspace!.connectionState,
          equals(ClientConnectionState.authenticated),
        );
        expect(workspace!.tabs, hasLength(1));

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'opens Stats, Help, and Settings overlays via Ctrl+\\ chords and survives hot reload reassemble',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(720, 420));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final harness = AppThreeWayWsHarness();
        await tester.runAsync(
          () => harness.startCaster(id: 's1', title: 'zsh'),
        );
        addTearDown(harness.dispose);

        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(token: harness.token),
            channelFactory: harness.openClientChannel,
            resizeDebounce: Duration.zero,
          ),
        );
        await settleCastApp(tester);

        for (final (key, overlayName) in const [
          (LogicalKeyboardKey.keyI, 'stats'),
          (LogicalKeyboardKey.slash, 'help'),
          (LogicalKeyboardKey.comma, 'settings'),
        ]) {
          final isShift = key == LogicalKeyboardKey.slash;
          await _sendLeaderKey(
            tester,
            key,
            shift: isShift,
            character: isShift ? '?' : null,
          );
          await tester.pump();
          expect(
            find.byKey(ValueKey('fterm-overlay-$overlayName')),
            findsOneWidget,
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pump();
          expect(
            find.byKey(ValueKey('fterm-overlay-$overlayName')),
            findsNothing,
          );
        }

        // Simulate hot reload reassemble().
        await tester.runAsync(() async => TermuiBinding.reassembleAll());
        await settleCastApp(tester, cycles: 2);
        expect(find.byType(TerminalSurface), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });
}

void _defineInputScrollUploadAndLinkTests() {
  testWidgets(
    'supports mouse wheel scrollback in primary shell and Alternate Scroll (?1007h) in alt screen',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(720, 420));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final harness = AppThreeWayWsHarness();
      final pty = await tester.runAsync(
        () => harness.startCaster(id: 's1', title: 'scroll-shell'),
      );
      addTearDown(harness.dispose);

      FtermWorkspaceController? workspace;
      await tester.pumpWidget(
        FtermApp(
          config: CastLaunchConfig(token: harness.token),
          channelFactory: harness.openClientChannel,
          resizeDebounce: Duration.zero,
          onWorkspaceCreated: (ws) => workspace = ws,
        ),
      );
      await settleCastApp(tester);

      // Fill primary scrollback buffer.
      final buf = StringBuffer();
      for (var i = 0; i < 40; i++) {
        buf.write('HISTORY-$i\r\n');
      }
      pty!.emitRawAnsi('$buf');
      await settleCastApp(tester, cycles: 5);

      final center = tester.getCenter(find.byType(TerminalSurface));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: center);
      await tester.pump();

      await _dispatchScrollSignal(tester, center, const Offset(0, -120));
      await settleCastApp(tester, cycles: 3);
      expect(workspace!.focusedPane!.scrollOffsetLines, greaterThan(0));

      // Enter alternate screen with ?1007h -> wheel up emits \x1b[A / \x1bOA.
      pty.writtenInputs.clear();
      pty.emitRawAnsi('\x1b[?1049h\x1b[?1007h');
      await settleCastApp(tester, cycles: 4);
      await _dispatchScrollSignal(tester, center, const Offset(0, -40));
      await settleCastApp(tester, cycles: 3);

      final altWire = [
        for (final chunk in pty.writtenInputs) utf8.decode(chunk),
      ].join();
      expect(altWire, contains('\x1b[A'));

      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'shows drag-over overlay, opens FileUpload overlay on drop, and uploads files to caster host',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(720, 420));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final uploadDir = Directory.systemTemp.createTempSync('fterm_upload_');
      addTearDown(() => uploadDir.deleteSync(recursive: true));

      final harness = AppThreeWayWsHarness();
      await tester.runAsync(
        () => harness.startCaster(
          id: 's1',
          title: 'upload-box',
          uploadDirectory: uploadDir,
        ),
      );
      addTearDown(harness.dispose);

      late void Function(bool) emitHover;
      late void Function(List<DroppedFileSource>) emitDrop;

      try {
        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(token: harness.token),
            channelFactory: harness.openClientChannel,
            resizeDebounce: Duration.zero,
            fileDropBridgeFactory:
                ({required onDragHoverChanged, required onFilesDropped}) {
                  emitHover = onDragHoverChanged;
                  emitDrop = onFilesDropped;
                  return _TestFileDropBridge(onDispose: () {});
                },
          ),
        );
        await settleCastApp(tester);

        emitHover(true);
        await tester.pump();
        expect(
          find.text('Drop files to upload to remote host'),
          findsOneWidget,
        );

        emitHover(false);
        emitDrop([
          MemoryDroppedFileSource(
            name: 'hello.txt',
            bytes: Uint8List.fromList(utf8.encode('hello-fterm')),
          ),
        ]);
        await tester.pump();
        expect(
          find.byKey(const ValueKey('fterm-overlay-fileUpload')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const ValueKey('upload-submit')));
        final dismissed = await settleCastAppUntil(
          tester,
          () => find
              .byKey(const ValueKey('fterm-overlay-fileUpload'))
              .evaluate()
              .isEmpty,
        );
        expect(
          dismissed,
          isTrue,
          reason: 'FileUpload overlay did not dismiss within timeout',
        );
        expect(
          find.byKey(const ValueKey('fterm-overlay-fileUpload')),
          findsNothing,
        );
        final uploadedFile = File('${uploadDir.path}/hello.txt');
        expect(uploadedFile.existsSync(), isTrue);
        expect(uploadedFile.readAsStringSync(), equals('hello-fterm'));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await settleCastApp(tester, cycles: 2);
      }
    },
  );

  testWidgets('opens OSC 8 and mailto: URLs via onOpenUrl on Ctrl+Click', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(720, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final harness = AppThreeWayWsHarness();
    final pty = await tester.runAsync(
      () => harness.startCaster(id: 's1', title: 'links'),
    );
    addTearDown(harness.dispose);

    final openedUrls = <Uri>[];
    await tester.pumpWidget(
      FtermApp(
        config: CastLaunchConfig(token: harness.token),
        channelFactory: harness.openClientChannel,
        resizeDebounce: Duration.zero,
        onOpenUrl: openedUrls.add,
      ),
    );
    await settleCastApp(tester);

    pty!.emitRawAnsi(
      '\x1b[2J\x1b[H\x1b]8;;https://dart.dev\x07Dart\x1b]8;;\x07  \x1b]8;;mailto:hi@dart.dev\x07Mail\x1b]8;;\x07',
    );
    await settleCastApp(tester, cycles: 5);

    final canvasFinder = find.descendant(
      of: find.byType(TerminalSurface),
      matching: find.byType(CustomPaint),
    );
    final surfaceRect = tester.getRect(canvasFinder);
    final cols = pty.cols;
    final rows = pty.rows;
    final cellW = surfaceRect.width / cols;
    final cellH = surfaceRect.height / rows;
    Offset cellCenter(int col0, int row0) => Offset(
      surfaceRect.left + (col0 + 0.5) * cellW,
      surfaceRect.top + (row0 + 0.5) * cellH,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.tapAt(cellCenter(1, 0));
    await settleCastApp(tester, cycles: 2);
    await tester.tapAt(cellCenter(7, 0));
    await settleCastApp(tester, cycles: 2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    expect(
      openedUrls,
      equals([Uri.parse('https://dart.dev'), Uri.parse('mailto:hi@dart.dev')]),
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'macOS Ctrl+RightClick opens plain-text https URLs and hovers with Rainbow Road wave',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await tester.binding.setSurfaceSize(const Size(720, 420));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      expect(
        () => openExternalUrl(Uri.parse('https://example.com')),
        returnsNormally,
      );

      final harness = AppThreeWayWsHarness();
      final pty = await tester.runAsync(
        () => harness.startCaster(id: 's1', title: 'links-macos'),
      );
      addTearDown(harness.dispose);

      final openedUrls = <Uri>[];
      await tester.pumpWidget(
        FtermApp(
          config: CastLaunchConfig(token: harness.token),
          channelFactory: harness.openClientChannel,
          resizeDebounce: Duration.zero,
          onOpenUrl: openedUrls.add,
        ),
      );
      await settleCastApp(tester);

      pty!.emitRawAnsi('\x1b[2J\x1b[HVisit https://flutter.dev/docs now');
      await settleCastApp(tester, cycles: 5);

      final canvasFinder = find.descendant(
        of: find.byType(TerminalSurface),
        matching: find.byType(CustomPaint),
      );
      final surfaceRect = tester.getRect(canvasFinder);
      final cellW = surfaceRect.width / pty.cols;
      final cellH = surfaceRect.height / pty.rows;
      final linkPos = Offset(
        surfaceRect.left + 10.5 * cellW,
        surfaceRect.top + 0.5 * cellH,
      );

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: surfaceRect.topLeft);
      await tester.pump();
      await mouse.moveTo(linkPos);
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));

      final painter =
          tester.widget<CustomPaint>(canvasFinder).painter! as TuiAtlasPainter;
      final link = painter.hoveredLink;
      expect(link?.uri, equals('https://flutter.dev/docs'));
      expect(painter.hoveredLinkStyler, isNotNull);
      final s0 = HoveredLinkCellStyles()..reset(8);
      final s1 = HoveredLinkCellStyles()..reset(8);
      painter.hoveredLinkStyler!(
        link!,
        8,
        DateTime(2026, 1, 1, 0, 0, 0, 0),
        s0,
      );
      painter.hoveredLinkStyler!(
        link,
        8,
        DateTime(2026, 1, 1, 0, 0, 0, 120),
        s1,
      );
      expect(s0.foregroundAt(0), isNotNull);
      expect(s0.foregroundAt(0), isNot(equals(s1.foregroundAt(0))));
      expect(s0.foregroundAt(0), isNot(equals(s0.foregroundAt(1))));
      expect(s0.backgroundAt(0), equals(0xFF1B263B));
      expect(s0.underlineColorAt(0), equals(s0.foregroundAt(0)));

      final click = await tester.startGesture(
        linkPos,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      await click.up();
      await settleCastApp(tester, cycles: 2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      expect(openedUrls, equals([Uri.parse('https://flutter.dev/docs')]));

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'macOS Ctrl+RightClick on soft-wrapped 2-row plain-text URL opens full URL from either row',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await tester.binding.setSurfaceSize(const Size(360, 320));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final harness = AppThreeWayWsHarness();
      final pty = await tester.runAsync(
        () => harness.startCaster(id: 's1', title: 'wrapped-links'),
      );
      addTearDown(harness.dispose);

      final openedUrls = <Uri>[];
      await tester.pumpWidget(
        FtermApp(
          config: CastLaunchConfig(token: harness.token),
          channelFactory: harness.openClientChannel,
          resizeDebounce: Duration.zero,
          onOpenUrl: openedUrls.add,
        ),
      );
      await settleCastApp(tester);

      const prefix = 'See ';
      const host = 'https://example.com/';
      final tailCount = (pty!.cols - prefix.length - host.length).clamp(4, 60);
      final fullUrl =
          '$host${List.filled(tailCount, 'x').join()}/wrapped/path/end';
      pty.emitRawAnsi('\x1b[2J\x1b[H$prefix$fullUrl ok');
      await settleCastApp(tester, cycles: 5);

      final canvasFinder = find.descendant(
        of: find.byType(TerminalSurface),
        matching: find.byType(CustomPaint),
      );
      final surfaceRect = tester.getRect(canvasFinder);
      final cellW = surfaceRect.width / pty.cols;
      final cellH = surfaceRect.height / pty.rows;
      Offset cellCenter(int col0, int row0) => Offset(
        surfaceRect.left + (col0 + 0.5) * cellW,
        surfaceRect.top + (row0 + 0.5) * cellH,
      );

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: surfaceRect.topLeft);
      await tester.pump();

      Future<void> ctrlRightClick(Offset pos) async {
        await mouse.moveTo(pos);
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        final click = await tester.startGesture(
          pos,
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await tester.pump();
        await click.up();
        await settleCastApp(tester, cycles: 2);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
      }

      await ctrlRightClick(cellCenter(prefix.length + 4, 0));
      await ctrlRightClick(cellCenter(2, 1));

      expect(openedUrls, equals([Uri.parse(fullUrl), Uri.parse(fullUrl)]));

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'renames live tabs on double-tap and closes exited 💀 tabs via close button',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(720, 420));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      var now = DateTime(2026, 2, 1, 10);
      final harness = AppThreeWayWsHarness();
      final pty1 = await tester.runAsync(
        () => harness.startCaster(id: 's1', title: 'first'),
      );
      await tester.runAsync(
        () => harness.startCaster(id: 's2', title: 'second'),
      );
      addTearDown(harness.dispose);

      FtermWorkspaceController? workspace;
      await tester.pumpWidget(
        FtermApp(
          config: CastLaunchConfig(token: harness.token),
          channelFactory: harness.openClientChannel,
          resizeDebounce: Duration.zero,
          clock: Clock(() => now),
          onWorkspaceCreated: (ws) => workspace = ws,
        ),
      );
      await settleCastApp(tester);

      final tab1 = workspace!.tabs.first;
      await tester.tap(find.byKey(ValueKey('fterm-tab-${tab1.tabId}')));
      now = now.add(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(ValueKey('fterm-tab-${tab1.tabId}')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('fterm-overlay-rename')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const ValueKey('rename-title-field')),
        'Build Tab',
      );
      await tester.tap(find.byKey(const ValueKey('rename-submit')));
      await tester.pump();
      expect(tab1.pinnedTitle, equals('Build Tab'));

      // Exit pty1 cleanly -> tab shows 💀 and dismisses via close icon.
      await tester.runAsync(() => pty1!.finish(0));
      await settleCastApp(tester, cycles: 5);
      expect(find.text('💀'), findsOneWidget);

      await tester.tap(find.byKey(ValueKey('fterm-tab-close-${tab1.tabId}')));
      await settleCastApp(tester, cycles: 3);
      expect(workspace!.tabs, hasLength(1));

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

void _defineThemeLifecycleAndPixelMouseTests() {
  testWidgets(
    'synchronously starts in Light Mode on frame 1 and updates Scaffold + TerminalSurface on platformBrightness changes',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(640, 384));
      addTearDown(() {
        tester.binding.platformDispatcher.clearPlatformBrightnessTestValue();
        return tester.binding.setSurfaceSize(null);
      });

      tester.binding.platformDispatcher.platformBrightnessTestValue =
          Brightness.light;

      final storage = _MemorySettingsStorage();
      saveStoredSettings(
        storage,
        const CastWorkspaceSettings(
          themeSettings: TerminalThemeSettings(
            appearanceMode: ThemeAppearanceMode.system,
          ),
        ),
      );

      final harness = AppThreeWayWsHarness();
      await tester.runAsync(() => harness.startCaster(id: 's1', title: 'zsh'));
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        FtermApp(
          config: CastLaunchConfig(token: harness.token),
          channelFactory: harness.openClientChannel,
          resizeDebounce: Duration.zero,
          settingsStorage: storage,
        ),
      );

      // Frame 1 (before settleCastApp): storage read only once per key & Scaffold light.
      expect(storage.readCountByKey[castSettingsStorageKey], equals(1));
      final scaffoldFrame1 = tester.widget<Scaffold>(
        find.byType(Scaffold).first,
      );
      expect(
        scaffoldFrame1.backgroundColor,
        equals(Color(TerminalColorTheme.termuiLight.background.argb)),
      );

      await settleCastApp(tester);
      expect(
        tester.widget<TerminalSurface>(find.byType(TerminalSurface)).palette.id,
        equals(TerminalColorTheme.termuiLight.id),
      );

      // Transition platform brightness to dark.
      tester.binding.platformDispatcher.platformBrightnessTestValue =
          Brightness.dark;
      await tester.pump();
      expect(
        tester.widget<TerminalSurface>(find.byType(TerminalSurface)).palette.id,
        equals(TerminalColorTheme.termuiDark.id),
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'zero FtermApp / Scaffold widget rebuilds during routine PTY output frames',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(640, 384));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final harness = AppThreeWayWsHarness();
      final pty = await tester.runAsync(
        () => harness.startCaster(id: 'rebuild-test', title: 'zsh'),
      );
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        FtermApp(
          config: CastLaunchConfig(token: harness.token),
          channelFactory: harness.openClientChannel,
          resizeDebounce: Duration.zero,
        ),
      );
      await settleCastApp(tester);

      final surfaceBefore = tester.widget<TerminalSurface>(
        find.byType(TerminalSurface),
      );
      final scaffoldBefore = tester.widget<Scaffold>(
        find.byType(Scaffold).first,
      );

      for (var i = 0; i < 5; i++) {
        pty!.emitRawAnsi('Frame count: $i\r\n');
        await tester.pump(const Duration(milliseconds: 50));
      }
      await settleCastApp(tester, cycles: 3);

      final surfaceAfter = tester.widget<TerminalSurface>(
        find.byType(TerminalSurface),
      );
      final scaffoldAfter = tester.widget<Scaffold>(
        find.byType(Scaffold).first,
      );

      expect(identical(surfaceBefore, surfaceAfter), isTrue);
      expect(identical(scaffoldBefore, scaffoldAfter), isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'copies Alt+Drag box selection cleanly without chrome and forwards CSI > 3 u + ?1016h pixel mouse',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(720, 420));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      String? hostClipboard;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              final args = call.arguments as Map<Object?, Object?>;
              hostClipboard = args['text'] as String?;
            } else if (call.method == 'Clipboard.getData') {
              return <String, Object?>{'text': hostClipboard};
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      final harness = AppThreeWayWsHarness();
      final pty = await tester.runAsync(
        () => harness.startCaster(id: 's1', title: 'sel-pixels'),
      );
      addTearDown(harness.dispose);

      Buffer? lastBuffer;
      await tester.pumpWidget(
        FtermApp(
          config: CastLaunchConfig(token: harness.token),
          channelFactory: harness.openClientChannel,
          resizeDebounce: Duration.zero,
          onFrameRedrawn: (buf) => lastBuffer = buf,
        ),
      );
      await settleCastApp(tester);

      pty!.emitRawAnsi('\x1b[2J\x1b[HLeft0│Right0\r\nLeft1│Right1\r\n');
      await settleCastApp(tester, cycles: 5);
      expect(lastBuffer, isNotNull);

      final canvasFinder = find.descendant(
        of: find.byType(TerminalSurface),
        matching: find.byType(CustomPaint),
      );
      final surfaceRect = tester.getRect(canvasFinder);
      final cellW = surfaceRect.width / pty.cols;
      final cellH = surfaceRect.height / pty.rows;
      Offset cellCenter(int col0, int row0) => Offset(
        surfaceRect.left + (col0 + 0.5) * cellW,
        surfaceRect.top + (row0 + 0.5) * cellH,
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      final boxDrag = await tester.startGesture(
        cellCenter(4, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await boxDrag.moveTo(cellCenter(6, 1));
      await tester.pump();
      await boxDrag.up();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await settleCastApp(tester, cycles: 3);
      expect(hostClipboard, equals('0│R\n1│R'));

      // Enable CSI > 3 u + ?1000;1016h pixel mouse.
      pty.emitRawAnsi('\x1b[>3u\x1b[?1000;1016h');
      await settleCastApp(tester, cycles: 4);
      pty.writtenInputs.clear();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
      await settleCastApp(tester, cycles: 3);
      final kbWire = [
        for (final chunk in pty.writtenInputs) latin1.decode(chunk),
      ].join();
      expect(kbWire, contains('\x1b[107;1:3u'));

      pty.writtenInputs.clear();
      await tester.tapAt(
        Offset(surfaceRect.left + 0.25 * cellW, surfaceRect.top + 0.5 * cellH),
      );
      await settleCastApp(tester, cycles: 3);
      final mouseWire = [
        for (final chunk in pty.writtenInputs) latin1.decode(chunk),
      ].join();
      final pressMatch = _sgrPixelsPressPattern.firstMatch(mouseWire);
      expect(pressMatch, isNotNull);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'didRequestAppExit flushes pending settings and disposes local PTY hosts before returning exit',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(640, 384));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final storage = _MemorySettingsStorage();
      final driver = _ExitTestLocalHostDriver();
      var dropBridgeDisposed = false;
      FtermWorkspaceController? workspace;

      await tester.pumpWidget(
        FtermApp(
          config: CastLaunchConfig(),
          localHostDriver: driver,
          settingsStorage: storage,
          resizeDebounce: Duration.zero,
          fileDropBridgeFactory:
              ({required onDragHoverChanged, required onFilesDropped}) =>
                  _TestFileDropBridge(
                    onDispose: () => dropBridgeDisposed = true,
                  ),
          onWorkspaceCreated: (ws) => workspace = ws,
        ),
      );
      await settleCastApp(tester);

      expect(driver.backends, hasLength(1));
      expect(driver.backends.single.disposed, isFalse);

      // Enqueue a debounced settings write before closing the window.
      workspace!.updateWorkspaceSettings(
        workspace!.workspaceSettings.copyWith(copyOnSelect: true),
      );

      final response = await tester.runAsync(
        () => WidgetsBinding.instance.handleRequestAppExit(),
      );
      expect(response, equals(AppExitResponse.exit));
      expect(dropBridgeDisposed, isTrue);
      expect(driver.disposed, isTrue);
      expect(driver.hosts.single.disposed, isTrue);
      expect(driver.backends.single.killed, isTrue);
      expect(driver.backends.single.disposed, isTrue);
      expect(loadStoredSettings(storage).copyOnSelect, isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'FtermAudioController.needsGestureUnlock and FtermShortcutDispatcher unlock only on KeyDownEvent',
    () async {
      final audio = FtermAudioController(initialMuted: true);
      expect(audio.needsGestureUnlock, isTrue);
      expect(audio.hasUserGesture, isFalse);

      final repo = CastClientRepository(transport: WsClientTransport());
      final driver = _ExitTestLocalHostDriver();
      final workspace = FtermWorkspaceController(
        launchConfig: CastLaunchConfig(),
        repository: repo,
        localHostDriver: driver,
        audioController: audio,
        storage: _MemorySettingsStorage(),
      );
      addTearDown(() async {
        await workspace.dispose();
        await repo.dispose();
        await driver.dispose();
      });

      final dispatcher = FtermShortcutDispatcher(workspace: workspace);

      // KeyUpEvent and KeyRepeatEvent skip audio gesture unlock.
      expect(
        dispatcher.handleHostShortcut(
          const KeyUpEvent(
            physicalKey: PhysicalKeyboardKey.keyA,
            logicalKey: LogicalKeyboardKey.keyA,
            timeStamp: Duration.zero,
          ),
          const {},
        ),
        isFalse,
      );
      expect(audio.hasUserGesture, isFalse);

      expect(
        dispatcher.handleHostShortcut(
          const KeyRepeatEvent(
            physicalKey: PhysicalKeyboardKey.keyA,
            logicalKey: LogicalKeyboardKey.keyA,
            character: 'a',
            timeStamp: Duration.zero,
          ),
          const {},
        ),
        isFalse,
      );
      expect(audio.hasUserGesture, isFalse);

      // KeyDownEvent unlocks when needsGestureUnlock is true.
      expect(
        dispatcher.handleHostShortcut(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.keyA,
            logicalKey: LogicalKeyboardKey.keyA,
            character: 'a',
            timeStamp: Duration.zero,
          ),
          const {},
        ),
        isFalse,
      );
      expect(audio.hasUserGesture, isTrue);
      expect(audio.needsGestureUnlock, isFalse);

      // Unmuted controller honors the 2s cooldown after 2 failures and stops
      // retrying permanently after _maxInitAttempts (3) failures.
      var initCalls = 0;
      var now = DateTime(2026, 1, 1);
      final failingAudio = FtermAudioController(
        clock: Clock(() => now),
        engineFactory: () => _FailingAudioEngine(() => initCalls++),
      );
      addTearDown(failingAudio.dispose);
      expect(failingAudio.needsGestureUnlock, isTrue);
      await failingAudio.notifyUserGesture();
      await failingAudio.notifyUserGesture();
      expect(initCalls, equals(2));
      expect(failingAudio.needsGestureUnlock, isFalse);

      // Cooldown blocks immediate 3rd retry; advancing >=2s re-enables it.
      await failingAudio.notifyUserGesture();
      expect(initCalls, equals(2));
      now = now.add(const Duration(seconds: 2));
      expect(failingAudio.needsGestureUnlock, isTrue);
      await failingAudio.notifyUserGesture();
      expect(initCalls, equals(3));
      now = now.add(const Duration(seconds: 10));
      expect(failingAudio.needsGestureUnlock, isFalse);
      await failingAudio.notifyUserGesture();
      expect(initCalls, equals(3));

      // Disposed controller clears needsGestureUnlock and returns synchronously.
      await audio.dispose();
      expect(audio.needsGestureUnlock, isFalse);
      await audio.notifyUserGesture();
    },
  );
}

void _definePersistedPreferencesStartupTests() {
  testWidgets(
    'loads persisted fontSize at startup and scales GlyphAtlasController with MediaQuery TextScaler without double-baking',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.binding.setSurfaceSize(const Size(900, 560));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final storage = _MemorySettingsStorage();
      saveStoredPreferences(
        storage,
        const FtermPreferences(
          fontSize: 16.0,
          shellExecutable: 'zsh',
          loginShell: false,
        ),
      );

      Future<void> verifyStartupFont({
        required TextScaler scaler,
        required double expectedSize,
      }) async {
        final driver = _ExitTestLocalHostDriver();
        FtermWorkspaceController? workspace;
        final app = FtermApp(
          config: CastLaunchConfig(promptForConnection: true),
          localHostDriver: driver,
          settingsStorage: storage,
          resizeDebounce: Duration.zero,
          fileDropBridgeFactory:
              ({required onDragHoverChanged, required onFilesDropped}) =>
                  _TestFileDropBridge(onDispose: () {}),
          onWorkspaceCreated: (ws) => workspace = ws,
        );
        await tester.pumpWidget(
          scaler == TextScaler.noScaling
              ? app
              : MediaQuery(
                  data: MediaQueryData(
                    textScaler: scaler,
                    devicePixelRatio: 1.0,
                  ),
                  child: app,
                ),
        );
        await settleCastApp(tester);

        expect(workspace!.preferences.fontSize, equals(16.0));
        expect(workspace!.effectiveFontSize, equals(16.0));
        expect(driver.openedConfigs.single.executable, equals('zsh'));
        expect(driver.openedConfigs.single.loginShell, isFalse);
        final surface = tester.widget<TerminalSurface>(
          find.byType(TerminalSurface),
        );
        expect(surface.fontSize, equals(expectedSize));
        expect(surface.atlasController!.fontSize, equals(expectedSize));
        expect(surface.atlasController!.atlas?.fontSize, equals(expectedSize));
        expect(surface.atlasController!.generationId, equals(1));
        expect(surface.atlasController!.debugCreatedAtlasCount, equals(1));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await workspace!.dispose();
          await driver.dispose();
        });
      }

      await verifyStartupFont(scaler: TextScaler.noScaling, expectedSize: 16.0);
      await verifyStartupFont(
        scaler: const TextScaler.linear(1.5),
        expectedSize: 24.0,
      );
    },
  );
}

final class _FailingAudioEngine implements TermuiAudioEngine {
  final VoidCallback _onInit;

  _FailingAudioEngine(this._onInit);

  @override
  Future<void> init({bool enableVisualization = false}) async {
    _onInit();
    throw StateError('audio unavailable');
  }

  @override
  Future<void> dispose() async {}

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _sendLeaderKey(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
  String? character,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.backslash, character: '\x1c');
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
  if (shift) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.sendKeyEvent(key, character: character);
  if (shift) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }
}

Future<void> _sendImeDeltaText(WidgetTester tester, String text) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        SystemChannels.textInput.name,
        SystemChannels.textInput.codec.encodeMethodCall(
          MethodCall('TextInputClient.updateEditingStateWithDeltas', <Object?>[
            -1,
            <String, Object?>{
              'deltas': <Map<String, Object?>>[
                <String, Object?>{
                  'oldText': '',
                  'deltaText': text,
                  'deltaStart': 0,
                  'deltaEnd': 0,
                  'selectionBase': text.length,
                  'selectionExtent': text.length,
                  'composingBase': -1,
                  'composingExtent': -1,
                },
              ],
            },
          ]),
        ),
        (_) {},
      );
  await tester.pump();
}

Future<void> _dispatchScrollSignal(
  WidgetTester tester,
  Offset position,
  Offset delta,
) async {
  final binding = tester.binding;
  final data = PointerScrollEvent(position: position, scrollDelta: delta);
  binding.handlePointerEvent(data);
  await tester.pump();
}

final class _TestFileDropBridge implements FileDropBridge {
  final void Function() onDispose;

  const _TestFileDropBridge({required this.onDispose});

  @override
  void dispose() => onDispose();
}

final class _MemorySettingsStorage implements SettingsStorage {
  final Map<String, String> _entries = {};
  final Map<String, int> readCountByKey = {};

  @override
  String? getItem(String key) {
    readCountByKey[key] = (readCountByKey[key] ?? 0) + 1;
    return _entries[key];
  }

  @override
  void setItem(String key, String value) => _entries[key] = value;
}

final class _ExitTestRoutedBackend implements RoutedPtyBackend {
  final StreamController<Uint8List> _outputController =
      StreamController<Uint8List>();
  final Completer<int> _exitCompleter = Completer<int>();
  bool killed = false;
  bool disposed = false;

  @override
  Stream<Uint8List> get output => _outputController.stream;

  @override
  Future<int> get exitCode => _exitCompleter.future;

  @override
  void write(Uint8List bytes) {}

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}

  @override
  void kill() {
    killed = true;
    if (!_exitCompleter.isCompleted) {
      _exitCompleter.complete(0);
    }
  }

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    kill();
    if (!_outputController.isClosed) {
      await _outputController.close();
    }
  }
}

final class _ExitTestLocalPaneHost implements LocalPaneHost {
  @override
  final String id;
  final PtyRouterSession _session;
  @override
  final TerminalPort port;
  final _ExitTestRoutedBackend backend;
  final StreamController<LocalShareSnapshot> _shareUpdates =
      StreamController<LocalShareSnapshot>.broadcast();
  bool disposed = false;

  _ExitTestLocalPaneHost({
    required this.id,
    required PtyRouterSession session,
    required this.port,
    required this.backend,
  }) : _session = session;

  @override
  Future<int> get exitCode => _session.exitCode;

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
  }) => throw UnimplementedError();

  @override
  Future<void> stopShare() async {}

  @override
  void setColorScheme(TerminalBrightness brightness) {
    _session.terminal.setColorScheme(brightness);
  }

  @override
  bool isLiveRowWrapped(int row) => _session.terminal.isRowWrapped(row);

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await port.dispose();
    await _session.dispose();
    await _shareUpdates.close();
  }
}

final class _ExitTestLocalHostDriver implements LocalHostDriver {
  final PtyRouter _router = PtyRouter();
  final List<_ExitTestRoutedBackend> backends = [];
  final List<_ExitTestLocalPaneHost> hosts = [];
  final List<LocalShellConfig> openedConfigs = [];
  bool disposed = false;

  @override
  bool get isSupported => true;

  @override
  Future<LocalPaneHost> openShell(LocalShellConfig config) async {
    openedConfigs.add(config);
    final backend = _ExitTestRoutedBackend();
    backends.add(backend);
    final session = _router.createSession(backend: backend);
    final port = session.openPort();
    final host = _ExitTestLocalPaneHost(
      id: 'exit-host-${hosts.length + 1}',
      session: session,
      port: port,
      backend: backend,
    );
    hosts.add(host);
    return host;
  }

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await Future.wait([for (final host in hosts) host.dispose()]);
    await _router.dispose();
  }
}
