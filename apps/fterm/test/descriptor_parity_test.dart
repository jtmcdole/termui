import 'dart:typed_data';

import 'package:flutter/services.dart'
    show KeyDownEvent, LogicalKeyboardKey, PhysicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/commands/action_descriptors.dart';
import 'package:fterm/src/commands/descriptor_adapters.dart';
import 'package:fterm/src/commands/fterm_capability_context.dart';
import 'package:fterm/src/commands/fterm_descriptor_models.dart';
import 'package:fterm/src/commands/fterm_shortcut_spec.dart';
import 'package:fterm/src/commands/settings_descriptors.dart';
import 'package:fterm/src/commands/shortcut_catalog.dart';
import 'package:fterm/src/launch_config.dart';
import 'package:fterm/src/perf/fterm_trace_recorder.dart';
import 'package:fterm/src/perf/trace_exporter.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/shader_profile_store.dart';
import 'package:fterm/src/ui/fterm_overlays.dart';
import 'package:fterm/src/ui/fterm_shortcut_dispatcher.dart';
import 'package:fterm/src/ui/palette/palette_command_registry.dart';
import 'package:fterm/src/ui/settings/fterm_keyboard_settings_tab.dart';
import 'package:fterm/src/ui/settings/fterm_settings_overlay.dart';
import 'package:fterm/src/ui/settings/settings_catalog.dart';
import 'package:fterm/src/ui/settings/settings_descriptor_renderer.dart';
import 'package:fterm/src/ui/settings/settings_sections.dart';
import 'package:fterm/src/ui/settings/settings_shader_panels.dart';
import 'package:fterm/src/update/update_service.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver.dart';
import 'package:material_ui/material_ui.dart';
import 'package:termui/terminal/event.dart' as ev;
import 'package:termui_cast_client_core/termui_cast_client_core.dart'
    show CastClientRepository, WsClientTransport;
import 'package:termui_flutter/termui_flutter.dart'
    show
        DisabledShaderBackend,
        HostShortcutResult,
        TerminalShaderController,
        TerminalShaderPreset;

final class _MemStorage implements SettingsStorage {
  final Map<String, String> _data = <String, String>{};

  @override
  String? getItem(String key) => _data[key];

  @override
  void setItem(String key, String value) => _data[key] = value;
}

final class _StubLocalHostDriver implements LocalHostDriver {
  @override
  final bool isSupported;

  const _StubLocalHostDriver({this.isSupported = true});

  @override
  Future<LocalPaneHost> openShell(LocalShellConfig config) =>
      throw UnimplementedError();

  @override
  Future<void> dispose() async {}
}

final class _StubShaderProfileStore implements ShaderProfileStore {
  @override
  String? get shadersDirectoryPath => '/tmp/fterm/shaders';

  @override
  Future<List<String>> listShaderFiles() async => const <String>[];

  @override
  Future<String> loadShaderSource(String pathOrKey) =>
      throw ShaderAssetException('Not found', pathOrKey: pathOrKey);

  @override
  Future<Uint8List> loadWallpaperBytes(String pathOrKey) =>
      throw ShaderAssetException('Not found', pathOrKey: pathOrKey);

  @override
  Future<void> saveShaderSource(String name, String glslSource) async {}

  @override
  Future<void> saveWallpaperBytes(String key, Uint8List bytes) async {}

  @override
  Stream<ShaderDirectoryChange> watchShaderDirectory() =>
      const Stream<ShaderDirectoryChange>.empty();

  @override
  void dispose() {}
}

final class _StubUpdateService implements UpdateService {
  @override
  final SelfUpdateCapability capability;

  const _StubUpdateService({bool isSupportedDesktop = true})
    : capability = isSupportedDesktop
          ? SelfUpdateCapability.supported
          : SelfUpdateCapability.unsupportedWeb;

  @override
  FtermSemVer get currentVersion => FtermSemVer(0, 7, 0);

  @override
  Future<UpdateCheckOutcome> checkForUpdates({
    required bool includePrereleases,
    String? lastEtag,
    List<String> cachedTags = const <String>[],
  }) async => UpdateCheckOutcome(
    availableUpdate: null,
    tagEtag: 'etag-1',
    cachedTags: const <String>[],
    cacheTagState: true,
  );

  @override
  Future<StagedUpdate> stageUpdate(
    AvailableUpdate update, {
    void Function(DownloadProgress progress)? onProgress,
  }) => throw UnimplementedError();

  @override
  bool hasSiblingInstances() => false;

  @override
  bool prepareExclusiveSwapLock() => false;

  @override
  void cancelExclusiveSwapLock() {}

  @override
  Future<void> applyStagedUpdateAndExit(
    StagedUpdate staged, {
    required bool relaunch,
    List<String> relaunchArgs = const <String>[],
    Future<void> Function()? beforeExitTeardown,
  }) async {}

  @override
  Future<void> revealStagedInFinder(StagedUpdate staged) async {}

  @override
  Future<void> runStartupCleanup() async {}

  @override
  void dispose() {}
}

FtermWorkspaceController _createWorkspace({
  bool isDesktopHost = true,
  bool supportsUpdates = true,
  FtermTraceRecorder? traceRecorder,
  Set<String> enabledFeatures = const <String>{},
}) {
  final transport = WsClientTransport(
    serverUri: CastLaunchConfig.defaultServerUri,
    token: '',
  );
  return FtermWorkspaceController(
    launchConfig: CastLaunchConfig(promptForConnection: false),
    repository: CastClientRepository(transport: transport),
    localHostDriver: _StubLocalHostDriver(isSupported: isDesktopHost),
    audioController: FtermAudioController(
      initialMuted: false,
      requireUserGesture: false,
    ),
    storage: _MemStorage(),
    resizeDebounce: Duration.zero,
    shaderProfileStore: _StubShaderProfileStore(),
    shaderController: TerminalShaderController(
      backendFactory: (_) => const DisabledShaderBackend(),
    ),
    traceRecorder: traceRecorder,
    updateService: _StubUpdateService(isSupportedDesktop: supportsUpdates),
    enabledFeatures: enabledFeatures,
  );
}

KeyDownEvent _keyDown(LogicalKeyboardKey key, {String? character}) =>
    KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: key,
      character: character,
      timeStamp: Duration.zero,
    );

void main() {
  const capabilityMatrix = <({String name, FtermCapabilityContext ctx})>[
    (
      name: 'macOS desktop',
      ctx: FtermCapabilityContext(
        isWeb: false,
        platform: .macOS,
        isDesktopHost: true,
        supportsUpdates: true,
      ),
    ),
    (
      name: 'Linux desktop',
      ctx: FtermCapabilityContext(
        isWeb: false,
        platform: .linux,
        isDesktopHost: true,
        supportsUpdates: true,
      ),
    ),
    (
      name: 'Windows desktop',
      ctx: FtermCapabilityContext(
        isWeb: false,
        platform: .windows,
        isDesktopHost: true,
        supportsUpdates: true,
      ),
    ),
    (
      name: 'Desktop without local shell or updates',
      ctx: FtermCapabilityContext(
        isWeb: false,
        platform: .linux,
        isDesktopHost: false,
        supportsUpdates: false,
      ),
    ),
    (
      name: 'Web macOS',
      ctx: FtermCapabilityContext(
        isWeb: true,
        platform: .macOS,
        isDesktopHost: false,
        supportsUpdates: false,
      ),
    ),
    (
      name: 'Web Linux',
      ctx: FtermCapabilityContext(
        isWeb: true,
        platform: .linux,
        isDesktopHost: false,
        supportsUpdates: false,
      ),
    ),
  ];

  group('SettingsCatalog <-> allSettingDescriptors 1:1 parity', () {
    test('allSearchItems matches projected setting descriptors 1:1', () {
      final projected = projectDescriptorsToSettingsSearchEntries(
        allSettingDescriptors,
      );
      expect(SettingsCatalog.allSearchItems.length, equals(projected.length));
      expect(allSettingDescriptors.length, equals(projected.length));

      final seenSettingIds = <String>{};
      for (var i = 0; i < projected.length; i++) {
        final item = SettingsCatalog.allSearchItems[i];
        final entry = projected[i];
        expect(seenSettingIds.add(item.id), isTrue, reason: 'dup ${item.id}');
        expect(item.id, equals(entry.id));
        expect(item.section, equals(entry.section));
        expect(item.panelId, equals(entry.panelId));
        expect(item.panelTitle, equals(entry.panelTitle));
        expect(item.title, equals(entry.title));
        expect(item.keywords, equals(entry.keywords));
        expect(item.desktopOnly, equals(entry.desktopOnly));
        expect(item.windowsOnly, equals(entry.windowsOnly));
      }
    });

    test('zero duplicate IDs across descriptors and Palette projections', () {
      final actionIds = <String>{};
      for (final action in allActionDescriptors) {
        expect(
          actionIds.add(action.id),
          isTrue,
          reason: 'duplicate action id ${action.id}',
        );
      }

      final ws = _createWorkspace();
      addTearDown(ws.dispose);

      for (final entry in capabilityMatrix) {
        final commands = buildPaletteCommands(
          PaletteContext(
            workspace: ws,
            isWeb: entry.ctx.isWeb,
            platform: entry.ctx.platform,
            isDesktopHost: entry.ctx.isDesktopHost,
            supportsUpdates: entry.ctx.supportsUpdates,
          ),
        );
        final ids = <String>{};
        for (final item in commands) {
          expect(
            ids.add(item.id),
            isTrue,
            reason: 'duplicate palette id ${item.id} on ${entry.name}',
          );
        }
      }
    });
  });

  group('Setting -> Palette coverage & custom setting rationale parity', () {
    test('every non-custom setting projects >=1 PaletteItem when visible and 0 '
        'when hidden across the capability matrix', () {
      final ws = _createWorkspace();
      addTearDown(ws.dispose);

      for (final descriptor in allSettingDescriptors) {
        if (descriptor is FtermCustomSettingDescriptor) continue;
        for (final entry in capabilityMatrix) {
          final projected = projectDescriptorsToPaletteItems(
            <FtermDescriptor>[descriptor],
            ws,
            entry.ctx,
          );
          if (descriptor.isVisibleFor(entry.ctx)) {
            expect(
              projected,
              isNotEmpty,
              reason: '${descriptor.id} should project on ${entry.name}',
            );
          } else {
            expect(
              projected,
              isEmpty,
              reason: '${descriptor.id} should be hidden on ${entry.name}',
            );
          }
        }
      }
    });

    test(
      'every FtermCustomSettingDescriptor has either paletteExcludedReason or '
      'runtime Palette items',
      () async {
        final ws = _createWorkspace();
        addTearDown(ws.dispose);
        // Activate a shader and add a trusted hash so runtime shader params and
        // trusted-hash reset commands are materialized in the Palette.
        await ws.toggleForegroundShader(
          TerminalShaderPreset.crtLottes.wireName,
        );
        ws.approveCliShaderHash(
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
          remember: true,
        );

        final commands = buildPaletteCommands(
          PaletteContext(
            workspace: ws,
            isWeb: false,
            platform: .windows,
            isDesktopHost: true,
            supportsUpdates: true,
          ),
        );
        final ids = <String>{for (final item in commands) item.id};

        final runtimeCoverageMatchers = <String, bool Function(Set<String>)>{
          'themes-preset': (s) => s.any((id) => id.startsWith('theme.preset.')),
          'themes-wallpaper': (s) => s.contains('appearance.wallpaper_set'),
          'shaders-actions': (s) => s.contains('shader.new_editor_tab'),
          'shaders-bg-chain': (s) => s.contains('shader.preset.wallpaper_wave'),
          'shaders-fg-chain': (s) => s.contains('shader.preset.crt_lottes'),
          'shaders-params': (s) =>
              s.any((id) => id.startsWith('shader.param.')),
          'shaders-cli-trusted-hashes': (s) =>
              s.contains('shader.cli_reset_trusted_hashes'),
          'updates-check': (s) => s.contains('system.check_updates'),
        };

        for (final descriptor in allSettingDescriptors) {
          if (descriptor is! FtermCustomSettingDescriptor) continue;
          final reason = descriptor.paletteExcludedReason?.trim();
          if (reason != null && reason.isNotEmpty) continue;
          final matcher = runtimeCoverageMatchers[descriptor.id];
          expect(
            matcher,
            isNotNull,
            reason:
                '${descriptor.id} must either declare paletteExcludedReason '
                'or map to runtime Palette items',
          );
          expect(
            matcher!(ids),
            isTrue,
            reason: 'Expected runtime Palette item(s) for ${descriptor.id}',
          );
        }
      },
    );
  });

  group('Exhaustive FtermSettingsSection and FtermOverlay coverage', () {
    test('every FtermSettingsSection has catalog metadata and descriptors', () {
      final ws = _createWorkspace();
      addTearDown(ws.dispose);
      final desktopCommands = buildPaletteCommands(
        PaletteContext(
          workspace: ws,
          isWeb: false,
          platform: .linux,
          isDesktopHost: true,
          supportsUpdates: true,
        ),
      );
      final commandIds = <String>{for (final item in desktopCommands) item.id};

      for (final section in FtermSettingsSection.values) {
        final expectedLabel = switch (section) {
          .interface => 'Interface',
          .themes => 'Themes',
          .shaders => 'Shaders',
          .keyboard => 'Keyboard',
          .shell => 'Shell',
          .system => 'System',
          .automation => 'Automation',
          .updates => 'Updates',
        };
        expect(SettingsCatalog.metaFor(section).label, equals(expectedLabel));
        expect(settingDescriptorsForSection(section), isNotEmpty);
        expect(commandIds, contains('settings.open.${section.name}'));
      }
    });

    test('every FtermOverlay is explicitly partitioned into palette vs non-command', () {
      final ws = _createWorkspace();
      addTearDown(ws.dispose);
      final commands = buildPaletteCommands(
        PaletteContext(
          workspace: ws,
          isWeb: false,
          platform: .linux,
          isDesktopHost: true,
          supportsUpdates: true,
        ),
      );
      final commandIds = <String>{for (final item in commands) item.id};

      for (final overlay in FtermOverlay.values) {
        final expectedCommandId = switch (overlay) {
          .none ||
          .commandPalette ||
          .licenses ||
          .feedback ||
          .fileUpload => null,
          .connect => 'overlay.connect',
          .sessionPicker => 'workspace.sessions_picker',
          .settings => 'settings.open.interface',
          .stats => 'overlay.stats',
          .rename => 'tab.rename',
          .help => 'overlay.help',
          .about => 'overlay.about',
          .whatsNew => 'overlay.whats_new',
        };
        if (expectedCommandId != null) {
          expect(
            commandIds,
            contains(expectedCommandId),
            reason: 'Overlay $overlay missing palette command',
          );
        }
      }
    });
  });

  group('Feature-flag and isAvailable zero-leakage across all 4 surfaces', () {
    testWidgets(
      'flagged-off descriptors and options never leak into Settings search, '
      'Settings UI, Command Palette, or Shortcut Dispatch',
      (tester) async {
        final ws = _createWorkspace();
        addTearDown(ws.dispose);

        var toggleState = false;
        var enumState = 'base';
        var actionFired = 0;

        const gatedShortcut = FtermShortcutBinding(
          macDesktopLabel: 'Ctrl+Shift+F8',
          linuxWinDesktopLabel: 'Ctrl+Shift+F8',
          leaderChordLabel: r'Ctrl+\ g',
          universalDesktopStroke: FtermKeyStroke(
            LogicalKeyboardKey.f8,
            ctrl: true,
            shift: true,
          ),
          leaderChord: FtermLeaderChord(LogicalKeyboardKey.keyG),
          desktopOnlyHint: true,
        );

        final gatedToggle = FtermToggleSettingDescriptor(
          id: 'experimental-toggle',
          paletteId: 'experimental.toggle',
          section: .interface,
          panelId: 'experimental-panel',
          panelTitle: 'Experimental',
          controlKey: const ValueKey('experimental-toggle-key'),
          settingsLabel: 'Quantum Buffer',
          settingsCaption: 'Experimental feature-flagged toggle',
          paletteCategory: 'Experimental',
          paletteTitle: 'Toggle Quantum Buffer',
          keywords: 'quantum experimental toggle',
          icon: Icons.science_outlined,
          featureFlag: 'flag.quantum',
          isAvailable: (ctx) => ctx.supportsUpdates,
          read: (_) => toggleState,
          write: (_, v) => toggleState = v,
        );

        final enumWithGatedOptions = FtermEnumSettingDescriptor<String>(
          id: 'experimental-mode',
          paletteIdPrefix: 'experimental.mode',
          section: .interface,
          panelId: 'experimental-panel',
          panelTitle: 'Experimental',
          settingsLabel: 'Render Mode',
          renderStyle: .segmented,
          paletteCategory: 'Experimental',
          paletteTitlePrefix: 'Render Mode',
          keywords: 'render mode experimental',
          icon: Icons.tune,
          optionsBuilder: (_) => <FtermEnumOption<String>>[
            const FtermEnumOption<String>(
              idSuffix: 'base',
              value: 'base',
              label: 'Base',
              settingsKey: ValueKey('opt-base'),
            ),
            const FtermEnumOption<String>(
              idSuffix: 'flagged',
              value: 'flagged',
              label: 'Flagged Opt',
              settingsKey: ValueKey('opt-flagged'),
              featureFlag: 'flag.opt',
            ),
            FtermEnumOption<String>(
              idSuffix: 'predicated',
              value: 'predicated',
              label: 'Predicated Opt',
              settingsKey: const ValueKey('opt-predicated'),
              isAvailable: (ctx) => ctx.isWindowsDesktop,
            ),
          ],
          read: (_) => enumState,
          write: (_, v) => enumState = v,
        );

        final gatedAction = FtermActionDescriptor(
          id: 'experimental.fire',
          category: 'Experimental',
          title: 'Fire Experimental Action',
          icon: Icons.bolt,
          shortcut: gatedShortcut,
          featureFlag: 'flag.action',
          isAvailable: (ctx) => ctx.supportsUpdates,
          execute: (_) => actionFired += 1,
        );

        const disabledCtx = FtermCapabilityContext(
          isWeb: false,
          platform: .linux,
          isDesktopHost: true,
          supportsUpdates: true,
        );
        const flagOnPredicateOffCtx = FtermCapabilityContext(
          isWeb: false,
          platform: .linux,
          isDesktopHost: true,
          supportsUpdates: false,
          enabledFeatures: <String>{'flag.quantum', 'flag.opt', 'flag.action'},
        );
        const allEnabledWindowsCtx = FtermCapabilityContext(
          isWeb: false,
          platform: .windows,
          isDesktopHost: true,
          supportsUpdates: true,
          enabledFeatures: <String>{'flag.quantum', 'flag.opt', 'flag.action'},
        );

        // 1. Settings search zero-leakage (featureFlag + isAvailable).
        final syntheticSearchItems = <SettingsSearchItem>[
          for (final entry in projectDescriptorsToSettingsSearchEntries(
            <FtermDescriptor>[gatedToggle],
          ))
            SettingsSearchItem.fromEntry(entry),
        ];
        expect(
          SettingsCatalog.search(
            'quantum',
            isWeb: false,
            isDesktopHost: true,
            supportsUpdates: true,
            isWindows: false,
            items: syntheticSearchItems,
          ).totalMatches,
          equals(0),
        );
        expect(
          SettingsCatalog.search(
            'quantum',
            isWeb: false,
            isDesktopHost: true,
            supportsUpdates: false,
            isWindows: false,
            enabledFeatures: const <String>{'flag.quantum'},
            items: syntheticSearchItems,
          ).totalMatches,
          equals(0),
        );
        expect(
          SettingsCatalog.search(
            'quantum',
            isWeb: false,
            isDesktopHost: true,
            supportsUpdates: true,
            isWindows: false,
            enabledFeatures: const <String>{'flag.quantum'},
            items: syntheticSearchItems,
          ).totalMatches,
          equals(1),
        );

        // 2. Command Palette projection zero-leakage (descriptor + option).
        final paletteDisabled = projectDescriptorsToPaletteItems(
          <FtermDescriptor>[gatedToggle, enumWithGatedOptions, gatedAction],
          ws,
          disabledCtx,
        );
        expect(
          paletteDisabled.map((e) => e.id),
          equals(const <String>['experimental.mode.base']),
        );

        final palettePredOff = projectDescriptorsToPaletteItems(
          <FtermDescriptor>[gatedToggle, enumWithGatedOptions, gatedAction],
          ws,
          flagOnPredicateOffCtx,
        );
        expect(
          palettePredOff.map((e) => e.id),
          equals(const <String>[
            'experimental.mode.base',
            'experimental.mode.flagged',
          ]),
        );

        final paletteEnabled = projectDescriptorsToPaletteItems(
          <FtermDescriptor>[gatedToggle, enumWithGatedOptions, gatedAction],
          ws,
          allEnabledWindowsCtx,
        );
        expect(
          paletteEnabled.map((e) => e.id),
          equals(const <String>[
            'experimental.toggle',
            'experimental.mode.base',
            'experimental.mode.flagged',
            'experimental.mode.predicated',
            'experimental.fire',
          ]),
        );

        // 3. Settings UI widget renderer zero-leakage (descriptor + option).
        final overlayPalette = FtermOverlayPalette.fromTerminalTheme(
          ws.activeTerminalTheme,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  buildSettingDescriptorWidget(
                    gatedToggle,
                    workspace: ws,
                    palette: overlayPalette,
                    capabilities: disabledCtx,
                  ),
                  buildSettingDescriptorWidget(
                    enumWithGatedOptions,
                    workspace: ws,
                    palette: overlayPalette,
                    capabilities: disabledCtx,
                  ),
                ],
              ),
            ),
          ),
        );
        expect(
          find.byKey(const ValueKey('experimental-toggle-key')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('opt-base')), findsOneWidget);
        expect(find.byKey(const ValueKey('opt-flagged')), findsNothing);
        expect(find.byKey(const ValueKey('opt-predicated')), findsNothing);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  buildSettingDescriptorWidget(
                    gatedToggle,
                    workspace: ws,
                    palette: overlayPalette,
                    capabilities: allEnabledWindowsCtx,
                  ),
                  buildSettingDescriptorWidget(
                    enumWithGatedOptions,
                    workspace: ws,
                    palette: overlayPalette,
                    capabilities: allEnabledWindowsCtx,
                  ),
                ],
              ),
            ),
          ),
        );
        expect(
          find.byKey(const ValueKey('experimental-toggle-key')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('opt-base')), findsOneWidget);
        expect(find.byKey(const ValueKey('opt-flagged')), findsOneWidget);
        expect(find.byKey(const ValueKey('opt-predicated')), findsOneWidget);

        // 4. Shortcut Dispatcher zero-leakage (desktop stroke + leader chord).
        final disabledDispatcher = FtermShortcutDispatcher(
          workspace: ws,
          platformOverride: .linux,
          isWebOverride: false,
          descriptorsOverride: <FtermDescriptor>[gatedAction],
        );
        const ctrlShift = <ev.Modifier>{.control, .shift};
        expect(
          disabledDispatcher.handleHostShortcut(
            _keyDown(LogicalKeyboardKey.f8),
            ctrlShift,
          ),
          equals(HostShortcutResult.unhandled),
        );
        expect(actionFired, equals(0));

        // Leader chord Ctrl+\ g also blocked when flag is off.
        disabledDispatcher.handleHostShortcut(
          _keyDown(LogicalKeyboardKey.backslash),
          const <ev.Modifier>{.control},
        );
        disabledDispatcher.handleHostShortcut(
          _keyDown(LogicalKeyboardKey.keyG),
          const <ev.Modifier>{},
        );
        expect(actionFired, equals(0));

        // When feature flag is enabled AND supportsUpdates is true, both fire.
        final enabledDispatcher = FtermShortcutDispatcher(
          workspace: ws,
          platformOverride: .linux,
          isWebOverride: false,
          enabledFeatures: const <String>{'flag.action'},
          descriptorsOverride: <FtermDescriptor>[gatedAction],
        );
        expect(
          enabledDispatcher.handleHostShortcut(
            _keyDown(LogicalKeyboardKey.f8),
            ctrlShift,
          ),
          equals(HostShortcutResult.handled),
        );
        expect(actionFired, equals(1));

        enabledDispatcher.handleHostShortcut(
          _keyDown(LogicalKeyboardKey.backslash),
          const <ev.Modifier>{.control},
        );
        enabledDispatcher.handleHostShortcut(
          _keyDown(LogicalKeyboardKey.keyG),
          const <ev.Modifier>{},
        );
        expect(actionFired, equals(2));

        // Still blocked when feature flag is enabled but isAvailable fails.
        final noUpdatesWs = _createWorkspace(supportsUpdates: false);
        addTearDown(noUpdatesWs.dispose);
        final predicateBlockedDispatcher = FtermShortcutDispatcher(
          workspace: noUpdatesWs,
          platformOverride: .linux,
          isWebOverride: false,
          enabledFeatures: const <String>{'flag.action'},
          descriptorsOverride: <FtermDescriptor>[gatedAction],
        );
        expect(
          predicateBlockedDispatcher.handleHostShortcut(
            _keyDown(LogicalKeyboardKey.f8),
            ctrlShift,
          ),
          equals(HostShortcutResult.unhandled),
        );
        expect(actionFired, equals(2));
      },
    );
  });

  group('Shortcut dispatch parity & Web hint hygiene', () {
    test('dispatches real KeyDownEvents matching FtermShortcuts on desktop and '
        'blocks desktop-only strokes on Web', () async {
      final recorder = FtermTraceRecorder(
        sampleRssBytes: () => 64 * 1024 * 1024,
        registerTimingsCallback: (_) {},
        unregisterTimingsCallback: (_) {},
        exporter:
            ({
              required basePath,
              required traceJson,
              required summaryJson,
              required eventCount,
            }) async => TraceExportResult(
              tracePath: '$basePath.trace.json',
              summaryPath: '$basePath.summary.json',
              eventCount: eventCount,
            ),
      );
      final ws = _createWorkspace(traceRecorder: recorder);
      addTearDown(() async {
        recorder.dispose();
        await ws.dispose();
      });

      final linuxDispatcher = FtermShortcutDispatcher(
        workspace: ws,
        platformOverride: .linux,
        isWebOverride: false,
      );
      final macDispatcher = FtermShortcutDispatcher(
        workspace: ws,
        platformOverride: .macOS,
        isWebOverride: false,
      );
      final webDispatcher = FtermShortcutDispatcher(
        workspace: ws,
        platformOverride: .linux,
        isWebOverride: true,
      );
      const ctrlShift = <ev.Modifier>{.control, .shift};
      const metaShift = <ev.Modifier>{.meta, .shift};
      const metaOnly = <ev.Modifier>{.meta};
      const ctrlOnly = <ev.Modifier>{.control};

      // Ctrl+Shift+F9 toggles Perf HUD on desktop, blocked on Web.
      expect(ws.showPerfHud, isFalse);
      expect(
        linuxDispatcher.handleHostShortcut(
          _keyDown(LogicalKeyboardKey.f9),
          ctrlShift,
        ),
        equals(HostShortcutResult.handled),
      );
      expect(ws.showPerfHud, isTrue);
      expect(
        webDispatcher.handleHostShortcut(
          _keyDown(LogicalKeyboardKey.f9),
          ctrlShift,
        ),
        equals(HostShortcutResult.unhandled),
      );
      expect(ws.showPerfHud, isTrue);

      // Ctrl+Shift+F10 toggles trace recording on desktop, blocked on Web.
      expect(ws.isRecordingTrace, isFalse);
      expect(
        linuxDispatcher.handleHostShortcut(
          _keyDown(LogicalKeyboardKey.f10),
          ctrlShift,
        ),
        equals(HostShortcutResult.handled),
      );
      await Future<void>.delayed(Duration.zero);
      expect(ws.isRecordingTrace, isTrue);
      expect(
        webDispatcher.handleHostShortcut(
          _keyDown(LogicalKeyboardKey.f10),
          ctrlShift,
        ),
        equals(HostShortcutResult.unhandled),
      );
      await Future<void>.delayed(Duration.zero);
      expect(ws.isRecordingTrace, isTrue);
      // Stop recording cleanly.
      linuxDispatcher.handleHostShortcut(
        _keyDown(LogicalKeyboardKey.f10),
        ctrlShift,
      );
      await Future<void>.delayed(Duration.zero);
      expect(ws.isRecordingTrace, isFalse);

      // Ctrl+Shift+F6 toggles shader E-Stop on BOTH desktop and Web.
      expect(ws.shadersEmergencyStopped, isFalse);
      expect(
        webDispatcher.handleHostShortcut(
          _keyDown(LogicalKeyboardKey.f6),
          ctrlShift,
        ),
        equals(HostShortcutResult.handled),
      );
      expect(ws.shadersEmergencyStopped, isTrue);
      expect(
        linuxDispatcher.handleHostShortcut(
          _keyDown(LogicalKeyboardKey.f6),
          ctrlShift,
        ),
        equals(HostShortcutResult.handled),
      );
      expect(ws.shadersEmergencyStopped, isFalse);

      // Cmd+Shift+P on macOS opens and toggles Command Palette; blocked on Web.
      expect(
        macDispatcher.handleHostShortcut(
          _keyDown(LogicalKeyboardKey.keyP),
          metaShift,
        ),
        equals(HostShortcutResult.handled),
      );
      expect(ws.activeOverlay, equals(FtermOverlay.commandPalette));
      expect(
        macDispatcher.handleHostShortcut(
          _keyDown(LogicalKeyboardKey.keyP),
          metaShift,
        ),
        equals(HostShortcutResult.handled),
      );
      expect(ws.activeOverlay, equals(FtermOverlay.none));

      expect(
        webDispatcher.handleHostShortcut(
          _keyDown(LogicalKeyboardKey.keyP),
          ctrlShift,
        ),
        equals(HostShortcutResult.unhandled),
      );
      expect(ws.activeOverlay, equals(FtermOverlay.none));

      // Cmd+, opens Settings on macOS; Ctrl+Shift+, opens Settings on Linux.
      expect(
        macDispatcher.handleHostShortcut(
          _keyDown(LogicalKeyboardKey.comma),
          metaOnly,
        ),
        equals(HostShortcutResult.handled),
      );
      expect(ws.activeOverlay, equals(FtermOverlay.settings));
      ws.dismissOverlay();

      expect(
        linuxDispatcher.handleHostShortcut(
          _keyDown(LogicalKeyboardKey.comma),
          ctrlShift,
        ),
        equals(HostShortcutResult.handled),
      );
      expect(ws.activeOverlay, equals(FtermOverlay.settings));
      ws.dismissOverlay();

      // Leader chords work across Web and desktop (e.g. Ctrl+\ ?, Ctrl+\ d,
      // Ctrl+\ Shift+P).
      webDispatcher.handleHostShortcut(
        _keyDown(LogicalKeyboardKey.backslash),
        ctrlOnly,
      );
      webDispatcher.handleHostShortcut(
        _keyDown(LogicalKeyboardKey.slash, character: '?'),
        const <ev.Modifier>{.shift},
      );
      expect(ws.activeOverlay, equals(FtermOverlay.help));
      ws.dismissOverlay();

      final dockBefore = ws.dockPosition;
      webDispatcher.handleHostShortcut(
        _keyDown(LogicalKeyboardKey.backslash),
        ctrlOnly,
      );
      webDispatcher.handleHostShortcut(
        _keyDown(LogicalKeyboardKey.space),
        const <ev.Modifier>{},
      );
      expect(ws.dockPosition, isNot(equals(dockBefore)));
    });

    test('zero desktop-only shortcut hints leak into Web Palette items', () {
      final ws = _createWorkspace();
      addTearDown(ws.dispose);

      const forbiddenWebHints = <String>{
        'Cmd+T',
        'Cmd+W',
        'Cmd+D',
        'Cmd+Shift+D',
        'Cmd+Shift+P',
        'Ctrl+Shift+T',
        'Ctrl+Shift+W',
        'Ctrl+Shift+D',
        'Ctrl+Shift+E',
        'Ctrl+Shift+P',
        'Ctrl+Shift+F5',
        'Ctrl+Shift+F9',
        'Ctrl+Shift+F10',
      };

      for (final platform in const <TargetPlatform>[.macOS, .linux, .windows]) {
        final webCommands = buildPaletteCommands(
          PaletteContext(
            workspace: ws,
            isWeb: true,
            platform: platform,
            isDesktopHost: false,
            supportsUpdates: false,
          ),
        );
        for (final item in webCommands) {
          final hint = item.shortcutHint;
          if (hint == null) continue;
          expect(
            forbiddenWebHints.contains(hint),
            isFalse,
            reason:
                'Desktop-only hint "$hint" leaked onto Web ($platform) for '
                '${item.id}',
          );
        }
      }
    });

    test('Help overlay entries cover Trace Recording and canonical chords', () {
      final entries = buildHelpShortcutEntries();
      final byKeys = <String, String>{
        for (final entry in entries) entry.keys: entry.description,
      };
      expect(byKeys.containsKey('Ctrl+Shift+F10'), isTrue);
      expect(byKeys.containsKey('Ctrl+Shift+F9'), isTrue);
      expect(byKeys.containsKey('Ctrl+Shift+F5'), isTrue);
      expect(byKeys.containsKey(r'Ctrl+Shift+F6 / Ctrl+\ 0'), isTrue);
      expect(byKeys.containsKey('Cmd+= / Cmd+- / Cmd+0'), isTrue);
      expect(byKeys.containsKey('Ctrl+= / Ctrl+- / Ctrl+0'), isTrue);
      expect(byKeys.containsKey(r'Ctrl+\ then e'), isTrue);
    });
  });

  group('Review regression suite (H1, H2, M1, M2, M3, M4)', () {
    test('H1: SettingsCatalog.search enforces macOsDesktop, linuxDesktop, '
        'localDesktopShell, and updatesSupported outside .shell/.updates', () {
      final descriptors = <FtermDescriptor>[
        const FtermCustomSettingDescriptor(
          id: 'iface-macos-only',
          section: .interface,
          panelId: 'interface-tab-bar',
          panelTitle: 'Tab Bar',
          title: 'Visibility Probe macOS',
          keywords: 'visprobe',
          visibility: .macOsDesktop,
        ),
        const FtermCustomSettingDescriptor(
          id: 'iface-linux-only',
          section: .interface,
          panelId: 'interface-tab-bar',
          panelTitle: 'Tab Bar',
          title: 'Visibility Probe Linux',
          keywords: 'visprobe',
          visibility: .linuxDesktop,
        ),
        const FtermCustomSettingDescriptor(
          id: 'system-local-shell-only',
          section: .system,
          panelId: 'system-graphics',
          panelTitle: 'Graphics & Performance',
          title: 'Visibility Probe Local Shell',
          keywords: 'visprobe',
          visibility: .localDesktopShell,
        ),
        const FtermCustomSettingDescriptor(
          id: 'system-updates-only',
          section: .system,
          panelId: 'system-graphics',
          panelTitle: 'Graphics & Performance',
          title: 'Visibility Probe Updates',
          keywords: 'visprobe',
          visibility: .updatesSupported,
        ),
      ];
      final items = <SettingsSearchItem>[
        for (final entry in projectDescriptorsToSettingsSearchEntries(
          descriptors,
        ))
          SettingsSearchItem.fromEntry(entry),
      ];

      Set<String> matchedIds(FtermCapabilityContext capabilities) => <String>{
        for (final panel in SettingsCatalog.search(
          'visprobe',
          capabilities: capabilities,
          items: items,
        ).panelMatches)
          ...panel.matchedItemIds,
      };

      expect(
        matchedIds(
          const FtermCapabilityContext(
            isWeb: false,
            platform: .macOS,
            isDesktopHost: true,
            supportsUpdates: true,
          ),
        ),
        equals(const <String>{
          'iface-macos-only',
          'system-local-shell-only',
          'system-updates-only',
        }),
      );
      expect(
        matchedIds(
          const FtermCapabilityContext(
            isWeb: false,
            platform: .linux,
            isDesktopHost: false,
            supportsUpdates: false,
          ),
        ),
        equals(const <String>{'iface-linux-only'}),
      );
      expect(
        matchedIds(
          const FtermCapabilityContext(
            isWeb: false,
            platform: .windows,
            isDesktopHost: true,
            supportsUpdates: false,
          ),
        ),
        equals(const <String>{'system-local-shell-only'}),
      );
      expect(
        matchedIds(
          const FtermCapabilityContext(
            isWeb: true,
            platform: .macOS,
            isDesktopHost: true,
            supportsUpdates: true,
          ),
        ),
        isEmpty,
      );

      // Compatibility derivation on manual SettingsSearchItem constructors.
      const macItem = SettingsSearchItem(
        id: 'manual-mac',
        section: .interface,
        panelId: 'p',
        panelTitle: 'P',
        title: 'Manual Mac',
        keywords: 'manual',
        visibility: .macOsDesktop,
      );
      expect(macItem.desktopOnly, isTrue);
      expect(macItem.windowsOnly, isFalse);

      const legacyWinItem = SettingsSearchItem(
        id: 'manual-win',
        section: .interface,
        panelId: 'p',
        panelTitle: 'P',
        title: 'Manual Win',
        keywords: 'manual',
        windowsOnly: true,
      );
      expect(legacyWinItem.visibility, equals(FtermVisibility.windowsDesktop));
      expect(legacyWinItem.desktopOnly, isTrue);
    });

    test('M1: SettingsCatalog.search preserves macOS platform without '
        'misidentifying it as Linux', () {
      final macPredicateItem = SettingsSearchItem(
        id: 'probe-mac-pred',
        section: .interface,
        panelId: 'interface-tab-bar',
        panelTitle: 'Tab Bar',
        title: 'macOS Predicate Setting',
        keywords: 'osprobe',
        isAvailable: (ctx) => ctx.isMacOsDesktop,
      );
      final linuxPredicateItem = SettingsSearchItem(
        id: 'probe-linux-pred',
        section: .interface,
        panelId: 'interface-tab-bar',
        panelTitle: 'Tab Bar',
        title: 'Linux Predicate Setting',
        keywords: 'osprobe',
        isAvailable: (ctx) => ctx.isLinuxDesktop,
      );
      final items = <SettingsSearchItem>[macPredicateItem, linuxPredicateItem];

      final macViaPlatform = SettingsCatalog.search(
        'osprobe',
        isWeb: false,
        isDesktopHost: true,
        supportsUpdates: true,
        isWindows: false,
        platform: .macOS,
        items: items,
      );
      expect(
        macViaPlatform.panelMatches.single.matchedItemIds,
        equals(const <String>{'probe-mac-pred'}),
      );

      final macViaCapabilities = SettingsCatalog.search(
        'osprobe',
        capabilities: const FtermCapabilityContext(
          isWeb: false,
          platform: .macOS,
          isDesktopHost: true,
          supportsUpdates: true,
        ),
        items: items,
      );
      expect(
        macViaCapabilities.panelMatches.single.matchedItemIds,
        equals(const <String>{'probe-mac-pred'}),
      );
    });

    testWidgets(
      'H2: Settings sections and overlay propagate isWeb, platformOverride, '
      'and shared capabilities consistently to child panels',
      (tester) async {
        final ws = _createWorkspace();
        addTearDown(ws.dispose);
        final palette = FtermOverlayPalette.fromTerminalTheme(
          ws.activeTerminalTheme,
        );

        // System section: Windows platformOverride renders GPU Driver row even
        // when Theme.platform is Linux, and Web hides it.
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: .linux),
            home: Scaffold(
              body: SingleChildScrollView(
                child: SettingsSystemSection(
                  workspace: ws,
                  palette: palette,
                  isWeb: false,
                  platformOverride: .windows,
                ),
              ),
            ),
          ),
        );
        expect(
          find.byKey(const ValueKey('settings-gpu-driver-powerSaving')),
          findsOneWidget,
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: .windows),
            home: Scaffold(
              body: SingleChildScrollView(
                child: SettingsSystemSection(
                  workspace: ws,
                  palette: palette,
                  isWeb: true,
                  platformOverride: .windows,
                ),
              ),
            ),
          ),
        );
        expect(
          find.byKey(const ValueKey('settings-gpu-driver-powerSaving')),
          findsNothing,
        );

        // Keyboard tab: isWeb + platformOverride flow to Meta policy summary
        // and passthrough presets from a single capability context.
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: .linux),
            home: Scaffold(
              body: SingleChildScrollView(
                child: FtermKeyboardSettingsTab(
                  workspace: ws,
                  palette: palette,
                  isWeb: false,
                  platformOverride: .macOS,
                ),
              ),
            ),
          ),
        );
        expect(
          find.text('Auto (macOS): passes unhandled Cmd chords to macOS.'),
          findsOneWidget,
        );

        // Themes & Shaders sections honor explicit capabilities without
        // throwing or dropping isWeb polarity.
        const webMacCaps = FtermCapabilityContext(
          isWeb: true,
          platform: .macOS,
          isDesktopHost: false,
          supportsUpdates: false,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [
                    SettingsThemesSection(
                      workspace: ws,
                      palette: palette,
                      isWeb: true,
                      capabilities: webMacCaps,
                    ),
                    SettingsShadersSection(
                      workspace: ws,
                      palette: palette,
                      isWeb: true,
                      capabilities: webMacCaps,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        expect(
          find.byKey(const ValueKey('settings-upload-glsl')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('settings-open-shaders-folder')),
          findsNothing,
        );

        // Full FtermSettingsOverlay on macOS renders accurately and searches
        // with macOS capabilities (never showing Windows-only GPU adapter).
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: .windows),
            home: Scaffold(
              body: SizedBox(
                width: 900,
                height: 600,
                child: FtermSettingsOverlay(
                  workspace: ws,
                  palette: palette,
                  onOpenUrl: (_) {},
                  isWeb: false,
                  platformOverride: .macOS,
                ),
              ),
            ),
          ),
        );
        await tester.enterText(
          find.byKey(const ValueKey('settings-search-field')),
          'dxgi',
        );
        await tester.pump();
        expect(
          find.byKey(const ValueKey('settings-search-empty')),
          findsOneWidget,
        );
      },
    );

    test('M2: hidden shortcut descriptor does not shadow a visible fallback '
        'for desktop strokes or leader chords', () {
      final ws = _createWorkspace();
      addTearDown(ws.dispose);

      var hiddenCalls = 0;
      var fallbackCalls = 0;
      const sharedBinding = FtermShortcutBinding(
        macDesktopLabel: 'Ctrl+Shift+F7',
        linuxWinDesktopLabel: 'Ctrl+Shift+F7',
        leaderChordLabel: r'Ctrl+\ y',
        universalDesktopStroke: FtermKeyStroke(
          LogicalKeyboardKey.f7,
          ctrl: true,
          shift: true,
        ),
        leaderChord: FtermLeaderChord(LogicalKeyboardKey.keyY),
      );
      final hiddenReplacement = FtermActionDescriptor(
        id: 'test.hidden_first',
        category: 'Test',
        title: 'Flagged Replacement',
        icon: Icons.science_outlined,
        shortcut: sharedBinding,
        featureFlag: 'flag.new_binding',
        execute: (_) => hiddenCalls++,
      );
      final visibleFallback = FtermActionDescriptor(
        id: 'test.visible_fallback',
        category: 'Test',
        title: 'Visible Fallback',
        icon: Icons.bolt,
        shortcut: sharedBinding,
        execute: (_) => fallbackCalls++,
      );

      final dispatcher = FtermShortcutDispatcher(
        workspace: ws,
        platformOverride: .linux,
        isWebOverride: false,
        descriptorsOverride: <FtermDescriptor>[
          hiddenReplacement,
          visibleFallback,
        ],
      );

      // Desktop stroke skips hidden replacement and invokes visible fallback.
      expect(
        dispatcher.handleHostShortcut(
          _keyDown(LogicalKeyboardKey.f7),
          const <ev.Modifier>{.control, .shift},
        ),
        equals(HostShortcutResult.handled),
      );
      expect(hiddenCalls, equals(0));
      expect(fallbackCalls, equals(1));

      // Leader chord skips hidden replacement and invokes visible fallback.
      dispatcher.handleHostShortcut(
        _keyDown(LogicalKeyboardKey.backslash),
        const <ev.Modifier>{.control},
      );
      dispatcher.handleHostShortcut(
        _keyDown(LogicalKeyboardKey.keyY),
        const <ev.Modifier>{},
      );
      expect(hiddenCalls, equals(0));
      expect(fallbackCalls, equals(2));

      // Enabling the flag invokes the replacement descriptor first.
      final flaggedDispatcher = FtermShortcutDispatcher(
        workspace: ws,
        platformOverride: .linux,
        isWebOverride: false,
        enabledFeatures: const <String>{'flag.new_binding'},
        descriptorsOverride: <FtermDescriptor>[
          hiddenReplacement,
          visibleFallback,
        ],
      );
      expect(
        flaggedDispatcher.handleHostShortcut(
          _keyDown(LogicalKeyboardKey.f7),
          const <ev.Modifier>{.control, .shift},
        ),
        equals(HostShortcutResult.handled),
      );
      expect(hiddenCalls, equals(1));
      expect(fallbackCalls, equals(2));
    });

    test('M3: descriptorsOverride fails closed when shader.emergency_stop or '
        'workspace.new_local_shell is omitted', () {
      final ws = _createWorkspace(isDesktopHost: true);
      addTearDown(ws.dispose);

      final emptyOverrideDispatcher = FtermShortcutDispatcher(
        workspace: ws,
        platformOverride: .linux,
        isWebOverride: false,
        descriptorsOverride: const <FtermDescriptor>[],
      );
      const ctrlShift = <ev.Modifier>{.control, .shift};
      const ctrlOnly = <ev.Modifier>{.control};

      // Omitted shader.emergency_stop disables Ctrl+Shift+F6.
      expect(ws.shadersEmergencyStopped, isFalse);
      expect(
        emptyOverrideDispatcher.handleHostShortcut(
          _keyDown(LogicalKeyboardKey.f6),
          ctrlShift,
        ),
        equals(HostShortcutResult.unhandled),
      );
      expect(ws.shadersEmergencyStopped, isFalse);

      // Omitted shader.emergency_stop disables overlay leader Ctrl+\ 0.
      ws.setOverlay(.help);
      emptyOverrideDispatcher.handleHostShortcut(
        _keyDown(LogicalKeyboardKey.backslash),
        ctrlOnly,
      );
      emptyOverrideDispatcher.handleHostShortcut(
        _keyDown(LogicalKeyboardKey.digit0),
        const <ev.Modifier>{},
      );
      expect(ws.shadersEmergencyStopped, isFalse);
      ws.dismissOverlay();

      // Omitted workspace.new_local_shell disables Ctrl+Shift+T on desktop host
      // (fails closed instead of calling openLocalShellTab or falling back to
      // global catalog).
      expect(
        emptyOverrideDispatcher.handleHostShortcut(
          _keyDown(LogicalKeyboardKey.keyT),
          ctrlShift,
        ),
        equals(HostShortcutResult.unhandled),
      );
      expect(ws.tabs, isEmpty);
    });

    testWidgets(
      'M4: workspace.enabledFeatures governs all four surfaces without manual '
      'threading',
      (tester) async {
        final flaggedWs = _createWorkspace(
          enabledFeatures: const <String>{'flag.unified_rollout'},
        );
        final unflaggedWs = _createWorkspace();
        addTearDown(() async {
          await flaggedWs.dispose();
          await unflaggedWs.dispose();
        });

        // Workspace exposes an unmodifiable feature set.
        expect(
          () => flaggedWs.enabledFeatures.add('other'),
          throwsUnsupportedError,
        );
        expect(unflaggedWs.enabledFeatures, isEmpty);

        var fired = 0;
        const binding = FtermShortcutBinding(
          macDesktopLabel: 'Ctrl+Shift+F7',
          linuxWinDesktopLabel: 'Ctrl+Shift+F7',
          universalDesktopStroke: FtermKeyStroke(
            LogicalKeyboardKey.f7,
            ctrl: true,
            shift: true,
          ),
        );
        final flaggedToggle = FtermToggleSettingDescriptor(
          id: 'unified-flag-toggle',
          paletteId: 'unified.flag_toggle',
          section: .interface,
          panelId: 'interface-tab-bar',
          panelTitle: 'Tab Bar',
          controlKey: const ValueKey('unified-flag-checkbox'),
          settingsLabel: 'Unified Rollout Setting',
          settingsCaption: 'Gated by workspace.enabledFeatures',
          paletteCategory: 'Experimental',
          paletteTitle: 'Toggle Unified Rollout',
          keywords: 'unifiedrollout',
          icon: Icons.flag_outlined,
          featureFlag: 'flag.unified_rollout',
          read: (_) => false,
          write: (_, _) {},
        );
        final flaggedAction = FtermActionDescriptor(
          id: 'unified.flag_action',
          category: 'Experimental',
          title: 'Run Unified Action',
          icon: Icons.bolt,
          shortcut: binding,
          featureFlag: 'flag.unified_rollout',
          execute: (_) => fired++,
        );
        final searchItems = <SettingsSearchItem>[
          for (final entry in projectDescriptorsToSettingsSearchEntries(
            <FtermDescriptor>[flaggedToggle],
          ))
            SettingsSearchItem.fromEntry(entry),
        ];

        // 1. FtermCapabilityContext.fromWorkspace inherits workspace flags.
        final enabledCaps = FtermCapabilityContext.fromWorkspace(
          flaggedWs,
          isWeb: false,
          platform: .linux,
        );
        final disabledCaps = FtermCapabilityContext.fromWorkspace(
          unflaggedWs,
          isWeb: false,
          platform: .linux,
        );
        expect(enabledCaps.isFeatureEnabled('flag.unified_rollout'), isTrue);
        expect(disabledCaps.isFeatureEnabled('flag.unified_rollout'), isFalse);

        // 2. Settings UI widget rendering inherits workspace flags.
        final palette = FtermOverlayPalette.fromTerminalTheme(
          flaggedWs.activeTerminalTheme,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: buildSettingDescriptorWidget(
                flaggedToggle,
                workspace: flaggedWs,
                palette: palette,
                capabilities: enabledCaps,
              ),
            ),
          ),
        );
        expect(
          find.byKey(const ValueKey('unified-flag-checkbox')),
          findsOneWidget,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: buildSettingDescriptorWidget(
                flaggedToggle,
                workspace: unflaggedWs,
                palette: palette,
                capabilities: disabledCaps,
              ),
            ),
          ),
        );
        expect(
          find.byKey(const ValueKey('unified-flag-checkbox')),
          findsNothing,
        );

        // 3. Settings search inherits workspace flags via capabilities.
        expect(
          SettingsCatalog.search(
            'unifiedrollout',
            capabilities: enabledCaps,
            items: searchItems,
          ).totalMatches,
          equals(1),
        );
        expect(
          SettingsCatalog.search(
            'unifiedrollout',
            capabilities: disabledCaps,
            items: searchItems,
          ).totalMatches,
          equals(0),
        );

        // 4. PaletteContext inherits workspace flags without passing them.
        final enabledPalette = PaletteContext(
          workspace: flaggedWs,
          isWeb: false,
          platform: .linux,
        );
        final disabledPalette = PaletteContext(
          workspace: unflaggedWs,
          isWeb: false,
          platform: .linux,
        );
        expect(
          projectDescriptorsToPaletteItems(
            <FtermDescriptor>[flaggedToggle, flaggedAction],
            flaggedWs,
            enabledPalette.capabilities,
          ).map((e) => e.id),
          equals(const <String>['unified.flag_toggle', 'unified.flag_action']),
        );
        expect(
          projectDescriptorsToPaletteItems(
            <FtermDescriptor>[flaggedToggle, flaggedAction],
            unflaggedWs,
            disabledPalette.capabilities,
          ),
          isEmpty,
        );

        // 5. FtermShortcutDispatcher inherits workspace flags without passing them.
        final enabledDispatcher = FtermShortcutDispatcher(
          workspace: flaggedWs,
          platformOverride: .linux,
          isWebOverride: false,
          descriptorsOverride: <FtermDescriptor>[flaggedAction],
        );
        final disabledDispatcher = FtermShortcutDispatcher(
          workspace: unflaggedWs,
          platformOverride: .linux,
          isWebOverride: false,
          descriptorsOverride: <FtermDescriptor>[flaggedAction],
        );
        expect(
          disabledDispatcher.handleHostShortcut(
            _keyDown(LogicalKeyboardKey.f7),
            const <ev.Modifier>{.control, .shift},
          ),
          equals(HostShortcutResult.unhandled),
        );
        expect(fired, equals(0));
        expect(
          enabledDispatcher.handleHostShortcut(
            _keyDown(LogicalKeyboardKey.f7),
            const <ev.Modifier>{.control, .shift},
          ),
          equals(HostShortcutResult.handled),
        );
        expect(fired, equals(1));

        // Explicit empty override still overrides workspace.enabledFeatures.
        final overriddenDispatcher = FtermShortcutDispatcher(
          workspace: flaggedWs,
          platformOverride: .linux,
          isWebOverride: false,
          enabledFeatures: const <String>{},
          descriptorsOverride: <FtermDescriptor>[flaggedAction],
        );
        expect(
          overriddenDispatcher.handleHostShortcut(
            _keyDown(LogicalKeyboardKey.f7),
            const <ev.Modifier>{.control, .shift},
          ),
          equals(HostShortcutResult.unhandled),
        );
        expect(fired, equals(1));
      },
    );
  });
}
