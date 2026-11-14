import 'dart:async';
import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/font_loader.dart';
import 'package:fterm/src/fterm_app.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/workspace/fterm_pane_controller.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver.dart';
import 'package:fterm/src/workspace/split_tree_model.dart';
import 'package:material_ui/material_ui.dart';
import 'package:termui/termui.dart' as tui;
import 'package:termui_audio_flutter/termui_audio_flutter.dart';
import 'package:termui_cast_client_core/termui_cast_client_core.dart'
    show DockPosition, TerminalColorResolver, TerminalThemeSettings;
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_flutter/termui_flutter.dart';
import 'package:termui_pty/termui_pty.dart';

import 'support/app_three_way_harness.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadCastFonts();
  });

  group('FtermShellScaffold splits, atlas sharing, chrome, and chords', () {
    testWidgets(
      '4 split panes share ONE GlyphAtlasController and single GlyphAtlas, separated by 1px draggable splitters and 0px bottom bar',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(960, 600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final harness = AppThreeWayWsHarness();
        await tester.runAsync(
          () => harness.startCaster(id: 's1', title: 'primary-zsh'),
        );

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

        // Split into 4 panes: right, then down inside left, then down inside right.
        await tester.runAsync(
          () => workspace!.splitFocusedPane(SplitAxis.horizontal),
        );
        await settleCastApp(tester, cycles: 3);
        final firstLeftId = workspace!.activeSplitTree!.paneIds.first;
        workspace!.focusPane(firstLeftId);
        await tester.runAsync(
          () => workspace!.splitFocusedPane(SplitAxis.vertical),
        );
        await settleCastApp(tester, cycles: 3);
        final thirdRightTopId = workspace!.activeSplitTree!.paneIds[2];
        workspace!.focusPane(thirdRightTopId);
        await tester.runAsync(
          () => workspace!.splitFocusedPane(SplitAxis.vertical),
        );
        await settleCastApp(tester, cycles: 6);

        final surfaces = tester
            .widgetList<TerminalSurface>(find.byType(TerminalSurface))
            .toList();
        expect(surfaces, hasLength(4));

        final sharedAtlas = surfaces.first.atlasController!;
        for (final surface in surfaces) {
          expect(identical(surface.atlasController, sharedAtlas), isTrue);
        }
        expect(sharedAtlas.debugCreatedAtlasCount, equals(1));

        // Zero bottom status bar: bottom-most leaf containers touch y == 600.0 cleanly.
        final bottomEdge = [
          for (final id in workspace!.activeSplitTree!.paneIds)
            tester.getRect(find.byKey(ValueKey('pane-leaf-$id'))).bottom,
        ].reduce((a, b) => a > b ? a : b);
        expect(bottomEdge, closeTo(600.0, 0.5));

        // Top tab bar is strictly 28px tall.
        expect(
          tester
              .getSize(find.byKey(const ValueKey('fterm-tab-bar-top')))
              .height,
          equals(28.0),
        );

        // Verify 1px draggable horizontal splitter adjusts ratio cleanly.
        final rootSplit = workspace!.activeSplitTree!.root as SplitNode;
        final splitterFinder = find.byKey(
          ValueKey('splitter-${rootSplit.splitId}'),
        );
        expect(tester.getSize(splitterFinder).width, equals(1.0));
        final beforeWidth = tester
            .getSize(find.byKey(ValueKey('pane-leaf-$firstLeftId')))
            .width;
        await tester.drag(splitterFinder, const Offset(100, 0));
        await tester.pump();
        final afterWidth = tester
            .getSize(find.byKey(ValueKey('pane-leaf-$firstLeftId')))
            .width;
        expect(afterWidth, greaterThan(beforeWidth + 50));

        await tester.runAsync(() => workspace!.dispose());
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(harness.dispose);
      },
    );

    testWidgets(
      'supports 28px top, macOS 72px inset, left rail, hidden, and auto-hide single-tab modes plus bell badges',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 500));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final harness = AppThreeWayWsHarness();
        final pty1 = await tester.runAsync(
          () => harness.startCaster(id: 's1', title: 'alpha'),
        );
        final pty2 = await tester.runAsync(
          () => harness.startCaster(id: 's2', title: 'beta'),
        );

        FtermWorkspaceController? workspace;
        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(token: harness.token),
            channelFactory: harness.openClientChannel,
            resizeDebounce: Duration.zero,
            platformOverride: TargetPlatform.macOS,
            isWebOverride: false,
            onWorkspaceCreated: (ws) => workspace = ws,
          ),
        );
        await settleCastApp(tester);

        // macOS top bar shows 72px leading inset.
        expect(
          tester.getSize(find.byKey(const ValueKey('fterm-macos-inset'))).width,
          equals(72.0),
        );

        // Emit BEL in background tab s2 -> unread bell badge appears on tab 2.
        pty2!.emitRawAnsi('\x07');
        await settleCastApp(tester, cycles: 3);
        final tab2 = workspace!.tabs[1];
        expect(
          find.byKey(ValueKey('fterm-tab-bell-${tab2.tabId}')),
          findsOneWidget,
        );

        // Clicking tab 2 clears its bell badge.
        await tester.tap(find.byKey(ValueKey('fterm-tab-${tab2.tabId}')));
        await tester.pump();
        expect(
          find.byKey(ValueKey('fterm-tab-bell-${tab2.tabId}')),
          findsNothing,
        );

        // Cycle dock top -> left -> hidden -> top via Ctrl+\ d.
        await _sendLeaderChord(tester, LogicalKeyboardKey.keyD);
        await tester.pump();
        expect(
          find.byKey(const ValueKey('fterm-tab-bar-left')),
          findsOneWidget,
        );

        await _sendLeaderChord(tester, LogicalKeyboardKey.keyD);
        await tester.pump();
        expect(find.byKey(const ValueKey('fterm-tab-bar-top')), findsNothing);
        expect(find.byKey(const ValueKey('fterm-tab-bar-left')), findsNothing);

        // Restore top mode and enable autoHideSingleTab: closing tab 2 hides bar!
        await _sendLeaderChord(tester, LogicalKeyboardKey.keyD);
        await tester.pump();
        workspace!.updatePreferences(
          workspace!.preferences.copyWith(autoHideSingleTab: true),
        );
        await tester.pump();
        expect(find.byKey(const ValueKey('fterm-tab-bar-top')), findsOneWidget);
        await tester.runAsync(() => workspace!.closeTab(1));
        await tester.pump();
        expect(find.byKey(const ValueKey('fterm-tab-bar-top')), findsNothing);

        // Tab 1 still interactive after hiding bar.
        expect(pty1, isNotNull);
        await tester.runAsync(() => workspace!.dispose());
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(harness.dispose);
      },
    );

    testWidgets(
      'dispatches Ctrl+\\ modal chords (with shifted | and "), Cmd+* on macOS Desktop, ignores Cmd+* on Web, and supports rename + clearPin + local share',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 560));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final harness = AppThreeWayWsHarness();
        await tester.runAsync(
          () => harness.startCaster(id: 'remote-1', title: 'remote-box'),
        );

        final driver = _WidgetFakeLocalHostDriver(harness: harness);
        final audioEngine = _WidgetFakeAudioEngine();
        FtermWorkspaceController? workspace;

        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(
              token: harness.token,
              casterToken: harness.token,
            ),
            channelFactory: harness.openClientChannel,
            localHostDriver: driver,
            audioControllerFactory: () =>
                FtermAudioController(engineFactory: () => audioEngine),
            resizeDebounce: Duration.zero,
            platformOverride: TargetPlatform.macOS,
            isWebOverride: false,
            onWorkspaceCreated: (ws) => workspace = ws,
          ),
        );
        await settleCastApp(tester);

        // Desktop started local tab 1 cleanly without blocking prompt.
        expect(workspace!.tabs, hasLength(1));
        expect(workspace!.focusedPane!.isLocal, isTrue);

        // Shifted Ctrl+\ | splits horizontally; Ctrl+\ " splits vertically.
        await _sendLeaderChord(
          tester,
          LogicalKeyboardKey.backslash,
          shift: true,
          character: '|',
        );
        await settleCastApp(tester, cycles: 3);
        expect(workspace!.activeSplitTree!.paneCount, equals(2));

        await _sendLeaderChord(
          tester,
          LogicalKeyboardKey.quote,
          shift: true,
          character: '"',
        );
        await settleCastApp(tester, cycles: 3);
        expect(workspace!.activeSplitTree!.paneCount, equals(3));

        // Ctrl+\ z zooms focused pane cleanly and toggles back.
        await _sendLeaderChord(tester, LogicalKeyboardKey.keyZ);
        await tester.pump();
        expect(workspace!.activeSplitTree!.isZoomed, isTrue);
        expect(find.byType(TerminalSurface), findsOneWidget);
        await _sendLeaderChord(tester, LogicalKeyboardKey.keyZ);
        await tester.pump();
        expect(find.byType(TerminalSurface), findsNWidgets(3));

        // Ctrl+\ b shares local pane & filters self-cast SessionId from Session Picker.
        await _sendLeaderChord(tester, LogicalKeyboardKey.keyB);
        await settleCastApp(tester, cycles: 4);
        final sharedId = workspace!.focusedPane!.shareSnapshot.sessionId!;
        expect(workspace!.ownedSharedSessionIds, contains(sharedId));
        await _sendLeaderChord(tester, LogicalKeyboardKey.keyC);
        await tester.pump();
        expect(
          find.byKey(const ValueKey('fterm-overlay-sessionPicker')),
          findsOneWidget,
        );
        expect(
          find.byKey(ValueKey('picker-session-${sharedId.value}')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('picker-session-remote-1')),
          findsOneWidget,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();

        // Ctrl+\ b again stops sharing without closing local shell.
        await _sendLeaderChord(tester, LogicalKeyboardKey.keyB);
        await settleCastApp(tester, cycles: 2);
        expect(
          workspace!.focusedPane!.shareSnapshot.state,
          equals(LocalShareState.unshared),
        );

        // Stereo-panned BEL + APC audio played on first gesture.
        final leftPaneId = workspace!.activeSplitTree!.paneIds.first;
        driver.hosts.first.port.emitBell();
        await settleCastApp(tester, cycles: 2);
        expect(audioEngine.initCalls, greaterThanOrEqualTo(1));
        expect(leftPaneId, isNotEmpty);

        // Native macOS Cmd+T opens tab 2; Cmd+1 switches to tab 1; Cmd+W closes focused pane.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await settleCastApp(tester, cycles: 3);
        expect(workspace!.tabs, hasLength(2));

        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();
        expect(workspace!.activeTabIndex, equals(0));

        // Ctrl+\ r opens Rename modal, pins title, and clears pin back to live title.
        await _sendLeaderChord(tester, LogicalKeyboardKey.keyR);
        await tester.pump();
        await tester.enterText(
          find.byKey(const ValueKey('rename-title-field')),
          'My Pinned Tab',
        );
        await tester.tap(find.byKey(const ValueKey('rename-submit')));
        await tester.pump();
        expect(workspace!.activeTab!.pinnedTitle, equals('My Pinned Tab'));

        await _sendLeaderChord(tester, LogicalKeyboardKey.keyR);
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('rename-clear-pin')));
        await tester.tap(find.byKey(const ValueKey('rename-submit')));
        await tester.pump();
        expect(workspace!.activeTab!.isUserPinned, isFalse);

        // Web override ignores native Cmd+T while keeping workspace clean.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pumpWidget(
          FtermApp(
            key: const ValueKey('web-mode'),
            config: CastLaunchConfig(token: harness.token),
            channelFactory: harness.openClientChannel,
            settingsStorage: _MemSettings(),
            resizeDebounce: Duration.zero,
            platformOverride: TargetPlatform.macOS,
            isWebOverride: true,
            onWorkspaceCreated: (ws) => workspace = ws,
          ),
        );
        await settleCastApp(tester);
        final webInitialTabs = workspace!.tabs.length;
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();
        expect(workspace!.tabs, hasLength(webInitialTabs));

        await tester.runAsync(() => workspace!.dispose());
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(harness.dispose);
      },
    );

    testWidgets(
      'caches bufferListenable without listener leaks across 20 chrome rebuilds and preserves TerminalSurface state across splits and zoom',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 560));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final harness = AppThreeWayWsHarness();
        await tester.runAsync(
          () => harness.startCaster(id: 's1', title: 'primary'),
        );
        final driver = _WidgetFakeLocalHostDriver(harness: harness);

        FtermWorkspaceController? workspace;
        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(token: harness.token),
            channelFactory: harness.openClientChannel,
            localHostDriver: driver,
            settingsStorage: _MemSettings(),
            audioControllerFactory: () =>
                FtermAudioController(engineFactory: _WidgetFakeAudioEngine.new),
            resizeDebounce: Duration.zero,
            onWorkspaceCreated: (ws) => workspace = ws,
          ),
        );
        await settleCastApp(tester);

        final pane = workspace!.focusedPane!;
        expect(identical(pane.bufferListenable, pane.bufferListenable), isTrue);
        final initialListenerCount = pane.debugVisualListenerCount;
        final initialState = tester.state<State<TerminalSurface>>(
          find.byType(TerminalSurface),
        );

        // 20 chrome rebuilds (leader armed/disarmed + bell/status toggles).
        for (var i = 0; i < 20; i++) {
          workspace!.setLeaderArmed(i.isEven);
          await tester.pump();
        }
        expect(pane.debugVisualListenerCount, equals(initialListenerCount));

        // Reparenting across split, zoom, unzoom, and sibling close preserves State<TerminalSurface>.
        final splitPaneId = await tester.runAsync(
          () => workspace!.splitFocusedPane(SplitAxis.horizontal),
        );
        await settleCastApp(tester, cycles: 3);
        expect(find.byType(TerminalSurface), findsNWidgets(2));
        workspace!.focusPane(pane.paneId);
        await tester.pump();
        expect(
          identical(
            tester.state<State<TerminalSurface>>(
              find.byType(TerminalSurface).first,
            ),
            initialState,
          ),
          isTrue,
        );

        await _sendLeaderChord(tester, LogicalKeyboardKey.keyZ);
        await tester.pump();
        expect(find.byType(TerminalSurface), findsOneWidget);
        expect(
          identical(
            tester.state<State<TerminalSurface>>(find.byType(TerminalSurface)),
            initialState,
          ),
          isTrue,
        );

        await _sendLeaderChord(tester, LogicalKeyboardKey.keyZ);
        await tester.pump();
        await tester.runAsync(() => workspace!.closePane(splitPaneId));
        await settleCastApp(tester, cycles: 2);
        expect(
          identical(
            tester.state<State<TerminalSurface>>(find.byType(TerminalSurface)),
            initialState,
          ),
          isTrue,
        );

        await tester.runAsync(() => workspace!.dispose());
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(harness.dispose);
      },
    );

    testWidgets(
      'macOS titlebar safe strip & drag region work across top/left/hidden/autoHideSingleTab, ignore secondary click, zoom on double-tap, and drag on primary pan',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 500));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        const channel = MethodChannel('fterm/window');
        final invokedMethods = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            invokedMethods.add(call.method);
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );

        final harness = AppThreeWayWsHarness();
        await tester.runAsync(
          () => harness.startCaster(id: 'mac-s1', title: 'mac'),
        );

        FtermWorkspaceController? workspace;
        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(token: harness.token),
            channelFactory: harness.openClientChannel,
            settingsStorage: _MemSettings(),
            audioControllerFactory: () =>
                FtermAudioController(engineFactory: _WidgetFakeAudioEngine.new),
            resizeDebounce: Duration.zero,
            platformOverride: TargetPlatform.macOS,
            isWebOverride: false,
            onWorkspaceCreated: (ws) => workspace = ws,
          ),
        );
        await settleCastApp(tester);

        // 1. top mode: TerminalSurface top >= 28 and drag strip present.
        final dragStripFinder = find.byKey(
          const ValueKey('fterm-window-drag-strip'),
        );
        expect(dragStripFinder, findsOneWidget);
        expect(
          tester.getRect(find.byType(TerminalSurface)).top,
          greaterThanOrEqualTo(28.0),
        );

        // Secondary mouse button press/move on drag strip must NOT invoke startDrag.
        final dragCenter = tester.getCenter(dragStripFinder);
        final rightClick = await tester.startGesture(
          dragCenter,
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await rightClick.moveBy(const Offset(30, 0));
        await rightClick.up();
        await tester.pump();
        expect(invokedMethods, isNot(contains('startDrag')));

        // Double-tap on drag strip invokes zoomWindow without triggering startDrag.
        await tester.tapAt(dragCenter);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tapAt(dragCenter);
        await tester.pump(kDoubleTapTimeout);
        expect(invokedMethods, contains('zoomWindow'));
        expect(invokedMethods, isNot(contains('startDrag')));

        // Primary mouse button drag invokes startDrag.
        invokedMethods.clear();
        await tester.drag(dragStripFinder, const Offset(40, 0));
        await tester.pump(kDoubleTapTimeout);
        expect(invokedMethods, contains('startDrag'));

        // 2. left mode: drag strip present in left rail and TerminalSurface clears 72x28 traffic lights.
        workspace!.setDockPosition(DockPosition.left);
        await tester.pump();
        expect(dragStripFinder, findsOneWidget);
        expect(
          tester.getRect(find.byType(TerminalSurface)).left,
          greaterThanOrEqualTo(172.0),
        );

        // 3. hidden mode: compact 28px safe strip keeps TerminalSurface top >= 28 with drag strip present.
        workspace!.setDockPosition(DockPosition.hidden);
        await tester.pump();
        expect(
          find.byKey(const ValueKey('fterm-macos-titlebar-strip')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('fterm-tab-bar-top')), findsNothing);
        expect(dragStripFinder, findsOneWidget);
        expect(
          tester.getRect(find.byType(TerminalSurface)).top,
          greaterThanOrEqualTo(28.0),
        );

        // 4. autoHideSingleTab on top mode: compact 28px safe strip keeps TerminalSurface top >= 28 with drag strip present.
        workspace!.setDockPosition(DockPosition.top);
        workspace!.updatePreferences(
          workspace!.preferences.copyWith(autoHideSingleTab: true),
        );
        await tester.pump();
        expect(find.byKey(const ValueKey('fterm-tab-bar-top')), findsNothing);
        expect(
          find.byKey(const ValueKey('fterm-macos-titlebar-strip')),
          findsOneWidget,
        );
        expect(dragStripFinder, findsOneWidget);
        expect(
          tester.getRect(find.byType(TerminalSurface)).top,
          greaterThanOrEqualTo(28.0),
        );

        await tester.runAsync(() => workspace!.dispose());
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(harness.dispose);
      },
    );

    testWidgets(
      '6px transparent splitter hit target drags off-center, top tab bar keeps >=48px drag space, F12 skips pane when overlay open, and Connect overlay scrolls in compact viewports',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(600, 420));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final harness = AppThreeWayWsHarness();
        await tester.runAsync(
          () => harness.startCaster(id: 'ui-s1', title: 'one'),
        );
        final driver = _WidgetFakeLocalHostDriver(harness: harness);

        FtermWorkspaceController? workspace;
        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(token: harness.token),
            channelFactory: harness.openClientChannel,
            localHostDriver: driver,
            settingsStorage: _MemSettings(),
            audioControllerFactory: () =>
                FtermAudioController(engineFactory: _WidgetFakeAudioEngine.new),
            resizeDebounce: Duration.zero,
            onWorkspaceCreated: (ws) => workspace = ws,
          ),
        );
        await settleCastApp(tester);

        // 1. 6px splitter hit target accepts drag 2px off-center while visual line stays 1px.
        await tester.runAsync(
          () => workspace!.splitFocusedPane(SplitAxis.horizontal),
        );
        await settleCastApp(tester, cycles: 3);
        final rootSplit = workspace!.activeSplitTree!.root as SplitNode;
        final firstId = workspace!.activeSplitTree!.paneIds.first;
        final visualFinder = find.byKey(
          ValueKey('splitter-${rootSplit.splitId}'),
        );
        final hitFinder = find.byKey(
          ValueKey('splitter-hit-${rootSplit.splitId}'),
        );
        expect(tester.getSize(visualFinder).width, equals(1.0));
        expect(tester.getSize(hitFinder).width, equals(6.0));
        final widthBefore = tester
            .getSize(find.byKey(ValueKey('pane-leaf-$firstId')))
            .width;
        final offCenterStart =
            tester.getCenter(visualFinder) + const Offset(2.0, 0);
        await tester.dragFrom(offCenterStart, const Offset(60, 0));
        await tester.pump();
        final widthAfter = tester
            .getSize(find.byKey(ValueKey('pane-leaf-$firstId')))
            .width;
        expect(widthAfter, greaterThan(widthBefore + 40));

        // 2. Top tab bar allocates > 50% width to many tabs while preserving >= 48px drag strip.
        for (var i = 0; i < 6; i++) {
          await tester.runAsync(() => workspace!.openLocalShellTab());
        }
        await settleCastApp(tester, cycles: 3);
        expect(
          tester
              .getSize(find.byKey(const ValueKey('fterm-window-drag-strip')))
              .width,
          greaterThanOrEqualTo(48.0),
        );

        // 3. F12 does not leak into pane while an overlay is open.
        workspace!.setF12ShortcutsEnabled(false);
        workspace!.setOverlay(FtermOverlay.connect);
        await tester.pump();
        final focusedHost = driver.hosts.last;
        focusedHost.port.inputs.clear();
        await tester.sendKeyEvent(LogicalKeyboardKey.f12);
        await tester.pump();
        expect(focusedHost.port.inputs, isEmpty);

        // 4. Short viewport with Connect overlay open scrolls cleanly with zero overflow.
        await tester.binding.setSurfaceSize(const Size(360, 220));
        await tester.pump();
        expect(tester.takeException(), isNull);

        // 5. Chrome connection icon and Settings -> Relay Connection button open Connect overlay.
        workspace!.dismissOverlay();
        await tester.binding.setSurfaceSize(const Size(800, 480));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('fterm-connect-button')));
        await tester.pump();
        expect(
          find.byKey(const ValueKey('fterm-overlay-connect')),
          findsOneWidget,
        );

        // Chrome Remote Sessions button opens Session Picker and lets desktop users open remote tabs.
        workspace!.dismissOverlay();
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('fterm-sessions-button')));
        await tester.pump();
        expect(
          find.byKey(const ValueKey('fterm-overlay-sessionPicker')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('picker-session-ui-s1')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('picker-session-ui-s1')));
        await settleCastApp(tester, cycles: 3);
        expect(
          find.byKey(const ValueKey('fterm-overlay-sessionPicker')),
          findsNothing,
        );
        expect(
          workspace!.focusedPane!.remoteSessionId,
          equals(const SessionId('ui-s1')),
        );

        workspace!.setOverlay(FtermOverlay.settings);
        await tester.pump();
        final openConnectBtn = find.byKey(
          const ValueKey('settings-open-connect'),
        );
        await tester.ensureVisible(openConnectBtn);
        await tester.pump();
        await tester.tap(openConnectBtn);
        await tester.pump();
        expect(
          find.byKey(const ValueKey('fterm-overlay-connect')),
          findsOneWidget,
        );

        await tester.runAsync(() => workspace!.dispose());
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(harness.dispose);
      },
    );

    testWidgets(
      'syncs shared GlyphAtlasController DPR on devicePixelRatio metric changes and Web tab resume',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetDevicePixelRatio);

        final harness = AppThreeWayWsHarness();
        await tester.runAsync(
          () => harness.startCaster(id: 'dpr-s1', title: 'one'),
        );
        final driver = _WidgetFakeLocalHostDriver(harness: harness);

        FtermWorkspaceController? workspace;
        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(token: harness.token),
            channelFactory: harness.openClientChannel,
            localHostDriver: driver,
            isWebOverride: true,
            settingsStorage: _MemSettings(),
            audioControllerFactory: () =>
                FtermAudioController(engineFactory: _WidgetFakeAudioEngine.new),
            resizeDebounce: Duration.zero,
            onWorkspaceCreated: (ws) => workspace = ws,
          ),
        );
        await settleCastApp(tester);

        final surface = tester.widget<TerminalSurface>(
          find.byType(TerminalSurface).first,
        );
        final sharedAtlas = surface.atlasController!;
        expect(sharedAtlas.devicePixelRatio, equals(1.0));
        expect(sharedAtlas.atlas?.devicePixelRatio, equals(1.0));

        // Simulate monitor DPR change (1.0 -> 2.0) + Web tab resume.
        tester.view.devicePixelRatio = 2.0;
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await settleCastApp(tester, cycles: 3);

        expect(sharedAtlas.devicePixelRatio, equals(2.0));
        expect(sharedAtlas.atlas?.devicePixelRatio, equals(2.0));

        await tester.runAsync(() => workspace!.dispose());
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(harness.dispose);
      },
    );

    testWidgets(
      'keeps TerminalSurface CustomPaint origin snapped to integer physical pixels across odd/even sizes and splits',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final harness = AppThreeWayWsHarness();
        await tester.runAsync(
          () => harness.startCaster(id: 'snap-s1', title: 'one'),
        );
        final driver = _WidgetFakeLocalHostDriver(harness: harness);

        FtermWorkspaceController? workspace;
        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(token: harness.token),
            channelFactory: harness.openClientChannel,
            localHostDriver: driver,
            isWebOverride: true,
            settingsStorage: _MemSettings(),
            audioControllerFactory: () =>
                FtermAudioController(engineFactory: _WidgetFakeAudioEngine.new),
            resizeDebounce: Duration.zero,
            onWorkspaceCreated: (ws) => workspace = ws,
          ),
        );
        await settleCastApp(tester);

        await tester.runAsync(
          () => workspace!.splitFocusedPane(SplitAxis.horizontal),
        );
        await settleCastApp(tester, cycles: 3);

        for (final dpr in [1.0, 2.0]) {
          tester.view.devicePixelRatio = dpr;
          for (final size in [const Size(901, 601), const Size(900, 600)]) {
            await tester.binding.setSurfaceSize(size);
            await settleCastApp(tester, cycles: 2);
            final painters = find.descendant(
              of: find.byType(TerminalSurface),
              matching: find.byType(CustomPaint),
            );
            expect(painters, findsNWidgets(2));
            for (var i = 0; i < 2; i++) {
              final origin = tester.getTopLeft(painters.at(i));
              final px = origin.dx * dpr;
              final py = origin.dy * dpr;
              expect(
                (px - px.roundToDouble()).abs(),
                lessThan(1e-6),
                reason: 'pane $i x=$origin at dpr=$dpr size=$size',
              );
              expect(
                (py - py.roundToDouble()).abs(),
                lessThan(1e-6),
                reason: 'pane $i y=$origin at dpr=$dpr size=$size',
              );
            }
          }
        }

        await tester.runAsync(() => workspace!.dispose());
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(harness.dispose);
      },
    );

    testWidgets(
      'middle-click pastes clipboard text and ignores empty clipboard',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(720, 420));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        String? hostClipboard = 'echo hello';
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.getData') {
                return hostClipboard == null
                    ? null
                    : <String, Object?>{'text': hostClipboard};
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null),
        );

        final harness = AppThreeWayWsHarness();
        final pty = await tester.runAsync(
          () => harness.startCaster(id: 'mid-s1', title: 'mid'),
        );

        FtermWorkspaceController? workspace;
        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(token: harness.token),
            channelFactory: harness.openClientChannel,
            settingsStorage: _MemSettings(),
            audioControllerFactory: () =>
                FtermAudioController(engineFactory: _WidgetFakeAudioEngine.new),
            resizeDebounce: Duration.zero,
            onWorkspaceCreated: (ws) => workspace = ws,
          ),
        );
        await settleCastApp(tester);

        pty!.emitRawAnsi('\x1b[?2004h');
        await settleCastApp(tester, cycles: 3);
        pty.writtenInputs.clear();

        final center = tester.getCenter(find.byType(TerminalSurface).first);
        final click1 = await tester.startGesture(
          center,
          kind: PointerDeviceKind.mouse,
          buttons: kMiddleMouseButton,
        );
        await tester.pump();
        await click1.up();
        await settleCastApp(tester, cycles: 3);
        expect(
          pty.writtenInputs.map(utf8.decode).join(),
          equals('\x1b[200~echo hello\x1b[201~'),
        );

        // Disable bracketed paste & test empty clipboard (no-op) + plain paste.
        pty.emitRawAnsi('\x1b[?2004l');
        await settleCastApp(tester, cycles: 3);
        pty.writtenInputs.clear();
        hostClipboard = '';

        final click2 = await tester.startGesture(
          center,
          kind: PointerDeviceKind.mouse,
          buttons: kMiddleMouseButton,
        );
        await tester.pump();
        await click2.up();
        await settleCastApp(tester, cycles: 3);
        expect(pty.writtenInputs, isEmpty);

        hostClipboard = 'ls -la';
        final click3 = await tester.startGesture(
          center,
          kind: PointerDeviceKind.mouse,
          buttons: kMiddleMouseButton,
        );
        await tester.pump();
        await click3.up();
        await settleCastApp(tester, cycles: 3);
        expect(pty.writtenInputs.map(utf8.decode).join(), equals('ls -la'));

        await tester.runAsync(() => workspace!.dispose());
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(harness.dispose);
      },
    );

    testWidgets(
      'mouse tracking forwards plain middle-click while Shift+middle-click pastes clipboard cleanly',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(720, 420));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        const hostClipboard = 'pasted-text';
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.getData') {
                return <String, Object?>{'text': hostClipboard};
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null),
        );

        final harness = AppThreeWayWsHarness();
        final pty = await tester.runAsync(
          () => harness.startCaster(id: 'mid-track', title: 'track'),
        );

        FtermWorkspaceController? workspace;
        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(token: harness.token),
            channelFactory: harness.openClientChannel,
            settingsStorage: _MemSettings(),
            audioControllerFactory: () =>
                FtermAudioController(engineFactory: _WidgetFakeAudioEngine.new),
            resizeDebounce: Duration.zero,
            onWorkspaceCreated: (ws) => workspace = ws,
          ),
        );
        await settleCastApp(tester);

        pty!.emitRawAnsi('\x1b[?1000;1006;2004h');
        await settleCastApp(tester, cycles: 3);
        pty.writtenInputs.clear();

        final center = tester.getCenter(find.byType(TerminalSurface).first);
        final plainClick = await tester.startGesture(
          center,
          kind: PointerDeviceKind.mouse,
          buttons: kMiddleMouseButton,
        );
        await tester.pump();
        await plainClick.up();
        await settleCastApp(tester, cycles: 3);
        final plainOut = pty.writtenInputs.map(utf8.decode).join();
        expect(plainOut, contains('\x1b[<1;'));
        expect(plainOut, isNot(contains(hostClipboard)));

        pty.writtenInputs.clear();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        final shiftClick = await tester.startGesture(
          center,
          kind: PointerDeviceKind.mouse,
          buttons: kMiddleMouseButton,
        );
        await tester.pump();
        await shiftClick.up();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await settleCastApp(tester, cycles: 3);
        expect(
          pty.writtenInputs.map(utf8.decode).join(),
          equals('\x1b[200~$hostClipboard\x1b[201~'),
        );

        await tester.runAsync(() => workspace!.dispose());
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(harness.dispose);
      },
    );

    testWidgets(
      'renders remote Kitty graphics (f=32 RGBA, 32-bit MSB ID, and f=100 PNG) over relay connection and across primary scrollback without global registry',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.binding.setSurfaceSize(const Size(640, 420));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        const idRaw = 0x004B01;
        const idMsb = 0x42004B02;
        const idPng = 0x004B03;

        final harness = AppThreeWayWsHarness();
        final pty = await tester.runAsync(
          () => harness.startCaster(id: 'ktty-remote', title: 'ktty-probe'),
        );

        FtermWorkspaceController? workspace;
        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(token: harness.token),
            channelFactory: harness.openClientChannel,
            isWebOverride: true,
            settingsStorage: _MemSettings(),
            audioControllerFactory: () =>
                FtermAudioController(engineFactory: _WidgetFakeAudioEngine.new),
            resizeDebounce: Duration.zero,
            onWorkspaceCreated: (ws) => workspace = ws,
          ),
        );
        await settleCastApp(tester);

        final rawTile = tui.KittyImageData(
          imageId: idRaw,
          pixelWidth: 2,
          pixelHeight: 2,
          rgbaPixels: Uint8List.fromList(const [
            0, 220, 255, 255, 0, 220, 255, 255, //
            0, 220, 255, 255, 0, 220, 255, 255,
          ]),
          gridCols: 2,
          gridRows: 1,
        );
        final msbTile = tui.KittyImageData(
          imageId: idMsb,
          pixelWidth: 2,
          pixelHeight: 2,
          rgbaPixels: Uint8List.fromList(const [
            0, 240, 80, 255, 0, 240, 80, 255, //
            0, 240, 80, 255, 0, 240, 80, 255,
          ]),
          gridCols: 2,
          gridRows: 1,
        );
        final pngTile = tui.KittyImageData.fromPng(
          imageId: idPng,
          pixelWidth: 2,
          pixelHeight: 2,
          pngBytes: _encodeSolidRgbaPng(2, 2, 255, 40, 20),
          gridCols: 2,
          gridRows: 1,
        );

        final wire = StringBuffer()
          ..write('\x1b[2J\x1b[?25l')
          ..write(rawTile.toApcSequence())
          ..write(msbTile.toApcSequence())
          ..write(pngTile.toApcSequence())
          ..write(
            '\x1b[1;1H\x1b[38;2;0;75;1m'
            '${tui.kittyPlaceholderCell(0, 0)}${tui.kittyPlaceholderCell(0, 1)}',
          )
          ..write(
            '\x1b[2;1H\x1b[38;2;0;75;2m'
            '${tui.kittyPlaceholderCell(0, 0, imageIdMsb: 0x42)}'
            '${tui.kittyPlaceholderCell(0, 1, imageIdMsb: 0x42)}',
          )
          ..write(
            '\x1b[3;1H\x1b[38;2;0;75;3m'
            '${tui.kittyPlaceholderCell(0, 0)}${tui.kittyPlaceholderCell(0, 1)}'
            '\x1b[0m',
          );
        pty!.emitRawAnsi('$wire');
        await settleCastApp(tester, cycles: 10);

        // Global registry stays completely untouched across the remote connection.
        expect(tui.KittyImageRegistry.global.lookupImage(idRaw), isNull);
        expect(tui.KittyImageRegistry.global.lookupImage(idMsb), isNull);
        expect(tui.KittyImageRegistry.global.lookupImage(idPng), isNull);

        final pane = workspace!.focusedPane!;
        final display = pane.displayBuffer;
        expect(display.lookupKittyImage(0, 0, idRaw), isNotNull);
        expect(display.lookupKittyImage(0, 1, idMsb), isNotNull);
        expect(display.lookupKittyImage(0, 2, idPng), isNotNull);

        // Verify actual GPU pixels painted on TerminalSurface for all 3 tiles.
        final surfaceFinder = find.byType(TerminalSurface).first;
        final atlas = tester
            .widget<TerminalSurface>(surfaceFinder)
            .atlasController!
            .atlas!;
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find
              .descendant(
                of: surfaceFinder,
                matching: find.byType(RepaintBoundary),
              )
              .first,
        );
        final screenshot = await tester.runAsync(
          () => boundary.toImage(pixelRatio: 1.0),
        );
        addTearDown(() => screenshot?.dispose());
        final rgba = await tester.runAsync(
          () => screenshot!.toByteData(format: ui.ImageByteFormat.rawRgba),
        );
        final cw = atlas.cellWidth;
        final ch = atlas.cellHeight;
        expect(
          _sampleRgbaAt(
            rgba!,
            screenshot!.width,
            (cw * 0.5).floor(),
            (ch * 0.5).floor(),
          ),
          equals((0, 220, 255)),
        );
        expect(
          _sampleRgbaAt(
            rgba,
            screenshot.width,
            (cw * 0.5).floor(),
            (ch * 1.5).floor(),
          ),
          equals((0, 240, 80)),
        );
        expect(
          _sampleRgbaAt(
            rgba,
            screenshot.width,
            (cw * 0.5).floor(),
            (ch * 2.5).floor(),
          ),
          equals((255, 40, 20)),
        );

        // Push lines into primary scrollback and scroll up 1 row: scoped registry persists.
        final rows = pane.port.rows;
        pty.emitRawAnsi('\x1b[$rows;1H\n\n\n');
        await settleCastApp(tester, cycles: 5);
        pane.scrollLines(1);
        await tester.pump();
        expect(pane.scrollOffsetLines, equals(1));
        expect(
          identical(
            pane.displayBuffer.lookupKittyRegistry(0, 0),
            tui.KittyImageRegistry.global,
          ),
          isFalse,
        );

        final localPort = _WidgetMemPort()..totalScrollbackLines = 1;
        final scopedReg = tui.KittyImageRegistry();
        localPort.buffer.registerKittyRegistry(
          const tui.Rect(0, 0, 80, 24),
          scopedReg,
        );
        final localPane = FtermPaneController(
          paneId: 'local-ktty',
          port: localPort,
          colorResolver: TerminalColorResolver(
            theme: tui.TerminalColorTheme.termuiDark,
            settings: const TerminalThemeSettings(),
          ),
        );
        localPane.scrollLines(1);
        expect(
          identical(
            localPane.displayBuffer.lookupKittyRegistry(0, 0),
            scopedReg,
          ),
          isTrue,
        );
        await localPane.dispose(disposePort: true);

        await tester.runAsync(() => workspace!.dispose());
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(harness.dispose);
      },
    );

    testWidgets(
      'captures mouse on interactive ?1002h screens without selecting text unless Shift is held, and double-click selects hit word when mouse tracking is off',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.binding.setSurfaceSize(const Size(640, 420));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final harness = AppThreeWayWsHarness();
        final pty = await tester.runAsync(
          () => harness.startCaster(id: 'mouse-word', title: 'interactive'),
        );

        FtermWorkspaceController? workspace;
        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(token: harness.token),
            channelFactory: harness.openClientChannel,
            isWebOverride: true,
            settingsStorage: _MemSettings(),
            audioControllerFactory: () =>
                FtermAudioController(engineFactory: _WidgetFakeAudioEngine.new),
            resizeDebounce: Duration.zero,
            onWorkspaceCreated: (ws) => workspace = ws,
          ),
        );
        await settleCastApp(tester);

        String? copiedClipboard;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              final args = call.arguments as Map<Object?, Object?>?;
              copiedClipboard = args?['text'] as String?;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );

        pty!.emitRawAnsi('\x1b[?1002h\x1b[?1006h\x1b[1;1HPlay Clouds Now');
        await settleCastApp(tester, cycles: 8);
        pty.writtenInputs.clear();

        final surfaceFinder = find.byType(TerminalSurface).first;
        final atlas = tester
            .widget<TerminalSurface>(surfaceFinder)
            .atlasController!
            .atlas!;
        final paintFinder = find
            .descendant(of: surfaceFinder, matching: find.byType(CustomPaint))
            .first;
        final topLeft = tester.getTopLeft(paintFinder);

        // 1. Interactive TUI (?1002h): clicking & dragging across 'Clouds' forwards mouse to PTY without selecting/copying text.
        final cloudsStart =
            topLeft + Offset(atlas.cellWidth * 5.5, atlas.cellHeight * 0.5);
        final cloudsEnd =
            topLeft + Offset(atlas.cellWidth * 10.5, atlas.cellHeight * 0.5);
        final interactiveDrag = await tester.startGesture(
          cloudsStart,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(milliseconds: 20));
        await interactiveDrag.moveTo(cloudsEnd);
        await tester.pump(const Duration(milliseconds: 20));
        await interactiveDrag.up();
        await settleCastApp(tester, cycles: 5);
        expect(copiedClipboard, isNull);
        expect(
          pty.writtenInputs.map(utf8.decode).join(),
          contains('\x1b[<0;6;1M'),
        );

        // 2. Shift+drag overrides mouse tracking to select/copy text locally without forwarding mouse clicks to PTY.
        pty.writtenInputs.clear();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        final shiftDrag = await tester.startGesture(
          cloudsStart,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(milliseconds: 20));
        await shiftDrag.moveTo(cloudsEnd);
        await tester.pump(const Duration(milliseconds: 20));
        await shiftDrag.up();
        await tester.pump();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await settleCastApp(tester, cycles: 4);
        expect(copiedClipboard, equals('Clouds'));
        expect(pty.writtenInputs, isEmpty);

        // 2b. Scrolled-back ?1002h pane selects locally and wheelDown scrolls without forwarding.
        final pane = workspace!.focusedPane!;
        pty.emitRawAnsi('\x1b[${pane.port.rows};1H\n\n');
        await settleCastApp(tester, cycles: 5);
        pty.writtenInputs.clear();
        copiedClipboard = null;
        pane.scrollLines(1);
        await tester.pump();
        final scrolledDrag = await tester.startGesture(
          cloudsStart,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(milliseconds: 20));
        await scrolledDrag.moveTo(cloudsEnd);
        await tester.pump(const Duration(milliseconds: 20));
        await scrolledDrag.up();
        await settleCastApp(tester, cycles: 4);
        expect(copiedClipboard, isNotNull);
        expect(pty.writtenInputs, isEmpty);
        pane.sendInputEvent(
          const tui.MouseEvent(
            x: 1,
            y: 1,
            button: tui.MouseButton.wheelDown,
            type: tui.MouseEventType.press,
          ),
        );
        expect(pane.scrollOffsetLines, equals(0));
        expect(pty.writtenInputs, isEmpty);

        // 3. Turn off mouse tracking (?1002l) and double-click 'Clouds' (col 7) -> selects & copies whole word 'Clouds'.
        copiedClipboard = null;
        pty.emitRawAnsi('\x1b[?1002l\x1b[1;1HPlay Clouds Now');
        await settleCastApp(tester, cycles: 6);
        await tester.pump(const Duration(milliseconds: 600));
        final wordHit =
            topLeft + Offset(atlas.cellWidth * 7.5, atlas.cellHeight * 0.5);
        final tap1 = await tester.startGesture(
          wordHit,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(milliseconds: 20));
        await tap1.up();
        await tester.pump(const Duration(milliseconds: 40));

        final tap2 = await tester.startGesture(
          wordHit,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(milliseconds: 20));
        await tap2.up();
        await tester.pump();

        expect(copiedClipboard, equals('Clouds'));

        // 4. Disabling copyOnSelect suppresses clipboard writes on release.
        copiedClipboard = null;
        workspace!.setCopyOnSelect(false);
        await tester.pump();
        final playDragStart =
            topLeft + Offset(atlas.cellWidth * 0.5, atlas.cellHeight * 0.5);
        final playDragEnd =
            topLeft + Offset(atlas.cellWidth * 3.5, atlas.cellHeight * 0.5);
        final noCopyDrag = await tester.startGesture(
          playDragStart,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(milliseconds: 20));
        await noCopyDrag.moveTo(playDragEnd);
        await tester.pump(const Duration(milliseconds: 20));
        await noCopyDrag.up();
        await tester.pump();
        expect(copiedClipboard, isNull);

        await tester.runAsync(() => workspace!.dispose());
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(harness.dispose);
      },
    );
  });
}

(int r, int g, int b) _sampleRgbaAt(
  ByteData rgba,
  int imageWidth,
  int x,
  int y,
) {
  final idx = (y * imageWidth + x) * 4;
  return (rgba.getUint8(idx), rgba.getUint8(idx + 1), rgba.getUint8(idx + 2));
}

Uint8List _encodeSolidRgbaPng(int width, int height, int r, int g, int b) {
  final stride = width * 4;
  final scanlines = Uint8List((stride + 1) * height);
  for (var y = 0; y < height; y++) {
    final rowBase = y * (stride + 1);
    scanlines[rowBase] = 0;
    for (var x = 0; x < width; x++) {
      final px = rowBase + 1 + x * 4;
      scanlines[px] = r;
      scanlines[px + 1] = g;
      scanlines[px + 2] = b;
      scanlines[px + 3] = 255;
    }
  }
  final ihdr = Uint8List(13);
  ByteData.sublistView(ihdr)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  final out = BytesBuilder(copy: false)
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  for (final (type, data) in [
    ('IHDR', ihdr),
    ('IDAT', Uint8List.fromList(zlib.encode(scanlines))),
    ('IEND', Uint8List(0)),
  ]) {
    final typeBytes = ascii.encode(type);
    final len = ByteData(4)..setUint32(0, data.length);
    final crc = ByteData(4)..setUint32(0, _pngCrc32(typeBytes, data));
    out
      ..add(len.buffer.asUint8List())
      ..add(typeBytes)
      ..add(data)
      ..add(crc.buffer.asUint8List());
  }
  return out.takeBytes();
}

int _pngCrc32(List<int> typeBytes, Uint8List data) {
  var crc = 0xFFFFFFFF;
  for (final byte in [...typeBytes, ...data]) {
    var c = (crc ^ byte) & 0xFF;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    }
    crc = c ^ (crc >>> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

Future<void> _sendLeaderChord(
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

final class _MemSettings implements SettingsStorage {
  final Map<String, String> _m = {};

  @override
  String? getItem(String key) => _m[key];

  @override
  void setItem(String key, String value) => _m[key] = value;
}

final class _WidgetFakeLocalHostDriver implements LocalHostDriver {
  final AppThreeWayWsHarness harness;
  final List<_WidgetFakeLocalPaneHost> hosts = [];
  int _counter = 0;

  _WidgetFakeLocalHostDriver({required this.harness});

  @override
  bool get isSupported => true;

  @override
  Future<LocalPaneHost> openShell(LocalShellConfig config) async {
    final host = _WidgetFakeLocalPaneHost(
      id: 'wlocal-${++_counter}',
      harness: harness,
    );
    hosts.add(host);
    return host;
  }

  @override
  Future<void> dispose() async {
    for (final h in [...hosts]) {
      await h.dispose();
    }
  }
}

final class _WidgetFakeLocalPaneHost implements LocalPaneHost {
  @override
  final String id;
  final AppThreeWayWsHarness harness;
  @override
  final _WidgetMemPort port = _WidgetMemPort();
  final Completer<int> _exitCode = Completer<int>();
  final StreamController<LocalShareSnapshot> _shareUpdates =
      StreamController<LocalShareSnapshot>.broadcast();
  LocalShareSnapshot _snapshot = LocalShareSnapshot.unshared;

  _WidgetFakeLocalPaneHost({required this.id, required this.harness});

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  LocalShareSnapshot get shareSnapshot => _snapshot;

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
  }) async {
    final assigned = SessionId('wself-$id');
    await Zone.root.run(
      () => harness.startCaster(id: assigned.value, title: title),
    );
    _snapshot = LocalShareSnapshot(
      state: LocalShareState.live,
      sessionId: assigned,
      subscriberCount: 2,
    );
    if (!_shareUpdates.isClosed) _shareUpdates.add(_snapshot);
    return assigned;
  }

  @override
  Future<void> stopShare() async {
    _snapshot = LocalShareSnapshot.unshared;
    if (!_shareUpdates.isClosed) _shareUpdates.add(_snapshot);
  }

  @override
  void setColorScheme(tui.TerminalBrightness brightness) {}

  @override
  Future<void> dispose() async {
    await stopShare();
    await port.dispose();
    if (!_exitCode.isCompleted) _exitCode.complete(0);
    await _shareUpdates.close();
  }
}

final class _WidgetMemPort implements TerminalPort {
  final tui.Buffer _buffer = tui.Buffer.blank(80, 24);
  int totalScrollbackLines = 0;
  final Set<void Function()> _listeners = {};
  final Set<void Function()> _bellListeners = {};
  final Completer<int> _exitCode = Completer<int>();
  final List<Uint8List> inputs = [];

  void emitBell() {
    for (final fn in [..._bellListeners]) {
      fn();
    }
  }

  @override
  String get id => 'wmem-port';

  @override
  tui.Buffer get buffer => _buffer;

  @override
  int get cols => _buffer.width;

  @override
  int get rows => _buffer.height;

  @override
  (int cols, int rows) get activePtySize => (_buffer.width, _buffer.height);

  @override
  CursorStateData get cursor => CursorStateData.origin;

  @override
  TerminalPortModes get modes => TerminalPortModes.defaults;

  @override
  ScrollbackWindowData get scrollbackWindow =>
      (clearSeq: 0, oldestLine: 0, totalLines: totalScrollbackLines);

  @override
  String get windowTitle => 'local-zsh';

  @override
  String? get workingDirectory => '/tmp';

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  void addListener(void Function() listener) => _listeners.add(listener);

  @override
  void removeListener(void Function() listener) => _listeners.remove(listener);

  @override
  void addTitleListener(void Function(String title) listener) {}

  @override
  void removeTitleListener(void Function(String title) listener) {}

  @override
  void addBellListener(void Function() listener) =>
      _bellListeners.add(listener);

  @override
  void removeBellListener(void Function() listener) =>
      _bellListeners.remove(listener);

  @override
  void addAudioListener(void Function(TerminalAudioEvent event) listener) {}

  @override
  void removeAudioListener(void Function(TerminalAudioEvent event) listener) {}

  @override
  void addClipboardListener(
    void Function(String selection, String text) listener,
  ) {}

  @override
  void removeClipboardListener(
    void Function(String selection, String text) listener,
  ) {}

  @override
  void sendInput(Uint8List utf8Bytes) => inputs.add(utf8Bytes);

  @override
  void setViewportSize(
    int cols,
    int rows, {
    int cellPixelWidth = 0,
    int cellPixelHeight = 0,
  }) {}

  @override
  List<ScrollbackLine?> readScrollbackSlice(int startLine, int count) =>
      List<ScrollbackLine?>.filled(count, null);

  @override
  Future<void> dispose() async {
    if (!_exitCode.isCompleted) _exitCode.complete(0);
  }
}

final class _WidgetFakeAudioBuffer implements AudioBuffer {
  @override
  final int hash;

  _WidgetFakeAudioBuffer(this.hash);
}

final class _WidgetFakeAudioEngine implements TermuiAudioEngine {
  int initCalls = 0;
  int _nextId = 1;
  double? lastPan;

  @override
  Future<void> init({bool enableVisualization = true}) async => initCalls += 1;

  @override
  Future<void> dispose() async {}

  @override
  Future<AudioBuffer> loadWaveform(
    WaveForm shape,
    double frequency, {
    bool usePcmFallback = false,
  }) async => _WidgetFakeAudioBuffer(++_nextId);

  @override
  Future<AudioBuffer> loadMem(
    String pathId,
    Uint8List bytes, {
    bool stream = false,
  }) async => _WidgetFakeAudioBuffer(++_nextId);

  @override
  AudioVoice play(
    AudioBuffer buffer, {
    bool loop = false,
    AudioBus? bus,
    bool paused = false,
  }) => AudioVoice(++_nextId, Completer<void>().future);

  @override
  void setVoicePan(AudioVoice voice, double pan) => lastPan = pan;

  @override
  void setVoiceVolume(AudioVoice voice, double volume) {}

  @override
  void setPaused(AudioVoice voice, bool paused) {}

  @override
  void fadeVolume(AudioVoice voice, double targetVolume, Duration duration) {}

  @override
  void scheduleStop(AudioVoice voice, Duration duration) {}

  @override
  void stop(AudioVoice voice) {}

  @override
  Future<void> disposeBuffer(AudioBuffer buffer) async {}

  @override
  void addStreamData(AudioBuffer buffer, Uint8List chunk) {}

  @override
  void attachFilterToBus(AudioBus bus, int filterId) {}

  @override
  Future<AudioBuffer> createBufferStream({
    int maxBufferSize = 4 * 1024 * 1024,
    bool releaseConsumed = false,
    Duration bufferingTimeNeeds = const Duration(milliseconds: 500),
    int sampleRate = 48000,
    int channels = 2,
  }) async => _WidgetFakeAudioBuffer(++_nextId);

  @override
  int createFilter(FilterType type) => 1;

  @override
  void fadeRelativePlaySpeed(
    AudioVoice voice,
    double speed,
    Duration duration,
  ) {}

  @override
  Duration getBufferDuration(AudioBuffer buffer) => Duration.zero;

  @override
  Duration getVoicePosition(AudioVoice voice) => Duration.zero;

  @override
  Stream<Duration> getVoicePositionStream(
    AudioVoice voice, {
    Duration interval = const Duration(milliseconds: 50),
  }) => const Stream.empty();

  @override
  Future<AudioBuffer> loadFile(
    String path, {
    bool stream = false,
    LoadProgressCallback? onProgress,
  }) async => _WidgetFakeAudioBuffer(++_nextId);

  @override
  Future<Uint8List> loadFileBytes(String path) async => Uint8List(0);

  @override
  Future<AudioBuffer> loadUrl(
    String url, {
    LoadProgressCallback? onProgress,
  }) async => _WidgetFakeAudioBuffer(++_nextId);

  @override
  AudioVoice play3d(AudioBuffer buffer, double x, double y, double z) =>
      play(buffer);

  @override
  void seek(AudioVoice voice, Duration position) {}

  @override
  void set3dSourceAttenuation(
    AudioVoice voice,
    AttenuationModel attenuationModel,
    double attenuationRolloffFactor,
  ) {}

  @override
  void set3dSourceMinMaxDistance(
    AudioVoice voice,
    double minDistance,
    double maxDistance,
  ) {}

  @override
  void set3dSourceParameters(
    AudioVoice voice,
    double x,
    double y,
    double z, {
    double vx = 0.0,
    double vy = 0.0,
    double vz = 0.0,
  }) {}

  @override
  void setFilterParameter(
    AudioBus bus,
    int filterId,
    int attributeId,
    double value,
  ) {}

  @override
  void setRelativePlaySpeed(
    AudioVoice voice,
    double speed, {
    bool preservePitch = false,
  }) {}

  @override
  void setStreamEnded(AudioBuffer buffer) {}

  @override
  AudioBus createBus() => const _WidgetFakeAudioBus();

  @override
  void destroyBus(AudioBus bus) {}

  @override
  void fadeFilterParameter(
    AudioBus bus,
    int filterId,
    int paramId,
    double targetValue,
    Duration duration,
  ) {}

  @override
  double getFilterParameter(AudioBus bus, int filterId, int paramId) => 0.0;

  @override
  Float32List getWaveform([Float32List? outBuffer]) =>
      outBuffer ?? Float32List(256);

  @override
  Future<Float32List> fetchWaveform([Float32List? outBuffer]) async =>
      getWaveform(outBuffer);

  @override
  Stream<Float32List> watchWaveform({
    Duration interval = const Duration(milliseconds: 100),
  }) => const Stream.empty();

  @override
  AudioVoice playSprite(
    AudioBuffer buffer, {
    required Duration start,
    required Duration duration,
    AudioBus? bus,
  }) => play(buffer, bus: bus);

  @override
  Future<void> playSpriteSequence(
    AudioBuffer buffer,
    List<SpriteSegment> segments, {
    AudioBus? bus,
  }) async {}
}

final class _WidgetFakeAudioBus implements AudioBus {
  const _WidgetFakeAudioBus();

  @override
  int get id => 1;

  @override
  void setVolume(double volume) {}
}
