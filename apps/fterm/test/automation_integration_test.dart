import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/automation/automation_models.dart';
import 'package:fterm/src/font_loader.dart';
import 'package:fterm/src/fterm_app.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver.dart';
import 'package:fterm/src/workspace/split_tree_model.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart'
    show DockPosition;
import 'package:termui_cast_protocol/termui_cast_protocol.dart'
    show IapTokenProvider, SessionId;
import 'package:termui_flutter/termui_flutter.dart' show ShaderBackendKind;
import 'package:termui_pty/termui_pty.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadCastFonts();
  });

  group('Automation HTTP driver end-to-end integration', () {
    testWidgets(
      'routes all Base endpoints: state, bounds, UI polarity, shader opacity, '
      'shader editor 200/422/404, pointer, tabs select/close force',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final storage = _MemorySettingsStorage()
          ..setItem(
            ftermPreferencesStorageKey,
            const FtermPreferences(
              shaderBackendOverride: ShaderBackendKind.disabled,
            ).toJsonString(),
          );
        final windowBridge = _RecordingWindowBridge();
        final hostDriver = _FakeLocalHostDriver();
        final port = await _reserveFreeLoopbackPort(tester);
        FtermWorkspaceController? workspace;

        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(
              automationDriverEnabled: true,
              automationPort: port,
            ),
            localHostDriver: hostDriver,
            channelFactory: _neverConnectChannelFactory,
            settingsStorage: storage,
            resizeDebounce: Duration.zero,
            automationWindowBridge: windowBridge,
            automationFrameSettle: () async {},
            onWorkspaceCreated: (ws) => workspace = ws,
          ),
        );
        await _settleApp(tester);

        final ws = workspace!;
        expect(ws.automationDriver.isRunning, isTrue);
        expect(ws.automationDriver.allowPty, isFalse);
        final token = ws.automationDriver.password;
        expect(token, isNotEmpty);

        // 1. GET /v1/state (no fps key).
        final stateRes = await _httpRequest(
          tester,
          method: 'GET',
          port: port,
          path: '/v1/state',
          token: token,
        );
        expect(stateRes.statusCode, equals(200));
        final stateResult = _resultMap(stateRes);
        expect(stateResult.containsKey('fps'), isFalse);
        expect(stateResult['theme'], equals(ws.activeTerminalTheme.id));
        expect(stateResult['overlay'], equals('none'));
        expect(stateResult['tabs'], isA<List<Object?>>());

        // 2. GET & POST /v1/window/bounds.
        final getBounds = await _httpRequest(
          tester,
          method: 'GET',
          port: port,
          path: '/v1/window/bounds',
          token: token,
        );
        expect(getBounds.statusCode, equals(200));
        expect(_resultMap(getBounds)['supported'], isTrue);
        expect(_resultMap(getBounds)['cols'], equals(80));
        expect(_resultMap(getBounds)['rows'], equals(24));

        final postBounds = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/window/bounds',
          token: token,
          body: <String, Object?>{
            'x': 10,
            'y': 20,
            'width': 1280,
            'height': 720,
            'units': 'logical',
            'squareCorners': true,
            'alwaysOnTop': true,
            'focus': true,
          },
        );
        expect(postBounds.statusCode, equals(200));
        expect(windowBridge.requests, hasLength(1));
        expect(
          windowBridge.requests.single.units,
          equals(WindowBoundsUnits.logical),
        );
        expect(windowBridge.requests.single.squareCorners, isTrue);
        expect(_resultMap(postBounds)['alwaysOnTop'], isTrue);
        expect(_resultMap(postBounds)['squareCorners'], isTrue);

        final badBounds = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/window/bounds',
          token: token,
          body: <String, Object?>{'width': -5},
        );
        expect(badBounds.statusCode, equals(400));

        // 3. GET & POST /v1/ui with light/dark polarity switching + 400 unknown.
        final getUi = await _httpRequest(
          tester,
          method: 'GET',
          port: port,
          path: '/v1/ui',
          token: token,
        );
        expect(getUi.statusCode, equals(200));
        expect(
          _resultMap(getUi)['availableThemes'],
          containsAll(<String>['termui_dark', 'solarized_light']),
        );

        final unknownTheme = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/ui',
          token: token,
          body: <String, Object?>{'theme': 'nonexistent_theme'},
        );
        expect(unknownTheme.statusCode, equals(400));

        final switchLight = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/ui',
          token: token,
          body: <String, Object?>{
            'theme': 'Solarized Light',
            'fontSize': 16,
            'perfHud': true,
            'overlay': 'about',
          },
        );
        expect(switchLight.statusCode, equals(200));
        final lightUi = _resultMap(switchLight);
        expect(lightUi['theme'], equals('solarized_light'));
        expect(lightUi['appearanceMode'], equals('light'));
        expect(lightUi['fontSize'], equals(16.0));
        expect(lightUi['perfHud'], isTrue);
        expect(lightUi['overlay'], equals('about'));
        expect(
          ws.activeTerminalTheme.brightness,
          equals(tui.TerminalBrightness.light),
        );

        final switchDark = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/ui',
          token: token,
          body: <String, Object?>{
            'theme': 'catppuccin_mocha',
            'perfHud': false,
            'overlay': 'none',
          },
        );
        expect(switchDark.statusCode, equals(200));
        expect(_resultMap(switchDark)['theme'], equals('catppuccin_mocha'));
        expect(_resultMap(switchDark)['appearanceMode'], equals('dark'));
        expect(ws.activeOverlay, equals(FtermOverlay.none));

        // 4. GET & POST /v1/shader preserving explicit backgroundOpacity.
        final postShader = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/shader',
          token: token,
          body: <String, Object?>{
            'background': <String>['wallpaper_wave'],
            'foreground': <String>['crt_lottes'],
            'backgroundOpacity': 0.82,
          },
        );
        expect(postShader.statusCode, equals(200));
        final shaderRes = _resultMap(postShader);
        expect(shaderRes['background'], equals(<String>['wallpaper_wave']));
        expect(shaderRes['foreground'], equals(<String>['crt_lottes']));
        expect(shaderRes['backgroundOpacity'], closeTo(0.82, 1e-6));

        final clearShader = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/shader',
          token: token,
          body: <String, Object?>{'clear': true},
        );
        expect(clearShader.statusCode, equals(200));
        expect(_resultMap(clearShader)['background'], isEmpty);
        expect(_resultMap(clearShader)['foreground'], isEmpty);

        // 5. GET & POST /v1/shader/editor (404 closed, 400 preset, 200, 404 find, 422 error).
        final closedEditor = await _httpRequest(
          tester,
          method: 'GET',
          port: port,
          path: '/v1/shader/editor',
          token: token,
        );
        expect(closedEditor.statusCode, equals(200));
        expect(_resultMap(closedEditor)['open'], isFalse);

        final editWhenClosed = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/shader/editor',
          token: token,
          body: <String, Object?>{'open': false, 'previewMode': 'bg'},
        );
        expect(editWhenClosed.statusCode, equals(404));

        final badPreset = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/shader/editor',
          token: token,
          body: <String, Object?>{'preset': 'totally_fake_preset'},
        );
        expect(badPreset.statusCode, equals(400));

        final openEditor = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/shader/editor',
          token: token,
          body: <String, Object?>{
            'preset': 'wallpaper_wave',
            'previewMode': 'bg',
            'composition': 'blend',
          },
        );
        expect(openEditor.statusCode, equals(200));
        final editorBody = _resultMap(openEditor);
        expect(editorBody['open'], isTrue);
        expect(editorBody['compiled'], isTrue);
        expect(editorBody['previewMode'], equals('bg'));
        expect(editorBody['composition'], equals('blend'));
        final editorPaneId = editorBody['paneId']! as String;

        final missingFind = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/shader/editor',
          token: token,
          body: <String, Object?>{
            'find': 'THIS_STRING_DOES_NOT_EXIST',
            'replace': 'foo',
          },
        );
        expect(missingFind.statusCode, equals(404));

        final validEdit = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/shader/editor',
          token: token,
          body: <String, Object?>{
            'find': 'void mainImage',
            'replace': '// edited\nvoid mainImage',
          },
        );
        expect(validEdit.statusCode, equals(200));
        expect(_resultMap(validEdit)['isDirty'], isTrue);

        final badGlsl = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/shader/editor',
          token: token,
          body: <String, Object?>{
            'source': 'broken glsl without entry point {{{',
            'awaitCompile': true,
          },
        );
        expect(badGlsl.statusCode, equals(422));
        final badGlslErr = badGlsl.body['error']! as Map<String, Object?>;
        final badGlslDetails = badGlslErr['details']! as Map<String, Object?>;
        expect(badGlslDetails['diagnostics'], isNotEmpty);

        // 6. POST /v1/input/pointer (Base scope, succeeds even with allowPty=false).
        await _settleApp(tester);
        final pointerRes = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/input/pointer',
          token: token,
          body: <String, Object?>{'x': 0.5, 'y': 0.25, 'pressed': true},
        );
        expect(pointerRes.statusCode, equals(200));
        expect(hostDriver.hosts.first.port.inputs, isEmpty);

        final pointerClear = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/input/pointer',
          token: token,
          body: <String, Object?>{'clear': true},
        );
        expect(pointerClear.statusCode, equals(200));

        // 7. Tabs select + close (force: false keeps dirty editor, force: true closes it).
        final tabsRes = await _httpRequest(
          tester,
          method: 'GET',
          port: port,
          path: '/v1/tabs',
          token: token,
        );
        expect(tabsRes.statusCode, equals(200));
        expect(_resultMap(tabsRes)['tabs'], hasLength(2));

        final selectFirst = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/tabs/select',
          token: token,
          body: <String, Object?>{'index': 0},
        );
        expect(selectFirst.statusCode, equals(200));
        expect(_resultMap(selectFirst)['activeTabIndex'], equals(0));

        final softCloseDirty = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/tabs/close',
          token: token,
          body: <String, Object?>{'paneId': editorPaneId, 'force': false},
        );
        expect(softCloseDirty.statusCode, equals(200));
        expect(ws.shaderEditorPaneById(editorPaneId), isNotNull);

        final forceCloseDirty = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/tabs/close',
          token: token,
          body: <String, Object?>{'paneId': editorPaneId, 'force': true},
        );
        expect(forceCloseDirty.statusCode, equals(200));
        expect(ws.shaderEditorPaneById(editorPaneId), isNull);
        expect(ws.tabs, hasLength(1));

        await _disposeWidgetTree(tester);
      },
    );

    testWidgets(
      'enforces PTY scope gating and executes spawn, pty/write, screen/find '
      'with wide glyphs, and input/mouse on PTY and ShaderEditorPane',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final storage = _MemorySettingsStorage()
          ..setItem(
            ftermPreferencesStorageKey,
            const FtermPreferences(
              shaderBackendOverride: ShaderBackendKind.disabled,
            ).toJsonString(),
          );
        final hostDriver = _FakeLocalHostDriver();
        final port = await _reserveFreeLoopbackPort(tester);
        FtermWorkspaceController? workspace;

        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(
              automationDriverEnabled: true,
              automationPort: port,
            ),
            localHostDriver: hostDriver,
            channelFactory: _neverConnectChannelFactory,
            settingsStorage: storage,
            resizeDebounce: Duration.zero,
            automationWindowBridge: _RecordingWindowBridge(),
            automationFrameSettle: () async {},
            onWorkspaceCreated: (ws) => workspace = ws,
          ),
        );
        await _settleApp(tester);

        final ws = workspace!;
        final token = ws.automationDriver.password;

        // With allowPty == false, every PTY endpoint returns 403.
        for (final check in const <(String, String, Map<String, Object?>?)>[
          ('POST', '/v1/tabs/spawn', <String, Object?>{}),
          ('POST', '/v1/pty/write', <String, Object?>{'text': 'hi'}),
          ('GET', '/v1/screen', null),
          ('POST', '/v1/screen/find', <String, Object?>{'text': 'a'}),
          (
            'POST',
            '/v1/input/mouse',
            <String, Object?>{'action': 'click', 'col': 1, 'row': 1},
          ),
        ]) {
          final res = await _httpRequest(
            tester,
            method: check.$1,
            port: port,
            path: check.$2,
            token: token,
            body: check.$3,
          );
          expect(
            res.statusCode,
            equals(403),
            reason: '${check.$1} ${check.$2}',
          );
        }

        // Enable PTY scope live.
        ws.automationDriver.setAllowPty(true);
        ws.updatePreferences(
          ws.preferences.copyWith(
            shellExecutable: '/bin/custom-zsh',
            shellArguments: const <String>['--interactive'],
            loginShell: true,
          ),
        );

        // 1. Spawn tab with only cwd: preserves user shell defaults & renames tab.
        final spawnTab = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/tabs/spawn',
          token: token,
          body: <String, Object?>{'cwd': '/tmp/demo', 'title': 'Demo Shell'},
        );
        expect(spawnTab.statusCode, equals(200));
        final spawnedTabId = _resultMap(spawnTab)['tabId']! as String;
        final spawnedPaneId = _resultMap(spawnTab)['paneId']! as String;
        expect(ws.activeTab!.tabId, equals(spawnedTabId));
        expect(ws.activeTab!.pinnedTitle, equals('Demo Shell'));
        expect(
          hostDriver.openedConfigs.last.executable,
          equals('/bin/custom-zsh'),
        );
        expect(
          hostDriver.openedConfigs.last.arguments,
          equals(<String>['--interactive']),
        );
        expect(hostDriver.openedConfigs.last.loginShell, isTrue);
        expect(
          hostDriver.openedConfigs.last.workingDirectory,
          equals('/tmp/demo'),
        );

        // Horizontal and vertical splits.
        final splitHoriz = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/tabs/spawn',
          token: token,
          body: <String, Object?>{'split': 'horizontal'},
        );
        expect(splitHoriz.statusCode, equals(200));
        final splitPaneId = _resultMap(splitHoriz)['paneId']! as String;
        expect(ws.activeTab!.splitTree.paneIds, contains(splitPaneId));
        expect(
          (ws.activeTab!.splitTree.root as SplitNode).axis,
          equals(SplitAxis.horizontal),
        );

        // 2. POST /v1/pty/write (UTF-8 + base64 + invalid base64 + editor + exited).
        final activeHost = hostDriver.hosts.last;
        final writeText = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/pty/write',
          token: token,
          body: <String, Object?>{'text': 'echo hello\n'},
        );
        expect(writeText.statusCode, equals(200));
        expect(
          utf8.decode(activeHost.port.inputs.last),
          equals('echo hello\n'),
        );

        const rawEsc = '\x1b_Sa=set,p=crt_lottes\x1b\\';
        final writeB64 = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/pty/write',
          token: token,
          body: <String, Object?>{
            'base64': base64Encode(utf8.encode(rawEsc)),
            'paneId': spawnedPaneId,
          },
        );
        expect(writeB64.statusCode, equals(200));
        expect(
          utf8.decode(hostDriver.hosts[1].port.inputs.last),
          equals(rawEsc),
        );

        final badB64 = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/pty/write',
          token: token,
          body: <String, Object?>{'base64': '!!!not-base64!!!'},
        );
        expect(badB64.statusCode, equals(400));

        // 3. GET /v1/screen & POST /v1/screen/find with wide CJK glyphs.
        final targetHost = hostDriver.hosts[1];
        targetHost.port.writeRowCells(2, <String>[
          '漢',
          '',
          '字',
          '',
          ' ',
          'C',
          'l',
          'i',
          'c',
          'k',
          ' ',
          '星',
          '',
        ]);
        targetHost.port.emitFrame();

        final screenRes = await _httpRequest(
          tester,
          method: 'GET',
          port: port,
          path: '/v1/screen?paneId=$spawnedPaneId',
          token: token,
        );
        expect(screenRes.statusCode, equals(200));
        final screenData = _resultMap(screenRes);
        expect(screenData['cols'], equals(80));
        expect(screenData['rows'], equals(24));
        expect(
          (screenData['lines']! as List<Object?>)[2],
          equals('漢字 Click 星'),
        );

        final findWide = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/screen/find',
          token: token,
          body: <String, Object?>{'text': 'Click 星', 'paneId': spawnedPaneId},
        );
        expect(findWide.statusCode, equals(200));
        final matches = _resultMap(findWide)['matches']! as List<Object?>;
        expect(matches, hasLength(1));
        final match = matches.single! as Map<String, Object?>;
        expect(match['row'], equals(2));
        expect(match['col'], equals(5));
        expect(
          match['endCol'],
          equals(13),
        ); // includes trailing empty continuation cell
        expect(match['x'], closeTo((5 + 13) / (2 * 80), 1e-6));
        expect(match['y'], closeTo(2.5 / 24, 1e-6));

        // 4. POST /v1/input/mouse on PTY pane (SGR mouse tracking on -> 1-based bytes).
        targetHost.port.modes = const TerminalPortModes(
          mouseTracking: true,
          sgrMouse: true,
        );
        targetHost.port.inputs.clear();
        final mouseClick = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/input/mouse',
          token: token,
          body: <String, Object?>{
            'action': 'click',
            'col': 5,
            'row': 2,
            'paneId': spawnedPaneId,
          },
        );
        expect(mouseClick.statusCode, equals(200));
        final clickWire = [
          for (final chunk in targetHost.port.inputs) utf8.decode(chunk),
        ].join();
        expect(clickWire, contains('\x1b[<0;6;3M'));
        expect(clickWire, contains('\x1b[<0;6;3m'));

        targetHost.port.inputs.clear();
        final mouseDrag = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/input/mouse',
          token: token,
          body: <String, Object?>{
            'action': 'drag',
            'col': 7,
            'row': 2,
            'paneId': spawnedPaneId,
          },
        );
        expect(mouseDrag.statusCode, equals(200));
        final dragWire = [
          for (final chunk in targetHost.port.inputs) utf8.decode(chunk),
        ].join();
        expect(dragWire, contains('\x1b[<32;8;3M'));

        targetHost.port.inputs.clear();
        final mouseScroll = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/input/mouse',
          token: token,
          body: <String, Object?>{
            'action': 'scroll',
            'col': 5,
            'row': 2,
            'deltaY': -1,
            'paneId': spawnedPaneId,
          },
        );
        expect(mouseScroll.statusCode, equals(200));
        final scrollWire = [
          for (final chunk in targetHost.port.inputs) utf8.decode(chunk),
        ].join();
        expect(scrollWire, contains('\x1b[<64;6;3M'));

        // Exited PTY returns 409 on pty/write and input/mouse.
        activeHost.port.completeExit(0);
        await _settleApp(tester);
        final exitedWrite = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/pty/write',
          token: token,
          body: <String, Object?>{'text': 'ls', 'paneId': splitPaneId},
        );
        expect(exitedWrite.statusCode, equals(409));

        // 5. ShaderEditorPane: pty/write returns 400; input/mouse succeeds (200).
        await tester.runAsync(() => ws.openShaderEditorTab());
        await _settleApp(tester);
        final editorId = ws.focusedEditorPane!.paneId;

        final writeEditor = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/pty/write',
          token: token,
          body: <String, Object?>{'text': 'nope', 'paneId': editorId},
        );
        expect(writeEditor.statusCode, equals(400));

        final mouseEditor = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/input/mouse',
          token: token,
          body: <String, Object?>{
            'action': 'click',
            'x': 0.3,
            'y': 0.4,
            'paneId': editorId,
          },
        );
        expect(mouseEditor.statusCode, equals(200));

        // 6. Empty-workspace split spawn succeeds.
        for (final tab in [...ws.tabs]) {
          await tester.runAsync(
            () => ws.closeTab(ws.tabs.indexOf(tab), force: true),
          );
        }
        expect(ws.tabs, isEmpty);
        final emptySplit = await _httpRequest(
          tester,
          method: 'POST',
          port: port,
          path: '/v1/tabs/spawn',
          token: token,
          body: <String, Object?>{'split': 'vertical'},
        );
        expect(emptySplit.statusCode, equals(200));
        expect(_resultMap(emptySplit)['tabId'], isNotEmpty);
        expect(_resultMap(emptySplit)['paneId'], isNotEmpty);
        expect(ws.tabs, hasLength(1));

        await _disposeWidgetTree(tester);
      },
    );

    testWidgets(
      'renders non-dismissable indicator in tab bar & hidden tab bar with '
      'accent/amber dot and navigates directly to Settings -> Automation',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final storage = _MemorySettingsStorage()
          ..setItem(
            ftermPreferencesStorageKey,
            const FtermPreferences(
              shaderBackendOverride: ShaderBackendKind.disabled,
            ).toJsonString(),
          );
        final hostDriver = _FakeLocalHostDriver();
        final port = await _reserveFreeLoopbackPort(tester);
        FtermWorkspaceController? workspace;

        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(),
            localHostDriver: hostDriver,
            channelFactory: _neverConnectChannelFactory,
            settingsStorage: storage,
            resizeDebounce: Duration.zero,
            automationWindowBridge: _RecordingWindowBridge(),
            automationFrameSettle: () async {},
            onWorkspaceCreated: (ws) => workspace = ws,
          ),
        );
        await _settleApp(tester);

        final ws = workspace!;
        // Stopped by default -> neither indicator appears.
        expect(
          find.byKey(const ValueKey('fterm-automation-indicator')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('fterm-automation-corner-pill')),
          findsNothing,
        );

        // Start driver (Base only) -> tab bar indicator appears with accent dot.
        ws.automationDriver.setPort(port);
        await tester.runAsync(() => ws.automationDriver.setEnabled(true));
        await _settleApp(tester);

        expect(
          find.byKey(const ValueKey('fterm-automation-indicator')),
          findsOneWidget,
        );
        final theme = ws.activeTerminalTheme;
        final baseDotColor = _readContainerColor(
          tester,
          const ValueKey('fterm-automation-indicator-dot'),
        );
        expect(baseDotColor, equals(Color(theme.resolveAnsi256(4).argb)));

        // Enable PTY -> dot switches to amber (ANSI 3).
        ws.automationDriver.setAllowPty(true);
        await _settleApp(tester);
        final ptyDotColor = _readContainerColor(
          tester,
          const ValueKey('fterm-automation-indicator-dot'),
        );
        expect(ptyDotColor, equals(Color(theme.resolveAnsi256(3).argb)));

        // Clicking indicator opens Settings directly on the Automation tab.
        await tester.tap(
          find.byKey(const ValueKey('fterm-automation-indicator')),
        );
        await _settleApp(tester);
        expect(ws.activeOverlay, equals(FtermOverlay.settings));
        expect(
          find.byKey(const ValueKey('automation-enable-switch')),
          findsOneWidget,
        );

        // Switch to Interface while Settings stays open, then request Automation ->
        // switches immediately even though Settings was already mounted.
        await tester.tap(find.byKey(const ValueKey('settings-tab-interface')));
        await _settleApp(tester);
        expect(
          find.byKey(const ValueKey('automation-enable-switch')),
          findsNothing,
        );

        ws.openSettingsOverlay(initialSection: .automation);
        await _settleApp(tester);
        expect(
          find.byKey(const ValueKey('automation-enable-switch')),
          findsOneWidget,
        );

        // Dismiss Settings and hide the tab bar -> corner pill stays visible!
        ws.dismissOverlay();
        ws.setDockPosition(DockPosition.hidden);
        await _settleApp(tester);

        expect(
          find.byKey(const ValueKey('fterm-automation-indicator')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('fterm-automation-corner-pill')),
          findsOneWidget,
        );
        final pillDotColor = _readContainerColor(
          tester,
          const ValueKey('fterm-automation-corner-pill-dot'),
        );
        expect(pillDotColor, equals(Color(theme.resolveAnsi256(3).argb)));

        // Clicking the hidden-tab-bar corner pill opens Settings -> Automation.
        await tester.tap(
          find.byKey(const ValueKey('fterm-automation-corner-pill')),
        );
        await _settleApp(tester);
        expect(ws.activeOverlay, equals(FtermOverlay.settings));
        expect(
          find.byKey(const ValueKey('automation-enable-switch')),
          findsOneWidget,
        );

        await _disposeWidgetTree(tester);
      },
    );

    testWidgets(
      'applies CLI startup flags including ephemeral FTERM_AUTOMATION_TOKEN',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final storage = _MemorySettingsStorage()
          ..setItem(
            ftermPreferencesStorageKey,
            const FtermPreferences(
              shaderBackendOverride: ShaderBackendKind.disabled,
            ).toJsonString(),
          );
        final hostDriver = _FakeLocalHostDriver();
        final port = await _reserveFreeLoopbackPort(tester);
        FtermWorkspaceController? workspace;

        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(
              automationDriverEnabled: true,
              automationAllowPty: true,
              automationPort: port,
              automationTokenOverride: 'cli-ephemeral-secret',
            ),
            localHostDriver: hostDriver,
            channelFactory: _neverConnectChannelFactory,
            settingsStorage: storage,
            resizeDebounce: Duration.zero,
            automationWindowBridge: _RecordingWindowBridge(),
            automationFrameSettle: () async {},
            onWorkspaceCreated: (ws) => workspace = ws,
          ),
        );
        await _settleApp(tester);

        final ws = workspace!;
        expect(ws.automationDriver.isRunning, isTrue);
        expect(ws.automationDriver.allowPty, isTrue);
        expect(ws.automationDriver.hasEphemeralTokenOverride, isTrue);

        // Ephemeral token authenticates and unlocks PTY endpoints immediately.
        final screenRes = await _httpRequest(
          tester,
          method: 'GET',
          port: port,
          path: '/v1/screen',
          token: 'cli-ephemeral-secret',
        );
        expect(screenRes.statusCode, equals(200));

        // Wrong token is rejected with 401.
        final badAuth = await _httpRequest(
          tester,
          method: 'GET',
          port: port,
          path: '/v1/state',
          token: 'wrong-secret',
        );
        expect(badAuth.statusCode, equals(401));

        await _disposeWidgetTree(tester);
      },
    );

    testWidgets(
      'Web mode hides Automation Settings tab and keeps storage/backend inert',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final storage = _MemorySettingsStorage()
          ..setItem(
            ftermPreferencesStorageKey,
            const FtermPreferences(
              shaderBackendOverride: ShaderBackendKind.disabled,
            ).toJsonString(),
          );
        FtermWorkspaceController? workspace;

        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(promptForConnection: false),
            isWebOverride: true,
            channelFactory: _neverConnectChannelFactory,
            settingsStorage: storage,
            resizeDebounce: Duration.zero,
            automationFrameSettle: () async {},
            onWorkspaceCreated: (ws) => workspace = ws,
          ),
        );
        await _settleApp(tester);

        final ws = workspace!;
        expect(ws.automationDriver.isSupported, isFalse);
        expect(ws.automationDriver.isRunning, isFalse);
        expect(storage.getItem(ftermAutomationConfigStorageKey), isNull);

        ws.openSettingsOverlay(initialSection: .automation);
        await _settleApp(tester);
        expect(
          find.byKey(const ValueKey('settings-tab-interface')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('settings-tab-keyboard')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('settings-tab-automation')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('automation-enable-switch')),
          findsNothing,
        );

        await _disposeWidgetTree(tester);
      },
    );
  });
}

Future<int> _reserveFreeLoopbackPort(WidgetTester tester) async {
  final port = await tester.runAsync(() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final freePort = socket.port;
    await socket.close();
    return freePort;
  });
  return port!;
}

Future<void> _settleApp(WidgetTester tester, {int cycles = 4}) async {
  for (var i = 0; i < cycles; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}

Future<void> _disposeWidgetTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump(const Duration(seconds: 3));
}

Color? _readContainerColor(WidgetTester tester, ValueKey<String> key) {
  final container = tester.widget<Container>(find.byKey(key));
  final deco = container.decoration as BoxDecoration?;
  return deco?.color;
}

Map<String, Object?> _resultMap(
  ({int statusCode, Map<String, Object?> body}) res,
) => res.body['result']! as Map<String, Object?>;

Future<({int statusCode, Map<String, Object?> body})> _httpRequest(
  WidgetTester tester, {
  required String method,
  required int port,
  required String path,
  required String token,
  Map<String, Object?>? body,
}) async {
  final completer = Completer<({int statusCode, Map<String, Object?> body})>();
  Zone.root.run(() {
    unawaited(
      HttpOverrides.runWithHttpOverrides(() async {
        final client = HttpClient();
        try {
          final uri = Uri.parse('http://127.0.0.1:$port$path');
          final req = await client.openUrl(method, uri);
          req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
          if (body != null) {
            req.headers.contentType = ContentType.json;
            req.add(utf8.encode(jsonEncode(body)));
          }
          final res = await req.close();
          final text = await utf8.decoder.bind(res).join();
          final decoded = jsonDecode(text) as Map<String, Object?>;
          completer.complete((statusCode: res.statusCode, body: decoded));
        } on Object catch (error, stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        } finally {
          client.close(force: true);
        }
      }, _PassthroughHttpOverrides()),
    );
  });

  for (var i = 0; i < 400 && !completer.isCompleted; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  if (!completer.isCompleted) {
    throw TimeoutException('HTTP timeout: $method $path');
  }
  return completer.future;
}

final class _PassthroughHttpOverrides extends HttpOverrides {}

Future<StreamChannel<Uint8List>> _neverConnectChannelFactory() =>
    Completer<StreamChannel<Uint8List>>().future;

final class _MemorySettingsStorage implements SettingsStorage {
  final Map<String, String> _values = <String, String>{};

  @override
  String? getItem(String key) => _values[key];

  @override
  void setItem(String key, String value) {
    _values[key] = value;
  }
}

final class _RecordingWindowBridge implements AutomationWindowBridge {
  final List<WindowBoundsRequest> requests = <WindowBoundsRequest>[];

  WindowBoundsSnapshot _snapshot = const WindowBoundsSnapshot(
    supported: true,
    physical: WindowBoundsRect(x: 0, y: 0, width: 1920, height: 1080),
    logical: WindowBoundsRect(x: 0, y: 0, width: 960, height: 540),
    dpr: 2.0,
    alwaysOnTop: false,
    squareCorners: false,
  );

  @override
  Future<WindowBoundsSnapshot> getBounds() async => _snapshot;

  @override
  Future<WindowBoundsSnapshot> setBounds(WindowBoundsRequest request) async {
    requests.add(request);
    final dpr = _snapshot.dpr;
    final curPhys = _snapshot.physical!;
    final curLog = _snapshot.logical!;
    final isLog = request.units == WindowBoundsUnits.logical;
    final nextLog = WindowBoundsRect(
      x: isLog ? (request.x ?? curLog.x) : (request.x ?? curPhys.x) / dpr,
      y: isLog ? (request.y ?? curLog.y) : (request.y ?? curPhys.y) / dpr,
      width: isLog
          ? (request.width ?? curLog.width)
          : (request.width ?? curPhys.width) / dpr,
      height: isLog
          ? (request.height ?? curLog.height)
          : (request.height ?? curPhys.height) / dpr,
    );
    final nextPhys = WindowBoundsRect(
      x: nextLog.x * dpr,
      y: nextLog.y * dpr,
      width: nextLog.width * dpr,
      height: nextLog.height * dpr,
    );
    _snapshot = WindowBoundsSnapshot(
      supported: true,
      physical: nextPhys,
      logical: nextLog,
      dpr: dpr,
      alwaysOnTop: request.alwaysOnTop ?? _snapshot.alwaysOnTop,
      squareCorners: request.squareCorners ?? _snapshot.squareCorners,
    );
    return _snapshot;
  }
}

final class _FakeLocalHostDriver implements LocalHostDriver {
  final List<_FakeLocalPaneHost> hosts = <_FakeLocalPaneHost>[];
  final List<LocalShellConfig> openedConfigs = <LocalShellConfig>[];
  int _counter = 0;

  @override
  bool get isSupported => true;

  @override
  Future<LocalPaneHost> openShell(LocalShellConfig config) async {
    openedConfigs.add(config);
    final host = _FakeLocalPaneHost(
      id: 'auto-local-${++_counter}',
      workingDirectory: config.workingDirectory,
    );
    hosts.add(host);
    return host;
  }

  @override
  Future<void> dispose() async {
    for (final host in [...hosts]) {
      await host.dispose();
    }
  }
}

final class _FakeLocalPaneHost implements LocalPaneHost {
  @override
  final String id;

  @override
  final _FakeTerminalPort port;

  final Completer<int> _exitCode = Completer<int>();
  final StreamController<LocalShareSnapshot> _shareUpdates =
      StreamController<LocalShareSnapshot>.broadcast();

  _FakeLocalPaneHost({required this.id, String? workingDirectory})
    : port = _FakeTerminalPort(
        id: 'port-$id',
        workingDirectory: workingDirectory,
      );

  @override
  Future<int> get exitCode => _exitCode.future;

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
  void setColorScheme(tui.TerminalBrightness brightness) {}

  @override
  bool isLiveRowWrapped(int row) => false;

  @override
  Future<void> dispose() async {
    await port.dispose();
    if (!_exitCode.isCompleted) _exitCode.complete(0);
    await _shareUpdates.close();
  }
}

final class _FakeTerminalPort implements TerminalPort {
  @override
  final String id;

  @override
  final String? workingDirectory;

  final tui.Buffer _buffer = tui.Buffer.blank(80, 24);
  final Set<void Function()> _listeners = <void Function()>{};
  final Set<void Function()> _bellListeners = <void Function()>{};
  final Set<void Function(String)> _titleListeners = <void Function(String)>{};
  final Set<void Function(TerminalAudioEvent)> _audioListeners =
      <void Function(TerminalAudioEvent)>{};
  final Set<void Function(String, String)> _clipboardListeners =
      <void Function(String, String)>{};
  final Set<void Function(TerminalShaderApcEvent)> _shaderListeners =
      <void Function(TerminalShaderApcEvent)>{};
  final Completer<int> _exitCode = Completer<int>();
  final List<Uint8List> inputs = <Uint8List>[];

  int _renderRevision = 0;
  int _fullSyncRevision = 0;
  TerminalPortModes _modes = TerminalPortModes.defaults;
  final String _title = 'zsh';

  _FakeTerminalPort({required this.id, this.workingDirectory});

  void writeRowCells(int row, List<String> cells) {
    final rowOffset = row * _buffer.width;
    for (var col = 0; col < cells.length && col < _buffer.width; col++) {
      _buffer.characters[rowOffset + col] = cells[col];
    }
  }

  void emitFrame() {
    _renderRevision += 1;
    _fullSyncRevision += 1;
    for (final fn in [..._listeners]) {
      fn();
    }
  }

  void completeExit([int code = 0]) {
    if (!_exitCode.isCompleted) _exitCode.complete(code);
  }

  set modes(TerminalPortModes next) => _modes = next;

  @override
  tui.Buffer get buffer => _buffer;

  @override
  int get cols => _buffer.width;

  @override
  int get rows => _buffer.height;

  @override
  int get renderRevision => _renderRevision;

  @override
  int get fullSyncRevision => _fullSyncRevision;

  @override
  List<DirtyCellSpan> get dirtySpans => const <DirtyCellSpan>[];

  @override
  (int cols, int rows) get activePtySize => (_buffer.width, _buffer.height);

  @override
  CursorStateData get cursor => CursorStateData.origin;

  @override
  TerminalPortModes get modes => _modes;

  @override
  ScrollbackWindowData get scrollbackWindow =>
      (clearSeq: 0, oldestLine: 0, totalLines: 0);

  @override
  String get windowTitle => _title;

  @override
  List<ScrollbackLine> readScrollbackSlice(int startLine, int count) =>
      const <ScrollbackLine>[];

  @override
  void setViewportSize(
    int cols,
    int rows, {
    int cellPixelWidth = 0,
    int cellPixelHeight = 0,
  }) {}

  @override
  void sendInput(Uint8List data) {
    inputs.add(Uint8List.fromList(data));
  }

  @override
  void setShaderCapabilities(TerminalShaderCapabilities capabilities) {}

  @override
  void addListener(void Function() listener) => _listeners.add(listener);

  @override
  void removeListener(void Function() listener) => _listeners.remove(listener);

  @override
  void addBellListener(void Function() listener) =>
      _bellListeners.add(listener);

  @override
  void removeBellListener(void Function() listener) =>
      _bellListeners.remove(listener);

  @override
  void addTitleListener(void Function(String title) listener) =>
      _titleListeners.add(listener);

  @override
  void removeTitleListener(void Function(String title) listener) =>
      _titleListeners.remove(listener);

  @override
  void addAudioListener(void Function(TerminalAudioEvent event) listener) =>
      _audioListeners.add(listener);

  @override
  void removeAudioListener(void Function(TerminalAudioEvent event) listener) =>
      _audioListeners.remove(listener);

  @override
  void addClipboardListener(
    void Function(String selection, String text) listener,
  ) => _clipboardListeners.add(listener);

  @override
  void removeClipboardListener(
    void Function(String selection, String text) listener,
  ) => _clipboardListeners.remove(listener);

  @override
  void addShaderListener(
    void Function(TerminalShaderApcEvent event) listener,
  ) => _shaderListeners.add(listener);

  @override
  void removeShaderListener(
    void Function(TerminalShaderApcEvent event) listener,
  ) => _shaderListeners.remove(listener);

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  Future<void> dispose() async {
    _listeners.clear();
    _bellListeners.clear();
    _titleListeners.clear();
    _audioListeners.clear();
    _clipboardListeners.clear();
    _shaderListeners.clear();
    if (!_exitCode.isCompleted) _exitCode.complete(0);
  }
}
